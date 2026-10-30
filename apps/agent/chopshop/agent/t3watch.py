import time
from datetime import datetime, timezone

from .. import answers, profile, reactions, t3mcp
from . import db, envelope, layout

ACTIVE = {"running", "starting", "waiting", "queued", "pending"}
DONE = {"completed"}
FAILED = {"failed", "cancelled", "interrupted", "rolled_back"}

TIMEOUT = 60
BACKOFF_BASE = 10
BACKOFF_MAX = 300
PAGE = 25
MAX_PAGES = 20
MAX_READS = 40
NEW_SLACK = 30

T3Error = t3mcp.T3Error


class AnswerError(T3Error):
    pass


def make_client(conf, timeout=TIMEOUT):
    conf = conf or {}
    return t3mcp.Client(origin=conf.get("origin") or None, access=conf.get("access") or "approval-required",
                        credential_file=conf.get("credential_file") or None, t3_bin=conf.get("t3_bin") or "t3",
                        timeout=timeout)


class T3:
    def __init__(self, cfg, client=None, clock=None, timeout=TIMEOUT):
        self.cfg = cfg
        self.conf = cfg.get("t3") or {}
        self.client = client if client is not None else make_client(self.conf, timeout)
        self.clock = clock or time.time
        self.reachable = None
        self.failures = 0
        self.retry_at = 0.0
        self.last_error = None

    def call(self, tool, args=None):
        try:
            return self.client.call(tool, args or {})
        except T3Error:
            raise
        except Exception as e:
            raise T3Error("%s: %s" % (tool, str(e)[:600]))

    def projects(self):
        out, cursor = [], None
        for _ in range(10):
            data = self.call("t3_project_list", dict({"limit": 100}, **({"cursor": cursor} if cursor is not None else {})))
            out += [p for p in (data.get("projects") or []) if not p.get("deletedAt")]
            cursor = data.get("nextCursor")
            if cursor is None:
                break
        return out

    def threads(self, project_id, stop=None, limit=PAGE, max_pages=MAX_PAGES):
        out, cursor = [], None
        for _ in range(max_pages):
            data = self.call("t3_thread_list", dict({"projectId": project_id, "limit": limit},
                                                    **({"cursor": cursor} if cursor is not None else {})))
            page = data.get("threads") or []
            out += page
            cursor = data.get("nextCursor")
            if cursor is None or not page or (stop and stop(page)):
                break
        return out

    def read(self, thread_id, limit=1, chars=1):
        return self.call("t3_thread_read", {"threadId": thread_id, "limit": limit, "maxCharsPerItem": chars})

    @property
    def backoff(self):
        return 0 if not self.failures else min(BACKOFF_MAX, BACKOFF_BASE * 2 ** (self.failures - 1))

    def mark_ok(self):
        self.reachable, self.failures, self.retry_at, self.last_error = True, 0, 0.0, None

    def mark_fail(self, err, now):
        self.reachable, self.failures, self.last_error = False, self.failures + 1, str(err)[:300]
        self.retry_at = now + self.backoff


def _epoch(s, default=None):
    try:
        return datetime.strptime(str(s)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return default


def _iso(ts):
    return envelope.iso(ts) if ts is not None else None


def _meta(conn, key, default=None):
    r = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return r["value"] if r else default


def _set_meta(conn, key, value):
    if value is None:
        conn.execute("DELETE FROM meta WHERE key=?", (key,))
    else:
        conn.execute("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", (key, str(value)))


def _prs(t):
    return [p.get("url") for p in (t.get("pullRequests") or []) if p.get("url")]


def _known_rows(conn):
    return {r["thread_id"]: dict(r) for r in conn.execute("SELECT * FROM t3_threads")}


def _stable(row, t):
    if not row:
        return False
    extra = db.jload(row.get("extra"), {}) or {}
    return (row["status"] == t.get("status") and bool(row["settled"]) == bool(t.get("settled"))
            and extra.get("t3_updated") == t.get("updatedAt"))


def _new_requests(t3, thread_id, known):
    ids = t3.call("t3_pending_request", {"action": "list", "threadId": thread_id}).get("requestIds", [])
    out = []
    for rid in ids:
        q = known.get(rid)
        if q is None:
            raw = t3.call("t3_pending_request", {"action": "read", "threadId": thread_id, "requestId": rid})
            q = {"request_id": rid, "questions": raw.get("questions") or []}
        out.append(q)
    return out


def _last_assistant_text(read, limit=600):
    msgs = [i for i in (read.get("items") or []) if i.get("type") == "assistant_message" and i.get("text")]
    return msgs[-1]["text"][:limit] if msgs else None


def reaction_level(project, text):
    try:
        rule = reactions.find(profile.load(project), "pending_question", text)
    except Exception:
        return None, None
    return (rule["level"], rule.get("notify")) if rule else (None, None)


def _level(p, project, questions):
    text = " ".join([str(q.get("question") or "") + " " + " ".join(str(o.get("label") or "") for o in q.get("options") or [])
                     for q in questions or [] if isinstance(q, dict)])
    try:
        level, notify = p.level_fn(project, text)
    except Exception:
        return None, None
    return level, notify


class _Pass:
    def __init__(self, conn, t3, emit_fn, now, baseline, last_poll, max_reads, level_fn=None):
        self.conn, self.t3, self.emit_fn, self.now = conn, t3, emit_fn, now
        self.level_fn = level_fn or reaction_level
        self.baseline, self.last_poll, self.reads_left = baseline, last_poll, max_reads
        self.changes, self.errors, self.seen = [], [], set()
        self.profiles = {}

    def role(self, project, title, branch):
        if project not in self.profiles:
            try:
                self.profiles[project] = profile.load(project)
            except Exception:
                self.profiles[project] = None
        prof = self.profiles[project]
        return layout.role_for(prof, title, branch) if prof else None

    def emit(self, event, project, body):
        seq = self.emit_fn(event, project, body)
        self.changes.append({"event": event, "thread_id": body.get("thread_id"), "project": project,
                             **({"seq": seq} if isinstance(seq, int) else {})})

    def read(self, thread_id, limit=1, chars=1):
        if self.reads_left <= 0:
            return None
        self.reads_left -= 1
        return self.t3.read(thread_id, limit, chars)


def _process(p, t, project, project_id, prev):
    tid, status, settled = t["threadId"], t.get("status"), bool(t.get("settled"))
    active, was_active = status in ACTIVE, bool(prev) and prev["status"] in ACTIVE
    created = _epoch(t.get("createdAt"), p.now)
    fresh = prev is None and not p.baseline and created >= p.last_poll - NEW_SLACK
    old_pending = db.jload(prev["pending"], []) if prev else []
    old_extra = db.jload(prev.get("extra"), {}) if prev else {}
    terminal_change = status in (DONE | FAILED) and (fresh or (prev is not None and prev["status"] != status))

    worktree, branch = (prev or {}).get("worktree"), (prev or {}).get("branch")
    pending, approvals = old_pending, old_extra.get("approvals", 0)
    result = None
    if active or old_pending or old_extra.get("approvals") or terminal_change:
        full = status in DONE and terminal_change
        th = p.read(tid, 30, 600) if full else p.read(tid)
        if th is not None:
            info = th.get("thread") or {}
            worktree, branch = info.get("worktreePath") or worktree, info.get("branch") or branch
            if full:
                result = _last_assistant_text(th)
            npend = info.get("pendingRequestCount") or 0
            if npend or old_pending or approvals:
                known = {q["request_id"]: q for q in old_pending}
                pending = _new_requests(p.t3, tid, known) if npend else []
                approvals = max(npend - len(pending), 0)

    row_title = t.get("title") or (prev or {}).get("title")
    role = (prev or {}).get("role") or p.role(project, row_title, branch)
    ended_at = None
    if status in DONE | FAILED:
        ended_at = (prev or {}).get("ended_at") if prev and prev["status"] in DONE | FAILED else None
        ended_at = ended_at or (p.now if terminal_change else _epoch(t.get("updatedAt"), p.now))
    body = {"thread_id": tid, "title": row_title, "status": status, "link": t.get("link"), "worktree": worktree,
            "branch": branch, "pull_requests": _prs(t), "role": role, "ended_at": _iso(ended_at)}
    quiet = p.baseline
    if not quiet:
        if active and not was_active:
            p.emit("thread_started", project, dict(body))
        elif prev is None and fresh and (status in DONE or status in FAILED):
            p.emit("thread_started", project, dict(body))
        if terminal_change and status in DONE:
            p.emit("thread_done", project, dict(body, **({"result": result, "summary": result} if result else {})))
        elif terminal_change and status in FAILED:
            p.emit("thread_failed", project, dict(body))
        if settled and not (prev and prev["settled"]) and (prev is not None or fresh):
            p.emit("thread_settled", project, dict(body, settled=True))
    old_ids = {q["request_id"] for q in old_pending}
    for q in pending:
        if q["request_id"] not in old_ids:
            level, notify = _level(p, project, q["questions"])
            p.emit("pending_question", project, dict(body, request_id=q["request_id"], questions=q["questions"],
                                                     level=level, notify=notify))
    if approvals > old_extra.get("approvals", 0) and not quiet:
        p.emit("pending_approval", project, dict(body, count=approvals,
                                                 note="el hilo espera un permiso; solo se aprueba desde la UI de T3"))

    extra = {"link": t.get("link"), "approvals": approvals, "pull_requests": _prs(t), "t3_updated": t.get("updatedAt")}
    with db.tx():
        p.conn.execute(
            "INSERT OR REPLACE INTO t3_threads(thread_id, project, t3_project_id, title, status, settled, worktree, branch, pending,"
            " first_seen, last_seen, updated, extra, role, ended_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (tid, project, project_id, row_title, status, int(settled), worktree, branch, db.jdump(pending),
             (prev or {}).get("first_seen") or p.now, p.now, _epoch(t.get("updatedAt"), p.now), db.jdump(extra), role,
             ended_at))


def poll(conn, cfg, t3, emit_fn, max_reads=MAX_READS, level_fn=None):
    now = t3.clock()
    res = {"threads": 0, "changes": [], "errors": [], "reachable": bool(t3.reachable), "backoff": t3.backoff}
    if now < t3.retry_at:
        return dict(res, skipped="backoff")
    baseline = _meta(conn, "t3_baseline") is None
    p = _Pass(conn, t3, emit_fn, now, baseline, float(_meta(conn, "t3_last_poll", 0) or 0), max_reads, level_fn)
    prev_rows = _known_rows(conn)
    try:
        projects = t3.projects()
        listed = failed = 0
        for pr in projects:
            title = pr.get("title") or pr["id"]
            try:
                ths = t3.threads(pr["id"], stop=None if baseline else
                                 (lambda page: all(_stable(prev_rows.get(x["threadId"]), x) for x in page)))
            except T3Error as e:
                failed += 1
                p.errors.append("%s: %s" % (title, str(e)[:200]))
                continue
            listed += 1
            for t in ths:
                p.seen.add(t["threadId"])
                try:
                    _process(p, t, title, pr["id"], prev_rows.get(t["threadId"]))
                except Exception as e:
                    p.errors.append("%s: %s" % (t["threadId"], str(e)[:200]))
        if projects and not listed:
            raise T3Error("no pude listar hilos de ningún proyecto: %s" % "; ".join(p.errors)[:300])
        for tid, row in prev_rows.items():
            if tid not in p.seen and row["status"] in ACTIVE and p.reads_left > 0:
                try:
                    th = p.read(tid)
                    if th:
                        _process(p, th["thread"], row["project"], row["t3_project_id"], row)
                        p.seen.add(tid)
                except Exception as e:
                    p.errors.append("%s: %s" % (tid, str(e)[:200]))
        ok = not failed
    except T3Error as e:
        return _unreachable(conn, t3, emit_fn, now, e, res, p)
    _recovered(conn, t3, emit_fn, now, p)
    if ok:
        if baseline:
            _set_meta(conn, "t3_baseline", now)
        _set_meta(conn, "t3_last_poll", now)
    return dict(res, threads=len(p.seen), changes=p.changes, errors=p.errors, reachable=True, backoff=0)


def _unreachable(conn, t3, emit_fn, now, err, res, p):
    t3.mark_fail(err, now)
    if _meta(conn, "t3_unreachable") is None:
        _set_meta(conn, "t3_unreachable", now)
        body = {"error": t3.last_error, "retry_in": t3.backoff}
        seq = emit_fn("t3_unreachable", None, body)
        p.changes.append({"event": "t3_unreachable", "thread_id": None, "project": None,
                          **({"seq": seq} if isinstance(seq, int) else {})})
    return dict(res, changes=p.changes, errors=p.errors + [t3.last_error], reachable=False, backoff=t3.backoff)


def _recovered(conn, t3, emit_fn, now, p):
    since = _meta(conn, "t3_unreachable")
    t3.mark_ok()
    if since is not None:
        _set_meta(conn, "t3_unreachable", None)
        seq = emit_fn("t3_recovered", None, {"down_seconds": round(now - float(since), 1)})
        p.changes.append({"event": "t3_recovered", "thread_id": None, "project": None,
                          **({"seq": seq} if isinstance(seq, int) else {})})


def settle(t3, thread_id):
    if not isinstance(thread_id, str) or not thread_id.strip():
        raise T3Error("thread_id requerido")
    return t3.call("t3_thread_organize", {"threadId": thread_id, "action": "settle"})


def answer(t3, thread_id, choice, request=None):
    ids = t3.call("t3_pending_request", {"action": "list", "threadId": thread_id}).get("requestIds", [])
    if not ids:
        raise AnswerError("%s no tiene preguntas pendientes" % thread_id)
    if request:
        ids = [r for r in ids if r.startswith(request)]
        if not ids:
            raise AnswerError("no hay petición pendiente que empiece por %r" % request)
    if len(ids) > 1:
        raise AnswerError("hay %d preguntas pendientes; indica request" % len(ids))
    q = t3.call("t3_pending_request", {"action": "read", "threadId": thread_id, "requestId": ids[0]})
    qs = q.get("questions") or []
    if not qs:
        raise AnswerError("la petición %s no trae preguntas" % ids[0])
    try:
        ans = answers.resolve_all(qs, choice)
    except answers.InvalidChoice as e:
        raise AnswerError(str(e))
    t3.call("t3_pending_request", {"action": "respond", "threadId": thread_id, "requestId": ids[0], "answers": ans})
    return {"request_id": ids[0], "answers": ans, "question": qs[0] if len(qs) == 1 else qs}
