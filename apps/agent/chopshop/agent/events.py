"""Eventos del agente: registro monotónico en SQLite (`events`) y entrega por webhook (`subscriptions` + `cfg["webhook_files"]`).

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

from . import db

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


def _matches(project, events, event, proj):
    return project in ("*", proj) and (not events or event in events)


def _targets(conn, cfg, event, project):
    """{nombre: archivo}: webhook_files de la config (sin filtro) + suscripciones cuyo filtro coincide (pisan al mismo nombre)."""
    out = {str(n): f for n, f in (cfg.get("webhook_files") or {}).items() if f}
    with db.tx():
        subs = db.rows(conn.execute("SELECT name, webhook_file, project, events FROM subscriptions"))
    for s in subs:
        if _matches(s["project"], db.jload(s["events"], []), event, project):
            out[s["name"]] = s["webhook_file"]
    return out


def emit(conn, cfg, event, project, body=None, poster=None, timeout=TIMEOUT, wait=False):
    """Registra el evento y devuelve `seq`. La entrega es asíncrona (`wait=True` espera a que termine, para CLI/tests)."""
    ts = time.time()
    machine = cfg.get("machine_id") or socket.gethostname()
    with db.tx():
        cur = conn.execute("INSERT INTO events(ts,machine_id,event,project,body) VALUES(?,?,?,?,?)",
                           (ts, machine, event, project, db.jdump(body or {})))
        seq = cur.lastrowid
    targets = _targets(conn, cfg, event, project)
    if targets:
        data = db.jdump({"seq": seq, "ts": ts, "machine_id": machine, "event": event, "project": project,
                         "body": body or {}}).encode("utf-8")
        post = poster or _default_poster
        for name, wfile in targets.items():
            def job(name=name, wfile=wfile):
                ok, detail = _deliver(wfile, data, post, timeout)
                _record(conn, seq, name, ok, detail)
            _queue.put(job)
        if wait:
            _queue.flush(timeout * (len(targets) + 1))
    return seq


# ---------------------------------------------------------------- lectura

def _row(r):
    d = dict(r)
    d["body"] = db.jload(d.get("body"), {})
    return d


def list_after(conn, after=0, limit=200):
    """Eventos con seq > after, del más viejo al más nuevo, con `body` ya parseado."""
    limit = max(1, min(int(limit), MAX_LIMIT))
    with db.tx():
        cur = conn.execute("SELECT seq,ts,machine_id,event,project,body FROM events WHERE seq>? ORDER BY seq LIMIT ?",
                           (int(after), limit))
        return [_row(r) for r in cur.fetchall()]


def recent(conn, limit=80):
    """Últimos eventos, el más nuevo primero (para el snapshot)."""
    limit = max(1, min(int(limit), MAX_LIMIT))
    with db.tx():
        cur = conn.execute("SELECT seq,ts,machine_id,event,project,body FROM events ORDER BY seq DESC LIMIT ?", (limit,))
        return [_row(r) for r in cur.fetchall()]


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
                conn.execute("INSERT INTO events(ts,machine_id,event,project,body) VALUES(?,?,?,?,?)",
                             (ts, machine, event, project, db.jdump(body)))
                res["imported"] += 1
            conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (LEGACY_KEY, str(offset + end)))
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
    return res
