"""Pruebas del agente ficticio de tools/mock_agent (el que usa la app de Mac para verificar varias máquinas) con dos
servidores REALES en loopback y puerto efímero: forma de /health y /snapshot, métricas que cambian, emparejamiento y
que la credencial nunca aparezca en el log."""
import http.client
import io
import json
import os
import sys
import threading
import unittest
from contextlib import redirect_stderr

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "mock_agent"))
import mock_agent  # noqa: E402


class MockAgentTest(unittest.TestCase):
    def start(self, name, require_pairing=False):
        agent = mock_agent.MockAgent(mock_agent.load_snapshot(name), require_pairing=require_pairing)
        srv = mock_agent.serve(agent)
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return srv.server_address[1]

    def req(self, port, method, path, body=None, token=None):
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        headers = {}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = "Bearer " + token
        c.request(method, path, body=data, headers=headers)
        r = c.getresponse()
        out = (r.status, json.loads(r.read() or b"{}"))
        c.close()
        return out

    def test_two_agents_serve_their_own_machine(self):
        with redirect_stderr(io.StringIO()):
            a, b = self.start("host-a"), self.start("host-b")
            st, ha = self.req(a, "GET", "/health")
            self.assertEqual((st, ha["machine_id"], ha["ok"]), (200, "host-a", True))
            sa = self.req(a, "GET", "/snapshot")[1]
            sb = self.req(b, "GET", "/snapshot")[1]
        self.assertEqual((sa["machine_id"], sb["machine_id"]), ("host-a", "host-b"))
        for s in (sa, sb):
            m = s["machine"]
            self.assertTrue(0 <= m["cpu_pct"] <= 100 and 0 <= m["ram_pct"] <= 100)
            self.assertIn("projects", s)
            self.assertIn("threads", s)

    def test_metrics_move_between_polls(self):
        agent = mock_agent.MockAgent(mock_agent.load_snapshot("host-a"), clock=lambda: 1768494600.0)
        cpus = {agent.snapshot()["machine"]["cpu_pct"] for _ in range(6)}
        self.assertGreater(len(cpus), 1)
        self.assertEqual(agent.snapshot()["ts"], 1768494600.0)

    def test_pairing_required(self):
        log = io.StringIO()
        with redirect_stderr(log):
            p = self.start("host-b", require_pairing=True)
            self.assertEqual(self.req(p, "GET", "/health")[0], 200, "health sin credencial")
            self.assertEqual(self.req(p, "GET", "/snapshot")[0], 401)
            self.assertEqual(self.req(p, "POST", "/pair", {})[0], 400)
            st, r = self.req(p, "POST", "/pair", {"code": "K7QM-93XD", "device_id": "mac-1"})
            self.assertEqual((st, r["device_id"], r["api_version"]), (200, "mac-1", 2))
            cred = r["credential"]
            self.assertTrue(cred.startswith("cs1_"))
            self.assertEqual(self.req(p, "GET", "/snapshot", token="cs1_otra")[0], 401)
            st, s = self.req(p, "GET", "/snapshot", token=cred)
            self.assertEqual((st, s["machine_id"]), (200, "host-b"))
        self.assertNotIn(cred, log.getvalue(), "la credencial nunca va al log")
        self.assertIn("/snapshot", log.getvalue())

    def test_unknown_agent_and_routes(self):
        with self.assertRaises(ValueError):
            mock_agent.load_snapshot("host-z")
        with redirect_stderr(io.StringIO()):
            p = self.start("host-a")
            self.assertEqual(self.req(p, "GET", "/stream")[0], 404)
            self.assertEqual(self.req(p, "POST", "/settle", {"thread_id": "t"})[0], 200)


if __name__ == "__main__":
    unittest.main()
