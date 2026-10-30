"""K4: valida las salidas reales del agente contra los schemas de K1 (packages/api/relay) y K2 (packages/api/fixtures).

Levanta un AgentService en un directorio temporal (sin T3, sin red), recorre un escenario de empleado y cola (asignar,
encolar, cancelar, renombrar, terminar, liberar, sacar de la cola) y valida:
- K2: `employees`/`queues` de GET /snapshot y cada sobre `employee.*`, `queue.changed`, `task.*` del bus;
- K1: `hello`, `snapshot` y `event` tal como los arma relaysync (A2) para el relay;
- los ejemplos de ambos contratos contra sus schemas;
- S1: las fixtures válidas e inválidas de packages/api/backend contra sus schemas, con un validador propio (stdlib).

Uso: python3 tools/contract_audit.py   (K1/K2 necesitan jsonschema >= 4.18). Sale con 1 si algo no valida.
     python3 tools/contract_audit.py --backend   (solo S1, sin dependencias).
"""
import copy
import json
import os
import re
import sys
import tempfile
from urllib.parse import urldefrag, urljoin

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "apps/agent"))
BACKEND = os.path.join(ROOT, "packages/api/backend")
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
KEYWORDS = {"type", "enum", "const", "pattern", "minLength", "maxLength", "minimum", "maximum", "items", "minItems",
            "maxItems", "uniqueItems", "properties", "required", "additionalProperties", "$ref", "oneOf"}
ANNOTATIONS = {"$schema", "$id", "title", "description", "$defs"}


def is_type(v, t):
    if t == "null":
        return v is None
    if t == "boolean":
        return isinstance(v, bool)
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool)
    if t == "number":
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    return isinstance(v, {"string": str, "array": list, "object": dict}[t])


def same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if is_type(a, "number") and is_type(b, "number"):
        return a == b
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


class MiniSchemas:
    def __init__(self, docs):
        self.docs = docs

    @classmethod
    def load(cls, base):
        docs, paths = {}, {}
        for d, _, files in os.walk(base):
            for f in sorted(files):
                if f.endswith(".schema.json"):
                    p = os.path.join(d, f)
                    with open(p) as fh:
                        doc = json.load(fh)
                    docs[doc["$id"]] = doc
                    paths[os.path.relpath(p, base)[:-len(".schema.json")]] = doc["$id"]
        return cls(docs), paths

    def resolve(self, base, ref):
        url, frag = urldefrag(urljoin(base, ref))
        node = self.docs[url]
        for part in [p for p in frag.split("/") if p]:
            node = node[part.replace("~1", "/").replace("~0", "~")]
        return url, node

    def lint(self, schema, base, path="#"):
        out = []
        if not isinstance(schema, dict):
            return [(path, "el schema no es un objeto")]
        for k in schema:
            if k not in KEYWORDS and k not in ANNOTATIONS:
                out.append((path, "palabra clave no soportada: " + k))
        if "$ref" in schema:
            try:
                self.resolve(base, schema["$ref"])
            except (KeyError, TypeError):
                out.append((path, "$ref sin resolver: " + schema["$ref"]))
        subs = [("properties/" + k, v) for k, v in schema.get("properties", {}).items()]
        subs += [("$defs/" + k, v) for k, v in schema.get("$defs", {}).items()]
        subs += [("oneOf/%d" % i, v) for i, v in enumerate(schema.get("oneOf", []))]
        for k in ("items", "additionalProperties"):
            if isinstance(schema.get(k), dict):
                subs.append((k, schema[k]))
        for k, sub in subs:
            out += self.lint(sub, base, path + "/" + k)
        return out

    def errors(self, schema, inst, base, path="$"):
        out = []
        if "$ref" in schema:
            url, target = self.resolve(base, schema["$ref"])
            out += self.errors(target, inst, url, path)
        if "type" in schema:
            ts = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(is_type(inst, t) for t in ts):
                return out + [(path, "tipo %s, se esperaba %s" % (type(inst).__name__, "|".join(ts)))]
        if "const" in schema and not same(inst, schema["const"]):
            out.append((path, "se esperaba %s" % json.dumps(schema["const"])))
        if "enum" in schema and not any(same(inst, e) for e in schema["enum"]):
            out.append((path, "%s no está en %s" % (json.dumps(inst, ensure_ascii=False)[:80], json.dumps(schema["enum"]))))
        if isinstance(inst, str):
            if "pattern" in schema and not re.search(schema["pattern"], inst):
                out.append((path, "%r no cumple %s" % (inst[:80], schema["pattern"])))
            if len(inst) < schema.get("minLength", 0) or len(inst) > schema.get("maxLength", len(inst)):
                out.append((path, "longitud %d fuera de rango" % len(inst)))
        if is_type(inst, "number"):
            if inst < schema.get("minimum", inst) or inst > schema.get("maximum", inst):
                out.append((path, "%s fuera de rango" % inst))
        if isinstance(inst, list):
            if len(inst) < schema.get("minItems", 0) or len(inst) > schema.get("maxItems", len(inst)):
                out.append((path, "%d elementos fuera de rango" % len(inst)))
            if schema.get("uniqueItems") and any(same(a, b) for i, a in enumerate(inst) for b in inst[i + 1:]):
                out.append((path, "elementos repetidos"))
            if "items" in schema:
                for i, item in enumerate(inst):
                    out += self.errors(schema["items"], item, base, "%s/%d" % (path, i))
        if isinstance(inst, dict):
            props = schema.get("properties", {})
            for k in schema.get("required", []):
                if k not in inst:
                    out.append((path, "falta %s" % k))
            for k, v in inst.items():
                if k in props:
                    out += self.errors(props[k], v, base, path + "/" + k)
                elif schema.get("additionalProperties") is False:
                    out.append((path, "propiedad no permitida: %s" % k))
                elif isinstance(schema.get("additionalProperties"), dict):
                    out += self.errors(schema["additionalProperties"], v, base, path + "/" + k)
        if "oneOf" in schema:
            n = sum(not self.errors(s, inst, base, path) for s in schema["oneOf"])
            if n != 1:
                out.append((path, "cumple %d de las alternativas de oneOf (se esperaba 1)" % n))
        return out


def schema_for(paths, folder, stem):
    names = [n for n in paths if os.path.dirname(n) == folder and (stem == os.path.basename(n) or
                                                                   stem.startswith(os.path.basename(n) + "."))]
    return max(names, key=len) if names else None


def backend_audit(base=BACKEND):
    failures = []
    schemas, paths = MiniSchemas.load(base)
    for name, sid in sorted(paths.items()):
        for p, msg in schemas.lint(schemas.docs[sid], sid):
            failures.append("S1 schema %s: %s: %s" % (name, p, msg))
    covered, counts = set(), [0, 0]
    for d, _, files in sorted(os.walk(base)):
        leaf = os.path.basename(d)
        if leaf not in ("fixtures", "invalid") or (leaf == "invalid" and os.path.basename(os.path.dirname(d)) != "fixtures"):
            continue
        valid = leaf == "fixtures"
        folder = os.path.relpath(os.path.dirname(d) if valid else os.path.dirname(os.path.dirname(d)), base)
        folder = "" if folder == "." else folder
        for f in sorted(files):
            if not f.endswith(".json"):
                continue
            label = "S1 fixture %s" % os.path.relpath(os.path.join(d, f), base)
            name = schema_for(paths, folder, f[:-5])
            if name is None:
                failures.append("%s: no hay schema para este nombre" % label)
                continue
            with open(os.path.join(d, f)) as fh:
                errs = schemas.errors(schemas.docs[paths[name]], json.load(fh), paths[name])
            counts[0 if valid else 1] += 1
            if valid:
                covered.add(name)
                failures += ["%s: %s: %s" % (label, p, msg) for p, msg in errs]
            elif not errs:
                failures.append("%s: es inválida pero valida contra %s" % (label, name))
    for name in sorted(set(paths) - covered - {"common"}):
        failures.append("S1 schema %s: sin fixture válida" % name)
    return failures, "S1: %d schemas, %d fixtures válidas, %d inválidas" % (len(paths), counts[0], counts[1])


def agent_imports():
    global TMP, Draft202012Validator, Registry, Resource, employees_mod, relaysync, settings, db, envelope, events, service
    TMP = tempfile.mkdtemp(prefix="contract-audit-")
    os.environ["CHOPSHOP_CONFIG"] = os.path.join(TMP, "config.toml")
    os.environ["CHOPSHOP_HOME"] = os.path.join(TMP, "home")
    open(os.environ["CHOPSHOP_CONFIG"], "w").close()
    from jsonschema import Draft202012Validator
    from referencing import Registry, Resource
    from chopshop import employees as employees_mod, relaysync, settings
    from chopshop.agent import db, envelope, events, service


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


def main(argv=()):
    failures, summary = backend_audit()
    if "--backend" in argv:
        print(summary)
        for f in failures:
            print("FALLA " + f)
        print("ok" if not failures else "%d fallos" % len(failures))
        return 1 if failures else 0
    agent_imports()

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

    print(summary)
    print("K2: %s" % ", ".join("%s×%d" % kv for kv in sorted(seen.items())))
    print("K1: hello×1, snapshot×1, event×%d" % n)
    for f in failures:
        print("FALLA " + f)
    print("ok" if not failures else "%d fallos" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
