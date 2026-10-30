import io
import json
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import relaycfg  # noqa: E402

CRED = "cm1_" + "A" * 39 + "wxyz"
MID = "0f8fad5b-d9cb-469f-a165-70867728950e"


def link_payload(**kw):
    d = {"api_url": "https://api.example.test", "machine_id": MID, "local_machine_id": "mini.local", "credential": CRED}
    d.update(kw)
    return d


class Env(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = {k: v for k, v in os.environ.items() if not k.startswith("CHOPSHOP_")}
        env.update(XDG_CONFIG_HOME=self.tmp.name, CHOPSHOP_CONFIG=os.path.join(self.tmp.name, "none.toml"))
        p = mock.patch.dict(os.environ, env, clear=True)
        p.start()
        self.addCleanup(p.stop)

    def run_cli(self, argv, stdin=""):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(stdin)):
            code = relaycfg.main(argv, out, err)
        return code, out.getvalue(), err.getvalue()


class MachineFileTest(Env):
    def test_write_sets_private_permissions(self):
        p = relaycfg.write_machine(link_payload())
        self.assertEqual(p, os.path.join(self.tmp.name, "chopshop", "relay", "machine.json"))
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode), 0o700)
        self.assertFalse(os.path.exists(p + ".tmp"))

    def test_write_tightens_existing_directory(self):
        d = os.path.join(self.tmp.name, "chopshop", "relay")
        os.makedirs(d, mode=0o755)
        os.chmod(d, 0o755)
        relaycfg.write_machine(link_payload())
        self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o700)

    def test_roundtrip(self):
        relaycfg.write_machine(link_payload(api_url="https://api.example.test/"))
        m = relaycfg.read_machine()
        self.assertEqual(m["v"], 1)
        self.assertEqual(m["api_url"], "https://api.example.test")
        self.assertEqual(m["machine_id"], MID)
        self.assertEqual(m["local_machine_id"], "mini.local")
        self.assertEqual(m["credential"], CRED)
        self.assertTrue(m["linked_at"])
        self.assertTrue(relaycfg.remove_machine())
        self.assertIsNone(relaycfg.read_machine())
        self.assertFalse(relaycfg.remove_machine())

    def test_rejects_bad_formats(self):
        bad = [
            link_payload(credential="cr1_" + "A" * 43),
            link_payload(credential="cm1_" + "A" * 42),
            link_payload(credential="cm1_" + "A" * 42 + "!"),
            link_payload(credential=None),
            link_payload(machine_id="no-uuid"),
            link_payload(local_machine_id="con espacio"),
            link_payload(api_url="http://api.example.test"),
            link_payload(api_url="ftp://api.example.test"),
            link_payload(api_url=None),
        ]
        for d in bad:
            with self.assertRaises(relaycfg.RelayCfgError):
                relaycfg.write_machine(d)
        self.assertFalse(os.path.exists(relaycfg.machine_path()))

    def test_error_never_contains_credential(self):
        with self.assertRaises(relaycfg.RelayCfgError) as cm:
            relaycfg.write_machine(link_payload(credential=CRED + "x"))
        self.assertNotIn(CRED, str(cm.exception))

    def test_read_rejects_corrupt_file(self):
        relaycfg.write_machine(link_payload())
        with open(relaycfg.machine_path(), "w") as f:
            f.write("{no json")
        with self.assertRaises(relaycfg.RelayCfgError):
            relaycfg.read_machine()

    def test_loopback_http_allowed(self):
        relaycfg.write_machine(link_payload(api_url="http://127.0.0.1:8787"))
        self.assertEqual(relaycfg.read_machine()["api_url"], "http://127.0.0.1:8787")

    def test_mask(self):
        self.assertEqual(relaycfg.mask(CRED), "cm1_…wxyz")


class UrlTest(Env):
    def test_https_to_wss(self):
        self.assertEqual(relaycfg.ws_url("https://api.example.test"), "wss://api.example.test/v1/connect")
        self.assertEqual(relaycfg.ws_url("https://api.example.test/"), "wss://api.example.test/v1/connect")
        self.assertEqual(relaycfg.ws_url("http://127.0.0.1:8787"), "ws://127.0.0.1:8787/v1/connect")

    def test_legacy_urls_kept(self):
        for u in ("wss://relay.example.test/v1/connect", "wss://relay.example.test", "https://relay.example.test/v1/connect"):
            self.assertEqual(relaycfg.ws_url(u), u)

    def test_empty_and_invalid(self):
        self.assertEqual(relaycfg.ws_url(""), "")
        with self.assertRaises(relaycfg.RelayCfgError):
            relaycfg.ws_url("api.example.test")

    def test_env_url_used_without_machine(self):
        with mock.patch.dict(os.environ, {"CHOPSHOP_RELAY__URL": "https://env.example.test"}):
            self.assertEqual(relaycfg.api_url(), "https://env.example.test")

    def test_machine_file_wins_over_config(self):
        relaycfg.write_machine(link_payload())
        with mock.patch.dict(os.environ, {"CHOPSHOP_RELAY__URL": "https://env.example.test"}):
            self.assertEqual(relaycfg.api_url(), "https://api.example.test")


class CliTest(Env):
    def test_link_status_unlink(self):
        code, out, err = self.run_cli(["link", "--stdin"], json.dumps(link_payload()))
        self.assertEqual(code, 0, err)
        self.assertIn("cm1_…wxyz", out)
        self.assertNotIn(CRED, out + err)
        code, out, err = self.run_cli(["status"])
        self.assertEqual(code, 0, err)
        self.assertIn("api: https://api.example.test", out)
        self.assertIn("websocket: wss://api.example.test/v1/connect", out)
        self.assertIn(MID, out)
        self.assertIn("cm1_…wxyz", out)
        self.assertIn("permisos 600, directorio 700", out)
        self.assertNotIn(CRED, out + err)
        code, out, _ = self.run_cli(["unlink"])
        self.assertEqual(code, 0)
        self.assertIn("revoca", out)
        self.assertFalse(os.path.exists(relaycfg.machine_path()))
        code, out, _ = self.run_cli(["unlink"])
        self.assertIn("no había", out)

    def test_link_api_flag_overrides(self):
        code, _, err = self.run_cli(["link", "--stdin", "--api", "https://other.example.test"], json.dumps(link_payload()))
        self.assertEqual(code, 0, err)
        self.assertEqual(relaycfg.read_machine()["api_url"], "https://other.example.test")

    def test_link_falls_back_to_config_url(self):
        d = link_payload()
        del d["api_url"]
        with mock.patch.dict(os.environ, {"CHOPSHOP_RELAY__URL": "https://env.example.test"}):
            code, _, err = self.run_cli(["link", "--stdin"], json.dumps(d))
        self.assertEqual(code, 0, err)
        self.assertEqual(relaycfg.read_machine()["api_url"], "https://env.example.test")

    def test_link_rejects_bad_input(self):
        for raw in ("no json", "[]", json.dumps(link_payload(credential="cm1_short"))):
            code, out, err = self.run_cli(["link", "--stdin"], raw)
            self.assertEqual(code, 1)
            self.assertIn("error:", err)
        code, _, err = self.run_cli(["link"])
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(relaycfg.machine_path()))

    def test_status_warns_on_loose_permissions(self):
        relaycfg.write_machine(link_payload())
        os.chmod(relaycfg.machine_path(), 0o644)
        code, out, err = self.run_cli(["status"])
        self.assertEqual(code, 0)
        self.assertIn("aviso", err)
        self.assertNotIn(CRED, out + err)

    def test_status_corrupt_machine(self):
        os.makedirs(os.path.dirname(relaycfg.machine_path()), mode=0o700)
        with open(relaycfg.machine_path(), "w") as f:
            json.dump(dict(link_payload(credential="cm1_bad"), v=1, linked_at="x"), f)
        code, out, err = self.run_cli(["status"])
        self.assertEqual(code, 1)
        self.assertNotIn("cm1_bad", out + err)

    def test_status_without_link_falls_back_to_legacy(self):
        code, out, _ = self.run_cli(["status"])
        self.assertEqual(code, 1)
        self.assertIn("token: no emparejado", out)


if __name__ == "__main__":
    unittest.main()
