import hashlib
import json
import logging
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


def configured():
    try:
        url = relaycfg.relay_url()
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


class RelayLink:
    def __init__(self, url, token, machine_id, conn, snapshot_fn, state_fn, profiles_fn, stop_event,
                 clock=time.monotonic, factory=None, backoff=None, jitter=None, tick=TICK):
        self.url, self._token, self.machine_id, self.conn = url, token, machine_id, conn
        self.snapshot_fn, self.state_fn, self.profiles_fn = snapshot_fn, state_fn, profiles_fn
        self.stop, self.clock, self.tick = stop_event, clock, tick
        self.factory = factory or self._client
        self.backoff = backoff or wsclient.exponential_backoff(cap=BACKOFF_CAP)
        self.jitter = jitter or wsclient.full_jitter()
        self.attempt = 0
        self.connected = False
        self.last_error = None
        self.sent = {"snapshot": 0, "event": 0}

    def _client(self):
        headers = {"Authorization": "Bearer " + self._token, "User-Agent": USER_AGENT}
        return wsclient.WSClient(self.url, headers=headers, timeout=IO_TIMEOUT)

    def run(self):
        while not self.stop.is_set():
            client = None
            try:
                client = self.factory()
                client.connect()
                self._session(client)
            except (OSError, ValueError, wsclient.WSError) as e:
                self._down(e)
            except Exception as e:
                log.exception("relay: fallo inesperado")
                self._down(e)
            finally:
                if client is not None:
                    client.close(wait=False)
            if self.stop.is_set():
                break
            delay = max(0.0, self.jitter(self.backoff(self.attempt)))
            self.attempt += 1
            self.stop.wait(delay)
        self.connected = False

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
            self._send(client, {"v": 1, "type": "pong", "id": envelope.new_id(), "ts": envelope.iso(), "re": msg.get("id")})
        elif kind == "error":
            log.warning("relay: error %s: %s", msg.get("code"), msg.get("message"))
            retry = msg.get("retry_after_s")
            if isinstance(retry, (int, float)) and not isinstance(retry, bool):
                self._hold = self.clock() + float(retry)
            if msg.get("close"):
                raise wsclient.WSClosed(None, "el relay cierra: %s" % msg.get("code"))

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
                raise wsclient.WSError("hello rechazado: %s" % msg.get("code"))
            self._handle(client, msg)
        return None

    def _snapshot(self, ttl):
        return relaysync.snapshot(self.snapshot_fn(), self.state_fn(), self._projects, machine_id=self.machine_id, ttl_s=ttl)

    def _events(self, client, cursor):
        for env in events.list_after(self.conn, cursor, EVENTS_PER_TICK):
            cursor = env["seq"]
            msg = relaysync.event(env, self.machine_id)
            if msg is not None:
                self._send(client, msg)
                self.sent["event"] += 1
        return cursor

    def _session(self, client):
        self._projects = self._roles()
        self._hold = 0.0
        self._rx = self.clock()
        hello = relaysync.hello(self.machine_id, self._projects, events.last_seq(self.conn))
        self._send(client, hello)
        welcome = self._welcome(client, hello["id"])
        if welcome is None:
            return
        ttl = max(relaysync.TTL_MIN, min(relaysync.TTL_MAX, int(welcome.get("snapshot_ttl_s") or relaysync.TTL_DEFAULT)))
        ping_every = float(welcome.get("ping_interval_s") or PING_DEFAULT)
        cursor = events.last_seq(self.conn)
        snap = self._snapshot(ttl)
        self._send(client, snap)
        self.sent["snapshot"] += 1
        digest, snap_at, checked = _digest(snap), self.clock(), self.clock()
        self.attempt = 0
        self.connected = True
        self.last_error = None
        log.info("relay conectado (sesión %s)", welcome.get("session_id"))
        last_events = pinged = 0.0
        while not self.stop.is_set():
            msg = self._recv(client, self.tick)
            if msg is not None:
                self._handle(client, msg)
            now = self.clock()
            if now - last_events >= self.tick:
                cursor = self._events(client, cursor)
                last_events = now
            if now >= self._hold and now - checked >= SNAPSHOT_EVERY:
                checked = now
                snap = self._snapshot(ttl)
                d = _digest(snap)
                if d != digest or now - snap_at >= ttl / 2.0:
                    self._send(client, snap)
                    self.sent["snapshot"] += 1
                    digest, snap_at = d, now
            if now - self._rx >= 3 * ping_every:
                raise wsclient.WSError("sin tráfico del relay en %ds" % int(3 * ping_every))
            if now - self._rx >= ping_every and now - pinged >= ping_every:
                self._send(client, {"v": 1, "type": "ping", "id": envelope.new_id(), "ts": envelope.iso()})
                pinged = now
        client.close(1000, "agent stopping", wait=False)
