"""Pasos 2 y 3: fanout / tick (lanzar, seguir, detectar pending_question) / gather / answer / settle.
Regla anti-Telar: no hay sesiones aquí; cada hilo es un hilo de T3 y Chopshop solo guarda su id."""
import re
import time

from . import events, graph, home, inbox, profile, reactions, settings, state, t3

TERMINAL = {"completed", "failed", "cancelled", "interrupted", "rolled_back"}


# ---------- ruteo ----------
def route(prof, n_tasks, cli_host=None, max_parallel=None):
    """Devuelve (host, cap, notas). Un lote más grande que el tope del host va al host de desborde (perfil o general.overflow_host)."""
    hs = profile.hosts()
    notes = []
    if cli_host:
        host = cli_host
    else:
        host = prof["host"]
        ov = prof.get("overflow_host") or settings.general("overflow_host")
        if ov and n_tasks > hs[host].get("cap", 2) and ov in hs and ov != host:
            if prof.get("scratch") or ov in (prof.get("remote_repos") or {}) or prof.get("t3_project"):
                notes.append("lote de %d > tope de %s (%d): se manda a %s" % (n_tasks, host, hs[host].get("cap", 2), ov))
                host = ov
            else:
                notes.append("lote > tope de %s pero el perfil no define remote_repos.%s: se queda en %s con tope %d"
                             % (host, ov, host, hs[host].get("cap", 2)))
    if host not in hs:
        raise profile.ProfileError("host desconocido: %s" % host)
    cap = hs[host].get("cap", 2)
    want = max_parallel or prof.get("max_parallel") or cap
    if want > cap:
        notes.append("--max-parallel %d recortado al tope de %s (%d)" % (want, host, cap))
    return host, min(want, cap), notes


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40] or "tarea"


def normalize_tasks(items):
    out = []
    for it in items:
        if isinstance(it, str):
            it = {"prompt": it}
        if not isinstance(it, dict) or not (it.get("prompt") or it.get("title")):
            raise profile.ProfileError("tarea inválida (necesita prompt o title): %r" % (it,))
        it = dict(it)
        it.setdefault("prompt", it.get("title"))
        it.setdefault("title", it["prompt"].strip().splitlines()[0][:70])
        out.append(it)
    return out


def skip_reason(prof, t):
    r = prof.get("ready") or {}
    labels = set(t.get("labels") or [])
    if "labels" in t and r.get("labels_all") and not set(r["labels_all"]) <= labels:
        return "falta label %s" % sorted(set(r["labels_all"]) - labels)
    if "labels" in t and set(r.get("skip_if_labeled") or []) & labels:
        return "tiene label %s" % sorted(set(r["skip_if_labeled"]) & labels)
    if t.get("assignee") and t["assignee"] in (r.get("skip_if_assigned") or []):
        return "asignada a %s" % t["assignee"]
    return None


def compose_prompt(prof, host, hostcfg, task):
    """Las reglas del perfil viajan como preámbulo del prompt (las 'instrucciones de bot')."""
    lines = ["[Chopshop] Proyecto %s. Reglas:" % prof["project"]]
    if prof.get("can_run"):
        lines.append("- Puedes ejecutar: %s." % ", ".join(map(str, prof["can_run"])))
    if prof.get("cannot_run"):
        lines.append("- NO ejecutes: %s." % ", ".join(map(str, prof["cannot_run"])))
    if hostcfg.get("purpose") == "tests-only":
        lines.append("- Este host (%s) es solo para tests: no levantes dev servers ni hagas deploys." % host)
    a = prof.get("autonomy") or {}
    if a.get("open_pr") == "draft-only":
        lines.append("- Si abres un PR, que sea en borrador (draft).")
    if a.get("merge") == "never":
        lines.append("- Nunca hagas merge a main.")
    d = prof.get("decider") or {}
    if d.get("name"):
        lines.append("- Si tienes una duda que bloquea, pregúntala con la herramienta de preguntas; la decide %s." % d["name"])
    if task.get("issue"):
        lines.append("- Issue: #%s" % task["issue"])
    return "\n".join(lines) + "\n\nTarea:\n" + task["prompt"]


# ---------- llamadas a T3 ----------
def _call(st_hostcfgs, host, tool, args=None):
    return t3.call(st_hostcfgs[host], host, tool, args)


def resolve_project(prof, host, hostcfg):
    """projectId de T3 en ese host (None si el perfil usa scratch)."""
    if prof.get("scratch"):
        return None
    import os
    want = prof.get("t3_project")
    root = (prof.get("remote_repos") or {}).get(host) or (prof.get("repo") if t3.is_local(hostcfg) else None)
    if root:
        root = os.path.realpath(os.path.expanduser(root)) if t3.is_local(hostcfg) else root
    out = t3.call(hostcfg, host, "t3_project_list", {"limit": 100})
    for p in (out or {}).get("projects", []):
        if p.get("deletedAt"):
            continue
        wr = p.get("workspaceRoot") or ""
        if want and want in (p["id"], p["title"]):
            return p["id"]
        if root and (wr == root or (t3.is_local(hostcfg) and os.path.realpath(wr) == root)
                     or wr.replace("~", "") .endswith(root.replace("~", ""))):
            return p["id"]
    if not want and not root:
        for p in (out or {}).get("projects", []):
            if p["title"] == prof["project"] and not p.get("deletedAt"):
                return p["id"]
    raise t3.T3Error("no encontré el proyecto %s en T3 de %s (define t3_project o remote_repos en el perfil)"
                     % (prof["project"], host))


def launch_args(prof, batch, task, hostcfg):
    args = {"title": "[%s] %s" % (batch["id"], task["title"])[:120],
            "runtimeMode": prof.get("runtime_mode", "approval-required"),
            "message": task["_composed"] if "_composed" in task else task["prompt"]}
    if batch.get("projectId"):
        args["projectId"] = batch["projectId"]
        if prof.get("workspace", "worktree") == "worktree":
            pat = (prof.get("branches") or {}).get("pattern") or "chopshop/{issue}-{slug}"
            br = pat.format(issue=task.get("issue") or task["id"], slug=slug(task["title"]), task=task["id"], batch=batch["id"])
            args["workspaceStrategy"] = {"type": "worktree", "branch": br, "baseRef": prof.get("base_ref", "main")}
    else:
        args["scratch"] = True
    m = prof.get("model")
    if m:  # opcional: con provider: any no se fija modelo y T3 usa el default del proyecto
        inst, _, model = str(m).partition("/")
        args["modelSelection"] = {"instanceId": inst, "model": model}
    return args


# ---------- fanout ----------
def create_batch(prof, items, host, cap, notes):
    tasks = normalize_tasks(items)
    with state.locked() as st:
        bid = state.new_batch_id(st)
        batch = {"id": bid, "project": prof["project"], "host": host, "max_parallel": cap,
                 "created": state.now(), "notes": notes, "projectId": None, "tasks": []}
        if prof.get("reactions"):
            batch["rx"] = True   # las reacciones solo aplican a lotes creados con reglas activas (los viejos no se tocan)
        for i, t in enumerate(tasks, 1):
            rec = {"id": "t-%s-%d" % (bid[2:], i), "title": t["title"], "prompt": t["prompt"], "issue": t.get("issue"),
                   "status": "queued", "threadId": None, "link": None, "t3status": None, "done": False,
                   "notified": [], "settled": False}
            why = skip_reason(prof, t)
            if why:
                rec.update(status="skipped", done=True, skip_reason=why)
            batch["tasks"].append(rec)
        st["batches"][bid] = batch
    return bid


def dry_run(prof, items, host, cap, notes):
    hs = profile.hosts()
    tasks = normalize_tasks(items)
    out = {"host": host, "max_parallel": cap, "notes": notes, "tasks": []}
    fake = {"id": "b-DRY", "projectId": "<projectId>" if not prof.get("scratch") else None}
    for i, t in enumerate(tasks, 1):
        t = dict(t, id="t-DRY-%d" % i)
        why = skip_reason(prof, t)
        t["_composed"] = compose_prompt(prof, host, hs[host], t)
        out["tasks"].append({"skip": why, "launch": None if why else launch_args(prof, fake, t, hs[host])})
    return out


# ---------- tick ----------
def _refresh(hc, host, task):
    th = t3.call(hc, host, "t3_thread_read", {"threadId": task["threadId"], "limit": 1, "maxCharsPerItem": 1})
    return th.get("thread", {})


def _questions(hc, host, task):
    ids = t3.call(hc, host, "t3_pending_request", {"action": "list", "threadId": task["threadId"]}).get("requestIds", [])
    return ids


def tick(batch_id=None, adhoc_files=None, log=print):
    """Una pasada: refresca hilos, emite eventos, lanza tareas en cola mientras haya cupo."""
    hs = profile.hosts()
    changed = []
    with state.locked() as st:
        batches = [st["batches"][batch_id]] if batch_id else list(st["batches"].values())
        for b in batches:
            if all(t["done"] for t in b["tasks"]) and (b.get("done_notified") or (b.get("graph") and graph.finished(st, b))):
                continue
            hc = hs[b["host"]]
            try:
                prof = profile.load(b["project"])
            except profile.ProfileError as e:
                log("! %s: %s" % (b["id"], e))
                continue
            if not b.get("rx") and prof.get("reactions"):
                prof = dict(prof, reactions=[])
            running = 0
            for t in b["tasks"]:
                if t["status"] != "launched" or t["done"]:
                    continue
                try:
                    th = _refresh(hc, b["host"], t)
                    t["last_error"] = None
                    t["t3status"] = th.get("status")
                    t["settled"] = bool(th.get("settled"))
                    t["pullRequests"] = [p.get("url") for p in (th.get("pullRequests") or [])]
                    npend = th.get("pendingRequestCount") or 0
                    if th.get("status") == "waiting" or npend:
                        known = {q["request"]: q for q in (t.get("pending") or {}).get("questions", [])}
                        qs_now = []
                        for rid in _questions(hc, b["host"], t):
                            q = known.get(rid)
                            if q is None:
                                raw = t3.call(hc, b["host"], "t3_pending_request", {"action": "read", "threadId": t["threadId"], "requestId": rid})
                                qq = (raw.get("questions") or [{}])[0]
                                q = {"request": rid, "summary": (qq.get("question") or "")[:300],
                                     "options": [o.get("label") for o in qq.get("options", [])]}
                            qs_now.append(q)
                            if rid not in t.get("reacted", []):
                                reactions.on_question(st, b, t, prof, q, hc, log, adhoc_files, rid)
                            if rid in t["notified"]:
                                continue
                            body = {"batch": b["id"], "task": t["id"], "thread": t["threadId"], "host": b["host"],
                                    "request": rid, "summary": q["summary"], "options": q["options"],
                                    "reply": 'chopshop answer %s "..."' % t["id"]}
                            ok_all, had, res = events.emit(st, "pending_question", b["project"], body, adhoc_files)
                            if ok_all or not had:   # si hay destinatarios y alguno falló, se reintenta en la próxima pasada
                                t["notified"].append(rid)
                            changed.append(("pending_question", t["id"], res))
                            log("evento pending_question %s (%s) -> %s" % (t["id"], rid[:12], res or "sin destinatarios"))
                        # permisos (comandos/ediciones): MCP no los lista ni los puede aprobar → solo se avisa
                        napp = max(npend - len(qs_now), 0)
                        if napp and napp > t.get("approval_notified", 0):
                            body = {"batch": b["id"], "task": t["id"], "thread": t["threadId"], "host": b["host"], "count": napp,
                                    "note": "el hilo espera un permiso; solo se aprueba desde la UI de T3 (no por MCP)"}
                            ok_all, had, res = events.emit(st, "pending_approval", b["project"], body, adhoc_files)
                            if ok_all or not had:
                                t["approval_notified"] = napp
                            changed.append(("pending_approval", t["id"], res))
                            log("evento pending_approval %s (%d) -> %s" % (t["id"], napp, res or "sin destinatarios"))
                        t["pending"] = {"questions": qs_now, "approvals": napp} if (qs_now or napp) else None
                        reactions.check_waiting(st, b, t, prof, qs_now, adhoc_files, log)
                        reactions.check_resolved(t, qs_now)
                        aa = t.pop("_auto_answer", None)
                        if aa:
                            try:
                                answer_inline(hc, b, t, aa["choice"], aa["request"], by="auto")
                                t["pending"] = None
                            except Exception as e:  # noqa: BLE001
                                log("! respuesta auto %s: %s" % (t["id"], str(e)[:160]))
                    else:
                        t["pending"] = None
                        t["approval_notified"] = 0
                        reactions.check_resolved(t, [])
                    if th.get("status") in TERMINAL:
                        t["done"] = True
                        t["pending"] = None
                        try:
                            full = t3.call(hc, b["host"], "t3_thread_read", {"threadId": t["threadId"], "limit": 30, "maxCharsPerItem": 1500})
                            msgs = [i for i in full.get("items", []) if i.get("type") == "assistant_message" and i.get("text")]
                            if msgs:
                                t["result"] = msgs[-1]["text"][:1500]
                        except t3.T3Error:
                            pass
                        ok_all, had, res = events.emit(st, "task_done", b["project"], {"batch": b["id"], "task": t["id"],
                                                       "thread": t["threadId"], "host": b["host"], "status": th["status"]}, adhoc_files)
                        changed.append(("task_done", t["id"], res))
                        reactions.on_terminal(st, b, t, th["status"], prof, hc, log, adhoc_files)
                    else:
                        if th.get("status") != "waiting":
                            reactions.on_progress(st, b, t, th, prof, hc, log, adhoc_files)
                        if not t["done"]:
                            running += 1
                except t3.T3Error as e:
                    t["last_error"] = str(e)[:300]
                    running += 1
                    log("! %s: %s" % (t["id"], str(e)[:200]))
            if b.get("graph"):
                try:
                    graph.step(st, b, prof, log, adhoc_files)
                except Exception as ex:  # noqa: BLE001 - un fallo del grafo no debe frenar el resto del tick
                    log("! grafo %s: %s" % (b["graph"], str(ex)[:200]))
            # lanzar en cola
            queued = [t for t in b["tasks"] if t["status"] == "queued"]
            if queued:
                try:
                    if not b.get("projectId") and not prof.get("scratch"):
                        b["projectId"] = resolve_project(prof, b["host"], hc)
                except t3.T3Error as e:
                    log("! %s: %s" % (b["id"], e))
                    queued = []
            for t in queued:
                if running >= b["max_parallel"]:
                    break
                t["_composed"] = compose_prompt(prof, b["host"], hc, t)
                try:
                    r = t3.call(hc, b["host"], "t3_thread_launch", launch_args(prof, b, t, hc))
                except t3.T3Error as e:   # sin reintento automático: T3 no tiene clave de idempotencia
                    t.pop("_composed", None)
                    t.update(status="launch_failed", done=True, last_error=str(e)[:300])
                    log("! lanzamiento falló %s: %s" % (t["id"], str(e)[:200]))
                    continue
                t.pop("_composed", None)
                t.update(status="launched", threadId=r["threadId"], link=r.get("link"), t3status=r.get("status"),
                         runId=r.get("runId"), projectId=r.get("projectId"))
                running += 1
                log("lanzado %s -> %s" % (t["id"], r["threadId"]))
            if all(t["done"] for t in b["tasks"]) and not b.get("done_notified") and not b.get("graph"):
                b["done_notified"] = True
                events.emit(st, "batch_done", b["project"], {"batch": b["id"], "host": b["host"],
                            "tasks": {t["id"]: t["status"] if t["status"] != "launched" else t["t3status"] for t in b["tasks"]}}, adhoc_files)
                changed.append(("batch_done", b["id"], None))
    return changed


def wait(batch_id, timeout=900, interval=10, adhoc_files=None, log=print):
    end = time.time() + timeout
    while True:
        tick(batch_id, adhoc_files, log)
        if all(t["done"] for t in state.read()["batches"][batch_id]["tasks"]):
            return True
        if time.time() > end:
            return False
        time.sleep(interval)


# ---------- answer / gather / settle ----------
def _find_task(st, task_id):
    for b in st["batches"].values():
        for t in b["tasks"]:
            if t["id"] == task_id:
                return b, t
    raise profile.ProfileError("tarea desconocida: %s" % task_id)


def _resolve_answer(q, choice):
    opts = q.get("options", [])
    val = lambda o: o.get("value") or o["label"]  # noqa: E731
    picks = [c.strip() for c in choice.split(",")] if q.get("multiSelect") else [choice]
    res = []
    for c in picks:
        if c.isdigit() and 1 <= int(c) <= len(opts):
            res.append(val(opts[int(c) - 1]))
            continue
        m = [o for o in opts if o["label"].lower() == c.lower() or (o.get("value") or "").lower() == c.lower()]
        if m:
            res.append(val(m[0]))
            continue
        if opts and q.get("allowCustomAnswer") is False:
            raise profile.ProfileError("'%s' no es una opción válida" % c)
        res.append(c)
    return res if q.get("multiSelect") else res[0]


def _flat(v):
    return ", ".join(map(str, v)) if isinstance(v, (list, tuple)) else str(v)


def _send_answer(hc, host, t, choice, request=None):
    ids = _questions(hc, host, t)
    if not ids:
        raise profile.ProfileError("%s no tiene preguntas pendientes" % t["id"])
    if request:
        ids = [r for r in ids if r.startswith(request)] or ids
    if len(ids) > 1 and not request:
        raise profile.ProfileError("hay %d preguntas pendientes; usa --request <id>" % len(ids))
    q = t3.call(hc, host, "t3_pending_request", {"action": "read", "threadId": t["threadId"], "requestId": ids[0]})
    if len(q["questions"]) != 1:
        raise profile.ProfileError("la petición tiene varias preguntas; no soportado en el MVP")
    qq = q["questions"][0]
    ans = {qq["id"]: _resolve_answer(qq, choice)}
    t3.call(hc, host, "t3_pending_request", {"action": "respond", "threadId": t["threadId"], "requestId": ids[0], "answers": ans})
    return ans, qq


def _record_answer(t, qq, ans, by):
    t.setdefault("answered", []).append({"summary": (qq.get("question") or "")[:300], "choice": _flat(list(ans.values())[0]),
                                         "options": [o.get("label") for o in qq.get("options", [])], "ts": state.now(), "by": by or "?"})


def answer_inline(hc, b, t, choice, request=None, by=None):
    """Responde sin tomar el lock (para usar dentro de tick, que ya lo tiene)."""
    ans, qq = _send_answer(hc, b["host"], t, choice, request)
    _record_answer(t, qq, ans, by)
    return ans


def answer(task_id, choice, request=None, by=None):
    hs = profile.hosts()
    st = state.read()
    b, t = _find_task(st, task_id)
    ans, qq = _send_answer(hs[b["host"]], b["host"], t, choice, request)
    try:   # historial local para la UI: qué se preguntó y qué se respondió
        with state.locked() as st2:
            _, t2 = _find_task(st2, task_id)
            _record_answer(t2, qq, ans, by)
    except Exception:
        pass
    return ans


def stop(batch_id=None, task_id=None, log=print):
    """Interrumpe el turno en curso de los hilos (t3_thread_interrupt). No archiva ni borra nada."""
    hs = profile.hosts()
    n = 0
    with state.locked() as st:
        batches = [st["batches"][batch_id]] if batch_id else list(st["batches"].values())
        for b in batches:
            for t in b["tasks"]:
                if task_id and t["id"] != task_id:
                    continue
                if t["status"] != "launched" or t["done"]:
                    continue
                try:
                    t3.call(hs[b["host"]], b["host"], "t3_thread_interrupt", {"threadId": t["threadId"], "reason": "chopshop stop"})
                    n += 1
                    log("interrumpido %s" % t["id"])
                except t3.T3Error as e:
                    log("! %s: %s" % (t["id"], str(e)[:200]))
    return n


def snapshot(events_limit=80):
    """Vista de solo lectura del estado local (sin llamar a T3) para la UI y los bots."""
    import json as _json
    st = state.read()
    out = {"generated": state.now(), "home": home.home(),
           "hosts": {n: {"cap": h.get("cap"), "purpose": h.get("purpose"), "transport": "local" if t3.is_local(h) else "remote"}
                     for n, h in profile.hosts().items()},
           "profiles": profile.list_projects(), "batches": [], "events": [],
           "inbox": inbox.status(),
           "subscriptions": {n: {"project": s.get("project"), "events": s.get("events")} for n, s in st.get("subscriptions", {}).items()}}
    out["graphs"] = graph.view(st)
    for b in sorted(st["batches"].values(), key=lambda x: x["id"], reverse=True):
        bb = {k: b.get(k) for k in ("id", "project", "host", "max_parallel", "created", "notes", "done_notified", "graph")}
        bb["tasks"] = []
        for t in b["tasks"]:
            row = {k: t.get(k) for k in ("id", "title", "status", "t3status", "done", "settled", "link", "threadId", "pending",
                                         "last_error", "skip_reason", "result", "pullRequests", "issue", "answered", "level", "reactions",
                                         "escalation", "bot_wait", "retry_of", "retried_by", "node")}
            row["prompt"] = (t.get("prompt") or "")[:400]
            bb["tasks"].append(row)
        out["batches"].append(bb)
    try:
        with open(home.events_log()) as f:
            lines = f.readlines()[-events_limit:]
        for l in lines:
            try:
                out["events"].append(_json.loads(l))
            except ValueError:
                pass
        out["events"].reverse()
    except OSError:
        pass
    return out


def gather(batch_id):
    hs = profile.hosts()
    with state.locked() as st:
        if batch_id not in st["batches"]:
            raise profile.ProfileError("lote desconocido: %s" % batch_id)
        b = st["batches"][batch_id]
        rows = []
        for t in b["tasks"]:
            row = {"task": t["id"], "title": t["title"], "status": t["status"], "t3status": t.get("t3status"),
                   "link": t.get("link"), "prs": t.get("pullRequests") or [], "result": None, "pending": []}
            if t.get("threadId"):
                hc = hs[b["host"]]
                try:
                    th = t3.call(hc, b["host"], "t3_thread_read", {"threadId": t["threadId"], "limit": 50, "maxCharsPerItem": 1200})
                    row["t3status"] = t["t3status"] = th["thread"].get("status")
                    row["prs"] = t["pullRequests"] = [p.get("url") for p in (th["thread"].get("pullRequests") or [])]
                    msgs = [i for i in th.get("items", []) if i.get("type") == "assistant_message" and i.get("text")]
                    if msgs:
                        row["result"] = t["result"] = msgs[-1]["text"][:1200]
                    if th["thread"].get("pendingRequestCount"):
                        row["pending"] = [r for r in _questions(hc, b["host"], t)]
                except t3.T3Error as e:
                    row["error"] = str(e)[:200]
            elif t["status"] == "skipped":
                row["result"] = "omitida: " + t.get("skip_reason", "")
            rows.append(row)
        return b, rows


def settle(batch_id, log=print):
    """Marca los hilos como settled (nunca archiva; no hay código que archive)."""
    hs = profile.hosts()
    n = 0
    with state.locked() as st:
        b = st["batches"][batch_id]
        for t in b["tasks"]:
            if not t.get("threadId") or t.get("settled"):
                continue
            try:
                t3.call(hs[b["host"]], b["host"], "t3_thread_organize", {"threadId": t["threadId"], "action": "settle"})
                t["settled"] = True
                n += 1
                log("settled %s" % t["id"])
            except t3.T3Error as e:
                log("! %s: %s" % (t["id"], str(e)[:200]))
    return n
