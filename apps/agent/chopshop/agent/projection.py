"""Proyección `state` (docs/agent-api.md, «GET /state»): lo que pinta la oficina, plegando sobres con la función pura `apply`.

- `apply(state, envelope) -> state` no muta su entrada y es la misma regla que aplica el cliente (app de Mac) a cada delta del
  `/stream`: `state(conn, cfg) == fold(apply, sobres)`. Es idempotente: un sobre con `seq <= head_seq` se ignora.
- Cada sobre trae el estado COMPLETO de su sujeto (upsert): `task.state` -> `tasks`, `batch.*` -> `batches`, `graph.*`/`node.state`
  -> `graphs`, `machine.health` -> `machine_health`.
- `attention` (por proyecto) = cola de sobres abiertos con `needs != null`: uno por sujeto (`kind:id`), lo cierra el siguiente sobre
  del mismo sujeto con `needs: null` (p. ej. `question.answered`, o `task.state` sin atención).
- `counts` por proyecto: running, queued, waiting, needs_human, waiting_bot, stuck, done, failed (ver `_counts`).
- `recent` = últimos 50 sobres, el más nuevo primero.
`to_envelope(row)` convierte una fila de `events` en sobre: usa `envelope.build` (contrato del bus) si existe; si no, una traducción
mínima de los nombres viejos (`thread_*`, `pending_question`, ...) para que la proyección funcione con lo que ya hay en la DB."""
import copy
import datetime

from . import db, events

API_VERSION = 2
RECENT = 50
PAGE = 1000
_RUNNING = ("running", "preparing")
_DONE = ("done", "settled")


# ---------------------------------------------------------------- filas -> sobres

def iso(ts):
    """epoch -> ISO-8601 UTC con milisegundos (`2026-10-29T16:12:03.412Z`); deja pasar textos."""
    if isinstance(ts, str) or ts is None:
        return ts
    return datetime.datetime.fromtimestamp(float(ts), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


_PHASE = {"thread_started": "running", "thread_done": "done", "thread_failed": "failed", "thread_settled": "settled"}


def _from_columns(row):
    """Sobre desde las columnas del esquema v3 del diseño (§2.3: id, type, severity, needs, subject_*, cause_*)."""
    body = dict(row.get("body") or {})
    extra = {k: body.pop("subject_" + k) for k in ("title", "url") if "subject_" + k in body}   # título/URL del sujeto
    subject = None
    if row.get("subject_id") is not None:
        subject = dict({"kind": row.get("subject_kind"), "id": row["subject_id"]}, **extra)
    cause = {"id": row["cause_id"], "depth": row.get("cause_depth") or 0} if row.get("cause_id") else None
    return {"v": 1, "id": row.get("id") or "%s:%s" % (row.get("machine_id"), row["seq"]), "seq": row["seq"],
            "ts": iso(row.get("ts")), "machine": row.get("machine_id"), "project": row.get("project"), "type": row["type"],
            "severity": row.get("severity") or "info", "needs": row.get("needs"), "subject": subject, "cause": cause, "body": body}


def _compat(row):
    """Sobre §2.1 a partir de una fila de `events`. Solo mientras no exista `agent/envelope.py` (tarea A): con las columnas v3
    usa `_from_columns`; con el esquema v2 (`event`, `body`) traduce los nombres viejos."""
    if row.get("type"):
        return _from_columns(row)
    ev, body = row.get("event"), dict(row.get("body") or {})
    body.setdefault("legacy", ev)
    tid = body.get("thread_id")
    subject = {"kind": "task", "id": tid, "title": body.get("title"), "url": body.get("link")} if tid else None
    typ, sev, needs = ev, "info", None
    if ev in _PHASE:
        typ = "task.state"
        body.setdefault("phase", _PHASE[ev])
        body.setdefault("attention", None)
        sev = "error" if ev == "thread_failed" else "info"
    elif ev == "pending_question":
        typ, sev, needs = "question.opened", "notice", body.get("level") if body.get("level") in ("human", "bot") else "human"
        qs = body.get("questions") or []
        if "summary" not in body and qs and isinstance(qs[0], dict):
            body["summary"] = qs[0].get("question")
    elif ev == "pending_approval":
        typ, sev, needs = "approval.requested", "notice", "approval"
    elif ev in ("t3_unreachable", "t3_recovered"):
        typ, sev = "machine.health", "warn" if ev == "t3_unreachable" else "info"
        body.setdefault("state", "degraded" if ev == "t3_unreachable" else "ok")
        body.setdefault("t3_ok", ev == "t3_recovered")
        subject = {"kind": "machine", "id": row.get("machine_id")}
    elif ev == "agent_started":
        typ, subject = "agent.started", {"kind": "agent", "id": row.get("machine_id")}
    if subject is not None:
        subject = {k: v for k, v in subject.items() if v is not None}
    return {"v": 1, "id": "%s:%s" % (row.get("machine_id"), row["seq"]), "seq": row["seq"], "ts": iso(row.get("ts")),
            "machine": row.get("machine_id"), "project": row.get("project"), "type": typ, "severity": sev, "needs": needs,
            "subject": subject, "cause": None, "body": body}


def to_envelope(row):
    """Fila de `events` (dict con `body` ya parseado) o sobre -> sobre."""
    if row.get("v") and row.get("type"):
        return row
    try:
        from . import envelope as env_mod                       # contrato del bus (tarea A), cuando exista
    except ImportError:
        env_mod = None
    if env_mod is not None and hasattr(env_mod, "build"):
        return env_mod.build(row)
    return _compat(row)


def envelopes_after(conn, after=0, limit=PAGE):
    """Sobres con seq > after, en orden (todas las columnas de `events`: las del sobre cuando existan)."""
    limit = max(1, min(int(limit), events.MAX_LIMIT))
    with db.tx():
        rows = db.rows(conn.execute("SELECT * FROM events WHERE seq>? ORDER BY seq LIMIT ?", (int(after), limit)))
    for r in rows:
        r["body"] = db.jload(r.get("body"), {})
    return [to_envelope(r) for r in rows]


def min_seq(conn):
    """Primer seq retenido (0 si no hay eventos)."""
    with db.tx():
        return conn.execute("SELECT COALESCE(MIN(seq),0) FROM events").fetchone()[0]


# ---------------------------------------------------------------- reductores

def empty(machine=None):
    return {"api_version": API_VERSION, "machine": machine, "head_seq": 0, "ts": None, "machine_health": None,
            "projects": [], "recent": []}


def _project(state, name):
    for p in state["projects"]:
        if p["name"] == name:
            return p
    p = {"name": name, "counts": {}, "batches": [], "tasks": [], "graphs": [], "attention": []}
    state["projects"].append(p)
    state["projects"].sort(key=lambda x: x["name"])
    return p


def _upsert(items, key, value, obj):
    for i, it in enumerate(items):
        if it.get(key) == value:
            items[i] = obj
            return
    items.append(obj)


def _clean(body):
    return {k: v for k, v in (body or {}).items() if k not in ("legacy", "context")}


def _subject_key(env):
    s = env.get("subject") or {}
    return "%s:%s" % (s.get("kind"), s.get("id")) if s.get("id") is not None else None


def _counts(p):
    """running (running/preparing), queued, waiting (sin atención), done (done/settled), failed, stuck (último sobre warn/error y
    sin terminar), needs_human (atención human/approval), waiting_bot (atención bot)."""
    c = dict.fromkeys(("running", "queued", "waiting", "stuck", "needs_human", "waiting_bot", "done", "failed"), 0)
    for t in p["tasks"]:
        ph = t.get("phase")
        if ph in _RUNNING:
            c["running"] += 1
        elif ph == "queued":
            c["queued"] += 1
        elif ph in _DONE:
            c["done"] += 1
        elif ph == "failed":
            c["failed"] += 1
        elif ph == "waiting" and not t.get("attention"):
            c["waiting"] += 1
        if t.get("severity") in ("warn", "error") and ph not in _DONE + ("failed", "skipped"):
            c["stuck"] += 1
    for a in p["attention"]:
        if a["needs"] == "bot":
            c["waiting_bot"] += 1
        else:
            c["needs_human"] += 1
    p["counts"] = c


def _apply(state, env):
    """Aplica en sitio (lo usan `fold` y `Projector`); `apply` es la versión pura."""
    seq = env.get("seq")
    if isinstance(seq, int) and seq <= state["head_seq"]:
        return state
    if isinstance(seq, int):
        state["head_seq"] = seq
    state["ts"] = env.get("ts") or state["ts"]
    typ, body, proj = env.get("type") or "", env.get("body") or {}, env.get("project")
    if typ == "machine.health":
        state["machine_health"] = dict(state["machine_health"] or {}, **_clean(body))
    p = _project(state, proj) if proj else None
    if p is not None:
        sid = (env.get("subject") or {}).get("id")
        if typ == "task.state" and sid is not None:
            _upsert(p["tasks"], "id", sid, dict(_clean(body), id=sid, severity=env.get("severity"), seq=seq, updated=env.get("ts")))
        elif typ.startswith("batch.") and body.get("batch"):
            old = next((b for b in p["batches"] if b["id"] == body["batch"]), {})
            new = dict(old, **{k: v for k, v in _clean(body).items() if k != "batch"})
            new.update(id=body["batch"], status=body.get("status") or ("done" if typ == "batch.done" else "running"))
            _upsert(p["batches"], "id", body["batch"], new)
        elif typ in ("graph.state", "graph.done") and body.get("graph"):
            new = dict({k: v for k, v in _clean(body).items() if k != "graph"}, id=body["graph"])
            if typ == "graph.done":
                new.setdefault("status", "done")
            _upsert(p["graphs"], "id", body["graph"], new)
        elif typ == "node.state" and body.get("graph"):
            node = body.get("node") if isinstance(body.get("node"), dict) else {k: v for k, v in _clean(body).items() if k != "graph"}
            g = next((x for x in p["graphs"] if x["id"] == body["graph"]), None)
            if g is None:
                g = {"id": body["graph"], "nodes": []}
                p["graphs"].append(g)
            g["nodes"] = list(g.get("nodes") or [])
            if node.get("id") is not None:
                _upsert(g["nodes"], "id", node["id"], dict(next((n for n in g["nodes"] if n.get("id") == node["id"]), {}), **node))
        key = _subject_key(env)
        if key is not None:
            old = next((a for a in p["attention"] if a["key"] == key), None)
            p["attention"] = [a for a in p["attention"] if a["key"] != key]
            if env.get("needs"):
                p["attention"].append({
                    "key": key, "id": env.get("id"), "seq": seq, "type": typ, "needs": env["needs"],
                    "severity": env.get("severity"), "subject": env.get("subject"),
                    "since": old["since"] if old else env.get("ts"),
                    "summary": body.get("summary") or body.get("note") or (env.get("subject") or {}).get("title")})
                p["attention"].sort(key=lambda a: (a["seq"] or 0))
        _counts(p)
    state["recent"] = [env] + state["recent"][:RECENT - 1]
    return state


def apply(state, env):
    """Función pura: estado nuevo con el sobre aplicado (no muta `state` ni `env`)."""
    return _apply(copy.deepcopy(state), copy.deepcopy(env))


def fold(envs, machine=None, state=None):
    st = copy.deepcopy(state) if state is not None else empty(machine)
    for e in envs:
        _apply(st, copy.deepcopy(e))
    return st


def state(conn, cfg):
    """Proyección completa desde SQLite (todos los eventos retenidos)."""
    st = empty(cfg.get("machine_id"))
    after = 0
    while True:
        page = envelopes_after(conn, after, PAGE)
        for e in page:
            _apply(st, e)
        if len(page) < PAGE:
            return st
        after = page[-1]["seq"]


def filter_project(st, project):
    """Copia del estado con solo ese proyecto (y `recent` de ese proyecto). `machine_health` se mantiene."""
    out = dict(st)
    out["projects"] = [p for p in st["projects"] if p["name"] == project]
    out["recent"] = [e for e in st["recent"] if e.get("project") == project]
    return out


class Projector:
    """Proyección incremental compartida (SSE y `GET /state`): pliega solo los sobres nuevos desde la última vez."""

    def __init__(self, conn, cfg):
        import threading
        self.conn, self.cfg = conn, cfg
        self._lock = threading.Lock()
        self._state = empty(cfg.get("machine_id"))

    def current(self):
        """Copia del estado al día (su `head_seq` es exactamente el último sobre incluido)."""
        with self._lock:
            while True:
                page = envelopes_after(self.conn, self._state["head_seq"], PAGE)
                for e in page:
                    _apply(self._state, e)
                if len(page) < PAGE:
                    break
            return copy.deepcopy(self._state)
