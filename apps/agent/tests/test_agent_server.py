"""Pruebas del servidor HTTP del agente (chopshop.agent.server) con un servidor REAL en loopback y puerto efímero que vive
solo durante cada test. Todo lo externo es falso: /proc, T3, tailscale y el poster de webhooks; la DB es temporal.
Sin hilos de fondo (se muestrea a mano) salvo en test_agent_service.py."""
import copy
import http.client
import json
import logging
import os
import shutil
import socket
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))          # para importar los falsos de otros tests
from chopshop import settings  # noqa: E402
from chopshop.agent import collector as collector_mod, db, events, server, t3watch  # noqa: E402
from chopshop.agent.service import AgentService  # noqa: E402
from test_agent_collector import FakeProc  # noqa: E402

TOKEN = "tok-3f9a-no-debe-salir-nunca"
WEBHOOK_URL = "https://hooks.example.test/canary-url-secreta"          # solo vive en un archivo temporal
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


class FakeTailscale:
    """Runner de `tailscale whois --json <ip>`: {ip: login}. Cuenta las llamadas."""

    def __init__(self, logins=None):
        self.logins = logins or {}
        self.calls = []

    def __call__(self, argv, timeout=3):
        self.calls.append(list(argv))
        if argv[1:3] == ["whois", "--json"] and argv[3] in self.logins:
            return 0, json.dumps({"Node": {"Name": "host-x"}, "UserProfile": {"LoginName": self.logins[argv[3]]}}), ""
        if argv[1:3] == ["ip", "-4"]:
            return 0, "100.64.0.7\n", ""
        return 1, "", "no such peer"


class FakeT3:
    """Cliente MCP falso de T3 (como `t3mcp.Client`): hilos con preguntas pendientes; registra las llamadas."""

    def __init__(self):
        self.calls = []
        self.pending = {}                       # thread_id -> [request_id]
        self.down = False

    def call(self, tool, args=None):
        args = args or {}
        self.calls.append((tool, args))
        if self.down:
            raise t3watch.T3Error("error de red con T3 (/mcp): Connection refused")
        if tool == "t3_pending_request":
            if args["action"] == "list":
                out = {"requestIds": self.pending.get(args["threadId"], [])}
            elif args["action"] == "read":
                out = {"questions": [{"id": "q1", "question": "¿Seguimos?", "options": [{"label": "Sí"}, {"label": "No"}]}]}
            else:
                out = {"ok": True}
        elif tool == "t3_project_list":
            out = {"projects": []}
        else:
            out = {"ok": True}
        return out


class ServerBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-srv-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.clock = Clock()
        self.ts, self.t3calls, self.posts = FakeTailscale(), FakeT3(), []
        self.token_file = os.path.join(self.tmp, "token")
        with open(self.token_file, "w") as f:
            f.write(TOKEN + "\n")
        os.chmod(self.token_file, 0o600)
        self.wfile = os.path.join(self.tmp, "hook.url")
        with open(self.wfile, "w") as f:
            f.write(WEBHOOK_URL + "\n")
        os.chmod(self.wfile, 0o600)
        os.makedirs(os.path.join(self.tmp, "projects", "proyecto-demo"))
        os.makedirs(os.path.join(self.tmp, "worktrees", "proyecto-demo", "wt-uno"))
        self.proc = FakeProc(os.path.join(self.tmp, "proc"))
        self.logs, self.responses = [], []
        handler = logging.Handler()
        handler.emit = lambda rec: self.logs.append(rec.getMessage())
        lg = logging.getLogger("chopshop.agent")
        lg.addHandler(handler)
        self.old_level = lg.level
        lg.setLevel(logging.DEBUG)
        self.addCleanup(lg.removeHandler, handler)
        self.addCleanup(lg.setLevel, self.old_level)
        self.svc = None

    def start(self, orchestrator=None, background=False, svc_kw=None, **over):
        cfg = copy.deepcopy(settings.DEFAULTS["agent"])
        cfg.update(machine_id="host-a", db_path=os.path.join(self.tmp, "agent", "agent.db"), token_file=self.token_file,
                   projects_root=os.path.join(self.tmp, "projects"), worktrees_root=os.path.join(self.tmp, "worktrees"),
                   bind="127.0.0.1", port=0, owner_login="yo@github", allowed_logins=["lector@github"], import_legacy=False)
        cfg["projects"] = {"proyecto-demo": {}}
        cfg["t3"] = {"origin": "http://127.0.0.1:9", "t3_bin": "/nonexistente/t3"}
        cfg.update(over)
        conn = db.connect(cfg["db_path"])
        self.addCleanup(conn.close)
        coll = collector_mod.Collector(cfg, conn, proc_root=self.proc.root, clock=self.clock, clk_tck=100, page_size=4096)
        self.svc = AgentService(cfg, conn=conn, collector=coll, t3=t3watch.T3(cfg, client=self.t3calls), runner=self.ts,
                                poster=lambda url, data, timeout: self.posts.append((url, data)) or 200,
                                orchestrator_fn=orchestrator or (lambda: None), clock=self.clock, **(svc_kw or {}))
        self.svc.start(background=background)
        self.addCleanup(self.svc.stop)
        self.addCleanup(events.flush, 2)
        self.host, self.port = self.svc.address
        self.conn, self.cfg = conn, cfg
        return self.svc

    def req(self, method, path, body=None, headers=None, raw=None):
        c = http.client.HTTPConnection(self.host, self.port, timeout=5)
        try:
            data = raw if raw is not None else (json.dumps(body).encode("utf-8") if body is not None else None)
            hdrs = dict(headers or {})
            if data is not None:
                hdrs.setdefault("Content-Type", "application/json")
            c.request(method, path, body=data, headers=hdrs)
            r = c.getresponse()
            payload = r.read()
            self.responses.append(payload.decode("utf-8", "replace"))
            return r.status, (json.loads(payload.decode("utf-8")) if payload else None), r
        finally:
            c.close()

    def get(self, path, **kw):
        return self.req("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.req("POST", path, body if body is not None else {}, **kw)

    def sample(self, busy=100, idle=900):
        self.proc.set_machine(busy=busy, idle=idle, cpus=4)
        self.clock.t += 10
        return self.svc.collector.sample_once()

    def add_thread(self, tid, project="proyecto-demo", status="running", settled=0, pending=None, title="Título añejo ñ"):
        with db.tx():
            self.conn.execute(
                "INSERT OR REPLACE INTO t3_threads(thread_id,project,t3_project_id,title,status,settled,worktree,branch,pending,"
                "first_seen,last_seen,updated,extra) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (tid, project, "p-1", title, status, settled, "/tmp/wt", "rama", db.jdump(pending or []), 1.0, 2.0, 3.0,
                 db.jdump({"link": "t3://x", "pull_requests": ["https://example.test/pr/1"]})))


class TestRoutes(ServerBase):
    def setUp(self):
        super().setUp()
        self.start()

    def test_health(self):
        st, body, r = self.get("/health")
        self.assertEqual(st, 200)
        self.assertEqual(r.getheader("Content-Type"), "application/json; charset=utf-8")
        self.assertEqual(sorted(body), ["api_version", "machine_id", "ok", "ts", "uptime", "version", "whoami"])
        self.assertEqual((body["ok"], body["api_version"], body["machine_id"]), (True, 1, "host-a"))
        self.assertEqual(body["whoami"], {"login": None, "via": "local", "write": True})

    def test_snapshot_has_contract_shape(self):
        self.sample()
        self.add_thread("t-1", pending=[{"request_id": "r-1", "questions": [{"id": "q1"}]}], status="waiting")
        self.add_thread("t-2", status="running")
        self.add_thread("t-3", status="completed", settled=1, project="otro")
        self.svc.emit("prueba", "proyecto-demo", {"i": 1})
        st, snap, _ = self.get("/snapshot")
        self.assertEqual(st, 200)
        self.assertEqual(sorted(snap), sorted([
            "api_version", "machine_id", "ts", "generated", "machine", "apps", "projects", "threads", "pending_questions",
            "events", "subscriptions", "orchestrator", "agent"]))
        self.assertEqual((snap["api_version"], snap["machine_id"]), (1, "host-a"))
        self.assertTrue({"cpus", "load", "cpu_pct", "ram_total_mb", "ram_avail_mb", "ram_pct", "swap_used_mb", "disk_used_gb",
                         "disk_total_gb", "disk_pct", "os", "uptime"} <= set(snap["machine"]))
        self.assertEqual(sorted(snap["agent"]), ["last_poll_age", "last_sample_age", "t3_ok", "uptime", "version"])
        self.assertIsNone(snap["orchestrator"])
        self.assertEqual(snap["agent"]["last_sample_age"], 0.0)
        proj = {p["name"]: p for p in snap["projects"]}
        self.assertTrue({"name", "cpu_pct", "rss_mb", "procs", "threads_running", "threads_pending"} <= set(proj["proyecto-demo"]))
        self.assertFalse({"leases_active", "leases_queued"} & set(proj["proyecto-demo"]))     # contrato sin leases
        self.assertEqual((proj["proyecto-demo"]["threads_running"], proj["proyecto-demo"]["threads_pending"]), (1, 1))
        self.assertEqual(snap["pending_questions"], [{"thread_id": "t-1", "project": "proyecto-demo", "request_id": "r-1",
                                                      "questions": [{"id": "q1"}]}])
        self.assertEqual(sorted(snap["threads"][0]), ["branch", "link", "pending", "project", "pull_requests", "settled",
                                                      "status", "thread_id", "title", "updated", "worktree"])
        self.assertEqual(snap["events"][0]["event"], "prueba")                             # más nuevo primero
        # el contrato del doc nombra cada clave de primer nivel
        with open(os.path.join(ROOT, "docs", "agent-api.md"), encoding="utf-8") as f:
            doc = f.read()
        for k in snap:
            self.assertIn('"%s"' % k, doc, k)

    def test_snapshot_orchestrator_and_failure(self):
        self.svc.app.orchestrator_fn = lambda: {"batches": [], "graphs": []}
        self.assertEqual(self.get("/snapshot")[1]["orchestrator"], {"batches": [], "graphs": []})
        self.svc.app._orch = (0.0, None)
        self.svc.app.orchestrator_fn = lambda: 1 / 0
        self.assertIsNone(self.get("/snapshot")[1]["orchestrator"])

    def test_snapshot_without_samples_or_t3_state(self):
        st, snap, _ = self.get("/snapshot")
        self.assertEqual(st, 200)
        self.assertEqual(snap["machine"], {})
        self.assertIsNone(snap["agent"]["last_sample_age"])
        self.assertIsNone(snap["agent"]["t3_ok"])

    def test_metrics(self):
        self.sample()
        self.proc.add(10, "node", ticks=0)
        self.sample(busy=600, idle=1400)
        to = self.clock.t
        st, body, _ = self.get("/metrics?from=%s&to=%s&group=machine" % (to - 100, to))
        self.assertEqual(st, 200)
        self.assertEqual((body["group"], body["res"]), ("machine", "raw"))
        self.assertEqual(body["series"][0]["name"], "machine")
        self.assertEqual(len(body["series"][0]["points"]), 2)
        st, body, _ = self.get("/metrics?from=%s&to=%s&group=app" % (to - 100, to))
        self.assertIn("node", [s["name"] for s in body["series"]])
        self.assertEqual(self.get("/metrics?group=nope")[0], 400)
        self.assertEqual(self.get("/metrics?from=abc")[0], 400)
        self.assertEqual(self.get("/metrics?from=5&to=1")[0], 400)

    def test_events_cursor(self):
        base = self.svc.emit("prueba", "proyecto-demo", {"i": 0})            # antes está agent_started (seq 1)
        for i in range(1, 5):
            self.svc.emit("prueba", "proyecto-demo", {"i": i})
        st, body, _ = self.get("/events?after=%d&limit=3" % (base - 1))
        self.assertEqual([e["body"]["i"] for e in body["events"]], [0, 1, 2])
        head = base + 4
        self.assertEqual((body["last_seq"], body["head_seq"]), (body["events"][-1]["seq"], head))
        body = self.get("/events?after=%d" % body["last_seq"])[1]
        self.assertEqual([e["body"]["i"] for e in body["events"]], [3, 4])
        self.assertEqual(self.get("/events?after=%d" % head)[1], {"events": [], "last_seq": head, "head_seq": head})
        self.assertEqual(self.get("/events?after=x")[0], 400)
        self.assertEqual(set(body["events"][0]), {"seq", "ts", "machine_id", "event", "project", "body"})

    def test_threads_utf8(self):
        self.add_thread("t-1")
        self.add_thread("t-2", project="otro", status="completed", settled=1)
        st, body, r = self.get("/threads")
        self.assertEqual({t["thread_id"] for t in body["threads"]}, {"t-1", "t-2"})
        self.assertIn("Título añejo ñ", self.responses[-1])                  # UTF-8 sin escapar
        self.assertTrue(next(t for t in body["threads"] if t["thread_id"] == "t-2")["settled"])
        self.assertEqual([t["thread_id"] for t in self.get("/threads?project=otro")[1]["threads"]], ["t-2"])

    def test_removed_routes_are_404(self):
        # servers de prueba, puertos y barrido de huérfanos son cosa de T3: la API ya no los expone
        for method, path in (("GET", "/leases"), ("GET", "/ports"), ("POST", "/leases/request"), ("POST", "/leases/release"),
                             ("POST", "/leases/touch"), ("POST", "/sweep")):
            self.assertEqual(self.req(method, path, body={} if method == "POST" else None)[0], 404, path)

    def test_settle_and_answer(self):
        st, body, _ = self.post("/settle", {"thread_id": "t-1"})
        self.assertEqual((st, body), (200, {"ok": True, "thread_id": "t-1"}))
        self.assertIn(("t3_thread_organize", {"threadId": "t-1", "action": "settle"}), self.t3calls.calls)
        self.assertEqual(self.post("/settle", {})[0], 400)
        # answer: sin preguntas -> 400 (AnswerError); con una pendiente -> responde
        st, body, _ = self.post("/answer", {"thread_id": "t-1", "choice": "1"})
        self.assertEqual(st, 400)
        self.assertIn("no tiene preguntas pendientes", body["error"])
        self.t3calls.pending["t-1"] = ["req-0001"]
        st, body, _ = self.post("/answer", {"thread_id": "t-1", "choice": "1"})
        self.assertEqual((st, body["ok"], body["request_id"], body["answers"]), (200, True, "req-0001", {"q1": "Sí"}))
        self.assertEqual(self.post("/answer", {"thread_id": "t-1", "choice": ""})[0], 400)
        self.assertEqual(self.post("/answer", {"thread_id": "t-1"})[0], 400)
        self.assertEqual(self.post("/answer", {"choice": "1"})[0], 400)
        for tool, args in self.t3calls.calls:                       # jamás se archiva
            self.assertNotEqual(args.get("action"), "archive")

    def test_t3_down_is_502_and_disabled_is_503(self):
        self.t3calls.down = True
        st, body, _ = self.post("/settle", {"thread_id": "t-1"})
        self.assertEqual(st, 502)
        self.assertTrue(body["error"].startswith("T3:"))
        self.svc.app.t3_enabled = False
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"})[0], 503)

    def test_subscriptions_never_leak_the_url(self):
        st, body, _ = self.post("/subscriptions", {"name": "bot", "webhook_file": self.wfile, "project": "proyecto-demo",
                                                   "events": ["pending_question"]})
        self.assertEqual((st, body["name"]), (200, "bot"))
        self.assertEqual(body["subscription"]["events"], ["pending_question"])
        self.assertEqual(self.post("/subscriptions", {"name": "x", "webhook_file": "https://hooks.example.test/a"})[0], 400)
        self.assertEqual(self.post("/subscriptions", {"name": "x", "webhook_file": "/no/existe"})[0], 400)
        self.assertEqual(self.post("/subscriptions", {"name": "mal nombre", "webhook_file": self.wfile})[0], 400)
        self.assertEqual(self.post("/subscriptions", {"webhook_file": self.wfile})[0], 400)
        self.assertEqual(list(self.get("/subscriptions")[1]["subscriptions"]), ["bot"])
        self.assertEqual(self.get("/snapshot")[1]["subscriptions"], {"bot": {"project": "proyecto-demo", "events": ["pending_question"]}})
        self.svc.emit("pending_question", "proyecto-demo", {"thread_id": "t-1"})   # dispara el webhook
        events.flush(5)
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.posts[0][0], WEBHOOK_URL)                       # la URL salió del archivo, no de la API
        self.assertEqual(self.get("/events")[1]["events"][-1]["event"], "pending_question")
        st, body, _ = self.req("DELETE", "/subscriptions/bot")
        self.assertEqual((st, body), (200, {"ok": True, "name": "bot"}))
        self.assertEqual(self.req("DELETE", "/subscriptions/bot")[0], 404)
        everything = "\n".join(self.responses) + "\n".join(self.logs)
        self.assertNotIn("canary-url-secreta", everything)
        self.assertNotIn(self.wfile, everything)
        self.assertNotIn(TOKEN, everything)

    def test_routing_errors_are_json(self):
        for method, path, code in (("GET", "/nada", 404), ("DELETE", "/health", 405), ("GET", "/answer", 405),
                                   ("POST", "/health", 405), ("PUT", "/health", 405), ("GET", "/subscriptions/bot", 405)):
            st, body, r = self.req(method, path)
            self.assertEqual(st, code, (method, path))
            self.assertIn("error", body)
            self.assertEqual(r.getheader("Content-Type"), "application/json; charset=utf-8")
        self.assertEqual(self.get("/health/")[0], 200)                         # barra final tolerada

    def test_body_limits_and_parsing(self):
        big = b'{"thread_id":"' + b"x" * (server.MAX_BODY + 10) + b'"}'
        st, body, _ = self.req("POST", "/settle", raw=big)
        self.assertEqual(st, 413)
        self.assertEqual(self.req("POST", "/settle", raw=b"{no json")[1]["error"], "el cuerpo debe ser JSON UTF-8")
        self.assertEqual(self.req("POST", "/settle", raw=b"[1,2]")[1]["error"], "el cuerpo debe ser un objeto JSON")
        self.assertEqual(self.req("POST", "/settle", raw=b"\xff\xfe")[0], 400)
        self.assertEqual(self.req("POST", "/settle", raw=b"")[1]["error"], "thread_id es obligatorio")   # sin cuerpo = {}
        # chunked: no se acepta (exige Content-Length)
        s = socket.create_connection((self.host, self.port), timeout=5)
        s.sendall(b"POST /settle HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        data = s.recv(4096)
        s.close()
        self.assertTrue(data.startswith(b"HTTP/1.0 411") or data.startswith(b"HTTP/1.1 411"), data[:40])

    def test_slow_client_is_cut_by_timeout(self):
        self.assertGreaterEqual(server.Handler.timeout, 1)
        self.assertLessEqual(server.Handler.timeout, 60)

    def test_internal_errors_do_not_leak(self):
        self.svc.collector.latest = lambda: 1 / 0
        st, body, _ = self.get("/snapshot")
        self.assertEqual((st, body), (500, {"error": "error interno"}))

    def test_logs_have_no_token_or_query(self):
        self.get("/events?after=0", headers={"Authorization": "Bearer " + TOKEN})
        self.post("/settle", {"thread_id": "t-1"}, headers={"Authorization": "Bearer " + TOKEN})
        end = time.monotonic() + 3                                 # el acceso se registra tras enviar la respuesta
        while not any("POST /settle -> 200" in l for l in self.logs) and time.monotonic() < end:
            time.sleep(0.02)
        text = "\n".join(self.logs)
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("after=0", text)
        self.assertIn("POST /settle -> 200", text)


class TestAuth(ServerBase):
    """Con trust_local=False el cliente de loopback pasa por la ruta de identidad (whois falso por 127.0.0.1)."""

    def bearer(self, tok=TOKEN):
        return {"Authorization": "Bearer " + tok}

    def test_tailscale_plus_token(self):
        self.start(auth="tailscale+token", trust_local=False)
        # sin identidad -> 403 en TODO, incluidas rutas que no existen (no se puede sondear)
        for method, path in (("GET", "/health"), ("GET", "/snapshot"), ("GET", "/nada"), ("POST", "/settle"), ("DELETE", "/health")):
            st, body, _ = self.req(method, path, headers=self.bearer())
            self.assertEqual((st, body["error"]), (403, "sin identidad válida"), (method, path))
        # lector: GET sí, POST no (ni con bearer)
        self.ts.logins["127.0.0.1"] = "Lector@github"
        self.svc.auth._whois.clear()                       # el fallo anterior queda en cache unos segundos
        st, body, _ = self.get("/health")
        self.assertEqual((st, body["whoami"]), (200, {"login": "lector@github", "via": "tailscale", "write": False}))
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"}, headers=self.bearer())[0], 403)
        # propietario: GET sí; POST exige además el bearer
        self.ts.logins["127.0.0.1"] = "yo@github"
        self.svc.auth._whois.clear()
        self.assertEqual(self.get("/health")[1]["whoami"], {"login": "yo@github", "via": "tailscale", "write": False})
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"})[0], 403)
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"}, headers=self.bearer("otro"))[0], 403)
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"}, headers={"Authorization": "Basic " + TOKEN})[0], 403)
        st, body, _ = self.post("/settle", {"thread_id": "t-1"}, headers=self.bearer())
        self.assertEqual((st, body["ok"]), (200, True))
        self.assertEqual(self.get("/health", headers=self.bearer())[1]["whoami"]["write"], True)
        # identidad desconocida
        self.ts.logins["127.0.0.1"] = "intruso@github"
        self.svc.auth._whois.clear()
        self.assertEqual(self.get("/health")[0], 403)

    def test_whois_cache_60s(self):
        self.start(auth="tailscale+token", trust_local=False)
        clock = Clock(100.0)
        self.svc.auth.clock = clock
        self.ts.logins["127.0.0.1"] = "yo@github"
        for _ in range(3):
            self.assertEqual(self.get("/health")[0], 200)
        self.assertEqual(len(self.ts.calls), 1)
        clock.t += 59
        self.get("/health")
        self.assertEqual(len(self.ts.calls), 1)
        clock.t += 2
        self.get("/health")
        self.assertEqual(len(self.ts.calls), 2)
        # un whois fallido se recuerda poco (no se martilla al CLI) y se reintenta enseguida
        del self.ts.logins["127.0.0.1"]
        clock.t += 61
        self.assertEqual(self.get("/health")[0], 403)
        n = len(self.ts.calls)
        self.get("/health")
        self.assertEqual(len(self.ts.calls), n)
        clock.t += server.WHOIS_FAIL_TTL + 1
        self.ts.logins["127.0.0.1"] = "yo@github"
        self.assertEqual(self.get("/health")[0], 200)

    def test_token_mode(self):
        self.start(auth="token", trust_local=False)
        self.assertEqual(self.get("/health")[0], 403)
        self.assertEqual(self.get("/health", headers=self.bearer("mal"))[0], 403)
        st, body, _ = self.get("/health", headers=self.bearer())
        self.assertEqual((st, body["whoami"]), (200, {"login": None, "via": "token", "write": True}))
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"}, headers=self.bearer())[0], 200)
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"})[0], 403)
        self.assertEqual(self.ts.calls, [])                                    # en modo token no se consulta a Tailscale
        os.unlink(self.token_file)                                             # sin archivo de token nadie entra
        self.assertEqual(self.get("/health", headers=self.bearer())[0], 403)

    def test_none_local_mode(self):
        self.start(auth="none-local", trust_local=False)
        self.assertEqual(self.get("/health", headers=self.bearer())[0], 403)
        self.assertEqual(self.ts.calls, [])

    def test_local_origin_trusted_by_default(self):
        self.start(auth="none-local")
        self.assertEqual(self.get("/health")[1]["whoami"]["via"], "local")
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"})[0], 200)
        self.assertEqual(self.ts.calls, [])

    def test_token_file_changes_are_picked_up_and_compare_is_constant_time(self):
        self.start(auth="token", trust_local=False)
        self.assertEqual(self.get("/health", headers=self.bearer())[0], 200)
        with open(self.token_file, "w") as f:
            f.write("nuevo-token-rotado-12345678\n")
        os.utime(self.token_file, (time.time() + 5, time.time() + 5))
        self.assertEqual(self.get("/health", headers=self.bearer())[0], 403)
        self.assertEqual(self.get("/health", headers=self.bearer("nuevo-token-rotado-12345678"))[0], 200)
        import inspect
        self.assertIn("hmac.compare_digest", inspect.getsource(server.Authenticator.bearer_ok))

    def test_authorize_units(self):
        cfg = dict(settings.DEFAULTS["agent"], owner_login="yo@github", allowed_logins=["l@github"], token_file=self.token_file)
        ts = FakeTailscale({"100.64.0.5": "yo@github", "100.64.0.6": "l@github", "100.64.0.7": "otro@github"})
        a = server.Authenticator(cfg, runner=ts)
        local = {"100.64.0.9"}
        self.assertEqual(a.authorize("127.0.0.1", local, True, None).via, "local")
        self.assertEqual(a.authorize("::1", local, True, None).via, "local")
        self.assertEqual(a.authorize("100.64.0.9", local, True, None).via, "local")         # la propia IP del agente
        self.assertEqual(a.authorize("::ffff:127.0.0.1", local, False, None).via, "local")
        self.assertEqual(a.authorize("100.64.0.5", local, False, None).login, "yo@github")
        self.assertEqual(a.authorize("100.64.0.5", local, True, "Bearer " + TOKEN).write, True)
        self.assertEqual(a.authorize("100.64.0.5", local, True, "bearer " + TOKEN).write, True)   # esquema sin distinguir mayúsculas
        for ip, write, hdr in (("100.64.0.5", True, None), ("100.64.0.6", True, "Bearer " + TOKEN), ("100.64.0.7", False, None),
                               ("100.64.0.8", False, None), ("no-es-ip", False, None), ("100.64.0.5", True, "Bearer ")):
            with self.assertRaises(server.ApiError) as cm:
                a.authorize(ip, local, write, hdr)
            self.assertEqual(cm.exception.status, 403, (ip, write, hdr))
        with self.assertRaises(ValueError):
            server.Authenticator(dict(cfg, auth="nada"))
        # owner vacío: el login vacío jamás coincide
        a2 = server.Authenticator(dict(cfg, owner_login="", allowed_logins=[]), runner=FakeTailscale({"100.64.0.5": ""}))
        with self.assertRaises(server.ApiError):
            a2.authorize("100.64.0.5", local, False, None)

    def test_whois_parsing_robust(self):
        cfg = dict(settings.DEFAULTS["agent"], owner_login="yo@github", token_file=self.token_file)
        for out in ("no json", "[]", '{"UserProfile": null}', '{"UserProfile": {"LoginName": 7}}', "{}"):
            a = server.Authenticator(cfg, runner=lambda argv, timeout=3, o=out: (0, o, ""))
            with self.assertRaises(server.ApiError):
                a.authorize("100.64.0.5", set(), False, None)
        a = server.Authenticator(cfg, runner=lambda argv, timeout=3: (_ for _ in ()).throw(RuntimeError("boom")))
        with self.assertRaises(server.ApiError):
            a.authorize("100.64.0.5", set(), False, None)


class TestCleanStop(ServerBase):
    def test_server_stops_and_releases_port(self):
        self.start()
        self.assertEqual(self.get("/health")[0], 200)
        threads = list(self.svc.threads)
        self.assertTrue(threads)
        self.svc.stop()
        for t in threads:
            self.assertFalse(t.is_alive(), t.name)
        with self.assertRaises(OSError):
            socket.create_connection((self.host, self.port), timeout=1)
        self.svc.stop()                                              # idempotente


class TestCpuConvention(ServerBase):
    """`machine.cpu_pct` es 0-100 de TODA la máquina; apps/proyectos usan 100 = un núcleo."""

    def test_machine_vs_core_percent(self):
        self.start()
        self.proc.add(10, "node", ticks=0, cwd=os.path.join(self.tmp, "projects", "proyecto-demo"))
        self.sample(busy=100, idle=900)
        self.proc.set_ticks(10, 1000)                          # 1000 ticks / (100 tck/s * 10 s) = 1 núcleo entero
        snap = self.sample(busy=600, idle=1400)               # 500 de 1000 jiffies ocupados = 50 % de la máquina (4 CPUs)
        self.assertEqual(snap["machine"]["cpu_pct"], 50.0)
        self.assertEqual(snap["machine"]["cpus"], 4)
        self.assertEqual(next(a for a in snap["apps"] if a["name"] == "node")["cpu_pct"], 100.0)
        self.assertEqual(snap["projects"][0]["cpu_pct"], 100.0)
        api = self.get("/snapshot")[1]
        self.assertEqual(api["machine"]["cpu_pct"], 50.0)
        self.assertEqual(next(p for p in api["projects"] if p["name"] == "proyecto-demo")["cpu_pct"], 100.0)



if __name__ == "__main__":
    unittest.main()
