"""K4: valida las salidas reales del agente contra los schemas de K1 (packages/api/relay) y K2 (packages/api/fixtures).

Levanta un AgentService en un directorio temporal (sin T3, sin red), recorre un escenario de empleado y cola (asignar,
encolar, cancelar, renombrar, terminar, liberar, sacar de la cola) y valida:
- K2: `employees`/`queues` de GET /snapshot y cada sobre `employee.*`, `queue.changed`, `task.*` del bus;
- K1: `hello`, `snapshot` y `event` tal como los arma relaysync (A2) para el relay;
- los ejemplos de ambos contratos contra sus schemas.

Uso: python3 tools/contract_audit.py   (necesita jsonschema >= 4.18). Sale con 1 si algo no valida.
"""
import copy
import json
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "apps/agent"))
TMP = tempfile.mkdtemp(prefix="contract-audit-")
os.environ["CHOPSHOP_CONFIG"] = os.path.join(TMP, "config.toml")
os.environ["CHOPSHOP_HOME"] = os.path.join(TMP, "home")
open(os.environ["CHOPSHOP_CONFIG"], "w").close()

from jsonschema import Draft202012Validator  # noqa: E402
from referencing import Registry, Resource  # noqa: E402

from chopshop import employees as employees_mod, relaysync, settings  # noqa: E402
from chopshop.agent import db, envelope, events, service  # noqa: E402

K1 = os.path.join(ROOT, "packages/api/relay")
K2 = os.path.join(ROOT, "packages/api/fixtures")
K2_TYPES = ("employee.assigned", "employee.idle", "employee.renamed", "queue.changed", "task.enqueued", "task.cancelled")
MACHINE = "contabo-dev"
EMP = "awesome-gb/0/triage/0"
PROFILE = {"project": "awesome-gb",
           "office": {"company": "Awesome GB", "half_life": "10m",
                      "floors": [{"name": "Producto", "rooms": [{"role": "triage", "desks": 1, "permanent": True},
                                                                {"role": "backend", "desks": 2}]}]},
           "capacity": {"flex_per_floor": 0, "max_extra_floors": 0, "outsourcing": False}}


def validator(base, name):
    res = []
    for f in os.listdir(base):
        if f.endswith(".schema.json"):
            d = json.load(open(os.path.join(base, f)))
            res.append((d["$id"], Resource.from_contents(d)))
    schema = json.load(open(os.path.join(base, name + ".schema.json")))
    return Draft202012Validator(schema, registry=Registry().with_resources(res),
                                format_checker=Draft202012Validator.FORMAT_CHECKER)


def scenario():
    now = [1_800_000_000.0]
    cfg = copy.deepcopy(settings.DEFAULTS["agent"])
    cfg.update(machine_id=MACHINE, db_path=os.path.join(TMP, "agent.db"), token_file=os.path.join(TMP, "token"),
               projects_root=TMP, worktrees_root=TMP, t3_enabled=False, import_legacy=False)
    conn = db.connect(cfg["db_path"])
    svc = service.AgentService(cfg, conn=conn, clock=lambda: now[0], relay=False)
    svc.office.profiles_fn = lambda: [PROFILE]

    def thread(tid, title, status="running"):
        name = {"running": "thread_started", "completed": "thread_done"}[status]
        body = {"thread_id": tid, "title": title, "status": status, "branch": "t/" + tid, "worktree": "/wt/" + tid,
                "pull_requests": [], "role": "triage", "settled": False,
                "ended_at": envelope.iso(now[0]) if status != "running" else None}
        if status == "completed":
            body.update(result="Hecho", summary="Hecho: " + title)
        svc.emit(name, "awesome-gb", body)

    def step():
        now[0] += 1
        svc.office_once()

    snaps = []
    step()
    thread("mcp:t1", "Triage #212")
    step()
    svc.office.assign(EMP, "mcp:t1", reason="manual")
    step()
    snaps.append(svc.app.r_snapshot(None, {}, None))
    svc.queue.enqueue(EMP, "Triage #213", "human", trigger="desk.note")
    row, _ = svc.queue.enqueue(EMP, "Triage #214", "triage-bot")
    svc.queue.cancel(row["task"], "human", reason="manual", note="duplicada")
    b = employees_mod.rename(conn, EMP, "Tría", "human", now[0])
    svc.emit_office("employee.renamed", "awesome-gb", b, needs=None, subject=envelope.subject("desk", EMP, "Tría"))
    thread("mcp:t1", "Triage #212", status="completed")
    step()
    svc.office.release(EMP, "manual")
    step()
    svc.queue.pop(EMP)
    step()
    snaps.append(svc.app.r_snapshot(None, {}, None))
    return conn, svc, snaps


def main():
    failures = []

    def check(label, v, inst):
        for e in v.iter_errors(inst):
            failures.append("%s: %s: %s" % (label, "/".join(map(str, e.absolute_path)) or "<raíz>", e.message[:200]))

    for f in sorted(os.listdir(os.path.join(K1, "fixtures"))):
        check("K1 ejemplo " + f, validator(K1, f[:-5]), json.load(open(os.path.join(K1, "fixtures", f))))
    for f in sorted(os.listdir(os.path.join(K2, "events"))):
        check("K2 ejemplo " + f, validator(os.path.join(K2, "schemas"), f[:-5]), json.load(open(os.path.join(K2, "events", f))))
    for f in sorted(os.listdir(K2)):
        if f.startswith("snapshot.") and f.endswith(".json"):
            check("K2 ejemplo " + f, validator(os.path.join(K2, "schemas"), "snapshot"), json.load(open(os.path.join(K2, f))))

    conn, svc, snaps = scenario()
    bus = events.list_after(conn, 0, 10000)
    seen = {}
    for i, s in enumerate(snaps):
        check("K2 GET /snapshot #%d" % i, validator(os.path.join(K2, "schemas"), "snapshot"),
              {"employees": s["employees"], "queues": s["queues"]})
        for e in s["employees"]:
            if e.get("location") != ("desk" if e["state"] == "working" else "common"):
                failures.append("K2 GET /snapshot #%d: %s location=%r con state=%r" % (i, e["id"], e.get("location"), e["state"]))
    for env in bus:
        if env["type"] in K2_TYPES:
            seen[env["type"]] = seen.get(env["type"], 0) + 1
            check("K2 " + env["type"], validator(os.path.join(K2, "schemas"), env["type"]), env)
    for t in K2_TYPES:
        if t not in seen:
            failures.append("K2 %s: el escenario no lo emitió" % t)

    roles = relaysync.roles_from_profiles([PROFILE])
    check("K1 hello (A2)", validator(K1, "hello"), relaysync.hello(MACHINE, roles, events.last_seq(conn)))
    check("K1 snapshot (A2)", validator(K1, "snapshot"),
          relaysync.snapshot(snaps[-1], svc.app.projector.current(), roles, machine_id=MACHINE))
    n = 0
    for env in bus:
        m = relaysync.event(env, MACHINE)
        if m is not None:
            n += 1
            check("K1 event (A2) " + env["type"], validator(K1, "event"), m)

    print("K2: %s" % ", ".join("%s×%d" % kv for kv in sorted(seen.items())))
    print("K1: hello×1, snapshot×1, event×%d" % n)
    for f in failures:
        print("FALLA " + f)
    print("ok" if not failures else "%d fallos" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
