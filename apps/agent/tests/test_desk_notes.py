"""Notas de bots en escritorios (chopshop.agent.notes y `POST /desks/<id>/notes`, docs/plans/office-redesign.md §5)."""
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop.agent import db, envelope, notes  # noqa: E402
from test_agent_server import ServerBase  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
EXAMPLE = os.path.join(ROOT, "examples", "profiles", "awesome-gb.example.yaml")
DESK = "awesome-gb/0/triage/0"
T0 = 1_800_000_000.0


class NotesUnit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-notes-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = db.connect(os.path.join(self.tmp, "agent.db"))
        self.addCleanup(self.conn.close)

    def test_add_pending_consume(self):
        a = notes.add(self.conn, DESK, "Grok · Facundo", "  Prioriza pagos.\n  Y el login. ", None, T0)
        self.assertEqual((a["text"], a["expires"]), ("Prioriza pagos.\n  Y el login.", T0 + notes.DEFAULT_TTL))
        notes.add(self.conn, DESK, "Grok · Juan Manuel", "Revisa el CI rojo", 120, T0 + 1)
        notes.add(self.conn, "awesome-gb/0/backend/0", "Grok · Facundo", "otra mesa", None, T0)
        self.assertEqual(notes.count(self.conn, DESK, T0 + 2), 2)
        self.assertEqual([n["from"] for n in notes.pending(self.conn, DESK, T0 + 2)], ["Grok · Facundo", "Grok · Juan Manuel"])
        # caduca la de ttl 120 s
        self.assertEqual(notes.count(self.conn, DESK, T0 + 200), 1)
        got = notes.consume(self.conn, DESK, T0 + 200, by="mcp:t1")
        self.assertEqual([(n["text"][:8], n["consumed_by"]) for n in got], [("Prioriza", "mcp:t1")])
        self.assertEqual((notes.count(self.conn, DESK, T0 + 200), notes.consume(self.conn, DESK, T0 + 201)), (0, []))
        self.assertEqual(notes.count(self.conn, "awesome-gb/0/backend/0", T0 + 200), 1)
        block = notes.prompt_block(got)
        self.assertIn("Grok · Facundo", block)
        self.assertIn("Prioriza pagos.\n    Y el login.", block)
        self.assertEqual(notes.prompt_block([]), "")

    def test_validation(self):
        for frm, text, ttl in (("", "x", None), ("a\x07", "x", None), ("a" * 65, "x", None), ("bot", "", None),
                               ("bot", "   ", None), ("bot", 3, None), ("bot", "x" * 2049, None), ("bot", "ñ" * 1025, None),
                               ("bot", "a\x00b", None), ("bot", "x", 10), ("bot", "x", 8 * 86400), ("bot", "x", True),
                               ("bot", "x", "60")):
            with self.assertRaises(notes.NoteError, msg=(frm, text, ttl)):
                notes.add(self.conn, DESK, frm, text, ttl, T0)
        notes.add(self.conn, DESK, "bot", "x" * 2048, 60, T0)          # justo 2 KB
        notes.add(self.conn, DESK, "bot", "a\tb\nc", 60, T0)

    def test_truncate_and_body(self):
        self.assertEqual(notes.truncate("ñ" * 3, 5), "ññ")
        b = notes.body({"desk": DESK, "from": "bot", "text": "hola", "expires": T0}, 2)
        self.assertEqual(b, {"desk": DESK, "from": "bot", "text": "hola", "pending": 2, "expires": envelope.iso(T0)})
        env = envelope.build("desk.note", "awesome-gb", b, machine="m", ts=T0)
        envelope.validate(env)
        self.assertEqual((env["subject"]["kind"], env["subject"]["id"], env["needs"]), ("desk", DESK, None))

    def test_inbox_cap_and_prune(self):
        for i in range(notes.MAX_PENDING + 3):
            notes.add(self.conn, DESK, "bot", "n%d" % i, None, T0 + i)
        live = notes.pending(self.conn, DESK, T0 + 100)
        self.assertEqual((len(live), live[0]["text"]), (notes.MAX_PENDING, "n3"))
        notes.consume(self.conn, DESK, T0 + 100, "t")
        self.assertEqual(notes.prune(self.conn, T0 + 100 + notes.KEEP_S - 1), 3)      # solo las descartadas por el tope
        self.assertEqual(notes.prune(self.conn, T0 + 101 + notes.KEEP_S), notes.MAX_PENDING)

    def test_table_is_idempotent_and_keeps_schema_version(self):
        notes.ensure(self.conn)
        notes.ensure(self.conn)
        self.assertEqual(self.conn.execute("PRAGMA user_version").fetchone()[0], db.SCHEMA_VERSION)
        with self.assertRaises(sqlite3.IntegrityError):
            self.conn.execute('INSERT INTO desk_notes(id, desk_id, "from", text, created, expires) VALUES(NULL,?,?,?,?,?)',
                              (DESK, None, "x", 0, 0))


class NotesRoute(ServerBase):
    def setUp(self):
        super().setUp()
        pdir = os.path.join(self.tmp, "home", "profiles")
        os.makedirs(pdir)
        shutil.copy(EXAMPLE, os.path.join(pdir, "awesome-gb.yaml"))

    def test_post_note_emits_desk_note(self):
        self.start()
        st, body, _ = self.post("/desks/%s/notes" % DESK, {"from": "Grok · Facundo", "text": "Mañana prioriza pagos."})
        self.assertEqual((st, body["ok"], body["pending"]), (200, True, 1))
        st, body, _ = self.post("/desks/%s/notes" % DESK, {"from": "Grok · Juan Manuel", "text": "CI rojo", "ttl_s": 3600})
        self.assertEqual((st, body["pending"]), (200, 2))
        evs = [e for e in self.get("/events")[1]["events"] if e["type"] == "desk.note"]
        self.assertEqual(len(evs), 2)
        e = evs[-1]
        self.assertEqual((e["project"], e["subject"], e["needs"]), ("awesome-gb", {"kind": "desk", "id": DESK}, None))
        self.assertEqual({k: e["body"][k] for k in ("desk", "from", "text", "pending", "expires")},
                         {"desk": DESK, "from": "Grok · Juan Manuel", "text": "CI rojo", "pending": 2,
                          "expires": envelope.iso(self.clock.t + 3600)})
        self.assertEqual([n["from"] for n in notes.pending(self.conn, DESK, self.clock.t)],
                         ["Grok · Facundo", "Grok · Juan Manuel"])

    def test_errors(self):
        self.start()
        for desk in ("awesome-gb/0/triage/1", "awesome-gb/9/triage/0", "otro/0/triage/0", "nada", "a/b/c/d"):
            self.assertEqual(self.post("/desks/%s/notes" % desk, {"from": "bot", "text": "x"})[0], 404, desk)
        self.assertEqual(self.post("/desks/%s/notes" % DESK, {"from": "bot"})[0], 400)
        self.assertEqual(self.post("/desks/%s/notes" % DESK, {"from": "bot", "text": "x" * 3000})[0], 400)
        self.assertEqual(self.post("/desks/%s/notes" % DESK, {"from": "bot", "text": "x", "ttl_s": 1})[0], 400)
        self.assertEqual(self.get("/desks/%s/notes" % DESK)[0], 405)
        self.assertEqual(self.post("/desks//notes", {"from": "bot", "text": "x"})[0], 404)
        self.assertEqual([e for e in self.get("/events")[1]["events"] if e["type"] == "desk.note"], [])
        # sin `from`, firma la identidad (origen local)
        st, body, _ = self.post("/desks/%s/notes" % DESK, {"text": "x"})
        self.assertEqual((st, notes.pending(self.conn, DESK, self.clock.t)[0]["from"]), (200, "local"))


if __name__ == "__main__":
    unittest.main()
