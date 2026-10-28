"""Grafo de tareas que crece. Un grafo = un lote (`batch["graph"]`) + nodos en `state["graphs"]`.
Raíz (meta) -> hilo de triage -> un nodo por bug -> hijos opcionales (SPLIT) o dependencias entre nodos.
Chopshop programa los nodos listos (deps cumplidas) en paralelo según el monitor de rendimiento, sube los resultados
al padre sin hilos extra y solo despierta a un bot/humano por excepciones, usando el sistema de niveles (reactions).
Perfil: `graph: {max_depth, thread_budget, done: all|ratio, min_ratio, throttle_cpu, stop_cpu, stop_ram}`."""
import json
import math
import re

from . import events, metrics, state

DEFAULTS = {"max_depth": 2, "thread_budget": 12, "done": "all", "min_ratio": 0.8,
            "throttle_cpu": 75, "stop_cpu": 100, "stop_ram": 92}
FINAL = ("done", "failed", "skipped")
GOAL = "resuelve todos los bugs del dummy"


def limits(prof):
    g = dict(DEFAULTS)
    g.update({k: v for k, v in (prof.get("graph") or {}).items() if v is not None})
    return g


def validate(prof):
    errs = []
    g = prof.get("graph")
    if g is None:
        return errs
    if not isinstance(g, dict):
        return ["graph: se esperaba un mapa"]
    for k in g:
        if k not in DEFAULTS:
            errs.append("graph.%s desconocido (%s)" % (k, ", ".join(DEFAULTS)))
    for k in ("max_depth", "thread_budget", "throttle_cpu", "stop_cpu", "stop_ram"):
        if k in g and not isinstance(g[k], (int, float)):
            errs.append("graph.%s debe ser número" % k)
    if g.get("done", "all") not in ("all", "ratio"):
        errs.append("graph.done debe ser all o ratio")
    return errs


# ---------- creación ----------
def _node(g, parent, title, kind, depth, deps=None, label=None, text="", ask=None, hint=None):
    nid = "n%d" % g["seq"]
    g["seq"] += 1
    g["nodes"][nid] = {"id": nid, "parent": parent, "title": title, "kind": kind, "depth": depth, "deps": list(deps or []),
                       "label": label or nid, "status": "pending", "task": None, "result": None, "reason": None,
                       "text": text, "ask": ask, "hint": hint}
    return nid


def _log(g, kind, msg, node=None):
    g["log"].append({"ts": state.now(), "kind": kind, "node": node, "msg": msg})
    del g["log"][:-80]


def new_graph(st, b, prof, goal, bugs):
    """Crea el grafo dentro del estado (el lote `b` ya existe). `bugs`: [{id,title,text,ask?,options?,hint?}]."""
    st["gcounter"] = st.get("gcounter", 0) + 1
    gid = "g-%04d" % st["gcounter"]
    g = {"id": gid, "project": b["project"], "batch": b["id"], "goal": goal or GOAL, "status": "running",
         "created": state.now(), "limits": limits(prof), "seq": 0, "nodes": {}, "log": [], "throttle": None,
         "bugs": {x["id"]: x for x in bugs}}
    root = _node(g, None, g["goal"], "root", 0, label="meta")
    g["nodes"][root]["status"] = "expanding"
    _node(g, root, "Triage: un nodo por bug", "triage", 1, label="triage")
    b["graph"] = gid
    st.setdefault("graphs", {})[gid] = g
    _log(g, "info", "grafo creado: %d bugs en la lista, presupuesto %d hilos, profundidad máx. %d"
         % (len(bugs), g["limits"]["thread_budget"], g["limits"]["max_depth"]))
    return g


def triage_prompt(g):
    lst = "\n".join("- %s: %s. %s" % (x["id"], x["title"], x.get("text", "")) for x in g["bugs"].values())
    return ("This is a FAKE-bug workflow test. Answer directly in plain text; do NOT use any tools.\n"
            "Goal: %s\nBugs:\n%s\n\n"
            "Task: triage. For every bug decide which OTHER bugs must be fixed first (only when the bug text says it requires another one). "
            "Reply with ONLY a JSON array, no prose, no code fences, one item per bug in the same order: "
            '[{"bug":"BUG-1","depends_on":[]}, ...]' % (g["goal"], lst))


def node_prompt(g, n):
    if n["kind"] == "triage":
        return triage_prompt(g)
    deps = [g["nodes"][d] for d in n["deps"]]
    dep_txt = "".join("\nResult of %s (already fixed): %s" % (d["label"], (d.get("result") or "")[:300]) for d in deps)
    head = ("This is a FAKE-bug workflow test on a dummy project. Do NOT use any tools (no file, shell or edit tools); "
            "answer directly in plain text.\n%s: %s. %s%s\n\n" % (n["label"], n["title"], n.get("text") or "", dep_txt))
    if n.get("ask"):
        opts = n.get("options") or []
        head += ('Before deciding, use your interactive question tool (AskUserQuestion) to ask me: "%s"%s Wait for my answer. '
                 "Whatever it is, do NOT use any other tool and do NOT change any file. " % (
                     n["ask"], (" with exactly these options: " + " / ".join(opts) + ".") if opts else ""))
        head += "Then finish with one line: RESULT: <what was decided, one short sentence>."
        return head
    if n.get("hint") == "split":
        return head + ("This bug is too big for one step. Reply ONLY with a line: "
                       'SPLIT: [{"title":"...","text":"..."},{"title":"...","text":"..."}] (exactly 2 sub-tasks, short texts).')
    return head + "Reply with a short analysis and finish with one line: RESULT: <the fix, one short sentence>."


# ---------- parseo de respuestas ----------
def parse_triage(text, known):
    """-> {bug_id: [deps]} ; None si no es JSON utilizable."""
    a, z = (text or "").find("["), (text or "").rfind("]")
    if a < 0 or z <= a:
        return None
    try:
        arr = json.loads(text[a:z + 1])
    except ValueError:
        return None
    out = {}
    for it in arr if isinstance(arr, list) else []:
        if isinstance(it, dict) and it.get("bug") in known:
            deps = [d for d in (it.get("depends_on") or []) if d in known and d != it["bug"]]
            out[it["bug"]] = deps
    return out or None


def parse_node(text):
    """-> ("split", [..]) | ("result", texto)."""
    text = text or ""
    m = re.search(r"SPLIT:\s*(\[.*\])", text, re.S)
    if m:
        try:
            arr = json.loads(m.group(1))
            items = [x for x in arr if isinstance(x, dict) and x.get("title")]
            if items:
                return "split", items
        except ValueError:
            pass
    rs = re.findall(r"RESULT:\s*(.+)", text)
    if rs:
        return "result", rs[-1].strip()[:300]
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    return "result", (lines[-1] if lines else "(sin texto)")[:300]


# ---------- monitor de rendimiento ----------
def throttle(g, host, cap, active, mx=None):
    """-> (permitidos, info). Con CPU alta baja a la mitad; saturado: no se lanza nada nuevo (siempre ≥ 1 si no corre nada)."""
    lim = g["limits"]
    m = ((mx or metrics.read())["hosts"].get(host)) or {}
    cpu, ram = m.get("cpu_pct"), m.get("ram_pct")
    info = {"cpu": cpu, "ram": ram, "cap": cap, "ts": state.now()}
    if not m.get("ok") or m.get("stale") or cpu is None:
        info.update(mode="sin-datos", allowed=cap)
    elif cpu >= lim["stop_cpu"] or (ram is not None and ram >= lim["stop_ram"]):
        info.update(mode="pausa", allowed=max(active, 1))
    elif cpu >= lim["throttle_cpu"]:
        info.update(mode="mitad", allowed=max(1, math.ceil(cap / 2)))
    else:
        info.update(mode="pleno", allowed=cap)
    return info["allowed"], info


# ---------- planificador ----------
def _cur(b, tid):
    by = {t["id"]: t for t in b["tasks"]}
    t = by.get(tid)
    while t and t.get("retried_by") in by:
        t = by[t["retried_by"]]
    return t


def _children(g, nid):
    return [n for n in g["nodes"].values() if n["parent"] == nid]


def _exception(st, b, g, node, why):
    _log(g, "exception", why, node["id"])
    events.emit(st, "graph_exception", b["project"], {"graph": g["id"], "node": node["id"], "label": node["label"], "reason": why})


def _add_task(b, n, prompt):
    i = len(b["tasks"]) + 1
    t = {"id": "t-%s-%d" % (b["id"][2:], i), "title": ("%s · %s" % (n["label"], n["title"]))[:70], "prompt": prompt, "issue": None,
         "status": "queued", "threadId": None, "link": None, "t3status": None, "done": False, "notified": [], "settled": False,
         "node": n["id"]}
    b["tasks"].append(t)
    return t


def _finish_ok(st, b, g, n, t):
    text = t.get("result") or ""
    if n["kind"] == "triage":
        known = [x for x in g["bugs"]]
        deps = parse_triage(text, known)
        n.update(status="done", result="%d bugs ordenados" % len(known))
        if deps is None:
            _exception(st, b, g, n, "triage sin JSON válido: nodos planos, sin dependencias")
            deps = {}
        ids = {}
        for bid in known:
            x = g["bugs"][bid]
            ids[bid] = _node(g, n["parent"], x["title"], "bug", 1, label=bid, text=x.get("text", ""), ask=x.get("ask"),
                             hint=x.get("hint"))
            if x.get("options"):
                g["nodes"][ids[bid]]["options"] = x["options"]
        for bid in known:
            g["nodes"][ids[bid]]["deps"] = [ids[d] for d in deps.get(bid, [])]
        _log(g, "triage", "triage: %d nodos, %d dependencias" % (len(known), sum(len(v) for v in deps.values())), n["id"])
        return
    kind, val = parse_node(text)
    if kind == "split":
        if n["depth"] + 1 > g["limits"]["max_depth"]:
            n.update(status="failed", reason="max_depth (%d)" % g["limits"]["max_depth"])
            _exception(st, b, g, n, "%s quiere dividirse pero rebasa la profundidad máxima %d" % (n["label"], g["limits"]["max_depth"]))
            return
        n["status"] = "expanding"
        for k, it in enumerate(val[:3], 1):
            _node(g, n["id"], str(it["title"])[:80], "child", n["depth"] + 1, label="%s.%d" % (n["label"], k), text=str(it.get("text", ""))[:300])
        _log(g, "split", "%s se divide en %d hijos" % (n["label"], min(len(val), 3)), n["id"])
    else:
        n.update(status="done", result=val)
        _log(g, "done", "%s listo: %s" % (n["label"], val[:90]), n["id"])


def _rollup(st, b, g):
    """Nodos que se expanden: cuando todos sus hijos terminaron, resuelve según los criterios y sube el resultado."""
    lim = g["limits"]
    changed = True
    while changed:
        changed = False
        for n in list(g["nodes"].values()):
            if n["status"] != "expanding":
                continue
            kids = _children(g, n["id"])
            if not kids or any(k["status"] not in FINAL for k in kids):
                continue
            ok = sum(1 for k in kids if k["status"] == "done")
            good = ok == len(kids) if lim["done"] == "all" else (ok > 0 and ok / len(kids) >= float(lim["min_ratio"]))
            n["result"] = "\n".join("%s: %s" % (k["label"], (k.get("result") or k.get("reason") or k["status"]).splitlines()[0][:120])
                                    for k in kids if k["kind"] != "triage")
            n["status"] = "done" if good else "failed"
            if not good:
                n["reason"] = "%d/%d hijos listos (criterio %s)" % (ok, len(kids), lim["done"])
            _log(g, "rollup", "%s %s: %d/%d hijos listos" % (n["label"], "completo" if good else "falló", ok, len(kids)), n["id"])
            changed = True


def step(st, b, prof, log=print, adhoc=None):
    g = st.get("graphs", {}).get(b.get("graph"))
    if not g or g["status"] != "running":
        return
    # 1) resultados de los hilos
    for n in list(g["nodes"].values()):
        if n["status"] != "running" or not n.get("task"):
            continue
        t = _cur(b, n["task"])
        if not t:
            continue
        n["task"] = t["id"]
        if not t["done"]:
            continue
        if t.get("t3status") == "completed":
            _finish_ok(st, b, g, n, t)
        else:
            n.update(status="failed", reason="hilo %s (%s)" % (t.get("status"), t.get("t3status") or t.get("last_error") or "-"))
            _exception(st, b, g, n, "%s falló: %s" % (n["label"], n["reason"]))
    _rollup(st, b, g)
    # 2) dependencias fallidas -> bloqueados
    pend = [n for n in g["nodes"].values() if n["status"] == "pending"]
    for n in pend:
        bad = [g["nodes"][d] for d in n["deps"] if g["nodes"][d]["status"] in ("failed", "skipped")]
        if bad:
            n.update(status="skipped", reason="depende de %s, que no salió" % bad[0]["label"])
            _exception(st, b, g, n, "%s bloqueado: %s" % (n["label"], n["reason"]))
    _rollup(st, b, g)
    # 3) liberar nodos listos según cupo, rendimiento y presupuesto
    active = sum(1 for t in b["tasks"] if t["status"] in ("queued", "launched") and not t["done"])
    allowed, info = throttle(g, b["host"], b["max_parallel"], active)
    if not g.get("throttle") or g["throttle"].get("mode") != info["mode"]:
        _log(g, "throttle", "rendimiento: %s (CPU %s%%, RAM %s%%) -> hasta %d hilos" % (info["mode"], info["cpu"], info["ram"], allowed))
    g["throttle"] = info
    slots = min(allowed, b["max_parallel"]) - active
    for n in [n for n in g["nodes"].values() if n["status"] == "pending"]:
        if any(g["nodes"][d]["status"] != "done" for d in n["deps"]):
            continue
        if len(b["tasks"]) >= g["limits"]["thread_budget"]:
            n.update(status="skipped", reason="presupuesto de %d hilos agotado" % g["limits"]["thread_budget"])
            _exception(st, b, g, n, "%s omitido: %s" % (n["label"], n["reason"]))
            continue
        if slots <= 0:
            continue
        t = _add_task(b, n, node_prompt(g, n))
        n.update(status="running", task=t["id"])
        slots -= 1
        _log(g, "launch", "%s -> %s" % (n["label"], t["id"]), n["id"])
    _rollup(st, b, g)
    # 4) bloqueos sin salida (ciclos) y fin del grafo
    left = [n for n in g["nodes"].values() if n["status"] == "pending"]
    if left and not any(n["status"] == "running" for n in g["nodes"].values()):
        for n in left:
            if all(g["nodes"][d]["status"] == "done" for d in n["deps"]):
                break
        else:
            for n in left:
                n.update(status="skipped", reason="dependencias cíclicas")
            _rollup(st, b, g)
    root = next(n for n in g["nodes"].values() if n["kind"] == "root")
    if root["status"] in ("done", "failed"):
        g["status"] = root["status"]
        g["finished"] = state.now()
        kinds = [n["status"] for n in g["nodes"].values() if n["kind"] in ("bug", "child")]
        g["summary"] = {"done": kinds.count("done"), "failed": kinds.count("failed"), "skipped": kinds.count("skipped"),
                        "threads": len(b["tasks"])}
        events.emit(st, "graph_done", b["project"], {"graph": g["id"], "batch": b["id"], "status": g["status"],
                                                      "summary": "%d listos, %d fallidos, %d omitidos, %d hilos" % (g["summary"]["done"], g["summary"]["failed"], g["summary"]["skipped"], g["summary"]["threads"]), "result": (root.get("result") or "")[:800]})
        _log(g, "end", "grafo %s: %d listos, %d fallidos, %d omitidos, %d hilos" % (g["status"], g["summary"]["done"], g["summary"]["failed"], g["summary"]["skipped"], g["summary"]["threads"]))
        log("grafo %s terminado: %s %s" % (g["id"], g["status"], g["summary"]))


def finished(st, b):
    g = st.get("graphs", {}).get(b.get("graph"))
    return bool(g) and g["status"] != "running"


# ---------- vista para la UI / CLI ----------
def view(st):
    out = []
    for g in sorted(st.get("graphs", {}).values(), key=lambda x: x["id"], reverse=True):
        b = st["batches"].get(g["batch"]) or {"tasks": []}
        by = {t["id"]: t for t in b["tasks"]}
        nodes = []
        for n in g["nodes"].values():
            row = {k: n.get(k) for k in ("id", "parent", "title", "kind", "depth", "deps", "label", "status", "task", "result", "reason", "ask")}
            t = _cur(b, n["task"]) if n.get("task") else None
            if t:
                row["task_state"] = {"id": t["id"], "t3status": t.get("t3status"), "done": t["done"], "link": t.get("link"),
                                     "level": t.get("level"), "pending": bool((t.get("pending") or {}).get("questions")),
                                     "escalation": (t.get("escalation") or {}).get("status"), "bot_wait": bool((t.get("bot_wait") or {}) and not (t.get("bot_wait") or {}).get("done")),
                                     "retries": t.get("retries", 0)}
            row["prompt"] = (by[n["task"]]["prompt"] if n.get("task") in by else "")[:500]
            nodes.append(row)
        out.append({"id": g["id"], "project": g["project"], "batch": g["batch"], "goal": g["goal"], "status": g["status"],
                    "created": g["created"], "finished": g.get("finished"), "limits": g["limits"], "throttle": g.get("throttle"),
                    "summary": g.get("summary"), "threads": len(b["tasks"]), "nodes": nodes, "log": g["log"][-30:]})
    return out
