"""Vestíbulo (planta baja de cada edificio): regla `apply` de `GET /state.lobby` (docs/agent-api.md, «`api_version 3`»).

Entran los hilos **activos sin rol** y los que **esperan escritorio** (con `waiting_role`); nunca los que ocupan un escritorio.
- `task.state` → si el hilo no ocupa escritorio de su proyecto: con `role` nulo y fase activa entra o se refresca; si ya
  estaba se refresca también en fase terminal (ahí se desvanece con la semivida); terminal y fuera del vestíbulo no entra.
- `desk.waiting` → upsert con `waiting_role = role` (resto de campos desde la última `task.state` del hilo).
- `desk.assigned` (sube a su escritorio) y `desk.released` con `desk: null` (salió del vestíbulo) → el hilo sale.
`company` y `half_life_s` salen del `office` del proyecto (o `null` y 1800). Orden: `(company, project, since)`.
Pura sobre `state` (la llama `projection._apply` en sitio); la misma regla aplica `LiveState.swift`."""

ACTIVE = ("queued", "preparing", "running", "waiting")
HALF_LIFE_S = 1800
_FROM_TASK = ("title", "phase", "attention", "ended_at", "touched_at")


def _occupies_desk(p, thread_id):
    office = p.get("office") or {}
    for fl in (office.get("floors") or []) + ((office.get("outsourced") or {}).get("floors") or []):
        for room in fl.get("rooms") or []:
            for d in room.get("desks") or []:
                if (d.get("occupant") or {}).get("thread_id") == thread_id:
                    return True
    return False


def _last_task(p, thread_id):
    ts = [t for t in p.get("tasks") or [] if t.get("thread_id") == thread_id]
    return max(ts, key=lambda t: t.get("seq") or 0) if ts else None


def _remove(state, thread_id):
    state["lobby"] = [x for x in state["lobby"] if x["thread_id"] != thread_id]


def _upsert(state, p, thread_id, src, ts, waiting_role):
    office = p.get("office") or {}
    old = next((x for x in state["lobby"] if x["thread_id"] == thread_id), None)
    item = {"thread_id": thread_id, "project": p["name"], "company": office.get("company"),
            "half_life_s": office.get("half_life_s") or HALF_LIFE_S, "waiting_role": waiting_role,
            "since": old["since"] if old else ts}
    item.update({k: src.get(k) for k in _FROM_TASK})
    _remove(state, thread_id)
    state["lobby"].append(item)
    state["lobby"].sort(key=lambda x: (x["company"] or "", x["project"] or "", x["since"] or ""))


def apply(state, p, env):
    """Aplica `env` al vestíbulo de `state` (en sitio); `p` es el proyecto del sobre ya actualizado con él."""
    state.setdefault("lobby", [])
    typ, body = env.get("type") or "", env.get("body") or {}
    tid = body.get("thread_id")
    if not tid:
        return
    if typ == "task.state":
        inside = any(x["thread_id"] == tid for x in state["lobby"])
        if _occupies_desk(p, tid):
            if inside:
                _remove(state, tid)
        elif inside or (body.get("role") is None and body.get("phase") in ACTIVE):
            old = next((x for x in state["lobby"] if x["thread_id"] == tid), {})
            _upsert(state, p, tid, body, env.get("ts"), old.get("waiting_role"))
    elif typ == "desk.waiting":
        src = _last_task(p, tid) or {"title": body.get("title"), "phase": body.get("phase") or "running"}
        _upsert(state, p, tid, src, env.get("ts"), body.get("role"))
    elif typ == "desk.assigned" or (typ == "desk.released" and body.get("desk") is None):
        _remove(state, tid)
