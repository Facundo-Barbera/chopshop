"""Eventos del agente: registro monotónico en SQLite (`events`) y entrega por webhook (`subscriptions` + `cfg["webhook_files"]`).

- Cada fila es un sobre (`agent/envelope.py`, columnas v3): `emit(event, project, body)` acepta el nombre viejo y lo traduce
  (`LEGACY_MAP`, `body.legacy`); `emit_envelope(type, ...)` emite tipos nuevos con `subject`/`needs`/`severity`/`cause`.
  `list_after`/`recent` devuelven sobres (+ `event` y `machine_id` viejos). El webhook recibe el sobre + `event`/`machine_id`.
- `emit` inserta y devuelve `seq`; la entrega va a una cola con hilos de fondo (no bloquea) y deja su resultado en `deliveries`.
- La URL del webhook se lee del archivo (primera línea) en cada entrega; nunca se guarda, se imprime ni se registra.
  `deliveries.detail` solo lleva `HTTP <código>` o el NOMBRE del tipo de excepción (los mensajes de urllib pueden traer la URL).
- Todo es inyectable: `poster(url, payload_bytes, timeout) -> código HTTP` (por defecto urllib), para tests sin red."""
import datetime
import json
import os
import re
import socket
import threading
import time
import urllib.error
import urllib.request
from collections import deque

from . import db, envelope

TIMEOUT = 3                       # segundos por POST
WORKERS = 4                       # hilos de entrega (un webhook lento no frena a los demás)
MAX_LIMIT = 1000                  # tope de list_after
LEGACY_KEY = "events_legacy_offset"
_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


class EventsError(Exception):
    pass


# ---------------------------------------------------------------- entrega

def _default_poster(url, data, timeout):
    """POST JSON con urllib. Devuelve el código HTTP (también para 4xx/5xx); el resto de fallos se propagan."""
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "chopshop-agent/0.6"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def _read_url(path):
    """Primera línea del archivo, sin espacios. Solo http(s)."""
    with open(os.path.expanduser(path), encoding="utf-8") as f:
        url = f.readline().strip()
    if not url.startswith(("http://", "https://")):
        raise ValueError("sin URL http(s)")
    return url


def _exc_detail(e):
    """Describe una excepción SIN su mensaje (puede contener la URL). Solo tipos (y el del motivo en URLError)."""
    name = type(e).__name__
    reason = getattr(e, "reason", None)
    if isinstance(e, urllib.error.URLError) and reason is not None and not isinstance(reason, str):
        name += "/" + type(reason).__name__
    return name


def _deliver(webhook_file, data, poster, timeout):
    """(ok, detail). Nunca lanza; el detail no incluye la URL ni mensajes de excepción."""
    try:
        url = _read_url(webhook_file)
    except Exception as e:  # noqa: BLE001
        return False, "archivo de webhook ilegible (%s)" % type(e).__name__
    try:
        status = poster(url, data, timeout)
    except Exception as e:  # noqa: BLE001 - solo el tipo, nunca str(e)
        return False, _exc_detail(e)
    if isinstance(status, bool) or not isinstance(status, int):
        return bool(status), "ok" if status else "fallo"
    return 200 <= status < 300, "HTTP %d" % status


class _Queue:
    """Cola de entregas con hilos daemon creados bajo demanda. `flush` espera a que se vacíe (tests, apagado limpio)."""

    def __init__(self):
        self._cv = threading.Condition()
        self._items = deque()
        self._pending = 0
        self._threads = 0

    def put(self, fn):
        with self._cv:
            self._items.append(fn)
            self._pending += 1
            if self._threads < WORKERS and self._threads < self._pending:
                self._threads += 1
                threading.Thread(target=self._run, name="chopshop-webhook", daemon=True).start()
            self._cv.notify()

    def _run(self):
        while True:
            with self._cv:
                while not self._items:
                    if not self._cv.wait(30):          # inactivo: el hilo termina y se recrea al necesitarlo
                        if not self._items:
                            self._threads -= 1
                            return
                fn = self._items.popleft()
            try:
                fn()
            except Exception:  # noqa: BLE001 - un fallo de entrega no debe matar al hilo
                pass
            finally:
                with self._cv:
                    self._pending -= 1
                    self._cv.notify_all()

    def flush(self, timeout=10):
        end = time.monotonic() + timeout
        with self._cv:
            while self._pending:
                left = end - time.monotonic()
                if left <= 0:
                    return False
                self._cv.wait(left)
        return True


_queue = _Queue()


def flush(timeout=10):
    """Espera a que terminen las entregas en curso. True si quedó vacía."""
    return _queue.flush(timeout)


def _record(conn, seq, name, ok, detail):
    try:
        with db.tx():
            conn.execute("INSERT OR REPLACE INTO deliveries(event_seq,name,ok,detail,ts) VALUES(?,?,?,?,?)",
                         (seq, name, 1 if ok else 0, detail, time.time()))
    except Exception:  # noqa: BLE001 - conexión cerrada al apagar, etc.
        pass


def _matches(project, events, event, proj, typ=None):
    return project in ("*", proj) and (not events or event in events or (typ is not None and typ in events))


def _targets(conn, cfg, event, project, typ=None):
    """{nombre: archivo}: webhook_files de la config (sin filtro) + suscripciones cuyo filtro coincide (pisan al mismo nombre).
    El filtro de eventos acepta el nombre viejo o el tipo nuevo."""
    out = {str(n): f for n, f in (cfg.get("webhook_files") or {}).items() if f}
    with db.tx():
        subs = db.rows(conn.execute("SELECT name, webhook_file, project, events FROM subscriptions"))
    for s in subs:
        if _matches(s["project"], db.jload(s["events"], []), event, project, typ):
            out[s["name"]] = s["webhook_file"]
    return out


def _machine(cfg):
    return cfg.get("machine_id") or socket.gethostname()


def _insert(conn, env, event, ts):
    """Inserta el sobre (con el nombre `event` en la columna vieja) y le pone `seq`. Llamar con db.tx() tomado."""
    s, c = env["subject"], env["cause"]
    cur = conn.execute(
        "INSERT INTO events(ts,machine_id,event,project,body,id,type,severity,needs,subject_kind,subject_id,subject,"
        "cause_id,cause_depth) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (ts, env["machine"], event, env["project"], db.jdump(env["body"]), env["id"], env["type"], env["severity"],
         env["needs"], s["kind"], s["id"], db.jdump(s), c["id"], c["depth"]))
    env["seq"] = cur.lastrowid
    return env


def _store(conn, machine, items, project, ts, cause):
    """[(nombre_columna_event, campos)] -> sobres guardados (en orden; ids ULID y seq crecientes juntos)."""
    out = []
    with db.tx():
        for event, f in items:
            env = envelope.build(f["type"], project, f["body"], f["severity"], f["needs"], f["subject"], cause,
                                 machine, ts)
            out.append((event, _insert(conn, env, event, ts)))
    return out


def payload(env, event=None):
    """Lo que recibe un webhook: el sobre + los campos viejos `event` y `machine_id` (compatibilidad un ciclo)."""
    return dict(env, event=event or (env.get("body") or {}).get("legacy") or env["type"], machine_id=env["machine"])


def _publish(conn, cfg, stored, poster, timeout, wait):
    post = poster or _default_poster
    n = 0
    for event, env in stored:
        targets = _targets(conn, cfg, event, env["project"], env["type"])
        if not targets:
            continue
        data = db.jdump(payload(env, event)).encode("utf-8")
        seq = env["seq"]
        for name, wfile in targets.items():
            def job(name=name, wfile=wfile, data=data, seq=seq):
                ok, detail = _deliver(wfile, data, post, timeout)
                _record(conn, seq, name, ok, detail)
            _queue.put(job)
            n += 1
    if wait and n:
        _queue.flush(timeout * (n + 1))


def emit(conn, cfg, event, project, body=None, poster=None, timeout=TIMEOUT, wait=False, ts=None, cause=None):
    """Registra el evento (nombre viejo o tipo nuevo) como sobre y devuelve su `seq`. El nombre viejo se traduce con
    `envelope.LEGACY_MAP` y viaja en `body.legacy`; una pregunta o un permiso añaden antes un `task.state` con
    `attention`. La entrega es asíncrona (`wait=True` espera a que termine, para CLI/tests)."""
    ts = time.time() if ts is None else float(ts)
    machine = _machine(cfg)
    main = envelope.from_legacy(event, body, machine)
    items = [(c["type"], c) for c in envelope.companions(main)] + [(event, main)]
    stored = _store(conn, machine, items, project, ts, cause)
    _publish(conn, cfg, stored, poster, timeout, wait)
    return stored[-1][1]["seq"]


def emit_envelope(conn, cfg, type, project=None, body=None, subject=None, severity=None, needs=envelope.DEFAULT,
                  cause=None, poster=None, timeout=TIMEOUT, wait=False, ts=None):
    """Emite un tipo nuevo. `cause` = sobre padre (el hijo va un nivel más hondo) o {"id","depth"}. Valida el sobre
    (`EnvelopeError` si no cuadra) y lo devuelve con `seq`; None si `cause.depth` > MAX_DEPTH (anti-bucles)."""
    ts = time.time() if ts is None else float(ts)
    machine = _machine(cfg)
    env = envelope.build(type, project, body, severity, needs, subject, cause, machine, ts, id="0" * 26)
    if env["cause"]["depth"] > envelope.MAX_DEPTH:
        return None
    envelope.validate(env)
    f = {k: env[k] for k in ("type", "severity", "needs", "subject", "body")}
    stored = _store(conn, machine, [(type, f)], project, ts, env["cause"])
    _publish(conn, cfg, stored, poster, timeout, wait)
    return stored[0][1]


# ---------------------------------------------------------------- lectura

COLUMNS = "seq,ts,machine_id,event,project,body,id,type,severity,needs,subject_kind,subject_id,subject,cause_id,cause_depth"


def to_envelope(r):
    """Fila de `events` -> sobre (+ `event` y `machine_id` viejos). Filas sin columnas v3 se traducen al vuelo."""
    d = dict(r)
    body = db.jload(d.get("body"), {})
    body = body if isinstance(body, dict) else {}
    machine = d.get("machine_id")
    if d.get("type"):
        subj = db.jload(d.get("subject"), None) or {"kind": d.get("subject_kind") or "agent",
                                                     "id": d.get("subject_id") or "?"}
        typ, sev, needs = d["type"], d.get("severity") or "info", d.get("needs")
    else:
        f = envelope.from_legacy(d.get("event"), body, machine)
        typ, sev, needs, subj, body = f["type"], f["severity"], f["needs"], f["subject"], f["body"]
    return {"v": envelope.V, "id": d.get("id"), "seq": d["seq"], "ts": envelope.iso(d["ts"]), "machine": machine,
            "project": d.get("project"), "type": typ, "severity": sev, "needs": needs, "subject": subj,
            "cause": {"id": d.get("cause_id"), "depth": d.get("cause_depth") or 0}, "body": body,
            "event": d.get("event"), "machine_id": machine}


def list_after(conn, after=0, limit=200):
    """Sobres con seq > after, del más viejo al más nuevo."""
    limit = max(1, min(int(limit), MAX_LIMIT))
    with db.tx():
        cur = conn.execute("SELECT %s FROM events WHERE seq>? ORDER BY seq LIMIT ?" % COLUMNS, (int(after), limit))
        return [to_envelope(r) for r in cur.fetchall()]


def recent(conn, limit=80):
    """Últimos sobres, el más nuevo primero (para el snapshot)."""
    limit = max(1, min(int(limit), MAX_LIMIT))
    with db.tx():
        cur = conn.execute("SELECT %s FROM events ORDER BY seq DESC LIMIT ?" % COLUMNS, (limit,))
        return [to_envelope(r) for r in cur.fetchall()]


def last_seq(conn):
    with db.tx():
        return conn.execute("SELECT COALESCE(MAX(seq),0) FROM events").fetchone()[0]


# ---------------------------------------------------------------- suscripciones

def subscribe(conn, name, webhook_file, project="*", events=None):
    """Crea o actualiza una suscripción. `webhook_file` es una RUTA; se rechaza una URL para que nunca llegue a la DB."""
    if not isinstance(name, str) or not _NAME.match(name):
        raise EventsError("nombre de suscripción inválido")
    if not isinstance(webhook_file, str) or not webhook_file.strip():
        raise EventsError("webhook_file debe ser la ruta de un archivo")
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", webhook_file.strip()):
        raise EventsError("webhook_file debe ser una ruta de archivo, no una URL")
    if events is None:
        events = []
    if isinstance(events, str):
        events = [events]
    if not isinstance(events, (list, tuple)) or not all(isinstance(e, str) and e for e in events):
        raise EventsError("events debe ser una lista de nombres de evento")
    project = project or "*"
    with db.tx():
        old = conn.execute("SELECT created FROM subscriptions WHERE name=?", (name,)).fetchone()
        conn.execute("INSERT OR REPLACE INTO subscriptions(name,webhook_file,project,events,created) VALUES(?,?,?,?,?)",
                     (name, webhook_file.strip(), project, db.jdump(list(events)), old["created"] if old else time.time()))


def unsubscribe(conn, name):
    """Borra la suscripción. True si existía."""
    with db.tx():
        return conn.execute("DELETE FROM subscriptions WHERE name=?", (name,)).rowcount > 0


def list_subscriptions(conn):
    """{nombre: {"project","events","created"}}. Sin URL y sin ruta del archivo."""
    with db.tx():
        rs = db.rows(conn.execute("SELECT name, project, events, created FROM subscriptions ORDER BY name"))
    return {r["name"]: {"project": r["project"], "events": db.jload(r["events"], []), "created": r["created"]} for r in rs}


# ---------------------------------------------------------------- migración del motor viejo

def _legacy_ts(v):
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    try:
        return datetime.datetime.strptime(str(v), "%Y-%m-%dT%H:%M:%S%z").timestamp()
    except ValueError:
        return time.time()


def import_legacy(conn, path, machine_id=None):
    """Importa `events.jsonl` del motor viejo (una línea JSON por evento: event, project, ts ISO + cuerpo + delivery).
    Idempotente: guarda en `meta` el desplazamiento ya leído (relee solo lo añadido después) y además omite líneas
    cuyo (ts, event, project) ya esté en `events`. Devuelve {"imported": n, "skipped": m}."""
    path = os.path.expanduser(path)
    res = {"imported": 0, "skipped": 0}
    if not os.path.isfile(path):
        return res
    machine = machine_id or socket.gethostname()
    with db.tx():
        row = conn.execute("SELECT value FROM meta WHERE key=?", (LEGACY_KEY,)).fetchone()
        try:
            offset = int(row["value"]) if row else 0
        except ValueError:
            offset = 0
        if offset > os.path.getsize(path):             # archivo rotado o truncado: se relee y deduplica
            offset = 0
        with open(path, "rb") as f:
            f.seek(offset)
            chunk = f.read()
        end = chunk.rfind(b"\n") + 1                     # solo líneas completas
        conn.execute("BEGIN IMMEDIATE")
        try:
            for raw in chunk[:end].splitlines():
                if not raw.strip():
                    continue
                try:
                    o = json.loads(raw.decode("utf-8"))
                    event = o["event"]
                    if not isinstance(o, dict) or not isinstance(event, str) or not event:
                        raise ValueError
                except (ValueError, KeyError, TypeError):
                    res["skipped"] += 1
                    continue
                project = o.get("project")
                ts = _legacy_ts(o.get("ts"))
                if conn.execute("SELECT 1 FROM events WHERE ts=? AND event=? AND project IS ?",
                                (ts, event, project)).fetchone():
                    res["skipped"] += 1
                    continue
                body = {k: v for k, v in o.items() if k not in ("event", "project", "ts", "delivery")}
                main = envelope.from_legacy(event, body, machine)
                for name, f in [(c["type"], c) for c in envelope.companions(main)] + [(event, main)]:
                    env = envelope.build(f["type"], project, f["body"], f["severity"], f["needs"], f["subject"], None,
                                         machine, ts)
                    _insert(conn, env, name, ts)
                res["imported"] += 1
            conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (LEGACY_KEY, str(offset + end)))
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
    return res
