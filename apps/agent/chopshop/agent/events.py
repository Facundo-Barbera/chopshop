"""Eventos del agente: registro monotónico en SQLite (`events`) y entrega por webhook (`subscriptions` + `cfg["webhook_files"]`).

- Cada fila es un sobre (`agent/envelope.py`, columnas v3): `emit(event, project, body)` acepta el nombre viejo y lo traduce
  (`LEGACY_MAP`, `body.legacy`); `emit_envelope(type, ...)` emite tipos nuevos con `subject`/`needs`/`severity`/`cause`.
  `list_after`/`recent` devuelven sobres (+ `event` y `machine_id` viejos). El webhook recibe el sobre + `event`/`machine_id`.
- `emit` inserta y devuelve `seq`; la entrega (filtros v2, reintentos, firma: ver `webhooks.py`) va por hilos de fondo
  (no bloquea) y deja su resultado en `deliveries`.
- La URL del webhook se lee del archivo (primera línea) en cada entrega; nunca se guarda, se imprime ni se registra.
  `deliveries.detail` solo lleva `HTTP <código>` o el NOMBRE del tipo de excepción (los mensajes de urllib pueden traer la URL).
- Todo es inyectable: `poster(url, payload_bytes, timeout, headers=None) -> código HTTP` (por defecto urllib; los
  posters de 3 argumentos siguen valiendo, sin cabeceras) y el despachador (`set_dispatcher`, reloj), para tests sin red."""
import datetime
import json
import os
import re
import socket
import time
import urllib.error
import urllib.request

from . import USER_AGENT, db, envelope, webhooks

TIMEOUT = 3                       # segundos por POST
MAX_LIMIT = 1000                  # tope de list_after
LEGACY_KEY = "events_legacy_offset"
_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


class EventsError(Exception):
    pass


# ---------------------------------------------------------------- entrega

def _default_poster(url, data, timeout, headers=None):
    """POST JSON con urllib. Devuelve el código HTTP (también para 4xx/5xx); el resto de fallos se propagan."""
    h = {"Content-Type": "application/json", "User-Agent": USER_AGENT}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


_dispatcher = webhooks.Dispatcher()


def dispatcher():
    return _dispatcher


def set_dispatcher(d):
    """Cambia el despachador del proceso (tests con reloj falso). Devuelve el anterior."""
    global _dispatcher
    old, _dispatcher = _dispatcher, d
    return old


def flush(timeout=10):
    """Espera a que terminen las entregas en curso (no los reintentos programados). True si quedó vacía."""
    return _dispatcher.flush(timeout)


def cancel_pending():
    """Descarta reintentos y entregas retenidas por debounce (apagado, tests)."""
    _dispatcher.cancel()


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
                                 machine, ts, id=f.get("id"))
            out.append((event, _insert(conn, env, event, ts)))
    return out


def payload(env, event=None):
    """Lo que recibe un webhook: el sobre + los campos viejos `event` y `machine_id` (compatibilidad un ciclo)."""
    return dict(env, event=event or (env.get("body") or {}).get("legacy") or env["type"], machine_id=env["machine"])


def _subscriptions(conn):
    with db.tx():
        return [webhooks.effective(r) for r in db.rows(conn.execute("SELECT * FROM subscriptions ORDER BY name"))]


def _publish(conn, cfg, stored, poster, timeout, wait):
    """Entrega cada sobre guardado a los destinos cuyo filtro casa (`webhooks.Dispatcher`: filtros v2, debounce,
    reintentos). `cfg["webhook_files"]` = destinos sin filtro (una suscripción del mismo nombre que case los pisa)."""
    fixed = {str(n): f for n, f in (cfg.get("webhook_files") or {}).items() if f}
    subs = _subscriptions(conn)
    if not (fixed or subs):
        return
    d, n = _dispatcher, 0
    for event, env in stored:
        n += len(d.dispatch(conn, subs, fixed, payload(env, event), poster or _default_poster, timeout))
    if wait and n:
        d.flush(timeout * (n + 1))


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
                  cause=None, poster=None, timeout=TIMEOUT, wait=False, ts=None, id=None):
    """Emite un tipo nuevo. `cause` = sobre padre (el hijo va un nivel más hondo) o {"id","depth"}. Valida el sobre
    (`EnvelopeError` si no cuadra) y lo devuelve con `seq`; None si `cause.depth` > MAX_DEPTH (anti-bucles)."""
    ts = time.time() if ts is None else float(ts)
    machine = _machine(cfg)
    env = envelope.build(type, project, body, severity, needs, subject, cause, machine, ts, id="0" * 26)
    if env["cause"]["depth"] > envelope.MAX_DEPTH:
        return None
    envelope.validate(env)
    f = {k: env[k] for k in ("type", "severity", "needs", "subject", "body")}
    stored = _store(conn, machine, [(type, dict(f, id=id))], project, ts, env["cause"])
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

def subscribe(conn, name, webhook_file, project="*", events=None, **opts):
    """Crea o actualiza (reemplaza) una suscripción. `webhook_file` y `secret_file` son RUTAS; se rechaza una URL para
    que nunca llegue a la DB. `opts` = filtros v2 (`webhooks.FIELDS`); sin ellos, la suscripción es vieja
    (`project` exacto o `*` + nombres de `events`)."""
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
    unknown = set(opts) - set(webhooks.FIELDS) - {"batch_window_s"}      # batch_window_s: solo 0 en v1
    if unknown:
        raise EventsError("opciones desconocidas: %s" % ", ".join(sorted(unknown)))
    try:
        v2 = webhooks.validate(opts)                  # no guarda batch_window_s (rechaza > 0)
    except webhooks.WebhookError as e:
        raise EventsError(str(e))
    project = project or "*"
    cols = ["name", "webhook_file", "project", "events", "created"] + list(webhooks.FIELDS)
    with db.tx():
        old = conn.execute("SELECT created FROM subscriptions WHERE name=?", (name,)).fetchone()
        vals = [name, webhook_file.strip(), project, db.jdump(list(events)), old["created"] if old else time.time()]
        for k in webhooks.FIELDS:
            v = v2[k]
            vals.append(db.jdump(v) if k in webhooks.JSON_FIELDS and v is not None
                        else (int(v) if isinstance(v, bool) else v))
        conn.execute("INSERT OR REPLACE INTO subscriptions(%s) VALUES(%s)" % (",".join(cols), ",".join("?" * len(cols))),
                     vals)


def unsubscribe(conn, name):
    """Borra la suscripción. True si existía."""
    with db.tx():
        return conn.execute("DELETE FROM subscriptions WHERE name=?", (name,)).rowcount > 0


def list_subscriptions(conn):
    """{nombre: {"project","events","created", filtros v2..., "signed"}}. Sin URL y sin rutas de archivos."""
    with db.tx():
        rs = db.rows(conn.execute("SELECT * FROM subscriptions ORDER BY name"))
    out = {}
    for r in rs:
        out[r["name"]] = dict({"project": r["project"], "events": db.jload(r["events"], []), "created": r["created"]},
                              **webhooks.public(webhooks.effective(r)))
    return out


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
