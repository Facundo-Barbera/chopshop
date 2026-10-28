"""CLI de Chopshop (stdlib). Uso: chopshop <comando> ... (ver README.md)."""
import argparse
import json
import os
import sys
import time

from . import engine, events, graph, home, inbox, metrics, miniyaml, profile, state, t3

HELP_EPILOG = """comandos: profile list|show|check | fanout | run | poll | watch | status | snapshot | metrics | wait | gather | answer [--queue] | stop | settle | subscribe | graph new|run|status | mcp (servidor MCP stdio) | release --worktree DIR [--thread ID] | agent run|status|token|check-config|print-unit"""


def _load_tasks(args):
    items = list(args.task or [])
    if args.from_file:
        data = miniyaml.load(args.from_file)
        if isinstance(data, dict):
            data = data.get("tasks")
        if not isinstance(data, list):
            raise profile.ProfileError("%s: se esperaba una lista de tareas (o tasks: [...])" % args.from_file)
        items += data
    if not items:
        raise profile.ProfileError("no hay tareas: usa --task o --from")
    return items


def cmd_profile(a):
    if a.action == "list":
        for p in profile.list_projects():
            print(p)
        return 0
    prof = profile.load(a.project)
    errs = profile.validate(prof)
    if a.action == "show":
        print(json.dumps({k: v for k, v in prof.items() if not k.startswith("_")}, indent=2, ensure_ascii=False))
    for k in prof["_unknown"]:
        print("aviso: campo desconocido en el perfil: %s" % k, file=sys.stderr)
    for e in errs:
        print("error: " + e, file=sys.stderr)
    if a.action == "check" and not errs:
        print("ok: %s (%s)" % (prof["project"], prof["_path"]))
    return 1 if errs else 0


def cmd_fanout(a):
    prof = profile.load(a.project)
    errs = profile.validate(prof)
    if errs:
        raise profile.ProfileError("; ".join(errs))
    items = _load_tasks(a)
    host, cap, notes = engine.route(prof, len(items), a.host, a.max_parallel)
    for n in notes:
        print("nota:", n)
    if a.dry_run:
        print(json.dumps(engine.dry_run(prof, items, host, cap, notes), indent=2, ensure_ascii=False))
        return 0
    bid = engine.create_batch(prof, items, host, cap, notes)
    print("batch %s (%d tareas, host %s, paralelo %d)" % (bid, len(items), host, cap))
    engine.tick(bid, a.webhook_file)
    if a.wait:
        ok = engine.wait(bid, a.timeout, a.interval, a.webhook_file)
        print("terminado" if ok else "timeout: el lote sigue (usa `chopshop wait %s`)" % bid)
    else:
        print("sigue con: chopshop watch | chopshop wait %s | chopshop gather %s" % (bid, bid))
    return 0


def cmd_run(a):
    a.task = [a.prompt]
    a.from_file = None
    a.max_parallel = 1
    return cmd_fanout(a)


def cmd_poll(a):
    inbox.drain(engine.answer)
    engine.tick(a.batch, a.webhook_file)
    return 0


def cmd_watch(a):
    print("watch cada %ss (Ctrl-C para salir)" % a.interval)
    last_metrics = 0
    try:
        while True:
            inbox.heartbeat(a.interval)
            inbox.drain(engine.answer)
            engine.tick(None, a.webhook_file)
            if time.time() - last_metrics > 30:
                last_metrics = time.time()
                try:
                    metrics.collect_remote()
                except Exception as e:  # el monitor nunca debe tumbar al watch
                    print("métricas remotas: %s" % e)
            inbox.heartbeat(a.interval)
            time.sleep(a.interval)
    except KeyboardInterrupt:
        return 0


def cmd_metrics(a):
    if a.collect:
        metrics.collect_remote()
    print(json.dumps(metrics.read(), ensure_ascii=False))
    return 0


def cmd_status(a):
    st = state.read()
    batches = [st["batches"][a.batch]] if a.batch else list(st["batches"].values())
    if a.batch and a.batch not in st["batches"]:
        raise profile.ProfileError("lote desconocido: %s" % a.batch)
    for b in batches:
        print("%s  %s  host=%s  paralelo=%d" % (b["id"], b["project"], b["host"], b["max_parallel"]))
        for t in b["tasks"]:
            extra = t.get("skip_reason") or t.get("last_error") or ""
            print("  %-12s %-13s t3=%-10s %s %s" % (t["id"], t["status"], t.get("t3status") or "-", t["title"][:50], ("(" + extra[:60] + ")") if extra else ""))
    if not batches:
        print("sin lotes")
    return 0


def cmd_wait(a):
    ok = engine.wait(a.batch, a.timeout, a.interval, a.webhook_file)
    print("terminado" if ok else "timeout")
    return 0 if ok else 2


def cmd_gather(a):
    b, rows = engine.gather(a.batch)
    if a.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return 0
    print("lote %s (%s, host %s)" % (b["id"], b["project"], b["host"]))
    for r in rows:
        print("\n- %s [%s/%s] %s" % (r["task"], r["status"], r["t3status"], r["title"]))
        if r.get("link"):
            print("  hilo:", r["link"])
        for pr in r["prs"]:
            print("  PR:", pr)
        if r["pending"]:
            print("  PENDIENTE: pregunta sin responder (chopshop answer %s ...)" % r["task"])
        if r.get("result"):
            print("  resultado:", r["result"].strip().replace("\n", "\n    ")[:600])
        if r.get("error"):
            print("  error:", r["error"])
    return 0


def cmd_answer(a):
    if a.queue:
        ident = inbox.enqueue_answer(a.task, " ".join(a.choice), a.request, a.by)
        print(json.dumps({"queued": True, "id": ident}))
        return 0
    ans = engine.answer(a.task, " ".join(a.choice), a.request, a.by)
    print("respondido:", json.dumps(ans, ensure_ascii=False))
    return 0


def cmd_settle(a):
    n = engine.settle(a.batch)
    print("%d hilos settled (nunca archivados)" % n)
    return 0


def cmd_stop(a):
    n = engine.stop(a.batch, a.task)
    print("%d hilos interrumpidos (no se archiva ni se borra nada)" % n)
    return 0


def cmd_graph(a):
    if a.action == "new":
        prof = profile.load(a.target)
        errs = profile.validate(prof)
        if errs:
            raise profile.ProfileError("; ".join(errs))
        data = miniyaml.load(a.bugs) if a.bugs else {}
        bugs = data.get("bugs") if isinstance(data, dict) else None
        if not bugs:
            raise profile.ProfileError("usa --bugs <archivo> con una lista `bugs:` (ver examples/dummy-bugs.yaml)")
        for x in bugs:
            if not x.get("id") or not x.get("title"):
                raise profile.ProfileError("cada bug necesita id y title")
        goal = a.goal or data.get("goal") or graph.GOAL
        host, cap, notes = engine.route(prof, 1, a.host, a.max_parallel)
        with state.locked() as st:
            bid = state.new_batch_id(st)
            b = {"id": bid, "project": prof["project"], "host": host, "max_parallel": cap, "created": state.now(),
                 "notes": notes, "projectId": None, "tasks": []}
            if prof.get("reactions"):
                b["rx"] = True
            g = graph.new_graph(st, b, prof, goal, bugs)
            st["batches"][bid] = b
        print("grafo %s (lote %s, host %s, paralelo %d): %d bugs; sigue con `chopshop graph run %s`" % (g["id"], bid, host, cap, len(bugs), g["id"]))
        return 0
    st = state.read()
    if a.action == "status":
        gs = graph.view(st)
        if a.target:
            gs = [g for g in gs if g["id"] == a.target]
        if a.json:
            print(json.dumps(gs, ensure_ascii=False, indent=1))
            return 0
        for g in gs:
            print("%s %s  [%s]  hilos %d/%d  %s" % (g["id"], g["goal"], g["status"], g["threads"], g["limits"]["thread_budget"], g.get("throttle") and g["throttle"].get("mode") or ""))
            for n in g["nodes"]:
                print("  %s%-7s %-8s %-9s %s %s" % ("  " * n["depth"], n["label"], n["id"], n["status"], n["title"][:48], ("(" + n["reason"] + ")") if n.get("reason") else ""))
        if not gs:
            print("sin grafos")
        return 0
    # run
    g = st.get("graphs", {}).get(a.target)
    if not g:
        raise profile.ProfileError("grafo desconocido: %s" % a.target)
    end = time.time() + a.timeout
    while True:
        inbox.drain(engine.answer)
        engine.tick(g["batch"], a.webhook_file)
        g = state.read()["graphs"][a.target]
        if g["status"] != "running":
            print("grafo %s: %s %s" % (g["id"], g["status"], g.get("summary")))
            return 0
        if time.time() > end:
            print("timeout: el grafo sigue (usa `chopshop watch` o `graph run` otra vez)")
            return 0
        time.sleep(a.interval)


def cmd_snapshot(a):
    print(json.dumps(engine.snapshot(a.events), ensure_ascii=False))
    return 0


def cmd_subscribe(a):
    if a.list:
        for n, s in state.read()["subscriptions"].items():
            print("%s project=%s events=%s webhook_file=%s" % (n, s["project"], ",".join(s["events"]), s["webhook_file"]))
        return 0
    if not a.name or not a.webhook_file:
        raise profile.ProfileError("uso: subscribe <nombre> --project P --events e1,e2 --webhook-file F")
    f = os.path.expanduser(a.webhook_file)
    if not os.path.isfile(f):
        raise profile.ProfileError("no existe el archivo de webhook: %s" % a.webhook_file)
    if os.stat(f).st_mode & 0o077:
        print("aviso: %s es legible por otros; haz chmod 600" % a.webhook_file, file=sys.stderr)
    with state.locked() as st:
        st["subscriptions"][a.name] = {"project": a.project, "events": a.events.split(","), "webhook_file": f}
    print("suscrito %s (la URL no se muestra)" % a.name)
    return 0


def build():
    p = argparse.ArgumentParser(prog="chopshop", description="Capa delgada entre bots y T3 Code", epilog=HELP_EPILOG)
    sp = p.add_subparsers(dest="cmd", required=True)

    def hook(x):
        x.add_argument("--webhook-file", action="append", help="archivo local con la URL del webhook (no se imprime)")

    x = sp.add_parser("profile"); x.add_argument("action", choices=["list", "show", "check"]); x.add_argument("project", nargs="?"); x.set_defaults(f=cmd_profile)
    x = sp.add_parser("fanout"); x.add_argument("project"); x.add_argument("--task", action="append"); x.add_argument("--from", dest="from_file")
    x.add_argument("--max-parallel", type=int); x.add_argument("--host"); x.add_argument("--dry-run", action="store_true")
    x.add_argument("--wait", action="store_true"); x.add_argument("--timeout", type=int, default=900); x.add_argument("--interval", type=int, default=10); hook(x); x.set_defaults(f=cmd_fanout)
    x = sp.add_parser("run"); x.add_argument("project"); x.add_argument("prompt"); x.add_argument("--host"); x.add_argument("--dry-run", action="store_true")
    x.add_argument("--wait", action="store_true"); x.add_argument("--timeout", type=int, default=900); x.add_argument("--interval", type=int, default=10); hook(x); x.set_defaults(f=cmd_run)
    x = sp.add_parser("poll"); x.add_argument("batch", nargs="?"); hook(x); x.set_defaults(f=cmd_poll)
    x = sp.add_parser("watch"); x.add_argument("--interval", type=int, default=20); hook(x); x.set_defaults(f=cmd_watch)
    x = sp.add_parser("metrics"); x.add_argument("--collect", action="store_true", help="antes consulta `fleet status` (red) y guarda los hosts remotos"); x.set_defaults(f=cmd_metrics)
    x = sp.add_parser("status"); x.add_argument("batch", nargs="?"); x.set_defaults(f=cmd_status)
    x = sp.add_parser("wait"); x.add_argument("batch"); x.add_argument("--timeout", type=int, default=900); x.add_argument("--interval", type=int, default=10); hook(x); x.set_defaults(f=cmd_wait)
    x = sp.add_parser("gather"); x.add_argument("batch"); x.add_argument("--json", action="store_true"); x.set_defaults(f=cmd_gather)
    x = sp.add_parser("answer"); x.add_argument("task"); x.add_argument("choice", nargs="+"); x.add_argument("--request"); x.add_argument("--by", help="quién responde (bot-sim, humano…) para el historial"); x.add_argument("--queue", action="store_true", help="solo encola la respuesta (la envía watch/poll)"); x.set_defaults(f=cmd_answer)
    x = sp.add_parser("settle"); x.add_argument("batch"); x.set_defaults(f=cmd_settle)
    x = sp.add_parser("stop"); x.add_argument("batch", nargs="?"); x.add_argument("--task"); x.set_defaults(f=cmd_stop)
    x = sp.add_parser("snapshot"); x.add_argument("--events", type=int, default=80); x.set_defaults(f=cmd_snapshot)
    x = sp.add_parser("graph"); x.add_argument("action", choices=["new", "run", "status"]); x.add_argument("target", nargs="?", help="new: proyecto; run/status: id del grafo")
    x.add_argument("--bugs"); x.add_argument("--goal"); x.add_argument("--host"); x.add_argument("--max-parallel", type=int); x.add_argument("--json", action="store_true")
    x.add_argument("--timeout", type=int, default=1800); x.add_argument("--interval", type=int, default=10); hook(x); x.set_defaults(f=cmd_graph)
    x = sp.add_parser("subscribe"); x.add_argument("name", nargs="?"); x.add_argument("--project", default="*"); x.add_argument("--events", default="pending_question")
    x.add_argument("--webhook-file"); x.add_argument("--list", action="store_true"); x.set_defaults(f=cmd_subscribe)
    return p


def main(argv):
    if argv and argv[0] in ("mcp", "release"):  # no pasan por argparse: stdout del MCP es solo protocolo y release nunca falla
        from .agent import mcp
        return (mcp.main_mcp if argv[0] == "mcp" else mcp.main_release)(argv[1:])
    if argv and argv[0] == "agent":  # servicio chopshop-agent: tiene su propio parser (run|status|token|check-config|print-unit)
        from .agent import service
        return service.main(argv[1:])
    a = build().parse_args(argv)
    if a.cmd == "profile" and a.action != "list" and not a.project:
        print("falta el proyecto", file=sys.stderr)
        return 2
    try:
        return a.f(a) or 0
    except (profile.ProfileError, miniyaml.YamlError, t3.T3Error) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
