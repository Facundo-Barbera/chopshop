"""Servidor HTTP del agente (stdlib: `ThreadingHTTPServer`), autenticación y lógica de las rutas de docs/agent-api.md.

- `Authenticator`: quién es el origen de cada petición. Origen local (loopback o la propia IP de escucha) -> aceptado si
  `agent.trust_local`. Si no, según `agent.auth`:
    * `tailscale+token` (por defecto): `tailscale whois --json <ip>` (cache 60 s) -> `UserProfile.LoginName` debe ser
      `owner_login` (lectura y escritura) o estar en `allowed_logins` (solo lectura); además TODA petición (salvo `GET /health` y
      `POST /pair`) exige una credencial: la de un dispositivo emparejado (`cs1_...`, ver pairing.py) o el bearer legado;
    * `token`: basta el bearer (`token_file`, 0600, o una credencial de dispositivo), también para leer;
    * `none-local`: nada que no sea el origen local.
  Sin identidad válida -> 403; sin credencial válida -> 401. Las credenciales se comparan en tiempo constante
  (`hmac.compare_digest` o por hash); nunca se registran ni se devuelven.
- Defensas web (todas las peticiones, también el origen local): se rechaza la cabecera `Origin` y un `Host` que no sea del agente
  (anti DNS-rebinding); las escrituras exigen `Content-Type: application/json`. -> 403.
- `AgentApp`: las rutas como métodos puros (sin HTTP), para poder probarlas sin sockets.
- `AgentHTTPServer` + `Handler`: JSON UTF-8, cuerpo máximo `MAX_BODY`, timeout por conexión, errores siempre en JSON.
  Nunca se devuelven ni se registran URLs de webhook ni tokens (las suscripciones solo guardan RUTAS de archivo).
Todo lo externo es inyectable (`runner` de tailscale, reloj, módulos falsos)."""
import base64
import hmac
import ipaddress
import json
import logging
import os
import re
import socket
import socketserver
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .. import relaycfg
from . import API_VERSION, __version__, collector as collector_mod, db, envelope, events, halflife, layout, notes as notes_mod, office as office_mod, pairing as pairing_mod, projection, registry, stream, \
    structure as structure_mod, t3watch, webhooks

log = logging.getLogger("chopshop.agent")

AUTH_MODES = ("tailscale+token", "token", "none-local")
MAX_BODY = 64 * 1024              # bytes de cuerpo aceptados en POST/DELETE
CONN_TIMEOUT = 15                 # s de inactividad de una conexión (lectura de la petición)
WHOIS_TTL = 60.0                  # s de cache de identidades de Tailscale
WHOIS_FAIL_TTL = 5.0              # s de cache de un whois fallido (evita martillar al CLI)
WHOIS_MAX = 256                   # entradas máximas del cache
SNAPSHOT_EVENTS = 80
SNAPSHOT_THREADS = 200
ORCHESTRATOR_TTL = 5.0            # s de cache del snapshot del orquestador
_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
RUNTIME_MODES = ("approval-required", "auto-accept-edits", "auto", "full-access")
SEND_MODES = ("auto", "queue", "steer", "restart")
MAX_MESSAGE = 60000
PUBLIC = {("GET", "/health"), ("POST", "/pair")}       # sin credencial (pero sí con identidad de Tailscale en ese modo)
LINK_NONCE_HEADER = "X-Chopshop-Link-Nonce"
LINK_KEYS = ("api_url", "machine_id", "local_machine_id", "credential")


class ApiError(Exception):
    """Error de la API con su código HTTP; el mensaje llega al cliente."""

    def __init__(self, status, message, extra=None):
        super().__init__(message)
        self.status, self.message, self.extra = status, message, extra     # extra: campos añadidos a la respuesta


# ---------------------------------------------------------------- autenticación

def default_runner(argv, timeout=3):
    """Ejecuta argv SIN shell -> (rc, stdout, stderr). Un fallo al lanzar es rc=127 (sin mensajes que arrastren datos)."""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", type(e).__name__
    return p.returncode, p.stdout, p.stderr


def parse_ip(text):
    """str -> ipaddress (IPv4-mapped IPv6 se normaliza a IPv4; se ignora el scope `%eth0`) o None."""
    try:
        ip = ipaddress.ip_address(str(text).split("%")[0])
    except ValueError:
        return None
    return ip.ipv4_mapped if getattr(ip, "ipv4_mapped", None) else ip


class Identity:
    """Quién hace la petición: `via` = local | tailscale | token; `write` = podría escribir (credencial ya verificada);
    `device` = id del dispositivo emparejado cuya credencial se usó (o None); `ip` = origen."""
    __slots__ = ("via", "login", "write", "device", "ip")

    def __init__(self, via, login=None, write=False, device=None, ip=None):
        self.via, self.login, self.write, self.device, self.ip = via, login, write, device, ip

    def public(self):
        out = {"login": self.login, "via": self.via, "write": self.write}
        if self.device:
            out["device"] = self.device
        return out


class Authenticator:
    def __init__(self, cfg, runner=None, clock=time.monotonic, pairing=None):
        self.mode = cfg.get("auth") or "tailscale+token"
        if self.mode not in AUTH_MODES:
            raise ValueError("agent.auth debe ser uno de %s (es %r)" % (", ".join(AUTH_MODES), self.mode))
        self.trust_local = bool(cfg.get("trust_local", True))
        self.owner = (cfg.get("owner_login") or "").strip().lower()
        self.allowed = {str(x).strip().lower() for x in (cfg.get("allowed_logins") or []) if str(x).strip()}
        self.token_file = os.path.expanduser(cfg.get("token_file") or "")
        self.tailscale_bin = cfg.get("tailscale_bin") or "tailscale"
        self.runner = runner or default_runner
        self.clock = clock
        self._lock = threading.Lock()
        self._whois = {}              # ip(str) -> (vence, login | None)
        self._tok = (None, None)      # ((mtime, size), token | None)
        self._warned = False
        self.pairing = pairing            # pairing.Pairing (credenciales de dispositivo) o None
        mid = (cfg.get("machine_id") or socket.gethostname()).strip().lower()
        hn = socket.gethostname().strip().lower()
        self.host_names = {"localhost", mid, hn, hn.split(".")[0]} | {
            str(h).strip().lower() for h in (cfg.get("allowed_hosts") or []) if str(h).strip()}
        self.host_names.discard("")

    # -- bearer
    def _token(self):
        try:
            st = os.stat(self.token_file)
        except OSError:
            return None
        key = (st.st_mtime, st.st_size)
        with self._lock:
            if self._tok[0] == key:
                return self._tok[1]
        try:
            with open(self.token_file, encoding="utf-8") as f:
                tok = f.read().strip() or None
        except OSError:
            tok = None
        if st.st_mode & 0o077 and not self._warned:
            self._warned = True
            log.warning("el archivo de token es legible por otros usuarios: chmod 600 %s", self.token_file)
        with self._lock:
            self._tok = (key, tok)
        return tok

    def bearer_ok(self, header):
        if not header:
            return False
        scheme, _, value = header.strip().partition(" ")
        value = value.strip()
        tok = self._token()
        if scheme.lower() != "bearer" or not value or not tok:
            return False
        return hmac.compare_digest(value.encode("utf-8"), tok.encode("utf-8"))

    # -- Tailscale
    def whois(self, ip_text):
        """LoginName de Tailscale para esa IP (con cache) o None. Nunca lanza."""
        now = self.clock()
        with self._lock:
            hit = self._whois.get(ip_text)
            if hit and hit[0] > now:
                return hit[1]
        login = self._whois_uncached(ip_text)
        with self._lock:
            if len(self._whois) >= WHOIS_MAX:
                self._whois = {k: v for k, v in self._whois.items() if v[0] > now}
                if len(self._whois) >= WHOIS_MAX:
                    self._whois.clear()
            self._whois[ip_text] = (now + (WHOIS_TTL if login else WHOIS_FAIL_TTL), login)
        return login

    def _whois_uncached(self, ip_text):
        try:
            rc, out, _ = self.runner([self.tailscale_bin, "whois", "--json", ip_text])
            if rc != 0:
                return None
            login = ((json.loads(out) or {}).get("UserProfile") or {}).get("LoginName")
        except Exception:  # noqa: BLE001 - un whois roto equivale a "sin identidad"
            return None
        return login.strip().lower() if isinstance(login, str) and login.strip() else None

    def credential(self, header, ip=None):
        """(ok, device_id): bearer legado (`token_file`) -> (True, None); credencial de dispositivo vigente -> (True, id)."""
        if not header:
            return False, None
        scheme, _, value = header.strip().partition(" ")
        value = value.strip()
        if scheme.lower() == "bearer" and value.startswith(pairing_mod.CRED_PREFIX) and self.pairing is not None:
            dev = self.pairing.check(value, ip)
            return dev is not None, dev
        return self.bearer_ok(header), None

    def device_active(self, device_id):
        return self.pairing is not None and self.pairing.active(device_id)

    # -- defensas web
    def host_ok(self, host, local_addrs):
        """`Host` es una IP del agente (o loopback), su nombre (`localhost`, machine_id, hostname) o uno de `allowed_hosts`
        (p. ej. el nombre MagicDNS completo). Anti DNS-rebinding: un dominio ajeno que resuelva a nuestra IP no pasa."""
        h = (host or "").strip().lower()
        if not h:
            return False
        if h.startswith("["):
            h = h[1:].split("]")[0]
        elif h.count(":") == 1:
            h = h.split(":")[0]
        h = h.rstrip(".")
        ip = parse_ip(h)
        if ip is not None:
            return ip.is_loopback or str(ip) in local_addrs
        return h in self.host_names

    def check_web(self, headers, local_addrs):
        """ApiError(403) si la petición parece de un navegador (`Origin`) o va a un Host ajeno."""
        if headers.get("Origin") is not None:
            raise ApiError(403, "no se aceptan peticiones con cabecera Origin (navegadores)")
        if not self.host_ok(headers.get("Host"), local_addrs):
            raise ApiError(403, "Host no reconocido")

    @staticmethod
    def check_json(method, headers, has_body):
        """Escrituras (POST/PUT, o DELETE con cuerpo): `Content-Type: application/json` o ApiError(403)."""
        if method != "GET" and (method in ("POST", "PUT") or has_body):
            ctype = (headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                raise ApiError(403, "las escrituras exigen Content-Type: application/json")

    # -- decisión
    def authorize(self, peer, local_addrs, write, auth_header, method=None, path=None):
        """Identity del origen o ApiError (403 identidad/permiso, 401 credencial). `peer` = IP del cliente (str);
        `local_addrs` = IPs propias del servidor; `method`/`path` deciden si la ruta es pública (`PUBLIC`)."""
        ip = parse_ip(peer)
        if ip is None:
            raise ApiError(403, "sin identidad válida")
        if self.trust_local and (ip.is_loopback or str(ip) in local_addrs):
            return Identity("local", None, True, ip=str(ip))
        if self.mode == "none-local":
            raise ApiError(403, "solo se acepta el origen local")
        cred, device = self.credential(auth_header, str(ip))
        if self.mode == "token":
            if not cred:
                raise ApiError(403, "sin identidad válida: falta un bearer correcto")
            return Identity("token", None, True, device, str(ip))
        login = self.whois(str(ip))
        owner = bool(login) and login == self.owner
        if not login or not (owner or login in self.allowed):
            raise ApiError(403, "sin identidad válida")
        if (method, path) not in PUBLIC:
            if not cred:
                raise ApiError(401, "falta una credencial válida: empareja este dispositivo (`chopshop pair create` + POST /pair)")
            if write and not owner:
                raise ApiError(403, "esta identidad es de solo lectura")
        return Identity("tailscale", login, owner and cred, device, str(ip))


def link_nonce_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "chopshop", "agent", "link.nonce")


class LinkNonce:
    def __init__(self, path=None):
        self.path = path or link_nonce_path()
        self.lock = threading.Lock()
        self._value = None

    def rotate(self):
        value = base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode("ascii")
        self._value = None
        try:
            relaycfg._write_private(self.path, value)
        except OSError as e:
            log.warning("no pude escribir el nonce de enlace en %s (%s)", self.path, e.strerror or type(e).__name__)
            return False
        self._value = value
        return True

    def verify(self, header):
        value = self._value
        if not value or not header or not hmac.compare_digest(header.strip().encode("utf-8"), value.encode("utf-8")):
            raise ApiError(401, "nonce de enlace inválido")


def local_guard(listen_host, port, peer, headers):
    listen, ip = parse_ip(listen_host), parse_ip(peer)
    if listen is None or ip is None or not listen.is_loopback or not ip.is_loopback:
        raise ApiError(404, "ruta desconocida")
    if headers.get("Origin") is not None:
        raise ApiError(403, "no se aceptan peticiones con cabecera Origin (navegadores)")
    if (headers.get("Host") or "").strip().lower() not in {"127.0.0.1:%d" % port, "localhost:%d" % port, "[::1]:%d" % port}:
        raise ApiError(403, "Host no reconocido")


# ---------------------------------------------------------------- estado en ejecución

class Runtime:
    """Estado vivo compartido entre el servicio (hilos de fondo) y la API (`/snapshot`, `/health`)."""

    def __init__(self, clock=time.time):
        self.clock = clock
        self.started = clock()
        self.last_poll = None         # ts del último sondeo de T3 que llegó a ejecutarse
        self.errors = {}              # hilo -> último error (texto corto)
        self._logged = {}             # hilo -> (mensaje, ts) para no repetir el mismo aviso

    def ok(self, name):
        self.errors.pop(name, None)

    def fail(self, name, exc):
        """Registra el fallo; True si conviene escribirlo en el log (cambia el mensaje o pasó más de un minuto)."""
        msg = ("%s: %s" % (type(exc).__name__, exc))[:200]
        self.errors[name] = msg
        last = self._logged.get(name)
        now = self.clock()
        if last and last[0] == msg and now - last[1] < 60:
            return False
        self._logged[name] = (msg, now)
        return True


# ---------------------------------------------------------------- lógica de las rutas

def _num(q, key, default=None, minimum=None):
    raw = q.get(key)
    if raw in (None, ""):
        return default
    try:
        v = float(raw)
    except ValueError:
        raise ApiError(400, "%s debe ser numérico" % key)
    if v != v or v in (float("inf"), float("-inf")) or (minimum is not None and v < minimum):
        raise ApiError(400, "%s fuera de rango" % key)
    return v


def _int(q, key, default, minimum=0):
    v = _num(q, key, default, minimum)
    return int(v)


def _text(body, key, required=False, maxlen=256):
    v = body.get(key)
    if v is None or v == "":
        if required:
            raise ApiError(400, "%s es obligatorio" % key)
        return None
    if not isinstance(v, str) or len(v) > maxlen or any(ord(c) < 32 for c in v):
        raise ApiError(400, "%s debe ser texto (máx. %d caracteres, sin controles)" % (key, maxlen))
    return v


def _ident(body, key, required=False):
    v = _text(body, key, required, 128)
    if v is not None and not _ID.match(v):
        raise ApiError(400, "%s tiene caracteres no permitidos" % key)
    return v


class AgentApp:
    """Cada ruta es un método `(ident, query, body, **path) -> objeto | (código, objeto)`."""

    ROUTES = {
        ("GET", "/health"): "health", ("GET", "/snapshot"): "snapshot", ("GET", "/metrics"): "metrics",
        ("GET", "/events"): "events", ("GET", "/threads"): "threads",
        ("GET", "/subscriptions"): "subscriptions", ("POST", "/answer"): "answer", ("POST", "/settle"): "settle",
        ("POST", "/subscriptions"): "subscribe", ("POST", "/touch"): "touch",
        ("GET", "/state"): "state", ("GET", "/stream"): "stream", ("POST", "/pair"): "pair",
        ("GET", "/t3/projects"): "t3_projects", ("GET", "/thread"): "thread_read", ("POST", "/threads"): "thread_launch",
        ("POST", "/threads/send"): "thread_send", ("POST", "/threads/interrupt"): "thread_interrupt",
        ("GET", "/projects"): "projects", ("POST", "/projects"): "project_register",
        ("POST", "/queue/cancel"): "queue_cancel",
        ("GET", "/local/relay/status"): "relay_status", ("POST", "/local/relay/link"): "relay_link",
        ("POST", "/local/relay/unlink"): "relay_unlink",
    }

    def __init__(self, cfg, conn, collector, t3, auth, runtime=None, emit_fn=None, orchestrator_fn=None,
                 clock=time.time, pairing=None, stream_opts=None, office=None):
        self.cfg, self.conn = cfg, conn
        self.office = office              # agent/office.py (None = sin oficina: las rutas /desks dan 503)
        self.queue = None                 # chopshop/queue.py (la pone el servicio; None = /queue/cancel da 503)
        self.collector, self.t3, self.auth = collector, t3, auth
        self.runtime = runtime or Runtime(clock)
        self.clock = clock
        self.machine_id = cfg.get("machine_id") or socket.gethostname()
        self.emit_fn = emit_fn
        self.orchestrator_fn = orchestrator_fn if orchestrator_fn is not None else _engine_snapshot
        self._orch = (0.0, None)
        self._orch_lock = threading.Lock()
        self.t3_enabled = bool(cfg.get("t3_enabled", True))
        self.pairing = pairing if pairing is not None else getattr(auth, "pairing", None)
        self.projector = projection.Projector(conn, dict(cfg, machine_id=self.machine_id))
        self.stream = stream.StreamHub(conn, dict(cfg, machine_id=self.machine_id), self.projector,
                                       device_active=getattr(auth, "device_active", None), **(stream_opts or {}))
        self.listen_ips = set()           # IPs de todos los listeners (las rellena el servicio; para validar Host)
        self.desk_fn = notes_mod.declared_desk   # id de escritorio -> escritorio del perfil local o None (inyectable)
        self.link_nonce = LinkNonce()
        self.relay_fn = lambda: None
        self.relay_reload = None

    # -- enrutado
    def match(self, method, path):
        """(nombre del método, parámetros de ruta) o ApiError 404/405."""
        name = self.ROUTES.get((method, path))
        if name:
            return name, {}
        if path.startswith("/subscriptions/") and len(path) > len("/subscriptions/"):
            if method == "DELETE":
                return "unsubscribe", {"name": urllib.parse.unquote(path[len("/subscriptions/"):])}
            raise ApiError(405, "método no permitido")
        if path.startswith("/desks/") and path.endswith("/notes") and len(path) > len("/desks//notes"):
            if method == "POST":
                return "desk_note", {"desk": urllib.parse.unquote(path[len("/desks/"):-len("/notes")])}
            raise ApiError(405, "método no permitido")
        if path.startswith("/desks/"):
            rest = urllib.parse.unquote(path[len("/desks/"):])
            if layout.parse_desk_id(rest):
                if method == "GET":
                    return "desk", {"desk_id": rest}
                raise ApiError(405, "método no permitido")
            head, _, action = rest.rpartition("/")
            if action == "assign" and layout.parse_desk_id(head):
                if method == "POST":
                    return "desk_assign", {"desk_id": head}
                raise ApiError(405, "método no permitido")
        if path.startswith("/projects/") and path.endswith("/disable") and len(path) > len("/projects//disable"):
            if method == "POST":
                return "project_disable", {"name": urllib.parse.unquote(path[len("/projects/"):-len("/disable")])}
            raise ApiError(405, "método no permitido")
        if path.startswith("/office/") and len(path) > len("/office/"):
            if method in ("GET", "PUT"):
                return ("office_put" if method == "PUT" else "office_get"), {"project": urllib.parse.unquote(path[len("/office/"):])}
            raise ApiError(405, "método no permitido")
        if any(p == path for (_m, p) in self.ROUTES):
            raise ApiError(405, "método no permitido")
        raise ApiError(404, "ruta desconocida")

    def call(self, method, path, ident, query=None, body=None):
        name, params = self.match(method, path)
        out = getattr(self, "r_" + name)(ident, query or {}, body or {}, **params)
        return out if isinstance(out, tuple) else (200, out)

    # -- lectura
    def r_health(self, ident, q, body):
        now = self.clock()
        return {"ok": True, "api_version": API_VERSION, "version": __version__, "machine_id": self.machine_id,
                "ts": now, "uptime": int(now - self.runtime.started), "whoami": ident.public()}

    def r_metrics(self, ident, q, body):
        to = _num(q, "to", self.clock())
        frm = _num(q, "from", to - 3600)
        group = q.get("group") or "machine"
        try:
            return collector_mod.query(self.conn, frm, to, group, _num(q, "step", None), q.get("name") or None)
        except collector_mod.CollectorError as e:
            raise ApiError(400, str(e))

    def r_events(self, ident, q, body):
        after = _int(q, "after", 0)
        evs = events.list_after(self.conn, after, _int(q, "limit", 200, 1))
        return {"events": evs, "last_seq": evs[-1]["seq"] if evs else after, "head_seq": events.last_seq(self.conn)}

    def r_threads(self, ident, q, body):
        sql, args = "SELECT * FROM t3_threads", []
        if q.get("project"):
            sql += " WHERE project=?"
            args.append(q["project"])
        sql += " ORDER BY updated DESC LIMIT ?"
        args.append(_int(q, "limit", 500, 1))
        with db.tx():
            rows = db.rows(self.conn.execute(sql, args))
        return {"threads": [_thread(r) for r in rows]}

    def r_state(self, ident, q, body):
        st = self.projector.current()
        return projection.filter_project(st, q["project"]) if q.get("project") else st

    def r_stream(self, ident, q, body):
        raise ApiError(400, "/stream solo se sirve por HTTP (text/event-stream)")

    def r_pair(self, ident, q, body):
        if self.pairing is None:
            raise ApiError(503, "emparejamiento no disponible en este agente")
        try:
            res = self.pairing.redeem(body.get("code"), body.get("device_name"), body.get("device_id"), ident.ip or "")
        except pairing_mod.PairError as e:
            log.warning("emparejamiento rechazado desde %s (%s)", ident.ip, e.status)
            raise ApiError(e.status, e.message)
        log.info("dispositivo %s emparejado desde %s (%s)", res["device_id"], ident.ip, ident.login or ident.via)
        return dict(res, api_version=projection.API_VERSION)

    def r_subscriptions(self, ident, q, body):
        return {"subscriptions": events.list_subscriptions(self.conn)}

    # -- snapshot
    def _orchestrator(self):
        now = time.monotonic()
        with self._orch_lock:
            if now - self._orch[0] < ORCHESTRATOR_TTL and self._orch[1] is not None:
                return self._orch[1]
        try:
            snap = self.orchestrator_fn()
        except Exception:  # noqa: BLE001 - el orquestador es opcional: sin él, null
            snap = None
        with self._orch_lock:
            self._orch = (now, snap)
        return snap

    def _thread_rows(self):
        act = ",".join("'%s'" % s for s in sorted(t3watch.ACTIVE))
        with db.tx():
            rows = db.rows(self.conn.execute(
                "SELECT * FROM t3_threads ORDER BY CASE WHEN status IN (%s) OR pending NOT IN ('[]','') THEN 0 ELSE 1 END,"
                " updated DESC LIMIT ?" % act, (SNAPSHOT_THREADS,)))
            pend = db.rows(self.conn.execute("SELECT * FROM t3_threads WHERE pending NOT IN ('[]','') ORDER BY updated DESC"))
        return [_thread(r) for r in rows], [_thread(r) for r in pend]

    def r_snapshot(self, ident, q, body):
        now = self.clock()
        latest = self.collector.latest()
        threads, with_pending = self._thread_rows()
        st = self.projector.current()
        projects = {p["name"]: dict(p) for p in latest.get("projects", [])}
        names = {t["project"] for t in threads if t["project"]} | set((self.cfg.get("projects") or {}))
        for n in names:
            projects.setdefault(n, {"name": n, "cpu_pct": 0.0, "rss_mb": 0.0, "procs": 0, "cgroups": []})
        for p in projects.values():
            mine = [t for t in threads if t["project"] == p["name"]]
            p["threads_running"] = sum(1 for t in mine if t["status"] in ("running", "starting"))
            p["threads_pending"] = sum(len(t["pending"]) for t in mine)
        t3_ok = self.t3.reachable if self.t3_enabled else None
        last_ts = getattr(self.collector, "last_ts", None)
        poll = self.runtime.last_poll
        agent = {"version": __version__, "uptime": int(now - self.runtime.started), "t3_ok": t3_ok,
                 "last_sample_age": round(now - last_ts, 1) if last_ts else None,
                 "last_poll_age": round(now - poll, 1) if poll else None}
        if self.runtime.errors:
            agent["errors"] = dict(self.runtime.errors)
        return {
            "api_version": API_VERSION, "machine_id": self.machine_id, "ts": now,
            "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
            "machine": latest.get("machine", {}), "apps": latest.get("apps", []),
            "projects": sorted(projects.values(), key=lambda p: (-p["cpu_pct"], p["name"])),
            "threads": threads,
            "pending_questions": [{"thread_id": t["thread_id"], "project": t["project"], "request_id": r.get("request_id"),
                                   "questions": r.get("questions", [])} for t in with_pending for r in t["pending"]],
            "events": events.recent(self.conn, SNAPSHOT_EVENTS),
            "subscriptions": {n: {"project": s["project"], "events": s["events"]}
                              for n, s in events.list_subscriptions(self.conn).items()},
            "orchestrator": self._orchestrator(),
            "agent": agent,
            "employees": st.get("employees") or [], "queues": st.get("queues") or {},
        }

    # -- T3
    def _t3(self, fn, *args):
        if not self.t3_enabled:
            raise ApiError(503, "T3 desactivado en este agente (agent.t3_enabled = false)")
        try:
            return fn(self.t3, *args)
        except t3watch.AnswerError as e:
            raise ApiError(400, str(e))
        except t3watch.T3Error as e:
            raise ApiError(502, "T3: %s" % e)

    def r_answer(self, ident, q, body):
        choice = body.get("choice")
        if isinstance(choice, dict):
            ok = bool(choice) and all(isinstance(k, str) and isinstance(v, (str, int)) for k, v in choice.items())
        else:
            ok = isinstance(choice, (str, int)) and not isinstance(choice, bool) and str(choice).strip() != ""
        if not ok:
            raise ApiError(400, "choice debe ser texto o un objeto {id_pregunta: elección}")
        thread = _ident(body, "thread_id", True)
        by = _text(body, "by", False, 64)
        res = self._t3(t3watch.answer, thread, choice if isinstance(choice, dict) else str(choice), _text(body, "request", False, 128))
        log.info("respuesta enviada al hilo %s por %s", thread, ident.login or ident.via)
        self._answered(thread, res, by or ident.login or "human")
        halflife.touch(self.conn, thread, self.clock())      # responder también reinicia la semivida
        return dict(res, ok=True)

    def _answered(self, thread, res, by):
        """Emite `question.answered` (needs: null) tras responder; un fallo aquí no deshace la respuesta."""
        if not self.emit_fn:
            return
        try:
            rid = res.get("request_id")
            with db.tx():
                row = self.conn.execute("SELECT project, title FROM t3_threads WHERE thread_id=?", (thread,)).fetchone()
                opened = self.conn.execute("SELECT ts, body FROM events WHERE type='question.opened' AND subject_id=?"
                                           " ORDER BY seq DESC LIMIT 20", (thread,)).fetchall()
            since = next((r["ts"] for r in opened if (db.jload(r["body"], {}) or {}).get("request_id") == rid), None)
            vals = list((res.get("answers") or {}).values())
            choice = vals[0] if len(vals) == 1 else vals
            self.emit_fn("question.answered", row["project"] if row else None,
                         {"thread_id": thread, "request_id": rid, "choice": choice, "by": by,
                          "latency_s": round(time.time() - since) if since else None, "title": row["title"] if row else None})
        except Exception:  # noqa: BLE001
            log.exception("no pude registrar question.answered de %s", thread)

    def r_settle(self, ident, q, body):
        thread = _ident(body, "thread_id", True)
        self._t3(t3watch.settle, thread)
        log.info("hilo %s settled por %s", thread, ident.login or ident.via)
        return {"ok": True, "thread_id": thread}

    def r_t3_projects(self, ident, q, body):
        projects = self._t3(lambda t3: t3.projects())
        return {"projects": [{"id": p.get("id"), "title": p.get("title"), "workspace_root": p.get("workspaceRoot")}
                             for p in projects]}

    def _project_id(self, name):
        conf = (self.cfg.get("projects") or {}).get(name) or {}
        if conf.get("t3_project_id"):
            return conf["t3_project_id"]
        for p in self._t3(lambda t3: t3.projects()):
            root = (p.get("workspaceRoot") or "").rstrip("/")
            if name in (p.get("id"), p.get("title")) or (root and os.path.basename(root) == name):
                return p.get("id")
        raise ApiError(404, f"proyecto desconocido en el T3 de esta máquina: {name}")

    def r_thread_read(self, ident, q, body):
        thread = _ident(q, "thread_id", True)
        args = {"threadId": thread, "limit": _int(q, "limit", 10, 1), "maxCharsPerItem": _int(q, "chars", 2000, 1)}
        if q.get("view") in ("messages", "activity"):
            args["view"] = q["view"]
        return self._t3(lambda t3: t3.call("t3_thread_read", args))

    def r_thread_launch(self, ident, q, body):
        title = _text(body, "title", True, 120)
        args = {"title": title, "runtimeMode": _text(body, "runtime_mode", False, 32) or "approval-required"}
        if args["runtimeMode"] not in RUNTIME_MODES:
            raise ApiError(400, f"runtime_mode debe ser uno de {', '.join(RUNTIME_MODES)}")
        message = _text(body, "message", False, MAX_MESSAGE)
        if message:
            args["message"] = message
        project = _text(body, "project", False, 128)
        if project:
            args["projectId"] = self._project_id(project)
            branch = _text(body, "branch", False, 200)
            if branch:
                args["workspaceStrategy"] = {"type": "worktree", "branch": branch,
                                             "baseRef": _text(body, "base_ref", False, 200) or "main"}
        else:
            args["scratch"] = True
        model = _text(body, "model", False, 200)
        if model:
            inst, _, name = model.partition("/")
            args["modelSelection"] = {"instanceId": inst, "model": name} if name else {"model": inst}
        if body.get("interaction_mode") in ("default", "plan"):
            args["interactionMode"] = body["interaction_mode"]
        rid = _ident(body, "client_request_id")
        if rid:
            args["clientRequestId"] = rid
        res = self._t3(lambda t3: t3.call("t3_thread_launch", args))
        log.info("hilo lanzado en %s por %s", project or "scratch", ident.login or ident.via)
        return dict(res if isinstance(res, dict) else {"result": res}, ok=True)

    def r_thread_send(self, ident, q, body):
        thread = _ident(body, "thread_id", True)
        mode = _text(body, "mode", False, 16) or "auto"
        if mode not in SEND_MODES:
            raise ApiError(400, f"mode debe ser uno de {', '.join(SEND_MODES)}")
        args = {"threadId": thread, "message": _text(body, "message", True, MAX_MESSAGE), "mode": mode}
        res = self._t3(lambda t3: t3.call("t3_thread_send", args))
        log.info("mensaje (%s) al hilo %s por %s", mode, thread, ident.login or ident.via)
        halflife.touch(self.conn, thread, self.clock())
        return dict(res if isinstance(res, dict) else {"result": res}, ok=True, thread_id=thread)

    def r_thread_interrupt(self, ident, q, body):
        thread = _ident(body, "thread_id", True)
        args = {"threadId": thread, "reason": _text(body, "reason", False, 2000) or "chopshop"}
        res = self._t3(lambda t3: t3.call("t3_thread_interrupt", args))
        log.info("hilo %s interrumpido por %s", thread, ident.login or ident.via)
        return dict(res if isinstance(res, dict) else {"result": res}, ok=True, thread_id=thread)

    # -- oficina (api_version 3)
    def _office(self):
        if self.office is None:
            raise ApiError(503, "oficina no disponible en este agente")
        return self.office

    def r_desk(self, ident, q, body, desk_id):
        d = self._office().desk(desk_id)
        if d is None:
            raise ApiError(404, "escritorio desconocido")
        return d

    def r_desk_assign(self, ident, q, body, desk_id):
        thread = _ident(body, "thread_id", True)
        try:
            self._office().assign(desk_id, thread)
        except office_mod.OfficeError as e:
            raise ApiError(e.status, e.message)
        log.info("hilo %s asignado a %s por %s", thread, desk_id, ident.login or ident.via)
        return {"ok": True, "desk": desk_id, "thread_id": thread}

    # -- colas de empleados
    def r_queue_cancel(self, ident, q, body):
        """Cancela una tarea en la cola de un empleado -> `task.cancelled` + `queue.changed`."""
        if self.queue is None:
            raise ApiError(503, "cola no disponible en este agente")
        emp, task = _text(body, "employee", True, 128), _ident(body, "task", True)
        by, note = _text(body, "by", maxlen=64) or "human", _text(body, "note", maxlen=500)
        cur = self.queue.get(task)
        if cur is None or cur["employee"] != emp or cur["state"] != "queued":
            raise ApiError(404, "no hay tarea %s en la cola de %s" % (task, emp))
        if self.queue.cancel(task, by, note=note) is None:
            raise ApiError(404, "la tarea %s ya no está en cola" % task)
        log.info("tarea %s de %s cancelada por %s", task, emp, ident.login or ident.via)
        return {"ok": True, "task": task, "employee": emp, "state": "cancelled", "queue_len": self.queue.length(emp)}

    # -- semivida
    def r_touch(self, ident, q, body):
        """Reinicia el reloj de semivida del hilo y reemite su último `task.state` con `touched_at` (misma atención)."""
        thread = _ident(body, "thread_id", True)
        now = halflife.touch(self.conn, thread, self.clock())
        try:
            self._retouch(thread, envelope.iso(now))
        except Exception:  # noqa: BLE001 - el toque ya quedó guardado; el temporizador lo respeta igual
            log.exception("no pude reemitir task.state de %s tras tocarlo", thread)
        return {"ok": True, "thread_id": thread, "touched_at": envelope.iso(now)}

    def _retouch(self, thread, touched):
        st = self.projector.current()
        for p in st["projects"]:
            for t in p["tasks"]:
                if t.get("thread_id") != thread:
                    continue
                b = {k: v for k, v in t.items() if k not in ("id", "severity", "seq", "updated")}
                b["touched_at"] = touched
                env = events.emit_envelope(self.conn, self.cfg, "task.state", p["name"], b,
                                           subject=envelope.subject("task", t["id"], t.get("title"), t.get("link")),
                                           severity=t.get("severity"), needs=envelope.needs_for_attention(t.get("attention")))
                if env:
                    self.stream.bus.publish(env["seq"])

    # -- escritorios
    def r_desk_note(self, ident, q, body, desk):
        """Nota de un bot en la bandeja de un escritorio -> `desk.note` (la consume el hilo que despierta allí)."""
        d = self.desk_fn(desk)
        if d is None:
            raise ApiError(404, "escritorio desconocido (no lo declara el perfil de su proyecto)")
        frm = body.get("from") if body.get("from") not in (None, "") else (ident.login or ident.device or ident.via)
        try:
            note = notes_mod.add(self.conn, d["id"], frm, body.get("text"), body.get("ttl_s"), self.clock())
        except notes_mod.NoteError as e:
            raise ApiError(400, str(e))
        n = notes_mod.count(self.conn, d["id"], self.clock())
        log.info("nota %s en el escritorio %s de %s", note["id"], d["id"], ident.login or ident.via)
        if self.emit_fn:
            self.emit_fn("desk.note", d["project"], notes_mod.body(note, n))
        occ = ((self.office.desk(d["id"]) if self.office is not None else None) or {}).get("occupant")
        if occ:                                       # dejar nota cuenta como tocar al ocupante (semivida)
            now = halflife.touch(self.conn, occ["thread_id"], self.clock())
            try:
                self._retouch(occ["thread_id"], envelope.iso(now))
            except Exception:  # noqa: BLE001 - el toque ya quedó guardado
                log.exception("no pude reemitir task.state de %s tras la nota", occ["thread_id"])
        return {"ok": True, "note_id": note["id"], "pending": n}

    # -- suscripciones
    def r_subscribe(self, ident, q, body):
        name, wfile = _text(body, "name", True, 64), _text(body, "webhook_file", True, 1024)
        if not os.path.isfile(os.path.expanduser(wfile)):
            raise ApiError(400, "webhook_file no existe o no es un archivo (en esta máquina)")
        opts = {k: body[k] for k in webhooks.FIELDS if body.get(k) is not None}
        if body.get("batch_window_s"):
            opts["batch_window_s"] = body["batch_window_s"]
        sfile = opts.get("secret_file")
        if sfile is not None:
            if not isinstance(sfile, str) or not os.path.isfile(os.path.expanduser(sfile)):
                raise ApiError(400, "secret_file no existe o no es un archivo (en esta máquina)")
            if os.stat(os.path.expanduser(sfile)).st_mode & 0o077:
                raise ApiError(400, "secret_file es legible por otros: chmod 600")
        hfile = opts.get("headers_file")
        if hfile is not None:
            if not isinstance(hfile, str) or not os.path.isfile(os.path.expanduser(hfile)):
                raise ApiError(400, "headers_file no existe o no es un archivo (en esta máquina)")
            try:
                webhooks.read_headers(hfile)
            except PermissionError:
                raise ApiError(400, "headers_file es legible por otros: chmod 600")
            except (OSError, ValueError) as e:
                raise ApiError(400, "headers_file inválido: %s" % (e if isinstance(e, ValueError) else type(e).__name__))
        try:
            events.subscribe(self.conn, name, wfile, _text(body, "project", False, 128) or "*", body.get("events"), **opts)
        except events.EventsError as e:
            raise ApiError(400, str(e))
        return {"ok": True, "name": name, "subscription": events.list_subscriptions(self.conn).get(name)}

    def r_unsubscribe(self, ident, q, body, name):
        if not events.unsubscribe(self.conn, name):
            raise ApiError(404, "suscripción desconocida")
        return {"ok": True, "name": name}

    def r_projects(self, ident, q, body):
        return _registry(registry.api_list)

    def r_project_register(self, ident, q, body):
        return _registry(registry.api_register, body)

    def r_project_disable(self, ident, q, body, name):
        return _registry(registry.api_disable, name)

    # -- estructura de la oficina (bots; docs/agent-api.md «api_version 3»)
    def r_office_get(self, ident, q, body, project):
        try:
            return structure_mod.read(self.conn, project)
        except structure_mod.StructureError as e:
            raise ApiError(e.status, e.message, {"problems": e.problems} if e.problems else None)

    def r_office_put(self, ident, q, body, project):
        _registry(registry.guard_local, project)
        by = _text(body, "by", True, 64)
        base = _text(body, "base_rev", False, 64)
        react = body.get("reactivate") or []
        if not isinstance(react, list) or not all(isinstance(x, str) for x in react):
            raise ApiError(400, "reactivate debe ser una lista de ids de escritorio")
        if "office" not in body:
            raise ApiError(400, "office es obligatorio")
        if self.office is not None and layout.parse_desk_id(project + "/0/x/0"):  # nombre sin `/` (si no, 400 de structure)
            self.office.sync_project(project)               # la oficina conoce la estructura previa (no-op si ya estaba al día)
        try:
            res = structure_mod.apply(self.conn, project, body.get("office"), body.get("rack"), by, base, react)
        except structure_mod.StructureError as e:
            raise ApiError(e.status, e.message, {"problems": e.problems} if e.problems else None)
        seq = None
        if res["changed"] and self.office is not None:   # la oficina sincroniza su tabla `desks` y emite `office.changed {by}`
            env = self.office.sync_project(project, by=by)
            seq = (env or {}).get("seq")
        elif res["changed"] and self.emit_fn:
            seq = self.emit_fn("office.changed", project, structure_mod.changed_body(res))
        log.info("oficina de %s %s por %s (%s)", project, "reescrita" if res["changed"] else "sin cambios", by,
                 ident.login or ident.via)
        return {"ok": True, "project": project, "rev": res["rev"], "changed": res["changed"], "seq": seq,
                "office": res["structure"], "diff": res["diff"]}

    def r_relay_status(self, ident, q, body):
        out = {"local_machine_id": self.machine_id, "linked": False, "api_url": None, "machine_id": None,
               "connected": False, "last_error": None}
        try:
            m = relaycfg.read_machine()
        except relaycfg.RelayCfgError as e:
            m, out["last_error"] = None, str(e)
        if m:
            out.update(linked=True, api_url=m["api_url"], machine_id=m["machine_id"])
        else:
            try:
                out["api_url"] = relaycfg.relay_url() or None
            except relaycfg.RelayCfgError:
                pass
        link = self.relay_fn()
        if link is not None:
            out["connected"] = bool(link.connected)
            out["last_error"] = link.last_error or out["last_error"]
        return out

    def r_relay_link(self, ident, q, body):
        d = {k: body.get(k) for k in LINK_KEYS}
        try:
            relaycfg.validate_machine(dict(d, v=1, linked_at="-"))
        except relaycfg.RelayCfgError as e:
            raise ApiError(400, str(e))
        if d["local_machine_id"] != self.machine_id:
            raise ApiError(409, "local_machine_id no coincide con el de este agente", {"local_machine_id": self.machine_id})
        try:
            relaycfg.write_machine(d)
        except OSError as e:
            raise ApiError(503, "no pude guardar la credencial (%s)" % (e.strerror or type(e).__name__))
        log.info("máquina %s enlazada por la app local", d["machine_id"])
        self._relay_changed()
        return 204, None

    def r_relay_unlink(self, ident, q, body):
        try:
            relaycfg.remove_machine()
        except OSError as e:
            raise ApiError(503, "no pude borrar la credencial (%s)" % (e.strerror or type(e).__name__))
        log.info("máquina desenlazada por la app local")
        self._relay_changed()
        return 204, None

    def _relay_changed(self):
        self.link_nonce.rotate()
        if self.relay_reload is not None:
            try:
                self.relay_reload()
            except Exception:  # noqa: BLE001
                log.exception("no pude reiniciar el hilo del relay")


def _registry(fn, *args):
    try:
        return fn(*args)
    except registry.RegistryError as e:
        raise ApiError(e.status, e.message)


def _thread(r):
    extra = db.jload(r.get("extra"), {}) or {}
    return {"thread_id": r["thread_id"], "project": r["project"], "title": r["title"], "status": r["status"],
            "settled": bool(r["settled"]), "pending": db.jload(r["pending"], []), "worktree": r["worktree"],
            "branch": r["branch"], "link": extra.get("link"), "pull_requests": extra.get("pull_requests") or [],
            "updated": r["updated"]}


def _engine_snapshot():
    from .. import engine
    return engine.snapshot()


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "chopshop-agent"
    sys_version = ""
    timeout = CONN_TIMEOUT

    def do_GET(self):
        self._serve("GET")

    def do_POST(self):
        self._serve("POST")

    def do_DELETE(self):
        self._serve("DELETE")

    def do_PUT(self):
        self._serve("PUT")

    def do_PATCH(self):
        self._serve("PATCH")

    def _reply(self, status, obj, headers=None):
        data = b"" if status == 204 else json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if status != 204:
            self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        return status

    def send_error(self, code, message=None, explain=None):          # errores del propio http.server, también en JSON
        self.close_connection = True
        try:
            self._reply(code, {"error": message or self.responses.get(code, ("error",))[0]})
        except OSError:
            pass

    def log_request(self, code="-", size="-"):                         # el acceso se registra en _serve (sin query ni cabeceras)
        pass

    def log_message(self, fmt, *args):                                 # errores del parser HTTP: sin la línea de petición
        log.debug("http.server: error de protocolo")

    def _read_raw(self):
        """Bytes del cuerpo, siempre consumidos ANTES de responder (cerrar con datos sin leer provoca un RST que pisa la
        respuesta). Un cuerpo mayor que MAX_BODY se descarta (hasta 1 MiB) y se rechaza con 413."""
        if self.headers.get("Transfer-Encoding"):
            raise ApiError(411, "Content-Length requerido (sin chunked)")
        raw = self.headers.get("Content-Length")
        if raw is None:
            return b""
        try:
            n = int(raw)
        except ValueError:
            raise ApiError(400, "Content-Length inválido")
        if n < 0:
            raise ApiError(400, "Content-Length inválido")
        if n > MAX_BODY:
            left = min(n, 1 << 20)
            while left > 0:
                chunk = self.rfile.read(min(left, 65536))
                if not chunk:
                    break
                left -= len(chunk)
            raise ApiError(413, "cuerpo demasiado grande (máx. %d bytes)" % MAX_BODY)
        data = self.rfile.read(n) if n else b""
        if len(data) != n:
            raise ApiError(400, "cuerpo incompleto")
        return data

    @staticmethod
    def _parse_body(data):
        if not data.strip():
            return {}
        try:
            obj = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "el cuerpo debe ser JSON UTF-8")
        if not isinstance(obj, dict):
            raise ApiError(400, "el cuerpo debe ser un objeto JSON")
        return obj

    def _serve(self, method):
        app = self.server.app
        who, status = "-", 500
        parts = urllib.parse.urlsplit(self.path)
        path = parts.path.rstrip("/") or "/"
        try:
            try:
                raw = self._read_raw()
                if path == "/local" or path.startswith("/local/"):
                    status = self._serve_local(app, method, path, raw)
                    who = "local"
                    return
                local = self.server.local_addrs | app.listen_ips
                app.auth.check_web(self.headers, local)
                ident = app.auth.authorize(self.client_address[0], local, method != "GET",
                                           self.headers.get("Authorization"), method, path)
                who = ident.login or ident.via
                if ident.device:
                    who += " dispositivo %s" % ident.device
                if method not in ("GET", "POST", "DELETE", "PUT"):
                    raise ApiError(405, "método no permitido")
                app.match(method, path)                      # 404/405 antes que la comprobación del Content-Type
                app.auth.check_json(method, self.headers, bool(raw))
                body = self._parse_body(raw) if method != "GET" else {}
                query = {k: v[0] for k, v in urllib.parse.parse_qs(parts.query, keep_blank_values=True).items()}
                if method == "GET" and path == "/stream":
                    status = app.stream.serve(self, ident, query)
                    return
                code, obj = app.call(method, path, ident, query, body)
                status = self._reply(code, obj)
            except ApiError as e:
                self.close_connection = True
                hdrs = {"WWW-Authenticate": 'Bearer realm="chopshop-agent"'} if e.status == 401 else None
                status = self._reply(e.status, dict(e.extra or {}, error=e.message), hdrs)
            except Exception:  # noqa: BLE001 - nunca filtrar detalles internos al cliente
                log.exception("error interno en %s %s", method, path)
                status = self._reply(500, {"error": "error interno"})
        except OSError:
            status = 0                                       # el cliente se fue a mitad de respuesta
        finally:
            lvl = logging.INFO if (method != "GET" or status >= 400 or status == 0) else logging.DEBUG
            log.log(lvl, "%s %s %s -> %s (%s)", self.client_address[0], method, path, status, who)

    def _serve_local(self, app, method, path, raw):
        local_guard(self.server.server_address[0], self.server.server_address[1], self.client_address[0], self.headers)
        app.match(method, path)
        ident = Identity("local", None, True, ip=self.client_address[0])
        if method == "GET":
            code, obj = app.call(method, path, ident)
            return self._reply(code, obj)
        with app.link_nonce.lock:
            app.link_nonce.verify(self.headers.get(LINK_NONCE_HEADER))
            body = {}
            if path == "/local/relay/link":
                app.auth.check_json(method, self.headers, bool(raw))
                body = self._parse_body(raw)
            code, obj = app.call(method, path, ident, {}, body)
        return self._reply(code, obj)


class AgentHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def __init__(self, address, app, handler=Handler):
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        self.app = app
        host = address[0]
        ip = parse_ip(host)
        self.local_addrs = {str(ip)} if ip is not None else set()
        super().__init__(address, handler)

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)                      # sin getfqdn(): no queremos DNS inverso al arrancar
        host, port = self.server_address[:2]
        self.server_name, self.server_port = host, port
