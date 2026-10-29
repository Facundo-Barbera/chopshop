"""Pruebas de chopshop.t3mcp contra un T3 falso (http.server en 127.0.0.1:0) y un `t3` CLI falso (sin T3 real)."""
import base64
import hashlib
import http.server
import json
import logging
import os
import stat
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import t3mcp  # noqa: E402

TOKEN = "tok-secreto-de-prueba-123"
PAIRING = "pair-secreto-de-prueba-456"


class FakeT3:
    """Estado del T3 falso: OAuth MCP + endpoint /mcp. Cada respuesta se puede forzar desde el test."""

    def __init__(self):
        self.requests = []           # (path, headers, body)
        self.tokens_issued = 0
        self.valid_tokens = set()
        self.sessions = set()
        self.sse = False
        self.tool_result = {"structuredContent": {"ok": True}}
        self.force = None            # (status, texto) para la próxima llamada a tools/call
        self.sleep = 0
        self.challenges = {}
        self.expires_in = 30 * 24 * 3600
        self.reject_decision = False

    def handle(self, path, headers, body):
        self.requests.append((path, dict(headers), body))
        if path == "/oauth/mcp/register":
            return 200, {}, {"client_id": "cli-1"}
        if path == "/oauth/mcp/decision":
            req = json.loads(body)
            if self.reject_decision or req["decision"]["code"] != PAIRING:
                return 200, {}, {"redirectTo": "http://127.0.0.1:1/chopshop-callback?error=access_denied"}
            self.challenges["code-1"] = req["authorization"]["code_challenge"]
            return 200, {}, {"redirectTo": "http://127.0.0.1:1/chopshop-callback?code=code-1&state=x"}
        if path == "/oauth/mcp/token":
            form = dict(urllib.parse.parse_qsl(body))
            digest = hashlib.sha256(form["code_verifier"].encode()).digest()
            if base64.urlsafe_b64encode(digest).rstrip(b"=").decode() != self.challenges.get(form["code"]):
                return 400, {}, {"error": "invalid_grant"}
            self.tokens_issued += 1
            tok = "%s-%d" % (TOKEN, self.tokens_issued)
            self.valid_tokens.add(tok)
            return 200, {}, {"access_token": tok, "token_type": "Bearer", "expires_in": self.expires_in}
        if path != "/mcp":
            return 404, {}, {"error": "no existe"}
        auth = headers.get("authorization", "")
        if auth[len("Bearer "):] not in self.valid_tokens:
            return 401, {}, {"error": "unauthorized " + auth}
        msg = json.loads(body)
        if headers.get("mcp-protocol-version") != "2025-06-18" or "text/event-stream" not in headers.get("accept", ""):
            return 400, {}, {"error": "cabeceras"}
        if msg["method"] == "initialize":
            sid = "sess-%d" % (len(self.sessions) + 1)
            self.sessions.add(sid)
            return 200, {"mcp-session-id": sid}, {"jsonrpc": "2.0", "id": msg["id"],
                                                  "result": {"protocolVersion": "2025-06-18"}}
        if headers.get("mcp-session-id") not in self.sessions:
            return 404, {}, {"error": "sesión desconocida"}
        if msg["method"] == "notifications/initialized":
            return 202, {}, ""
        if msg["method"] == "tools/list":
            res = {"tools": [{"name": "t3_thread_read"}, {"name": "t3_thread_launch"}]}
        elif msg["method"] == "tools/call":
            if self.sleep:
                time.sleep(self.sleep)
            if self.force:
                st, text = self.force
                self.force = None
                return st, {}, text
            res = dict(self.tool_result)
        else:
            return 200, {}, {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "no"}}
        out = {"jsonrpc": "2.0", "id": msg["id"], "result": res}
        if self.sse:
            noise = {"jsonrpc": "2.0", "method": "notifications/progress", "params": {}}
            text = "event: message\ndata: %s\n\nevent: message\ndata: %s\n\n" % (json.dumps(noise), json.dumps(out))
            return 200, {"content-type": "text/event-stream"}, text
        return 200, {}, out


def _serve(fake):
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(n).decode()
            hdrs = {k.lower(): v for k, v in self.headers.items()}
            st, extra, payload = fake.handle(self.path, hdrs, body)
            data = (payload if isinstance(payload, str) else json.dumps(payload)).encode()
            self.send_response(st)
            if "content-type" not in extra:
                self.send_header("content-type", "application/json")
            for k, v in extra.items():
                self.send_header(k, v)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    srv.daemon_threads = True
    srv.handle_error = lambda *a: None  # el test de timeout corta la conexión a propósito
    threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
    return srv


class FakeRun:
    """Simula `t3 auth pairing create/revoke`."""

    def __init__(self, fail=None):
        self.calls = []
        self.fail = fail

    def __call__(self, argv, timeout):
        self.calls.append(list(argv))
        if self.fail:
            raise self.fail
        if argv[1:4] == ["auth", "pairing", "create"]:
            out = json.dumps({"id": "pair-%d" % len(self.calls), "credential": PAIRING})
            return types.SimpleNamespace(returncode=0, stdout=out, stderr="")
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")

    def creates(self):
        return [c for c in self.calls if c[1:4] == ["auth", "pairing", "create"]]

    def revokes(self):
        return [c for c in self.calls if c[1:4] == ["auth", "pairing", "revoke"]]


class Base(unittest.TestCase):
    def setUp(self):
        self.fake = FakeT3()
        self.srv = _serve(self.fake)
        self.origin = "http://127.0.0.1:%d" % self.srv.server_address[1]
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = os.path.join(self.tmp.name, "sub", "t3-credential.json")
        self.run = FakeRun()
        self.now = [1_000_000.0]

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.tmp.cleanup()

    def client(self, **kw):
        opts = dict(origin=self.origin, credential_file=self.cache, t3_bin="/opt/t3/bin/t3",
                    run=self.run, clock=lambda: self.now[0], timeout=5)
        opts.update(kw)
        return t3mcp.Client(**opts)

    def mcp_requests(self):
        return [json.loads(b) for p, h, b in self.fake.requests if p == "/mcp"]


class HandshakeTest(Base):
    def test_handshake_y_llamada_json(self):
        c = self.client()
        self.assertEqual(c.call("t3_thread_read", {"threadId": "t-1"}), {"ok": True})
        methods = [m["method"] for m in self.mcp_requests()]
        self.assertEqual(methods, ["initialize", "notifications/initialized", "tools/call"])
        self.assertNotIn("id", self.mcp_requests()[1])
        call = self.mcp_requests()[2]
        self.assertEqual(call["params"], {"name": "t3_thread_read", "arguments": {"threadId": "t-1"}})
        # la sesión se guarda de la primera respuesta y viaja en las siguientes
        hdrs = [h for p, h, b in self.fake.requests if p == "/mcp"]
        self.assertNotIn("mcp-session-id", hdrs[0])
        self.assertEqual(hdrs[2]["mcp-session-id"], "sess-1")
        # segunda llamada: sin nuevo handshake
        c.call("t3_thread_read", {"threadId": "t-2"})
        self.assertEqual([m["method"] for m in self.mcp_requests()].count("initialize"), 1)

    def test_oauth_pkce_y_pairing_revocado(self):
        self.client().call("t3_thread_read")
        paths = [p for p, h, b in self.fake.requests]
        self.assertEqual(paths[:3], ["/oauth/mcp/register", "/oauth/mcp/decision", "/oauth/mcp/token"])
        create = self.run.creates()[0]
        self.assertEqual(create[0], "/opt/t3/bin/t3")
        self.assertIn("orchestration:operate", create)
        self.assertNotIn("settings:write", create)
        self.assertEqual(create[create.index("--label") + 1], "chopshop")
        self.assertEqual(self.run.revokes(), [["/opt/t3/bin/t3", "auth", "pairing", "revoke", "pair-1"]])
        decision = json.loads(self.fake.requests[1][2])
        self.assertEqual(decision["authorization"]["code_challenge_method"], "S256")
        self.assertEqual(decision["authorization"]["resource"], self.origin + "/mcp")

    def test_full_access_pide_mas_scopes(self):
        self.client(access="full-access").call("t3_thread_read")
        create = self.run.creates()[0]
        self.assertIn("settings:write", create)
        self.assertIn("source-control:write", create)

    def test_sse(self):
        self.fake.sse = True
        self.fake.tool_result = {"content": [{"type": "text", "text": "hola"}]}
        self.assertEqual(self.client().call("t3_thread_read"), [{"type": "text", "text": "hola"}])

    def test_list_tools(self):
        names = [t["name"] for t in self.client().list_tools()]
        self.assertEqual(names, ["t3_thread_read", "t3_thread_launch"])

    def test_origen_desde_runtime(self):
        rt = os.path.join(self.tmp.name, "server-runtime.json")
        with open(rt, "w") as f:
            json.dump({"origin": self.origin + "/"}, f)
        c = t3mcp.Client(credential_file=self.cache, run=self.run, clock=lambda: self.now[0], runtime_file=rt)
        self.assertEqual(c.origin, self.origin)
        self.assertEqual(c.call("t3_thread_read"), {"ok": True})

    def test_runtime_ausente(self):
        c = t3mcp.Client(credential_file=self.cache, run=self.run,
                         runtime_file=os.path.join(self.tmp.name, "no-existe.json"))
        with self.assertRaises(t3mcp.T3Error):
            c.call("t3_thread_read")

    def test_http_inyectable(self):
        seen = []

        def http(method, url, headers, body, timeout):
            seen.append(url)
            path = urllib.parse.urlsplit(url).path
            st, extra, payload = self.fake.handle(path, headers, body.decode())
            return st, extra, payload if isinstance(payload, str) else json.dumps(payload)

        c = self.client(origin="http://localhost:1", http=http)
        self.assertEqual(c.call("t3_thread_read"), {"ok": True})
        self.assertTrue(all(u.startswith("http://localhost:1/") for u in seen))


class CredentialTest(Base):
    def test_cache_0600_reutilizada(self):
        self.client().call("t3_thread_read")
        mode = stat.S_IMODE(os.stat(self.cache).st_mode)
        self.assertEqual(mode, 0o600)
        with open(self.cache) as f:
            cred = json.load(f)
        self.assertEqual(set(cred), {"origin", "access", "token", "expiresAt"})
        self.assertEqual((cred["origin"], cred["access"]), (self.origin, "approval-required"))
        # otro cliente (otro proceso) reutiliza la caché: sin nuevo pairing ni OAuth
        self.client().call("t3_thread_read")
        self.assertEqual(len(self.run.creates()), 1)
        self.assertEqual(self.fake.tokens_issued, 1)

    def test_cache_de_otro_acceso_no_sirve(self):
        self.client().call("t3_thread_read")
        self.client(access="full-access").call("t3_thread_read")
        self.assertEqual(self.fake.tokens_issued, 2)

    def test_expiracion(self):
        c = self.client()
        c.call("t3_thread_read")
        self.now[0] += self.fake.expires_in  # pasado el margen de 1 h
        c.call("t3_thread_read")
        self.assertEqual(self.fake.tokens_issued, 2)
        self.assertEqual(len(self.run.creates()), 2)

    def test_reintento_tras_401(self):
        c = self.client()
        c.call("t3_thread_read")
        self.fake.valid_tokens.clear()  # T3 revoca la sesión MCP
        self.assertEqual(c.call("t3_thread_read"), {"ok": True})
        self.assertEqual(self.fake.tokens_issued, 2)
        with open(self.cache) as f:
            self.assertTrue(json.load(f)["token"].endswith("-2"))

    def test_401_persistente_reintenta_una_sola_vez(self):
        c = self.client()
        c.call("t3_thread_read")
        orig = self.fake.handle

        def always_401(path, headers, body):
            if path == "/mcp":
                self.fake.requests.append((path, dict(headers), body))
                return 401, {}, {"error": "no"}
            return orig(path, headers, body)

        self.fake.handle = always_401
        with self.assertRaises(t3mcp.T3Error) as cm:
            c.call("t3_thread_read")
        self.assertIn("401", str(cm.exception))
        self.assertEqual(self.fake.tokens_issued, 2)

    def test_sesion_caducada_404_reabre(self):
        c = self.client()
        c.call("t3_thread_read")
        self.fake.sessions.clear()
        self.assertEqual(c.call("t3_thread_read"), {"ok": True})
        self.assertEqual([m["method"] for m in self.mcp_requests()].count("initialize"), 2)
        self.assertEqual(self.fake.tokens_issued, 1)

    def test_aprobacion_rechazada_revoca_igual(self):
        self.fake.reject_decision = True
        with self.assertRaises(t3mcp.T3Error) as cm:
            self.client().call("t3_thread_read")
        self.assertIn("access_denied", str(cm.exception))
        self.assertEqual(len(self.run.revokes()), 1)
        self.assertFalse(os.path.exists(self.cache))

    def test_decision_http_error_revoca_igual(self):
        orig = self.fake.handle
        self.fake.handle = lambda p, h, b: (500, {}, "boom") if p == "/oauth/mcp/decision" else orig(p, h, b)
        with self.assertRaises(t3mcp.T3Error):
            self.client().call("t3_thread_read")
        self.assertEqual(len(self.run.revokes()), 1)

    def test_remoto_sin_t3_local(self):
        c = self.client(origin="http://100.64.0.10:3773", run=FakeRun(fail=FileNotFoundError("t3")),
                        http=lambda *a: (200, {}, json.dumps({"client_id": "cli-1"})))
        with self.assertRaises(t3mcp.T3Error) as cm:
            c.call("t3_thread_read")
        self.assertIn("remoto", str(cm.exception))

    def test_local_sin_t3(self):
        c = self.client(run=FakeRun(fail=FileNotFoundError("t3")))
        with self.assertRaises(t3mcp.T3Error) as cm:
            c.call("t3_thread_read")
        self.assertIn("pairing", str(cm.exception))


class ErrorTest(Base):
    def assertNoSecret(self, text):
        self.assertNotIn(TOKEN, text)
        self.assertNotIn(PAIRING, text)

    def test_is_error(self):
        self.fake.tool_result = {"isError": True, "content": [{"type": "text", "text": "hilo no encontrado"}]}
        with self.assertRaises(t3mcp.T3Error) as cm:
            self.client().call("t3_thread_read")
        self.assertIn("hilo no encontrado", str(cm.exception))

    def test_tag_failure(self):
        text = json.dumps({"_tag": "ThreadNotFoundFailure", "message": "x"})
        self.fake.tool_result = {"content": [{"type": "text", "text": text}]}
        with self.assertRaises(t3mcp.T3Error) as cm:
            self.client().call("t3_thread_read")
        self.assertIn("ThreadNotFoundFailure", str(cm.exception))

    def test_http_500(self):
        self.fake.force = (500, "x" * 5000)
        with self.assertRaises(t3mcp.T3Error) as cm:
            self.client().call("t3_thread_read")
        self.assertIn("500", str(cm.exception))
        self.assertLessEqual(len(str(cm.exception)), 600)

    def test_jsonrpc_error(self):
        self.fake.force = (200, json.dumps({"jsonrpc": "2.0", "id": 3, "error": {"code": -32000, "message": "mal"}}))
        with self.assertRaises(t3mcp.T3Error) as cm:
            self.client().call("t3_thread_read")
        self.assertIn("mal", str(cm.exception))

    def test_respuesta_no_json(self):
        self.fake.force = (200, "<html>")
        with self.assertRaises(t3mcp.T3Error):
            self.client().call("t3_thread_read")

    def test_timeout(self):
        self.fake.sleep = 1.0
        with self.assertRaises(t3mcp.T3Error) as cm:
            self.client(timeout=0.2).call("t3_thread_read")
        self.assertIn("red", str(cm.exception))

    def test_red_caida(self):
        port = self.srv.server_address[1]
        self.srv.shutdown()
        self.srv.server_close()
        self.srv = _serve(FakeT3())  # para que tearDown tenga algo que cerrar
        with self.assertRaises(t3mcp.T3Error):
            self.client(origin="http://127.0.0.1:%d" % port).call("t3_thread_read")

    def test_guardia_archivar(self):
        c = self.client()
        for action in ("archive", "delete", None):
            with self.assertRaises(t3mcp.T3Error):
                c.call("t3_thread_organize", {"threadId": "t-1", "action": action})
        self.assertEqual(self.fake.requests, [])  # ni siquiera se conecta
        self.assertEqual(c.call("t3_thread_organize", {"threadId": "t-1", "action": "settle"}), {"ok": True})
        self.assertEqual(c.call("t3_thread_organize", {"threadId": "t-1", "action": "unsettle"}), {"ok": True})

    def test_token_nunca_en_errores_ni_logs(self):
        # el servidor hace eco de la cabecera authorization en sus errores
        c = self.client()
        errors = []
        with self.assertLogs("chopshop.t3mcp", level="DEBUG") as logs:
            c.call("t3_thread_read")
            self.fake.force = (500, "eco: Bearer %s-1 pairing %s" % (TOKEN, PAIRING))
            with self.assertRaises(t3mcp.T3Error) as cm:
                c.call("t3_thread_read")
            errors.append(str(cm.exception))
            self.fake.tool_result = {"isError": True, "content": [{"type": "text", "text": "eco %s-1" % TOKEN}]}
            with self.assertRaises(t3mcp.T3Error) as cm:
                c.call("t3_thread_read")
            errors.append(str(cm.exception))
            self.fake.valid_tokens.clear()
            orig = self.fake.handle
            self.fake.handle = lambda p, h, b: (401, {}, {"e": h.get("authorization")}) if p == "/mcp" else orig(p, h, b)
            with self.assertRaises(t3mcp.T3Error) as cm:
                c.call("t3_thread_read")
            errors.append(str(cm.exception))
            logging.getLogger("chopshop.t3mcp").debug("fin")
        self.assertIn("***", errors[0])
        for text in errors + logs.output:
            self.assertNoSecret(text)


if __name__ == "__main__":
    unittest.main()
