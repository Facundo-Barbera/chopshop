"""Pruebas de chopshop.agent.service: bind, token, validación de config, unidad systemd, hilos de fondo con parada limpia y
subcomandos `chopshop agent ...`. Nada de systemd real (solo `systemd-analyze --user verify` si existe, que no arranca nada),
ni Tailscale, ni T3: todo con runners falsos. Puertos efímeros en loopback solo mientras dura cada test."""
import copy
import io
import json
import logging
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop import cli, settings  # noqa: E402
from chopshop.agent import db, events, server, service  # noqa: E402
from test_agent_server import FakeTailscale, ServerBase, TOKEN  # noqa: E402

ROOT = service.ROOT


def wait_for(pred, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.02)
    return pred()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def base_cfg(tmp, **over):
    cfg = copy.deepcopy(settings.DEFAULTS["agent"])
    cfg.update(machine_id="host-a", db_path=os.path.join(tmp, "agent", "agent.db"), token_file=os.path.join(tmp, "token"),
               projects_root=tmp, worktrees_root=tmp, t3_enabled=False, import_legacy=False)
    cfg.update(over)
    return cfg


class TmpCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-svc-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.saved = {k: v for k, v in os.environ.items() if k.startswith("CHOPSHOP_")}
        for k in self.saved:
            del os.environ[k]
        self.addCleanup(self._restore_env)
        os.environ["CHOPSHOP_CONFIG"] = os.path.join(self.tmp, "config.toml")
        os.environ["CHOPSHOP_HOME"] = os.path.join(self.tmp, "home")

    def _restore_env(self):
        for k in [k for k in os.environ if k.startswith("CHOPSHOP_")]:
            del os.environ[k]
        os.environ.update(self.saved)

    def write_config(self, text):
        with open(os.environ["CHOPSHOP_CONFIG"], "w") as f:
            f.write(text)


class TestBind(unittest.TestCase):
    def test_resolve(self):
        ts = FakeTailscale()
        self.assertEqual(service.resolve_bind({"bind": "127.0.0.1"}), "127.0.0.1")
        self.assertEqual(service.resolve_bind({"bind": "localhost"}), "127.0.0.1")
        self.assertEqual(service.resolve_bind({"bind": "100.64.0.10"}), "100.64.0.10")     # la IP que ponga el usuario
        self.assertEqual(service.resolve_bind({"bind": "auto"}, ts), "100.64.0.7")
        self.assertEqual(ts.calls, [["tailscale", "ip", "-4"]])
        self.assertEqual(service.resolve_bind({"bind": "auto", "tailscale_bin": "/opt/ts"}, ts), "100.64.0.7")
        self.assertEqual(ts.calls[-1][0], "/opt/ts")

    def test_never_wildcard(self):
        for bad in ("0.0.0.0", "::", "0:0:0:0:0:0:0:0", "", "  0.0.0.0 "):
            if bad.strip() == "":                      # vacío = valor por defecto seguro
                self.assertEqual(service.resolve_bind({"bind": bad}), "127.0.0.1")
                continue
            with self.assertRaises(service.ServiceError, msg=bad):
                service.resolve_bind({"bind": bad})

    def test_invalid_and_auto_failure(self):
        with self.assertRaises(service.ServiceError):
            service.resolve_bind({"bind": "mi-host.example"})
        with self.assertRaises(service.ServiceError):
            service.resolve_bind({"bind": "auto"}, lambda argv, timeout=3: (1, "", "tailscaled no corre"))
        with self.assertRaises(service.ServiceError):
            service.resolve_bind({"bind": "auto"}, lambda argv, timeout=3: (0, "no es una ip\n", ""))

    def test_plan_listeners(self):
        self.assertEqual(service.plan_listeners("127.0.0.1", 3790), [("127.0.0.1", 3790)])
        self.assertEqual(service.plan_listeners("100.64.0.10", 3790), [("100.64.0.10", 3790), ("127.0.0.1", 3790)])
        self.assertEqual(service.plan_listeners("100.64.0.10", 3790, False), [("100.64.0.10", 3790)])
        self.assertEqual(service.plan_listeners("::1", 1), [("::1", 1)])


class TestToken(TmpCase):
    def test_create_exists_rotate(self):
        path = os.path.join(self.tmp, "sub", "token")
        self.assertEqual(service.ensure_token(path), "created")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode), 0o700)
        with open(path) as f:
            first = f.read().strip()
        self.assertGreaterEqual(len(first), 32)
        self.assertEqual(service.ensure_token(path), "exists")
        with open(path) as f:
            self.assertEqual(f.read().strip(), first)
        os.chmod(path, 0o644)
        self.assertEqual(service.ensure_token(path), "exists")                      # corrige permisos flojos
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(service.ensure_token(path, rotate=True), "rotated")
        with open(path) as f:
            self.assertNotEqual(f.read().strip(), first)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(os.listdir(os.path.dirname(path)), ["token"])              # sin temporales

    def test_cli_never_prints_the_token(self):
        path = os.path.join(self.tmp, "tok")
        self.write_config('[agent]\ntoken_file = "%s"\n' % path)
        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(service.main(["token"], out, err), 0)
        with open(path) as f:
            tok = f.read().strip()
        self.assertIn(path, out.getvalue())
        self.assertIn("token creado", out.getvalue())
        self.assertNotIn(tok, out.getvalue() + err.getvalue())
        out = io.StringIO()
        self.assertEqual(service.main(["token", "--rotate"], out, err), 0)
        with open(path) as f:
            new = f.read().strip()
        self.assertNotEqual(new, tok)
        self.assertNotIn(new, out.getvalue() + err.getvalue())

    def test_cli_token_error_is_clean(self):
        blocker = os.path.join(self.tmp, "archivo")
        open(blocker, "w").close()
        self.write_config('[agent]\ntoken_file = "%s/dentro/token"\n' % blocker)
        err = io.StringIO()
        self.assertEqual(service.main(["token"], io.StringIO(), err), 1)
        self.assertIn("error:", err.getvalue())


class TestCheckConfig(TmpCase):
    def cfg(self, **over):
        return base_cfg(self.tmp, **over)

    def test_defaults_valid(self):
        errs, warns = service.check_config(self.cfg(), which=lambda b: "/usr/bin/" + b)
        self.assertEqual(errs, [])

    def test_errors(self):
        webhooks = {"bot": "https://hooks.example.test/x", "ok": os.path.join(self.tmp, "no-existe")}
        errs, warns = service.check_config(self.cfg(auth="otra", port=70000, sample_interval=0, webhook_files=webhooks,
                                                    retention={"raw_hours": 0}, bind="0.0.0.0"))
        text = "\n".join(errs)
        for needle in ("agent.auth", "agent.port", "sample_interval", "no una URL", "retention.raw_hours", "no se permite"):
            self.assertIn(needle, text)
        self.assertTrue(any("webhook_files.ok" in w and "no existe" in w for w in warns))
        self.assertNotIn("hooks.example.test", "\n".join(warns))          # las URLs ni se repiten

    def test_remote_bind_warnings(self):
        errs, warns = service.check_config(self.cfg(bind="100.64.0.10", owner_login=""), which=lambda b: None)
        self.assertEqual(errs, [])
        text = "\n".join(warns)
        for needle in ("owner_login", "token_file", "CLI de Tailscale"):
            self.assertIn(needle, text)
        warns = service.check_config(self.cfg(bind="100.64.0.10", owner_login="usuario@"), which=lambda b: "x")[1]
        self.assertTrue(any("marcador" in w for w in warns))
        errs = service.check_config(self.cfg(bind="100.64.0.10", auth="token"))[0]
        self.assertTrue(any("auth = \"token\"" in e for e in errs))
        service.ensure_token(self.cfg()["token_file"])
        self.assertEqual(service.check_config(self.cfg(bind="100.64.0.10", auth="token"))[0], [])
        warns = service.check_config(self.cfg(bind="100.64.0.10", auth="none-local"))[1]
        self.assertTrue(any("none-local" in w for w in warns))

    def test_t3_config_warnings(self):
        ok = service.check_config(self.cfg(t3_enabled=True), which=lambda b: "/usr/bin/" + b)[1]
        self.assertFalse(any("agent.t3" in w for w in ok))
        warns = service.check_config(self.cfg(t3_enabled=True, t3={"t3_bin": "", "origin": ""}))[1]
        self.assertTrue(any("t3_bin" in w and "origin" in w for w in warns))
        self.assertEqual(service.check_config(self.cfg(t3_enabled=True, t3={"t3_bin": "", "origin": "http://100.64.0.10:3773"}))[0], [])
        warns = service.check_config(self.cfg(t3_enabled=True, t3={"t3_bin": "t3", "helper": "~/x/t3mcp.mjs", "node": "node"}))[1]
        self.assertTrue(any("ya no se usa" in w and "helper" in w for w in warns))
        self.assertFalse(any("t3_bin o" in w for w in warns))

    def test_loose_permissions_warn_without_reading(self):
        tok, hook = self.cfg()["token_file"], os.path.join(self.tmp, "hook")
        for p in (tok, hook):
            with open(p, "w") as f:
                f.write("https://hooks.example.test/secreto\n")
            os.chmod(p, 0o644)
        warns = service.check_config(self.cfg(webhook_files={"bot": hook}))[1]
        self.assertTrue(any("chmod 600" in w and tok in w for w in warns))
        self.assertTrue(any("chmod 600" in w and hook in w for w in warns))
        self.assertNotIn("secreto", "\n".join(warns))

    def test_cli_check_config(self):
        self.write_config('[agent]\nauth = "nada"\n')
        out = io.StringIO()
        self.assertEqual(service.main(["check-config"], out, io.StringIO()), 1)
        self.assertIn("error: agent.auth", out.getvalue())
        self.write_config("a = \n")
        err = io.StringIO()
        self.assertEqual(service.main(["check-config"], io.StringIO(), err), 2)
        self.write_config('[agent]\ndb_path = "%s/x/agent.db"\nt3_enabled = false\n' % self.tmp)
        out = io.StringIO()
        self.assertEqual(service.main(["check-config"], out, io.StringIO()), 0)
        self.assertIn("ok:", out.getvalue())


class TestUnit(TmpCase):
    def render(self, home=None, **kw):
        home = home or os.path.join(self.tmp, "casa")
        env = {"HOME": home, "PATH": "%s/.local/bin:/usr/local/bin:/usr/bin" % home}
        env.update(kw.pop("env", {}))
        cfg = base_cfg(self.tmp, db_path=os.path.join(home, ".local", "share", "chopshop", "agent.db"))
        return service.render_unit(cfg, kw.pop("exec_path", os.path.join(home, ".local", "bin", "chopshop")), environ=env, **kw), home

    def test_template_has_required_directives(self):
        with open(service.UNIT_TEMPLATE, encoding="utf-8") as f:
            t = f.read()
        for needle in ("Type=simple", "Restart=on-failure", "WantedBy=default.target", "Slice=chopshop.slice", "NoNewPrivileges=yes",
                       "PrivateTmp=yes", "ProtectSystem=strict", "ReadWritePaths=", "MemoryMax=", "CPUQuota=", "@EXEC_START@",
                       "@READ_WRITE_PATHS@", "@PATH@"):
            self.assertIn(needle, t)
        self.assertNotRegex(t, r"(?m)^ExecStart=/")             # nada de rutas fijas: todo viene del render

    def test_render_uses_environment_and_leaves_no_placeholders(self):
        text, home = self.render()
        self.assertNotRegex(text, r"@[A-Z_]+@")
        self.assertIn("ExecStart=%h/.local/bin/chopshop agent run", text)
        self.assertIn("ReadWritePaths=-%h/.local/share/chopshop", text)
        self.assertIn("-" + os.path.join(self.tmp, "home"), text)           # general.home (CHOPSHOP_HOME) también es escribible
        self.assertIn('Environment="PATH=%h/.local/bin:/usr/local/bin:/usr/bin"', text)
        self.assertNotIn(home, text)                           # ninguna ruta de usuario real en el resultado
        self.assertNotIn("/home/", text)

    def test_extra_paths_env_and_escaping(self):
        text, home = self.render(extra_rw=["/srv/datos con espacio", os.path.join(self.tmp, "casa", "extra")],
                                 env={"CHOPSHOP_CONFIG": os.path.join(self.tmp, "casa", "c.toml")})
        self.assertIn("-/srv/datos\\x20con\\x20espacio", text)
        self.assertIn("-%h/extra", text)
        self.assertIn('Environment="CHOPSHOP_CONFIG=%h/c.toml"', text)
        text2, _ = self.render(exec_path="/opt/mi herramienta/chopshop")
        self.assertIn('ExecStart="/opt/mi herramienta/chopshop" agent run', text2)

    def test_service_read_write_paths_from_config(self):
        cfg = base_cfg(self.tmp, service={"read_write_paths": ["/srv/uno"]})
        text = service.render_unit(cfg, "/usr/bin/true", environ={"HOME": self.tmp, "PATH": "/usr/bin"})
        self.assertIn("-/srv/uno", text)

    def test_local_t3_data_dir_is_writable(self):
        text, _ = self.render()
        self.assertIn(" -%h/.t3", text)                                      # T3 local: ~/.t3 por defecto
        text, _ = self.render(env={"T3CODE_HOME": os.path.join(self.tmp, "casa", "t3-datos")})
        self.assertIn(" -%h/t3-datos", text)
        self.assertNotIn("%h/.t3", text)

    def test_local_t3_data_dir_not_duplicated(self):
        home = os.path.join(self.tmp, "casa")
        cfg = base_cfg(self.tmp, service={"read_write_paths": ["~/.t3"]})
        text = service.render_unit(cfg, "/usr/bin/true", environ={"HOME": home, "PATH": "/usr/bin"}).replace("%h/.t3/", "")
        self.assertEqual(text.count("%h/.t3"), 1)

    def test_remote_t3_origin_does_not_add_data_dir(self):
        home = os.path.join(self.tmp, "casa")
        cfg = base_cfg(self.tmp, t3={"origin": "http://192.0.2.5:3773"})
        text = service.render_unit(cfg, "/usr/bin/true", environ={"HOME": home, "PATH": "/usr/bin"})
        self.assertNotIn(".t3", text)

    def test_template_memory_limits_fit_t3_cli(self):
        with open(service.UNIT_TEMPLATE, encoding="utf-8") as f:
            t = f.read()
        self.assertRegex(t, r"(?m)^MemoryHigh=1G$")
        self.assertRegex(t, r"(?m)^MemoryMax=1500M$")

    def test_unresolved_placeholder_is_an_error(self):
        tpl = os.path.join(self.tmp, "t.service")
        with open(tpl, "w") as f:
            f.write("[Service]\nExecStart=@EXEC_START@\nFoo=@DESCONOCIDO@\n")
        with self.assertRaises(service.ServiceError):
            service.render_unit(base_cfg(self.tmp), "/usr/bin/true", template=tpl, environ={"HOME": self.tmp})

    def test_print_unit_cli_writes_nothing(self):
        before = set(os.listdir(self.tmp))
        out = io.StringIO()
        self.assertEqual(service.main(["print-unit", "--exec", "/usr/bin/true", "--rw", "/srv/x"], out, io.StringIO()), 0)
        self.assertIn("ExecStart=/usr/bin/true agent run", out.getvalue())
        self.assertIn("-/srv/x", out.getvalue())
        self.assertEqual(set(os.listdir(self.tmp)), before)
        self.assertEqual(service.main(["print-unit", "--template", "/no/existe"], io.StringIO(), io.StringIO()), 1)

    @unittest.skipUnless(shutil.which("systemd-analyze"), "systemd-analyze no está disponible")
    def test_systemd_analyze_verify_accepts_the_unit(self):
        text, _ = self.render(exec_path=shutil.which("true") or "/usr/bin/true")
        d = os.path.join(self.tmp, "u")
        os.makedirs(d)
        path = os.path.join(d, "chopshop-agent.service")
        with open(path, "w") as f:
            f.write(text)
        p = subprocess.run(["systemd-analyze", "--user", "verify", path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=30)           # solo analiza el archivo: no arranca nada
        self.assertNotRegex(p.stdout, r"Unknown (key|section)|Failed to parse|Invalid|bad")


class TestInstaller(unittest.TestCase):
    """El instalador SOLO copia y recarga: nunca habilita ni arranca (se revisa el texto; no se ejecuta)."""
    PATH = os.path.join(ROOT, "scripts", "install-user-unit.sh")

    def commands(self):
        with open(self.PATH, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                s = re.sub(r'"[^"]*"', '""', line.strip())             # los textos entre comillas (echo, mensajes) no cuentan
                if s and not s.startswith("#"):
                    yield n, s

    def test_no_enable_start_or_linger(self):
        for n, cmd in self.commands():
            self.assertNotRegex(cmd, r"systemctl.*\b(enable|start|restart|reload-or-restart|link|mask)\b", "línea %d" % n)
            self.assertNotRegex(cmd, r"loginctl|enable-linger|pkill|killall", "línea %d" % n)

    def test_has_dry_run_and_only_daemon_reload(self):
        with open(self.PATH, encoding="utf-8") as f:
            text = f.read()
        self.assertIn("--dry-run", text)
        self.assertIn("systemctl --user daemon-reload", text)
        self.assertEqual(len(re.findall(r"^\s*systemctl ", text, re.M)), 1)
        self.assertTrue(os.access(self.PATH, os.X_OK))
        p = subprocess.run(["sh", "-n", self.PATH], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True,
                           timeout=10)                                        # solo sintaxis
        self.assertEqual((p.returncode, p.stdout), (0, ""))


class TestLifecycle(ServerBase):
    """Servicio con hilos de fondo reales (intervalos mínimos) y módulos falsos."""

    def start_bg(self, **over):
        over.setdefault("sample_interval", 0.05)
        over.setdefault("t3_poll_interval", 0.05)
        over.setdefault("t3_enabled", True)
        return self.start(background=True, svc_kw={"maint_first": 0.05, "maint_interval": 0.05}, **over)

    def our_threads(self):
        return [t for t in threading.enumerate() if t.name.startswith("chopshop-") and t.name != "chopshop-webhook"]

    def test_threads_work_and_stop_cleanly(self):
        self.proc.add(10, "node", ticks=0)
        self.start_bg()
        names = {t.name for t in self.svc.threads}
        self.assertTrue({"chopshop-sampler", "chopshop-t3", "chopshop-maintenance"} <= names)
        svc = self.svc
        self.assertTrue(wait_for(lambda: svc.collector.last_ts is not None and svc.runtime.last_poll is not None))
        st, snap, _ = self.get("/snapshot")
        self.assertEqual(st, 200)
        self.assertIs(snap["agent"]["t3_ok"], True)
        self.assertIsNotNone(snap["agent"]["last_sample_age"])
        self.assertIsNotNone(snap["agent"]["last_poll_age"])
        self.assertNotIn("errors", snap["agent"])
        self.assertTrue(any(t[0] == "t3_project_list" for t in self.t3calls.calls))
        threads = list(svc.threads)
        t0 = time.monotonic()
        svc.stop()
        self.assertLess(time.monotonic() - t0, 5)
        for t in threads:
            self.assertFalse(t.is_alive(), t.name)
        self.assertEqual([t.name for t in self.our_threads() if t in threads], [])
        n = len(self.t3calls.calls)
        time.sleep(0.2)
        self.assertEqual(len(self.t3calls.calls), n)                    # nada sigue sondeando tras parar

    def test_t3_disabled_means_no_poll_thread(self):
        self.start_bg(t3_enabled=False)
        self.assertNotIn("chopshop-t3", {t.name for t in self.svc.threads})
        time.sleep(0.2)
        self.assertEqual(self.t3calls.calls, [])
        self.assertIsNone(self.get("/snapshot")[1]["agent"]["t3_ok"])

    def test_dispatcher_disabled_means_no_dispatcher_thread(self):
        self.start_bg(t3_enabled=False)
        self.assertFalse(self.svc.dispatch_enabled)
        self.assertNotIn("chopshop-dispatcher", {t.name for t in self.svc.threads})
        self.svc.stop()
        self.start_bg(t3_enabled=False, dispatcher={"enabled": True, "max_threads": 3, "interval": 0.05})
        self.assertEqual(self.svc.max_threads, 3)
        self.assertIn("chopshop-dispatcher", {t.name for t in self.svc.threads})

    def test_t3_down_emits_event_once_and_reports(self):
        self.t3calls.down = True
        self.start_bg()
        self.assertTrue(wait_for(lambda: self.svc.t3.reachable is False))
        time.sleep(0.2)
        evs = [e for e in self.get("/events")[1]["events"] if e["event"] == "t3_unreachable"]
        self.assertEqual(len(evs), 1)
        self.assertIs(self.get("/snapshot")[1]["agent"]["t3_ok"], False)

    def test_loop_survives_errors_and_reports_them(self):
        self.start()
        calls = []

        def boom():
            calls.append(1)
            raise RuntimeError("fallo de prueba")
        stop_after = threading.Timer(0.3, self.svc.stop_event.set)
        stop_after.start()
        self.svc._loop("demo", boom, lambda: 0.05)
        stop_after.join()
        self.assertGreater(len(calls), 2)                                 # siguió intentando
        self.assertEqual(self.svc.runtime.errors["demo"], "RuntimeError: fallo de prueba")
        self.svc.stop_event.clear()
        self.assertIn("demo", self.get("/snapshot")[1]["agent"]["errors"])
        rt = server.Runtime(clock=self.clock)
        self.assertTrue(rt.fail("x", ValueError("a")))
        self.assertFalse(rt.fail("x", ValueError("a")))                   # mismo mensaje: no se repite en el log
        self.assertTrue(rt.fail("x", ValueError("b")))
        self.clock.t += 61
        self.assertTrue(rt.fail("x", ValueError("b")))
        rt.ok("x")
        self.assertEqual(rt.errors, {})

    def test_maintenance_prunes_old_events(self):
        self.clock.t = time.time()                    # los eventos usan la hora real: el reloj falso debe coincidir
        self.start(retention={"events_days": 30, "raw_hours": 24, "m1_days": 30, "h1_days": 365})
        now = self.clock.t
        with db.tx():
            for i, age in enumerate((100, 40, 1)):
                self.conn.execute("INSERT INTO events(ts,machine_id,event,project,body) VALUES(?,?,?,?,?)",
                                  (now - age * 86400, "host-a", "viejo%d" % i, None, "{}"))
                self.conn.execute("INSERT INTO deliveries(event_seq,name,ok,detail,ts) VALUES((SELECT MAX(seq) FROM events),'bot',1,'HTTP 200',?)", (now,))
        self.assertEqual(self.svc.maintenance_once(), 2)
        names = [e["event"] for e in events.list_after(self.conn, 0)]
        self.assertEqual(names, ["agent_started", "viejo2"])
        left = self.conn.execute("SELECT COUNT(*) FROM deliveries").fetchone()[0]
        self.assertEqual(left, 1)

    def test_legacy_events_import_at_start(self):
        home = os.environ.get("CHOPSHOP_HOME") or os.path.join(self.tmp, "home")
        os.environ["CHOPSHOP_HOME"] = home
        self.addCleanup(os.environ.pop, "CHOPSHOP_HOME", None)
        os.makedirs(home)
        with open(os.path.join(home, "events.jsonl"), "w") as f:
            f.write(json.dumps({"event": "task_done", "project": "proyecto-demo", "ts": "2026-10-28T09:40:00-0600", "task": "t1"}) + "\n")
        self.start(import_legacy=True)
        names = [e["event"] for e in self.get("/events")[1]["events"]]
        self.assertIn("task_done", names)

    def test_port_in_use_is_a_clean_error(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        self.addCleanup(s.close)
        conn = db.connect(os.path.join(self.tmp, "x", "agent.db"))
        self.addCleanup(conn.close)
        svc = service.AgentService(base_cfg(self.tmp, port=s.getsockname()[1]), conn=conn)
        with self.assertRaises(service.ServiceError):
            svc.start()
        self.assertEqual(svc.threads, [])

    def test_wildcard_bind_refuses_to_start(self):
        conn = db.connect(os.path.join(self.tmp, "x", "agent.db"))
        self.addCleanup(conn.close)
        svc = service.AgentService(base_cfg(self.tmp, bind="0.0.0.0"), conn=conn)
        with self.assertRaises(service.ServiceError):
            svc.start()
        self.assertEqual((svc.servers, svc.threads), ([], []))


class TestCli(TmpCase):
    def test_wiring_from_main_cli(self):
        out = io.StringIO()
        old = sys.stdout
        sys.stdout = out
        try:
            self.assertEqual(cli.main(["agent", "print-unit", "--exec", "/usr/bin/true"]), 0)
        finally:
            sys.stdout = old
        self.assertIn("[Service]", out.getvalue())
        self.assertIn("agent run|status", cli.HELP_EPILOG)

    def test_status_when_agent_is_down(self):
        out = io.StringIO()
        rc = service.main(["status", "--url", "http://127.0.0.1:%d" % free_port()], out, io.StringIO(),
                          runner=lambda argv, timeout=3: (127, "", ""))
        self.assertEqual(rc, 1)
        self.assertIn("no responde", out.getvalue())

    def test_run_status_and_sigterm(self):
        """`agent run` arranca, responde, y el manejador de SIGTERM lo detiene con limpieza. No se envían señales reales:
        `signal.signal` se sustituye por un registro y el hilo auxiliar invoca el manejador registrado."""
        port = free_port()
        self.write_config('[agent]\nmachine_id = "host-a"\nbind = "127.0.0.1"\nport = %d\ndb_path = "%s/d/agent.db"\ntoken_file = "%s/tok"\n'
                          't3_enabled = false\nimport_legacy = false\nsample_interval = 1\n' % (port, self.tmp, self.tmp))
        out, err = io.StringIO(), io.StringIO()
        before_threads = set(threading.enumerate())
        root_handlers = list(logging.getLogger().handlers)
        self.addCleanup(lambda: [logging.getLogger().removeHandler(h) for h in logging.getLogger().handlers
                                 if h not in root_handlers])
        installed, result = {}, {}
        sentinel = object()

        def fake_signal(sig, handler):
            previous = installed.get(sig, sentinel)
            installed[sig] = handler
            return "previo-%d" % sig if previous is sentinel else previous

        def probe(url):
            try:
                return urllib.request.urlopen(url + "/health", timeout=1).status == 200
            except OSError:
                return False

        def driver():
            url = "http://127.0.0.1:%d" % port
            result["up"] = wait_for(lambda: probe(url), 10)
            if result["up"]:
                sio = io.StringIO()
                result["status_rc"] = service.main(["status", "--url", url], sio, io.StringIO(),
                                                  runner=lambda argv, timeout=3: (0, "active\n", ""))
                result["status"] = sio.getvalue()
            installed[signal.SIGTERM](signal.SIGTERM, None)         # lo que haría systemd al parar la unidad

        t = threading.Thread(target=driver, daemon=True)
        with mock.patch.object(service.signal, "signal", fake_signal):
            t.start()
            rc = service.main(["run"], out, err)
        t.join(5)
        self.assertEqual(rc, 0, err.getvalue())
        self.assertTrue(result.get("up"), result)
        self.assertEqual(result["status_rc"], 0)
        self.assertIn("chopshop-agent %s en host-a" % service.__version__, result["status"])
        self.assertIn("unidad systemd chopshop-agent: active", result["status"])
        self.assertEqual(installed[signal.SIGTERM], "previo-%d" % signal.SIGTERM)       # `run` restaura los manejadores
        self.assertEqual(installed[signal.SIGINT], "previo-%d" % signal.SIGINT)
        self.assertTrue(wait_for(lambda: not [x for x in set(threading.enumerate()) - before_threads
                                              if x.name.startswith("chopshop-") and x is not t]))
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=1)

    def test_run_refuses_bad_config(self):
        self.write_config('[agent]\nbind = "0.0.0.0"\n')
        err = io.StringIO()
        self.assertEqual(service.main(["run"], io.StringIO(), err), 2)
        self.assertIn("no se permite", err.getvalue())


if __name__ == "__main__":
    unittest.main()
