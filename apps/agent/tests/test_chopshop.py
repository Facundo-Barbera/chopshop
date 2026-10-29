import http.server
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import engine, events, home, inbox, miniyaml, profile, settings, state, t3  # noqa: E402

TEST_CONFIG = """[general]
default_host = "host-a"
overflow_host = "host-b"

[hosts.host-a]
cap = 2
purpose = "dev"
t3_bin = "t3"

[hosts.host-b]
origin = "http://100.64.0.10:3773"
cap = 4
purpose = "tests-only"
"""


class Env(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["CHOPSHOP_HOME"] = self.tmp
        os.environ["CHOPSHOP_CONFIG"] = os.path.join(self.tmp, "config.toml")
        with open(os.environ["CHOPSHOP_CONFIG"], "w") as f:
            f.write(TEST_CONFIG)
        os.makedirs(home.profiles_dir())
        self.addCleanup(t3.set_client_factory, None)

    def use_t3(self, fake):
        """Inyecta `fake(host_cfg, host, tool, args, timeout)` como cliente MCP de cada host."""
        use_fake(fake)

    def prof(self, name, text):
        with open(os.path.join(home.profiles_dir(), name + ".yaml"), "w") as f:
            f.write(text)


class TestYaml(unittest.TestCase):
    def test_basic(self):
        d = miniyaml.loads("a: 1\nb:\n  - x\n  - y: 2\n    z: [1, 'q']\nc: |\n  l1\n  l2\nd: hola # c\n")
        self.assertEqual(d, {"a": 1, "b": ["x", {"y": 2, "z": [1, "q"]}], "c": "l1\nl2", "d": "hola"})

    def test_error(self):
        with self.assertRaises(miniyaml.YamlError):
            miniyaml.loads("a: 1\n  b: 2\n")


class TestRouting(Env):
    def test_route(self):
        self.prof("p", "project: p\nremote_repos:\n  host-b: ~/projects/p\n")
        p = profile.load("p")
        self.assertEqual(engine.route(p, 2)[:2], ("host-a", 2))        # cabe en el host principal
        h, cap, notes = engine.route(p, 3)                                     # lote grande -> host de desborde
        self.assertEqual(h, "host-b"); self.assertTrue(notes)
        self.assertEqual(engine.route(p, 5, max_parallel=9)[1], 4)             # recorta al tope del host de desborde
        self.assertEqual(engine.route(p, 5, cli_host="host-a")[:2], ("host-a", 2))

    def test_no_remote_stays(self):
        self.prof("q", "project: q\nrepo: /tmp/q\n")
        self.assertEqual(engine.route(profile.load("q"), 5)[0], "host-a")

    def test_skip(self):
        self.prof("p", "project: p\nready:\n  labels_all: [ready]\n  skip_if_assigned: [bob]\n  skip_if_labeled: [needs-approval]\n")
        p = profile.load("p")
        self.assertIsNone(engine.skip_reason(p, {"labels": ["ready"]}))
        self.assertIn("falta", engine.skip_reason(p, {"labels": []}))
        self.assertIn("asignada", engine.skip_reason(p, {"labels": ["ready"], "assignee": "bob"}))
        self.assertIn("tiene label", engine.skip_reason(p, {"labels": ["ready", "needs-approval"]}))
        self.assertIsNone(engine.skip_reason(p, {}))


class Hook(http.server.BaseHTTPRequestHandler):
    got = []

    def do_POST(self):
        Hook.got.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(200); self.end_headers()

    def log_message(self, *a):
        pass


class _FakeClient:
    def __init__(self, fake, host_cfg, host, timeout):
        self.fake, self.host_cfg, self.host, self.timeout = fake, host_cfg, host, timeout

    def call(self, tool, args=None):
        return self.fake(self.host_cfg, self.host, tool, args, self.timeout)


def use_fake(fake):
    t3.set_client_factory(lambda hc, host, timeout: _FakeClient(fake, hc, host, timeout))


class FakeT3:
    """Transporte falso: un hilo que primero 'waiting' con una pregunta y luego completed."""
    def __init__(self):
        self.calls = []; self.n = 0; self.status = {}; self.answered = False

    def __call__(self, hc, host, tool, args=None, timeout=0):
        args = args or {}
        self.calls.append((tool, args))
        if tool == "t3_thread_launch":
            self.n += 1; tid = "mcp:%d" % self.n; self.status[tid] = "waiting"
            return {"threadId": tid, "link": "L" + tid, "projectId": "P", "runId": "r", "status": "running"}
        if tool == "t3_thread_read":
            s = self.status[args["threadId"]]
            return {"thread": {"status": s, "pendingRequestCount": 1 if s == "waiting" else 0, "settled": False, "pullRequests": []},
                    "items": [{"type": "assistant_message", "text": "listo"}]}
        if tool == "t3_pending_request":
            if args["action"] == "list":
                return {"requestIds": ["req-1"] if self.status[args["threadId"]] == "waiting" else []}
            if args["action"] == "read":
                return {"requestId": "req-1", "questions": [{"id": "q1", "question": "¿A o B?", "options": [{"label": "A"}, {"label": "B"}]}]}
            if args["action"] == "respond":
                self.status[args["threadId"]] = "completed"; self.answered = args["answers"]; return {}
        if tool == "t3_thread_organize":
            return {}
        raise AssertionError(tool)


class TestFlow(Env):
    def test_flow(self):
        Hook.got.clear()
        srv = http.server.HTTPServer(("127.0.0.1", 0), Hook)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        hookfile = os.path.join(self.tmp, "h.url")
        with open(hookfile, "w") as f:
            f.write("http://127.0.0.1:%d/secret-path" % srv.server_port)
        os.chmod(hookfile, 0o600)
        self.prof("s", "project: s\nscratch: true\nmodel: claudeAgent/claude-haiku-5-5\ncannot_run: [deploy]\n")
        fake = FakeT3(); self.use_t3(fake)
        prof = profile.load("s")
        bid = engine.create_batch(prof, ["uno", "dos", "tres"], "host-a", 2, [])
        buf = io.StringIO()
        with redirect_stdout(buf):
            engine.tick(bid, [hookfile], log=print)
        st = state.read()
        self.assertEqual([t["status"] for t in st["batches"][bid]["tasks"]], ["launched", "launched", "queued"])  # tope 2
        launches = [a for t, a in fake.calls if t == "t3_thread_launch"]
        self.assertTrue(launches[0]["scratch"]); self.assertEqual(launches[0]["modelSelection"]["model"], "claude-haiku-5-5")
        self.assertIn("NO ejecutes: deploy", launches[0]["message"])
        self.assertEqual(len(Hook.got), 0)                                         # el refresco ocurre en la pasada siguiente
        with redirect_stdout(buf):
            engine.tick(bid, [hookfile], log=print)
        self.assertEqual(len(Hook.got), 2)                                         # un pending_question por hilo
        self.assertEqual(Hook.got[0]["event"], "pending_question")
        self.assertNotIn("secret-path", buf.getvalue())                           # la URL nunca se imprime
        with open(home.events_log()) as ef:
            self.assertNotIn("secret-path", ef.read())
        with redirect_stdout(io.StringIO()):
            engine.tick(bid, [hookfile], log=print)
        self.assertEqual(len(Hook.got), 2)                                         # sin duplicados
        engine.answer("t-0001-1", "B")
        self.assertEqual(fake.answered, {"q1": "B"})
        ans = state.read()["batches"][bid]["tasks"][0]["answered"]          # historial local para la UI
        self.assertEqual((ans[0]["summary"], ans[0]["choice"], ans[0]["options"]), ("¿A o B?", "B", ["A", "B"]))
        snap_t = [t for b in engine.snapshot()["batches"] for t in b["tasks"] if t["id"] == "t-0001-1"][0]
        self.assertEqual(snap_t["answered"][0]["choice"], "B")
        with redirect_stdout(io.StringIO()):
            engine.tick(bid, [hookfile], log=print)                                # termina t1, lanza t3
        self.assertEqual(state.read()["batches"][bid]["tasks"][2]["status"], "launched")
        self.assertEqual(engine.settle(bid, log=lambda *_: None), 3)
        self.assertFalse(any(a.get("action") == "archive" for t, a in fake.calls))


class FakeApproval(FakeT3):
    """Hilo que espera un permiso (pendingRequestCount=1, sin preguntas listables)."""
    def __call__(self, hc, host, tool, args=None, timeout=0):
        args = args or {}
        if tool == "t3_thread_launch":
            self.calls.append((tool, args)); self.n += 1
            return {"threadId": "mcp:a%d" % self.n, "link": "L", "projectId": "P", "runId": "r", "status": "running"}
        if tool == "t3_thread_read":
            self.calls.append((tool, args))
            return {"thread": {"status": "running", "pendingRequestCount": 1, "settled": False, "pullRequests": []}, "items": []}
        if tool == "t3_pending_request" and args["action"] == "list":
            return {"requestIds": []}
        if tool == "t3_thread_interrupt":
            self.calls.append((tool, args)); return {"status": "interrupt_requested"}
        return super().__call__(hc, host, tool, args, timeout)


class TestApprovalAndSnapshot(Env):
    def test_approval_event_snapshot_stop(self):
        Hook.got.clear()
        srv = http.server.HTTPServer(("127.0.0.1", 0), Hook)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        hookfile = os.path.join(self.tmp, "h.url")
        with open(hookfile, "w") as f:
            f.write("http://127.0.0.1:%d/x" % srv.server_port)
        self.prof("s", "project: s\nscratch: true\n")
        fake = FakeApproval(); self.use_t3(fake)
        bid = engine.create_batch(profile.load("s"), ["uno"], "host-a", 2, [])
        with redirect_stdout(io.StringIO()):
            for _ in range(3):
                engine.tick(bid, [hookfile], log=print)
        self.assertEqual([e["event"] for e in Hook.got], ["pending_approval"])    # una sola vez
        snap = engine.snapshot()
        t = snap["batches"][0]["tasks"][0]
        self.assertEqual(t["pending"]["approvals"], 1)
        self.assertEqual(snap["events"][0]["event"], "pending_approval")
        self.assertNotIn("/x", json.dumps(snap))
        with redirect_stdout(io.StringIO()):
            self.assertEqual(engine.stop(bid), 1)
        self.assertTrue(any(t == "t3_thread_interrupt" for t, a in fake.calls))
        self.assertFalse(any(a.get("action") == "archive" for t, a in fake.calls))


class TestWebhookFailure(Env):
    def test_no_leak(self):
        f = os.path.join(self.tmp, "u")
        with open(f, "w") as fh:
            fh.write("http://127.0.0.1:1/token-xyz")
        ok, why = events.post(f, {"a": 1}, timeout=2)
        self.assertFalse(ok); self.assertNotIn("token-xyz", why)


class TestInbox(Env):
    def test_queue_and_drain(self):
        i1 = inbox.enqueue_answer("t-0001-1", "Verde", "req1")
        self.assertEqual(len(inbox.status()["pending"]), 1)
        seen = []

        def fake(task, choice, request, by=None):
            seen.append((task, choice, request))
            if choice == "boom":
                raise RuntimeError("falla simulada")
            return {"q": choice}
        import time
        time.sleep(0.01)
        inbox.enqueue_answer("t-0001-2", "boom")
        self.assertEqual(inbox.drain(fake, log=lambda *a: None), 2)
        self.assertEqual(seen[0], ("t-0001-1", "Verde", "req1"))
        st = inbox.status()
        self.assertEqual(st["pending"], [])
        self.assertEqual([r["ok"] for r in st["results"]], [True, False])
        self.assertIn("falla simulada", st["results"][1]["error"])
        self.assertIsNone(st["watcher"])
        inbox.heartbeat(20)
        self.assertTrue(inbox.status()["watcher"]["alive"])


class TestMetrics(Env):
    def test_read_local_and_remote(self):
        from chopshop import metrics
        m = metrics.read()
        self.assertEqual(m["hosts"]["host-a"]["transport"], "local")
        self.assertTrue(m["hosts"]["host-a"]["ok"])
        self.assertIn("cpu_pct", m["hosts"]["host-a"])
        rem = m["hosts"]["host-b"]                 # con origin: no se recolecta desde aquí, no inventa datos
        self.assertEqual(rem["transport"], "remote")
        self.assertFalse(rem["ok"])
        self.assertEqual(rem["reason"], metrics.REMOTE_REASON)
        self.assertNotIn("cpu_pct", rem)
        self.assertFalse(hasattr(metrics, "collect_remote"))
        self.assertFalse(hasattr(metrics, "parse_fleet_status"))

    def test_snapshot_transport(self):
        hosts = engine.snapshot()["hosts"]
        self.assertEqual((hosts["host-a"]["transport"], hosts["host-b"]["transport"]), ("local", "remote"))


if __name__ == "__main__":
    unittest.main()
