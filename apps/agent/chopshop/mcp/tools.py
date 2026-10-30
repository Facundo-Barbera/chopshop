import re
import uuid

from .. import employees, profile, state, t3
from .. import queue as equeue
from ..agent import client as agent_client
from ..agent import config as agent_config
from ..agent import db, envelope, events, layout, registry
from .fleet import ACTIVE, ToolError

RUNTIME_MODES = ["approval-required", "auto-accept-edits", "auto", "full-access"]
SEND_MODES = ["auto", "queue", "steer", "restart"]
MAX_FANOUT = 20

S = {"type": "string"}
I = {"type": "integer"}
B = {"type": "boolean"}
STRS = {"type": "array", "items": S}
HOST = {"type": "string", "description": "Máquina (nombre de [app.agents.<nombre>] o machine_id). Ver machines_list."}
THREAD = {"type": "string", "description": "Id del hilo de T3."}
LAUNCH = {
    "project": {"type": "string", "description": "Proyecto (nombre, título o id de T3). Sin proyecto: carpeta scratch."},
    "role": {"type": "string", "description": "Rol de máquina ([mcp.machines.<nombre>] roles) para elegir host."},
    "model": {"type": "string", "description": "instancia/modelo (p. ej. claude/claude-opus-5-5). Vacío: el del proyecto."},
    "runtime_mode": {"type": "string", "enum": RUNTIME_MODES},
    "interaction_mode": {"type": "string", "enum": ["default", "plan"]},
    "base_ref": {"type": "string", "description": "Rama base del worktree (por defecto main)."},
}


def _obj(props, required=()):
    return {"type": "object", "properties": props, "required": list(required), "additionalProperties": False}


def _slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "tarea"


def _compact(host, t):
    return {"host": host, "thread_id": t.get("thread_id"), "project": t.get("project"), "title": t.get("title"),
            "status": t.get("status"), "settled": t.get("settled"), "pending": len(t.get("pending") or []),
            "branch": t.get("branch"), "link": t.get("link"), "pull_requests": t.get("pull_requests") or [],
            "updated": t.get("updated")}


def _call(fn, *args, **kw):
    try:
        return fn(*args, **kw)
    except agent_client.AgentError as e:
        if e.status == 404:
            raise ToolError(f"{e} (¿agente sin las rutas de hilos? actualízalo a esta versión)")
        raise ToolError(str(e))


class Tools:
    def __init__(self, fleet, hooks, conn=None):
        self.fleet, self.hooks, self.conn = fleet, hooks, conn
        self.specs = [
            ("machines_list", "Estado de cada máquina de Chopshop: alcanzable, T3, carga, hilos y preguntas.", _obj({}),
             self.machines_list),
            ("projects_list", "Proyectos de T3 por máquina.", _obj({"host": HOST}), self.projects_list),
            ("thread_start", "Lanza un hilo de T3. Sin host elige la máquina menos cargada que tenga el proyecto y el rol.",
             _obj(dict(LAUNCH, host=HOST, title=S, message={"type": "string", "description": "Primer mensaje."},
                       branch={"type": "string", "description": "Rama de un worktree nuevo (requiere project)."},
                       client_request_id=S), ["title", "message"]), self.thread_start),
            ("thread_send", "Envía un mensaje a un hilo. steer=true lo inyecta en el turno en curso.",
             _obj({"thread_id": THREAD, "message": S, "steer": B, "mode": {"type": "string", "enum": SEND_MODES},
                   "host": HOST}, ["thread_id", "message"]), self.thread_send),
            ("thread_show", "Muestra un hilo: estado, rama, PRs, preguntas y sus últimos mensajes.",
             _obj({"thread_id": THREAD, "host": HOST, "limit": I, "max_chars": I,
                   "view": {"type": "string", "enum": ["messages", "activity"]}}, ["thread_id"]), self.thread_show),
            ("threads_list", "Lista hilos de todas las máquinas (o de una), más recientes primero.",
             _obj({"host": HOST, "project": S, "status": STRS, "include_settled": B, "limit": I}), self.threads_list),
            ("pending_list", "Preguntas pendientes de todos los hilos de todas las máquinas.",
             _obj({"host": HOST, "project": S}), self.pending_list),
            ("pending_answer", "Responde la pregunta pendiente de un hilo (texto/número de opción o {id_pregunta: elección}).",
             _obj({"thread_id": THREAD, "choice": {"oneOf": [S, I, {"type": "object"}]},
                   "request_id": S, "host": HOST}, ["thread_id", "choice"]), self.pending_answer),
            ("thread_settle", "Marca un hilo como settled en T3. Nunca archiva.",
             _obj({"thread_id": THREAD, "host": HOST}, ["thread_id"]), self.thread_settle),
            ("thread_interrupt", "Interrumpe el turno en curso de un hilo.",
             _obj({"thread_id": THREAD, "reason": S, "host": HOST}, ["thread_id"]), self.thread_interrupt),
            ("fanout", "Lanza varias tareas del mismo proyecto repartidas entre máquinas (o en un host fijo).",
             _obj(dict(LAUNCH, host=HOST,
                       tasks={"type": "array", "maxItems": MAX_FANOUT, "items": {"oneOf": [S, _obj(
                           {"title": S, "message": S, "branch": S}, ["message"])]}},
                       branch_prefix={"type": "string", "description": "Con project: un worktree por tarea, rama <prefijo><slug>."}),
                  ["project", "tasks"]), self.fanout),
            ("subscribe", ("Suscribe un webhook a los eventos de todas las máquinas (filtros opcionales). "
                          "heartbeat_s > 0 activa heartbeats periódicos. La URL se guarda en un archivo 0600 y nunca se devuelve."),
             _obj({"name": S, "url": S, "webhook_file": S, "projects": STRS, "types": STRS, "exclude_types": STRS,
                   "min_severity": {"type": "string", "enum": ["info", "notice", "warn", "error"]},
                   "needs": STRS, "machines": STRS, "heartbeat_s": I, "secret_file": S, "headers_file": S}, ["name"]),
             self.subscribe),
            ("unsubscribe", "Elimina una suscripción de webhook.", _obj({"name": S}, ["name"]), self.unsubscribe),
            ("subscriptions_list", "Suscripciones de webhook activas (sin URLs).", _obj({}), self.subscriptions_list),
            ("registry_list", "Proyectos del registro de Chopshop (projects.toml): empresa, proyecto de T3, host, roles.",
             _obj({"include_disabled": B}), self.registry_list),
            ("project_register", "Registra (o reactiva y actualiza) un proyecto en el registro. Idempotente; crea un perfil mínimo si falta.",
             _obj({"name": {"type": "string", "description": "Nombre del proyecto (perfil)."},
                   "company": {"type": "string", "description": "Empresa. Obligatoria al registrar uno nuevo."},
                   "t3_project": S, "repo": S, "host": S}, ["name"]), self.project_register),
            ("role_list", "Roles del perfil de un proyecto: escritorios, permanentes y disparadores de wake.",
             _obj({"project": {"type": "string", "description": "Nombre del proyecto (perfil)."}}, ["project"]),
             self.role_list),
            ("task_enqueue", "Encola una tarea para el empleado (escritorio permanente) de un rol de un proyecto.",
             _obj({"project": {"type": "string", "description": "Nombre del proyecto (perfil)."},
                   "role": S, "title": S, "slot": I, "floor": I, "priority": I, "by": S,
                   "key": {"type": "string", "description": "Clave de idempotencia por empleado."}},
                  ["project", "role", "title"]), self.task_enqueue),
            ("queue_show", "Colas de los empleados de un proyecto (opcionalmente de un rol), en orden de ejecución.",
             _obj({"project": {"type": "string", "description": "Nombre del proyecto (perfil)."}, "role": S},
                  ["project"]), self.queue_show),
            ("task_cancel", ("Cancela una tarea de cola (q:…): si aún no arrancó la saca de la cola; si ya está en marcha "
                             "interrumpe su hilo (nunca archiva) y libera al empleado."),
             _obj({"task": S, "reason": {"type": "string", "enum": list(equeue.CANCEL_REASONS)}, "note": S, "by": S},
                  ["task"]), self.task_cancel),
            ("employee_rename", "Renombra un empleado (id <proyecto>/<piso>/<rol>/<slot>); name null quita el nombre.",
             _obj({"employee": S, "name": {"type": ["string", "null"]}, "by": S}, ["employee", "name"]),
             self.employee_rename),
        ]
        self.by_name = {n: fn for n, _d, _s, fn in self.specs}

    def list(self):
        return [{"name": n, "description": d, "inputSchema": s} for n, d, s, _fn in self.specs]

    def call(self, name, args):
        fn = self.by_name.get(name)
        if fn is None:
            raise ToolError(f"herramienta desconocida: {name}")
        return fn(**(args or {}))

    def machines_list(self):
        ms = self.fleet.machines()
        snaps = self.fleet.snapshots(ms)
        out = []
        for m in ms:
            s = snaps.get(m.name) or {}
            row = {"name": m.name, "url": m.url, "local": m.local, "paired": m.paired or m.local, "roles": m.roles,
                   "cap": m.cap}
            if s.get("error"):
                row.update(ok=False, error=s["error"])
            else:
                threads = s.get("threads") or []
                agent = s.get("agent") or {}
                row.update(ok=True, machine_id=s.get("machine_id"), version=agent.get("version"), t3_ok=agent.get("t3_ok"),
                           uptime=agent.get("uptime"), errors=agent.get("errors"), machine=s.get("machine"),
                           threads_running=sum(1 for t in threads if t.get("status") in ACTIVE),
                           threads_unsettled=sum(1 for t in threads if not t.get("settled")),
                           pending_questions=len(s.get("pending_questions") or []))
            out.append(row)
        return {"machines": out}

    def projects_list(self, host=None):
        ms = [self.fleet.get(host)] if host else self.fleet.machines()
        res = self.fleet.each(lambda m: m.get("/t3/projects"), ms)
        return {"machines": {n: r for n, r in res.items()}}

    def _pick(self, host, project, role):
        if host:
            return self.fleet.get(host)
        return self.fleet.choose(self.fleet.candidates(project, role))

    def _launch(self, m, title, message, project=None, branch=None, base_ref=None, model=None, runtime_mode=None,
                interaction_mode=None, client_request_id=None):
        body = {"title": title[:120], "message": message, "project": project, "branch": branch, "base_ref": base_ref,
                "model": model, "runtime_mode": runtime_mode, "interaction_mode": interaction_mode,
                "client_request_id": client_request_id or uuid.uuid4().hex}
        res = _call(m.post, "/threads", {k: v for k, v in body.items() if v is not None}, timeout=120)
        tid = res.get("threadId") or res.get("thread_id") or (res.get("thread") or {}).get("id")
        if tid:
            self.fleet.remember(tid, m.name)
        return dict(res, host=m.name)

    def thread_start(self, title, message, host=None, project=None, role=None, branch=None, base_ref=None, model=None,
                     runtime_mode=None, interaction_mode=None, client_request_id=None):
        if branch and not project:
            raise ToolError("branch requiere project")
        m = self._pick(host, project, role)
        return self._launch(m, title, message, project, branch, base_ref, model, runtime_mode, interaction_mode,
                            client_request_id)

    def fanout(self, project, tasks, host=None, role=None, model=None, runtime_mode=None, interaction_mode=None,
               base_ref=None, branch_prefix=None):
        if not tasks:
            raise ToolError("tasks está vacío")
        if len(tasks) > MAX_FANOUT:
            raise ToolError(f"máximo {MAX_FANOUT} tareas por fanout")
        items = []
        for t in tasks:
            t = {"message": t} if isinstance(t, str) else dict(t)
            if not t.get("message"):
                raise ToolError("cada tarea necesita message")
            t["title"] = t.get("title") or t["message"].strip().splitlines()[0][:80]
            items.append(t)
        cands = None if host else self.fleet.candidates(project, role)
        results = []
        for t in items:
            try:
                m = self.fleet.get(host) if host else self.fleet.choose(cands)
                branch = t.get("branch") or (branch_prefix + _slug(t["title"]) if branch_prefix else None)
                r = self._launch(m, t["title"], t["message"], project, branch, base_ref, model, runtime_mode,
                                 interaction_mode)
                results.append({"title": t["title"], "ok": True, "host": m.name, "result": r})
            except ToolError as e:
                results.append({"title": t["title"], "ok": False, "error": str(e)})
        return {"launched": sum(1 for r in results if r["ok"]), "total": len(results), "results": results}

    def thread_send(self, thread_id, message, steer=False, mode=None, host=None):
        m = self.fleet.locate(thread_id, host)
        res = _call(m.post, "/threads/send", {"thread_id": thread_id, "message": message,
                                              "mode": "steer" if steer else (mode or "auto")})
        return dict(res, host=m.name)

    def thread_show(self, thread_id, host=None, limit=10, max_chars=2000, view=None):
        m = self.fleet.locate(thread_id, host)
        params = {"thread_id": thread_id, "limit": max(1, min(int(limit), 100)),
                  "chars": max(1, min(int(max_chars), 50000)), "view": view}
        read = _call(m.get, "/thread", params, timeout=60)
        rows = _call(m.get, "/threads", {"limit": 500}).get("threads") or []
        row = next((t for t in rows if t.get("thread_id") == thread_id), None)
        return {"host": m.name, "thread": _compact(m.name, row) if row else None,
                "pending": (row or {}).get("pending") or [], "read": read}

    def threads_list(self, host=None, project=None, status=None, include_settled=False, limit=50):
        ms = [self.fleet.get(host)] if host else self.fleet.machines()
        limit = max(1, min(int(limit), 500))
        res = self.fleet.each(lambda m: m.get("/threads", {"project": project, "limit": 500}), ms)
        out, errors = [], {}
        for name, r in res.items():
            if r.get("error"):
                errors[name] = r["error"]
                continue
            for t in r.get("threads") or []:
                self.fleet.remember(t.get("thread_id"), name)
                if not include_settled and t.get("settled"):
                    continue
                if status and t.get("status") not in status:
                    continue
                out.append(_compact(name, t))
        out.sort(key=lambda t: t.get("updated") or 0, reverse=True)
        return {"threads": out[:limit], "total": len(out), "errors": errors}

    def pending_list(self, host=None, project=None):
        ms = [self.fleet.get(host)] if host else self.fleet.machines()
        snaps = self.fleet.snapshots(ms)
        out, errors = [], {}
        for name, s in snaps.items():
            if s.get("error"):
                errors[name] = s["error"]
                continue
            titles = {t.get("thread_id"): t.get("title") for t in s.get("threads") or []}
            for q in s.get("pending_questions") or []:
                if project and q.get("project") != project:
                    continue
                self.fleet.remember(q.get("thread_id"), name)
                out.append(dict(q, host=name, title=titles.get(q.get("thread_id"))))
        return {"pending": out, "errors": errors}

    def pending_answer(self, thread_id, choice, request_id=None, host=None):
        m = self.fleet.locate(thread_id, host)
        body = {"thread_id": thread_id, "choice": choice, "by": "chopshop-mcp"}
        if request_id:
            body["request"] = request_id
        return dict(_call(m.post, "/answer", body, timeout=60), host=m.name)

    def thread_settle(self, thread_id, host=None):
        m = self.fleet.locate(thread_id, host)
        return dict(_call(m.post, "/settle", {"thread_id": thread_id}), host=m.name)

    def thread_interrupt(self, thread_id, reason=None, host=None):
        m = self.fleet.locate(thread_id, host)
        return dict(_call(m.post, "/threads/interrupt", {"thread_id": thread_id, "reason": reason or "chopshop-mcp"}),
                    host=m.name)

    def subscribe(self, **args):
        return self.hooks.subscribe(args)

    def unsubscribe(self, name):
        return self.hooks.unsubscribe(name)

    def subscriptions_list(self):
        return {"subscriptions": self.hooks.list()}

    def registry_list(self, include_disabled=True):
        try:
            rows = registry.listing()
        except registry.RegistryError as e:
            raise ToolError(e.message)
        return {"projects": [p for p in rows if include_disabled or p["enabled"]], "path": registry.path()}

    def project_register(self, name, company=None, t3_project=None, repo=None, host=None):
        try:
            return registry.api_register({"name": name, "company": company, "t3_project": t3_project, "repo": repo,
                                          "host": host})
        except (registry.RegistryError, OSError) as e:
            raise ToolError(getattr(e, "message", None) or str(e))

    def role_list(self, project):
        try:
            prof = profile.load(project)
        except profile.ProfileError as e:
            raise ToolError(str(e))
        specs, out = layout.roles(prof), {}
        for d in layout.desks(prof):
            r = out.setdefault(d["role"], {"role": d["role"], "desks": 0, "permanent": 0, "zones": []})
            r["desks"] += 1
            r["permanent"] += 1 if d["permanent"] else 0
            if d["zone"] not in r["zones"]:
                r["zones"].append(d["zone"])
        for role in specs:
            out.setdefault(role, {"role": role, "desks": 0, "permanent": 0, "zones": []})
        for role, r in out.items():
            r["wake"] = [t.get("type") for t in layout.wake_triggers(prof, role)]
            spec = specs.get(role)
            r["prompt_file"] = spec.get("prompt_file") if isinstance(spec, dict) else None
        return {"project": prof.get("project") or project, "registered": registry.counts(project),
                "roles": list(out.values())}

    def _db(self):
        cfg = agent_config.load()
        if self.conn is None:
            self.conn = db.connect(cfg["db_path"])
        return cfg

    def _queue(self):
        cfg = self._db()

        def emit(env):
            return events.emit_envelope(self.conn, cfg, env["type"], env.get("project"), env.get("body"), env.get("subject"),
                                        env.get("severity"), env.get("needs"), env.get("cause"), ts=envelope.epoch(env["ts"]),
                                        id=env.get("id"))
        return equeue.Queue(self.conn, emit, machine=cfg["machine_id"])

    def _staff(self, project, role=None):
        try:
            prof = profile.load(project)
        except profile.ProfileError as e:
            raise ToolError(str(e))
        staff = employees.declared(prof)
        if role is not None:
            if role not in layout.roles(prof) and not any(d["role"] == role for d in layout.desks(prof)):
                raise ToolError(f"el proyecto {project} no tiene el rol {role}")
            staff = [d for d in staff if d["role"] == role]
            if not staff:
                raise ToolError(f"el rol {role} de {project} no tiene escritorios permanentes")
        return prof, staff

    def task_enqueue(self, project, role, title, slot=None, floor=None, priority=0, by="human", key=None):
        _prof, staff = self._staff(project, role)
        staff = [d for d in staff if (slot is None or d["slot"] == slot) and (floor is None or d["floor"] == floor)]
        if not staff:
            raise ToolError(f"no hay empleado de {role} con slot={slot} floor={floor} en {project}")
        q = self._queue()
        emp = min(staff, key=lambda d: q.length(d["id"]))["id"]
        try:
            row, created = q.enqueue(emp, title, by or "human", priority=priority or 0, key=key)
        except equeue.QueueError as e:
            raise ToolError(str(e))
        items = q.show(emp)
        return {"task": row["task"], "employee": emp, "created": created, "state": row["state"],
                "position": next((i for i, it in enumerate(items) if it["task"] == row["task"]), None),
                "queue_len": len(items)}

    def queue_show(self, project, role=None):
        _prof, staff = self._staff(project, role)
        q = self._queue()
        snap = q.snapshot([d["id"] for d in staff])
        return {"project": project, "queues": [dict(snap[d["id"]], employee=d["id"], role=d["role"]) for d in staff]}

    def task_cancel(self, task, reason="manual", note=None, by="human"):
        q = self._queue()
        try:
            r = q.cancel(task, by or "human", reason=reason or "manual", note=note)
        except equeue.QueueError as e:
            raise ToolError(str(e))
        if r is None:
            cur = q.get(task)
            if cur is not None and cur["state"] == "dequeued":
                return self._cancel_running(q, cur, by or "human", reason or "manual", note)
            raise ToolError(f"no existe la tarea {task}" if cur is None else f"la tarea {task} ya está {cur['state']}")
        return {"task": task, "employee": r["employee"], "state": r["state"], "reason": r["cancel_reason"],
                "phase": "queued", "thread_id": None, "queue_len": q.length(r["employee"])}

    def _cancel_running(self, q, cur, by, reason, note):
        task = cur["task"]
        if reason not in equeue.CANCEL_REASONS:
            raise ToolError(f"reason inválido: {reason}")
        with state.locked() as st:
            found = next(((b, t) for b in st.get("batches", {}).values() for t in b.get("tasks", [])
                          if t.get("qtask") == task), None)
            if found is None or found[1].get("done"):
                raise ToolError(f"la tarea {task} ya terminó o no tiene hilo en el motor")
            b, t = found
            if t.get("status") != "launched" or not t.get("threadId"):
                raise ToolError(f"la tarea {task} aún no tiene hilo; reintenta en unos segundos")
            try:
                t3.call(profile.hosts()[b["host"]], b["host"], "t3_thread_interrupt",
                        {"threadId": t["threadId"], "reason": "chopshop: tarea %s cancelada" % task})
            except (t3.T3Error, KeyError) as e:
                raise ToolError(f"no pude interrumpir el hilo {t['threadId']}: {e}")
            t.update(done=True, cancelled=True, pending=None,
                     last_error=("cancelada por %s (%s)" % (by, reason) + (": " + note if note else ""))[:300])
        r = q.cancel_running(task, by, reason=reason, note=note, thread_id=t["threadId"])
        if r is None:
            raise ToolError(f"la tarea {task} cambió de estado mientras se cancelaba")
        return {"task": task, "employee": r["employee"], "state": r["state"], "reason": r["cancel_reason"],
                "phase": "running", "thread_id": t["threadId"], "queue_len": q.length(r["employee"])}

    def employee_rename(self, employee, name, by="human"):
        cfg = self._db()
        employees.ensure_schema(self.conn)
        try:
            body = employees.rename(self.conn, employee, name, by or "human")
        except employees.EmployeeError as e:
            raise ToolError(str(e))
        emp = employees.get(self.conn, employee)
        events.emit_envelope(self.conn, cfg, "employee.renamed", emp["project"], body, needs=None,
                             subject=envelope.subject("desk", employee, body["name"] or body["role"]))
        return body
