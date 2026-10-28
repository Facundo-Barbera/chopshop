import http.server
import io
import json
import os
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop.agent import client as agent_client, mcp  # noqa: E402
from chopshop.agent.client import AgentClient, AgentError  # noqa: E402


class FakeClient:
    """Cliente HTTP falso: registra las llamadas y responde con `responses[(método, ruta)]` (o lanza si es una excepción)."""
    timeout = 10

    def __init__(self, responses=None):
        self.responses = responses or {}
        self.calls = []

    def _answer(self, method, path, body, timeout):
        self.calls.append((method, path, body, timeout))
        r = self.responses.get((method, path), {})
        if isinstance(r, Exception):
            raise r
        return r

    def get(self, path, params=None, timeout=None):
        return self._answer("GET", path, None, timeout)

    def post(self, path, body=None, timeout=None):
        return self._answer("POST", path, body, timeout)


def make_cfg(tmp):
    cfg = {"projects_root": os.path.join(tmp, "projects"), "worktrees_root": os.path.join(tmp, "worktrees"),
           "port": 3790, "token_file": os.path.join(tmp, "token"), "projects": {}}
    for d in ("projects/proyecto-demo/src", "worktrees/proyecto-demo/wt-uno/src", "worktrees/proyecto-demo/wt-dos"):
        os.makedirs(os.path.join(tmp, d))
    return cfg


class TmpCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = os.path.realpath(self._tmp.name)
        self.cfg = make_cfg(self.tmp)

    def path(self, *p):
        return os.path.join(self.tmp, *p)


class TestInfer(TmpCase):
    def test_t3_worktree(self):
        ctx = mcp.infer_context(self.path("worktrees", "proyecto-demo", "wt-uno", "src"), self.cfg)
        self.assertEqual(ctx, {"project": "proyecto-demo", "worktree": self.path("worktrees", "proyecto-demo", "wt-uno")})

    def test_t3_worktree_root_itself(self):
        ctx = mcp.infer_context(self.path("worktrees", "proyecto-demo", "wt-dos"), self.cfg)
        self.assertEqual(ctx["worktree"], self.path("worktrees", "proyecto-demo", "wt-dos"))

    def test_project_checkout(self):
        ctx = mcp.infer_context(self.path("projects", "proyecto-demo", "src"), self.cfg)
        self.assertEqual(ctx, {"project": "proyecto-demo", "worktree": self.path("projects", "proyecto-demo")})

    def test_unknown(self):
        self.assertEqual(mcp.infer_context(self.tmp, self.cfg), {"project": None, "worktree": None})
        # el directorio de proyectos sin proyecto, o el de worktrees sin worktree, no cuentan
        self.assertIsNone(mcp.infer_context(self.path("projects"), self.cfg)["project"])
        self.assertIsNone(mcp.infer_context(self.path("worktrees", "proyecto-demo"), self.cfg)["project"])

    def test_sibling_prefix_is_not_inside(self):
        os.makedirs(self.path("projects-otro", "x"))
        self.assertIsNone(mcp.infer_context(self.path("projects-otro", "x"), self.cfg)["project"])

    def test_configured_project_wins(self):
        os.makedirs(self.path("otro", "raiz", "pkg"))
        self.cfg["projects"] = {"alias-demo": {"root": self.path("otro", "raiz")}}
        ctx = mcp.infer_context(self.path("otro", "raiz", "pkg"), self.cfg)
        self.assertEqual(ctx, {"project": "alias-demo", "worktree": self.path("otro", "raiz")})


class TestProtocol(TmpCase):
    def rpc(self, server, *msgs):
        stdin = io.StringIO("".join(json.dumps(m) + "\n" for m in msgs))
        out = io.StringIO()
        server.serve(stdin, out)
        return [json.loads(x) for x in out.getvalue().splitlines()]

    def server(self, responses=None, cwd=None, environ=None):
        self.fake = FakeClient(responses)
        return mcp.McpServer(mcp.Tools(self.fake, self.cfg, cwd=cwd or self.path("worktrees", "proyecto-demo", "wt-uno"),
                                       environ=environ if environ is not None else {}))

    def test_handshake(self):
        out = self.rpc(self.server(),
                       {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}},
                       {"jsonrpc": "2.0", "method": "notifications/initialized"},
                       {"jsonrpc": "2.0", "id": 2, "method": "ping"})
        self.assertEqual(len(out), 2)  # la notificación no responde
        r = out[0]["result"]
        self.assertEqual(out[0]["id"], 1)
        self.assertEqual(r["protocolVersion"], "2024-11-05")
        self.assertIn("tools", r["capabilities"])
        self.assertEqual(r["serverInfo"]["name"], "chopshop")
        self.assertEqual(out[1], {"jsonrpc": "2.0", "id": 2, "result": {}})

    def test_tools_list(self):
        out = self.rpc(self.server(), {"jsonrpc": "2.0", "id": 7, "method": "tools/list"})
        tools = out[0]["result"]["tools"]
        self.assertEqual([t["name"] for t in tools], ["chopshop_request_test_server", "chopshop_request_port",
                                                      "chopshop_release", "chopshop_status"])
        for t in tools:
            self.assertEqual(t["inputSchema"]["type"], "object")
            self.assertTrue(t["description"])

    def test_errors(self):
        s = self.server()
        out = self.rpc(s, {"jsonrpc": "2.0", "id": 1, "method": "no/existe"},
                       {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "otra"}},
                       {"jsonrpc": "2.0", "method": "no/existe"},
                       [1])
        self.assertEqual(out[0]["error"]["code"], -32601)
        self.assertEqual(out[1]["error"]["code"], -32602)
        self.assertEqual(out[2][0]["error"]["code"], -32600)  # lote con un elemento inválido
        self.assertEqual(len(out), 3)                          # la notificación desconocida no responde
        self.assertEqual(json.loads(s.handle_line("{no json")), {"jsonrpc": "2.0", "id": None,
                                                                 "error": {"code": -32700, "message": "JSON inválido"}})
        self.assertIsNone(s.handle_line("   "))

    def call(self, server, name, arguments=None, rid=1):
        out = self.rpc(server, {"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                                "params": {"name": name, "arguments": arguments or {}}})
        res = out[0]["result"]
        return res, res["content"][0]["text"]

    def test_request_test_server_infers_and_wait(self):
        lease = {"id": "l-0001", "state": "active", "port": 41000}
        s = self.server({("POST", "/leases/request"): lease}, environ={"T3CODE_THREAD_ID": "hilo-1"})
        res, text = self.call(s, "chopshop_request_test_server", {"wait_seconds": 30})
        self.assertFalse(res["isError"])
        self.assertEqual(json.loads(text), lease)
        method, path, body, timeout = self.fake.calls[0]
        self.assertEqual((method, path), ("POST", "/leases/request"))
        self.assertEqual(body, {"project": "proyecto-demo", "kind": "test_server", "wait_seconds": 30, "thread_id": "hilo-1",
                                "worktree": self.path("worktrees", "proyecto-demo", "wt-uno")})
        self.assertEqual(timeout, 40)  # el timeout HTTP cubre la espera

    def test_request_without_thread_env_and_explicit_args(self):
        s = self.server({("POST", "/leases/request"): {"id": "l-2"}})
        self.call(s, "chopshop_request_test_server", {"project": "proyecto-demo", "worktree": "../wt-dos"})
        body = self.fake.calls[0][2]
        self.assertNotIn("thread_id", body)
        self.assertEqual(body["worktree"], self.path("worktrees", "proyecto-demo", "wt-dos"))
        # proyecto explícito distinto del inferido: no se arrastra el worktree del cwd
        self.call(s, "chopshop_request_test_server", {"project": "otro-demo"})
        self.assertEqual(self.fake.calls[1][2], {"project": "otro-demo", "kind": "test_server"})

    def test_request_port(self):
        s = self.server({("POST", "/leases/request"): {"id": "l-3", "kind": "port", "port": 41010}})
        res, _ = self.call(s, "chopshop_request_port")
        self.assertFalse(res["isError"])
        body = self.fake.calls[0][2]
        self.assertEqual((body["kind"], body["project"]), ("port", "proyecto-demo"))
        self.assertNotIn("wait_seconds", body)

    def test_release_variants(self):
        s = self.server({("POST", "/leases/release"): {"released": [{"id": "l-1"}]}})
        res, _ = self.call(s, "chopshop_release", {"lease_id": "l-1"})
        self.assertFalse(res["isError"])
        self.call(s, "chopshop_release", {})
        self.call(s, "chopshop_release", {"worktree": "."})
        self.assertEqual(self.fake.calls[0][2], {"lease_id": "l-1"})
        wt = self.path("worktrees", "proyecto-demo", "wt-uno")
        self.assertEqual(self.fake.calls[1][2], {"worktree": wt})
        self.assertEqual(self.fake.calls[2][2], {"worktree": wt})

    def test_release_without_context_is_tool_error(self):
        s = self.server(cwd=self.tmp)
        res, text = self.call(s, "chopshop_release", {})
        self.assertTrue(res["isError"])
        self.assertIn("lease_id", text)
        self.assertEqual(self.fake.calls, [])

    def test_status(self):
        data = {"active": [], "queued": [], "capacity": {"max_servers": 4}}
        s = self.server({("GET", "/leases"): data})
        res, text = self.call(s, "chopshop_status")
        self.assertEqual(json.loads(text), data)
        self.assertEqual(self.fake.calls[0][:2], ("GET", "/leases"))

    def test_agent_error_is_iserror_not_exception(self):
        s = self.server({("POST", "/leases/request"): AgentError("HTTP 403: sin identidad", status=403),
                         ("GET", "/leases"): AgentError("agente no disponible en http://127.0.0.1:3790: conexión rechazada")})
        res, text = self.call(s, "chopshop_request_test_server")
        self.assertTrue(res["isError"])
        self.assertIn("403", text)
        res, text = self.call(s, "chopshop_status", rid=2)
        self.assertTrue(res["isError"])
        self.assertIn("no disponible", text)

    def test_invalid_input_and_no_project(self):
        s = self.server()
        res, text = self.call(s, "chopshop_request_test_server", {"wait_seconds": "mucho"})
        self.assertTrue(res["isError"])
        s = self.server(cwd=self.tmp)
        res, text = self.call(s, "chopshop_request_test_server")
        self.assertTrue(res["isError"])
        self.assertIn("project", text)
        self.assertEqual(self.fake.calls, [])

    def test_main_mcp_end_to_end(self):
        stdin = io.StringIO(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                        "params": {"name": "chopshop_status", "arguments": {}}}) + "\n")
        out = io.StringIO()
        fake = FakeClient({("GET", "/leases"): {"active": []}})
        self.assertEqual(mcp.main_mcp(["--cwd", self.tmp], stdin, out, client=fake), 0)
        self.assertEqual(json.loads(out.getvalue())["result"]["isError"], False)


class TestMainRelease(TmpCase):
    def run_release(self, argv, client):
        err, out = io.StringIO(), io.StringIO()
        old = sys.stdout
        sys.stdout = out
        try:
            code = mcp.main_release(argv, client=client, stderr=err)
        finally:
            sys.stdout = old
        return code, out.getvalue(), err.getvalue()

    def test_agent_down_exits_zero_with_warning(self):
        c = FakeClient({("POST", "/leases/release"): AgentError("agente no disponible en http://127.0.0.1:3790: rechazado")})
        code, out, err = self.run_release(["--worktree", self.tmp, "--thread", "hilo-1"], c)
        self.assertEqual(code, 0)
        self.assertIn("no disponible", err)
        self.assertEqual(len(c.calls), 2)  # intenta ambos selectores

    def test_real_unreachable_agent_exits_zero(self):
        # puerto 9 en loopback: nadie escucha; no se arranca nada
        cl = AgentClient(url="http://127.0.0.1:9", token_file=self.path("sin-token"), timeout=1)
        code, out, err = self.run_release(["--worktree", self.tmp], cl)
        self.assertEqual(code, 0)
        self.assertIn("chopshop release", err)

    def test_bad_args_and_unexpected_errors_exit_zero(self):
        self.assertEqual(self.run_release(["--no-existe"], FakeClient())[0], 0)

        class Boom(FakeClient):
            def post(self, *a, **k):
                raise RuntimeError("inesperado")
        code, _, err = self.run_release(["--worktree", self.tmp], Boom())
        self.assertEqual(code, 0)
        self.assertIn("inesperado", err)

    def test_selectors(self):
        c = FakeClient({("POST", "/leases/release"): {"released": [{"id": "l-1"}]}})
        code, out, err = self.run_release(["--worktree", ".", "--thread", " hilo-1 "], c)
        self.assertEqual(code, 0)
        self.assertEqual([x[2] for x in c.calls], [{"worktree": os.path.realpath(".")}, {"thread_id": "hilo-1"}])
        self.assertIn("2 lease(s)", out)
        # hilo vacío (variable sin definir) y sin worktree: cae al directorio actual
        c = FakeClient()
        self.run_release(["--thread", ""], c)
        self.assertEqual([x[2] for x in c.calls], [{"worktree": os.path.realpath(".")}])
        c = FakeClient()
        self.run_release(["--lease", "l-9"], c)
        self.assertEqual([x[2] for x in c.calls], [{"lease_id": "l-9"}])


class _Handler(http.server.BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.seen.append(("GET", self.path, None, self.headers.get("Authorization")))
        if self.path.startswith("/leases"):
            self._send(200, {"active": []})
        else:
            self._send(404, {"error": "no existe"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        self.seen.append(("POST", self.path, body, self.headers.get("Authorization")))
        self._send(403 if body.get("project") == "prohibido" else 200, {"error": "sin identidad"} if body.get("project") == "prohibido" else {"id": "l-1"})


class TestClientHttp(TmpCase):
    """Cliente real contra un servidor HTTP falso efímero en loopback (solo durante el test)."""

    def setUp(self):
        super().setUp()
        _Handler.seen = []
        self.httpd = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.url = "http://127.0.0.1:%d" % self.httpd.server_address[1]

    def _stop(self):
        if self.thread.is_alive():  # idempotente: test_connection_refused lo llama antes del cleanup
            self.httpd.shutdown()
            self.httpd.server_close()
            self.thread.join(5)

    def test_get_post_and_bearer(self):
        with open(self.cfg["token_file"], "w") as f:
            f.write("tok-falso\n")
        c = AgentClient(url=self.url + "/", token_file=self.cfg["token_file"], timeout=5)
        self.assertEqual(c.get("/leases"), {"active": []})
        self.assertEqual(c.post("/leases/request", {"project": "proyecto-demo"}), {"id": "l-1"})
        self.assertEqual(_Handler.seen[0][3], "Bearer tok-falso")
        self.assertEqual(_Handler.seen[1][2], {"project": "proyecto-demo"})

    def test_no_token_file_means_no_header(self):
        c = AgentClient(url=self.url, token_file=self.path("no-existe"), timeout=5)
        c.get("/leases")
        self.assertIsNone(_Handler.seen[0][3])

    def test_http_error_becomes_agent_error_without_token(self):
        with open(self.cfg["token_file"], "w") as f:
            f.write("tok-falso")
        c = AgentClient(url=self.url, token_file=self.cfg["token_file"], timeout=5)
        with self.assertRaises(AgentError) as cm:
            c.post("/leases/request", {"project": "prohibido"})
        self.assertEqual(cm.exception.status, 403)
        self.assertIn("sin identidad", str(cm.exception))
        self.assertNotIn("tok-falso", str(cm.exception))
        with self.assertRaises(AgentError) as cm:
            c.get("/nada")
        self.assertEqual(cm.exception.status, 404)

    def test_connection_refused(self):
        self._stop()
        c = AgentClient(url=self.url, token_file=self.path("x"), timeout=1)
        with self.assertRaises(AgentError) as cm:
            c.get("/leases")
        self.assertIsNone(cm.exception.status)
        self.assertIn("no disponible", str(cm.exception))


class TestResolveUrl(unittest.TestCase):
    def test_env_then_port(self):
        self.assertEqual(agent_client.resolve_url({"port": 3791}, {}), "http://127.0.0.1:3791")
        self.assertEqual(agent_client.resolve_url({"port": 3791}, {"CHOPSHOP_AGENT_URL": "http://100.64.0.10:3790/"}),
                         "http://100.64.0.10:3790")

    def test_token_reader(self):
        self.assertIsNone(agent_client.read_token(""))
        self.assertIsNone(agent_client.read_token("/ruta/que/no/existe/token"))


if __name__ == "__main__":
    unittest.main()
