"""Pruebas del pipeline de release de la app Mac (sin credenciales ni macOS).

Ejecutan los scripts REALES de apps/mac/release con ejecutables falsos delante en PATH (ver fakes.py) y revisan
los workflows de GitHub Actions. Datos ficticios: hosts example.*, claves de juguete, Team ID de mentira.

    cd apps/mac && python3 -m unittest discover -s release/tests
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakes  # noqa: E402

try:
    import yaml
except ImportError:  # pragma: no cover - sin PyYAML solo se hacen las comprobaciones de texto
    yaml = None

RELEASE = fakes.RELEASE
MAC = os.path.dirname(RELEASE)
ROOT = os.path.dirname(os.path.dirname(MAC))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
appcast = fakes.appcast

SIGN_SECRETS = ["MACOS_CERT_P12_BASE64", "MACOS_CERT_PASSWORD", "KEYCHAIN_PASSWORD",
                "ASC_API_KEY_P8_BASE64", "ASC_API_KEY_ID", "ASC_API_ISSUER_ID"]
PUBLISH_SECRETS = ["SPARKLE_ED_PRIVATE_KEY", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"]
REQUIRED_VARS = ["APPLE_TEAM_ID", "BUNDLE_ID", "SIGNING_IDENTITY", "SPARKLE_ED_PUBLIC_KEY", "R2_ACCOUNT_ID", "R2_BUCKET", "UPDATES_BASE_URL"]
R2_ACCOUNT = "0123456789abcdef0123456789abcdef"  # ficticio
ALL_SECRETS = SIGN_SECRETS + PUBLISH_SECRETS


def read(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as f:
        return f.read()


def slurp(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def spit(path, data, mode="w"):
    with open(path, mode) as f:
        f.write(data)


def release_scripts():
    return sorted(f for f in os.listdir(RELEASE) if f.endswith(".sh"))


class WorkDir(unittest.TestCase):
    """Directorio temporal con shims instalados y un log compartido."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-release-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = fakes.install_shims(os.path.join(self.tmp, "bin"))
        self.log = os.path.join(self.tmp, "shim.log")
        self.base_env = {"SHIM_LOG": self.log, "RELEASE_DIR": RELEASE, "RUNNER_TEMP": self.tmp,
                         "PLISTBUDDY": os.path.join(self.bin, "PlistBuddy")}

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as f:
            return f.read().splitlines()

    def run_sh(self, script, args=(), env=None, cwd=None):
        e = dict(self.base_env)
        e.update(env or {})
        return fakes.run_script(script, args, env=e, cwd=cwd, shims=self.bin)


# ---------------------------------------------------------------------------
class TestVersion(WorkDir):
    def version(self, ref_type, name, *flags, env=None):
        r = self.run_sh("version.sh", ["--ref-type", ref_type, "--ref-name", name, *flags], env=env)
        out = dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l)
        return r, out

    def test_stable_tag(self):
        r, out = self.version("tag", "v1.2.3", env={"BUILD_NUMBER": "202610281200"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((out["short_version"], out["channel"], out["prerelease"], out["build_number"]),
                         ("1.2.3", "", "false", "202610281200"))

    def test_beta_tag_uses_beta_channel(self):
        r, out = self.version("tag", "v1.2.3-beta.4")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((out["short_version"], out["channel"], out["prerelease"]), ("1.2.3-beta.4", "beta", "true"))

    def test_build_number_is_monotonic_utc_timestamp(self):
        _, out = self.version("tag", "v1.0.0")
        self.assertRegex(out["build_number"], r"^\d{12}$")

    def test_invalid_tags_fail(self):
        for bad in ("v1.2", "1.2.3", "v01.2.3", "v1.2.3+meta", "vfoo", "v1.2.3-", "v1.2.3-01"):
            r, _ = self.version("tag", bad)
            self.assertNotEqual(r.returncode, 0, bad)

    def test_branch_only_allowed_in_dry_run(self):
        r, _ = self.version("branch", "main")
        self.assertNotEqual(r.returncode, 0)
        r, out = self.version("branch", "main", "--dry-run")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(out["short_version"], "0.0.0-dryrun")

    def test_non_numeric_build_number_rejected(self):
        r, _ = self.version("tag", "v1.0.0", env={"BUILD_NUMBER": "abc"})
        self.assertNotEqual(r.returncode, 0)


# ---------------------------------------------------------------------------
class TestPreflight(WorkDir):
    GOOD_VARS = {"APPLE_TEAM_ID": "ABCDE12345", "BUNDLE_ID": "org.example.chopshop", "SIGNING_IDENTITY": "Developer ID Application: Nombre Demo (ABCDE12345)",
                 "SPARKLE_ED_PUBLIC_KEY": fakes.PUBLIC_B64, "R2_ACCOUNT_ID": R2_ACCOUNT, "R2_BUCKET": "bucket-demo",
                 "UPDATES_BASE_URL": "https://updates.example.com"}
    FLAGS = {n: "set" for n in SIGN_SECRETS + PUBLISH_SECRETS}  # el workflow pasa un indicador, nunca el valor

    def good(self, **over):
        env = dict(self.GOOD_VARS, **self.FLAGS)
        env.update(over)
        return env

    def test_everything_defined_passes(self):
        self.assertEqual(self.run_sh("preflight.sh", ["release"], env=self.good()).returncode, 0)

    def test_lists_ALL_missing_names_without_values(self):
        env = {k: v for k, v in self.good().items() if k not in ("MACOS_CERT_P12_BASE64", "ASC_API_KEY_ID", "R2_SECRET_ACCESS_KEY", "BUNDLE_ID", "APPLE_TEAM_ID")}
        env["MACOS_CERT_PASSWORD"] = "valor-secreto-123"
        r = self.run_sh("preflight.sh", ["release"], env=env)
        self.assertEqual(r.returncode, 1)
        for name in ("MACOS_CERT_P12_BASE64", "ASC_API_KEY_ID", "R2_SECRET_ACCESS_KEY", "BUNDLE_ID", "APPLE_TEAM_ID"):
            self.assertIn(name, r.stderr)
        self.assertIn("Faltan 5 secret(s)/variable(s)", r.stderr)
        self.assertNotIn("valor-secreto-123", r.stdout + r.stderr)
        self.assertNotIn("MACOS_CERT_PASSWORD", r.stderr)  # esa sí estaba definida

    def test_nothing_defined_lists_the_exact_required_names(self):
        r = self.run_sh("preflight.sh", ["release"])
        self.assertEqual(r.returncode, 1)
        listed = re.search(r"requeridos: (.*?)\. Créalos", r.stderr).group(1)
        names = sorted(re.findall(r"([A-Z0-9_]+) \((?:secret|var)\)", listed))
        self.assertEqual(names, sorted(REQUIRED_VARS + SIGN_SECRETS + PUBLISH_SECRETS))

    def test_rollback_scope_only_needs_publishing_values(self):
        env = {k: v for k, v in self.good().items() if k not in SIGN_SECRETS + ["APPLE_TEAM_ID", "BUNDLE_ID", "SIGNING_IDENTITY"]}
        self.assertEqual(self.run_sh("preflight.sh", ["rollback"], env=env).returncode, 0)

    def test_formats(self):
        for key, bad in (("SPARKLE_ED_PUBLIC_KEY", "AAAA"), ("UPDATES_BASE_URL", "http://updates.example.com"), ("APPLE_TEAM_ID", "abc"),
                         ("R2_ACCOUNT_ID", "xyz"), ("SIGNING_IDENTITY", "Apple Development: Nombre Demo (ABCDE12345)"),
                         ("SIGNING_IDENTITY", "Developer ID Application: Nombre Demo (ZZZZZ99999)")):
            r = self.run_sh("preflight.sh", ["release"], env=self.good(**{key: bad}))
            self.assertEqual(r.returncode, 1, key + "=" + bad)

    def test_identity_may_be_a_sha1_hash(self):
        self.assertEqual(self.run_sh("preflight.sh", ["release"], env=self.good(SIGNING_IDENTITY="0123456789ABCDEF0123456789ABCDEF01234567")).returncode, 0)

    def test_empty_public_key_fails_release(self):
        r = self.run_sh("preflight.sh", ["release"], env=self.good(SPARKLE_ED_PUBLIC_KEY=""))
        self.assertEqual(r.returncode, 1)
        self.assertIn("SPARKLE_ED_PUBLIC_KEY", r.stderr)

    def test_generic_bundle_id_blocks_release_but_not_dry_run(self):
        env = self.good(BUNDLE_ID="com.example.chopshop")
        self.assertEqual(self.run_sh("preflight.sh", ["release"], env=env).returncode, 1)
        env["PREFLIGHT_MODE"] = "dryrun"
        self.assertEqual(self.run_sh("preflight.sh", ["release"], env=env).returncode, 0)

    def test_dry_run_never_fails_on_missing(self):
        r = self.run_sh("preflight.sh", ["release"], env={"PREFLIGHT_MODE": "dryrun"})
        self.assertEqual(r.returncode, 0)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY", r.stderr)  # avisa, no falla


# ---------------------------------------------------------------------------
class TestEd25519AndAppcast(WorkDir):
    def test_rfc8032_vector_1(self):
        seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        pub = appcast.ed25519_public_from_seed(seed)
        self.assertEqual(pub.hex(), "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        sig = bytes.fromhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46"
                            "bd25bf5f0595bbe24655141438e7a100b")
        self.assertTrue(appcast.ed25519_verify(pub, b"", sig))
        self.assertFalse(appcast.ed25519_verify(pub, b"x", sig))

    def test_sign_verify_roundtrip_and_tamper(self):
        pub = base64_decode(fakes.PUBLIC_B64)
        sig = fakes.ed25519_sign(fakes.SEED, b"contenido")
        self.assertTrue(appcast.ed25519_verify(pub, b"contenido", sig))
        self.assertFalse(appcast.ed25519_verify(pub, b"contenidO", sig))

    def test_public_from_secret_formats(self):
        self.assertEqual(appcast.public_from_sparkle_secret(fakes.SECRET_B64), base64_decode(fakes.PUBLIC_B64))
        old = base64_encode(bytes(64) + base64_decode(fakes.PUBLIC_B64))  # formato antiguo: 96 bytes
        self.assertEqual(appcast.public_from_sparkle_secret(old), base64_decode(fakes.PUBLIC_B64))
        with self.assertRaises(ValueError):
            appcast.public_from_sparkle_secret(base64_encode(b"corta"))

    def test_check_key_cli(self):
        p = subprocess.run([sys.executable, "-I", os.path.join(RELEASE, "appcast.py"), "check-key", "--public", fakes.PUBLIC_B64],
                           input=fakes.SECRET_B64, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        otra = base64_encode(appcast.ed25519_public_from_seed(bytes(32)))
        p = subprocess.run([sys.executable, "-I", os.path.join(RELEASE, "appcast.py"), "check-key", "--public", otra],
                           input=fakes.SECRET_B64, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertNotIn(fakes.SECRET_B64, p.stdout + p.stderr)

    def feed(self, items, d):
        os.makedirs(d, exist_ok=True)
        body = ""
        for build, short, name in items:
            data = ("zip-" + short).encode()
            with open(os.path.join(d, name), "wb") as f:
                f.write(data)
            sig = base64_encode(fakes.ed25519_sign(fakes.SEED, data))
            body += ('<item><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString>'
                     '<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>'
                     '<enclosure url="https://updates.example.com/%s" length="%d" sparkle:edSignature="%s"/></item>'
                     % (build, short, name, len(data), sig))
        with open(os.path.join(d, "appcast.xml"), "w") as f:
            f.write('<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
                    "<channel><title>x</title>%s</channel></rss><!-- sparkle-signatures: demo -->" % body)

    def cli(self, *args):
        return subprocess.run([sys.executable, "-I", os.path.join(RELEASE, "appcast.py"), *args], capture_output=True, text=True)

    def test_check_new_rules(self):
        d = os.path.join(self.tmp, "feed")
        self.feed([("202610010000", "1.0.0", "Chopshop-1.0.0.zip")], d)
        new = os.path.join(self.tmp, "Chopshop-1.1.0.zip")
        spit(new, b"nuevo", "wb")
        ok = self.cli("check-new", "--dir", d, "--archive", new, "--version", "1.1.0", "--build", "202610020000")
        self.assertEqual(ok.returncode, 0, ok.stderr)
        # build no monotónico
        low = self.cli("check-new", "--dir", d, "--archive", new, "--version", "1.1.0", "--build", "202609010000")
        self.assertEqual(low.returncode, 1)
        self.assertIn("no es mayor", low.stderr)
        # misma versión con otro contenido: no se pisa
        other = os.path.join(self.tmp, "Chopshop-1.0.0.zip")
        spit(other, b"distinto", "wb")
        dup = self.cli("check-new", "--dir", d, "--archive", other, "--version", "1.0.0", "--build", "202610030000")
        self.assertEqual(dup.returncode, 1)
        # misma versión idéntica: reintento idempotente (código 3)
        spit(other, b"zip-1.0.0", "wb")
        same = self.cli("check-new", "--dir", d, "--archive", other, "--version", "1.0.0", "--build", "202610010000")
        self.assertEqual(same.returncode, 3, same.stderr)

    def test_verify_detects_wrong_key_missing_file_and_unsigned_feed(self):
        d = os.path.join(self.tmp, "feed")
        self.feed([("202610010000", "1.0.0", "Chopshop-1.0.0.zip")], d)
        base = ["verify", "--dir", d, "--base-url", "https://updates.example.com", "--version", "1.0.0", "--build", "202610010000",
                "--min-system", "13.0", "--public", fakes.PUBLIC_B64, "--require-signed-feed"]
        self.assertEqual(self.cli(*base).returncode, 0)
        wrong = base[:base.index("--public") + 1] + [base64_encode(appcast.ed25519_public_from_seed(bytes(32)))] + base[base.index("--public") + 2:]
        r = self.cli(*wrong)
        self.assertEqual(r.returncode, 1)
        self.assertIn("NO coincide", r.stderr)
        r = self.cli(*(base[:-1] + ["--min-system", "26.0", "--require-signed-feed"]))
        self.assertEqual(r.returncode, 1)  # minimumSystemVersion 13.0 != 26.0 esperado
        os.remove(os.path.join(d, "Chopshop-1.0.0.zip"))
        self.assertEqual(self.cli(*base).returncode, 1)

    def test_find_remove_list_files(self):
        d = os.path.join(self.tmp, "feed")
        self.feed([("202610020000", "1.1.0", "Chopshop-1.1.0.zip"), ("202610010000", "1.0.0", "Chopshop-1.0.0.zip")], d)
        info = json.loads(self.cli("find", "--appcast", os.path.join(d, "appcast.xml"), "--version", "1.0.0").stdout)
        self.assertEqual((info["build"], info["remaining"], info["files"]), ("202610010000", 1, ["Chopshop-1.0.0.zip"]))
        self.assertEqual(self.cli("find", "--appcast", os.path.join(d, "appcast.xml"), "--version", "9.9.9").returncode, 1)
        names = self.cli("list-files", "--appcast", os.path.join(d, "appcast.xml")).stdout.split()
        self.assertEqual(names, ["Chopshop-1.1.0.zip", "Chopshop-1.0.0.zip"])
        self.assertEqual(self.cli("remove-item", "--appcast", os.path.join(d, "appcast.xml"), "--version", "1.0.0").returncode, 0)
        self.assertEqual([i["short"] for i in appcast.load_items(os.path.join(d, "appcast.xml"))], ["1.1.0"])
        self.assertEqual(self.cli("max-build", "--appcast", os.path.join(d, "appcast.xml")).stdout.strip(), "202610020000")


def base64_decode(s):
    import base64
    return base64.b64decode(s)


def base64_encode(b):
    import base64
    return base64.b64encode(b).decode()


# ---------------------------------------------------------------------------
class TestNotes(WorkDir):
    def test_changelog_section(self):
        text = "# Cambios\n## [1.2.3] - 2026-10-01\n- uno\n- dos\n\n## [1.2.2]\n- viejo\n"
        sys.path.insert(0, RELEASE)
        spec = __import__("importlib.util").util.spec_from_file_location("notes_mod", os.path.join(RELEASE, "notes.py"))
        mod = __import__("importlib.util").util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertEqual(mod.changelog_section(text, "1.2.3"), "- uno\n- dos")
        self.assertEqual(mod.changelog_section(text, "9.9.9"), "")

    def test_html_is_escaped(self):
        p = subprocess.run([sys.executable, "-I", os.path.join(RELEASE, "notes.py"), "html"],
                           input="# Título\n- **a** <script>alert(1)</script> [x](javascript:alert(1)) [ok](https://example.org/p)\n```\n<b>\n```\n",
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("<script>", p.stdout)
        self.assertNotIn('href="javascript', p.stdout)
        self.assertIn('<a href="https://example.org/p">ok</a>', p.stdout)
        self.assertIn("&lt;b&gt;", p.stdout)

    def git_repo(self):
        repo = os.path.join(self.tmp, "repo")
        os.makedirs(repo)
        env = dict(os.environ, GIT_AUTHOR_NAME="Demo", GIT_AUTHOR_EMAIL="ci@invalid.test", GIT_COMMITTER_NAME="Demo",
                   GIT_COMMITTER_EMAIL="ci@invalid.test")
        for cmd in (["git", "init", "-q"], ["git", "commit", "-q", "--allow-empty", "-m", "primer cambio"],
                    ["git", "tag", "v1.0.0"], ["git", "commit", "-q", "--allow-empty", "-m", "arreglo visible"]):
            subprocess.run(cmd, cwd=repo, env=env, check=True)
        return repo, env

    def test_notes_from_annotated_tag_and_commit_fallback(self):
        repo, env = self.git_repo()
        subprocess.run(["git", "tag", "v1.1.0"], cwd=repo, env=env, check=True)  # ligero: cae a los commits
        out = os.path.join(self.tmp, "out")
        r = self.run_sh("notes.sh", ["v1.1.0", out, "Chopshop-1.1.0"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("arreglo visible", slurp(os.path.join(out, "Chopshop-1.1.0.html")))
        self.assertNotIn("primer cambio", slurp(os.path.join(out, "notes", "1.1.0.md")))
        subprocess.run(["git", "tag", "-a", "--cleanup=verbatim", "v1.2.0", "-m", "## Novedades\n- algo importante"], cwd=repo, env=env, check=True)
        r = self.run_sh("notes.sh", ["v1.2.0", out, "Chopshop-1.2.0"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("mensaje del tag", r.stdout)
        page = slurp(os.path.join(out, "notes", "1.2.0.html"))
        self.assertIn("<h3>Novedades</h3>", page)
        self.assertTrue(page.startswith("<!DOCTYPE html>"))
        self.assertNotIn("<!DOCTYPE", slurp(os.path.join(out, "Chopshop-1.2.0.html")))  # fragmento: se incrusta en el feed


# ---------------------------------------------------------------------------
class TestKeychain(WorkDir):
    ENV = {"MACOS_CERT_P12_BASE64": "UDEyLWRlLXBydWViYQ==", "MACOS_CERT_PASSWORD": "pw-del-p12-ficticia", "KEYCHAIN_PASSWORD": "kc-pw-ficticia",
           "SIGNING_IDENTITY": "Developer ID Application: Nombre Demo (ABCDE12345)", "APPLE_TEAM_ID": "ABCDE12345"}

    def test_setup_orders_calls_masks_and_never_prints_secrets(self):
        github_env = os.path.join(self.tmp, "github_env")
        env = dict(self.ENV, GITHUB_ENV=github_env)
        r = self.run_sh("keychain.sh", ["setup"], env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout + r.stderr
        for secret in ("pw-del-p12-ficticia", "kc-pw-ficticia", self.ENV["MACOS_CERT_P12_BASE64"]):
            self.assertNotIn(secret, out.replace("::add-mask::kc-pw-ficticia", ""))
        self.assertIn("::add-mask::kc-pw-ficticia", out)
        self.assertIn("::add-mask::Developer ID Application: Nombre Demo (ABCDE12345)", out)
        self.assertIn("::add-mask::ABCDE12345", out)
        names = [c.split()[1] for c in self.calls() if c.startswith("security ")]
        order = ["create-keychain", "set-keychain-settings", "unlock-keychain", "import", "set-key-partition-list"]
        idx = [names.index(n) for n in order]
        self.assertEqual(idx, sorted(idx))
        search_list = [c for c in self.calls() if c.startswith("security list-keychains")]
        self.assertEqual(len(search_list), 2)  # una lectura previa (para restaurar) y la reescritura con -s
        self.assertIn(" -s ", search_list[-1])
        self.assertIn("import-p12-existed-at-import yes", self.calls())
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "chopshop-cert.p12")), "el .p12 no debe quedar en disco")
        exported = read(github_env)
        self.assertRegex(exported, r"SIGN_IDENTITY=[0-9A-F]{40}\n")
        self.assertNotIn("Nombre Demo", exported)
        self.assertIn("SIGN_KEYCHAIN=", exported)

    def test_keychain_password_is_required(self):
        env = {k: v for k, v in self.ENV.items() if k != "KEYCHAIN_PASSWORD"}
        r = self.run_sh("keychain.sh", ["setup"], env=env)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("KEYCHAIN_PASSWORD", r.stderr)
        self.assertFalse(any(c.startswith("security create-keychain") for c in self.calls()))

    def test_identity_must_match_and_be_unambiguous_and_of_the_team(self):
        r = self.run_sh("keychain.sh", ["setup"], env=dict(self.ENV, FAKE_IDENTITIES="2"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("2 identidades", r.stderr)
        r = self.run_sh("keychain.sh", ["setup"], env=dict(self.ENV, SIGNING_IDENTITY="Developer ID Application: Otro Nombre (ZZZZZ99999)", APPLE_TEAM_ID="ZZZZZ99999"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("SIGNING_IDENTITY", r.stderr)
        r = self.run_sh("keychain.sh", ["setup"], env=dict(self.ENV, APPLE_TEAM_ID="ZZZZZ99999"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("APPLE_TEAM_ID", r.stderr)

    def test_identity_can_be_selected_by_hash(self):
        gh = os.path.join(self.tmp, "ge")
        r = self.run_sh("keychain.sh", ["setup"], env=dict(self.ENV, SIGNING_IDENTITY="0000000000000000000000000000000000000001", GITHUB_ENV=gh))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("SIGN_IDENTITY=0000000000000000000000000000000000000001", read(gh))

    def test_cleanup_always_deletes_keychain_and_credentials(self):
        self.run_sh("keychain.sh", ["setup"], env=self.ENV)
        stray = os.path.join(self.tmp, "chopshop-notary-999.p8")
        spit(stray, "x", "w")
        r = self.run_sh("keychain.sh", ["cleanup"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any(c.startswith("security delete-keychain") for c in self.calls()))
        self.assertFalse(os.path.exists(stray))
        self.assertEqual(self.run_sh("keychain.sh", ["cleanup"]).returncode, 0)  # idempotente


# ---------------------------------------------------------------------------
class TestSignAndNotarize(WorkDir):
    MACHO = bytes.fromhex("cffaedfe") + b"\0" * 32

    def make_app(self):
        app = os.path.join(self.tmp, "Chopshop.app")
        files = ["Contents/MacOS/Chopshop",
                 "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
                 "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
                 "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
                 "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
                 "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"]
        for f in files:
            p = os.path.join(app, f)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            spit(p, self.MACHO, "wb")
        os.makedirs(os.path.join(app, "Contents/Resources"), exist_ok=True)
        spit(os.path.join(app, "Contents/Resources/script.py"), "#!/usr/bin/env python3\n", "w")
        spit(os.path.join(app, "Contents/Info.plist"), '{"CFBundleExecutable": "Chopshop"}')
        os.symlink("B", os.path.join(app, "Contents/Frameworks/Sparkle.framework/Versions/Current"))
        return app

    def signed_paths(self):
        return [c.split()[-1] for c in self.calls() if c.startswith("codesign --force")]

    def test_sign_order_inside_out_with_hardened_runtime(self):
        app = self.make_app()
        r = self.run_sh("sign-app.sh", [app], env={"SIGN_IDENTITY": "0123456789ABCDEF0123456789ABCDEF01234567", "SIGN_KEYCHAIN": "/tmp/fake.kc"})
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        paths = [os.path.relpath(p, app) for p in self.signed_paths()]
        fw = "Contents/Frameworks/Sparkle.framework"
        pos = {p: i for i, p in enumerate(paths)}
        for helper in (fw + "/Versions/B/XPCServices/Installer.xpc", fw + "/Versions/B/XPCServices/Downloader.xpc",
                       fw + "/Versions/B/Updater.app", fw + "/Versions/B/Autoupdate", fw + "/Versions/B/Sparkle"):
            self.assertLess(pos[helper], pos[fw], helper)
        self.assertLess(pos[fw + "/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"], pos[fw + "/Versions/B/XPCServices/Installer.xpc"])
        self.assertEqual(paths[-1], ".")  # la app, al final
        self.assertNotIn("Contents/MacOS/Chopshop", paths)  # el ejecutable principal lo firma la app
        for c in [c for c in self.calls() if c.startswith("codesign --force")]:
            self.assertIn("--options runtime", c)
            self.assertIn("--timestamp", c)
            self.assertIn("--keychain /tmp/fake.kc", c)
        last = [c for c in self.calls() if c.startswith("codesign --force")][-1]
        self.assertIn("--entitlements", last)
        self.assertTrue(any(c.startswith("codesign --verify --deep --strict --verbose=2") for c in self.calls()))
        self.assertNotIn("Nombre Demo", r.stdout + r.stderr)

    def test_adhoc_signing_skips_timestamp(self):
        app = self.make_app()
        r = self.run_sh("sign-app.sh", [app], env={"SIGN_IDENTITY": "-", "FAKE_TIMESTAMP": "0"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(all("--timestamp=none" in c for c in self.calls() if c.startswith("codesign --force")))

    def test_team_identifier_must_match(self):
        app = self.make_app()
        ok = self.run_sh("sign-app.sh", [app], env={"SIGN_IDENTITY": "ABCD", "APPLE_TEAM_ID": "ABCDE12345"})
        self.assertEqual(ok.returncode, 0, ok.stderr)
        bad = self.run_sh("sign-app.sh", [app], env={"SIGN_IDENTITY": "ABCD", "APPLE_TEAM_ID": "ABCDE12345", "FAKE_TEAM": "ZZZZZ99999"})
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("TeamIdentifier", bad.stderr)

    def test_real_signature_without_timestamp_fails(self):
        r = self.run_sh("sign-app.sh", [self.make_app()], env={"SIGN_IDENTITY": "ABCD", "FAKE_TIMESTAMP": "0"})
        self.assertNotEqual(r.returncode, 0)

    def notary_env(self):
        return {"ASC_API_KEY_P8_BASE64": "cDgtZmljdGljaW8=", "ASC_API_KEY_ID": "KEYID-DEMO", "ASC_API_ISSUER_ID": "issuer-demo-0001"}

    def test_notarize_accepted_staples_then_validates(self):
        app = self.make_app()
        r = self.run_sh("notarize.sh", [app, os.path.join(self.tmp, "submit.zip")], env=self.notary_env())
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        calls = self.calls()
        order = ["xcrun notarytool submit", "xcrun stapler staple", "xcrun stapler validate", "spctl --assess --type execute -vv",
                 "codesign --verify --deep --strict --verbose=2"]
        idx = [next(i for i, c in enumerate(calls) if c.startswith(o)) for o in order]
        self.assertEqual(idx, sorted(idx))
        self.assertIn("--wait", next(c for c in calls if c.startswith("xcrun notarytool submit")))
        self.assertIn("key-file-existed yes", calls)
        self.assertEqual([f for f in os.listdir(self.tmp) if f.startswith("chopshop-notary")], [], "la .p8 temporal debe borrarse")
        out = r.stdout + r.stderr
        self.assertNotIn("Nombre Demo", out)
        self.assertNotIn("ABCDE12345", out)
        for secret in self.notary_env().values():
            self.assertNotIn(secret, out)

    def test_notarize_rejected_prints_log_and_fails(self):
        app = self.make_app()
        r = self.run_sh("notarize.sh", [app, os.path.join(self.tmp, "submit.zip")], env=dict(self.notary_env(), FAKE_NOTARY_STATUS="Invalid"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("notarytool log", r.stdout)
        self.assertIn("El binario no esta firmado", r.stdout)
        self.assertFalse(any(c.startswith("xcrun stapler") for c in self.calls()))
        self.assertEqual([f for f in os.listdir(self.tmp) if f.startswith("chopshop-notary")], [])
        for secret in self.notary_env().values():
            self.assertNotIn(secret, r.stdout + r.stderr)

    def test_package_creates_zip_after_staple_and_checksum(self):
        app = self.make_app()
        zip_path = os.path.join(self.tmp, "dist", "Chopshop-1.0.0.zip")
        r = self.run_sh("package.sh", [app, zip_path], env={"REQUIRE_STAPLE": "1"})
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        ditto = [c for c in self.calls() if c.startswith("ditto -c -k --sequesterRsrc --keepParent")]
        self.assertEqual(len(ditto), 1)
        self.assertTrue(any(c.startswith("xcrun stapler validate") for c in self.calls()))
        self.assertRegex(read(zip_path + ".sha256"), r"^[0-9a-f]{64}  Chopshop-1\.0\.0\.zip\n$")


# ---------------------------------------------------------------------------
class TestAssemble(WorkDir):
    """assemble-app.sh + embed-sparkle.sh con un build.sh, PlistBuddy y otool falsos."""

    def setUp(self):
        super().setUp()
        self.build = os.path.join(self.tmp, "fake-build.sh")
        spit(self.build, "set -euo pipefail\n"
             "mkdir -p \"$CHOPSHOP_APP/Contents/MacOS\" \"$CHOPSHOP_APP/Contents/Resources\"\n"
             "echo '{\"CFBundleExecutable\": \"Chopshop\", \"CFBundleIdentifier\": \"local.chopshop.ui\", \"NSAppTransportSecurity\": 1}' > \"$CHOPSHOP_APP/Contents/Info.plist\"\n"
             "echo bin > \"$CHOPSHOP_APP/Contents/MacOS/Chopshop\"\n")
        self.fw = os.path.join(self.tmp, "Sparkle.framework")
        os.makedirs(os.path.join(self.fw, "Resources"))
        spit(os.path.join(self.fw, "Resources", "Info.plist"), '{"CFBundleShortVersionString": "2.10.1"}')
        self.out = os.path.join(self.tmp, "out", "Chopshop.app")
        self.env = {"BUILD_SCRIPT": self.build, "SPARKLE_FRAMEWORK_SRC": self.fw, "APP_OUT": self.out, "SHORT_VERSION": "1.2.3",
                    "BUILD_NUMBER": "202610281200", "BUNDLE_ID": "org.example.chopshop", "MIN_MACOS_VERSION": "13.0",
                    "UPDATES_BASE_URL": "https://updates.example.com", "SPARKLE_ED_PUBLIC_KEY": fakes.PUBLIC_B64,
                    "RELEASE_MODE": "release"}

    def plist(self):
        return json.loads(slurp(os.path.join(self.out, "Contents", "Info.plist")))

    def test_release_injects_versions_and_sparkle_keys_and_embeds_framework(self):
        r = self.run_sh("assemble-app.sh", env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        p = self.plist()
        self.assertEqual((p["CFBundleIdentifier"], p["CFBundleShortVersionString"], p["CFBundleVersion"], p["LSMinimumSystemVersion"]),
                         ("org.example.chopshop", "1.2.3", "202610281200", "13.0"))
        self.assertEqual((p["SUFeedURL"], p["SUPublicEDKey"]), ("https://updates.example.com/appcast.xml", fakes.PUBLIC_B64))
        self.assertIs(p["SUEnableAutomaticChecks"], True)
        self.assertIs(p["SUAutomaticallyUpdate"], False)
        self.assertEqual(p["SUScheduledCheckInterval"], 86400)
        self.assertIs(p["SURequireSignedFeed"], True)
        self.assertIs(p["SUVerifyUpdateBeforeExtraction"], True)
        self.assertEqual(p["NSAppTransportSecurity"], 1)  # lo que ponga build.sh se conserva
        self.assertTrue(os.path.isdir(os.path.join(self.out, "Contents", "Frameworks", "Sparkle.framework")))
        self.assertTrue(any(c.startswith("install_name_tool -add_rpath @executable_path/../Frameworks") for c in self.calls()))

    def test_configurable_auto_update_and_interval(self):
        r = self.run_sh("assemble-app.sh", env=dict(self.env, SPARKLE_AUTO_UPDATE="true", SPARKLE_CHECK_INTERVAL="3600"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.plist()["SUAutomaticallyUpdate"], self.plist()["SUScheduledCheckInterval"]), (True, 3600))
        self.assertNotEqual(self.run_sh("assemble-app.sh", env=dict(self.env, SPARKLE_AUTO_UPDATE="quizas")).returncode, 0)

    def test_existing_rpath_is_not_added_twice(self):
        r = self.run_sh("assemble-app.sh", env=dict(self.env, FAKE_RPATH="1"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(any(c.startswith("install_name_tool") for c in self.calls()))

    def test_release_without_feed_or_public_key_fails(self):
        for missing in ("UPDATES_BASE_URL", "SPARKLE_ED_PUBLIC_KEY"):
            env = dict(self.env, **{missing: ""})
            r = self.run_sh("assemble-app.sh", env=env)
            self.assertNotEqual(r.returncode, 0, missing)
            self.assertIn(missing, r.stderr)

    def test_dry_run_without_sparkle_vars_builds_with_updater_disabled(self):
        env = dict(self.env, RELEASE_MODE="dryrun", UPDATES_BASE_URL="", SPARKLE_ED_PUBLIC_KEY="")
        r = self.run_sh("assemble-app.sh", env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse([k for k in self.plist() if k.startswith("SU")])
        self.assertIn("updater desactivado", r.stderr)

    def test_invalid_public_key_rejected(self):
        r = self.run_sh("assemble-app.sh", env=dict(self.env, SPARKLE_ED_PUBLIC_KEY="AAAA"))
        self.assertNotEqual(r.returncode, 0)

    def test_binary_newer_than_declared_minimum_fails(self):
        r = self.run_sh("assemble-app.sh", env=dict(self.env, FAKE_MINOS="26.0"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("MIN_MACOS_VERSION", r.stderr)
        self.assertEqual(self.run_sh("assemble-app.sh", env=dict(self.env, FAKE_MINOS="26.0", MIN_MACOS_VERSION="26.0")).returncode, 0)

    def test_sparkle_framework_version_must_match_pin(self):
        spit(os.path.join(self.fw, "Resources", "Info.plist"), '{"CFBundleShortVersionString": "2.0.0"}')
        r = self.run_sh("assemble-app.sh", env=self.env)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("sparkle.version", r.stderr)


# ---------------------------------------------------------------------------
class TestSparkleTools(WorkDir):
    def make_tarball(self, version, with_tools=True):
        import io
        import tarfile
        site = os.path.join(self.tmp, "site", "sparkle-project", "Sparkle", "releases", "download", version)
        os.makedirs(site)
        path = os.path.join(site, "Sparkle-%s.tar.xz" % version)
        with tarfile.open(path, "w:xz") as tf:
            for name in (("bin/generate_appcast", "bin/sign_update") if with_tools else ("bin/otra",)):
                data = b"#!/bin/sh\n"
                info = tarfile.TarInfo("./" + name)
                info.size, info.mode = len(data), 0o755
                tf.addfile(info, io.BytesIO(data))
            info = tarfile.TarInfo("./Sparkle.framework/Resources/Info.plist")
            info.size = 2
            tf.addfile(info, io.BytesIO(b"{}"))
        import hashlib
        return hashlib.sha256(slurp(path, "rb")).hexdigest()

    def run_install(self, sha, version="9.9.9"):
        pin = os.path.join(self.tmp, "pin")
        spit(pin, "SPARKLE_VERSION=%s\nSPARKLE_SHA256=%s\n" % (version, sha))
        env = {"SPARKLE_VERSION_FILE": pin, "FAKE_S3_DIR": os.path.join(self.tmp, "site")}
        return self.run_sh("sparkle-tools.sh", ["install", os.path.join(self.tmp, "tools")], env=env)

    def test_verified_download_is_installed(self):
        sha = self.make_tarball("9.9.9")
        r = self.run_install(sha)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertTrue(os.access(os.path.join(self.tmp, "tools", "bin", "generate_appcast"), os.X_OK))

    def test_checksum_mismatch_aborts_and_discards_the_download(self):
        self.make_tarball("9.9.9")
        r = self.run_install("0" * 64)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no coincide", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "tools", "Sparkle-9.9.9.tar.xz")))

    def test_tarball_without_tools_is_rejected(self):
        sha = self.make_tarball("9.9.9", with_tools=False)
        self.assertNotEqual(self.run_install(sha).returncode, 0)


# ---------------------------------------------------------------------------
class TestPublishFlow(WorkDir):
    """publish.sh y rollback.sh de punta a punta contra un R2 y un appcast falsos."""

    def setUp(self):
        super().setUp()
        self.s3 = os.path.join(self.tmp, "r2")
        os.makedirs(self.s3)
        self.env = dict(self.base_env, FAKE_S3_DIR=self.s3, R2_ACCOUNT_ID=R2_ACCOUNT, R2_ACCESS_KEY_ID="akid-demo",
                        R2_SECRET_ACCESS_KEY="secreto-r2-ficticio", R2_BUCKET="bucket-demo",
                        UPDATES_BASE_URL="https://updates.example.com", SPARKLE_BIN=self.bin,
                        SPARKLE_ED_PRIVATE_KEY=fakes.SECRET_B64, SPARKLE_ED_PUBLIC_KEY=fakes.PUBLIC_B64,
                        MIN_MACOS_VERSION="13.0")
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        genv = dict(os.environ, GIT_AUTHOR_NAME="Demo", GIT_AUTHOR_EMAIL="ci@invalid.test", GIT_COMMITTER_NAME="Demo",
                    GIT_COMMITTER_EMAIL="ci@invalid.test")
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "base"], cwd=self.repo, env=genv, check=True)
        self.genv = genv

    def release(self, version, build, channel="", payload=None):
        subprocess.run(["git", "tag", "-a", "--cleanup=verbatim", "v" + version, "-m", "## Novedades\n- cambio " + version], cwd=self.repo, env=self.genv, check=True)
        zip_path = os.path.join(self.tmp, "Chopshop-%s.zip" % version)
        spit(zip_path, payload or ("contenido-" + version).encode(), "wb")
        env = dict(self.env, TAG="v" + version, VERSION=version, BUILD_NUMBER=build, CHANNEL=channel)
        return self.run_sh("publish.sh", [zip_path], env=env, cwd=self.repo)

    def puts(self):
        return [c.split()[2] for c in self.calls() if c.startswith("aws put")]

    def test_first_release_orders_uploads_and_sets_cache_headers(self):
        r = self.release("1.0.0", "202610010000")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        puts = self.puts()
        self.assertEqual(puts, ["Chopshop-1.0.0.zip", "notes/1.0.0.html", "appcast.xml"])  # el appcast, al final
        by_key = {c.split()[2]: c for c in self.calls() if c.startswith("aws put")}
        self.assertIn("immutable", by_key["Chopshop-1.0.0.zip"])
        self.assertIn("max-age=60", by_key["appcast.xml"])
        self.assertNotIn("immutable", by_key["appcast.xml"])
        gen = next(c for c in self.calls() if c.startswith("generate_appcast"))
        for flag in ("--ed-key-file -", "--download-url-prefix https://updates.example.com/", "--maximum-deltas 3",
                     "--delta-compression lzma", "--versions 202610010000", "--embed-release-notes"):
            self.assertIn(flag, gen)
        self.assertNotIn(fakes.SECRET_B64, "\n".join(self.calls()))
        self.assertTrue(any(c.startswith("sign_update --verify --ed-key-file -") for c in self.calls()))
        out = r.stdout + r.stderr
        for secret in ("secreto-r2-ficticio", fakes.SECRET_B64):
            self.assertNotIn(secret, out)
        self.assertNotIn("secreto-r2-ficticio", "\n".join(self.calls()))  # las credenciales viajan por entorno, no por argv

    def test_second_release_keeps_previous_and_never_deletes(self):
        self.assertEqual(self.release("1.0.0", "202610010000").returncode, 0)
        spit(self.log, "")
        r = self.release("1.1.0", "202610020000", channel="beta")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        items = appcast.load_items(os.path.join(self.s3, "appcast.xml"))
        self.assertEqual([i["short"] for i in items], ["1.1.0", "1.0.0"])
        self.assertEqual(items[0]["channel"], "beta")
        self.assertEqual(items[1]["channel"], "")
        self.assertTrue(os.path.exists(os.path.join(self.s3, "Chopshop-1.0.0.zip")))
        self.assertIn("--channel beta", next(c for c in self.calls() if c.startswith("generate_appcast")))
        self.assertFalse(any("delete" in c or "rm " in c for c in self.calls()))
        self.assertEqual(self.puts(), ["Chopshop-1.1.0.zip", "notes/1.1.0.html", "appcast.xml"])  # lo previo no se resube

    def test_phased_rollout_only_for_stable(self):
        self.env["PHASED_ROLLOUT_INTERVAL"] = "86400"
        self.assertEqual(self.release("1.0.0", "202610010000").returncode, 0)
        self.assertIn("--phased-rollout-interval 86400", next(c for c in self.calls() if c.startswith("generate_appcast")))
        spit(self.log, "")
        self.assertEqual(self.release("1.1.0-beta.1", "202610020000", channel="beta").returncode, 0)
        self.assertNotIn("--phased-rollout-interval", next(c for c in self.calls() if c.startswith("generate_appcast")))

    def test_refuses_non_monotonic_build_and_republish_with_other_content(self):
        self.assertEqual(self.release("1.1.0", "202610020000").returncode, 0)
        before = slurp(os.path.join(self.s3, "appcast.xml"))
        spit(self.log, "")
        r = self.release("1.2.0", "202610010000")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no es mayor", r.stderr)
        # misma versión, contenido distinto
        subprocess.run(["git", "tag", "-d", "v1.1.0"], cwd=self.repo, env=self.genv, check=True)
        r = self.release("1.1.0", "202610040000", payload=b"otro contenido")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ya existe", r.stderr)
        self.assertEqual(slurp(os.path.join(self.s3, "Chopshop-1.1.0.zip"), "rb"), b"contenido-1.1.0")
        self.assertEqual(slurp(os.path.join(self.s3, "appcast.xml")), before)

    def test_idempotent_rerun_of_same_release(self):
        self.assertEqual(self.release("1.0.0", "202610010000").returncode, 0)
        subprocess.run(["git", "tag", "-d", "v1.0.0"], cwd=self.repo, env=self.genv, check=True)
        r = self.release("1.0.0", "202610010000")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn("idempotente", r.stdout)

    def test_auth_error_is_not_treated_as_first_publication(self):
        r = self.release("1.0.0", "202610010000")
        self.assertEqual(r.returncode, 0)
        before = slurp(os.path.join(self.s3, "appcast.xml"))
        self.env["FAKE_AWS_AUTH_FAIL"] = "1"
        r = self.release("1.1.0", "202610020000")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(slurp(os.path.join(self.s3, "appcast.xml")), before, "no se debe pisar el feed ante un error de credenciales")

    def test_rollback_dry_run_and_real(self):
        self.assertEqual(self.release("1.0.0", "202610010000").returncode, 0)
        self.assertEqual(self.release("1.1.0", "202610020000").returncode, 0)
        feed_before = slurp(os.path.join(self.s3, "appcast.xml"))
        spit(self.log, "")
        r = self.run_sh("rollback.sh", ["1.1.0"], env=dict(self.env, ROLLBACK_DRY_RUN="true"))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(self.puts(), [])
        self.assertEqual(slurp(os.path.join(self.s3, "appcast.xml")), feed_before)
        r = self.run_sh("rollback.sh", ["1.1.0"], env=dict(self.env, ROLLBACK_DRY_RUN="false"))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        calls = self.calls()
        put_i = next(i for i, c in enumerate(calls) if c.startswith("aws put appcast.xml"))
        mv_i = next(i for i, c in enumerate(calls) if c.startswith("aws mv Chopshop-1.1.0.zip"))
        self.assertLess(put_i, mv_i, "primero el feed, después mover los archivos")
        self.assertEqual([i["short"] for i in appcast.load_items(os.path.join(self.s3, "appcast.xml"))], ["1.0.0"])
        self.assertTrue(os.path.exists(os.path.join(self.s3, "retired", "Chopshop-1.1.0.zip")))
        self.assertTrue(os.path.exists(os.path.join(self.s3, "Chopshop-1.0.0.zip")), "las demás versiones no se tocan")

    def test_rollback_prunes_manually_when_generate_appcast_keeps_the_item(self):
        self.assertEqual(self.release("1.0.0", "202610010000").returncode, 0)
        self.assertEqual(self.release("1.1.0", "202610020000").returncode, 0)
        r = self.run_sh("rollback.sh", ["1.1.0"], env=dict(self.env, ROLLBACK_DRY_RUN="false", FAKE_KEEP_STALE_ITEM="1"))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn("poda manual", r.stdout)
        self.assertEqual([i["short"] for i in appcast.load_items(os.path.join(self.s3, "appcast.xml"))], ["1.0.0"])
        self.assertIn("sparkle-signatures", slurp(os.path.join(self.s3, "appcast.xml")))  # re-firmado con sign_update
        self.assertTrue(any(c.startswith("sign_update --ed-key-file -") and c.endswith("appcast.xml") for c in self.calls()))

    def test_rollback_of_only_version_is_refused(self):
        self.assertEqual(self.release("1.0.0", "202610010000").returncode, 0)
        r = self.run_sh("rollback.sh", ["1.0.0"], env=dict(self.env, ROLLBACK_DRY_RUN="false"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("vacío", r.stderr)

    def test_rollback_validates_version_argument(self):
        r = self.run_sh("rollback.sh", ["../etc"], env=self.env)
        self.assertNotEqual(r.returncode, 0)


# ---------------------------------------------------------------------------
class TestRepoHygiene(unittest.TestCase):
    """Los workflows y scripts no llevan valores propios ni imprimen secretos."""

    ALLOWED_HOSTS = {"github.com", "api.github.com", "api.cloudflare.com", "cloudflare.com", "dash.cloudflare.com", "developers.cloudflare.com",
                     "r2.cloudflarestorage.com", "r2.dev", "example.com", "example.org", "example.net", "updates.example.com",
                     "developer.apple.com", "appstoreconnect.apple.com", "www.apple.com", "apple.com", "www.andymatuschak.org",
                     "andymatuschak.org", "purl.org", "sparkle-project.org", "www.shellcheck.net", "shellcheck.net", "pnpm.io", "docs.github.com",
                     "brew.sh", "tailscale.com", "swift.org"}
    HOST_RE = re.compile(r"https?://([A-Za-z0-9.${}_-]+)")
    DOMAIN_RE = re.compile(r"\b([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:com|net|org|io|dev|ai|co|xyz))\b")
    FORBIDDEN = re.compile(r"novarix|telar|io\.github|facundo", re.I)

    def tracked(self):
        files = []
        for d, _dirs, names in os.walk(RELEASE):
            if os.path.basename(d) in ("tests", "__pycache__"):
                _dirs[:] = []
                continue
            files += [os.path.join(d, n) for n in names]
        files += [os.path.join(WORKFLOWS, n) for n in os.listdir(WORKFLOWS)]
        files += [os.path.join(ROOT, "docs", "release.md"), os.path.join(MAC, "Sources", "ChopshopUI", "Updater.swift"),
                  os.path.join(MAC, "Package.swift")]
        return [f for f in files if os.path.isfile(f) and not f.endswith(".pyc")]

    def test_no_private_names_hosts_or_team_ids(self):
        bad = []
        for p in self.tracked():
            text = read(p)
            rel = os.path.relpath(p, ROOT)
            if self.FORBIDDEN.search(text):
                bad.append("%s: nombre propio/privado" % rel)
            for host in self.HOST_RE.findall(text):
                h = host.rstrip(".")
                if "$" in h or "{" in h:
                    continue
                if not any(h == a or h.endswith("." + a) for a in self.ALLOWED_HOSTS):
                    bad.append("%s: host no permitido %s" % (rel, h))
            for dom in self.DOMAIN_RE.findall(text):
                if not any(dom == a or dom.endswith("." + a) for a in self.ALLOWED_HOSTS) and not dom.startswith(("com.example", "org.example")):
                    if re.search(r"(?<![\w.-])" + re.escape(dom) + r"(?![\w-])", text) and not re.match(r"^(node|next|package|index)\.", dom):
                        bad.append("%s: dominio no permitido %s" % (rel, dom))
            for team in re.findall(r"\(([A-Z0-9]{10})\)", text):
                if team != "ABCDE12345":
                    bad.append("%s: posible Team ID %s" % (rel, team))
        self.assertEqual(sorted(set(bad)), [])

    def test_bash_scripts_use_strict_mode(self):
        for name in release_scripts():
            text = read(RELEASE, name)
            self.assertTrue(text.startswith("#!/usr/bin/env bash"), name)
            if name != "lib.sh":
                self.assertIn("set -euo pipefail", text, name)

    def test_scripts_parse_with_bash_n(self):
        for name in release_scripts():
            r = subprocess.run(["bash", "-n", os.path.join(RELEASE, name)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, "%s: %s" % (name, r.stderr))

    def test_scripts_never_print_or_trace_secrets(self):
        for name in release_scripts() + ["appcast.py"]:
            text = read(RELEASE, name)
            self.assertNotRegex(text, r"set -[a-z]*x|bash -x|\bxtrace\b|printenv|\benv \||curl [^\n]*(-v\b|--verbose)", name)
            for ln in text.splitlines():
                if ln.lstrip().startswith("#"):
                    continue
                self.assertNotRegex(ln, r"aws\b[^\n]*--delete|\bs3 (rm|rb)\b", "%s borra objetos de R2: %s" % (name, ln.strip()))
                for secret in ALL_SECRETS:
                    if not re.search(r"\$\{?%s\b" % secret, ln):
                        continue
                    if re.search(r"\b(echo|log|warn|die|summary|set_output|set_env)\b", ln) and "mask_value" not in ln:
                        self.fail("%s imprime/exporta un secreto: %s" % (name, ln.strip()))
                    if "printf" in ln and not re.search(r'"\$\{?%s\}?"\s*(\||>)' % secret, ln):
                        self.fail("%s: printf de un secreto sin tubería/redirección: %s" % (name, ln.strip()))

    def test_workflow_run_blocks_never_echo_secrets(self):
        for n in os.listdir(WORKFLOWS):
            for ln in read(WORKFLOWS, n).splitlines():
                if ln.lstrip().startswith("#"):
                    continue
                for secret in ALL_SECRETS:
                    if re.search(r"\$\{?%s\b" % secret, ln):
                        self.assertNotRegex(ln, r"\b(echo|printf|cat)\b", "%s: %s" % (n, ln.strip()))
                self.assertNotRegex(ln, r"(set -x|bash -x|ACTIONS_STEP_DEBUG)", n)

    def test_sparkle_pin_matches_package_swift(self):
        pin = dict(re.findall(r"^(\w+)=(\S+)$", read(RELEASE, "sparkle.version"), re.M))
        self.assertRegex(pin["SPARKLE_SHA256"], r"^[0-9a-f]{64}$")
        self.assertIn('exact: "%s"' % pin["SPARKLE_VERSION"], read(MAC, "Package.swift"))
        self.assertIn("sparkle-project/Sparkle", read(MAC, "Package.swift"))

    def test_sparkle_version_file_is_not_gitignored(self):
        r = subprocess.run(["git", "check-ignore", "-q", os.path.join(RELEASE, "sparkle.version")], cwd=ROOT, capture_output=True)
        if r.returncode == 128:
            self.skipTest("fuera de un repo git")
        self.assertNotEqual(r.returncode, 0, "sparkle.version está ignorado por .gitignore")

    def test_swift_updater_is_safe_by_default(self):
        text = read(MAC, "Sources", "ChopshopUI", "Updater.swift")
        for needle in ("SPUStandardUpdaterController", "guard isConfigured else { return }", "Buscar actualizaciones…", "SUFeedURL", "SUPublicEDKey",
                       "allowedChannels"):
            self.assertIn(needle, text)
        self.assertIn("UpdaterCommands()", read(MAC, "Sources", "ChopshopUI", "App.swift"))
        assemble = read(RELEASE, "assemble-app.sh")
        for key in ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUScheduledCheckInterval", "SURequireSignedFeed"):
            self.assertIn(key, assemble)
        self.assertEqual(text.count("import "), len(re.findall(r"^import \w+$", text, re.M)))

    def test_sparkle_dependency_is_embedded_by_local_build_too(self):
        self.assertIn("release/embed-sparkle.sh", read(MAC, "build.sh"))

    def test_entitlements_are_minimal(self):
        text = read(RELEASE, "Chopshop.entitlements")
        self.assertIn("<dict/>", text)
        self.assertNotIn("com.apple.security.cs.", text.split("-->", 1)[1])


# ---------------------------------------------------------------------------
class TestWorkflows(unittest.TestCase):
    NAMES = ["release-mac.yml", "rollback-mac.yml", "release-tooling.yml"]

    def load(self, name):
        data = yaml.safe_load(read(WORKFLOWS, name))
        data["on"] = data.pop(True, data.get("on"))  # PyYAML (YAML 1.1) lee `on` como True
        return data

    def test_files_exist_without_tabs(self):
        for n in self.NAMES:
            text = read(WORKFLOWS, n)
            self.assertNotIn("\t", text, n)
            self.assertRegex(text, r"(?m)^name: ", n)

    def test_actions_are_pinned_by_sha(self):
        for n in os.listdir(WORKFLOWS):
            for ln in read(WORKFLOWS, n).splitlines():
                m = re.match(r"\s*(?:-\s+)?uses:\s*(\S+)", ln)
                if m and not m.group(1).startswith("./"):
                    self.assertRegex(m.group(1), r"@[0-9a-f]{40}$", "%s: %s" % (n, ln.strip()))
                    self.assertRegex(ln, r"# v?\d", "%s: falta el comentario con la versión" % n)

    def test_secrets_only_appear_as_step_env_mappings(self):
        value = r"^ {10}[A-Z][A-Z0-9_]*: \$\{\{ secrets\.[A-Z][A-Z0-9_]* \}\}$"
        flag = r"^ {10}[A-Z][A-Z0-9_]*: \$\{\{ secrets\.[A-Z][A-Z0-9_]* != '' && 'set' \|\| '' \}\}$"
        for n in os.listdir(WORKFLOWS):
            for ln in read(WORKFLOWS, n).splitlines():
                if "secrets." in ln and "${{ github.token }}" not in ln:
                    self.assertTrue(re.match(value, ln) or re.match(flag, ln), "%s: un secret fuera de `env:` de un paso: %s" % (n, ln.strip()))

    def test_no_workflow_runs_on_pull_request_with_secrets(self):
        for n in ("release-mac.yml", "rollback-mac.yml"):
            text = read(WORKFLOWS, n)
            self.assertNotRegex(text, r"(?m)^\s*pull_request", n)  # (los comentarios pueden mencionarlo)
            self.assertNotIn("secrets: inherit", text)
        self.assertNotIn("secrets.", read(WORKFLOWS, "release-tooling.yml"))

    def test_exact_secret_and_variable_names(self):
        secrets, variables = set(), set()
        for n in os.listdir(WORKFLOWS):
            text = read(WORKFLOWS, n)
            secrets |= set(re.findall(r"secrets\.([A-Z][A-Z0-9_]+)", text))
            variables |= set(re.findall(r"vars\.([A-Z][A-Z0-9_]+)", text))
        self.assertEqual(sorted(secrets), sorted(SIGN_SECRETS + PUBLISH_SECRETS))
        self.assertEqual(sorted(variables), sorted(REQUIRED_VARS))

    def test_old_names_are_gone_everywhere(self):
        old = ["MACOS_KEYCHAIN_PASSWORD", "MACOS_SIGN_IDENTITY", "APPLE_API_KEY", "APPLE_API_ISSUER", "SPARKLE_PUBLIC_ED_KEY", "SPARKLE_FEED_URL",
               "CLOUDFLARE_", "R2_PREFIX", "SPARKLE_SIGNING_PUBLIC", "release-signing", "release-dryrun", "vars.MIN_MACOS_VERSION"]
        for p in TestRepoHygiene.tracked(None):
            text = read(p)
            for o in old:
                self.assertNotIn(o, text, "%s todavía usa %s" % (os.path.relpath(p, ROOT), o))

    @unittest.skipUnless(yaml, "PyYAML no disponible")
    def test_release_workflow_structure(self):
        wf = self.load("release-mac.yml")
        self.assertEqual(wf["on"]["push"]["tags"], ["v*"])
        self.assertIs(wf["on"]["workflow_dispatch"]["inputs"]["dry_run"]["default"], True)
        self.assertEqual(wf["on"]["workflow_dispatch"]["inputs"]["min_macos_version"]["default"], "13.0")
        self.assertEqual(wf["permissions"], {"contents": "read"})
        self.assertEqual(wf["concurrency"]["group"], "release-mac-${{ github.ref }}")
        self.assertIs(wf["concurrency"]["cancel-in-progress"], False)
        self.assertEqual(wf["env"]["MIN_MACOS_VERSION"], "${{ inputs.min_macos_version || '13.0' }}")  # input/valor por defecto, no var
        self.assertNotIn("secrets.", json.dumps(wf["env"]))
        jobs = wf["jobs"]
        self.assertEqual(set(jobs), {"preflight", "build", "publish"})
        for name, job in jobs.items():
            self.assertIn("timeout-minutes", job, name)
            self.assertNotIn("secrets.", json.dumps(job.get("env", {})), name)
        self.assertEqual(jobs["build"]["runs-on"], "macos-15")
        self.assertEqual(jobs["publish"]["runs-on"], "macos-15")
        self.assertEqual(jobs["build"]["needs"], "preflight")
        self.assertEqual(jobs["publish"]["environment"], "release")
        self.assertEqual(jobs["publish"]["permissions"], {"contents": "write"})
        self.assertIs(jobs["publish"]["concurrency"]["cancel-in-progress"], False)
        self.assertEqual(jobs["publish"]["concurrency"]["group"], "mac-updates-feed")
        self.assertEqual(jobs["publish"]["needs"], ["preflight", "build"])
        self.assertIn("dry_run != 'true'", jobs["publish"]["if"])

    @unittest.skipUnless(yaml, "PyYAML no disponible")
    def test_preflight_fails_first_before_keychain_or_network(self):
        steps = self.load("release-mac.yml")["jobs"]["preflight"]["steps"]
        names = [s.get("name", s.get("uses", "")) for s in steps]
        pre = next(i for i, s in enumerate(steps) if "preflight.sh release" in s.get("run", ""))
        # solo checkout y la decisión de modo pueden ir antes; nada de red, git fetch, versión ni keychain
        for s in steps[:pre]:
            self.assertTrue(s.get("uses", "").startswith("actions/checkout") or s.get("id") == "mode", s.get("name"))
        env = steps[pre]["env"]
        for n in SIGN_SECRETS + PUBLISH_SECRETS:
            self.assertEqual(env[n], "${{ secrets.%s != '' && 'set' || '' }}" % n)  # solo el indicador, nunca el valor
        for n in REQUIRED_VARS:
            self.assertEqual(env[n], "${{ vars.%s }}" % n)
        self.assertEqual(sorted(names).count("Secrets y variables requeridos"), 1)
        build = self.load("release-mac.yml")["jobs"]["build"]
        self.assertEqual(build["needs"], "preflight")
        self.assertNotIn("environment", build)

    @unittest.skipUnless(yaml, "PyYAML no disponible")
    def test_secrets_are_scoped_to_the_job_that_needs_them(self):
        wf = self.load("release-mac.yml")
        value = lambda n: "${{ secrets.%s }}" % n  # noqa: E731
        def step_envs(job):
            return [s.get("env", {}) for s in wf["jobs"][job]["steps"]]
        def uses_value(job, n):
            return any(e.get(n) == value(n) for e in step_envs(job))
        for n in SIGN_SECRETS:
            self.assertTrue(uses_value("build", n), n)
            self.assertFalse(uses_value("publish", n), n)
        for n in PUBLISH_SECRETS:
            self.assertTrue(uses_value("publish", n), n)
            self.assertFalse(uses_value("build", n), n)
        for n in SIGN_SECRETS + PUBLISH_SECRETS:
            self.assertFalse(uses_value("preflight", n), n)

    @unittest.skipUnless(yaml, "PyYAML no disponible")
    def test_build_job_always_cleans_up_and_gates_secret_steps_on_dry_run(self):
        steps = self.load("release-mac.yml")["jobs"]["build"]["steps"]
        self.assertEqual(steps[-1].get("if"), "always()")
        self.assertIn("keychain.sh cleanup", steps[-1]["run"])
        for s in steps:
            if "secrets." in json.dumps(s.get("env", {})):
                self.assertIn("DRY_RUN != 'true'", s.get("if", ""), s.get("name"))
        runs = " ".join(s.get("run", "") for s in steps)
        for script in ("assemble-app.sh", "sign-app.sh", "notarize.sh", "package.sh", "keychain.sh setup"):
            self.assertIn(script, runs)
        self.assertLess(runs.index("notarize.sh"), runs.index("package.sh"), "el zip final se crea DESPUÉS de grapar")
        # la release real siempre se firma y notariza: ningún paso de notarización/firma real es opcional salvo en dry-run
        self.assertNotIn("unsigned", json.dumps(steps).lower())

    @unittest.skipUnless(yaml, "PyYAML no disponible")
    def test_rollback_workflow_structure(self):
        wf = self.load("rollback-mac.yml")
        inputs = wf["on"]["workflow_dispatch"]["inputs"]
        self.assertTrue(inputs["version"]["required"])
        self.assertIs(inputs["dry_run"]["default"], True)
        job = wf["jobs"]["rollback"]
        self.assertEqual(job["environment"], "release")
        self.assertEqual(job["concurrency"]["group"], "mac-updates-feed")
        self.assertIs(job["concurrency"]["cancel-in-progress"], False)
        self.assertEqual(wf["permissions"], {"contents": "read"})
        self.assertEqual(job["needs"], "guard")
        self.assertTrue(any("preflight.sh rollback" in s.get("run", "") for s in wf["jobs"]["guard"]["steps"]))

    def test_docs_list_every_secret_and_variable_used(self):
        doc = read(ROOT, "docs", "release.md")
        used = set()
        for n in os.listdir(WORKFLOWS):
            used |= set(re.findall(r"(?:secrets|vars)\.([A-Z][A-Z0-9_]+)", read(WORKFLOWS, n)))
        for name in sorted(used):
            self.assertIn("`%s`" % name, doc, "docs/release.md no documenta %s" % name)

    def test_yaml_parses(self):
        if yaml is None:
            self.skipTest("PyYAML no disponible")
        for n in os.listdir(WORKFLOWS):
            self.assertIsInstance(yaml.safe_load(read(WORKFLOWS, n)), dict, n)

    def test_actionlint_if_available(self):
        exe = shutil.which("actionlint") or os.path.expanduser("~/.local/bin/actionlint")
        if not os.path.exists(exe):
            self.skipTest("actionlint no instalado")
        r = subprocess.run([exe] + [os.path.join(WORKFLOWS, n) for n in sorted(os.listdir(WORKFLOWS)) if n.endswith(".yml")],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_shellcheck_if_available(self):
        exe = shutil.which("shellcheck") or os.path.expanduser("~/.local/bin/shellcheck")
        if not os.path.exists(exe):
            self.skipTest("shellcheck no instalado")
        r = subprocess.run([exe, "-x", "-P", "SCRIPTDIR", "-s", "bash"] + [os.path.join(RELEASE, n) for n in release_scripts()],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
