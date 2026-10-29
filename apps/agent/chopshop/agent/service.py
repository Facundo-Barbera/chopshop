"""Servicio chopshop-agent: arranque, hilos de fondo y subcomandos `chopshop agent run|status|token|check-config|print-unit`.

`AgentService` ensambla los módulos (colector, T3, eventos) y el servidor HTTP (`server.py`):
  hilos: muestreo (+ compactación) · sondeo de T3 · motor (`engine.tick` con el bus inyectado, solo si hay lotes en
  state.json) · importación periódica de events.jsonl (CLI externa) · automatizaciones (sobres del bus + horarios) ·
  GitHub (si `[agent.github] enabled`) · roles permanentes (si `[agent.roles] enabled`: despertar por horario/eventos y
  seguimiento del hilo en su escritorio) · mantenimiento (retención de eventos, checkpoint WAL).
  Un fallo en un hilo se registra (sin repetirlo cada ciclo) y el hilo sigue; `stop()` los para a todos de forma ordenada.
`run` instala SIGTERM/SIGINT para la parada limpia. Nada aquí habla con systemd salvo `status` (solo lectura, inyectable) y
`print-unit` solo IMPRIME la unidad: no escribe, no habilita y no arranca nada.
Todo lo externo es inyectable (runners de tailscale/systemd/T3, reloj, poster de webhooks, módulos completos)."""
import argparse
import ipaddress
import json
import logging
import os
import re
import secrets
import shutil
import signal
import sys
import threading
import time

from .. import engine as engine_mod, events as legacy_events, graph, home, settings, state
from . import __version__, automations as automations_mod, collector as collector_mod, config, db, envelope, events, github, \
    halflife, notes, office as office_mod, pairing, roles as roles_mod, server, t3watch

log = logging.getLogger("chopshop.agent")

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))   # raíz del repo
AGENT_DIR = os.path.join(ROOT, "apps", "agent")
UNIT_TEMPLATE = os.path.join(ROOT, "systemd", "chopshop-agent.service")
UNIT_NAME = "chopshop-agent"
COMPACT_EVERY = 300.0             # s entre compactaciones de métricas
MAINT_INTERVAL = 3600.0           # s entre tareas de mantenimiento
MAINT_FIRST = 60.0                # primera pasada de mantenimiento tras arrancar
STOP_TIMEOUT = 10.0               # s totales para esperar a los hilos al parar
AUTOMATIONS_RELOAD = 60.0         # s entre relecturas de los perfiles por el hilo de automatizaciones
AUTOMATIONS_CURSOR = "automations_cursor"
AUTOMATIONS_BATCH = 500           # sobres por pasada


class ServiceError(Exception):
    """El servicio no puede arrancar (bind inválido, puerto ocupado...). El mensaje es para el operador."""


# ---------------------------------------------------------------- bind

def _is_loopback(host):
    ip = server.parse_ip(host)
    return bool(ip and ip.is_loopback)


def resolve_bind(cfg, runner=None):
    """IP de escucha efectiva. `auto` = primera IPv4 de `tailscale ip -4`. Nunca 0.0.0.0 ni `::`."""
    bind = str(cfg.get("bind") or "127.0.0.1").strip()
    if bind == "auto":
        rc, out, _ = (runner or server.default_runner)([cfg.get("tailscale_bin") or "tailscale", "ip", "-4"])
        ips = [l.strip() for l in (out or "").splitlines() if server.parse_ip(l.strip())] if rc == 0 else []
        if not ips:
            raise ServiceError("bind = \"auto\" pero no pude obtener la IP de Tailscale (¿tailscaled activo?). "
                               "Pon una IP en agent.bind o arranca Tailscale")
        return ips[0]
    if bind == "localhost":
        return "127.0.0.1"
    ip = server.parse_ip(bind)
    if ip is None:
        raise ServiceError("agent.bind inválido: %r (usa una IP, \"auto\" o \"localhost\")" % bind)
    if ip.is_unspecified:
        raise ServiceError("agent.bind = %s expondría el agente en todas las interfaces: no se permite" % bind)
    return str(ip)


def plan_listeners(host, port, local_listener=True):
    """[(host, port)] a abrir: la IP configurada y, si no es loopback, también 127.0.0.1 (CLI local)."""
    out = [(host, port)]
    if local_listener and not _is_loopback(host):
        out.append(("127.0.0.1", port))
    return out


# ---------------------------------------------------------------- token

def ensure_token(path, rotate=False):
    """Crea (0600, con `secrets.token_urlsafe`) el archivo del bearer si falta -> "created"; "exists" si ya está;
    "rotated" si `rotate`. El token NUNCA se devuelve ni se imprime."""
    path = os.path.expanduser(path)
    os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
    existed = os.path.exists(path)
    if existed and not rotate:
        if os.stat(path).st_mode & 0o077:
            os.chmod(path, 0o600)
        return "exists"
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(secrets.token_urlsafe(32) + "\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.chmod(path, 0o600)
    return "rotated" if existed else "created"


# ---------------------------------------------------------------- validación

def _writable_target(path):
    """El ancestro existente más cercano de `path` admite escritura (para crear el directorio de la DB)."""
    p = os.path.abspath(path)
    while p and not os.path.exists(p):
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return os.access(p, os.W_OK)


def check_config(cfg, runner=None, which=shutil.which):
    """(errores, avisos) de la configuración del agente. Solo mira rutas y permisos: nunca lee token ni webhooks."""
    errs, warns = [], []
    mode = cfg.get("auth")
    if mode not in server.AUTH_MODES:
        errs.append("agent.auth debe ser uno de %s (es %r)" % (", ".join(server.AUTH_MODES), mode))
    port = cfg.get("port")
    if isinstance(port, bool) or not isinstance(port, int) or not 0 <= port <= 65535:
        errs.append("agent.port debe ser un entero 0-65535 (es %r)" % (port,))
    for key in ("sample_interval", "t3_poll_interval"):
        v = cfg.get(key)
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 1:
            errs.append("agent.%s debe ser un número >= 1 (es %r)" % (key, v))
    try:
        host = resolve_bind(cfg, runner)
    except ServiceError as e:
        errs.append(str(e))
        host = None
    token = os.path.expanduser(cfg.get("token_file") or "")
    token_ok = bool(token) and os.path.isfile(token)
    if token_ok and os.stat(token).st_mode & 0o077:
        warns.append("el archivo de token es legible por otros: chmod 600 %s" % token)
    if host and not _is_loopback(host):
        if mode == "none-local":
            warns.append("bind %s con auth = \"none-local\": nadie podrá conectar desde la red" % host)
        elif mode == "token" and not token_ok:
            errs.append("auth = \"token\" y no hay token_file (%s): crea uno con `chopshop agent token`" % token)
        elif mode == "tailscale+token":
            owner = (cfg.get("owner_login") or "").strip()
            if not owner:
                warns.append("sin owner_login nadie podrá escribir desde la red (solo se acepta el origen local)")
            elif "@" not in owner or owner.endswith("@"):
                warns.append("owner_login %r parece un marcador: usa el login completo que muestra `tailscale whois`" % owner)
            if not token_ok:
                warns.append("sin token_file (%s) no habrá escrituras remotas: `chopshop agent token`" % token)
            if not which(cfg.get("tailscale_bin") or "tailscale"):
                warns.append("no encuentro el CLI de Tailscale (agent.tailscale_bin): sin él todo acceso remoto será 403")
    if not _writable_target(os.path.dirname(cfg.get("db_path") or "") or "."):
        errs.append("no puedo escribir en el directorio de la base de datos: %s" % cfg.get("db_path"))
    for name, path in (cfg.get("webhook_files") or {}).items():
        if not isinstance(path, str) or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", path.strip()):
            errs.append("webhook_files.%s debe ser la RUTA de un archivo, no una URL" % name)
            continue
        p = os.path.expanduser(path)
        if not os.path.isfile(p):
            warns.append("webhook_files.%s: el archivo no existe (%s)" % (name, path))
        elif os.stat(p).st_mode & 0o077:
            warns.append("webhook_files.%s: el archivo es legible por otros: chmod 600 %s" % (name, path))
    if cfg.get("t3_enabled", True):
        t3c = cfg.get("t3") or {}
        if not (t3c.get("t3_bin") or t3c.get("origin")):
            warns.append("define agent.t3.t3_bin o agent.t3.origin: sin ellos el sondeo de T3 avisará t3_unreachable")
        old = [k for k in ("helper", "node", "transport") if k in t3c]
        if old:
            warns.append("agent.t3.%s es una clave vieja que ya no se usa: bórrala de la config" % "/".join(old))
    if not os.path.isdir(cfg.get("projects_root") or ""):
        warns.append("projects_root no existe: %s" % cfg.get("projects_root"))
    gerrs, gwarns = github.check(cfg, which)
    errs += gerrs
    warns += gwarns
    for k, v in (cfg.get("retention") or {}).items():
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0:
            errs.append("retention.%s debe ser un número > 0 (es %r)" % (k, v))
    return errs, warns


# ---------------------------------------------------------------- retención de eventos

def prune_events(conn, days, now=None):
    """Borra eventos (y sus entregas) más viejos que `days` días. Devuelve cuántos eventos se borraron."""
    cut = (time.time() if now is None else now) - float(days) * 86400
    with db.tx():
        n = conn.execute("DELETE FROM events WHERE ts<?", (cut,)).rowcount
        conn.execute("DELETE FROM deliveries WHERE event_seq NOT IN (SELECT seq FROM events)")
    return max(0, n)


# ---------------------------------------------------------------- puente del motor

def engine_emitter(conn, cfg, poster=None, on_emit=None):
    """`emit_fn` para el motor dentro del agente (misma firma y resultado que `chopshop.events.emit`): primero guarda el
    sobre en el bus (con el mismo `ts` en segundos que la línea de events.jsonl, así `import_legacy` la reconoce y no la
    duplica) y después hace lo de siempre (events.jsonl + suscripciones de state.json, p. ej. el `notify` de reacciones)."""
    def emit_fn(st, event, project, body, adhoc_files=None, log=True, only=None):
        ts = state.now()
        try:
            seq = events.emit(conn, cfg, event, project, body, poster=poster, ts=envelope.epoch(ts))
            if on_emit:
                on_emit(seq)                     # despierta a /stream
        except Exception:  # noqa: BLE001 - el bus no debe frenar al motor
            logging.getLogger("chopshop.agent").exception("no pude registrar %s en el bus", event)
        return legacy_events.emit(st, event, project, body, adhoc_files, log=log, only=only, ts=ts)
    return emit_fn


def engine_has_work(st=None):
    """Hay algún lote que `engine.tick` todavía procesaría (mismo criterio con el que tick los salta)."""
    st = st if st is not None else state.read()
    for b in st.get("batches", {}).values():
        if not (all(t["done"] for t in b["tasks"]) and (b.get("done_notified") or (b.get("graph") and graph.finished(st, b)))):
            return True
    return False


# ---------------------------------------------------------------- servicio

class AgentService:
    """Ensambla módulos + servidor + hilos. `start()` → escucha y trabaja; `stop()` → parada ordenada (idempotente)."""

    def __init__(self, cfg, conn=None, collector=None, t3=None, runner=None, poster=None,
                 orchestrator_fn=None, clock=time.time, maint_interval=MAINT_INTERVAL, maint_first=MAINT_FIRST, compact_every=COMPACT_EVERY,
                 engine_tick=None, stream_opts=None, automations=None,
                 gh_runner=None, gh_projects_fn=github.profile_repos, roles=None):
        self.cfg, self.clock, self.runner, self.poster = cfg, clock, runner, poster
        self.engine_tick = engine_tick or engine_mod.tick
        self.owns_conn = conn is None
        self.conn = conn if conn is not None else db.connect(cfg["db_path"])
        self.collector = collector or collector_mod.Collector(cfg, self.conn)
        self.t3 = t3 or t3watch.T3(cfg)
        self.runtime = server.Runtime(clock)
        self.pairing = pairing.Pairing(self.conn, clock)
        self.auth = server.Authenticator(cfg, runner, pairing=self.pairing)
        self.app = server.AgentApp(cfg, self.conn, self.collector, self.t3, self.auth, self.runtime,
                                   self.emit, orchestrator_fn, clock, pairing=self.pairing, stream_opts=stream_opts)
        self.engine_emit = engine_emitter(self.conn, cfg, poster, self.app.stream.bus.publish)
        self.office = office_mod.Office(self.conn, cfg, self.emit_office, clock=clock)
        self.app.office = self.office
        self.maint_interval, self.maint_first = maint_interval, maint_first
        self.compact_every = compact_every
        acfg = cfg.get("automations") or {}
        self.automations = automations or automations_mod.Automations(
            self.emit_envelope, clock=clock, store=automations_mod.MetaStore(self.conn), enabled=acfg.get("enabled", True))
        self._auto_cursor = None
        self._auto_loaded = None
        self._wake_seats = {}                       # hilo despertado -> (escritorio, desde) pendiente de sentar
        rcfg = cfg.get("roles") or {}
        self.roles = roles or roles_mod.Roles(
            self.conn, self._emit_role, assign_fn=self._seat_wake, clock=clock, enabled=bool(rcfg.get("enabled", False)),
            max_wakes_per_hour=int(rcfg.get("max_wakes_per_hour") or roles_mod.MAX_WAKES_PER_HOUR))
        self.github = None
        if (cfg.get("github") or {}).get("enabled"):
            self.github = github.GitHubPoller(self.conn, cfg, self.emit, runner=gh_runner, clock=clock,
                                              projects_fn=gh_projects_fn)
        self.fader = halflife.Fader(self.conn, self.app.projector.current, self._fade_emit, clock=clock)
        self.stop_event = threading.Event()
        self.servers, self.threads, self._serving = [], [], []
        self._stopped = False

    WAKE_SEAT_TTL = 900.0           # s que se reintenta sentar un hilo despertado que la oficina aún no conoce

    def _seat_wake(self, project, desk, thread_id, role, inheritance=None, title=None, cause=None):
        """`assign_fn` de los roles permanentes: el hilo despertado se sienta por la oficina (`desk.assigned reason: wake`),
        que lleva la tabla de ocupación y la herencia. Si la oficina aún no vio su `task.state`, se reintenta en `office_once`."""
        self._wake_seats[thread_id] = (desk, self.clock())
        self._retry_wake_seats()

    def _retry_wake_seats(self):
        for tid, (desk, since) in list(self._wake_seats.items()):
            try:
                self.office.assign(desk, tid, reason="wake")
            except office_mod.OfficeError as e:
                if e.status == 404 and "hilo" in e.message and self.clock() - since < self.WAKE_SEAT_TTL:
                    continue
                log.warning("no pude sentar el hilo despertado %s en %s: %s", tid, desk, e.message)
            self._wake_seats.pop(tid, None)

    def office_once(self):
        r = self.office.tick()
        if self._wake_seats:
            self._retry_wake_seats()
        return r

    def _fade_emit(self, event, project, body):
        """Salida por semivida: un escritorio lo libera `office.release` (actualiza su tabla y sube a quien espere el rol);
        el vestíbulo (`desk: null`) va directo al bus."""
        office = getattr(self, "office", None)
        if event == "desk.released" and body.get("desk") and office is not None:
            occ = (office.desk(body["desk"]) or {}).get("occupant") or {}
            if occ.get("thread_id") == body.get("thread_id"):
                office.release(body["desk"], body.get("reason") or "faded")
            return None
        return self.emit(event, project, body)

    # -- API común de los módulos
    def emit(self, event, project, body=None):
        body = halflife.stamp(self.conn, event, body)   # el `touched_at` de un toque viaja en cada `task.state` del hilo
        seq = events.emit(self.conn, self.cfg, event, project, body, poster=self.poster)
        self.app.stream.bus.publish(seq)            # despierta a los clientes de /stream
        return seq

    def emit_office(self, type, project, body, **kw):
        """Sobre de la oficina (`desk.*`, `office.changed`) -> bus + `/stream`."""
        env = events.emit_envelope(self.conn, self.cfg, type, project, body, poster=self.poster, ts=self.clock(), **kw)
        if env:
            self.app.stream.bus.publish(env["seq"])
        return env

    def emit_envelope(self, env):
        """Sobre parcial de una automatización -> bus (mismo `emit`, con los metadatos del sobre)."""
        return automations_mod.bus_emit(self.conn, self.cfg, env, poster=self.poster)

    def _emit_role(self, env):
        """Sobre de los roles (`desk.*`) -> bus (valida el esquema del tipo) y despierta a /stream."""
        stored = self.emit_envelope(env)
        self.app.stream.bus.publish(stored.get("seq") if stored else None)
        return stored

    @property
    def address(self):
        """(host, puerto) del listener principal (el puerto real si se pidió 0)."""
        return self.servers[0].server_address[:2] if self.servers else None

    # -- arranque
    def start(self, background=True):
        host = resolve_bind(self.cfg, self.runner)
        port = int(self.cfg.get("port"))
        try:
            for i, (h, p) in enumerate(plan_listeners(host, port, self.cfg.get("local_listener", True))):
                try:
                    self.servers.append(server.AgentHTTPServer((h, p if i == 0 else self.servers[0].server_address[1]), self.app))
                except OSError as e:
                    if i == 0:
                        raise ServiceError("no pude escuchar en %s:%s: %s" % (h, p, e))
                    log.warning("no pude abrir el listener local %s:%s (%s); el CLI local usará %s", h, p, e, host)
        except BaseException:
            self._close_servers()
            raise
        self.app.listen_ips = {str(server.parse_ip(s.server_address[0])) for s in self.servers}
        self._import_legacy()
        if background:
            self._spawn("sampler", self._run_sampler)
            if self.cfg.get("t3_enabled", True):
                self._spawn("t3", self._loop, "t3", self._poll_once, lambda: self.cfg.get("t3_poll_interval") or 5)
            if self.cfg.get("engine_enabled", True):
                self._spawn("engine", self._loop, "engine", self.engine_once, lambda: self.cfg.get("engine_interval") or 5)
            if self.cfg.get("import_legacy", True):
                self._spawn("legacy", self._loop, "legacy", self.import_legacy_once, lambda: self.cfg.get("legacy_interval") or 5)
            if (self.cfg.get("automations") or {}).get("enabled", True):
                self._spawn("automations", self._loop, "automations", self.automations_once,
                            lambda: (self.cfg.get("automations") or {}).get("interval") or 2)
            if (self.cfg.get("office") or {}).get("enabled", True):
                self._spawn("office", self._loop, "office", self.office_once,
                            lambda: (self.cfg.get("office") or {}).get("interval") or 2)
            if self.roles.enabled:
                self._spawn("roles", self._loop, "roles", self.roles_once, lambda: (self.cfg.get("roles") or {}).get("interval") or 5)
            if self.github is not None:
                self._spawn("github", self._loop, "github", self.github.poll_once, self.github.next_delay)
            if self.cfg.get("halflife_enabled", True):
                self._spawn("halflife", self._loop, "halflife", self.fader.sweep, self.fader.next_delay)
            self._spawn("maintenance", self._maintenance)
        for s in self.servers:
            self._serving.append(s)
            self._spawn("http-%s" % s.server_address[0], s.serve_forever, 0.2)
        try:
            self.emit("agent_started", None, {"version": __version__})
        except Exception:  # noqa: BLE001
            log.exception("no pude registrar agent_started")
        log.info("chopshop-agent %s en %s escuchando en %s (auth=%s)", __version__, self.app.machine_id,
                 ", ".join("%s:%s" % s.server_address[:2] for s in self.servers), self.auth.mode)
        return self

    def _spawn(self, name, target, *args):
        t = threading.Thread(target=target, args=args, name="chopshop-" + name, daemon=True)
        t.start()
        self.threads.append(t)

    def _import_legacy(self):
        if not self.cfg.get("import_legacy", True):
            return
        try:
            self.import_legacy_once()
        except Exception:  # noqa: BLE001 - la migración es opcional
            log.exception("no pude importar events.jsonl")

    def import_legacy_once(self):
        """Importa lo añadido a events.jsonl desde la última vez (idempotente por desplazamiento + deduplicación)."""
        res = events.import_legacy(self.conn, home.events_log(), self.cfg.get("machine_id"))
        if res["imported"]:
            log.info("importados %d eventos de events.jsonl (%d omitidos)", res["imported"], res["skipped"])
            self.app.stream.bus.publish()
        return res

    def engine_once(self):
        """Una pasada del motor con el bus inyectado; nada si no hay lotes con trabajo en state.json."""
        if not os.path.exists(home.state_path()) or not engine_has_work():
            return None
        return self.engine_tick(None, None, lambda m: log.info("motor: %s", m), emit_fn=self.engine_emit)

    # -- hilos
    def _loop(self, name, fn, interval):
        while not self.stop_event.is_set():
            try:
                fn()
                self.runtime.ok(name)
            except Exception as e:  # noqa: BLE001 - un fallo no mata el hilo
                if self.runtime.fail(name, e):
                    log.warning("hilo %s: %s: %s", name, type(e).__name__, e)
            if self.stop_event.wait(max(0.05, float(interval()))):
                break

    def _run_sampler(self):
        self.collector.run_forever(self.stop_event, compact_every=self.compact_every)

    def _poll_once(self):
        res = t3watch.poll(self.conn, self.cfg, self.t3, self.emit)
        if not res.get("skipped"):
            self.runtime.last_poll = self.clock()
        return res

    def automations_once(self):
        """Una pasada: relee perfiles (cada AUTOMATIONS_RELOAD s), despacha los sobres nuevos del bus y revisa horarios.
        El cursor vive en `meta`; la primera vez en una DB nueva empieza en la cabeza (no reprocesa el historial)."""
        now = self.clock()
        if self._auto_loaded is None or now - self._auto_loaded >= AUTOMATIONS_RELOAD:
            self.automations.reload()
            self._auto_loaded = now
        if self._auto_cursor is None:
            with db.tx():
                row = self.conn.execute("SELECT value FROM meta WHERE key=?", (AUTOMATIONS_CURSOR,)).fetchone()
            self._auto_cursor = int(row["value"]) if row and str(row["value"]).isdigit() else events.last_seq(self.conn)
            if not row:
                with db.tx():
                    self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (AUTOMATIONS_CURSOR, str(self._auto_cursor)))
        fired = []
        rows = events.list_after(self.conn, self._auto_cursor, AUTOMATIONS_BATCH)
        for r in rows:
            fired += self.automations.on_event(r)
            self._auto_cursor = r["seq"]
        if rows:
            with db.tx():
                self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (AUTOMATIONS_CURSOR, str(self._auto_cursor)))
        fired += self.automations.tick(now)
        return fired

    def roles_once(self):
        """Una pasada de los roles permanentes (sobres nuevos del bus con cursor propio, horarios y despertares vivos)."""
        return self.roles.once(events.list_after, events.last_seq, self.clock())

    def _maintenance(self):
        if self.stop_event.wait(self.maint_first):
            return
        self._loop("maintenance", self.maintenance_once, lambda: self.maint_interval)

    def maintenance_once(self):
        days = (self.cfg.get("retention") or {}).get("events_days", 90)
        n = prune_events(self.conn, days, self.clock())
        if n:
            log.info("retención: %d eventos con más de %s días borrados", n, days)
        notes.prune(self.conn, self.clock())
        with db.tx():
            self.conn.execute("PRAGMA wal_checkpoint(PASSIVE)")
        return n

    # -- parada
    def request_stop(self):
        self.stop_event.set()

    def wait(self):
        while not self.stop_event.wait(0.5):
            pass

    def _close_servers(self):
        for s in self.servers:
            try:
                if s in self._serving:
                    s.shutdown()
                s.server_close()
            except Exception:  # noqa: BLE001
                pass
        self._serving = []

    def stop(self):
        if self._stopped:
            return
        self._stopped = True
        self.stop_event.set()
        self.app.stream.close()                     # corta las conexiones SSE (sus hilos son daemon)
        self._close_servers()
        end = time.monotonic() + STOP_TIMEOUT
        for t in self.threads:
            t.join(max(0.1, end - time.monotonic()))
        self.automations.wait_idle(max(0.1, end - time.monotonic()))   # los scripts en curso tienen su propio timeout
        alive = [t.name for t in self.threads if t.is_alive()]
        if alive:
            log.warning("hilos que no terminaron a tiempo: %s", ", ".join(alive))
        events.flush(5)
        events.cancel_pending()                 # reintentos/debounce pendientes no sobreviven a la conexión
        if self.owns_conn and not alive:
            try:
                self.conn.close()
            except Exception:  # noqa: BLE001
                pass
        log.info("chopshop-agent detenido")


# ---------------------------------------------------------------- unidad systemd

PLACEHOLDER = re.compile(r"@[A-Z_]+@")


def _collapse(path, home_dir):
    """Ruta -> forma para systemd: lo que cuelga de $HOME pasa a `%h`; el resto escapa `%`."""
    if home_dir and (path == home_dir or path.startswith(home_dir.rstrip("/") + "/")):
        return "%h" + path[len(home_dir.rstrip("/")):].replace("%", "%%")
    return path.replace("%", "%%")


def _quote(arg):
    """Argumento de ExecStart= entre comillas si hace falta ($ escapado; %h se conserva)."""
    arg = arg.replace("$", "$$")
    return '"%s"' % arg.replace("\\", "\\\\").replace('"', '\\"') if re.search(r'[\s"\'\\]', arg) else arg


def default_exec(environ=None):
    env = os.environ if environ is None else environ
    exe = shutil.which("chopshop", path=env.get("PATH"))
    if exe:
        return os.path.abspath(exe)
    repo_bin = os.path.join(AGENT_DIR, "bin", "chopshop")
    return repo_bin if os.path.isfile(repo_bin) else os.path.expanduser("~/.local/bin/chopshop")


def render_unit(cfg, exec_path=None, extra_rw=(), template=None, environ=None):
    """Texto de la unidad `chopshop-agent.service` con las rutas del entorno actual. No escribe nada."""
    env = os.environ if environ is None else environ
    home_dir = os.path.expanduser(env.get("HOME") or "~")
    with open(template or UNIT_TEMPLATE, encoding="utf-8") as f:
        text = f.read()
    exe = os.path.expanduser(exec_path) if exec_path else default_exec(env)
    rw = [os.path.dirname(cfg.get("db_path") or ""), home.home()]
    rw += list((cfg.get("service") or {}).get("read_write_paths") or []) + list(extra_rw)
    if not (cfg.get("t3") or {}).get("origin"):    # T3 local: su CLI (`t3 auth pairing create`) escribe en su carpeta de datos
        rw.append(env.get("T3CODE_HOME") or os.path.join(home_dir, ".t3"))
    seen, rw_out = set(), []
    for p in rw:
        p = os.path.abspath(os.path.expanduser(p)) if p else ""
        if p and p not in seen:
            seen.add(p)
            rw_out.append("-" + _collapse(p, home_dir).replace(" ", "\\x20"))
    path_dirs = [d for d in (env.get("PATH") or "").split(os.pathsep) if d.startswith("/")]
    extra_env = []
    for var in ("CHOPSHOP_CONFIG", "CHOPSHOP_HOME"):
        if env.get(var):
            val = _collapse(os.path.abspath(os.path.expanduser(env[var])), home_dir)
            extra_env.append('Environment="%s=%s"' % (var, val.replace("\\", "\\\\").replace('"', '\\"')))
    subs = {"@EXEC_START@": "%s agent run" % _quote(_collapse(os.path.abspath(exe), home_dir)),
            "@READ_WRITE_PATHS@": " ".join(rw_out),
            "@PATH@": os.pathsep.join(_collapse(d, home_dir) for d in path_dirs) or "/usr/local/bin:/usr/bin:/bin"}
    out = []
    for line in text.splitlines():
        if line.strip() == "@EXTRA_ENVIRONMENT@":
            out += extra_env
            continue
        for k, v in subs.items():
            line = line.replace(k, v)
        out.append(line)
    rendered = "\n".join(out) + "\n"
    left = PLACEHOLDER.findall(rendered)
    if left:
        raise ServiceError("la plantilla tiene marcadores sin resolver: %s" % ", ".join(sorted(set(left))))
    return rendered


# ---------------------------------------------------------------- CLI

def _dur(seconds):
    s = int(seconds or 0)
    if s < 120:
        return "%ds" % s
    if s < 7200:
        return "%dm" % (s // 60)
    if s < 172800:
        return "%dh %dm" % (s // 3600, s % 3600 // 60)
    return "%dd %dh" % (s // 86400, s % 86400 // 3600)


def _load_cfg(a, err):
    over = {}
    if getattr(a, "bind", None):
        over["bind"] = a.bind
    if getattr(a, "port", None) is not None:
        over["port"] = a.port
    try:
        return config.load(over)
    except settings.SettingsError as e:
        print("error: %s" % e, file=err)
        return None


def cmd_run(a, out, err, runner):
    cfg = _load_cfg(a, err)
    if cfg is None:
        return 2
    errs, warns = check_config(cfg, runner)
    for w in warns:
        log.warning("%s", w)
    if errs:
        for e in errs:
            print("error: %s" % e, file=err)
        return 2
    try:
        svc = AgentService(cfg, runner=runner)
    except (ServiceError, ValueError) as e:
        print("error: %s" % e, file=err)
        return 2
    # los manejadores van ANTES de abrir el puerto: una señal temprana solo marca la parada y start() termina limpio
    old = {sig: signal.signal(sig, lambda *_: svc.request_stop()) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        svc.start()
        svc.wait()
    except (ServiceError, ValueError) as e:
        print("error: %s" % e, file=err)
        return 2
    finally:
        svc.stop()
        for sig, handler in old.items():
            signal.signal(sig, handler)
    return 0


def cmd_status(a, out, err, runner):
    from .client import AgentClient, AgentError
    cfg = _load_cfg(a, err)
    if cfg is None:
        return 2
    code = 0
    try:
        c = AgentClient(url=a.url, cfg=cfg, timeout=5)
        health, snap = c.get("/health"), c.get("/snapshot")
    except AgentError as e:
        print("el agente no responde: %s" % e, file=out)
        health = snap = None
        code = 1
    unit = None
    rc, text, _ = (runner or server.default_runner)(["systemctl", "--user", "is-active", UNIT_NAME])
    if rc != 127:
        unit = (text or "").strip() or "desconocido"
    if a.json:
        print(json.dumps({"reachable": code == 0, "health": health, "agent": (snap or {}).get("agent"), "unit": unit},
                         ensure_ascii=False), file=out)
        return code
    if health:
        ag = snap["agent"]
        print("chopshop-agent %s en %s (api %s) — activo %s" % (health["version"], health["machine_id"], health["api_version"],
                                                                 _dur(health["uptime"])), file=out)
        age = lambda v: "-" if v is None else "%.1fs" % v  # noqa: E731
        print("  T3: %s · última muestra: %s · último sondeo: %s" % (
            {True: "ok", False: "caído", None: "sin datos"}[ag["t3_ok"]], age(ag["last_sample_age"]), age(ag["last_poll_age"])),
            file=out)
        print("  hilos: %d (%d preguntas pendientes)" % (len(snap["threads"]), len(snap["pending_questions"])), file=out)
        for name, msg in (ag.get("errors") or {}).items():
            print("  aviso (%s): %s" % (name, msg), file=out)
    if unit is not None:
        print("  unidad systemd %s: %s" % (UNIT_NAME, unit), file=out)
    return code


def cmd_token(a, out, err, runner):
    cfg = _load_cfg(a, err)
    if cfg is None:
        return 2
    path = cfg["token_file"]
    try:
        what = ensure_token(path, rotate=a.rotate)
    except OSError as e:
        print("error: no pude escribir el token en %s: %s" % (path, e.strerror or type(e).__name__), file=err)
        return 1
    print({"created": "token creado", "exists": "el token ya existe", "rotated": "token regenerado"}[what]
          + ": %s (0600; el contenido no se muestra: cópialo con scp/ssh a los clientes)" % path, file=out)
    return 0


def cmd_check(a, out, err, runner):
    cfg = _load_cfg(a, err)
    if cfg is None:
        return 2
    errs, warns = check_config(cfg, runner)
    print("config: %s" % settings.path(), file=out)
    for e in errs:
        print("error: %s" % e, file=out)
    for w in warns:
        print("aviso: %s" % w, file=out)
    if not errs:
        print("ok: la configuración es válida%s" % (" (con avisos)" if warns else ""), file=out)
    return 1 if errs else 0


def cmd_print_unit(a, out, err, runner):
    cfg = _load_cfg(a, err)
    if cfg is None:
        return 2
    try:
        out.write(render_unit(cfg, a.exec, a.rw or (), a.template))
    except (OSError, ServiceError) as e:
        print("error: %s" % e, file=err)
        return 1
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="chopshop agent", description="Servicio chopshop-agent (métricas, T3, eventos, API HTTP)")
    sp = p.add_subparsers(dest="cmd", required=True)
    x = sp.add_parser("run", help="arranca el agente en primer plano (SIGTERM/SIGINT lo paran con limpieza)")
    x.add_argument("--bind", help="sustituye agent.bind")
    x.add_argument("--port", type=int, help="sustituye agent.port")
    x.set_defaults(f=cmd_run)
    x = sp.add_parser("status", help="consulta al agente en ejecución (y al estado de su unidad systemd)")
    x.add_argument("--url", help="URL del agente (por defecto CHOPSHOP_AGENT_URL o 127.0.0.1:<port>)")
    x.add_argument("--json", action="store_true")
    x.set_defaults(f=cmd_status)
    x = sp.add_parser("token", help="crea el token (0600) si falta; nunca lo imprime")
    x.add_argument("--rotate", action="store_true", help="genera uno nuevo aunque ya exista")
    x.set_defaults(f=cmd_token)
    sp.add_parser("check-config", help="valida la configuración del agente").set_defaults(f=cmd_check)
    x = sp.add_parser("print-unit", help="imprime la unidad systemd --user (no escribe ni arranca nada)")
    x.add_argument("--exec", help="ruta del ejecutable `chopshop` (por defecto el del PATH o el del repo)")
    x.add_argument("--rw", action="append", help="ruta extra de escritura (repetible)")
    x.add_argument("--template", help="plantilla alternativa")
    x.set_defaults(f=cmd_print_unit)
    return p


def main(argv, stdout=None, stderr=None, runner=None):
    out, err = stdout or sys.stdout, stderr or sys.stderr
    try:
        a = build_parser().parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 2
    if a.cmd == "run":
        logging.basicConfig(level=logging.INFO, stream=err, format="%(levelname)s %(name)s: %(message)s")
    return a.f(a, out, err, runner) or 0
