"""Proyección `state` (docs/agent-api.md, «GET /state»): lo que pinta la oficina, plegando sobres con la función pura `apply`.

- `apply(state, envelope) -> state` no muta su entrada y es la misma regla que aplica el cliente (app de Mac) a cada delta del
  `/stream`: `state(conn, cfg) == fold(apply, sobres)`. Es idempotente: un sobre con `seq <= head_seq` se ignora.
- Cada sobre trae el estado COMPLETO de su sujeto (upsert): `task.state` -> `tasks`, `batch.*` -> `batches`, `graph.*`/`node.state`
  -> `graphs`, `machine.health` -> `machine_health`.
- `attention` (por proyecto) = cola de sobres abiertos con `needs != null`: uno por sujeto (`kind:id`), lo cierra el siguiente sobre
  del mismo sujeto con `needs: null` (p. ej. `question.answered`, o `task.state` sin atención). `reaction.applied` y
  `automation.ran` no abren ni cierran (describen una acción, no el estado del sujeto).
- `counts` por proyecto: running, queued, waiting, needs_human, waiting_bot, stuck, done, failed (ver `_counts`).
- `recent` = últimos 50 sobres, el más nuevo primero.
- `machine_room` (v3): listeners, automatizaciones y rack de la sala de máquinas (`machine_room.py`); sus `subscriptions` las
  rellena `Projector.current()` desde SQLite (no vienen de sobres).
Los sobres salen de `events.list_after` (contrato del bus, docs/event-envelope.md)."""
import copy
import threading

from . import db, events, machine_room

API_VERSION = 3
RECENT = 50
PAGE = 1000
_RUNNING = ("running", "preparing")
_DONE = ("done", "settled")
NO_ATTENTION = ("reaction.applied", "automation.ran")   # cuentan lo que se hizo, no el estado del sujeto: no abren ni cierran


# ---------------------------------------------------------------- filas -> sobres

def to_envelope(env):
    """Sobre de `events.list_after` -> sobre §2.1 (sin los campos viejos `event`/`machine_id` que añade para /events)."""
    return {k: v for k, v in env.items() if k not in ("event", "machine_id")}


def envelopes_after(conn, after=0, limit=PAGE):
    """Sobres con seq > after, en orden."""
    return [to_envelope(e) for e in events.list_after(conn, after, limit)]


def min_seq(conn):
    """Primer seq retenido (0 si no hay eventos)."""
    with db.tx():
        return conn.execute("SELECT COALESCE(MIN(seq),0) FROM events").fetchone()[0]


# ---------------------------------------------------------------- reductores

def empty(machine=None):
    return {"api_version": API_VERSION, "machine": machine, "head_seq": 0, "ts": None, "machine_health": None,
            "projects": [], "recent": [], "machine_room": machine_room.empty()}


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
        state["machine_health"] = _clean(body)
    machine_room.apply(state, env)
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
            old = next((g for g in p["graphs"] if g["id"] == body["graph"]), {})      # graph.done puede venir sin nodos
            new = dict(old, **{k: v for k, v in _clean(body).items() if k != "graph"})
            new["id"] = body["graph"]
            if typ == "graph.done":
                new.setdefault("status", "done")
            _upsert(p["graphs"], "id", body["graph"], new)
        elif typ == "node.state" and body.get("graph"):
            node = body.get("node")                      # cuerpo plano: {"graph","node": id, label, phase, deps, task}
            node = node if isinstance(node, dict) else dict(
                {k: v for k, v in _clean(body).items() if k not in ("graph", "node")}, id=node)
            g = next((x for x in p["graphs"] if x["id"] == body["graph"]), None)
            if g is None:
                g = {"id": body["graph"], "nodes": []}
                p["graphs"].append(g)
            g["nodes"] = list(g.get("nodes") or [])
            if node.get("id") is not None:
                _upsert(g["nodes"], "id", node["id"], dict(next((n for n in g["nodes"] if n.get("id") == node["id"]), {}), **node))
        key = _subject_key(env) if typ not in NO_ATTENTION else None
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
    if "machine_room" in st:
        out["machine_room"] = machine_room.filter_project(st["machine_room"], project)
    return out


class Projector:
    """Proyección incremental compartida (SSE y `GET /state`): pliega solo los sobres nuevos desde la última vez."""

    def __init__(self, conn, cfg):
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
            return machine_room.live(copy.deepcopy(self._state), self.conn)
