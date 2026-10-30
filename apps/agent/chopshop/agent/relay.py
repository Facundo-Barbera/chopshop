import hashlib
import json
import logging
import os
import socket
import time

from .. import relaycfg, relaysync, wsclient
from . import USER_AGENT, envelope, events

log = logging.getLogger("chopshop.agent.relay")

TICK = 1.0
IO_TIMEOUT = 5.0
WELCOME_TIMEOUT = 10.0
SNAPSHOT_EVERY = 6.0
EVENTS_PER_TICK = 40
PING_DEFAULT = 30.0
BACKOFF_CAP = 60.0
SYNC_WAIT = 5.0
HOLD_S = 600.0
WATCH_EVERY = 30.0
REFUSED = {"unauthorized": 401, "forbidden": 403, "conflict": 409}
LAST_ERROR = {401: "revocada", 403: "pausada", 409: "conflicto"}


def configured():
    try:
        machine = relaycfg.read_machine()
        if machine:
            return relaycfg.ws_url(machine["api_url"]), machine["credential"]
        url = relaycfg.ws_url(relaycfg.relay_url())
    except relaycfg.RelayCfgError as e:
        log.warning("relay desactivado: %s", e)
        return None
    if not url:
        return None
    try:
        token = relaycfg.read_token()
    except OSError as e:
        log.warning("relay desactivado: no pude leer el token (%s)", e.strerror or type(e).__name__)
        return None
    if not token or not relaycfg.TOKEN_RE.match(token):
        log.warning("relay desactivado: [relay] url está configurado pero no hay un token cr1_ válido (`chopshop relay pair`)")
        return None
    return url, token


def _dump(msg):
    return json.dumps(msg, ensure_ascii=False, separators=(",", ":"))


def _digest(msg):
    body = {k: v for k, v in msg.items() if k not in ("id", "ts")}
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def refusal(e):
    if isinstance(e, wsclient.WSClosed) and e.code in (4401, 4403, 4409):
        return e.code - 4000
    parts = str(e).split(" ")
    if str(e).startswith("handshake failed:") and len(parts) > 3 and parts[3] in ("401", "403", "409"):
        return int(parts[3])
    return None


def _machine_stamp():
    try:
        st = os.stat(relaycfg.machine_path())
    except OSError:
        return None
    return st.st_mtime_ns, st.st_ino, st.st_size


class RelayLink:
    def __init__(self, url, token, machine_id, conn, snapshot_fn, state_fn, profiles_fn, stop_event,
                 clock=time.monotonic, factory=None, backoff=None, jitter=None, tick=TICK, offer_fn=None):
        self.url, self._token, self.machine_id, self.conn = url, token, machine_id, conn
        self.snapshot_fn, self.state_fn, self.profiles_fn = snapshot_fn, state_fn, profiles_fn
        self.stop, self.clock, self.tick = stop_event, clock, tick
        self.factory = factory or self._client
        self.offer_fn = offer_fn or relaysync.local_projects
        self.backoff = backoff or wsclient.exponential_backoff(cap=BACKOFF_CAP)
        self.jitter = jitter or wsclient.full_jitter()
        self.attempt = 0
        self.connected = False
        self.last_error = None
        self.sent = {"snapshot": 0, "event": 0, "import.offer": 0}
        self.v = 2 if relaycfg.MACHINE_CRED_RE.match(token or "") else 1
        self.machine, self.rev = None, None
        self.workspaces, self.ws_map = [], {}
        self._synced = False
        self._cloud_names = set()
        self._offer_due, self._offered = False, None

    def _client(self):
        headers = {"Authorization": "Bearer " + self._token, "User-Agent": USER_AGENT}
        return wsclient.WSClient(self.url, headers=headers, timeout=IO_TIMEOUT)

    def run(self):
        while not self.stop.is_set():
            client, err = None, None
            try:
                client = self.factory()
                client.connect()
                self._session(client)
            except (OSError, ValueError, wsclient.WSError) as e:
                err = e
                self._down(e)
            except Exception as e:
                log.exception("relay: fallo inesperado")
                self._down(e)
            finally:
                if client is not None:
                    client.close(wait=False)
            if self.stop.is_set():
                break
            status = refusal(err) if self.v == 2 and err is not None else None
            if status is not None:
                self.last_error = LAST_ERROR[status]
            if status == 401:
                log.warning("relay: credencial de máquina revocada; espero a que cambie machine.json")
                self._await_relink()
                continue
            if status is not None:
                log.warning("relay: rechazo (%s); reintento en %ds", self.last_error, int(HOLD_S))
                self.stop.wait(HOLD_S)
                continue
            delay = max(0.0, self.jitter(self.backoff(self.attempt)))
            self.attempt += 1
            self.stop.wait(delay)
        self.connected = False

    def _await_relink(self):
        stamp = _machine_stamp()
        while not self.stop.wait(WATCH_EVERY):
            now = _machine_stamp()
            if now == stamp:
                continue
            stamp = now
            try:
                machine = relaycfg.read_machine()
                url = relaycfg.ws_url(machine["api_url"]) if machine else None
            except relaycfg.RelayCfgError as e:
                log.warning("relay: machine.json inválido: %s", e)
                continue
            if machine:
                self.url, self._token, self.attempt = url, machine["credential"], 0
                return

    def _down(self, e):
        msg = "%s: %s" % (type(e).__name__, e)
        if self.connected or msg != self.last_error:
            log.warning("relay desconectado (%s); reintento con backoff", msg)
        self.connected = False
        self.last_error = msg

    def _send(self, client, msg):
        client.sock.settimeout(IO_TIMEOUT)
        client.send_text(_dump(msg))

    def _recv(self, client, timeout):
        client.sock.settimeout(timeout)
        try:
            op, data = client.recv()
        except socket.timeout:
            return None
        self._rx = self.clock()
        if op != wsclient.OP_TEXT:
            return None
        try:
            msg = json.loads(data)
        except ValueError:
            return None
        return msg if isinstance(msg, dict) else None

    def _handle(self, client, msg):
        kind = msg.get("type")
        if kind == "ping":
            self._send(client, {"v": self.v, "type": "pong", "id": envelope.new_id(), "ts": envelope.iso(), "re": msg.get("id")})
        elif kind == "sync" and self.v == 2:
            self.workspaces, self.ws_map = relaysync.workspace_map(msg)
            self.rev = msg.get("rev")
            self._cloud_names = relaysync.sync_names(msg)
            self._synced = True
            self._offer_due = True
        elif kind == "import.result" and self.v == 2:
            self._import_result(msg)
        elif kind == "error":
            log.warning("relay: error %s: %s", msg.get("code"), msg.get("message"))
            retry = msg.get("retry_after_s")
            if isinstance(retry, (int, float)) and not isinstance(retry, bool):
                self._hold = self.clock() + float(retry)
            if msg.get("close"):
                raise wsclient.WSClosed(self._close_code(msg), "el relay cierra: %s" % msg.get("code"))

    def _import_result(self, msg):
        if not self._offered or msg.get("re") != self._offered[0]:
            return
        if msg.get("status") in ("stored", "duplicate"):
            try:
                relaysync.write_import_hash(self._offered[1])
            except OSError as e:
                log.warning("relay: no pude guardar el hash de la oferta: %s", e.strerror or type(e).__name__)
            log.info("relay: oferta de importación %s (%s)", msg.get("status"), msg.get("import_id"))

    def _offer(self, client):
        self._offer_due = False
        try:
            msg, skipped = relaysync.import_offer(self.offer_fn(self._cloud_names))
        except Exception as e:
            log.warning("relay: no pude construir la oferta de importación: %s", e)
            return
        if skipped:
            log.warning("relay: proyectos fuera de la oferta de importación por tamaño: %s", ", ".join(skipped))
        if msg is None:
            return
        h = relaysync.offer_hash(msg["projects"])
        if (self._offered and self._offered[1] == h) or relaysync.read_import_hash() == h:
            return
        self._send(client, msg)
        self.sent["import.offer"] += 1
        self._offered = (msg["id"], h)

    def _close_code(self, msg):
        status = REFUSED.get(msg.get("code"))
        return 4000 + status if status else None

    def _roles(self):
        try:
            return relaysync.roles_from_profiles(self.profiles_fn())
        except Exception as e:
            log.warning("relay: no pude leer los roles de los perfiles: %s", e)
            return {}

    def _welcome(self, client, hello_id):
        end = self.clock() + WELCOME_TIMEOUT
        while not self.stop.is_set():
            if self.clock() >= end:
                raise wsclient.WSError("el relay no respondió al hello")
            msg = self._recv(client, self.tick)
            if msg is None:
                continue
            if msg.get("type") == "welcome":
                return msg
            if msg.get("type") == "error" and msg.get("re") == hello_id:
                raise wsclient.WSClosed(self._close_code(msg), "hello rechazado: %s" % msg.get("code"))
            self._handle(client, msg)
        return None

    def _await_sync(self, client):
        end = self.clock() + SYNC_WAIT
        while not self._synced and not self.stop.is_set() and self.clock() < end:
            msg = self._recv(client, self.tick)
            if msg is not None:
                self._handle(client, msg)

    def _snapshots(self, ttl):
        snap, state = self.snapshot_fn(), self.state_fn()
        if self.v == 1:
            return {None: relaysync.snapshot(snap, state, self._projects, machine_id=self.machine_id, ttl_s=ttl)}
        names = set(self._projects)
        for src in ((snap or {}).get("projects") or [], (state or {}).get("projects") or []):
            names.update(p.get("name") for p in src if isinstance(p, dict) and isinstance(p.get("name"), str))
        groups = {w: set() for w in self.workspaces}
        unmigrated = set()
        for n in names:
            wid = self.ws_map.get(n)
            (groups.setdefault(wid, set()) if wid else unmigrated).add(n)
        if unmigrated or not groups:
            groups[None] = unmigrated
        return {w: relaysync.snapshot(snap, state, self._projects, machine_id=self.machine_id, ttl_s=ttl, v=2,
                                      workspace_id=w, projects=g) for w, g in groups.items()}

    def _push_snapshots(self, client, ttl, sent, force=False):
        now = self.clock()
        for wid, snap in self._snapshots(ttl).items():
            d = _digest(snap)
            prev = sent.get(wid)
            if force or prev is None or prev[0] != d or now - prev[1] >= ttl / 2.0:
                self._send(client, snap)
                self.sent["snapshot"] += 1
                sent[wid] = (d, now)

    def _events(self, client, cursor):
        for env in events.list_after(self.conn, cursor, EVENTS_PER_TICK):
            cursor = env["seq"]
            msg = relaysync.event(env, self.machine_id, v=self.v, workspaces=self.ws_map)
            if msg is not None:
                self._send(client, msg)
                self.sent["event"] += 1
        return cursor

    def _session(self, client):
        self._projects = self._roles()
        self._hold = 0.0
        self._rx = self.clock()
        self._synced, self._offer_due, self._offered = False, False, None
        hello = relaysync.hello(self.machine_id, self._projects, events.last_seq(self.conn), v=self.v)
        self._send(client, hello)
        welcome = self._welcome(client, hello["id"])
        if welcome is None:
            return
        if self.v == 2:
            self.machine, self.rev = welcome.get("machine"), welcome.get("rev")
            self._await_sync(client)
        ttl = max(relaysync.TTL_MIN, min(relaysync.TTL_MAX, int(welcome.get("snapshot_ttl_s") or relaysync.TTL_DEFAULT)))
        ping_every = float(welcome.get("ping_interval_s") or PING_DEFAULT)
        cursor = events.last_seq(self.conn)
        sent = {}
        self._push_snapshots(client, ttl, sent, force=True)
        checked = self.clock()
        self.attempt = 0
        self.connected = True
        self.last_error = None
        log.info("relay conectado (sesión %s)", welcome.get("session_id"))
        last_events = pinged = 0.0
        while not self.stop.is_set():
            msg = self._recv(client, self.tick)
            if msg is not None:
                self._handle(client, msg)
            if self._offer_due:
                self._offer(client)
            now = self.clock()
            if now - last_events >= self.tick:
                cursor = self._events(client, cursor)
                last_events = now
            if now >= self._hold and now - checked >= SNAPSHOT_EVERY:
                checked = now
                self._push_snapshots(client, ttl, sent)
            if now - self._rx >= 3 * ping_every:
                raise wsclient.WSError("sin tráfico del relay en %ds" % int(3 * ping_every))
            if now - self._rx >= ping_every and now - pinged >= ping_every:
                self._send(client, {"v": self.v, "type": "ping", "id": envelope.new_id(), "ts": envelope.iso()})
                pinged = now
        client.close(1000, "agent stopping", wait=False)
