ACTIVE = ("queued", "preparing", "running", "waiting")
HALF_LIFE_S = 1800
_FROM_TASK = ("title", "phase", "attention", "ended_at", "touched_at")


def _occupies_desk(p, thread_id):
    for fl in (p.get("office") or {}).get("floors") or []:
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
