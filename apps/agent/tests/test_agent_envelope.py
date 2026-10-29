import glob
import json
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop.agent import db, envelope, events  # noqa: E402

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures", "events")


def load(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return json.load(f)


class TestUlid(unittest.TestCase):
    def test_format_and_time(self):
        u = envelope.Ulid()(1793290323.412)
        self.assertRegex(u, r"^[0-9A-HJKMNP-TV-Z]{26}$")
        self.assertAlmostEqual(envelope.id_time(u), 1793290323.412, places=3)

    def test_monotonic_same_ms_and_clock_backwards(self):
        now = [1000.0]
        gen = envelope.Ulid(clock=lambda: now[0], rand=lambda n: b"\xff" * (n - 1) + b"\xfe")
        a, b = gen(), gen()
        now[0] = 999.0                                    # reloj hacia atrás: sigue creciendo
        c = gen()
        now[0] = 1001.0
        d = gen()
        self.assertEqual(sorted([a, b, c, d]), [a, b, c, d])
        self.assertEqual(len({a, b, c, d}), 4)

    def test_overflow_moves_to_next_ms(self):
        gen = envelope.Ulid(clock=lambda: 5.0, rand=lambda n: b"\xff" * n)
        a, b = gen(), gen()
        self.assertLess(a, b)
        self.assertAlmostEqual(envelope.id_time(b), 5.001, places=3)

    def test_many_are_sorted(self):
        ids = [envelope.new_id() for _ in range(2000)]
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(len(set(ids)), len(ids))


class TestTime(unittest.TestCase):
    def test_iso_and_epoch(self):
        self.assertEqual(envelope.iso(1793290323.412), "2026-10-29T16:12:03.412Z")
        for s in ("2026-10-29T16:12:03.412Z", "2026-10-29T10:12:03.412-0600", "2026-10-29T16:12:03.412+00:00"):
            self.assertAlmostEqual(envelope.epoch(s), 1793290323.412, places=3)
        self.assertIsNone(envelope.epoch("ayer"))


class TestGolden(unittest.TestCase):
    def test_one_fixture_per_type_and_all_valid(self):
        files = sorted(p for p in glob.glob(os.path.join(FIXTURES, "*.json"))
                       if "-fixture." not in os.path.basename(p))   # ui-fixture.state.json = estado dorado (fold), no un sobre
        types = set()
        for p in files:
            env = load(os.path.basename(p))
            envelope.validate(env)
            self.assertEqual(env["type"] + ".json", os.path.basename(p))
            types.add(env["type"])
        self.assertEqual(types, set(envelope.TYPES))
        self.assertEqual(set(envelope.TYPES), set(envelope.SEVERITY) | set(envelope.GITHUB_TYPES))

    def test_needs_of_attention_events(self):
        self.assertEqual(load("question.opened.json")["needs"], "human")
        self.assertEqual(load("approval.requested.json")["needs"], "approval")
        self.assertIsNone(load("question.answered.json")["needs"])

    def test_ui_fixture(self):
        with open(os.path.join(FIXTURES, "ui-fixture.jsonl"), encoding="utf-8") as f:
            envs = [json.loads(l) for l in f if l.strip()]
        self.assertGreaterEqual(len(envs), 35)
        for e in envs:
            envelope.validate(e)
        seqs, ids = [e["seq"] for e in envs], [e["id"] for e in envs]
        self.assertEqual(seqs, sorted(seqs))
        self.assertEqual(len(set(seqs)), len(seqs))
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(len({e["project"] for e in envs if e["project"]}), 3)
        self.assertTrue({"task.state", "question.opened", "question.answered", "approval.requested",
                         "machine.health"} <= {e["type"] for e in envs})
        byid = {e["id"]: e for e in envs}
        for e in envs:                                     # cause.depth = padre + 1
            if e["cause"]["id"] in byid:
                self.assertEqual(e["cause"]["depth"], byid[e["cause"]["id"]]["cause"]["depth"] + 1)


class TestValidate(unittest.TestCase):
    def good(self):
        return load("task.state.json")

    def test_rejects(self):
        cases = [("v", 2), ("id", "nope"), ("ts", "2026-10-29 16:00"), ("machine", ""), ("type", "TaskState"),
                 ("severity", "fatal"), ("needs", "alguien"), ("subject", {"kind": "planeta", "id": "x"}),
                 ("cause", {"id": None, "depth": -1}), ("body", [])]
        for k, v in cases:
            e = self.good()
            e[k] = v
            with self.assertRaises(envelope.EnvelopeError, msg=k):
                envelope.validate(e)

    def test_body_schema(self):
        e = self.good()
        e["body"]["phase"] = "volando"
        self.assertIn("body.phase", "; ".join(envelope.errors(e)))
        q = load("question.opened.json")
        del q["body"]["request_id"]
        self.assertTrue(envelope.errors(q))

    def test_custom_types_only_check_envelope(self):
        e = envelope.build("triage.result", "p", {"x": 1}, machine="m")
        envelope.validate(e)


class TestLegacy(unittest.TestCase):
    BODIES = {
        "thread_started": {"thread_id": "mcp:1", "title": "T", "status": "running", "link": "t3://1"},
        "thread_done": {"thread_id": "mcp:1", "status": "completed", "result": "ok"},
        "thread_failed": {"thread_id": "mcp:1", "status": "failed"},
        "thread_settled": {"thread_id": "mcp:1", "status": "completed", "settled": True},
        "task_done": {"batch": "b-1", "task": "t-1", "thread": "mcp:1", "host": "h", "status": "completed"},
        "pending_question": {"thread_id": "mcp:1", "request_id": "rq", "questions": [
            {"id": "q", "question": "¿Sí?", "options": [{"label": "Sí"}, {"label": "No"}], "multiSelect": False}]},
        "pending_approval": {"thread_id": "mcp:1", "count": 2, "note": "n"},
        "batch_done": {"batch": "b-1", "host": "h", "tasks": {"t-1": "completed"}},
        "graph_exception": {"graph": "g-1", "node": "n-1", "label": "L", "reason": "r"},
        "graph_done": {"graph": "g-1", "batch": "b-1", "status": "done"},
        "reaction": {"level": "bot", "reaction": "pending_question", "batch": "b-1", "task": "t-1", "notify": "bot-x"},
        "t3_unreachable": {"error": "x", "retry_in": 10},
        "t3_recovered": {"down_seconds": 12.5},
        "agent_started": {"version": "0.6.0"},
    }

    def test_every_legacy_name_builds_a_valid_envelope(self):
        for name, typ in envelope.LEGACY_MAP.items():
            f = envelope.from_legacy(name, self.BODIES.get(name, {"task": "t-1"}), "m")
            self.assertEqual(f["type"], typ)
            self.assertEqual(f["body"]["legacy"], name)
            env = envelope.build(f["type"], "p", f["body"], f["severity"], f["needs"], f["subject"], machine="m")
            envelope.validate(env)
            for c in envelope.companions(f):
                envelope.validate(envelope.build(c["type"], "p", c["body"], c["severity"], c["needs"], c["subject"], machine="m"))

    def test_mapping_details(self):
        f = envelope.from_legacy("thread_failed", self.BODIES["thread_failed"])
        self.assertEqual((f["body"]["phase"], f["severity"], f["subject"]["id"]), ("failed", "error", "mcp:1"))
        f = envelope.from_legacy("pending_question", self.BODIES["pending_question"])
        self.assertEqual((f["needs"], f["body"]["options"], f["body"]["summary"]), ("human", ["Sí", "No"], "¿Sí?"))
        c = envelope.companions(f)[0]
        self.assertEqual((c["type"], c["body"]["phase"], c["body"]["attention"], c["needs"]), ("task.state", "waiting", "ask", "human"))
        f = envelope.from_legacy("pending_question", dict(self.BODIES["pending_question"], level="bot"))
        self.assertEqual((f["needs"], envelope.companions(f)[0]["body"]["attention"]), ("bot", "bot"))
        f = envelope.from_legacy("t3_unreachable", {})
        self.assertEqual((f["type"], f["body"]["state"], f["severity"], f["subject"]["kind"]), ("machine.health", "degraded", "warn", "machine"))
        f = envelope.from_legacy("prueba", {})
        self.assertEqual(f["type"], "legacy.prueba")
        f = envelope.from_legacy("task.state", {"phase": "running", "attention": None, "thread_id": "x", "settled": False})
        self.assertNotIn("legacy", f["body"])


class TestMigration(unittest.TestCase):
    def make_v2(self, path):
        os.makedirs(os.path.dirname(path))
        old = sqlite3.connect(path)
        old.executescript(db.SCHEMA + "PRAGMA user_version=2;")
        rows = [(1.0, "host-a", "thread_done", "p1", json.dumps({"thread_id": "mcp:1", "status": "completed"})),
                (2.0, "host-a", "pending_question", "p1", json.dumps({"thread_id": "mcp:1", "request_id": "rq"})),
                (3.0, "host-a", "t3_unreachable", None, "{}"),
                (4.0, "host-a", "raro", None, "no es json")]
        old.executemany("INSERT INTO events(ts,machine_id,event,project,body) VALUES(?,?,?,?,?)", rows)
        old.commit()
        old.close()

    def test_v2_to_v3_keeps_rows_and_fills(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "agent", "agent.db")
            self.make_v2(path)
            conn = db.connect(path)
            try:
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], db.SCHEMA_VERSION)
                rs = [dict(r) for r in conn.execute("SELECT * FROM events ORDER BY seq")]
                self.assertEqual([r["event"] for r in rs], ["thread_done", "pending_question", "t3_unreachable", "raro"])
                self.assertEqual([r["type"] for r in rs], ["task.state", "question.opened", "machine.health", "legacy.raro"])
                self.assertEqual([r["needs"] for r in rs], [None, "human", None, None])
                self.assertEqual([r["severity"] for r in rs], ["info", "notice", "warn", "info"])
                self.assertTrue(all(r["id"] and r["cause_depth"] == 0 for r in rs))
                self.assertEqual(json.loads(rs[0]["body"])["legacy"], "thread_done")
                ids = [r["id"] for r in rs]
                for e in events.list_after(conn):
                    envelope.validate(e)
                db._migrate_v3(conn)                                     # repetir no cambia nada
                self.assertEqual([r[0] for r in conn.execute("SELECT id FROM events ORDER BY seq")], ids)
            finally:
                conn.close()
            conn = db.connect(path)                                      # reabrir una v3 tampoco
            try:
                self.assertEqual([r[0] for r in conn.execute("SELECT id FROM events ORDER BY seq")], ids)
                self.assertEqual(conn.execute("SELECT COUNT(*) FROM events").fetchone()[0], 4)
            finally:
                conn.close()

    def test_id_is_unique(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = db.connect(os.path.join(tmp, "a", "a.db"))
            try:
                events.emit(conn, {"machine_id": "m"}, "x", None)
                uid = conn.execute("SELECT id FROM events").fetchone()[0]
                with self.assertRaises(sqlite3.IntegrityError):
                    conn.execute("INSERT INTO events(ts,machine_id,event,id) VALUES(1,'m','y',?)", (uid,))
            finally:
                conn.close()


class TestEmitEnvelope(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conn = db.connect(os.path.join(self.tmp.name, "agent", "agent.db"))
        self.addCleanup(self.conn.close)
        self.addCleanup(events.flush)
        self.cfg = {"machine_id": "host-a", "webhook_files": {}}

    def test_cause_depth_propagates_and_caps(self):
        root = events.emit_envelope(self.conn, self.cfg, "github.issue.opened", "p",
                                    {"repo": "o/r", "number": 1, "action": "opened", "title": "t", "url": None})
        self.assertEqual(root["cause"], {"id": None, "depth": 0})
        e, chain = root, [root]
        for depth in (1, 2, 3):
            e = events.emit_envelope(self.conn, self.cfg, "triage.result", "p", {"n": depth}, cause=e)
            self.assertEqual(e["cause"], {"id": chain[-1]["id"], "depth": depth})
            chain.append(e)
        self.assertIsNone(events.emit_envelope(self.conn, self.cfg, "triage.result", "p", {"n": 4}, cause=e))
        listed = events.list_after(self.conn)
        self.assertEqual([x["cause"]["depth"] for x in listed], [0, 1, 2, 3])
        self.assertEqual([x["id"] for x in listed], [x["id"] for x in chain])

    def test_invalid_raises_and_stores_nothing(self):
        with self.assertRaises(envelope.EnvelopeError):
            events.emit_envelope(self.conn, self.cfg, "task.state", "p", {"phase": "volando"})
        self.assertEqual(events.last_seq(self.conn), 0)

    def test_ids_unique_and_sorted_like_seq(self):
        for i in range(50):
            events.emit(self.conn, self.cfg, "thread_started" if i % 2 else "pending_question", "p",
                        {"thread_id": "t%d" % i, "request_id": "r%d" % i, "status": "running"})
        evs = events.list_after(self.conn, 0, 1000)
        self.assertEqual([e["seq"] for e in evs], sorted(e["seq"] for e in evs))
        self.assertEqual([e["id"] for e in evs], sorted(e["id"] for e in evs))
        self.assertEqual(len({e["id"] for e in evs}), len(evs))
        for e in evs:
            envelope.validate(e)


if __name__ == "__main__":
    unittest.main()
