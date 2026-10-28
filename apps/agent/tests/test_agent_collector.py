"""Tests del colector: parseo puro, agrupación por app/proyecto con un /proc falso, CPU por delta, compactación,
retención y consultas. Nada de red, servicios ni procesos reales (salvo un humo de solo lectura sobre el /proc real)."""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop.agent import collector as C  # noqa: E402
from chopshop.agent import db  # noqa: E402

CG_AGENT = "/user.slice/user-1000.slice/user@1000.service/app.slice/app-t3code.slice/app-t3code-agents.slice/" \
           "app-t3code-agents-2523669e90f4.slice/t3code-claude-c7150fe3.scope"


def stat_line(pid, comm, ticks=0, starttime=100, rss_pages=0, state="S", ppid=1, flags=0):
    """Línea de /proc/<pid>/stat con los 52 campos (utime = ticks, stime = 0)."""
    f = ["0"] * 49
    f[0], f[1], f[6] = state, str(ppid), str(flags)          # campos 3, 4 y 9
    f[11], f[12] = str(ticks), "0"                            # campos 14 y 15
    f[19], f[21] = str(starttime), str(rss_pages)             # campos 22 y 24
    return "%d (%s) %s\n" % (pid, comm, " ".join(f))


class FakeProc(object):
    """Árbol /proc falso en un directorio temporal."""

    def __init__(self, root):
        self.root = root
        self.set_machine()

    def write(self, rel, content, binary=False):
        p = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb" if binary else "w") as f:
            f.write(content)

    def set_machine(self, busy=100, idle=900, load=(0.1, 0.2, 0.3), cpus=4, mem_total_kb=8 * 1048576,
                    mem_avail_kb=6 * 1048576, uptime=1000.0):
        lines = ["cpu  %d 0 0 %d 0 0 0 0 0 0" % (busy, idle)]
        lines += ["cpu%d  0 0 0 0 0 0 0 0 0 0" % i for i in range(cpus)]
        self.write("stat", "\n".join(lines) + "\nbtime 1\n")
        self.write("meminfo", "MemTotal: %d kB\nMemFree: 1 kB\nMemAvailable: %d kB\nSwapTotal: 2048 kB\nSwapFree: 1024 kB\n"
                   % (mem_total_kb, mem_avail_kb))
        self.write("loadavg", "%.2f %.2f %.2f 1/100 999\n" % load)
        self.write("uptime", "%.2f 0.00\n" % uptime)

    def add(self, pid, comm, cmdline=None, cwd=None, cgroup="/", ticks=0, starttime=100, rss_pages=0, state="S",
            environ=None, flags=0):
        d = "%d" % pid
        self.write(d + "/stat", stat_line(pid, comm, ticks, starttime, rss_pages, state, flags=flags))
        argv = [comm] if cmdline is None else cmdline
        self.write(d + "/cmdline", b"\0".join(a.encode() for a in argv) + b"\0" if argv else b"", binary=True)
        self.write(d + "/cgroup", "0::%s\n" % cgroup)
        if environ is not None:
            self.write(d + "/environ", b"".join(("%s=%s" % kv).encode() + b"\0" for kv in environ.items()), binary=True)
        link = os.path.join(self.root, d, "cwd")
        if os.path.lexists(link):
            os.remove(link)
        if cwd is not None:
            os.symlink(cwd, link)

    def set_ticks(self, pid, ticks, starttime=100, comm=None, rss_pages=0):
        if comm is None:
            with open(os.path.join(self.root, str(pid), "stat")) as f:
                comm = f.read().split("(")[1].split(")")[0]
        self.write("%d/stat" % pid, stat_line(pid, comm, ticks, starttime, rss_pages))

    def remove(self, pid):
        shutil.rmtree(os.path.join(self.root, str(pid)))


class Clock(object):
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


class CollectorBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-collector-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.proj_root = os.path.join(self.tmp, "projects")
        self.wt_root = os.path.join(self.tmp, "worktrees")
        self.cfg = {"sample_interval": 10, "projects_root": self.proj_root, "worktrees_root": self.wt_root,
                    "projects": {}, "retention": {"raw_hours": 24, "m1_days": 30, "h1_days": 365}}
        self.conn = db.connect(os.path.join(self.tmp, "agent.db"))
        self.addCleanup(self.conn.close)
        self.proc = FakeProc(os.path.join(self.tmp, "proc"))
        self.clock = Clock()
        self.col = C.Collector(self.cfg, self.conn, proc_root=self.proc.root, clock=self.clock, disk_path=self.tmp,
                               page_size=4096, clk_tck=100)

    def advance(self, secs):
        self.clock.t += secs


class TestParsing(unittest.TestCase):
    def test_stat_con_comm_raro(self):
        st = C.parse_stat(stat_line(42, "my (weird) app", ticks=150, starttime=777, rss_pages=25, state="R", ppid=7))
        self.assertEqual((st["pid"], st["comm"], st["state"], st["ppid"]), (42, "my (weird) app", "R", 7))
        self.assertEqual((st["ticks"], st["starttime"], st["rss_pages"], st["flags"]), (150, 777, 25, 0))
        self.assertIsNone(C.parse_stat("basura"))
        self.assertIsNone(C.parse_stat("1 (x) S 1 2"))

    def test_cpu_meminfo_loadavg_uptime(self):
        cpu = C.parse_cpu_stat("cpu  10 0 5 80 5 0 0 0 9 0\ncpu0 1 1 1 1 1 0 0 0 0 0\ncpu1 1 1 1 1 1 0 0 0 0 0\nintr 1\n")
        self.assertEqual(cpu, {"busy": 15, "total": 100, "cpus": 2})
        self.assertIsNone(C.parse_cpu_stat("nada"))
        mem = C.parse_meminfo("MemTotal:  1000 kB\nMemAvailable:   400 kB\nHugePages_Total:  0\n")
        self.assertEqual((mem["MemTotal"], mem["MemAvailable"]), (1000, 400))
        self.assertEqual(C.parse_loadavg("0.50 0.25 0.10 2/300 1234\n"), (0.5, 0.25, 0.1))
        self.assertIsNone(C.parse_loadavg(""))
        self.assertEqual(C.parse_uptime("123.45 99.0\n"), 123.45)

    def test_cmdline_y_environ(self):
        self.assertEqual(C.parse_cmdline(b"node\0--flag\0/x/app.js\0"), ["node", "--flag", "/x/app.js"])
        self.assertEqual(C.parse_cmdline(b""), [])
        env = b"A=1\0T3CODE_THREAD_ID=abc-123\0B=2\0"
        self.assertEqual(C.parse_environ_var(env, "T3CODE_THREAD_ID"), "abc-123")
        self.assertIsNone(C.parse_environ_var(env, "NOPE"))

    def test_cgroup(self):
        self.assertEqual(C.parse_cgroup("0::/system.slice/t3code.service\n"), "/system.slice/t3code.service")
        v1 = "12:cpu:/foo\n1:name=systemd:/user.slice/x.service\n"
        self.assertEqual(C.parse_cgroup(v1), "/user.slice/x.service")
        self.assertEqual(C.parse_cgroup(""), "/")

    def test_cgroup_label(self):
        self.assertEqual(C.cgroup_label(CG_AGENT), "app-t3code-agents.slice")      # el slice por instancia se reporta como su padre
        self.assertEqual(C.cgroup_label("/user.slice/user-1000.slice/user@1000.service/app.slice/t3code.service"), "t3code.service")
        self.assertEqual(C.cgroup_label("/chopshop-servers.slice/chopshop-ts-proyecto-demo-l-0001.service"),
                         "chopshop-ts-proyecto-demo-l-0001.service")
        self.assertEqual(C.cgroup_label("/user.slice/user-1000.slice/session-3.scope"), None)
        self.assertEqual(C.cgroup_label("/"), None)
        self.assertEqual(C.cgroup_label("/system.slice/ssh.service"), "ssh.service")

    def test_project_from_cgroup(self):
        self.assertEqual(C.project_from_cgroup("/chopshop-servers.slice/chopshop-ts-proyecto-demo-l-0001.service"), "proyecto-demo")
        self.assertEqual(C.project_from_cgroup("/a/chopshop-ts-web-ab12.service"), "web")
        self.assertIsNone(C.project_from_cgroup("/chopshop-servers.slice"))
        self.assertIsNone(C.project_from_cgroup(CG_AGENT))

    def test_app_name(self):
        cases = [
            ("python3", ["/usr/bin/python3.12", "-m", "pytest"], "python"),
            ("node", ["node", "/x/node_modules/vitest/vitest.mjs", "run"], "vitest"),
            ("node", ["node", "/x/node_modules/typescript/lib/tsc.js", "--noEmit"], "tsc"),
            ("node", ["node", "--max-old-space-size=4096", "/x/@anthropic-ai/claude-code/cli.js"], "claude"),
            ("node", ["node", "-r", "ts-node/register", "/x/server.js"], "node"),
            ("node", ["node", "-e", "console.log(1)"], "node"),
            ("claude", ["claude"], "claude"),
            ("codex", ["/opt/codex/bin/codex", "exec"], "codex"),
            ("chrome", ["/opt/google/chrome/chrome", "--type=renderer"], "chrome"),
            ("chromium-browse", ["/usr/lib/chromium/chromium-browser"], "chrome"),
            ("bash", ["-bash"], "bash"),
            ("git", ["git", "status"], "git"),
            ("next-server (v1", ["next-server (v14.2)"], "next-server"),
            ("kworker-ish", [], "kworker-ish"),
        ]
        for comm, argv, expected in cases:
            self.assertEqual(C.app_name(comm, argv), expected, argv)

    def test_project_for_path(self):
        explicit, roots = C.build_matchers({
            "projects_root": "/work/projects", "worktrees_root": "/work/wt",
            "projects": {"especial": {"root": "/otro/lugar/especial", "worktrees": "/otro/wt-especial"}}})
        f = lambda p: C.project_for_path(p, explicit, roots)  # noqa: E731
        self.assertEqual(f("/work/projects/proyecto-demo/src"), "proyecto-demo")
        self.assertEqual(f("/work/wt/proyecto-demo/rama-1/pkg"), "proyecto-demo")
        self.assertEqual(f("/otro/lugar/especial"), "especial")
        self.assertEqual(f("/otro/wt-especial/x/y"), "especial")
        self.assertEqual(f("/work/projects/proyecto-demo (deleted)"), "proyecto-demo")
        self.assertIsNone(f("/work/projects"))
        self.assertIsNone(f("/work/projectsx/foo"))
        self.assertIsNone(f("/tmp"))
        self.assertIsNone(f(None))


class TestSampling(CollectorBase):
    def populate(self):
        p = self.proc
        p.set_machine(busy=100, idle=900)
        p.add(10, "node", ["node", "/x/node_modules/vitest/vitest.mjs"], cwd=os.path.join(self.proj_root, "proyecto-demo", "pkg"),
              cgroup=CG_AGENT, ticks=1000, starttime=50, rss_pages=2560)             # 10 MB
        p.add(11, "node", ["node", "/x/server.js"], cwd=os.path.join(self.wt_root, "proyecto-demo", "rama-1"),
              cgroup=CG_AGENT, ticks=0, starttime=50, rss_pages=5120)                # 20 MB
        p.add(12, "python3", ["python3", "-m", "http.server"], cwd=self.tmp, ticks=0, starttime=60, rss_pages=256)
        p.add(13, "bash", ["bash"], cwd=self.tmp, cgroup="/chopshop-servers.slice/chopshop-ts-otro-l-0002.service",
              ticks=0, starttime=60, rss_pages=256)
        p.add(14, "kthreadd", [], flags=C.PF_KTHREAD, rss_pages=999)
        p.add(15, "defunct", [], state="Z", rss_pages=999)
        os.makedirs(os.path.join(self.tmp, "no-proj"), exist_ok=True)

    def test_primera_muestra_cpu_cero_y_agrupacion(self):
        self.populate()
        s = self.col.sample_once()
        self.assertEqual(set(s), {"machine", "apps", "projects"})
        m = s["machine"]
        self.assertEqual((m["cpus"], m["cpu_pct"], m["load"]), (4, 0.0, [0.1, 0.2, 0.3]))
        self.assertEqual((m["ram_total_mb"], m["ram_avail_mb"], m["ram_pct"], m["swap_used_mb"]), (8192, 6144, 25, 1))
        self.assertEqual((m["os"], m["uptime"], m["procs"]), (os.uname().sysname, 1000, 4))     # kthread y zombi fuera
        self.assertGreater(m["disk_total_gb"], 0)
        apps = {a["name"]: a for a in s["apps"]}
        self.assertEqual(set(apps), {"vitest", "node", "python", "bash"})
        self.assertTrue(all(a["cpu_pct"] == 0.0 for a in s["apps"]))
        self.assertEqual((apps["vitest"]["rss_mb"], apps["vitest"]["procs"]), (10.0, 1))
        self.assertEqual(apps["node"]["cgroups"], ["app-t3code-agents.slice"])
        projs = {p["name"]: p for p in s["projects"]}
        self.assertEqual(set(projs), {"proyecto-demo", "otro"})                    # 'otro' sale del cgroup chopshop-ts-
        self.assertEqual((projs["proyecto-demo"]["procs"], projs["proyecto-demo"]["rss_mb"]), (2, 30.0))

    def test_cpu_por_delta(self):
        self.populate()
        self.col.sample_once()
        self.advance(10)
        self.proc.set_machine(busy=150, idle=950, uptime=1010.0)                     # 50 de 100 jiffies ocupados
        self.proc.set_ticks(10, 1200, starttime=50, rss_pages=2560)                   # +200 ticks en 10 s = 20 %
        s = self.col.sample_once()
        self.assertEqual(s["machine"]["cpu_pct"], 50.0)
        apps = {a["name"]: a for a in s["apps"]}
        self.assertEqual(apps["vitest"]["cpu_pct"], 20.0)
        self.assertEqual(apps["node"]["cpu_pct"], 0.0)
        projs = {p["name"]: p for p in s["projects"]}
        self.assertEqual(projs["proyecto-demo"]["cpu_pct"], 20.0)
        self.assertEqual(s["apps"][0]["name"], "vitest")                              # ordenadas por CPU

    def test_proceso_nuevo_cuenta_todo_y_el_viejo_desconocido_no(self):
        self.populate()
        self.col.sample_once()
        self.advance(10)
        self.proc.set_machine(uptime=1010.0)
        self.proc.add(20, "git", ["git", "gc"], cwd=self.tmp, ticks=100, starttime=100500, rss_pages=10)   # nació a los 1005 s
        self.proc.add(21, "git", ["git", "log"], cwd=self.tmp, ticks=300, starttime=500, rss_pages=10)      # nació antes y no se vio
        s = self.col.sample_once()
        apps = {a["name"]: a for a in s["apps"]}
        self.assertEqual(apps["git"]["cpu_pct"], 10.0)        # solo los 100 ticks del proceso nuevo en 10 s

    def test_proceso_que_termina_y_reuso_de_pid(self):
        self.populate()
        self.col.sample_once()
        self.advance(10)
        self.proc.remove(12)
        # mismo pid 11 pero otro proceso (starttime distinto): no hereda el delta del anterior
        self.proc.add(11, "node", ["node", "/x/server.js"], cwd=self.tmp, ticks=5000, starttime=90000, rss_pages=1)
        self.proc.set_machine(uptime=1010.0)
        s = self.col.sample_once()
        apps = {a["name"]: a for a in s["apps"]}
        self.assertNotIn("python", apps)
        self.assertEqual(apps["node"]["cpu_pct"], 0.0)

    def test_thread_id_de_t3_asigna_proyecto(self):
        self.conn.execute("INSERT INTO t3_threads(thread_id, project, status) VALUES ('thr-1', 'proyecto-demo', 'running')")
        self.proc.add(30, "node", ["node", "/x/agent.js"], cwd=self.tmp, rss_pages=256, environ={"HOME": "x", "T3CODE_THREAD_ID": "thr-1"})
        self.proc.add(31, "node", ["node", "/x/agent.js"], cwd=self.tmp, rss_pages=256, environ={"T3CODE_THREAD_ID": "desconocido"})
        self.proc.add(32, "node", ["node", "/x/agent.js"], cwd=self.tmp, rss_pages=256)                  # sin environ legible
        s = self.col.sample_once()
        self.assertEqual([(p["name"], p["procs"]) for p in s["projects"]], [("proyecto-demo", 1)])

    def test_cwd_tiene_prioridad_sobre_thread_id(self):
        self.conn.execute("INSERT INTO t3_threads(thread_id, project, status) VALUES ('thr-1', 'otro-proyecto', 'running')")
        self.proc.add(30, "node", ["node", "/x/agent.js"], cwd=os.path.join(self.proj_root, "proyecto-demo"), rss_pages=256,
                      environ={"T3CODE_THREAD_ID": "thr-1"})
        s = self.col.sample_once()
        self.assertEqual([p["name"] for p in s["projects"]], ["proyecto-demo"])

    def test_cache_por_pid_starttime_comm(self):
        self.proc.add(40, "node", ["node", "/x/server.js"], cwd=self.tmp, rss_pages=1)
        self.assertEqual(self.col.sample_once()["apps"][0]["name"], "node")
        self.advance(10)
        self.proc.write("40/cmdline", b"node\0/x/node_modules/vite/bin/vite.js\0", binary=True)
        self.assertEqual(self.col.sample_once()["apps"][0]["name"], "node")        # cacheado: no relee cmdline
        self.advance(10)
        self.proc.add(40, "vite", ["node", "/x/node_modules/vite/bin/vite.js"], cwd=self.tmp, rss_pages=1)   # exec: cambia comm
        self.assertEqual(self.col.sample_once()["apps"][0]["name"], "vite")

    def test_top_n_limita_apps_persistidas(self):
        self.col.top_n = 2
        for i in range(10):
            self.proc.add(50 + i, "app%d" % i, ["/bin/app%d" % i], rss_pages=100 * (i + 1))
        s = self.col.sample_once()
        names = {a["name"] for a in s["apps"]}
        self.assertTrue({"app9", "app8"} <= names)
        self.assertLessEqual(len(names), 4)

    def test_persistencia_y_latest(self):
        self.populate()
        s = self.col.sample_once()
        self.assertEqual(self.col.latest(), s)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM machine_samples").fetchone()[0], 1)
        kinds = {r[0]: r[1] for r in self.conn.execute("SELECT kind, COUNT(*) FROM samples GROUP BY kind")}
        self.assertEqual(kinds, {"app": 4, "project": 2})
        # un colector nuevo (reinicio del agente) reconstruye latest() desde la DB
        again = C.Collector(self.cfg, self.conn, proc_root=self.proc.root, clock=self.clock).latest()
        self.assertEqual(again["machine"]["cpus"], 4)
        self.assertEqual({a["name"] for a in again["apps"]}, {a["name"] for a in s["apps"]})
        self.assertEqual(again["apps"][0]["cgroups"], s["apps"][0]["cgroups"])
        # sin muestras: estructura vacía
        empty = C.Collector(self.cfg, db.connect(os.path.join(self.tmp, "otra.db")), proc_root=self.proc.root).latest()
        self.assertEqual(empty, {"machine": {}, "apps": [], "projects": []})

    def test_proc_vacio_no_revienta(self):
        col = C.Collector(self.cfg, self.conn, proc_root=os.path.join(self.tmp, "no-existe"), clock=self.clock)
        s = col.sample_once()
        self.assertEqual((s["apps"], s["projects"], s["machine"]["ram_total_mb"]), ([], [], 0))

    def test_interval_con_backoff(self):
        self.assertEqual(self.col.interval(), 10)                       # sin muestras
        self.proc.set_machine(load=(1.0, 1, 1), cpus=4)                  # 1.0 < 0.5*4 = 2
        self.col.sample_once()
        self.assertEqual(self.col.interval(), 10)
        self.advance(10)
        self.proc.set_machine(load=(2.5, 1, 1), cpus=4)                  # > 0.5*cpus
        self.col.sample_once()
        self.assertEqual(self.col.interval(), 30)
        self.advance(10)
        self.proc.set_machine(load=(9.0, 1, 1), cpus=4)                  # > cpus
        self.col.sample_once()
        self.assertEqual(self.col.interval(), 60)
        self.cfg["sample_interval"] = 120
        self.assertEqual(self.col.interval(), 120)                       # nunca baja del base

    def test_run_forever_sigue_tras_un_fallo(self):
        class Stop(object):
            def __init__(self):
                self.waits = 0

            def is_set(self):
                return self.waits >= 3

            def wait(self, secs):
                self.waits += 1
                return False

        self.proc.add(60, "node", ["node"], rss_pages=1)
        calls = []
        real = self.col.sample_once

        def flaky():
            calls.append(1)
            if len(calls) == 1:
                raise RuntimeError("boom")
            self.advance(10)
            return real()

        self.col.sample_once = flaky
        self.col.run_forever(Stop(), compact_every=0)
        self.assertEqual(len(calls), 3)
        self.assertIsNone(self.col.last_error)

    @unittest.skipUnless(os.path.isdir("/proc/self"), "requiere /proc real")
    def test_humo_sobre_proc_real(self):
        col = C.Collector(self.cfg, self.conn, clock=self.clock)
        col.sample_once()
        self.advance(1)
        s = col.sample_once()
        self.assertGreater(s["machine"]["procs"], 0)
        self.assertGreater(s["machine"]["cpus"], 0)
        self.assertTrue(s["apps"])
        self.assertTrue(all(a["rss_mb"] >= 0 and a["cpu_pct"] >= 0 for a in s["apps"]))


class TestCompactAndQuery(CollectorBase):
    def fill(self, start, count, step=10, cpu=lambda i: 10.0, rss_pages=2560, extra_app=False):
        """`count` muestras cada `step` s empezando en `start`, con un proceso 'node' en proyecto-demo."""
        self.clock.t = start
        cwd = os.path.join(self.proj_root, "proyecto-demo")
        ticks = 0
        busy = 0
        self.proc.add(70, "node", ["node", "/x/server.js"], cwd=cwd, starttime=1, rss_pages=rss_pages)
        for i in range(count):
            ticks += int(cpu(i) * step)             # cpu% de un núcleo * step s = ticks (CLK_TCK=100)
            busy += int(cpu(i))
            self.proc.set_machine(busy=busy, idle=i * 100, uptime=100.0 + i * step)
            self.proc.set_ticks(70, ticks, starttime=1, rss_pages=rss_pages)
            if extra_app and i % 2 == 0:
                self.proc.add(71, "git", ["git"], cwd=self.tmp, starttime=1, rss_pages=256)
            elif os.path.isdir(os.path.join(self.proc.root, "71")):
                self.proc.remove(71)
            self.col.sample_once()
            self.advance(step)

    def test_compact_1m_y_idempotencia(self):
        start = 1_000_020.0                        # 20 s dentro del minuto 1_000_020 // 60 * 60 = 999_960
        self.fill(start, 30)                       # 300 s de datos
        self.clock.t = start + 300
        res = self.col.compact()
        self.assertGreater(res["m1"], 0)
        rows = self.conn.execute("SELECT ts, kind, name, cpu_avg, cpu_max, rss_avg, n FROM samples_agg WHERE res='1m' AND kind='app' ORDER BY ts").fetchall()
        self.assertTrue(rows)
        full = [r for r in rows if r["n"] == 6]    # cubetas completas: 6 muestras de 10 s
        self.assertTrue(full)
        r = full[0]
        # la primera muestra global tiene cpu 0 por definición; el resto, 10 %
        self.assertTrue(abs(r["cpu_avg"] - 10.0) < 1e-6 or abs(r["cpu_avg"] - 8.333333) < 1e-3, r["cpu_avg"])
        self.assertEqual(r["name"], "node")
        self.assertAlmostEqual(r["rss_avg"], 10.0, places=3)
        mach = self.conn.execute("SELECT * FROM samples_agg WHERE res='1m' AND kind='machine'").fetchall()
        self.assertTrue(mach and mach[0]["name"] == "machine")
        before = [tuple(x) for x in self.conn.execute("SELECT * FROM samples_agg ORDER BY res,ts,kind,name")]
        again = self.col.compact()
        self.assertEqual(again["m1"], 0)
        self.assertEqual([tuple(x) for x in self.conn.execute("SELECT * FROM samples_agg ORDER BY res,ts,kind,name")], before)

    def test_compact_solo_cubetas_completas(self):
        self.fill(1_000_020.0, 3)                  # 30 s, dentro de un solo minuto
        self.clock.t = 1_000_050.0
        self.assertEqual(self.col.compact()["m1"], 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM samples_agg").fetchone()[0], 0)

    def test_compact_1h_ponderado(self):
        start = 3600.0 * 300                       # alineado a la hora
        self.fill(start, 360 * 2 + 30, cpu=lambda i: 20.0 if i < 360 else 40.0)
        self.clock.t = start + 3600 * 3
        res = self.col.compact()
        self.assertGreater(res["h1"], 0)
        hrs = self.conn.execute("SELECT ts, cpu_avg, cpu_max, n FROM samples_agg WHERE res='1h' AND kind='app' AND name='node' ORDER BY ts").fetchall()
        self.assertEqual([h["ts"] for h in hrs][:2], [start, start + 3600])      # la tercera hora (parcial) también se cierra a las 3 h
        self.assertAlmostEqual(hrs[0]["cpu_avg"], 20.0 * 359 / 360, delta=0.1)     # la 1ª muestra es 0
        self.assertAlmostEqual(hrs[1]["cpu_avg"], 40.0, delta=0.1)
        self.assertEqual(hrs[1]["cpu_max"], 40.0)
        self.assertEqual(hrs[1]["n"], 360)

    def test_retencion(self):
        start = 3600.0 * 300
        self.fill(start, 360 * 2)
        now = start + 3600 * 40                    # 40 h después: lo crudo pasa de 24 h
        self.col.compact(now)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM machine_samples").fetchone()[0], 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM samples").fetchone()[0], 0)
        self.assertGreater(self.conn.execute("SELECT COUNT(*) FROM samples_agg WHERE res='1m'").fetchone()[0], 0)
        self.assertGreater(self.conn.execute("SELECT COUNT(*) FROM samples_agg WHERE res='1h'").fetchone()[0], 0)
        # 31 días: caen los 1m; 366 días: caen los 1h
        self.col.compact(start + 86400 * 31)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM samples_agg WHERE res='1m'").fetchone()[0], 0)
        self.assertGreater(self.conn.execute("SELECT COUNT(*) FROM samples_agg WHERE res='1h'").fetchone()[0], 0)
        self.col.compact(start + 86400 * 366)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM samples_agg").fetchone()[0], 0)

    def test_no_borra_crudo_sin_compactar(self):
        start = 3600.0 * 300
        self.fill(start, 30)
        # el reloj salta 2 días sin compactar nunca: compact() agrega primero y luego purga, sin perder nada
        self.col.compact(start + 86400 * 2)
        self.assertGreater(self.conn.execute("SELECT COUNT(*) FROM samples_agg WHERE res='1m'").fetchone()[0], 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM machine_samples").fetchone()[0], 0)

    def test_query_crudo(self):
        start = 1_000_000.0
        self.fill(start, 12)                       # 120 s
        q = C.query(self.conn, start - 5, start + 130, "machine")
        self.assertEqual((q["group"], q["res"], q["step"]), ("machine", "raw", 10.0))
        self.assertEqual([s["name"] for s in q["series"]], ["machine"])
        pts = q["series"][0]["points"]
        self.assertEqual(len(pts), 12)
        self.assertEqual(pts[0][0], start)
        self.assertAlmostEqual(pts[0][2], 8192 - 6144, delta=0.1)       # rss de la máquina = RAM usada
        qa = C.query(self.conn, start, start + 130, "app")
        self.assertEqual([s["name"] for s in qa["series"]], ["node"])
        self.assertEqual(qa["series"][0]["points"][3][1:], [10.0, 10.0])
        qp = C.query(self.conn, start, start + 130, "project")
        self.assertEqual([s["name"] for s in qp["series"]], ["proyecto-demo"])
        self.assertEqual(C.query(self.conn, start, start + 130, "app", name="nada")["series"], [])

    def test_query_downsample_con_step(self):
        start = 1_000_020.0
        self.fill(start, 30)
        q = C.query(self.conn, start, start + 300, "app", step=30)
        self.assertEqual((q["res"], q["step"]), ("raw", 30.0))
        pts = q["series"][0]["points"]
        self.assertTrue(all(b[0] - a[0] == 30 for a, b in zip(pts, pts[1:])))
        self.assertEqual(pts[2][1], 10.0)

    def test_query_1m_con_cola_sin_compactar(self):
        start = 1_000_020.0
        self.fill(start, 30)
        # sin compactar: 1m se calcula al vuelo desde lo crudo
        q = C.query(self.conn, start - 100, start + 400, "app", step=60)
        self.assertEqual((q["res"], q["step"]), ("1m", 60.0))
        raw_view = q["series"][0]["points"]
        self.assertTrue(len(raw_view) >= 4)
        self.clock.t = start + 300
        self.col.compact()
        q2 = C.query(self.conn, start - 100, start + 400, "app", step=60)
        self.assertEqual(q2["res"], "1m")
        self.assertEqual([p[0] for p in q2["series"][0]["points"]], [p[0] for p in raw_view])    # compactar no duplica ni pierde cubetas
        for a, b in zip(q2["series"][0]["points"], raw_view):
            self.assertAlmostEqual(a[1], b[1], places=1)

    def test_query_elige_resolucion_por_rango(self):
        start = 3600.0 * 300
        self.fill(start, 360 * 3)
        self.col.compact(start + 3600 * 5)
        self.assertEqual(C.query(self.conn, start, start + 3600, "machine")["res"], "raw")          # <= 2 h
        q = C.query(self.conn, start, start + 3600 * 6, "machine")                                   # > 2 h
        self.assertEqual((q["res"], q["step"]), ("1m", 60.0))
        q = C.query(self.conn, start, start + 86400 * 10, "machine")                                  # > 3 d
        self.assertEqual((q["res"], q["step"]), ("1h", 3600.0))
        self.assertEqual(len(q["series"][0]["points"]), 3)       # 3 horas con datos (la última parcial)
        q = C.query(self.conn, start, start + 3600 * 3, "app", step=3600)
        self.assertEqual(q["res"], "1h")

    def test_query_cae_a_resolucion_mas_gruesa_si_no_hay_crudo(self):
        start = 3600.0 * 300
        self.fill(start, 360 * 2)
        self.col.compact(start + 3600 * 40)                                  # el crudo ya se purgó
        q = C.query(self.conn, start, start + 600, "app")                    # rango corto -> pediría crudo
        self.assertEqual(q["res"], "1m")
        self.assertTrue(q["series"][0]["points"])

    def test_query_errores(self):
        with self.assertRaises(C.CollectorError):
            C.query(self.conn, 0, 10, "otra-cosa")
        with self.assertRaises(C.CollectorError):
            C.query(self.conn, 10, 0, "app")
        with self.assertRaises(C.CollectorError):
            C.query(self.conn, "x", 10, "app")
        with self.assertRaises(C.CollectorError):
            C.query(self.conn, 0, 10, "app", step=-1)
        self.assertEqual(C.query(self.conn, 0, 10, "app")["series"], [])       # sin datos: vacío, no error

    def test_series_ordenadas_por_cpu(self):
        start = 1_000_000.0
        self.fill(start, 6, extra_app=True)
        q = C.query(self.conn, start, start + 100, "app")
        self.assertEqual([s["name"] for s in q["series"]][0], "node")
        self.assertIn("git", [s["name"] for s in q["series"]])


if __name__ == "__main__":
    unittest.main()
