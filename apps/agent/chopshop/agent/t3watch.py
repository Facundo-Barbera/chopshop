"""Vigilante de T3: lee proyectos e hilos por el MCP de T3, mantiene `t3_threads` y emite eventos por transición.

- `T3(cfg, client=None, clock=None)`: adaptador fino sobre el cliente MCP nativo compartido (`chopshop/t3mcp.py`).
  `.call(tool, args)` delega en `client` (inyectado, o un `t3mcp.Client` construido desde `cfg["t3"]`: `origin`,
  `access`, `credential_file`, `t3_bin`); todo fallo llega como `T3Error` (= `t3mcp.T3Error`). Guarda además el estado
  de alcanzabilidad/backoff que usa `poll` (`.reachable`, `.failures`, `.backoff`, `.retry_at`, `.last_error`).
  No hay transporte propio: autenticación, sesión MCP y la guardia contra archivar viven en `t3mcp.Client`.
- `poll(conn, cfg, t3, emit_fn, level_fn=None)`: una pasada. `emit_fn(event, project, body)` (el agente lo envuelve sobre
  `events.emit`, que traduce cada nombre al sobre: `task.state`, `question.opened` + `task.state` con `attention`,
  `approval.requested`, `machine.health`). `level_fn(project, texto) -> (nivel, notify)` decide si una pregunta la atiende
  un bot o una persona (por defecto: la regla `reactions` `on: pending_question` del perfil del proyecto, si existe).
  Eventos: `thread_started`, `thread_done`, `thread_failed`, `thread_settled`, `pending_question`, `pending_approval`,
  `t3_unreachable` (una sola vez al caer) y `t3_recovered`. Los cuerpos de hilo llevan además `role` (el guardado, o el de
  las reglas `match` del perfil; `agent/office.py` lo usa para el escritorio) y `ended_at` (ISO). La primera pasada (sin línea base) siembra la tabla en silencio
  salvo las preguntas pendientes, que sí se avisan (son accionables).
- `settle(t3, thread_id)`: `t3_thread_organize {action: "settle"}`. Nunca archiva.
- `answer(t3, thread_id, choice, request=None)`: resuelve la opción con `chopshop/answers.py` (igual que el motor).
Se prueba inyectando un cliente falso con `.call(tool, args) -> obj` (o que lance `T3Error`)."""
import time
from datetime import datetime, timezone

from .. import answers, profile, reactions, t3mcp
from . import db, envelope, layout

# Estados de hilo de T3 (los terminales coinciden con engine.TERMINAL). `idle` (hilos de proveedor/subagentes sin
# ejecuciones) no es activo ni terminal: se registra pero no genera transiciones de inicio/fin.
ACTIVE = {"running", "starting", "waiting", "queued", "pending"}
DONE = {"completed"}
FAILED = {"failed", "cancelled", "interrupted", "rolled_back"}

TIMEOUT = 60              # segundos por llamada a T3
BACKOFF_BASE = 10         # primer reintento tras caer T3
BACKOFF_MAX = 300
PAGE = 25                 # páginas chicas: respuestas acotadas y cortes tempranos al paginar
MAX_PAGES = 20
MAX_READS = 40            # tope de t3_thread_read por pasada
NEW_SLACK = 30            # un hilo "nuevo" se considera reciente si se creó tras la pasada anterior (menos esta holgura)

T3Error = t3mcp.T3Error


class AnswerError(T3Error):
    """Petición inválida al responder (sin preguntas, ambigua u opción no válida): no es un fallo de T3."""


def make_client(conf, timeout=TIMEOUT):
    """`t3mcp.Client` desde la sección `agent.t3` (vacíos = valores por defecto del cliente)."""
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
        self.reachable = None     # None = aún no se sabe; True/False tras la primera pasada
        self.failures = 0         # fallos consecutivos de poll
        self.retry_at = 0.0       # no volver a llamar antes de este instante (clock)
        self.last_error = None

    def call(self, tool, args=None):
        try:
            return self.client.call(tool, args or {})
        except T3Error:
            raise
        except Exception as e:  # noqa: BLE001 - un cliente que falla de forma inesperada cuenta como T3 caído
            raise T3Error("%s: %s" % (tool, str(e)[:600]))

    def projects(self):
        """Proyectos de T3 no borrados: [{id, title, workspaceRoot, ...}]."""
        out, cursor = [], None
        for _ in range(10):
            data = self.call("t3_project_list", dict({"limit": 100}, **({"cursor": cursor} if cursor is not None else {})))
            out += [p for p in (data.get("projects") or []) if not p.get("deletedAt")]
            cursor = data.get("nextCursor")
            if cursor is None:
                break
        return out

    def threads(self, project_id, stop=None, limit=PAGE, max_pages=MAX_PAGES):
        """Hilos de un proyecto, más nuevos primero, paginando. `stop(page)` -> True corta (la página ya es conocida)."""
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

    # ---- estado de alcanzabilidad ----
    @property
    def backoff(self):
        """Segundos de espera actuales (0 si T3 responde)."""
        return 0 if not self.failures else min(BACKOFF_MAX, BACKOFF_BASE * 2 ** (self.failures - 1))

    def mark_ok(self):
        self.reachable, self.failures, self.retry_at, self.last_error = True, 0, 0.0, None

    def mark_fail(self, err, now):
        self.reachable, self.failures, self.last_error = False, self.failures + 1, str(err)[:300]
        self.retry_at = now + self.backoff


# ---------- utilidades ----------
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
    """La fila guardada ya refleja este hilo (mismo estado, settled y última actualización)."""
    if not row:
        return False
    extra = db.jload(row.get("extra"), {}) or {}
    return (row["status"] == t.get("status") and bool(row["settled"]) == bool(t.get("settled"))
            and extra.get("t3_updated") == t.get("updatedAt"))


def _new_requests(t3, thread_id, known):
    """Preguntas pendientes: [{request_id, questions}] reutilizando las ya leídas (`known` por request_id)."""
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
    """(nivel, notify) de la regla `reactions` `on: pending_question` del perfil que aplica a la pregunta; (None, None)
    sin perfil o sin regla (entonces la pregunta la atiende una persona)."""
    try:
        rule = reactions.find(profile.load(project), "pending_question", text)
    except Exception:  # noqa: BLE001 - perfil ausente o inválido: sin reacción
        return None, None
    return (rule["level"], rule.get("notify")) if rule else (None, None)


def _level(p, project, questions):
    text = " ".join([str(q.get("question") or "") + " " + " ".join(str(o.get("label") or "") for o in q.get("options") or [])
                     for q in questions or [] if isinstance(q, dict)])
    try:
        level, notify = p.level_fn(project, text)
    except Exception:  # noqa: BLE001
        return None, None
    return level, notify


# ---------- poll ----------
class _Pass:
    """Contexto de una pasada de poll."""
    def __init__(self, conn, t3, emit_fn, now, baseline, last_poll, max_reads, level_fn=None):
        self.conn, self.t3, self.emit_fn, self.now = conn, t3, emit_fn, now
        self.level_fn = level_fn or reaction_level
        self.baseline, self.last_poll, self.reads_left = baseline, last_poll, max_reads
        self.changes, self.errors, self.seen = [], [], set()
        self.profiles = {}
        self.allowed = None

    def role(self, project, title, branch):
        """Rol de la oficina por las reglas `match` del perfil (perfil leído una vez por pasada)."""
        if project not in self.profiles:
            try:
                self.profiles[project] = profile.load(project)
            except Exception:  # noqa: BLE001 - sin perfil (o inválido): sin rol
                self.profiles[project] = None
        prof = self.profiles[project]
        return layout.role_for(prof, title, branch) if prof else None

    def emit(self, event, project, body):
        if self.allowed is not None and project not in self.allowed:
            return
        seq = self.emit_fn(event, project, body)
        self.changes.append({"event": event, "thread_id": body.get("thread_id"), "project": project,
                             **({"seq": seq} if isinstance(seq, int) else {})})

    def read(self, thread_id, limit=1, chars=1):
        if self.reads_left <= 0:
            return None
        self.reads_left -= 1
        return self.t3.read(thread_id, limit, chars)


def _process(p, t, project, project_id, prev):
    """Procesa un hilo (dict de t3_thread_list o de t3_thread_read.thread): upsert + eventos por transición."""
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
    # lecturas acotadas: activos, con pendientes, o cuya transición terminal interesa
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
    if status in DONE | FAILED:     # cuándo terminó (el primer avistamiento usa la última actualización de T3)
        ended_at = (prev or {}).get("ended_at") if prev and prev["status"] in DONE | FAILED else None
        ended_at = ended_at or (p.now if terminal_change else _epoch(t.get("updatedAt"), p.now))
    body = {"thread_id": tid, "title": row_title, "status": status, "link": t.get("link"), "worktree": worktree,
            "branch": branch, "pull_requests": _prs(t), "role": role, "ended_at": _iso(ended_at)}
    quiet = p.baseline   # primera pasada: sembrar sin avisar (salvo preguntas)
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


def poll(conn, cfg, t3, emit_fn, max_reads=MAX_READS, level_fn=None, project_fn=None):
    """Una pasada de vigilancia -> {"threads": n, "changes": [...], "errors": [...], "reachable": bool, "backoff": s}.
    Respeta el backoff de `t3`: si T3 está caído y aún no toca reintentar, no llama (devuelve `skipped`)."""
    now = t3.clock()
    res = {"threads": 0, "changes": [], "errors": [], "reachable": bool(t3.reachable), "backoff": t3.backoff}
    if now < t3.retry_at:
        return dict(res, skipped="backoff")
    baseline = _meta(conn, "t3_baseline") is None
    p = _Pass(conn, t3, emit_fn, now, baseline, float(_meta(conn, "t3_last_poll", 0) or 0), max_reads, level_fn)
    prev_rows = _known_rows(conn)
    try:
        projects = t3.projects()
        if project_fn is not None:
            names = {pr["id"]: project_fn(pr) for pr in projects}
            p.allowed = {n for n in names.values() if n}
        listed = failed = 0
        for pr in projects:
            title = (names.get(pr["id"]) if project_fn is not None else None) or pr.get("title") or pr["id"]
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
                except Exception as e:  # noqa: BLE001 - un hilo con problemas (o un emit fallido) no frena el resto
                    p.errors.append("%s: %s" % (t["threadId"], str(e)[:200]))
        if projects and not listed:
            raise T3Error("no pude listar hilos de ningún proyecto: %s" % "; ".join(p.errors)[:300])
        # activos conocidos que no salieron en el listado (p. ej. paginados fuera): se leen directo
        for tid, row in prev_rows.items():
            if tid not in p.seen and row["status"] in ACTIVE and p.reads_left > 0:
                try:
                    th = p.read(tid)
                    if th:
                        _process(p, th["thread"], row["project"], row["t3_project_id"], row)
                        p.seen.add(tid)
                except Exception as e:  # noqa: BLE001
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
    if _meta(conn, "t3_unreachable") is None:   # una sola emisión mientras dure la caída (sobrevive a reinicios del agente)
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


# ---------- acciones ----------
def settle(t3, thread_id):
    """Marca el hilo como settled en T3. Nunca archiva."""
    if not isinstance(thread_id, str) or not thread_id.strip():
        raise T3Error("thread_id requerido")
    return t3.call("t3_thread_organize", {"threadId": thread_id, "action": "settle"})


def answer(t3, thread_id, choice, request=None):
    """Responde la pregunta pendiente de un hilo. `request` = id (o prefijo) si hay varias. Con una petición de varias
    preguntas, `choice` debe ser un dict {id_pregunta: elección}. Devuelve {"request_id", "answers", "question"}."""
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
