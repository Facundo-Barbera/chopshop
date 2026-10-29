"""Pruebas de los escritorios por rol (agent/office.py y la regla `apply` de los escritorios en projection.py): asignación,
herencia, rol lleno -> espera, con atención no se hereda, retiro, asignación manual y la equivalencia
`state(conn) == fold(apply, sobres)`. Fixtures: tests/fixtures/office/."""
import copy
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop.agent import config as agent_config, db, envelope, events, office, projection, server, t3watch  # noqa: E402

FIX = os.path.join(os.path.dirname(__file__), "fixtures", "office")
T0 = 1_800_000_000.0
HL = 600.0                                     # T½ = 10 min en el perfil de prueba


def profile(backend=2, frontend=1, extra_floor=False):
    rooms = [{"role": "triage", "desks": 1, "permanent": True}, {"role": "backend", "desks": backend}]
    floors = [{"name": "Producto", "rooms": rooms}]
    floors.append({"name": "Front", "rooms": [{"role": "frontend", "desks": frontend}]})
    if extra_floor:
        floors.append({"name": "Docs", "rooms": [{"role": "docs", "desks": 1}]})
    return {"project": "awesome-gb", "office": {"company": "Awesome GB", "half_life": "10m", "floors": floors,
                                                 "roles": {"backend": {"match": {"title": r"^\[be\]"}}}}}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cfg = dict(copy.deepcopy(agent_config.DEFAULTS), machine_id="contabo-dev")
        self.conn = db.connect(os.path.join(self.tmp.name, "agent.db"))
        self.addCleanup(self.conn.close)
        self.now = T0
        self.prof = profile()
        self.office = office.Office(self.conn, self.cfg, self.emit, profiles_fn=lambda: [self.prof], clock=lambda: self.now)

    def emit(self, type, project, body, **kw):
        return events.emit_envelope(self.conn, self.cfg, type, project, body, ts=self.now, **kw)

    def thread(self, tid, title, status="running", role=None, ended_at=None, settled=False):
        """Un sobre de hilo como los de t3watch (nombre viejo -> task.state)."""
        name = {"running": "thread_started", "completed": "thread_done", "failed": "thread_failed"}[status]
        if settled:
            name = "thread_settled"
        body = {"thread_id": tid, "title": title, "status": status, "branch": "be/" + tid, "worktree": "/wt/" + tid,
                "pull_requests": [], "role": role, "ended_at": envelope.iso(ended_at) if ended_at else None, "settled": settled}
        if status == "completed":
            body.update(result="Hecho: " + title, summary="Hecho: " + title)
        events.emit(self.conn, self.cfg, name, "awesome-gb", body, ts=self.now)

    def end(self, tid, title, status="completed", role="backend"):
        self.thread(tid, title, status, role, ended_at=self.now)

    def step(self, dt=0):
        self.now += dt
        self.office.tick()

    def envs(self, after=0, types=None):
        out = projection.envelopes_after(self.conn, after, 10000)
        return [e for e in out if types is None or e["type"] in types]

    def desk_events(self):
        return [(e["type"], e["body"].get("desk"), e["body"]["thread_id"], e["body"].get("reason") or e["body"].get("role"))
                for e in self.envs(types=("desk.assigned", "desk.released", "desk.waiting"))]

    def seat(self, tid):
        r = self.office._seat(tid)
        return r["desk_id"] if r else None

    def state(self):
        return projection.state(self.conn, self.cfg)

    def occupants(self, st=None):
        st = st or self.state()
        p = next(p for p in st["projects"] if p["name"] == "awesome-gb")
        return {d["id"]: (d["occupant"] or {}).get("thread_id") for d in projection._desks(p["office"])}


class TestStructure(Base):
    def test_office_changed_once_and_retire(self):
        self.step()
        ch = self.envs(types=("office.changed",))
        self.assertEqual(len(ch), 1)
        b = ch[0]["body"]
        self.assertEqual((b["by"], b["company"], b["half_life_s"], len(b["diff"]["added"])), ("profile", "Awesome GB", HL, 4))
        self.office.reload()
        self.assertEqual(len(self.envs(types=("office.changed",))), 1)          # sin cambios: no se repite
        st = self.state()
        p = st["projects"][0]
        self.assertEqual([d["id"] for d in projection._desks(p["office"])],
                         ["awesome-gb/0/triage/0", "awesome-gb/0/backend/0", "awesome-gb/0/backend/1", "awesome-gb/1/frontend/0"])
        # el perfil quita un escritorio de backend: queda retirado, nunca se borra; su ocupante sale y se reubica
        self.thread("b1", "[be] uno", role="backend")
        self.thread("b2", "[be] dos", role="backend")
        self.step()
        self.assertEqual(self.seat("b2"), "awesome-gb/0/backend/1")
        self.prof = profile(backend=1)
        self.office.reload()
        ch = self.envs(types=("office.changed",))
        self.assertEqual(ch[-1]["body"]["diff"]["retired"], ["awesome-gb/0/backend/1"])
        self.assertIn(("desk.released", "awesome-gb/0/backend/1", "b2", "retired"), self.desk_events())
        self.assertIn(("desk.waiting", None, "b2", "backend"), self.desk_events())     # el otro está activo: espera
        retired = [d for d in projection._desks(self.state()["projects"][0]["office"]) if d["retired"]]
        self.assertEqual([(d["id"], d["occupant"], d["lineage"][0]["reason"]) for d in retired],
                         [("awesome-gb/0/backend/1", None, "retired")])
        self.assertEqual(self.office.desk("awesome-gb/0/backend/1")["desk"]["retired"], True)
        # se vuelve a declarar: se reactiva y sube el que esperaba
        self.prof = profile(backend=2)
        self.office.reload()
        self.assertEqual(self.seat("b2"), "awesome-gb/0/backend/1")
        self.assertEqual(self.envs(types=("office.changed",))[-1]["body"]["diff"]["reactivated"], ["awesome-gb/0/backend/1"])


class TestDesks(Base):
    def test_assign_inherit_and_lineage(self):
        self.step()
        self.thread("a1", "[be] sesión", role="backend")
        self.step()
        self.assertEqual(self.seat("a1"), "awesome-gb/0/backend/0")
        self.now += 60
        self.end("a1", "[be] sesión")
        self.step(60)
        self.assertEqual(self.seat("a1"), "awesome-gb/0/backend/0")             # terminado, sigue sentado
        self.thread("b7", "[be] login", role="backend")
        self.step(60)
        self.assertEqual(self.seat("b7"), "awesome-gb/0/backend/0")             # hereda el terminado (no el libre)
        self.assertIsNone(self.seat("a1"))
        evs = self.desk_events()
        self.assertEqual(evs, [("desk.assigned", "awesome-gb/0/backend/0", "a1", "start"),
                               ("desk.released", "awesome-gb/0/backend/0", "a1", "inherited"),
                               ("desk.assigned", "awesome-gb/0/backend/0", "b7", "inherited")])
        inh = self.envs(types=("desk.assigned",))[-1]["body"]["inheritance"]
        self.assertEqual((inh["thread_id"], inh["summary"], inh["branch"], inh["worktree"], inh["phase"]),
                         ("a1", "Hecho: [be] sesión", "be/a1", "/wt/a1", "done"))
        d = self.office.desk("awesome-gb/0/backend/0")
        self.assertEqual((d["occupant"]["thread_id"], [x["thread_id"] for x in d["lineage"]]), ("b7", ["a1"]))
        st = self.state()
        occ = next(x for x in projection._desks(st["projects"][0]["office"]) if x["id"] == "awesome-gb/0/backend/0")
        self.assertEqual((occ["occupant"]["thread_id"], occ["occupant"]["inheritance"]["thread_id"], occ["lineage"][0]["reason"]),
                         ("b7", "a1", "inherited"))
        self.assertEqual(occ["occupant"]["half_life_s"], HL)

    def test_inheritance_from_lineage_after_release(self):
        self.step()
        self.thread("t1", "triage lunes", role="triage")
        self.step()
        self.end("t1", "triage lunes", role="triage")
        self.step()
        self.assertEqual(self.office.release("awesome-gb/0/triage/0", "faded"), "t1")   # p. ej. la semivida
        self.assertIsNone(self.seat("t1"))
        self.assertEqual(self.office.desk("awesome-gb/0/triage/0")["lineage"][0]["reason"], "faded")
        self.thread("t2", "triage martes", role="triage")
        self.step()
        a = self.envs(types=("desk.assigned",))[-1]["body"]
        self.assertEqual((a["reason"], a["inheritance"]["thread_id"]), ("start", "t1"))

    def test_role_full_waits_then_promoted(self):
        self.step()
        self.thread("f1", "[fe] tema", role="frontend")
        self.thread("f2", "[fe] modo oscuro", role="frontend")
        self.step()
        self.assertEqual(self.seat("f1"), "awesome-gb/1/frontend/0")
        self.assertIsNone(self.seat("f2"))
        self.assertEqual(self.office._waiting("f2")["role"], "frontend")
        self.thread("f2", "[fe] modo oscuro", role="frontend")                   # un task.state más: no repite desk.waiting
        self.step()
        self.assertEqual(len(self.envs(types=("desk.waiting",))), 1)
        self.end("f1", "[fe] tema", role="frontend")
        self.step()
        # f1 terminó: el que espera lo hereda
        self.assertEqual(self.seat("f2"), "awesome-gb/1/frontend/0")
        self.assertIsNone(self.office._waiting("f2"))

    def test_attention_blocks_inheritance(self):
        self.step()
        self.thread("f1", "[fe] uno", role="frontend")
        self.step()
        self.thread("f1", "[fe] uno", "completed", role="frontend", ended_at=self.now)
        # f1 terminó pero tiene una pregunta abierta: no se hereda
        events.emit(self.conn, self.cfg, "pending_question", "awesome-gb",
                    {"thread_id": "f1", "title": "[fe] uno", "request_id": "r1", "questions": [{"question": "¿Sigo?"}]},
                    ts=self.now)
        self.thread("q1", "nuevo", role="frontend")
        self.step()
        self.assertIsNone(self.seat("q1"))
        self.assertEqual(self.seat("f1"), "awesome-gb/1/frontend/0")
        events.emit(self.conn, self.cfg, "thread_done", "awesome-gb",
                    {"thread_id": "f1", "title": "[fe] uno", "status": "completed", "role": "frontend",
                     "ended_at": envelope.iso(self.now)}, ts=self.now)
        self.step()
        self.assertEqual(self.seat("q1"), "awesome-gb/1/frontend/0")             # heredó al cerrarse la atención

    def test_no_role_not_seated_unknown_role_waits(self):
        self.step()
        self.thread("x1", "explorar algo")
        self.thread("x9", "rol sin escritorios", role="ops")
        self.step()
        self.assertEqual((self.seat("x1"), self.seat("x9")), (None, None))
        self.assertIsNone(self.office._waiting("x1"))
        self.assertEqual(self.desk_events(), [("desk.waiting", None, "x9", "ops")])

    def test_manual_assign_and_move(self):
        self.step()
        self.thread("x1", "sin rol")
        self.thread("b1", "[be] uno", role="backend")
        self.step()
        with self.assertRaises(office.OfficeError) as e:
            self.office.assign("awesome-gb/0/backend/0", "x1")                   # ocupado por un hilo activo
        self.assertEqual(e.exception.status, 409)
        with self.assertRaises(office.OfficeError) as e:
            self.office.assign("awesome-gb/0/nope/0", "x1")
        self.assertEqual(e.exception.status, 404)
        self.office.assign("awesome-gb/0/backend/1", "x1")
        self.assertEqual(self.seat("x1"), "awesome-gb/0/backend/1")
        self.assertEqual(self.desk_events()[-1], ("desk.assigned", "awesome-gb/0/backend/1", "x1", "manual"))
        # el rol queda fijado: un task.state posterior sin rol no lo baja al vestíbulo
        self.thread("x1", "sin rol")
        self.step()
        self.assertEqual(self.seat("x1"), "awesome-gb/0/backend/1")
        self.assertEqual(self.office._snap("x1")["role"], "backend")
        # traslado: el escritorio anterior queda libre (sin linaje)
        self.office.assign("awesome-gb/1/frontend/0", "x1")
        occ = self.occupants()
        self.assertEqual((occ["awesome-gb/0/backend/1"], occ["awesome-gb/1/frontend/0"]), (None, "x1"))
        self.assertEqual(self.office.desk("awesome-gb/0/backend/1")["lineage"], [])

    def test_bootstrap_seats_only_active(self):
        self.thread("old", "[be] viejo", "completed", role="backend", ended_at=T0 - 86400)
        self.thread("run", "[be] vivo", role="backend")
        self.step()
        self.assertEqual((self.seat("run"), self.seat("old")), ("awesome-gb/0/backend/0", None))
        self.assertIsNotNone(self.office._meta(office.CURSOR))

    def test_equivalence_state_fold(self):
        """Proyección desde SQLite == fold del historial, y los ocupantes coinciden con la DB de la oficina."""
        self.step()
        for i, (tid, role) in enumerate([("a", "backend"), ("b", "backend"), ("c", "backend"), ("f", "frontend"),
                                         ("g", "frontend"), ("x", None), ("t", "triage")]):
            self.thread(tid, "hilo " + tid, role=role)
            self.step(10)
        self.end("a", "hilo a")
        self.end("f", "hilo f", role="frontend")
        self.step(30)
        self.thread("d", "hilo d", role="backend")
        self.step(30)
        envs = self.envs()
        st = self.state()
        self.assertEqual(st, projection.fold(envs, "contabo-dev"))
        db_occ = {r["id"]: self.office._occupant(r["id"]) for r in self.office._q("SELECT id FROM desks")}
        self.assertEqual(self.occupants(st), {k: (v or {}).get("thread_id") for k, v in db_occ.items()})
        for e in envs:
            self.assertEqual(envelope.errors(e), [], e["type"])


class TestProjectionFixture(unittest.TestCase):
    """fold(office-fixture.jsonl) == office-fixture.state.json (herencia, rol lleno, nota, retiro).
    Con CHOPSHOP_UPDATE_GOLDEN=1 regenera ambos desde el escenario (la app de Mac usa el par para su test de equivalencia)."""

    JSONL = os.path.join(FIX, "office-fixture.jsonl")
    GOLDEN = os.path.join(FIX, "office-fixture.state.json")

    def scenario(self):
        b = Base("run")
        b.setUp()
        try:
            b.step()
            b.thread("mcp:a1", "[be] sesión", role="backend")
            b.thread("mcp:f1", "[fe] tema", role="frontend")
            b.thread("mcp:f2", "[fe] modo oscuro", role="frontend")
            b.step(60)
            b.end("mcp:a1", "[be] sesión")
            b.step(60)
            b.thread("mcp:b7", "[be] login con passkeys", role="backend")
            b.step(60)
            b.emit("desk.note", "awesome-gb", {"desk": "awesome-gb/0/triage/0", "from": "grok-facundo",
                                               "text": "Revisar issues sin triage", "pending": 1})
            b.thread("mcp:b8", "[be] segundo", role="backend")
            b.step()
            b.prof = profile(backend=1)
            b.office.reload()
            return b.envs()
        finally:
            b.doCleanups()

    def test_fold_matches_golden(self):
        if os.environ.get("CHOPSHOP_UPDATE_GOLDEN") == "1":
            envs = self.scenario()
            with open(self.JSONL, "w", encoding="utf-8") as f:
                f.writelines(json.dumps(e, ensure_ascii=False, sort_keys=True) + "\n" for e in envs)
            st = projection.fold(envs, "contabo-dev")
            with open(self.GOLDEN, "w", encoding="utf-8") as f:
                f.write(json.dumps(st, sort_keys=True, indent=2, ensure_ascii=False) + "\n")
        with open(self.JSONL, encoding="utf-8") as f:
            envs = [json.loads(line) for line in f if line.strip()]
        with open(self.GOLDEN, encoding="utf-8") as f:
            golden = json.load(f)
        st = projection.fold(envs, "contabo-dev")
        self.assertEqual(json.loads(json.dumps(st)), golden)
        self.assertEqual(projection.fold(envs + envs, "contabo-dev"), st)          # idempotente
        p = st["projects"][0]
        desks = {d["id"]: d for d in projection._desks(p["office"])}
        self.assertEqual(desks["awesome-gb/0/backend/0"]["occupant"]["thread_id"], "mcp:b7")
        self.assertEqual(desks["awesome-gb/0/backend/0"]["lineage"][0]["reason"], "inherited")
        self.assertEqual(desks["awesome-gb/1/frontend/0"]["occupant"]["thread_id"], "mcp:f1")
        self.assertEqual(desks["awesome-gb/0/triage/0"]["notes_pending"], 1)
        self.assertEqual(desks["awesome-gb/0/backend/1"]["retired"], True)
        self.assertEqual(desks["awesome-gb/0/backend/1"]["lineage"][0]["reason"], "retired")
        self.assertEqual([(x["thread_id"], x["waiting_role"]) for x in st["lobby"]], [("mcp:f2", "frontend"), ("mcp:b8", "backend")])

    def test_desk_golden_envelopes_apply(self):
        """Los sobres dorados de la fase 0 (fixtures/events/desk.*) se aplican sobre una oficina con la regla del contrato."""
        ev = os.path.join(os.path.dirname(__file__), "fixtures", "events")

        def load(n):
            with open(os.path.join(ev, n + ".json"), encoding="utf-8") as f:
                return json.load(f)
        changed = dict(load("office.changed"), seq=1)
        st = projection.fold([changed])
        a, r, w = load("desk.assigned"), load("desk.released"), load("desk.waiting")
        occ_prev = dict(a, seq=a["seq"] - 10, body=dict(a["body"], thread_id="mcp:a1", reason="start", inheritance=None))
        st = projection.fold([occ_prev, dict(r, seq=a["seq"] - 1), a, w], state=st)   # el agente libera antes de asignar
        self.assertEqual([(x["thread_id"], x["waiting_role"]) for x in st["lobby"]], [("mcp:c9", "frontend")])  # lobby.py
        p = next(x for x in st["projects"] if x["name"] == "awesome-gb")
        d = projection._find_desk(p, "awesome-gb/0/backend/0")
        self.assertEqual((d["occupant"]["thread_id"], d["lineage"][0]["thread_id"]), ("mcp:b7", "mcp:a1"))


class TestRoutes(Base):
    def app(self):
        a = server.AgentApp(self.cfg, self.conn, collector=None, t3=None, auth=None, office=self.office)
        ident = server.Identity("local", None, True)
        return lambda m, p, body=None: a.call(m, p, ident, {}, body or {})

    def test_desk_and_assign(self):
        call = self.app()
        self.step()
        self.thread("x1", "sin rol")
        self.step()
        code, d = call("GET", "/desks/awesome-gb/0/backend/0")
        self.assertEqual((code, d["desk"]["role"], d["occupant"]), (200, "backend", None))
        with self.assertRaises(server.ApiError) as e:
            call("GET", "/desks/awesome-gb/9/nada/0")
        self.assertEqual(e.exception.status, 404)
        code, r = call("POST", "/desks/awesome-gb/0/backend/0/assign", {"thread_id": "x1"})
        self.assertEqual((code, r["desk"]), (200, "awesome-gb/0/backend/0"))
        self.assertEqual(call("GET", "/desks/awesome-gb%2F0%2Fbackend%2F0")[1]["occupant"]["thread_id"], "x1")
        with self.assertRaises(server.ApiError) as e:
            call("POST", "/desks/awesome-gb/0/backend/0")
        self.assertEqual(e.exception.status, 405)
        with self.assertRaises(server.ApiError) as e:
            call("POST", "/desks/awesome-gb/0/backend/1/assign", {})
        self.assertEqual(e.exception.status, 400)

    def test_without_office_503(self):
        a = server.AgentApp(self.cfg, self.conn, collector=None, t3=None, auth=None)
        with self.assertRaises(server.ApiError) as e:
            a.call("GET", "/desks/awesome-gb/0/backend/0", server.Identity("local", None, True), {}, {})
        self.assertEqual(e.exception.status, 503)


class TestT3watchRole(unittest.TestCase):
    """t3watch pone `role` (reglas `match` del perfil) y `ended_at` en el cuerpo de los hilos."""

    def setUp(self):
        from test_agent_t3watch import FakeServer
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = os.path.join(self.tmp.name, "home")
        os.makedirs(os.path.join(home, "profiles"))
        with open(os.path.join(home, "profiles", "proyecto-demo.yaml"), "w", encoding="utf-8") as f:
            f.write("project: proyecto-demo\noffice:\n  floors:\n    - name: P\n      rooms:\n"
                    "        - {role: demo, desks: 1}\n  roles:\n    demo:\n      match: {title: \"^Implementar\"}\n")
        old = os.environ.get("CHOPSHOP_HOME")
        os.environ["CHOPSHOP_HOME"] = home
        self.addCleanup(lambda: os.environ.__setitem__("CHOPSHOP_HOME", old) if old else os.environ.pop("CHOPSHOP_HOME"))
        self.cfg = copy.deepcopy(agent_config.DEFAULTS)
        self.conn = db.connect(os.path.join(self.tmp.name, "agent.db"))
        self.addCleanup(self.conn.close)
        self.srv = FakeServer()
        self.now = [T0]
        self.t3 = t3watch.T3(self.cfg, client=self.srv, clock=lambda: self.now[0])
        self.events = []

    def poll(self, advance=60):
        self.now[0] += advance
        t3watch.poll(self.conn, self.cfg, self.t3, lambda e, p, b: self.events.append((e, p, b)) or len(self.events))

    def test_role_and_ended_at(self):
        self.poll()
        self.srv.set("t-run", status="completed", updatedAt="2026-10-28T11:00:00.000Z")
        self.poll()
        ev, project, body = self.events[-1]
        self.assertEqual((ev, body["role"], body["ended_at"]), ("thread_done", "demo", envelope.iso(self.now[0])))
        self.assertEqual(body["summary"], body["result"])
        row = self.conn.execute("SELECT role, ended_at FROM t3_threads WHERE thread_id='t-run'").fetchone()
        self.assertEqual((row["role"], row["ended_at"]), ("demo", self.now[0]))
        ended = self.now[0]
        self.srv.set("t-run", settled=True, updatedAt="2026-10-28T11:05:00.000Z")
        self.poll()
        self.assertEqual(self.events[-1][2]["ended_at"], envelope.iso(ended))      # settle no mueve el fin


if __name__ == "__main__":
    unittest.main()
