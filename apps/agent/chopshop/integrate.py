"""Integración: cuando un hilo de T3 termina, lleva su rama a la base (main) y lo settlea.
Pasos (todo con `git` en el worktree que creó T3 para el hilo; Chopshop no crea worktrees):
  1. worktree limpio y en la rama del hilo;
  2. `git fetch origin` + `git rebase origin/<base>` (conflicto → `rebase --abort`, estado `conflict`);
  3. tests del perfil (`integration.test_cmd`); sin tests no se integra nunca (`no_tests`);
  4. `git push origin HEAD:<base>` sin reescribir historia; si lo rechazan, hasta 2 reintentos de fetch+rebase+tests;
  5. solo tras un push correcto: `t3_thread_organize settle` (nunca archiva), `integrated: true` y evento `task_integrated`.
`runner(argv, cwd) -> (rc, salida)` es inyectable para probar sin repo real."""
import os
import subprocess

from . import engine, events, profile, state, t3

DEFAULT_TIMEOUT = 900
PUSH_RETRIES = 2
OK_STATUSES = ("ok", "dry_run", "already")
REJECTED_HINTS = ("non-fast-forward", "[rejected]", "fetch first", "stale info")


class IntegrateError(profile.ProfileError):
    pass


# ---------- guardia del push ----------
# Prohibido reescribir la base: se rechaza cualquier push con --force, -f (también agrupado, p. ej. -uf),
# --force-with-lease / --force-if-includes o un refspec con '+' (p. ej. +HEAD:main).
def check_push(argv):
    if "push" not in argv:
        return
    for a in argv[argv.index("push") + 1:]:
        if a.startswith("--force") or a.startswith("+") or ":+" in a or (a.startswith("-") and not a.startswith("--") and "f" in a[1:]):
            raise IntegrateError("push prohibido: %r reescribe historia" % a)


def subprocess_runner(timeout=DEFAULT_TIMEOUT):
    """Runner real: ejecuta argv sin shell, salida combinada; timeout → rc 124."""
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")

    def run(argv, cwd):
        try:
            p = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, text=True, timeout=timeout)
            return p.returncode, p.stdout or ""
        except subprocess.TimeoutExpired as e:
            out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            return 124, out + "\n[timeout tras %ss]" % timeout
        except OSError as e:
            return 127, "%s: %s" % (argv[0], e)
    return run


def _tail(s, n=1500):
    s = (s or "").strip()
    return s if len(s) <= n else "…" + s[-n:]


# ---------- pasos git ----------
def integrate_worktree(worktree, branch, base, test_cmd, test_cwd=None, runner=None, dry_run=False,
                       retries=PUSH_RETRIES, log=print):
    """Ejecuta los pasos 1-4 en `worktree`. Devuelve {"status", "steps", ...}; nunca lanza por fallos de git/tests."""
    runner = runner or subprocess_runner()
    steps = []
    res = {"status": None, "worktree": worktree, "branch": branch, "base": base, "steps": steps}

    def git(*args):
        argv = ["git"] + list(args)
        check_push(argv)
        rc, out = runner(argv, worktree)
        steps.append({"cmd": " ".join(argv), "rc": rc})
        return rc, out or ""

    def done(status, detail=None):
        res["status"] = status
        if detail:
            res["detail"] = _tail(detail)
        log("integrate: %s%s" % (status, (" — " + _tail(detail, 300)) if detail else ""))
        return res

    if not test_cmd:
        return done("no_tests", "el perfil no define integration.test_cmd: nunca se integra sin pruebas")
    rc, out = git("status", "--porcelain")
    if rc != 0:
        return done("git_error", out)
    if out.strip():
        return done("dirty", "el worktree tiene cambios sin commitear:\n" + out)
    rc, out = git("rev-parse", "--abbrev-ref", "HEAD")
    if rc != 0 or out.strip() != branch:
        return done("wrong_branch", "el worktree está en %r, se esperaba %r" % (out.strip(), branch))

    def sync_and_test():
        rc, out = git("fetch", "origin")
        if rc != 0:
            return done("fetch_failed", out)
        rc, out = git("rebase", "origin/" + base)
        if rc != 0:
            git("rebase", "--abort")
            return done("conflict", out)
        log("integrate: rebase sobre origin/%s ok; tests: %s" % (base, " ".join(test_cmd)))
        cwd = os.path.join(worktree, test_cwd) if test_cwd else worktree
        rc, out = runner(list(test_cmd), cwd)
        steps.append({"cmd": " ".join(test_cmd), "rc": rc})
        res["tests"] = _tail(out, 800)
        if rc != 0:
            return done("tests_failed", out)
        return None

    attempt = 0
    while True:
        failed = sync_and_test()
        if failed:
            return failed
        if dry_run:
            return done("dry_run")
        rc, out = git("push", "origin", "HEAD:" + base)
        if rc == 0:
            rc2, sha = git("rev-parse", "HEAD")
            if rc2 == 0:
                res["commit"] = sha.strip()
            return done("ok")
        if not any(h in out for h in REJECTED_HINTS):
            return done("push_failed", out)
        if attempt >= retries:
            return done("push_rejected", out)
        attempt += 1
        log("integrate: push rechazado (la base avanzó); reintento %d/%d" % (attempt, retries))


# ---------- orquestación con T3 y el estado ----------
def _thread_info(hc, host, thread_id):
    th = t3.call(hc, host, "t3_thread_read", {"threadId": thread_id, "limit": 1, "maxCharsPerItem": 1})
    return (th or {}).get("thread") or {}


def _targets(target, thread, host, project):
    """Lista de (batch|None, task|None, host, project, threadId)."""
    st = state.read()
    if thread:
        if not host or not project:
            raise IntegrateError("con --thread hacen falta --host y --project (el perfil da los tests)")
        for b in st["batches"].values():
            for t in b["tasks"]:
                if t.get("threadId") == thread:
                    return [(b, t, host, project, thread)]
        return [(None, None, host, project, thread)]
    if not target:
        raise IntegrateError("uso: chopshop integrate <batch|task> | --thread ID --host H --project P")
    if target in st["batches"]:
        b = st["batches"][target]
        out = [(b, t, b["host"], b["project"], t["threadId"]) for t in b["tasks"] if t.get("threadId")]
        if not out:
            raise IntegrateError("el lote %s no tiene hilos lanzados" % target)
        return out
    b, t = engine._find_task(st, target)
    if not t.get("threadId"):
        raise IntegrateError("la tarea %s no tiene hilo de T3" % target)
    return [(b, t, b["host"], b["project"], t["threadId"])]


def _mark(b, t, thread_id, host, project, res, adhoc_files):
    body = {"thread": thread_id, "host": host, "branch": res["branch"], "base": res["base"], "commit": res.get("commit"),
            "settled": res.get("settled", False)}
    with state.locked() as st:
        if b and t:
            tt = next(x for x in st["batches"][b["id"]]["tasks"] if x["id"] == t["id"])
            tt["integrated"] = True
            tt["integratedAt"] = state.now()
            tt["integratedCommit"] = res.get("commit")
            if res.get("settled"):
                tt["settled"] = True
            body.update(batch=b["id"], task=t["id"])
        _, _, deliv = events.emit(st, "task_integrated", project, body, adhoc_files)
    res["delivery"] = deliv


def integrate_one(b, t, host, project, thread_id, dry_run=False, runner=None, adhoc_files=None, log=print):
    label = t["id"] if t else thread_id
    if t and t.get("integrated"):
        return {"target": label, "status": "already", "thread": thread_id}
    hs = profile.hosts()
    if host not in hs:
        raise IntegrateError("host desconocido: %s" % host)
    hc = hs[host]
    prof = profile.load(project)
    errs = profile.validate_integration(prof)
    if errs:
        raise IntegrateError("; ".join(errs))
    cfg = prof.get("integration") or {}
    th = _thread_info(hc, host, thread_id)
    branch, worktree = th.get("branch"), th.get("worktreePath")
    base = prof.get("base_ref") or "main"

    def reject(status, why):
        log("integrate %s: %s (%s)" % (label, status, why))
        return {"target": label, "thread": thread_id, "status": status, "detail": why, "steps": []}

    if th.get("status") != "completed":
        return reject("not_ready", "el hilo no terminó (estado T3: %s)" % th.get("status"))
    if th.get("pendingRequestCount") or (t and t.get("pending")):
        return reject("not_ready", "el hilo tiene preguntas o permisos pendientes")
    if not branch or not worktree:
        return reject("no_worktree", "T3 no da rama o worktree del hilo (¿scratch o workspace local?)")
    if not os.path.isdir(worktree):
        return reject("no_worktree", "el worktree %s no existe en esta máquina" % worktree)
    timeout = cfg.get("timeout") or DEFAULT_TIMEOUT
    res = integrate_worktree(worktree, branch, base, cfg.get("test_cmd"), cfg.get("test_cwd"),
                             runner or subprocess_runner(timeout), dry_run, log=log)
    res.update(target=label, thread=thread_id)
    if res["status"] != "ok":
        return res
    try:
        t3.call(hc, host, "t3_thread_organize", {"threadId": thread_id, "action": "settle"})
        res["settled"] = True
    except t3.T3Error as e:  # el push ya está hecho: se marca integrada igual y se avisa
        res["settled"] = False
        res["settle_error"] = str(e)[:300]
        log("! settle %s: %s" % (label, str(e)[:200]))
    _mark(b, t, thread_id, host, project, res, adhoc_files)
    return res


def run(target=None, thread=None, host=None, project=None, dry_run=False, runner=None, adhoc_files=None, log=print):
    """Integra una tarea, todas las de un lote (en orden) o un hilo suelto. Devuelve la lista de resultados."""
    out = []
    for b, t, h, p, tid in _targets(target, thread, host, project):
        out.append(integrate_one(b, t, h, p, tid, dry_run, runner, adhoc_files, log))
    return out


def ok(results):
    return bool(results) and all(r["status"] in OK_STATUSES for r in results)
