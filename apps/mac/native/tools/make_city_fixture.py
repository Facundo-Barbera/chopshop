import json
import os
from typing import Any

BASE_MS = 1793296800000
MACHINE = "contabo-dev"
CROCK = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

here = os.path.dirname(os.path.abspath(__file__))
outs = [os.path.join(here, "..", "..", "Sources", "ChopshopNative", "Resources", "city-fixture.jsonl")]


def ulid(ms, n):
    s = ""
    for _ in range(10):
        s = CROCK[ms % 32] + s
        ms //= 32
    r = ""
    x = n * 2654435761 % (32 ** 16)
    for _ in range(16):
        r = CROCK[x % 32] + r
        x //= 32
    return s + r


def ts(t):
    ms = BASE_MS + int(round(t * 1000))
    sec, msr = divmod(ms, 1000)
    import datetime
    d = datetime.datetime.fromtimestamp(sec, datetime.timezone.utc)
    return d.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % msr


envs: list[dict[str, Any]] = []


def emit(t, project, typ, subject, body, severity="info", needs=None):
    envs.append(dict(t=t, project=project, type=typ, subject=subject, body=body, severity=severity, needs=needs))


def thread(tid, title):
    return {"kind": "task", "id": tid, "title": title, "url": "t3-thread://v2/threads/" + tid.split(":")[1]}


def task_state(t, project, tid, title, phase, batch, node=None, attention=None, severity="info", needs=None, error=None):
    emit(t, project, "task.state", thread(tid, title),
         {"phase": phase, "attention": attention, "title": title, "thread_id": tid, "batch": batch, "node": node,
          "error": error}, severity=severity, needs=needs)


PROJECTS = [
    ("chopshop", "b-0101", [("mcp:c101", "Ciudad nativa · CityView"), ("mcp:c102", "Vídeo de la ciudad (AVAssetWriter)"),
                            ("mcp:c103", "Emparejamiento por QR"), ("mcp:c104", "Docs del contrato v1"),
                            ("mcp:c105", "Notarizar el DMG")]),
    ("life", "b-0102", [("mcp:l201", "Presupuesto de noviembre"), ("mcp:l202", "Plan de entrenamiento")]),
    ("orchestrator", "b-0103", [("mcp:o301", "Cola de reintentos"), ("mcp:o302", "Límite de hilos por máquina"),
                                ("mcp:o303", "Métricas por proyecto"), ("mcp:o304", "Reparto por afinidad")]),
    ("nuskills", "b-0104", []),
    ("ozom-gv", "b-0105", [("mcp:g501", "Importar catálogo de GV"), ("mcp:g502", "Precios por zona"),
                           ("mcp:g503", "Facturas en lote"), ("mcp:g504", "Panel de pedidos")]),
    ("ozom-trade", "b-0106", [("mcp:t601", "Conciliar pagos"), ("mcp:t602", "Alertas de stock"),
                              ("mcp:t603", "Exportar a contabilidad")]),
    ("bixku-utilities", "b-0107", [("mcp:u701", "Migrar fechas a Temporal"), ("mcp:u702", "Parser de CSV"),
                                   ("mcp:u703", "slugify() sin dependencias")]),
]

NUS = [
    ("n-1", "meta", [], "mcp:n800", "meta · Triage de bugs"),
    ("n-2", "BUG-1", [], "mcp:n801", "BUG-1 · Lección no guarda progreso"),
    ("n-3", "BUG-2", [], "mcp:n802", "BUG-2 · Quiz duplica preguntas"),
    ("n-4", "BUG-5", ["n-1"], "mcp:n805", "BUG-5 · Racha por zona horaria"),
    ("n-5", "BUG-6", ["n-2"], "mcp:n806", "BUG-6 · Certificado con nombre vacío"),
    ("n-6", "BUG-3", ["n-3"], "mcp:n803", "BUG-3 · Racha se reinicia"),
    ("n-7", "BUG-8", ["n-4"], "mcp:n808", "BUG-8 · Notificación push llega 2 veces"),
    ("n-8", "BUG-9", ["n-5"], "mcp:n809", "BUG-9 · Búsqueda ignora acentos"),
    ("n-9", "BUG-4", ["n-6"], "mcp:n804", "BUG-4 · Insignias sin traducir"),
]

emit(0.0, None, "agent.started", {"kind": "agent", "id": MACHINE}, {"version": "0.6.0"})
emit(0.05, None, "machine.health", {"kind": "machine", "id": MACHINE},
     {"state": "ok", "cpu_pct": 12, "ram_pct": 31, "disk_pct": 5, "load": [0.3, 0.2, 0.1], "threads_running": 0,
      "t3_ok": True, "agent_version": "0.6.0", "down_seconds": None})

for i, (name, batch, threads) in enumerate(PROJECTS):
    tl = threads if name != "nuskills" else [(n[3], n[4]) for n in NUS]
    ids = ["t-%s-%d" % (batch[2:], k + 1) for k in range(len(tl))]
    emit(0.1 + i * 0.06, name, "batch.created", {"kind": "batch", "id": batch},
         {"batch": batch, "host": MACHINE, "max_parallel": len(tl), "tasks": {x: "queued" for x in ids}, "notes": []})

nus_batch = "b-0104"
nodes = [{"id": n, "label": lab, "phase": "queued", "deps": deps, "task": "t-0104-%d" % (k + 1)}
         for k, (n, lab, deps, _, _) in enumerate(NUS)]
emit(0.55, "nuskills", "graph.state", {"kind": "graph", "id": "g-7", "title": "Resolver los bugs de la app de lecciones"},
     {"graph": "g-7", "goal": "Resolver los bugs de la app de lecciones", "status": "running", "nodes": nodes})
emit(0.6, "nuskills", "node.state", {"kind": "node", "id": "g-7/n-1", "title": "meta"},
     {"graph": "g-7", "node": "n-1", "label": "meta", "phase": "done", "deps": [], "task": "t-0104-1"})
task_state(0.6, "nuskills", "mcp:n800", "meta · Triage de bugs", "done", nus_batch, node="n-1")

FLOOR_START = {"chopshop": 3.2, "life": 3.5, "orchestrator": 3.8, "nuskills": 4.0, "ozom-gv": 4.3, "ozom-trade": 4.6,
               "bixku-utilities": 4.9}
for name, batch, threads in PROJECTS:
    if name == "nuskills":
        continue
    for k, (tid, title) in enumerate(threads):
        task_state(round(FLOOR_START[name] + k * 0.38 + (k % 2) * 0.11, 2), name, tid, title, "running", batch)
for k, (n, lab, deps, tid, title) in enumerate(NUS[1:]):
    t = round(FLOOR_START["nuskills"] + k * 0.31, 2)
    task_state(t, "nuskills", tid, title, "running", nus_batch, node=n)
    emit(t, "nuskills", "node.state", {"kind": "node", "id": "g-7/" + n, "title": lab},
         {"graph": "g-7", "node": n, "label": lab, "phase": "running", "deps": deps, "task": "t-0104-%d" % (k + 2)})

emit(7.0, None, "machine.health", {"kind": "machine", "id": MACHINE},
     {"state": "ok", "cpu_pct": 59, "ram_pct": 63, "disk_pct": 5, "load": [3.1, 2.4, 1.2], "threads_running": 29,
      "t3_ok": True, "agent_version": "0.6.0", "down_seconds": None})

task_state(8.2, "bixku-utilities", "mcp:u702", "Parser de CSV", "running", "b-0107", severity="warn",
           error="Hilo trabajado sin progreso")
task_state(9.6, "nuskills", "mcp:n806", "BUG-6 · Certificado con nombre vacío", "waiting", nus_batch, node="n-5",
           attention="ask", severity="notice", needs="human")
emit(9.6, "nuskills", "question.opened", {"kind": "task", "id": "mcp:n806", "title": "BUG-6 · Certificado con nombre vacío"},
     {"thread_id": "mcp:n806", "request_id": "rq-206", "summary": "¿El certificado debe permitir nombre vacío?",
      "options": ["Bloquear", "Usar el correo"], "multi_select": False, "level": "human"},
     severity="notice", needs="human")

envs.sort(key=lambda e: e["t"])
lines = []
for k, e in enumerate(envs):
    seq = 2001 + k
    ms = BASE_MS + int(round(e["t"] * 1000))
    lines.append(json.dumps({"v": 1, "id": ulid(ms, seq), "seq": seq, "ts": ts(e["t"]), "machine": MACHINE,
                             "project": e["project"], "type": e["type"], "severity": e["severity"], "needs": e["needs"],
                             "subject": e["subject"], "cause": {"id": None, "depth": 0}, "body": e["body"]},
                            ensure_ascii=False, separators=(",", ":")))
for o in outs:
    with open(o, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
print("ok: %d sobres" % len(lines))
