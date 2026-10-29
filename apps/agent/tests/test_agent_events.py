import json
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop.agent import db, events  # noqa: E402

# Valor sentinela con forma de URL (dominio reservado .invalid): solo se usa para comprobar que nunca se filtra.
SECRET = "https://hooks.example.invalid/secreto-0123456789abcdef"


class FakePoster:
    """poster(url, data, timeout) falso: guarda las llamadas y responde según `plan[url]` (código, excepción o callable)."""

    def __init__(self, result=204):
        self.result = result
        self.calls = []
        self.lock = threading.Lock()

    def __call__(self, url, data, timeout):
        with self.lock:
            self.calls.append((url, json.loads(data.decode("utf-8")), timeout))
        r = self.result(url) if callable(self.result) else self.result
        if isinstance(r, BaseException):
            raise r
        return r


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conn = db.connect(os.path.join(self.tmp.name, "agent", "agent.db"))
        self.addCleanup(self.conn.close)
        self.addCleanup(events.flush)
        self.cfg = {"machine_id": "host-a", "webhook_files": {}}

    def hook(self, name, url=SECRET):
        p = os.path.join(self.tmp.name, name + ".url")
        with open(p, "w") as f:
            f.write("  %s  \nsegunda línea ignorada\n" % url)
        os.chmod(p, 0o600)
        return p

    def deliveries(self, seq=None):
        q = "SELECT event_seq,name,ok,detail FROM deliveries" + ("" if seq is None else " WHERE event_seq=%d" % seq)
        return {(r["event_seq"], r["name"]): (r["ok"], r["detail"]) for r in self.conn.execute(q + " ORDER BY name")}

    def dump(self):
        """Todo el contenido de la DB como texto, para buscar fugas."""
        return "\n".join(repr(tuple(r)) for t in ("events", "deliveries", "subscriptions", "meta")
                         for r in self.conn.execute("SELECT * FROM " + t))


class TestEmitList(Base):
    def test_emit_and_list_after(self):
        s1 = events.emit(self.conn, self.cfg, "thread_started", "proyecto-demo", {"thread_id": "t1", "n": 1})
        s2 = events.emit(self.conn, self.cfg, "thread_done", None)
        self.assertEqual((s1, s2), (1, 2))
        evs = events.list_after(self.conn)
        self.assertEqual([e["seq"] for e in evs], [1, 2])
        self.assertEqual({k: evs[0]["body"][k] for k in ("thread_id", "n", "legacy", "phase")},
                         {"thread_id": "t1", "n": 1, "legacy": "thread_started", "phase": "queued"})   # sobre: superconjunto
        self.assertEqual((evs[0]["type"], evs[0]["machine"]), ("task.state", "host-a"))
        self.assertEqual(evs[0]["machine_id"], "host-a")
        self.assertEqual(evs[0]["event"], "thread_started")
        self.assertEqual(evs[0]["project"], "proyecto-demo")
        self.assertIsNone(evs[1]["project"])
        self.assertEqual((evs[1]["body"]["legacy"], evs[1]["body"]["phase"]), ("thread_done", "done"))
        self.assertTrue(evs[0]["ts"].endswith("Z"))
        self.assertEqual([e["seq"] for e in events.list_after(self.conn, after=1)], [2])
        self.assertEqual([e["seq"] for e in events.list_after(self.conn, limit=1)], [1])
        self.assertEqual(events.list_after(self.conn, after=2), [])
        self.assertEqual(events.last_seq(self.conn), 2)
        self.assertEqual([e["seq"] for e in events.recent(self.conn, 1)], [2])

    def test_machine_id_default_and_unicode(self):
        seq = events.emit(self.conn, {"webhook_files": {}}, "x", "p", {"msg": "ñandú ✓"})
        e = events.list_after(self.conn)[0]
        self.assertTrue(e["machine_id"])
        self.assertEqual(e["body"]["msg"], "ñandú ✓")
        self.assertEqual(seq, e["seq"])


class TestSubscriptions(Base):
    def test_crud_without_url(self):
        f = self.hook("a")
        events.subscribe(self.conn, "bot", f, project="proyecto-demo", events=["thread_done"])
        events.subscribe(self.conn, "todo", f)
        subs = events.list_subscriptions(self.conn)
        self.assertEqual(list(subs), ["bot", "todo"])
        self.assertEqual(subs["bot"]["project"], "proyecto-demo")
        self.assertEqual(subs["bot"]["events"], ["thread_done"])
        self.assertEqual((subs["todo"]["project"], subs["todo"]["events"]), ("*", []))
        self.assertNotIn(SECRET, repr(subs))
        self.assertNotIn("webhook_file", repr(subs))
        created = subs["bot"]["created"]
        events.subscribe(self.conn, "bot", f, events="thread_failed")      # actualiza y conserva created
        subs = events.list_subscriptions(self.conn)
        self.assertEqual(subs["bot"]["events"], ["thread_failed"])
        self.assertEqual(subs["bot"]["created"], created)
        self.assertTrue(events.unsubscribe(self.conn, "bot"))
        self.assertFalse(events.unsubscribe(self.conn, "bot"))
        self.assertEqual(list(events.list_subscriptions(self.conn)), ["todo"])

    def test_rejects_url_and_bad_input(self):
        for bad in (SECRET, "http://100.64.0.10/hook", "", "  "):
            with self.assertRaises(events.EventsError) as cm:
                events.subscribe(self.conn, "x", bad)
            self.assertNotIn(SECRET, str(cm.exception))
        with self.assertRaises(events.EventsError):
            events.subscribe(self.conn, "mal nombre!", "/tmp/a")
        with self.assertRaises(events.EventsError):
            events.subscribe(self.conn, "x", "/tmp/a", events=[1])
        self.assertEqual(events.list_subscriptions(self.conn), {})
        self.assertNotIn(SECRET, self.dump())


class TestDelivery(Base):
    def test_filters_project_and_event(self):
        f = self.hook("a")
        events.subscribe(self.conn, "todo", f)
        events.subscribe(self.conn, "solo-demo", f, project="proyecto-demo")
        events.subscribe(self.conn, "solo-done", f, events=["thread_done"])
        events.subscribe(self.conn, "demo-done", f, project="proyecto-demo", events=["thread_done"])
        p = FakePoster()
        seq = events.emit(self.conn, self.cfg, "thread_started", "proyecto-demo", poster=p, wait=True)
        self.assertEqual(sorted(n for (_, n) in self.deliveries(seq)), ["solo-demo", "todo"])
        seq = events.emit(self.conn, self.cfg, "thread_done", "otro", poster=p, wait=True)
        self.assertEqual(sorted(n for (_, n) in self.deliveries(seq)), ["solo-done", "todo"])
        seq = events.emit(self.conn, self.cfg, "thread_done", "proyecto-demo", poster=p, wait=True)
        self.assertEqual(sorted(n for (_, n) in self.deliveries(seq)), ["demo-done", "solo-demo", "solo-done", "todo"])
        seq = events.emit(self.conn, self.cfg, "nada", None, poster=p, wait=True)
        self.assertEqual(sorted(n for (_, n) in self.deliveries(seq)), ["todo"])
        self.assertEqual(len(p.calls), 2 + 2 + 4 + 1)

    def test_payload_and_config_webhook_files(self):
        self.cfg["webhook_files"] = {"cfgbot": self.hook("cfg", "https://hooks.example.invalid/cfg")}
        p = FakePoster(200)
        seq = events.emit(self.conn, self.cfg, "pending_question", "proyecto-demo", {"thread_id": "t9"},
                          poster=p, timeout=2, wait=True)
        self.assertEqual(len(p.calls), 2)                                # task.state (attention) + question.opened
        url, payload, timeout = [c for c in p.calls if c[1]["event"] == "pending_question"][0]
        self.assertEqual(url, "https://hooks.example.invalid/cfg")     # primera línea, sin espacios
        self.assertEqual(timeout, 2)
        self.assertEqual(set(payload), {"v", "id", "seq", "ts", "machine", "project", "type", "severity", "needs",
                                        "subject", "cause", "body", "event", "machine_id"})
        self.assertEqual((payload["seq"], payload["machine_id"], payload["event"], payload["project"]),
                         (seq, "host-a", "pending_question", "proyecto-demo"))
        self.assertEqual((payload["type"], payload["needs"], payload["body"]["thread_id"], payload["body"]["legacy"]),
                         ("question.opened", "human", "t9", "pending_question"))
        self.assertEqual(self.deliveries(seq), {(seq, "cfgbot"): (1, "HTTP 200")})

    def test_default_timeout_is_short(self):
        p = FakePoster()
        events.subscribe(self.conn, "a", self.hook("a"))
        events.emit(self.conn, self.cfg, "x", None, poster=p, wait=True)
        self.assertEqual(p.calls[0][2], 3)

    def test_http_error_status_recorded(self):
        events.subscribe(self.conn, "a", self.hook("a"))
        seq = events.emit(self.conn, self.cfg, "x", None, poster=FakePoster(500), wait=True)
        self.assertEqual(self.deliveries(seq), {(seq, "a"): (0, "HTTP 500")})

    def test_emit_does_not_block_on_slow_webhook(self):
        events.subscribe(self.conn, "a", self.hook("a"))
        gate = threading.Event()
        started = threading.Event()

        def slow(url, data, timeout):
            started.set()
            gate.wait(5)
            return 204
        seq = events.emit(self.conn, self.cfg, "x", None, poster=slow)       # vuelve sin esperar la entrega
        self.assertTrue(started.wait(2))
        self.assertEqual(self.deliveries(seq), {})
        gate.set()
        self.assertTrue(events.flush(5))
        self.assertEqual(self.deliveries(seq), {(seq, "a"): (1, "HTTP 204")})

    def test_url_never_leaks_in_deliveries_or_exceptions(self):
        f = self.hook("a")
        events.subscribe(self.conn, "boom", f)
        events.subscribe(self.conn, "urlerr", f)
        events.subscribe(self.conn, "http", f)

        errs = {
            "boom": RuntimeError("fallo al conectar con " + SECRET),
            "urlerr": urllib.error.URLError(ConnectionRefusedError("rechazado " + SECRET)),
            "http": urllib.error.HTTPError(SECRET, 502, "Bad Gateway " + SECRET, {}, None),
        }
        calls = []

        def poster(url, data, timeout):
            calls.append(url)
            raise errs["boom" if len(calls) == 1 else "urlerr" if len(calls) == 2 else "http"]
        seq = events.emit(self.conn, self.cfg, "x", None, poster=poster, wait=True)
        self.assertEqual(len(calls), 3)
        d = self.deliveries(seq)
        self.assertEqual(len(d), 3)
        for ok, detail in d.values():
            self.assertEqual(ok, 0)
            self.assertNotIn("secreto", detail)
            self.assertNotIn("hooks.example", detail)
            self.assertNotIn("rechazado", detail)
        self.assertIn("URLError/ConnectionRefusedError", [v[1] for v in d.values()])
        self.assertIn("RuntimeError", [v[1] for v in d.values()])
        self.assertNotIn("secreto", self.dump())
        self.assertNotIn(SECRET, self.dump())

    def test_unreadable_or_invalid_webhook_file(self):
        bad = os.path.join(self.tmp.name, "mal.url")
        with open(bad, "w") as f:
            f.write("esto no es una URL\n")
        events.subscribe(self.conn, "falta", os.path.join(self.tmp.name, "no-existe.url"))
        events.subscribe(self.conn, "mal", bad)
        p = FakePoster()
        seq = events.emit(self.conn, self.cfg, "x", None, poster=p, wait=True)
        self.assertEqual(p.calls, [])
        d = self.deliveries(seq)
        self.assertEqual(d[(seq, "falta")], (0, "archivo de webhook ilegible (FileNotFoundError)"))
        self.assertEqual(d[(seq, "mal")], (0, "archivo de webhook ilegible (ValueError)"))
        self.assertNotIn("esto no es", self.dump())            # ni el contenido del archivo

    def test_url_read_on_each_delivery(self):
        f = self.hook("a", "https://hooks.example.invalid/uno")
        events.subscribe(self.conn, "a", f)
        p = FakePoster()
        events.emit(self.conn, self.cfg, "x", None, poster=p, wait=True)
        self.hook("a", "https://hooks.example.invalid/dos")
        events.emit(self.conn, self.cfg, "x", None, poster=p, wait=True)
        self.assertEqual([c[0] for c in p.calls], ["https://hooks.example.invalid/uno", "https://hooks.example.invalid/dos"])

    def test_default_poster_uses_urllib(self):
        # sin red: el poster por defecto falla (puerto cerrado en loopback) y el detail es solo el tipo
        events.subscribe(self.conn, "a", self.hook("a", "http://127.0.0.1:9/secreto-hook"))
        seq = events.emit(self.conn, self.cfg, "x", None, timeout=1, wait=True)
        ok, detail = self.deliveries(seq)[(seq, "a")]
        self.assertEqual(ok, 0)
        self.assertTrue(detail.startswith("URLError"), detail)
        self.assertNotIn("secreto", detail)

    def test_many_deliveries_concurrent(self):
        f = self.hook("a")
        for i in range(8):
            events.subscribe(self.conn, "s%d" % i, f)
        p = FakePoster()
        seqs = [events.emit(self.conn, self.cfg, "x", None, poster=p) for _ in range(5)]
        self.assertTrue(events.flush(5))
        self.assertEqual(len(p.calls), 40)
        self.assertEqual(len(self.deliveries()), 40)
        self.assertEqual(seqs, [1, 2, 3, 4, 5])


class TestLegacy(Base):
    LINES = [
        {"event": "task_done", "project": "p1", "ts": "2026-10-01T10:00:00-0600", "task": "a",
         "delivery": {"bot": "fallo: HTTP 404"}},
        {"event": "pending_question", "project": "p1", "ts": "2026-10-01T10:05:00-0600", "thread_id": "t1"},
        {"event": "batch_done", "project": None, "ts": "2026-10-01T11:00:00+0000"},
    ]

    def write(self, lines, mode="w"):
        p = os.path.join(self.tmp.name, "events.jsonl")
        with open(p, mode) as f:
            for ln in lines:
                f.write((ln if isinstance(ln, str) else json.dumps(ln)) + "\n")
        return p

    def test_import_idempotent(self):
        p = self.write(self.LINES + ["no es json", json.dumps({"sin": "evento"})])
        r = events.import_legacy(self.conn, p, machine_id="host-a")
        self.assertEqual(r, {"imported": 3, "skipped": 2})
        evs = events.list_after(self.conn)
        # la pregunta añade antes su task.state con attention
        self.assertEqual([e["event"] for e in evs], ["task_done", "task.state", "pending_question", "batch_done"])
        self.assertEqual([e["type"] for e in evs], ["task.state", "task.state", "question.opened", "batch.done"])
        self.assertEqual(evs[0]["body"]["task"], "a")
        self.assertFalse({"event", "project", "ts", "delivery"} & set(evs[0]["body"]))
        self.assertEqual(evs[0]["machine_id"], "host-a")
        self.assertEqual(evs[0]["ts"], "2026-10-01T16:00:00.000Z")
        self.assertIsNone(evs[3]["project"])
        self.assertEqual(events.import_legacy(self.conn, p, machine_id="host-a"), {"imported": 0, "skipped": 0})
        self.assertEqual(events.last_seq(self.conn), 4)

    def test_import_incremental_and_dedup_after_reset(self):
        p = self.write(self.LINES[:2])
        self.assertEqual(events.import_legacy(self.conn, p)["imported"], 2)
        self.write(self.LINES[2:], mode="a")
        self.assertEqual(events.import_legacy(self.conn, p)["imported"], 1)
        self.conn.execute("DELETE FROM meta WHERE key=?", (events.LEGACY_KEY,))     # se pierde el desplazamiento
        r = events.import_legacy(self.conn, p)
        self.assertEqual(r, {"imported": 0, "skipped": 3})                           # la deduplicación lo salva
        self.assertEqual(events.last_seq(self.conn), 4)                              # 3 + el task.state de la pregunta

    def test_partial_last_line_waits(self):
        p = self.write(self.LINES[:1])
        with open(p, "a") as f:
            f.write('{"event": "x", "ts": ')                                         # línea a medio escribir
        self.assertEqual(events.import_legacy(self.conn, p)["imported"], 1)
        with open(p, "a") as f:
            f.write('"2026-10-02T00:00:00+0000"}\n')
        self.assertEqual(events.import_legacy(self.conn, p)["imported"], 1)
        self.assertEqual(events.last_seq(self.conn), 2)

    def test_missing_file(self):
        self.assertEqual(events.import_legacy(self.conn, os.path.join(self.tmp.name, "nada.jsonl")),
                         {"imported": 0, "skipped": 0})

    def test_imported_events_are_not_delivered(self):
        events.subscribe(self.conn, "a", self.hook("a"))
        events.import_legacy(self.conn, self.write(self.LINES))
        events.flush()
        self.assertEqual(self.deliveries(), {})


class TestSchema(unittest.TestCase):
    def test_v1_database_drops_old_tables_and_keeps_data(self):
        """Una base v1 (con las tablas viejas de servers de prueba y puertos) migra a v2 sin perder eventos."""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "agent", "agent.db")
            os.makedirs(os.path.dirname(path))
            old = sqlite3.connect(path)
            old.executescript(db.SCHEMA + "CREATE TABLE ports (port INTEGER PRIMARY KEY); CREATE TABLE leases (id TEXT PRIMARY KEY);"
                              "INSERT INTO events(ts,machine_id,event,project) VALUES(1.0,'host-a','prueba','p1');"
                              "PRAGMA user_version=1;")
            old.close()
            conn = db.connect(path)
            try:
                tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                self.assertFalse({"leases", "ports"} & tables)
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], db.SCHEMA_VERSION)
                self.assertEqual(conn.execute("SELECT event FROM events").fetchone()[0], "prueba")
            finally:
                conn.close()
            conn = db.connect(path)                                     # reabrir una v2 no toca nada
            conn.close()

    def test_new_database_has_no_old_tables(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = db.connect(os.path.join(tmp, "agent", "agent.db"))
            try:
                tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                self.assertIn("events", tables)
                self.assertFalse({"leases", "ports"} & tables)
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], db.SCHEMA_VERSION)
            finally:
                conn.close()


if __name__ == "__main__":
    unittest.main()
