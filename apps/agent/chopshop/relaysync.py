import base64
import hashlib
import json
import re

from .agent import __version__ as AGENT_VERSION
from .agent import envelope, layout

PROTOCOL = [1]
PROTOCOL_V2 = [2]
TTL_DEFAULT = 120
TTL_MIN, TTL_MAX = 30, 900
MAX_PART_BYTES = 786432
MAX_EVENTS = 80
MAX_QUEUE_ITEMS = 100
TITLE_MAX, SUMMARY_MAX, TEXT_MAX = 120, 280, 120

COUNT_KEYS = ("running", "queued", "waiting", "stuck", "needs_human", "waiting_bot", "done", "failed")
BODY_KEYS = ("phase", "attention", "settled", "title", "role", "summary", "state", "light", "status", "conclusion", "count",
             "desk", "reason", "zone", "employee", "task", "thread_id", "name", "items", "position", "queue_len", "since", "by",
             "trigger")
HEALTH_STATES = ("ok", "degraded", "down")
PHASES = envelope.PHASES
ATTENTION = envelope.ATTENTION

_MACHINE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
_TYPE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$")
_ULID = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")
_SUBJECT = re.compile(r"^[A-Za-z0-9_.:#@-]([A-Za-z0-9_.:#@/-]{0,127})$")
_SECRETISH = re.compile(r"(cs1_|cr1_|cm1_|t3-thread:|://|^[/~]|\\)")
_EMPLOYEE = re.compile(r"^[^/\s]+/[0-9]+/[a-z0-9][a-z0-9_-]{0,31}/[0-9]+$")
_TASK = re.compile(r"^q:[0-7][0-9A-HJKMNP-TV-Z]{25}$")
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _name(v):
    return v if isinstance(v, str) and _NAME.match(v) else None


def _text(v, n=TEXT_MAX):
    if not isinstance(v, str) or not v or _SECRETISH.search(v):
        return None
    return v[:n]


def _scalar(v):
    if v is None or isinstance(v, (bool, int, float)):
        return v
    return _text(v)


def _count(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0


def _pct(v):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return 0.0
    return 0.0 if v != v else max(0.0, min(100.0, v))


def _ts(v):
    t = envelope.epoch(v)
    return envelope.iso(t) if t is not None else None


def key(machine_id, ident):
    if ident is None:
        return None
    digest = hashlib.sha256(("%s\x00%s" % (machine_id, ident)).encode("utf-8")).hexdigest()
    return "k-" + digest[:16]


def part(name, obj):
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(raw) > MAX_PART_BYTES:
        return None
    return {"name": name, "media_type": "application/json", "enc": "none", "bytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(), "data": base64.b64encode(raw).decode("ascii")}


def decode(p):
    return json.loads(base64.b64decode(p["data"]).decode("utf-8"))


def _header(type, ts=None, v=1):
    return {"v": v, "type": type, "id": envelope.new_id(ts), "ts": envelope.iso(ts)}


def _machine(machine_id):
    if not isinstance(machine_id, str) or not _MACHINE.match(machine_id):
        raise ValueError("machine_id inválido para el relay")
    return machine_id


def _roles(roles):
    out = []
    for r in roles or ():
        if _name(r) and r not in out:
            out.append(r)
    return out[:64]


def roles_from_profiles(profiles):
    out = {}
    for prof in profiles or ():
        name = _name((prof or {}).get("project"))
        if name:
            out[name] = _roles(sorted(layout.roles(prof)))
    return out


def workspace_id(v):
    return v if isinstance(v, str) and _UUID.match(v) else None


def workspace_map(sync):
    sync = sync if isinstance(sync, dict) else {}
    ids = []
    for w in sync.get("workspaces") or ():
        wid = workspace_id((w or {}).get("id")) if isinstance(w, dict) else None
        if wid and wid not in ids:
            ids.append(wid)
    projects = {}
    for p in sync.get("projects") or ():
        if not isinstance(p, dict):
            continue
        name, wid = _name(p.get("name")), workspace_id(p.get("workspace_id"))
        if name and wid:
            projects[name] = wid
            if wid not in ids:
                ids.append(wid)
    return ids, projects


def hello(machine_id, projects, last_seq=None, ts=None, version=AGENT_VERSION, v=1):
    msg = dict(_header("hello", ts, v), machine_id=_machine(machine_id), agent_version=version,
               protocol=list(PROTOCOL_V2 if v == 2 else PROTOCOL))
    if isinstance(last_seq, int) and last_seq >= 0:
        msg["last_seq"] = last_seq
    msg["projects"] = [{"name": n, "roles": _roles(r)} for n, r in sorted((projects or {}).items()) if _name(n)][:256]
    return msg


def _employee(v):
    return v if isinstance(v, str) and _EMPLOYEE.match(v) and not _SECRETISH.search(v) else None


def _task(v):
    return v if isinstance(v, str) and _TASK.match(v) else None


def _queue_items(items):
    out = []
    for it in items if isinstance(items, list) else ():
        if isinstance(it, dict) and _task(it.get("task")):
            out.append({"task": it["task"], "title": _text(it.get("title"), TITLE_MAX), "enqueued_at": _ts(it.get("enqueued_at")),
                        "by": _text(it.get("by")), "trigger": _text(it.get("trigger"))})
        if len(out) >= MAX_QUEUE_ITEMS:
            break
    return out


def body(b, machine_id=None):
    b = b if isinstance(b, dict) else {}
    out = {}
    for k in BODY_KEYS:
        if k not in b:
            continue
        v = b[k]
        if k == "title":
            v = _text(v, TITLE_MAX)
        elif k == "summary":
            v = _text(v, SUMMARY_MAX)
        elif k == "employee":
            v = _employee(v)
        elif k == "task":
            v = _task(v)
        elif k == "thread_id":
            v = key(machine_id, v)
        elif k == "items":
            v = _queue_items(v)
        elif k == "since":
            v = _ts(v)
        elif k in ("position", "queue_len"):
            v = v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None
        else:
            v = _scalar(v)
        if v is not None or b[k] is None:
            out[k] = v
    return out


def _subject(machine_id, s):
    s = s if isinstance(s, dict) else {}
    kind = s.get("kind") if s.get("kind") in envelope.SUBJECT_KINDS else "machine"
    sid = s.get("id")
    if not (isinstance(sid, str) and _SUBJECT.match(sid) and not _SECRETISH.search(sid)):
        sid = key(machine_id, sid) or machine_id
    return {"kind": kind, "id": sid}


def event_fields(env, machine_id=None):
    if not isinstance(env, dict) or not _TYPE.match(str(env.get("type") or "")):
        return None
    mid = _machine(machine_id or env.get("machine"))
    eid, seq, ets = env.get("id"), env.get("seq"), _ts(env.get("ts"))
    if not (isinstance(eid, str) and _ULID.match(eid)) or ets is None:
        return None
    return {"machine_id": mid, "event_id": eid, "seq": _count(seq), "event_ts": ets, "project": _name(env.get("project")),
            "event_type": env["type"],
            "severity": env.get("severity") if env.get("severity") in envelope.SEVERITIES else "info",
            "needs": env.get("needs") if env.get("needs") in envelope.NEEDS_VALUES else None,
            "subject": _subject(mid, env.get("subject"))}


def event(env, machine_id=None, ts=None, v=1, workspaces=None):
    fields = event_fields(env, machine_id)
    if fields is None:
        return None
    msg = dict(_header("event", ts, v), **fields, body=part("body", body(env.get("body"), fields["machine_id"])))
    if v == 2:
        msg["workspace_id"] = (workspaces or {}).get(fields["project"]) if fields["project"] else None
    return msg


def events_from_bus(conn, after=0, limit=200, machine_id=None, ts=None):
    from .agent import events as bus
    out = []
    for env in bus.list_after(conn, after, limit):
        msg = event(env, machine_id, ts)
        if msg is not None:
            out.append(msg)
    return out


def _desks(office):
    for f in (office or {}).get("floors") or []:
        for r in f.get("rooms") or []:
            for d in r.get("desks") or []:
                yield f, r, d


def _seats(state):
    seats = {}
    for p in (state or {}).get("projects") or []:
        for _f, r, d in _desks(p.get("office")):
            occ = d.get("occupant") or {}
            if occ.get("thread_id"):
                seats[occ["thread_id"]] = (occ.get("role") or r.get("role"), d.get("id"))
    return seats


def _thread_rows(snap, state):
    rows = {}
    for p in (state or {}).get("projects") or []:
        for t in p.get("tasks") or []:
            tid = t.get("thread_id") or t.get("id")
            if tid:
                rows[tid] = {"project": p.get("name"), "title": t.get("title"), "phase": t.get("phase"),
                             "attention": t.get("attention"), "updated": t.get("updated")}
    for t in (snap or {}).get("threads") or []:
        tid = t.get("thread_id")
        if not tid:
            continue
        attention = "ask" if t.get("pending") else (rows.get(tid) or {}).get("attention")
        rows[tid] = {"project": t.get("project"), "title": t.get("title"),
                     "phase": envelope.phase_for(t.get("status"), t.get("settled")), "attention": attention,
                     "updated": t.get("updated")}
    return rows


def _state_part(machine_id, snap, state):
    seats = _seats(state)
    threads = []
    for tid, t in _thread_rows(snap, state).items():
        role, desk = seats.get(tid, (None, None))
        threads.append({"key": key(machine_id, tid), "project": _name(t["project"]), "title": _text(t["title"], TITLE_MAX),
                        "phase": t["phase"] if t["phase"] in PHASES else None,
                        "attention": t["attention"] if t["attention"] in ATTENTION else None,
                        "role": _name(role), "desk": _text(desk), "updated": _ts(t["updated"])})
    attention = []
    for p in (state or {}).get("projects") or []:
        for a in p.get("attention") or []:
            attention.append({"key": key(machine_id, a.get("key") or a.get("id")), "project": _name(p.get("name")),
                              "needs": a.get("needs") if a.get("needs") in envelope.NEEDS_VALUES else None,
                              "summary": _text(a.get("summary"), SUMMARY_MAX)})
    seen = {a["key"] for a in attention}
    for q in (snap or {}).get("pending_questions") or []:
        k = key(machine_id, q.get("thread_id"))
        if k not in seen:
            seen.add(k)
            attention.append({"key": k, "project": _name(q.get("project")), "needs": "human", "summary": None})
    return {"threads": threads, "attention": attention}


def _queue_part(machine_id, snap, state):
    seats, items = _seats(state), []
    for tid, t in _thread_rows(snap, state).items():
        if t["phase"] == "queued":
            items.append({"key": key(machine_id, tid), "project": _name(t["project"]), "role": _name(seats.get(tid, (None,))[0]),
                          "title": _text(t["title"], TITLE_MAX), "phase": "queued", "position": len(items) + 1})
    return {"items": items}


def _events_part(machine_id, snap, state):
    envs = (snap or {}).get("events") or (state or {}).get("recent") or []
    out = []
    for env in envs:
        fields = event_fields(env, machine_id)
        if fields is not None:
            out.append(dict(fields, body=body(env.get("body"), machine_id)))
        if len(out) >= MAX_EVENTS:
            break
    return {"events": out}


def _office_part(machine_id, state):
    floors, companies = [], set()
    for p in (state or {}).get("projects") or []:
        office = p.get("office")
        if not office:
            continue
        companies.add(_text(office.get("company")))
        for f in office.get("floors") or []:
            desks = []
            for r in f.get("rooms") or []:
                for d in r.get("desks") or []:
                    occ = d.get("occupant") or {}
                    desks.append({"id": _text(d.get("id")), "role": _name(d.get("role") or r.get("role")),
                                  "zone": _name(occ.get("zone") or d.get("zone") or ("flex" if r.get("flex") else "room")),
                                  "occupant_key": key(machine_id, occ.get("thread_id"))})
            floors.append({"name": _text(f.get("name")), "desks": desks})
    if not floors:
        return None
    return {"floors": floors, "company": companies.pop() if len(companies) == 1 else None}


def _employees_part(machine_id, snap):
    snap = snap or {}
    if "employees" not in snap and "queues" not in snap:
        return None
    employees = []
    for e in snap.get("employees") or []:
        eid = _employee((e or {}).get("id"))
        if not eid:
            continue
        employees.append({"id": eid, "project": _name(e.get("project")), "floor": _count(e.get("floor")),
                          "role": _name(e.get("role")), "slot": _count(e.get("slot")), "name": _text(e.get("name")),
                          "state": e.get("state") if e.get("state") in ("idle", "working") else "idle",
                          "location": "desk" if e.get("state") == "working" else "common",
                          "thread_id": key(machine_id, e.get("thread_id")), "task": _task(e.get("task")),
                          "title": _text(e.get("title"), TITLE_MAX), "since": _ts(e.get("since")),
                          "queue_len": _count(e.get("queue_len"))})
    queues = {}
    for eid, q in (snap.get("queues") or {}).items():
        if _employee(eid) and isinstance(q, dict):
            queues[eid] = {"items": _queue_items(q.get("items")), "updated": _ts(q.get("updated"))}
    return {"employees": employees[:1024], "queues": queues}


def _health(snap, state):
    mh = (state or {}).get("machine_health") or {}
    machine = (snap or {}).get("machine") or {}
    agent = (snap or {}).get("agent") or {}
    src = mh or machine
    load = src.get("load") or [0]
    try:
        load1 = max(0.0, float(load[0]))
    except (TypeError, ValueError, IndexError):
        load1 = 0.0
    if mh.get("state") in HEALTH_STATES:
        st = mh["state"]
    else:
        st = "degraded" if agent.get("errors") else "ok"
    t3_ok = mh["t3_ok"] if "t3_ok" in mh else agent.get("t3_ok")
    return {"state": st, "t3_ok": t3_ok if isinstance(t3_ok, bool) else None, "cpu_pct": _pct(src.get("cpu_pct")),
            "ram_pct": _pct(src.get("ram_pct")), "disk_pct": _pct(src.get("disk_pct")), "load1": load1}


def _counts(snap, state):
    sp = (state or {}).get("projects")
    if sp:
        return {k: sum(_count((p.get("counts") or {}).get(k)) for p in sp) for k in COUNT_KEYS}
    return {"running": sum(_count(p.get("threads_running")) for p in (snap or {}).get("projects") or [])}


def _projects(snap, state, roles, attention):
    rows = {}
    for p in (snap or {}).get("projects") or []:
        n = _name(p.get("name"))
        if n:
            rows[n] = {"threads_running": _count(p.get("threads_running")), "threads_pending": _count(p.get("threads_pending"))}
    for p in (state or {}).get("projects") or []:
        n = _name(p.get("name"))
        if n:
            counts = p.get("counts") or {}
            rows.setdefault(n, {"threads_running": _count(counts.get("running")),
                                "threads_pending": _count(counts.get("needs_human"))})
    for n in roles or {}:
        if _name(n):
            rows.setdefault(n, {"threads_running": 0, "threads_pending": 0})
    return [{"name": n, "roles": _roles((roles or {}).get(n)), "threads_running": r["threads_running"],
             "threads_pending": r["threads_pending"], "attention": attention.get(n, 0)}
            for n, r in sorted(rows.items())][:256]


def _keep(names, unscoped, project):
    return project in names if project else unscoped


def _only(rows, names, unscoped, field="project"):
    return [r for r in rows or () if isinstance(r, dict) and _keep(names, unscoped, r.get(field))]


def scope(snap, state, roles, projects, unscoped=False):
    names = set(projects)
    snap, state = dict(snap or {}), dict(state or {})
    for k in ("threads", "pending_questions", "events", "employees"):
        if k in snap:
            snap[k] = _only(snap[k], names, unscoped)
    if "projects" in snap:
        snap["projects"] = _only(snap["projects"], names, False, "name")
    if isinstance(snap.get("queues"), dict):
        snap["queues"] = {e: q for e, q in snap["queues"].items() if isinstance(e, str) and e.split("/", 1)[0] in names}
    if "projects" in state:
        state["projects"] = _only(state["projects"], names, False, "name")
    if "recent" in state:
        state["recent"] = _only(state["recent"], names, unscoped)
    return snap, state, {n: r for n, r in (roles or {}).items() if n in names}


def snapshot(snap, state=None, roles=None, machine_id=None, seq=None, ttl_s=TTL_DEFAULT, ts=None, version=AGENT_VERSION,
             v=1, workspace_id=None, projects=None):
    snap = snap or {}
    mid = _machine(machine_id or snap.get("machine_id") or (state or {}).get("machine"))
    if seq is None:
        seq = (state or {}).get("head_seq") or max([e.get("seq") or 0 for e in snap.get("events") or []] or [0])
    if projects is not None:
        snap, state, roles = scope(snap, state, roles, projects, unscoped=workspace_id is None)
    msg = dict(_header("snapshot", ts, v), machine_id=mid, seq=_count(seq),
               ttl_s=max(TTL_MIN, min(TTL_MAX, int(ttl_s or TTL_DEFAULT))), agent_version=version,
               health=_health(snap, state), counts=_counts(snap, state))
    if v == 2:
        msg["workspace_id"] = workspace_id
    st = _state_part(mid, snap, state)
    attention = {}
    for a in st["attention"]:
        if a["project"]:
            attention[a["project"]] = attention.get(a["project"], 0) + 1
    msg["projects"] = _projects(snap, state, roles, attention)
    parts = [part("state", st), part("queue", _queue_part(mid, snap, state)),
             part("events", _events_part(mid, snap, state))]
    office = _office_part(mid, state)
    if office is not None:
        parts.append(part("office", office))
    employees = _employees_part(mid, snap)
    if employees is not None:
        parts.append(part("employees", employees))
    msg["parts"] = [p for p in parts if p is not None]
    return msg
