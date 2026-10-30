import io
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from chopshop import cli, relayadmin

SECRET = "op-secret-Zq81xLw0-DO-NOT-PRINT"
LINK = "https://chopshop.novarix.online/invite#t=ci1_" + "A" * 43


class FakeApi:
    def __init__(self):
        self.requests = []
        self.replies = {}
        api = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n)
                api.requests.append({"path": self.path, "headers": dict(self.headers), "body": json.loads(body or b"{}")})
                status, payload = api.replies.get(self.path, (404, {"code": "not_found", "message": "no existe"}))
                if status in (301, 302, 307):
                    self.send_response(status)
                    self.send_header("Location", payload)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                raw = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, args=(0.05,), daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def error(code, message, **extra):
    return dict({"v": 2, "type": "error", "id": "e1", "ts": 0, "re": None, "code": code, "message": message}, **extra)


def invitation(kind):
    return {"invitation": {"id": "inv-1", "email": "owner@example.test", "kind": kind, "expires_at": "2026-10-31T00:00:00Z"}, "link": LINK}


class RelayAdminTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeApi()
        self.addCleanup(self.api.close)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.token_file = os.path.join(self.tmp.name, "op")
        fd = os.open(self.token_file, os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(SECRET + "\n")

    def run_cli(self, argv, stdin=""):
        out, err = io.StringIO(), io.StringIO()
        rc = relayadmin.main(argv, stdin=io.StringIO(stdin), stdout=out, stderr=err)
        self.assertNotIn(SECRET, out.getvalue())
        self.assertNotIn(SECRET, err.getvalue())
        return rc, out.getvalue(), err.getvalue()

    def test_bootstrap_token_file(self):
        self.api.replies["/v1/operator/bootstrap"] = (201, invitation("owner_bootstrap"))
        rc, out, err = self.run_cli(["bootstrap", "--email", "owner@example.test", "--token-file", self.token_file, "--api", self.api.url])
        self.assertEqual(rc, 0)
        self.assertEqual(out.count(LINK), 1)
        self.assertIn("fuera de línea", out)
        self.assertIn("UNA sola vez", out)
        self.assertEqual(err, "")
        req = self.api.requests[0]
        self.assertEqual(req["path"], "/v1/operator/bootstrap")
        self.assertEqual(req["headers"]["Authorization"], "Bearer " + SECRET)
        self.assertTrue(req["headers"]["User-Agent"].startswith("chopshop-cli/"))
        self.assertEqual(req["body"], {"email": "owner@example.test"})

    def test_bootstrap_stdin(self):
        self.api.replies["/v1/operator/bootstrap"] = (201, invitation("owner_bootstrap"))
        rc, out, _ = self.run_cli(["bootstrap", "--email", "owner@example.test", "--stdin", "--api", self.api.url + "/"], stdin=SECRET + "\n")
        self.assertEqual(rc, 0)
        self.assertIn(LINK, out)
        self.assertEqual(self.api.requests[0]["headers"]["Authorization"], "Bearer " + SECRET)

    def test_bootstrap_conflict_exits_2(self):
        self.api.replies["/v1/operator/bootstrap"] = (409, error("conflict", "ya existe un dueño"))
        rc, out, err = self.run_cli(["bootstrap", "--email", "owner@example.test", "--token-file", self.token_file, "--api", self.api.url])
        self.assertEqual(rc, 2)
        self.assertEqual(out, "")
        self.assertIn("recover", err)

    def test_recover(self):
        self.api.replies["/v1/operator/recover"] = (201, invitation("owner_reset"))
        rc, out, _ = self.run_cli(["recover", "--stdin", "--api", self.api.url], stdin=SECRET)
        self.assertEqual(rc, 0)
        self.assertEqual(out.count(LINK), 1)
        self.assertIn("fuera de línea", out)
        self.assertEqual(self.api.requests[0]["path"], "/v1/operator/recover")
        self.assertEqual(self.api.requests[0]["body"], {})

    def test_recover_prints_recovery_code_once(self):
        reply = dict(invitation("owner_reset"), recovery_code="ABCDE-FGHJK-MNPQR-STVWX")
        self.api.replies["/v1/operator/recover"] = (201, reply)
        rc, out, _ = self.run_cli(["recover", "--token-file", self.token_file, "--api", self.api.url])
        self.assertEqual(rc, 0)
        self.assertEqual(out.count("ABCDE-FGHJK-MNPQR-STVWX"), 1)

    def test_recover_without_owner_exits_2(self):
        self.api.replies["/v1/operator/recover"] = (409, error("conflict", "no hay dueño"))
        rc, _, err = self.run_cli(["recover", "--token-file", self.token_file, "--api", self.api.url])
        self.assertEqual(rc, 2)
        self.assertIn("bootstrap", err)

    def test_http_errors_exit_1(self):
        cases = [(401, error("unauthorized", "no autorizado")), (503, error("internal", "operador deshabilitado")),
                 (429, error("rate_limited", "demasiados intentos", retry_after_s=60)), (500, {}), (400, error("bad_request", "correo inválido", field="email"))]
        for status, payload in cases:
            with self.subTest(status=status):
                self.api.replies["/v1/operator/recover"] = (status, payload)
                rc, out, err = self.run_cli(["recover", "--token-file", self.token_file, "--api", self.api.url])
                self.assertEqual(rc, 1)
                self.assertEqual(out, "")
                self.assertIn("HTTP %d" % status, err)
                if status == 429:
                    self.assertIn("reintenta en 60 s", err)

    def test_redirect_not_followed(self):
        self.api.replies["/v1/operator/recover"] = (307, self.api.url + "/elsewhere")
        rc, _, _ = self.run_cli(["recover", "--token-file", self.token_file, "--api", self.api.url])
        self.assertEqual(rc, 1)
        self.assertEqual([r["path"] for r in self.api.requests], ["/v1/operator/recover"])

    def test_bad_success_body_exits_1(self):
        self.api.replies["/v1/operator/recover"] = (201, {"invitation": {}})
        rc, _, err = self.run_cli(["recover", "--token-file", self.token_file, "--api", self.api.url])
        self.assertEqual(rc, 1)
        self.assertIn("falta link", err)

    def test_secret_source_rules(self):
        base = ["recover", "--api", self.api.url]
        self.assertEqual(self.run_cli(base)[0], 1)
        self.assertEqual(self.run_cli(base + ["--stdin", "--token-file", self.token_file], stdin=SECRET)[0], 1)
        self.assertEqual(self.run_cli(base + ["--stdin"], stdin="\n")[0], 1)
        self.assertEqual(self.run_cli(base + ["--token-file", os.path.join(self.tmp.name, "nope")])[0], 1)
        self.assertEqual(self.api.requests, [])

    def test_secret_never_accepted_in_argv(self):
        for flag in ("--token", "--secret", "--token-f"):
            with self.subTest(flag=flag):
                rc, _, _ = self.run_cli(["recover", flag, SECRET, "--api", self.api.url])
                self.assertEqual(rc, 1)
        rc, _, _ = self.run_cli(["recover", SECRET, "--stdin", "--api", self.api.url], stdin=SECRET)
        self.assertEqual(rc, 1)
        self.assertEqual(self.api.requests, [])

    def test_world_readable_token_file_warns(self):
        os.chmod(self.token_file, 0o644)
        self.api.replies["/v1/operator/recover"] = (201, invitation("owner_reset"))
        rc, _, err = self.run_cli(["recover", "--token-file", self.token_file, "--api", self.api.url])
        self.assertEqual(rc, 0)
        self.assertIn("chmod 600", err)

    def test_invalid_email_and_api(self):
        rc, _, _ = self.run_cli(["bootstrap", "--email", "no-es-correo", "--token-file", self.token_file, "--api", self.api.url])
        self.assertEqual(rc, 1)
        rc, _, err = self.run_cli(["recover", "--token-file", self.token_file, "--api", "http://example.com"])
        self.assertEqual(rc, 1)
        self.assertIn("https://", err)
        self.assertEqual(self.api.requests, [])

    def test_unreachable_api_exits_1(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        rc, _, err = self.run_cli(["recover", "--token-file", self.token_file, "--api", "http://127.0.0.1:%d" % port])
        self.assertEqual(rc, 1)
        self.assertIn("no se pudo contactar", err)

    def test_default_api(self):
        self.assertEqual(relayadmin.api_base(None), "https://api.chopshop.novarix.online")

    def test_cli_routes_relay_admin(self):
        with mock.patch.object(relayadmin, "main", return_value=2) as m:
            self.assertEqual(cli.main(["relay", "admin", "recover", "--stdin"]), 2)
        m.assert_called_once_with(["recover", "--stdin"])


if __name__ == "__main__":
    unittest.main()
