import ipaddress
import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import minitoml, settings  # noqa: E402
from chopshop.agent import config as agent_config  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
EXAMPLE = os.path.join(ROOT, "config.example.toml")

# Patrones genéricos de datos personales. Direcciones permitidas: rangos documentales (RFC 5737 / CGNAT 100.64.0.0/24) y loopback.
PERSONAL = {
    "ruta de usuario": re.compile(r"/Volumes/|/Users/|/home/[a-z]"),
    "dominio de tailnet": re.compile(r"\.ts\.net\b"),
    "correo": re.compile(r"[\w.+-]+@[\w-]+\.(?:com|ai|dev|net|org|io|app)\b", re.I),
    "URL de webhook": re.compile(r"hooks\.slack\.com|discord(?:app)?\.com/api/webhooks|/webhook[s]?/[\w-]{16,}", re.I),
}
IPV4 = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w.])")
DOC_NETS = [ipaddress.ip_network(n) for n in ("100.64.0.0/24", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
                                              "127.0.0.0/8", "0.0.0.0/32")]


def personal_findings(text):
    out = [name for name, rx in PERSONAL.items() if rx.search(text)]
    for m in IPV4.finditer(text):
        try:
            ip = ipaddress.ip_address(m.group(1))
        except ValueError:
            continue
        if not any(ip in n for n in DOC_NETS):
            out.append("IP no documental " + m.group(1))
    return out


def flatten_keys(d, prefix=""):
    for k, v in d.items():
        yield prefix + k
        if isinstance(v, dict):
            yield from flatten_keys(v, prefix + k + ".")


SAMPLE = '''# comentario
[general]
default_host = "uno"   # trailing
[hosts.uno]
cap = 3
list = [1, 2,
  3]
inl = {a = 1, "b c" = 'lit'}
flag = true
ratio = 1.5
"q.k".z = "x\\ty"
[agent]
port = 4000
allowed_logins = ["a@", "b@"]
[agent.service]
read_write_paths = ["/srv/a", "/srv/b"]
'''


class TestMiniToml(unittest.TestCase):
    def test_parser_equals_tomllib(self):
        got = minitoml._Parser(SAMPLE).parse()
        self.assertEqual(got["hosts"]["uno"]["list"], [1, 2, 3])
        self.assertEqual(got["hosts"]["uno"]["q.k"]["z"], "x\ty")
        try:
            import tomllib
        except ImportError:
            return
        self.assertEqual(got, tomllib.loads(SAMPLE))

    def test_errors(self):
        for bad in ("a = \n", "[x\n", "a = 1\na = 2\n", "[[x]]\n", 'a = """x"""\n'):
            with self.assertRaises(minitoml.TomlError):
                minitoml._Parser(bad).parse()


class TestSettings(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.saved = {k: v for k, v in os.environ.items() if k.startswith("CHOPSHOP_")}
        for k in self.saved:
            del os.environ[k]
        os.environ["CHOPSHOP_CONFIG"] = os.path.join(self.tmp, "config.toml")

    def tearDown(self):
        for k in [k for k in os.environ if k.startswith("CHOPSHOP_")]:
            del os.environ[k]
        os.environ.update(self.saved)

    def write(self, text):
        with open(os.environ["CHOPSHOP_CONFIG"], "w") as f:
            f.write(text)

    def test_defaults_are_generic(self):
        c = settings.load()
        self.assertEqual(list(c["hosts"]), ["local"])
        self.assertEqual(c["agent"]["owner_login"], "")
        self.assertEqual(c["general"]["overflow_host"], "")
        self.assertEqual(personal_findings(repr(c)), [])
        self.assertEqual(c["app"]["agent_url"], "")
        self.assertEqual(c["agent"]["webhook_files"], {})

    def test_file_and_env_override(self):
        self.write(SAMPLE)
        c = settings.load()
        self.assertEqual(list(c["hosts"]), ["uno"])           # [hosts.*] reemplaza al host genérico
        self.assertEqual(c["agent"]["port"], 4000)
        self.assertEqual(c["agent"]["sample_interval"], 10)       # el resto, por defecto
        os.environ["CHOPSHOP_AGENT__PORT"] = "4100"
        os.environ["CHOPSHOP_HOSTS__UNO__CAP"] = "9"
        os.environ["CHOPSHOP_AGENT__ALLOWED_LOGINS"] = '["z@"]'
        os.environ["CHOPSHOP_GENERAL__OVERFLOW_HOST"] = "otro"
        c = settings.load()
        self.assertEqual(c["agent"]["port"], 4100)
        self.assertEqual(c["hosts"]["uno"]["cap"], 9)
        self.assertEqual(c["agent"]["allowed_logins"], ["z@"])
        self.assertEqual(c["general"]["overflow_host"], "otro")

    def test_t3_defaults_and_old_keys(self):
        c = settings.load()
        self.assertEqual(c["hosts"]["local"], {"cap": 2, "purpose": "dev", "t3_bin": "t3", "access": "approval-required"})
        self.assertEqual(c["agent"]["t3"], {"origin": "", "t3_bin": "t3", "access": "full-access", "credential_file": ""})
        self.assertNotIn("fleet_bin", c["general"])
        # config vieja: transport/node/helper/fleet_bin se leen sin error y no afectan al cliente
        self.write('[general]\nfleet_bin = "/opt/fleet"\n[hosts.uno]\ntransport = "fleet"\nnode = "node"\n'
                   'helper = "~/x/t3mcp.mjs"\ncap = 3\n[agent.t3]\nhelper = "~/x/t3mcp.mjs"\nnode = "node"\n')
        c = settings.load()
        self.assertEqual(c["hosts"]["uno"]["cap"], 3)
        self.assertEqual(c["agent"]["t3"]["t3_bin"], "t3")
        from chopshop import t3
        self.assertTrue(t3.is_local(c["hosts"]["uno"]))

    def test_bad_file_raises(self):
        self.write("a = \n")
        with self.assertRaises(settings.SettingsError):
            settings.load()

    def test_agent_config_uses_settings(self):
        self.write('[agent]\nmachine_id = "m1"\nowner_login = "yo@"\n')
        cfg = agent_config.load()
        self.assertEqual((cfg["machine_id"], cfg["owner_login"]), ("m1", "yo@"))
        self.assertTrue(cfg["db_path"].startswith(os.path.expanduser("~")))


class TestExampleConfig(unittest.TestCase):
    def setUp(self):
        self.saved = {k: v for k, v in os.environ.items() if k.startswith("CHOPSHOP_")}
        for k in self.saved:
            del os.environ[k]
        os.environ["CHOPSHOP_CONFIG"] = EXAMPLE

    def tearDown(self):
        for k in [k for k in os.environ if k.startswith("CHOPSHOP_")]:
            del os.environ[k]
        os.environ.update(self.saved)

    def test_loads_and_covers_every_default_key(self):
        c = settings.load(force=True)
        example = minitoml.load(EXAMPLE)
        # [agent.projects.*] y [agent.webhook_files] son mapas libres: basta con que la clave exista y traiga un ejemplo
        for key in flatten_keys(settings.DEFAULTS):
            if key.startswith("hosts."):
                continue
            node = example
            for part in key.split("."):
                self.assertIn(part, node, "falta %s en config.example.toml" % key)
                node = node[part]
        self.assertEqual(sorted(c["hosts"]), ["host-a", "host-b"])
        self.assertEqual(c["agent"]["owner_login"], "usuario@")
        self.assertIn("proyecto-demo", c["agent"]["projects"])
        self.assertTrue(c["general"]["default_host"] in c["hosts"] and c["general"]["overflow_host"] in c["hosts"])

    def test_example_has_no_personal_data(self):
        with open(EXAMPLE, encoding="utf-8") as f:
            text = f.read()
        self.assertEqual(personal_findings(text), [])
        # los webhooks son rutas a archivos, nunca URLs
        self.assertNotRegex(text, r"https?://(?!100\.64\.0\.)")
        for name, path in settings.load()["agent"]["webhook_files"].items():
            self.assertFalse(path.startswith(("http://", "https://")), name)

    def test_example_is_not_gitignored_but_config_toml_is(self):
        with open(os.path.join(ROOT, ".gitignore"), encoding="utf-8") as f:
            lines = [l.strip() for l in f]
        self.assertIn("config.toml", lines)
        self.assertNotIn("config.example.toml", lines)


class TestRepoHasNoPersonalData(unittest.TestCase):
    """Recorre agente, UI, app Mac, paquetes, docs, ejemplos, herramientas, unidades systemd y scripts (más README y config de ejemplo): nada de rutas de usuario, IPs reales, correos ni URLs de webhook."""
    AREAS = ("apps/agent", "apps/ui", "apps/mac", "packages", "docs", "examples", "tools", "systemd", "scripts", ".github")
    FILES = ("README.md", "config.example.toml")
    SKIP_DIRS = {"node_modules", "__pycache__", ".turbo", ".git", "dist", ".build"}
    SELF = os.path.abspath(__file__)

    def test_scan(self):
        files = []
        for area in self.AREAS:
            for dirpath, dirs, names in os.walk(os.path.join(ROOT, area)):
                dirs[:] = [d for d in dirs if d not in self.SKIP_DIRS]
                files += [os.path.join(dirpath, n) for n in names if os.path.join(dirpath, n) != self.SELF]
        files += [os.path.join(ROOT, n) for n in self.FILES if os.path.isfile(os.path.join(ROOT, n))]
        if not files:
            self.skipTest("fuera del monorepo")
        bad = []
        for p in files:
            try:
                with open(p, encoding="utf-8") as f:
                    text = f.read()
            except (UnicodeDecodeError, OSError):
                continue
            bad += ["%s: %s" % (os.path.relpath(p, ROOT), x) for x in personal_findings(text)]
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
