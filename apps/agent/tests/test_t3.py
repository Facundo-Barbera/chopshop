"""Pruebas de chopshop.t3 (fachada sobre t3mcp): caché de clientes, is_local, T3Error unificado y sin fleet.
Sin red, sin T3 ni node: el cliente se sustituye con `t3.set_client_factory`."""
import inspect
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import t3, t3mcp  # noqa: E402


class Fake:
    def __init__(self, hc, host, timeout):
        self.hc, self.host, self.timeout, self.calls = hc, host, timeout, []

    def call(self, tool, args=None):
        self.calls.append((tool, args, self.timeout))
        if tool == "boom":
            raise t3mcp.T3Error("boom falló: algo")
        return {"tool": tool, "host": self.host}


class TestT3(unittest.TestCase):
    def setUp(self):
        self.made = []

        def factory(hc, host, timeout):
            c = Fake(hc, host, timeout)
            self.made.append(c)
            return c
        t3.set_client_factory(factory)
        self.addCleanup(t3.set_client_factory, None)

    def test_cache_por_host(self):
        a = {"access": "full-access"}
        self.assertEqual(t3.call(a, "host-a", "t3_project_list"), {"tool": "t3_project_list", "host": "host-a"})
        t3.call(dict(a), "host-a", "t3_thread_list", {"limit": 5}, timeout=7)
        self.assertEqual(len(self.made), 1)                                  # mismo host y config: se reutiliza
        self.assertEqual(self.made[0].calls[1], ("t3_thread_list", {"limit": 5}, 7))
        t3.call(a, "host-b", "x")                                            # otro host
        t3.call({"access": "approval-required"}, "host-a", "x")              # otro access
        t3.call({"access": "full-access", "origin": "http://100.64.0.10:3773"}, "host-a", "x")
        t3.call({"access": "full-access", "credential_file": "/tmp/otra.json"}, "host-a", "x")
        self.assertEqual(len(self.made), 5)
        t3.call({}, "host-c", "x"); t3.call({"access": "approval-required"}, "host-c", "x")   # access por defecto
        self.assertEqual(len(self.made), 6)
        t3.reset()
        t3.call(a, "host-a", "x")
        self.assertEqual(len(self.made), 7)

    def test_cache_concurrente(self):
        ths = [threading.Thread(target=t3.call, args=({}, "host-a", "x")) for _ in range(20)]
        for th in ths:
            th.start()
        for th in ths:
            th.join()
        self.assertEqual(len(self.made), 1)

    def test_is_local(self):
        self.assertTrue(t3.is_local({}))
        self.assertTrue(t3.is_local(None))
        self.assertTrue(t3.is_local({"origin": "", "t3_bin": "t3"}))
        self.assertFalse(t3.is_local({"origin": "http://100.64.0.10:3773"}))

    def test_t3error_unificado(self):
        self.assertIs(t3.T3Error, t3mcp.T3Error)
        with self.assertRaises(t3mcp.T3Error) as cm:
            t3.call({}, "host-b", "boom")
        self.assertIn("host-b", str(cm.exception))

    def test_cliente_real_por_defecto(self):
        t3.set_client_factory(None)
        c = t3.client({"origin": "http://100.64.0.10:3773/", "access": "full-access",
                       "credential_file": "/tmp/cred.json", "t3_bin": "/opt/t3/bin/t3"}, "host-b", timeout=12)
        self.assertIsInstance(c, t3mcp.Client)
        self.assertEqual((c.origin, c.access, c.credential_file, c.t3_bin, c.timeout),
                         ("http://100.64.0.10:3773", "full-access", "/tmp/cred.json", "/opt/t3/bin/t3", 12))
        loc = t3.client({}, "local")
        self.assertEqual((loc.access, loc.t3_bin, loc._origin), ("approval-required", "t3", None))

    def test_claves_viejas_se_ignoran(self):
        t3.set_client_factory(None)
        c = t3.client({"transport": "fleet", "node": "node", "helper": "~/x/t3mcp.mjs", "fleet_host": "h"}, "host-a")
        self.assertIsInstance(c, t3mcp.Client)                               # sin error y sin transporte fleet
        self.assertTrue(t3.is_local({"transport": "fleet"}))

    def test_sin_transporte_fleet(self):
        src = inspect.getsource(t3).lower()
        for w in ("fleet", "subprocess", "helper", "t3mcp.mjs", "transport"):
            self.assertNotIn(w, src)


if __name__ == "__main__":
    unittest.main()
