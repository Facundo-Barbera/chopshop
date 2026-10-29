"""Pruebas de la oficina por escritorios (agent/office.py, agent/halflife.py y la regla `apply` de la v3 en projection.py):
asignación, herencia, rol lleno -> vestíbulo, semivida (desvanece, tocar reinicia, con atención no sale), retiro, asignación
manual y la equivalencia `state(conn) == fold(apply, sobres)`. Fixtures: tests/fixtures/office/."""
import copy
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop.agent import config as agent_config, db, envelope, events, halflife, office, projection, server, t3watch  # noqa: E402

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


class TestHalfLife(unittest.TestCase):
    def test_shared_table(self):
        with open(os.path.join(FIX, "halflife.json"), encoding="utf-8") as f:
            table = json.load(f)
        self.assertEqual((table["fade_out"], table["failed_factor"]), (halflife.FADE_OUT, halflife.FAILED_FACTOR))
        for c in table["cases"]:
            args = (c["phase"], c["attention"], c["ended_at"], c["touched_at"], c["half_life_s"])
            self.assertAlmostEqual(halflife.opacity(*args, c["now"]), c["opacity"], places=6, msg=c["name"])
            self.assertEqual(halflife.gone(*args, c["now"]), c["gone"], c["name"])
            ex = halflife.exit_at(*args)
            if c["exit_at"] is None:
                self.assertIsNone(ex, c["name"])
            else:
                self.assertAlmostEqual(ex, c["exit_at"], places=2, msg=c["name"])

    def test_iso_dates(self):
        self.assertAlmostEqual(halflife.opacity("done", None, envelope.iso(T0), None, 1800, T0 + 1800), 0.5)


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
        self.assertEqual(self.seat("a1"), "awesome-gb/0/backend/0")             # en semivida, sigue sentado
        self.thread("b7", "[be] login", role="backend")
        self.step(60)
        self.assertEqual(self.seat("b7"), "awesome-gb/0/backend/0")             # hereda el que se desvanece (no el libre)
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

    def test_inheritance_from_lineage_after_fade(self):
        self.step()
        self.thread("t1", "triage lunes", role="triage")
        self.step()
        self.end("t1", "triage lunes", role="triage")
        self.step(HL * 4)                                                       # se desvaneció del todo
        self.assertIsNone(self.seat("t1"))
        self.thread("t2", "triage martes", role="triage")
        self.step()
        a = self.envs(types=("desk.assigned",))[-1]["body"]
        self.assertEqual((a["reason"], a["inheritance"]["thread_id"]), ("start", "t1"))

    def test_role_full_waits_in_lobby_then_promoted(self):
        self.step()
        self.thread("f1", "[fe] tema", role="frontend")
        self.thread("f2", "[fe] modo oscuro", role="frontend")
        self.step()
        self.assertEqual(self.seat("f1"), "awesome-gb/1/frontend/0")
        self.assertIsNone(self.seat("f2"))
        st = self.state()
        self.assertEqual([(x["thread_id"], x["waiting_role"], x["company"]) for x in st["lobby"]],
                         [("f2", "frontend", "Awesome GB")])
        self.thread("f2", "[fe] modo oscuro", role="frontend")                   # un task.state más: no repite desk.waiting
        self.step()
        self.assertEqual(len(self.envs(types=("desk.waiting",))), 1)
        self.end("f1", "[fe] tema", role="frontend")
        self.step()
        # el que espera está activo: hereda el escritorio en semivida
        self.assertEqual(self.seat("f2"), "awesome-gb/1/frontend/0")
        self.assertEqual(self.state()["lobby"], [])

    def test_waiting_promoted_when_desk_fades(self):
        self.step()
        self.thread("f1", "[fe] uno", role="frontend")
        self.step()
        self.thread("f1", "[fe] uno", "completed", role="frontend", ended_at=self.now)
        # f1 terminó pero tiene una pregunta abierta: no está en semivida, no se hereda
        events.emit(self.conn, self.cfg, "pending_question", "awesome-gb",
                    {"thread_id": "f1", "title": "[fe] uno", "request_id": "r1", "questions": [{"question": "¿Sigo?"}]},
                    ts=self.now)
        self.thread("q1", "nuevo", role="frontend")
        self.step()
        self.assertIsNone(self.seat("q1"))
        self.step(HL * 10)
        self.assertEqual(self.seat("f1"), "awesome-gb/1/frontend/0")             # con atención no se desvanece
        events.emit(self.conn, self.cfg, "thread_done", "awesome-gb",
                    {"thread_id": "f1", "title": "[fe] uno", "status": "completed", "role": "frontend",
                     "ended_at": envelope.iso(self.now)}, ts=self.now)
        self.step()
        self.assertEqual(self.seat("q1"), "awesome-gb/1/frontend/0")             # heredó al cerrarse la atención

    def test_no_role_goes_to_lobby_and_fades(self):
        self.step()
        self.thread("x1", "explorar algo")
        self.thread("x9", "rol sin escritorios", role="ops")
        self.step()
        self.assertIsNone(self.seat("x1"))
        st = self.state()
        self.assertEqual(sorted((x["thread_id"], x["waiting_role"]) for x in st["lobby"]), [("x1", None), ("x9", "ops")])
        self.end("x1", "explorar algo", role=None)
        self.step(HL * 3)
        self.assertEqual(len(self.state()["lobby"]), 2)                         # 0.125 > 0.1: sigue
        self.step(HL * 0.5)
        lobby = self.state()["lobby"]
        self.assertEqual([x["thread_id"] for x in lobby], ["x9"])
        self.assertIn(("desk.released", None, "x1", "faded"), self.desk_events())

    def test_fade_failed_double_and_touch_resets(self):
        self.step()
        self.thread("b1", "[be] uno", role="backend")
        self.step()
        self.end("b1", "[be] uno", status="failed")
        self.step(HL * 4)
        self.assertEqual(self.seat("b1"), "awesome-gb/0/backend/0")             # fallido: 2 × T½ (0.25)
        touched = self.office.touch("b1")
        self.assertEqual(touched, envelope.iso(self.now))
        ts = self.envs(types=("task.state",))[-1]
        self.assertEqual((ts["body"]["touched_at"], ts["body"]["phase"], ts["severity"]), (touched, "failed", "error"))
        self.step(HL * 6)
        self.assertEqual(self.seat("b1"), "awesome-gb/0/backend/0")             # 0.125 desde el toque
        self.step(HL * 1)
        self.assertIsNone(self.seat("b1"))
        self.assertEqual(self.desk_events()[-1], ("desk.released", "awesome-gb/0/backend/0", "b1", "faded"))
        occ = self.occupants()
        self.assertIsNone(occ["awesome-gb/0/backend/0"])

    def test_touch_keeps_attention_open(self):
        self.step()
        self.thread("b1", "[be] uno", role="backend")
        events.emit(self.conn, self.cfg, "pending_question", "awesome-gb",
                    {"thread_id": "b1", "title": "[be] uno", "request_id": "r1", "questions": [{"question": "¿Sigo?"}]},
                    ts=self.now)
        self.step()
        self.office.touch("b1")
        st = self.state()
        self.assertEqual([a["key"] for a in st["projects"][0]["attention"]], ["task:b1"])

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
        self.assertEqual(self.state()["lobby"], [])
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
        self.thread("lob", "sin rol")
        self.step()
        self.assertEqual((self.seat("run"), self.seat("old")), ("awesome-gb/0/backend/0", None))
        self.assertEqual([x["thread_id"] for x in self.state()["lobby"]], ["lob"])
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
        self.end("x", "hilo x", role=None)
        self.step(30)
        self.office.touch("x")
        self.step(HL * 5)
        envs = self.envs()
        st = self.state()
        self.assertEqual(st, projection.fold(envs, "contabo-dev"))
        db_occ = {r["id"]: self.office._occupant(r["id"]) for r in self.office._q("SELECT id FROM desks")}
        self.assertEqual(self.occupants(st), {k: (v or {}).get("thread_id") for k, v in db_occ.items()})
        self.assertEqual(sorted(x["thread_id"] for x in st["lobby"]),
                         sorted(r["thread_id"] for r in self.office._q("SELECT thread_id FROM office_lobby")))
        for e in envs:
            self.assertEqual(envelope.errors(e), [], e["type"])


class TestProjectionFixture(unittest.TestCase):
    """fold(office-fixture.jsonl) == office-fixture.state.json (herencia, rol lleno, vestíbulo, nota, salida por semivida).
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
            b.thread("mcp:x1", "explorar")
            b.step(60)
            b.end("mcp:a1", "[be] sesión")
            b.end("mcp:x1", "explorar", role=None)
            b.step(60)
            b.thread("mcp:b7", "[be] login con passkeys", role="backend")
            b.step(60)
            b.emit("desk.note", "awesome-gb", {"desk": "awesome-gb/0/triage/0", "from": "grok-facundo",
                                               "text": "Revisar issues sin triage", "pending": 1})
            b.step(HL * 4)
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
        self.assertEqual([(x["thread_id"], x["waiting_role"]) for x in st["lobby"]], [("mcp:f2", "frontend")])

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
        p = next(x for x in st["projects"] if x["name"] == "awesome-gb")
        d = projection._find_desk(p, "awesome-gb/0/backend/0")
        self.assertEqual((d["occupant"]["thread_id"], d["lineage"][0]["thread_id"]), ("mcp:b7", "mcp:a1"))
        self.assertEqual([(x["thread_id"], x["waiting_role"]) for x in st["lobby"]], [("mcp:c9", "frontend")])


class TestRoutes(Base):
    def app(self):
        a = server.AgentApp(self.cfg, self.conn, collector=None, t3=None, auth=None, office=self.office)
        ident = server.Identity("local", None, True)
        return lambda m, p, body=None: a.call(m, p, ident, {}, body or {})

    def test_desk_touch_assign(self):
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
        code, t = call("POST", "/touch", {"thread_id": "x1"})
        self.assertEqual((code, t["touched_at"]), (200, envelope.iso(self.now)))
        with self.assertRaises(server.ApiError) as e:
            call("POST", "/touch", {})
        self.assertEqual(e.exception.status, 400)

    def test_without_office_503(self):
        a = server.AgentApp(self.cfg, self.conn, collector=None, t3=None, auth=None)
        with self.assertRaises(server.ApiError) as e:
            a.call("POST", "/touch", server.Identity("local", None, True), {}, {"thread_id": "x"})
        self.assertEqual(e.exception.status, 503)


class TestT3watchRole(unittest.TestCase):
    """t3watch pone `role` (reglas `match` del perfil), `ended_at` y `touched_at` en el cuerpo de los hilos."""

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

    def test_role_ended_touched(self):
        self.poll()
        with db.tx():
            self.conn.execute("INSERT INTO thread_touch(thread_id, touched_at) VALUES('t-run', ?)", (T0,))
        self.srv.set("t-run", status="completed", updatedAt="2026-10-28T11:00:00.000Z")
        self.poll()
        ev, project, body = self.events[-1]
        self.assertEqual((ev, body["role"], body["ended_at"], body["touched_at"]),
                         ("thread_done", "demo", envelope.iso(self.now[0]), envelope.iso(T0)))
        self.assertEqual(body["summary"], body["result"])
        row = self.conn.execute("SELECT role, ended_at FROM t3_threads WHERE thread_id='t-run'").fetchone()
        self.assertEqual((row["role"], row["ended_at"]), ("demo", self.now[0]))
        ended = self.now[0]
        self.srv.set("t-run", settled=True, updatedAt="2026-10-28T11:05:00.000Z")
        self.poll()
        self.assertEqual(self.events[-1][2]["ended_at"], envelope.iso(ended))      # settle no mueve el fin


if __name__ == "__main__":
    unittest.main()
