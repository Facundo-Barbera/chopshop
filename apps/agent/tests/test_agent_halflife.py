"""Pruebas de chopshop.agent.halflife (fase 2 del rediseño de la oficina): la función pura contra la tabla compartida,
el temporizador de salida sobre la proyección v3, los toques y `POST /touch`."""
import json
import os
import sys
import tempfile
import shutil
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from test_agent_server import ServerBase  # noqa: E402
from chopshop.agent import db, envelope, events, halflife as H, projection  # noqa: E402

TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "office", "halflife.json")
T0 = 1000000.0
HL = 1800.0


def iso(t):
    return envelope.iso(t) if t is not None else None


def occupant(tid, phase="done", ended=T0, touched=None, attention=None, hl=HL):
    return {"thread_id": tid, "title": tid, "role": "backend", "phase": phase, "attention": attention,
            "since": iso(T0 - 600), "ended_at": iso(ended), "touched_at": iso(touched), "half_life_s": hl}


def state(desks=(), lobby=(), attention=()):
    """Proyección v3 mínima: un proyecto con un piso de backend y los ocupantes dados."""
    ds = [{"id": "p/0/backend/%d" % i, "slot": i, "retired": False, "occupant": o, "lineage": [], "notes_pending": 0}
          for i, o in enumerate(desks)]
    office = {"company": "Acme", "half_life_s": HL,
              "floors": [{"index": 0, "name": "F", "rooms": [{"role": "backend", "permanent": False, "desks": ds}]}]}
    lob = [dict(it, project="p", company="Acme", waiting_role=None) for it in lobby]
    return {"api_version": 3, "projects": [{"name": "p", "tasks": [], "attention": list(attention), "office": office}],
            "lobby": lob}


class TestTable(unittest.TestCase):
    def test_shared_table(self):
        with open(TABLE) as f:
            t = json.load(f)
        self.assertEqual(t["fade_out"], H.FADE_OUT)
        self.assertEqual(t["failed_factor"], H.FAILED_FACTOR)
        for c in t["cases"]:
            with self.subTest(c["name"]):
                args = (c["phase"], c["attention"], c["ended_at"], c["touched_at"], c["half_life_s"])
                self.assertAlmostEqual(H.opacity(*args, c["now"]), c["opacity"], delta=1e-6)
                self.assertEqual(H.gone(*args, c["now"]), c["gone"])
                at = H.exit_at(*args)
                if c["exit_at"] is None:
                    self.assertIsNone(at)
                else:
                    self.assertAlmostEqual(at, c["exit_at"], delta=1e-3)

    def test_iso_dates(self):
        self.assertAlmostEqual(H.opacity("done", None, iso(T0), None, HL, T0 + HL), 0.5, delta=1e-6)
        self.assertAlmostEqual(H.opacity("done", None, iso(T0), iso(T0 + HL), HL, T0 + 2 * HL), 0.5, delta=1e-6)


class TestSchedule(unittest.TestCase):
    def test_desk_and_lobby_exits(self):
        st = state(desks=[occupant("a"), occupant("b", phase="failed"), occupant("c", phase="running", ended=None)],
                   lobby=[occupant("d", ended=T0 + 60)])
        plan = H.schedule(st)
        self.assertEqual([(p, d, t) for _a, p, d, t in plan],
                         [("p", "p/0/backend/0", "a"), ("p", None, "d"), ("p", "p/0/backend/1", "b")])
        self.assertEqual(H.due(st, T0 + 3.4 * HL), [("p", "p/0/backend/0", "a"), ("p", None, "d")])
        self.assertEqual(H.due(st, T0 + 3 * HL), [])

    def test_open_attention_never_fades(self):
        att = [{"key": "task:a", "needs": "human", "subject": {"kind": "task", "id": "a"}}]
        self.assertEqual(H.due(state(desks=[occupant("a")], attention=att), T0 + 100 * HL), [])
        self.assertEqual(H.due(state(desks=[occupant("a", attention="ask")]), T0 + 100 * HL), [])

    def test_local_touch_wins(self):
        st = state(desks=[occupant("a")])
        self.assertEqual(H.due(st, T0 + 3.4 * HL, {"a": T0 + HL}), [])
        self.assertEqual(len(H.due(st, T0 + 4.4 * HL, {"a": T0 + HL})), 1)
        self.assertEqual(len(H.due(st, T0 + 3.4 * HL, {"a": T0 - HL})), 1)    # tocado antes de terminar: no cuenta


class TestFader(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.mkdtemp(prefix="chopshop-hl-")
        self.addCleanup(shutil.rmtree, tmp, True)
        self.conn = db.connect(os.path.join(tmp, "agent.db"))
        self.addCleanup(self.conn.close)
        self.now, self.sent = T0, []
        self.st = state(desks=[occupant("a")], lobby=[occupant("d", phase="failed")])
        self.fader = H.Fader(self.conn, lambda: self.st, lambda *a: self.sent.append(a), clock=lambda: self.now)

    def test_fades_then_exits_once(self):
        self.assertEqual(self.fader.sweep(), [])
        self.assertAlmostEqual(self.fader.next_delay(), H.MAX_DELAY)
        self.now = T0 + 3.3 * HL
        self.assertEqual(self.fader.sweep(), [])
        self.assertAlmostEqual(self.fader.next_delay(), H.MAX_DELAY)
        self.now = T0 + HL * H._LOG2_10 - 5
        self.fader.sweep()
        self.assertAlmostEqual(self.fader.next_delay(), 5, delta=1e-3)
        self.now = T0 + 3.4 * HL
        self.assertEqual(self.fader.sweep(), [("p", "p/0/backend/0", "a")])
        self.assertEqual(self.sent, [("desk.released", "p", {"desk": "p/0/backend/0", "thread_id": "a", "reason": "faded"})])
        self.fader.sweep()                      # la proyección aún no lo sacó: no se repite
        self.assertEqual(len(self.sent), 1)
        self.now = T0 + 7 * HL                  # el fallido del vestíbulo dura el doble
        self.assertEqual(self.fader.sweep(), [("p", None, "d")])
        self.assertEqual(self.sent[-1][2], {"desk": None, "thread_id": "d", "reason": "faded"})
        env = envelope.build("desk.released", "p", self.sent[-1][2], subj=envelope.default_subject(
            "desk.released", "p", self.sent[-1][2]), machine="m")
        envelope.validate(env)

    def test_touch_resets_clock(self):
        H.touch(self.conn, "a", T0 + 3 * HL)
        self.now = T0 + 3.4 * HL
        self.assertEqual(self.fader.sweep(), [])
        self.now = T0 + 3 * HL + 3.4 * HL
        self.assertEqual(self.fader.sweep(), [("p", "p/0/backend/0", "a")])

    def test_attention_holds_until_closed(self):
        self.st["projects"][0]["office"]["floors"][0]["rooms"][0]["desks"][0]["occupant"]["attention"] = "ask"
        self.now = T0 + 50 * HL
        self.assertNotIn("a", [t for _p, _d, t in self.fader.sweep()])
        self.st["projects"][0]["office"]["floors"][0]["rooms"][0]["desks"][0]["occupant"]["attention"] = None
        self.assertIn(("p", "p/0/backend/0", "a"), self.fader.sweep())

    def test_stamp(self):
        body = {"thread_id": "a", "status": "completed"}
        self.assertIs(H.stamp(self.conn, "thread_done", body), body)
        H.touch(self.conn, "a", T0)
        self.assertEqual(H.stamp(self.conn, "thread_done", body)["touched_at"], iso(T0))
        self.assertEqual(H.stamp(self.conn, "task.state", body)["touched_at"], iso(T0))
        self.assertNotIn("touched_at", H.stamp(self.conn, "question.answered", body))
        self.assertEqual(H.stamp(self.conn, "task.state", dict(body, touched_at="x"))["touched_at"], "x")


class TestTouchRoute(ServerBase):
    def setUp(self):
        super().setUp()
        self.start()

    def _tasks(self):
        st = projection.state(self.conn, self.cfg)
        return {t["id"]: t for p in st["projects"] for t in p["tasks"]}

    def test_touch_reemits_task_state(self):
        events.emit(self.conn, self.cfg, "thread_done", "proyecto-demo",
                    {"thread_id": "mcp:a", "title": "x", "status": "completed"}, ts=T0)
        code, out, _ = self.post("/touch", {"thread_id": "mcp:a"})
        self.assertEqual(code, 200, out)
        self.assertTrue(out["ok"])
        self.assertEqual(out["touched_at"], iso(self.clock()))
        self.assertEqual(H.touched_at(self.conn, "mcp:a"), self.clock())
        t = self._tasks()["mcp:a"]
        self.assertEqual((t["phase"], t["touched_at"]), ("done", out["touched_at"]))
        # los task.state siguientes del hilo conservan el toque
        self.svc.emit("thread_settled", "proyecto-demo", {"thread_id": "mcp:a", "status": "completed", "settled": True})
        self.assertEqual(self._tasks()["mcp:a"]["touched_at"], out["touched_at"])

    def test_touch_keeps_attention(self):
        events.emit(self.conn, self.cfg, "pending_question", "proyecto-demo",
                    {"thread_id": "mcp:q", "request_id": "r1", "questions": [{"question": "¿sí?", "options": ["sí"]}]})
        self.post("/touch", {"thread_id": "mcp:q"})
        st = projection.state(self.conn, self.cfg)
        p = next(p for p in st["projects"] if p["name"] == "proyecto-demo")
        self.assertTrue(any(a["subject"]["id"] == "mcp:q" for a in p["attention"]))

    def test_touch_unknown_thread_and_bad_body(self):
        code, out, _ = self.post("/touch", {"thread_id": "mcp:nadie"})
        self.assertEqual(code, 200)
        self.assertEqual(self.post("/touch", {})[0], 400)


if __name__ == "__main__":
    unittest.main()
