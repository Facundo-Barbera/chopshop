import os
import re
import threading
import time
from datetime import datetime, timezone
from typing import Optional

V = 1
MAX_DEPTH = 3
SEVERITIES = ("info", "notice", "warn", "error")
NEEDS_VALUES = (None, "human", "bot", "approval")
SUBJECT_KINDS = ("task", "batch", "node", "graph", "thread", "machine", "pr", "issue", "automation", "agent",
                 "desk", "office", "repo", "run", "listener")
PHASES = ("queued", "preparing", "running", "waiting", "done", "failed", "skipped", "settled")
ATTENTION = (None, "ask", "approval", "human", "bot")
HEALTH = ("ok", "degraded", "down")
DESK_ASSIGN_REASONS = ("start", "inherited", "manual", "wake")
DESK_RELEASE_REASONS = ("faded", "inherited", "retired", "manual")
LIGHTS = ("green", "amber", "red", "gray")
ORIGIN_KINDS = ("thread", "automation", "bot", "schedule", "human", "unknown")
FORGE_TYPES = ("forge.repo.state", "forge.run.state", "forge.dispatch")
OFFICE_TYPES = ("desk.assigned", "desk.released", "desk.waiting", "desk.note", "office.changed", "listener.state")
GITHUB_TYPES = ("github.issue.opened", "github.issue.updated", "github.issue.closed", "github.pr.opened",
                "github.pr.updated", "github.pr.merged", "github.pr.review", "github.ci.completed", "github.push")

SEVERITY = {
    "task.state": "info", "question.opened": "notice", "question.answered": "info", "approval.requested": "notice",
    "batch.created": "info", "batch.done": "info", "graph.state": "info", "node.state": "info", "graph.done": "info",
    "reaction.applied": "info", "machine.health": "info", "automation.ran": "info", "agent.started": "info",
}
SEVERITY.update({t: "info" for t in GITHUB_TYPES + FORGE_TYPES + OFFICE_TYPES})
NEEDS: dict[str, Optional[str]] = {t: None for t in SEVERITY}
NEEDS.update({"question.opened": "human", "approval.requested": "approval"})
TYPES = tuple(SEVERITY)

LEGACY_MAP = {
    "thread_started": "task.state", "thread_done": "task.state", "thread_failed": "task.state",
    "thread_settled": "task.state", "task_done": "task.state",
    "pending_question": "question.opened", "pending_approval": "approval.requested",
    "batch_done": "batch.done", "graph_exception": "node.state", "graph_done": "graph.done",
    "reaction": "reaction.applied", "t3_unreachable": "machine.health", "t3_recovered": "machine.health",
    "agent_started": "agent.started", "task_integrated": "task.integrated",
}

_TYPE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$")
_CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
_ULID = re.compile(r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$")
_ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,6})?Z$")


class EnvelopeError(ValueError):
    pass


def _b32(n, length):
    out = []
    for _ in range(length):
        out.append(_CROCKFORD[n & 31])
        n >>= 5
    return "".join(reversed(out))


class Ulid:
    def __init__(self, clock=None, rand=None):
        self.clock, self.rand = clock or time.time, rand or os.urandom
        self._lock = threading.Lock()
        self._ms, self._r = -1, 0

    def __call__(self, ts=None):
        ms = int((self.clock() if ts is None else ts) * 1000)
        with self._lock:
            if ms <= self._ms:
                ms, r = self._ms, self._r + 1
                if r >> 80:
                    ms, r = ms + 1, int.from_bytes(self.rand(10), "big")
            else:
                r = int.from_bytes(self.rand(10), "big")
            self._ms, self._r = ms, r
        return _b32(ms & ((1 << 48) - 1), 10) + _b32(r, 16)


_default = Ulid()


def new_id(ts=None):
    return _default(ts)


def id_time(ulid):
    n = 0
    for c in ulid[:10]:
        n = n * 32 + _CROCKFORD.index(c)
    return n / 1000.0


def iso(ts=None):
    ts = time.time() if ts is None else float(ts)
    d = datetime.fromtimestamp(ts, timezone.utc)
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (d.microsecond // 1000)


def epoch(s):
    if isinstance(s, (int, float)) and not isinstance(s, bool):
        return float(s)
    s = str(s or "").strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    m = re.match(r"^(.*[+-]\d\d)(\d\d)$", s)
    if m and ":" not in s[-5:]:
        s = m.group(1) + ":" + m.group(2)
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp()


DEFAULT = object()


def subject(kind, id, title=None, url=None):
    s = {"kind": kind, "id": str(id)}
    if title:
        s["title"] = str(title)
    if url:
        s["url"] = str(url)
    return s


def cause_of(parent):
    if not parent:
        return {"id": None, "depth": 0}
    if "type" in parent:
        return {"id": parent.get("id"), "depth": int((parent.get("cause") or {}).get("depth") or 0) + 1}
    return {"id": parent.get("id"), "depth": int(parent.get("depth") or 0)}


def build(type, project=None, body=None, severity=None, needs=DEFAULT, subj=None, cause=None, machine=None,
          ts=None, id=None, seq=None):
    ts = time.time() if ts is None else float(ts)
    return {"v": V, "id": id or new_id(ts), "seq": seq, "ts": iso(ts), "machine": machine, "project": project,
            "type": type, "severity": severity or SEVERITY.get(type, "info"),
            "needs": NEEDS.get(type) if needs is DEFAULT else needs,
            "subject": subj or default_subject(type, project, body or {}, machine),
            "cause": cause_of(cause), "body": dict(body or {})}


def default_subject(type, project, body, machine=None):
    if type.startswith("github."):
        kind = "pr" if ".pr." in type or type == "github.ci.completed" else ("issue" if ".issue." in type else "pr")
        num = body.get("number")
        return subject(kind, "%s#%s" % (body.get("repo") or "?", num) if num is not None else (body.get("repo") or "?"),
                       body.get("title"), body.get("url"))
    if type == "automation.ran":
        return subject("automation", body.get("automation") or "?")
    if type in ("desk.assigned", "desk.note") or type == "desk.released" and body.get("desk"):
        return subject("desk", body.get("desk") or "?", body.get("role"))
    if type in ("desk.waiting", "desk.released"):
        return subject("thread", body.get("thread_id") or "?", body.get("title"))
    if type == "office.changed":
        return subject("office", body.get("project") or project or "?")
    if type == "forge.repo.state":
        return subject("repo", "%s:%s" % (body.get("provider") or "?", body.get("repo") or "?"), body.get("label"),
                       body.get("url"))
    if type in ("forge.run.state", "forge.dispatch"):
        return subject("run", "%s:%s#%s" % (body.get("provider") or "?", body.get("repo") or "?",
                                            body.get("run_id") or body.get("nonce") or "?"), body.get("workflow"), body.get("url"))
    if type == "listener.state":
        return subject("listener", body.get("name") or "?")
    if type in ("machine.health",):
        return subject("machine", machine or "?")
    if type == "agent.started":
        return subject("agent", machine or "?")
    if type.startswith("batch."):
        return subject("batch", body.get("batch") or "?")
    if type in ("graph.state", "graph.done"):
        return subject("graph", body.get("graph") or "?", body.get("goal"))
    if type == "node.state":
        return subject("node", "%s/%s" % (body.get("graph") or "?", body.get("node") or "?"), body.get("label"))
    tid = body.get("thread_id") or body.get("thread") or body.get("task")
    if tid:
        return subject("task", tid, body.get("title"), body.get("link"))
    return subject("agent", machine or project or "?")


def phase_for(status, settled=False):
    if settled:
        return "settled"
    if status in ("running", "starting"):
        return "running"
    if status == "waiting":
        return "waiting"
    if status in ("queued", "pending"):
        return "queued"
    if status == "completed":
        return "done"
    if status in ("failed", "cancelled", "interrupted", "rolled_back", "launch_failed"):
        return "failed"
    if status == "skipped":
        return "skipped"
    return "running" if status else "queued"


_ATTN_NEEDS = {"ask": "human", "approval": "approval", "human": "human", "bot": "bot"}


def needs_for_attention(attention):
    return _ATTN_NEEDS.get(attention)


def _task_state(b, phase, attention=None, extra=None):
    out = dict(b)
    out.update(extra or {})
    out.setdefault("thread_id", b.get("thread"))
    out["phase"], out["attention"] = phase, attention
    if "status" in b and "t3status" not in b:
        out["t3status"] = b.get("status")
    for k in ("title", "batch", "node", "link", "worktree", "branch", "level", "retry_of", "result", "error"):
        out.setdefault(k, None)
    out.setdefault("pull_requests", [])
    out["settled"] = bool(b.get("settled")) or phase == "settled"
    return out


def _labels(opts):
    out = []
    for o in opts or []:
        out.append(o.get("label") if isinstance(o, dict) else o)
    return [str(o) for o in out if o is not None]


def _task_subject(b):
    return subject("task", b.get("thread_id") or b.get("thread") or b.get("task") or "?", b.get("title"), b.get("link"))


def from_legacy(event, body=None, machine=None):
    b = dict(body or {})
    b.pop("legacy", None)
    typ = LEGACY_MAP.get(event)
    if typ is None:
        typ = event if _TYPE.match(event or "") else "legacy.%s" % re.sub(r"[^a-z0-9_]", "_", str(event).lower())
    sev, needs, subj = SEVERITY.get(typ, "info"), NEEDS.get(typ), None
    nb = b
    if event in ("thread_started", "thread_done", "thread_failed", "thread_settled", "task_done"):
        st = b.get("status")
        phase = {"thread_done": "done", "thread_failed": "failed", "thread_settled": "settled"}.get(event)
        if event == "task_done":
            phase = phase_for(st)
        if phase is None:
            phase = phase_for(st)
            if phase in ("done", "failed"):
                phase = "running"
        nb = _task_state(b, phase, extra={"thread_id": b.get("thread_id") or b.get("thread")})
        sev = "error" if phase == "failed" else "info"
        subj = _task_subject(nb)
    elif event == "pending_question":
        qs = b.get("questions") or []
        q0 = qs[0] if qs and isinstance(qs[0], dict) else {}
        level = b.get("level")
        nb = dict(b)
        nb.update(thread_id=b.get("thread_id") or b.get("thread"), request_id=b.get("request_id") or b.get("request"),
                  summary=b.get("summary") or (q0.get("question") or "")[:300] or None,
                  options=_labels(b.get("options") if b.get("options") is not None else q0.get("options")),
                  multi_select=bool(b.get("multi_select", q0.get("multiSelect", False))), level=level)
        nb.setdefault("notify", None)
        nb.setdefault("reply", None)
        needs = "bot" if level == "bot" else "human"
        subj = _task_subject(nb)
    elif event == "pending_approval":
        nb = dict(b, thread_id=b.get("thread_id") or b.get("thread"), count=int(b.get("count") or 1))
        nb.setdefault("note", "se aprueba en la UI de T3")
        subj = _task_subject(nb)
    elif event == "batch_done":
        nb = dict(b)
        nb.setdefault("tasks", {})
        nb.setdefault("notes", [])
        nb.setdefault("max_parallel", None)
    elif event == "graph_exception":
        nb = dict(b, phase=b.get("phase") if b.get("phase") in PHASES else "failed")
        nb.setdefault("deps", [])
        nb.setdefault("task", None)
        sev = "error" if nb["phase"] == "failed" else "warn"
    elif event == "graph_done":
        sev = "error" if b.get("status") == "failed" else "info"
    elif event == "reaction":
        lvl = b.get("level")
        nb = dict(b, on=b.get("reaction") or b.get("on") or "pending_question", level=lvl,
                  action=b.get("action") or ("notify:%s" % b["notify"] if b.get("notify") else lvl or "?"))
        nb.setdefault("note", "")
        sev = "notice" if lvl == "human" else "info"
    elif event == "t3_unreachable":
        nb = dict(b, state="degraded", t3_ok=False, down_seconds=None)
        sev = "warn"
    elif event == "t3_recovered":
        nb = dict(b, state="ok", t3_ok=True)
        nb.setdefault("down_seconds", None)
    if typ != event:
        nb["legacy"] = event
    return {"type": typ, "severity": sev, "needs": needs, "subject": subj or default_subject(typ, None, nb, machine),
            "body": nb}


def companions(fields):
    typ, b = fields["type"], fields["body"]
    if typ not in ("question.opened", "approval.requested") or not fields["subject"]["kind"] == "task":
        return []
    if typ == "approval.requested":
        attention = "approval"
    else:
        attention = {"bot": "bot", "human": "human"}.get(b.get("level"), "ask")
    keep = {k: b[k] for k in ("thread_id", "title", "batch", "task", "node", "link", "worktree", "branch",
                              "pull_requests", "host") if k in b}
    tb = _task_state(dict(keep, status=b.get("status")), "waiting", attention,
                     extra={"level": b.get("level")} if b.get("level") else None)
    tb["legacy"] = b.get("legacy")
    return [{"type": "task.state", "severity": "notice", "needs": needs_for_attention(attention),
             "subject": dict(fields["subject"]), "body": tb}]


def _str(v):
    return isinstance(v, str) and v != ""


def _opt_str(v):
    return v is None or isinstance(v, str)


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _opt_int(v):
    return v is None or _int(v)


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _list(v):
    return isinstance(v, list)


def _dict(v):
    return isinstance(v, dict)


def _in(*vals):
    return lambda v: v in vals


_GITHUB = {"repo": _str, "action": _str, "url": _opt_str, "title": _opt_str, "number": _opt_int}

SCHEMAS = {
    "task.state": {"phase": _in(*PHASES), "attention": _in(*ATTENTION), "thread_id": _opt_str, "settled": _in(True, False)},
    "question.opened": {"thread_id": _opt_str, "request_id": _str, "summary": _opt_str, "options": _list,
                        "multi_select": _in(True, False)},
    "question.answered": {"thread_id": _opt_str, "request_id": _opt_str, "choice": lambda v: v is not None,
                          "by": _str},
    "approval.requested": {"thread_id": _opt_str, "count": _int, "note": _opt_str},
    "batch.created": {"batch": _str, "host": _opt_str, "tasks": _dict},
    "batch.done": {"batch": _str, "host": _opt_str, "tasks": _dict},
    "graph.state": {"graph": _str, "status": _str, "nodes": _list},
    "node.state": {"graph": _str, "node": _str, "phase": _in(*PHASES)},
    "graph.done": {"graph": _str, "status": _str},
    "reaction.applied": {"on": _str, "level": _in("auto", "bot", "human"), "action": _str},
    "machine.health": {"state": _in(*HEALTH), "t3_ok": _in(True, False, None)},
    "automation.ran": {"automation": _str, "trigger": _str, "exit": _opt_int, "duration_ms": _num, "error": _opt_str},
    "agent.started": {"version": _str},
}
SCHEMAS.update({t: _GITHUB for t in GITHUB_TYPES})
_ORIGIN = lambda v: _dict(v) and v.get("kind") in ORIGIN_KINDS
SCHEMAS.update({
    "desk.assigned": {"desk": _str, "thread_id": _str, "role": _str, "reason": _in(*DESK_ASSIGN_REASONS)},
    "desk.released": {"desk": _opt_str, "thread_id": _str, "reason": _in(*DESK_RELEASE_REASONS)},
    "desk.waiting": {"thread_id": _str, "role": _str},
    "desk.note": {"desk": _str, "from": _str, "text": _str},
    "office.changed": {"project": _str, "by": _str, "floors": _list},
    "forge.repo.state": {"provider": _str, "repo": _str, "light": _in(*LIGHTS)},
    "forge.run.state": {"provider": _str, "repo": _str, "run_id": _str, "workflow": _opt_str, "status": _str,
                        "event": _opt_str, "origin": _ORIGIN},
    "forge.dispatch": {"provider": _str, "repo": _str, "workflow": _str, "ref": _str},
    "listener.state": {"name": _str, "state": _in(*HEALTH)},
})


def errors(env):
    if not isinstance(env, dict):
        return ["el sobre no es un objeto"]
    errs = []
    if env.get("v") != V:
        errs.append("v debe ser %d" % V)
    if not isinstance(env.get("id"), str) or not _ULID.match(env["id"]):
        errs.append("id debe ser un ULID")
    if not _opt_int(env.get("seq")):
        errs.append("seq debe ser entero o null")
    if not isinstance(env.get("ts"), str) or not _ISO.match(env["ts"]):
        errs.append("ts debe ser ISO-8601 UTC con Z")
    if not _str(env.get("machine")):
        errs.append("machine requerido")
    if not _opt_str(env.get("project")):
        errs.append("project debe ser texto o null")
    typ = env.get("type")
    if not isinstance(typ, str) or not _TYPE.match(typ):
        errs.append("type inválido")
    if env.get("severity") not in SEVERITIES:
        errs.append("severity debe ser uno de %s" % ", ".join(SEVERITIES))
    if env.get("needs") not in NEEDS_VALUES:
        errs.append("needs debe ser null, human, bot o approval")
    s = env.get("subject")
    if not _dict(s) or s.get("kind") not in SUBJECT_KINDS or not _str(s.get("id")):
        errs.append("subject debe ser {kind: %s, id}" % "|".join(SUBJECT_KINDS))
    elif not (_opt_str(s.get("title")) and _opt_str(s.get("url"))):
        errs.append("subject.title/url deben ser texto")
    c = env.get("cause")
    if not _dict(c) or not _opt_str(c.get("id")) or not _int(c.get("depth")) or c["depth"] < 0:
        errs.append("cause debe ser {id: ULID|null, depth: entero >= 0}")
    body = env.get("body")
    if not _dict(body):
        errs.append("body debe ser un objeto")
    elif isinstance(typ, str):
        for k, ok in (SCHEMAS.get(typ) or {}).items():
            if k not in body or not ok(body[k]):
                errs.append("body.%s inválido o ausente para %s" % (k, typ))
        if "legacy" in body and not _opt_str(body["legacy"]):
            errs.append("body.legacy debe ser texto")
    return errs


def validate(env):
    errs = errors(env)
    if errs:
        raise EnvelopeError("; ".join(errs))
    return env
