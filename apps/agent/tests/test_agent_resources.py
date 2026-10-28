"""Pruebas de chopshop.agent.resources. Cero systemd real: runner, reloj, sleep, kill_fn, cgroup y /proc son falsos."""
import ast
import copy
import os
import shutil
import signal
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import settings  # noqa: E402
from chopshop.agent import db, resources  # noqa: E402

T0 = 1_000_000.0


class Clock:
    def __init__(self):
        self.t = T0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


class FakeSystemd:
    """Imita systemd-run / systemctl --user show|stop|list-units con un diccionario de unidades."""

    def __init__(self):
        self.calls = []
        self.units = {}                 # "nombre.service" -> {"state": "active", "pid": n}
        self.stopped = []
        self.fail_run = False
        self.fail_stop = False

    def __call__(self, argv):
        self.calls.append(list(argv))
        if argv[0] == "systemd-run":
            if self.fail_run:
                return 1, "", "Failed to start transient service"
            unit = next(a[len("--unit="):] for a in argv if a.startswith("--unit="))
            self.units[unit + ".service"] = {"state": "active", "pid": 5000 + len(self.units)}
            return 0, "Running as unit: %s.service" % unit, ""
        if argv[:3] == ["systemctl", "--user", "show"]:
            u = self.units.get(argv[3])
            if not u:
                return 0, "ActiveState=inactive\nMainPID=0\n", ""
            return 0, "ActiveState=%s\nMainPID=%d\n" % (u["state"], u["pid"]), ""
        if argv[:3] == ["systemctl", "--user", "stop"]:
            self.stopped.append(argv[3])
            if self.fail_stop:
                return 1, "", "no se pudo parar"
            self.units.pop(argv[3], None)
            return 0, "", ""
        if argv[:3] == ["systemctl", "--user", "list-units"]:
            return 0, "".join("%s loaded %s running desc\n" % (n, u["state"]) for n, u in sorted(self.units.items())), ""
        return 1, "", "comando inesperado %r" % (argv,)

    def started(self):
        return [a for a in self.calls if a[0] == "systemd-run"]


class FakeCollector:
    def __init__(self, machine):
        self.machine = machine

    def latest(self):
        return {"machine": self.machine, "apps": [], "projects": []}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-res-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.clock = Clock()
        self.sd = FakeSystemd()
        self.events = []
        self.conn = db.connect(os.path.join(self.tmp, "agent", "agent.db"))
        self.addCleanup(self.conn.close)
        self.cfg = copy.deepcopy(settings.DEFAULTS["agent"])
        self.cfg["projects"] = {
            "proyecto-demo": {"test_server": {"cmd": "pnpm dev", "port_env": "PORT", "idle_seconds": 600,
                                              "cpu_quota": "150%", "mem_max": "1G"}},
            "proyecto-otro": {"test_server": {"cmd": "npm run start"}},
            "proyecto-tercero": {"test_server": {"cmd": "make serve"}},
            "sin-cmd": {},
        }
        self.proc = os.path.join(self.tmp, "proc")
        os.makedirs(os.path.join(self.proc, "net"))
        self.cgroup = os.path.join(self.tmp, "cgroup", "app-t3code-agents.slice")
        os.makedirs(self.cgroup)

    def mk(self, **kw):
        kw.setdefault("runner", self.sd)
        kw.setdefault("clock", self.clock)
        kw.setdefault("sleep", self.clock.sleep)
        kw.setdefault("proc_root", self.proc)
        kw.setdefault("cgroup_root", self.cgroup)
        return resources.Resources(self.cfg, self.conn, lambda e, p, b: self.events.append((e, p, b)), **kw)

    def wt(self, name):
        p = os.path.join(self.tmp, "worktrees", name)
        os.makedirs(p, exist_ok=True)
        return p

    def names(self):
        return [e[0] for e in self.events]


class TestPorts(Base):
    def test_deterministic_and_persisted(self):
        r = self.mk()
        a = r.ports_for("proyecto-demo", self.wt("a"))
        self.assertEqual(a, r.ports_for("proyecto-demo", self.wt("a")))
        lo, hi = self.cfg["ports"]["range"]
        self.assertTrue(lo <= a["base"] and a["range"][1] <= hi)
        self.assertEqual(a["range"][1] - a["base"], self.cfg["ports"]["per_worktree"] - 1)
        self.assertEqual((a["base"] - lo) % self.cfg["ports"]["per_worktree"], 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM ports").fetchone()[0], 1)
        # otra base de datos (otro proceso/arranque): mismo worktree -> mismo bloque (hash determinista)
        conn2 = db.connect(os.path.join(self.tmp, "otro", "agent.db"))
        self.addCleanup(conn2.close)
        r2 = resources.Resources(self.cfg, conn2, None, runner=self.sd, proc_root=self.proc)
        self.assertEqual(r2.ports_for("proyecto-demo", self.wt("a")), a)

    def test_no_collisions_and_exhaustion(self):
        self.cfg["ports"] = {"range": [41000, 41039], "per_worktree": 10}      # 4 bloques
        r = self.mk()
        bases = [r.ports_for("proyecto-demo", self.wt("w%d" % i))["base"] for i in range(4)]
        self.assertEqual(sorted(bases), [41000, 41010, 41020, 41030])
        with self.assertRaises(resources.ResourcesError):
            r.ports_for("proyecto-demo", self.wt("w4"))

    def test_many_worktrees_never_overlap(self):
        r = self.mk()
        bases = sorted(r.ports_for("proyecto-demo", self.wt("m%d" % i))["base"] for i in range(80))
        for x, y in zip(bases, bases[1:]):
            self.assertGreaterEqual(y - x, self.cfg["ports"]["per_worktree"])

    def test_skips_blocks_with_listeners(self):
        self.cfg["ports"] = {"range": [41000, 41009], "per_worktree": 10}      # un solo bloque
        with open(os.path.join(self.proc, "net", "tcp"), "w") as f:
            f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
                    "   0: 0100007F:A029 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 555 1 0 100 0 0 10 0\n")
        with self.assertRaises(resources.ResourcesError):      # 0xA029 = 41001 escucha dentro del único bloque
            self.mk().ports_for("proyecto-demo", self.wt("a"))

    def test_port_lease_kind(self):
        r = self.mk()
        lease = r.request("proyecto-demo", self.wt("a"), kind="port")
        self.assertEqual(lease["state"], "active")
        self.assertEqual(lease["port"], r.ports_for("proyecto-demo", self.wt("a"))["base"])
        self.assertEqual(self.sd.calls, [])
        self.assertEqual(self.names(), ["lease_active"])


class TestRequest(Base):
    def test_start_builds_systemd_run(self):
        r = self.mk()
        w = self.wt("a")
        lease = r.request("proyecto-demo", w, thread_id="th-1")
        self.assertEqual(lease["id"], "l-0001")
        self.assertEqual(lease["state"], "active")
        self.assertEqual(lease["unit"], "chopshop-ts-proyecto-demo-l-0001")
        self.assertEqual(lease["pid"], 5000)
        argv = self.sd.started()[0]
        self.assertEqual(argv[:3], ["systemd-run", "--user", "--unit=chopshop-ts-proyecto-demo-l-0001"])
        self.assertIn("--collect", argv)
        for prop in ("CPUQuota=150%", "MemoryMax=1G", "Slice=chopshop-servers.slice", "Environment=PORT=%d" % lease["port"]):
            i = argv.index(prop)
            self.assertEqual(argv[i - 1], "-p")
        self.assertIn("--working-directory=" + w, argv)
        self.assertEqual(argv[argv.index("--") + 1:], ["pnpm", "dev"])
        self.assertEqual(self.conn.execute("SELECT lease_id FROM ports WHERE port=?", (lease["port"],)).fetchone()[0], "l-0001")
        self.assertEqual(self.names(), ["lease_active"])
        self.assertEqual(self.events[0][1], "proyecto-demo")
        self.assertEqual(self.events[0][2]["lease_id"], "l-0001")

    def test_idempotent_for_same_worktree(self):
        r = self.mk()
        a = r.request("proyecto-demo", self.wt("a"))
        b = r.request("proyecto-demo", self.wt("a"), thread_id="th-9")
        self.assertEqual(a["id"], b["id"])
        self.assertEqual(b["thread_id"], "th-9")
        self.assertEqual(len(self.sd.started()), 1)

    def test_cmd_override_and_missing_cmd(self):
        r = self.mk()
        lease = r.request("sin-cmd", self.wt("s"), cmd="python3 -m http.server")
        self.assertEqual(self.sd.started()[0][-3:], ["python3", "-m", "http.server"])
        self.assertEqual(lease["state"], "active")
        bad = r.request("sin-cmd", self.wt("s2"))
        self.assertEqual(bad["state"], "failed")
        self.assertIn("test_server.cmd", bad["reason"])
        self.assertIn("lease_failed", self.names())
        self.assertEqual(len(self.sd.started()), 1)

    def test_legacy_test_cmd_key(self):
        self.cfg["projects"]["viejo"] = {"test_cmd": "npm test"}
        lease = self.mk().request("viejo", self.wt("v"))
        self.assertEqual(lease["cmd"], "npm test")
        self.assertEqual(lease["state"], "active")

    def test_systemd_failure_marks_failed(self):
        self.sd.fail_run = True
        lease = self.mk().request("proyecto-demo", self.wt("a"))
        self.assertEqual(lease["state"], "failed")
        self.assertIn("systemd-run", lease["reason"])
        self.assertIsNone(self.conn.execute("SELECT lease_id FROM ports").fetchone()[0])

    def test_missing_cwd_fails_without_running(self):
        lease = self.mk().request("proyecto-demo", os.path.join(self.tmp, "no-existe"))
        self.assertEqual(lease["state"], "failed")
        self.assertEqual(self.sd.started(), [])

    def test_validation(self):
        r = self.mk()
        with self.assertRaises(ValueError):
            r.request("proyecto-demo", self.wt("a"), kind="otra")
        with self.assertRaises(ValueError):
            r.request("")


class TestQueue(Base):
    def test_one_server_per_project(self):
        r = self.mk()
        a = r.request("proyecto-demo", self.wt("a"))
        b = r.request("proyecto-demo", self.wt("b"))
        self.assertEqual((a["state"], b["state"]), ("active", "queued"))
        self.assertEqual(b["position"], 1)
        self.assertEqual(self.names(), ["lease_active", "lease_queued"])
        self.assertEqual(self.events[1][2]["position"], 1)
        c = r.request("proyecto-otro", self.wt("c"))           # otro proyecto no espera
        self.assertEqual(c["state"], "active")
        r.tick(sweep=False)
        self.assertEqual(r.status()["queued"][0]["id"], b["id"])
        r.release(lease_id=a["id"])
        out = r.tick(sweep=False)
        self.assertEqual(out["promoted"], [b["id"]])
        st = r.status()
        self.assertEqual(sorted(x["id"] for x in st["active"]), sorted([b["id"], c["id"]]))
        self.assertEqual(st["queued"], [])
        self.assertEqual(st["capacity"]["used"], 2)

    def test_fifo_and_project_skip(self):
        self.cfg["capacity"]["max_servers"] = 2
        r = self.mk()
        a = r.request("proyecto-demo", self.wt("a"))
        b = r.request("proyecto-otro", self.wt("b"))
        c = r.request("proyecto-tercero", self.wt("c"))        # global lleno -> cola
        d = r.request("proyecto-demo", self.wt("d"))
        self.assertEqual([a["state"], b["state"], c["state"], d["state"]], ["active", "active", "queued", "queued"])
        self.assertEqual((c["position"], d["position"]), (1, 2))
        r.release(lease_id=b["id"])
        r.tick(sweep=False)
        st = r.status()
        # c (primero de la cola) entra; d espera por tope de proyecto (a sigue activo) y por global
        self.assertEqual(sorted(x["id"] for x in st["active"]), sorted([a["id"], c["id"]]))
        self.assertEqual([x["id"] for x in st["queued"]], [d["id"]])
        r.release(lease_id=a["id"])
        r.tick(sweep=False)
        self.assertEqual(r.status()["queued"], [])

    def test_blocked_by_project_does_not_block_others(self):
        self.cfg["capacity"]["max_servers"] = 2
        r = self.mk()
        r.request("proyecto-demo", self.wt("a"))
        r.request("proyecto-demo", self.wt("b"))               # cola (proyecto)
        c = r.request("proyecto-otro", self.wt("c"))           # no se queda detrás de b
        self.assertEqual(c["state"], "active")

    def test_ram_and_cpu_limits_use_collector(self):
        machine = {"cpus": 4, "cpu_pct": 10, "ram_avail_mb": 1000}
        r = self.mk(collector=FakeCollector(machine))
        a = r.request("proyecto-demo", self.wt("a"))
        self.assertEqual(a["state"], "queued")                  # RAM disponible < min_ram_avail_mb (6000)
        machine["ram_avail_mb"] = 20000
        r.tick(sweep=False)
        self.assertEqual(r.status()["active"][0]["id"], a["id"])
        machine["cpu_pct"] = 90                                 # 90 % de 4 núcleos = 360 de 700
        b = r.request("proyecto-otro", self.wt("b"))
        self.assertEqual(b["state"], "active")
        machine["cpu_pct"] = 100                                # 400 < 700: aún cabe
        self.cfg["capacity"]["max_cpu_pct"] = 300               # pero el tope ahora es 300
        r2 = self.mk(collector=FakeCollector(machine))
        c = r2.request("proyecto-tercero", self.wt("c"))
        self.assertEqual(c["state"], "queued")
        self.assertEqual(r2.status()["capacity"]["cpu_pct_used"], 400)

    def test_one_promotion_per_tick_with_metrics(self):
        machine = {"cpus": 4, "cpu_pct": 1, "ram_avail_mb": 20000}
        self.cfg["capacity"]["max_servers"] = 4
        r = self.mk(collector=FakeCollector(dict(machine, ram_avail_mb=0)))
        for p in ("proyecto-demo", "proyecto-otro", "proyecto-tercero"):
            self.assertEqual(r.request(p, self.wt(p))["state"], "queued")
        r.collector = FakeCollector(machine)
        self.assertEqual(len(r.tick(sweep=False)["promoted"]), 1)
        self.assertEqual(len(r.tick(sweep=False)["promoted"]), 1)

    def test_wait_polls_until_promoted(self):
        r = self.mk(poll_interval=1.0)
        a = r.request("proyecto-demo", self.wt("a"))
        polls = []
        real_sleep = self.clock.sleep

        def sleeper(s):
            polls.append(s)
            real_sleep(s)
            if len(polls) == 2:                                   # a la segunda espera alguien libera
                r.release(lease_id=a["id"])
        r.sleep = sleeper
        b = r.request("proyecto-demo", self.wt("b"), wait=True, wait_seconds=10)
        self.assertEqual(b["state"], "active")
        self.assertEqual(len(polls), 2)

    def test_wait_gives_up_queued(self):
        r = self.mk()
        r.request("proyecto-demo", self.wt("a"))
        b = r.request("proyecto-demo", self.wt("b"), wait_seconds=3)
        self.assertEqual(b["state"], "queued")
        self.assertEqual(b["position"], 1)
        self.assertAlmostEqual(self.clock.t - T0, 3, delta=1.5)

    def test_queue_ttl_expires(self):
        self.cfg["projects"]["proyecto-demo"]["test_server"]["idle_seconds"] = 10 ** 6    # que `a` no venza por inactividad
        r = self.mk()
        r.request("proyecto-demo", self.wt("a"))
        b = r.request("proyecto-demo", self.wt("b"))
        self.clock.t += self.cfg["capacity"]["queue_ttl_seconds"] - 5
        self.assertEqual(r.tick(sweep=False)["expired"], [])
        self.clock.t += 10
        out = r.tick(sweep=False)
        self.assertIn(b["id"], out["expired"])
        row = self.conn.execute("SELECT state, reason FROM leases WHERE id=?", (b["id"],)).fetchone()
        self.assertEqual((row["state"], row["reason"]), ("expired", "queue_ttl"))
        self.assertIn(("lease_expired", "proyecto-demo"), [(e[0], e[1]) for e in self.events])


class TestLifecycle(Base):
    def test_idle_shutdown_and_touch(self):
        r = self.mk()
        a = r.request("proyecto-demo", self.wt("a"))           # idle_seconds = 600 (config del proyecto)
        self.assertEqual(a["idle_seconds"], 600)
        self.clock.t += 500
        r.touch(a["id"])
        self.clock.t += 500
        self.assertEqual(r.tick(sweep=False)["expired"], [])   # 500 s desde el touch: sigue vivo
        self.clock.t += 101
        out = r.tick(sweep=False)
        self.assertEqual(out["expired"], [a["id"]])
        self.assertEqual(self.sd.stopped, ["chopshop-ts-proyecto-demo-l-0001.service"])
        row = self.conn.execute("SELECT state, reason FROM leases WHERE id=?", (a["id"],)).fetchone()
        self.assertEqual((row["state"], row["reason"]), ("expired", "idle"))
        self.assertIn("lease_expired", self.names())
        self.assertIsNone(self.conn.execute("SELECT lease_id FROM ports").fetchone()[0])

    def test_default_idle_seconds(self):
        r = self.mk()
        b = r.request("proyecto-otro", self.wt("b"))
        self.assertEqual(b["idle_seconds"], self.cfg["capacity"]["default_idle_seconds"])

    def test_touch_unknown(self):
        with self.assertRaises(resources.LeaseNotFound):
            self.mk().touch("l-9999")

    def test_dead_unit_is_reaped(self):
        r = self.mk()
        a = r.request("proyecto-demo", self.wt("a"))
        self.sd.units["chopshop-ts-proyecto-demo-l-0001.service"]["state"] = "failed"
        out = r.tick(sweep=False)
        self.assertEqual(out["released"], [a["id"]])
        self.assertEqual(self.sd.stopped, [])
        row = self.conn.execute("SELECT state, reason FROM leases").fetchone()
        self.assertEqual((row["state"], row["reason"]), ("released", "exited"))

    def test_release_by_worktree_thread_lease_and_project(self):
        r = self.mk()
        a = r.request("proyecto-demo", self.wt("a"), thread_id="th-a")
        b = r.request("proyecto-otro", self.wt("b"), thread_id="th-b")
        c = r.request("proyecto-tercero", self.wt("c"), thread_id="th-c")
        out = r.release(worktree=self.wt("a"))
        self.assertEqual([x["id"] for x in out], [a["id"]])
        self.assertEqual(self.sd.stopped, ["chopshop-ts-proyecto-demo-l-0001.service"])
        self.assertEqual([x["id"] for x in r.release(thread_id="th-b")], [b["id"]])
        self.assertEqual(r.release(worktree=self.wt("c"), project="proyecto-demo"), [])     # acotado por proyecto
        self.assertEqual([x["id"] for x in r.release(project="proyecto-tercero")], [c["id"]])
        self.assertEqual(r.release(lease_id=a["id"]), [])                                    # ya liberado
        self.assertEqual(self.names().count("lease_released"), 3)
        self.assertEqual(r.status()["active"], [])
        with self.assertRaises(ValueError):
            r.release()

    def test_release_worktree_or_thread(self):
        r = self.mk()
        a = r.request("proyecto-demo", self.wt("a"), thread_id="th-1")
        b = r.request("proyecto-otro", self.wt("b"), thread_id="th-1")
        out = r.release(worktree=self.wt("a"), thread_id="th-1")
        self.assertEqual(sorted(x["id"] for x in out), sorted([a["id"], b["id"]]))

    def test_release_queued(self):
        r = self.mk()
        r.request("proyecto-demo", self.wt("a"))
        b = r.request("proyecto-demo", self.wt("b"))
        out = r.release(lease_id=b["id"])
        self.assertEqual(out[0]["state"], "released")
        self.assertEqual(self.sd.stopped, [])                  # sin unidad que parar

    def test_failed_stop_leaves_orphan_for_sweep(self):
        r = self.mk()
        r.request("proyecto-demo", self.wt("a"))
        self.sd.fail_stop = True
        r.release(worktree=self.wt("a"))
        self.assertIn("no se pudo parar", self.conn.execute("SELECT detail FROM leases").fetchone()[0])
        self.sd.fail_stop = False
        rep = r.sweep()
        self.assertEqual([u["unit"] for u in rep["units"]], ["chopshop-ts-proyecto-demo-l-0001.service"])
        self.assertEqual(self.sd.units, {})

    def test_status_shape(self):
        r = self.mk(collector=FakeCollector({"cpus": 8, "cpu_pct": 5, "ram_avail_mb": 30000}))
        a = r.request("proyecto-demo", self.wt("a"))
        st = r.status()
        self.assertEqual(set(st), {"active", "queued", "ports", "capacity"})
        self.assertEqual(st["active"][0]["id"], a["id"])
        self.assertEqual(st["ports"][0]["lease_id"], a["id"])
        self.assertEqual(st["capacity"]["max_servers"], 4)
        self.assertEqual(st["capacity"]["used"], 1)
        self.assertEqual(st["capacity"]["cpu_pct_used"], 40)
        self.assertEqual(st["capacity"]["ram_avail_mb"], 30000)

    def test_tick_runs_sweep_by_interval(self):
        r = self.mk()
        self.assertIsNotNone(r.tick()["sweep"])
        self.assertIsNone(r.tick()["sweep"])
        self.clock.t += self.cfg["sweep"]["interval"] + 1
        self.assertIsNotNone(r.tick()["sweep"])


class TestSweepUnits(Base):
    def test_only_orphan_chopshop_units_are_stopped(self):
        r = self.mk()
        r.request("proyecto-demo", self.wt("a"))
        self.sd.units["chopshop-ts-fantasma-l-0099.service"] = {"state": "active", "pid": 1}
        self.sd.units["chopshop-agent.service"] = {"state": "active", "pid": 2}     # el propio agente: jamás
        self.sd.units["otra-cosa.service"] = {"state": "active", "pid": 3}
        dry = r.sweep(dry_run=True)
        self.assertEqual([(u["unit"], u["action"]) for u in dry["units"]], [("chopshop-ts-fantasma-l-0099.service", "would_stop")])
        self.assertEqual(self.sd.stopped, [])
        self.assertNotIn("orphan_found", self.names())
        rep = r.sweep()
        self.assertEqual(self.sd.stopped, ["chopshop-ts-fantasma-l-0099.service"])
        self.assertEqual(rep["units"][0]["project"], "fantasma")
        self.assertEqual(self.names().count("orphan_found"), 1)
        self.assertEqual(self.names().count("orphan_stopped"), 1)
        self.assertIn("chopshop-agent.service", self.sd.units)
        self.assertIn("chopshop-ts-proyecto-demo-l-0001.service", self.sd.units)
        r.sweep()
        self.assertEqual(self.names().count("orphan_found"), 1)

    def test_orphan_found_not_repeated_when_stop_fails(self):
        r = self.mk()
        self.sd.units["chopshop-ts-fantasma-l-0099.service"] = {"state": "active", "pid": 1}
        self.sd.fail_stop = True
        r.sweep()
        rep = r.sweep()
        self.assertFalse(rep["units"][0]["ok"])
        self.assertEqual(self.names().count("orphan_found"), 1)
        self.assertEqual(self.names().count("orphan_stopped"), 0)

    def test_ports_without_worktree_are_returned(self):
        r = self.mk()
        gone = r.ports_for("proyecto-demo", os.path.join(self.tmp, "ya-no-existe"))
        keep = r.ports_for("proyecto-demo", self.wt("vivo"))
        dry = r.sweep(dry_run=True)
        self.assertEqual([p["port"] for p in dry["ports"]], [gone["base"]])
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM ports").fetchone()[0], 2)
        r.sweep()
        self.assertEqual([x["port"] for x in self.conn.execute("SELECT port FROM ports")], [keep["base"]])


class TestSweepScopes(Base):
    """Cgroup falso en tmpdir + /proc falso + kill_fn inyectado: solo se señalan PIDs listados en el cgroup.procs."""

    def setUp(self):
        super().setUp()
        self.scope = os.path.join(self.cgroup, "app-t3code-agents-demo.scope")
        os.makedirs(self.scope)
        self.signals = []
        self.alive = []                                  # PIDs "vivos" en el cgroup falso
        self.sigterm_works = False
        with open(os.path.join(self.proc, "net", "tcp"), "w") as f:
            f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
                    "   0: 0100007F:A029 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 777 1 0 100 0 0 10 0\n"
                    "   1: 0100007F:A02A 0100007F:9999 01 00000000:00000000 00:00000000 00000000  1000        0 888 1 0 100 0 0 10 0\n")

    def set_pids(self, pids):
        self.alive = list(pids)
        with open(os.path.join(self.scope, "cgroup.procs"), "w") as f:
            f.write("".join("%d\n" % p for p in self.alive))

    def fake_proc(self, pid, sockets=(), cwd=None, thread=None):
        base = os.path.join(self.proc, str(pid))
        os.makedirs(os.path.join(base, "fd"), exist_ok=True)
        for i, inode in enumerate(sockets):
            os.symlink("socket:[%d]" % inode, os.path.join(base, "fd", str(3 + i)))
        os.symlink(cwd or self.wt("vivo"), os.path.join(base, "cwd"))
        with open(os.path.join(base, "environ"), "wb") as f:
            f.write(b"PATH=/usr/bin\0" + (b"T3CODE_THREAD_ID=" + thread.encode() + b"\0" if thread else b""))

    def thread(self, tid, settled=1, age=1000, worktree=None, project="proyecto-demo"):
        self.conn.execute("INSERT INTO t3_threads(thread_id, project, status, settled, worktree, updated) VALUES (?,?,?,?,?,?)",
                          (tid, project, "idle", settled, worktree, T0 - age))

    def kill_fn(self, pid, sig):
        self.signals.append((pid, sig))
        if pid in self.alive and (sig == signal.SIGKILL or self.sigterm_works):
            self.set_pids([p for p in self.alive if p != pid])

    def mkr(self, mode):
        self.cfg["sweep"]["agent_scopes"] = mode
        return self.mk(kill_fn=self.kill_fn)

    def setup_processes(self):
        self.thread("th-1")
        self.fake_proc(4242, sockets=[777], thread="th-1")                    # escucha un puerto, hilo settled
        self.fake_proc(4243, sockets=[888], thread="th-1")                    # socket establecido (no LISTEN), cwd vivo
        self.set_pids([4242, 4243])

    def test_report_mode_never_signals(self):
        self.setup_processes()
        r = self.mkr("report")
        rep = r.sweep()
        sc = rep["agent_scopes"]
        self.assertEqual(sc["mode"], "report")
        cands = sc["scopes"][0]["candidates"]
        self.assertEqual([c["pid"] for c in cands], [4242])
        self.assertEqual(cands[0]["ports"], [0xA029])
        self.assertEqual(cands[0]["thread_id"], "th-1")
        self.assertEqual(self.signals, [])
        self.assertEqual(self.alive, [4242, 4243])
        self.assertEqual(self.names(), ["orphan_found"])
        r.sweep()
        self.assertEqual(self.names(), ["orphan_found"])                       # sin repetir

    def test_default_mode_is_report(self):
        self.setup_processes()
        self.assertEqual(self.cfg["sweep"]["agent_scopes"], "report")
        self.mk(kill_fn=self.kill_fn).sweep()
        self.assertEqual(self.signals, [])

    def test_unknown_mode_falls_back_to_report(self):
        self.setup_processes()
        rep = self.mkr("destruir").sweep()
        self.assertEqual(rep["agent_scopes"]["mode"], "report")
        self.assertEqual(self.signals, [])

    def test_kill_only_exact_candidate_pids_term_then_kill(self):
        self.setup_processes()
        self.set_pids([4242, 4243])
        r = self.mkr("kill")
        rep = r.sweep()
        self.assertEqual(self.signals, [(4242, signal.SIGTERM), (4242, signal.SIGKILL)])
        sc = rep["agent_scopes"]["scopes"][0]
        self.assertEqual((sc["killed"], sc["survivors"]), ([4242], []))
        self.assertEqual(self.alive, [4243])
        self.assertEqual(self.names(), ["orphan_found", "orphan_stopped"])
        self.assertNotIn(4243, [p for p, _ in self.signals])

    def test_sigterm_enough_skips_sigkill(self):
        self.setup_processes()
        self.sigterm_works = True
        self.mkr("kill").sweep()
        self.assertEqual(self.signals, [(4242, signal.SIGTERM)])

    def test_kill_dry_run_does_nothing(self):
        self.setup_processes()
        rep = self.mkr("kill").sweep(dry_run=True)
        self.assertEqual([c["pid"] for c in rep["agent_scopes"]["scopes"][0]["candidates"]], [4242])
        self.assertEqual(self.signals, [])
        self.assertEqual(self.names(), [])

    def test_held_when_thread_unsettled_unknown_or_in_grace(self):
        self.thread("th-run", settled=0)
        self.thread("th-new", settled=1, age=10)                              # grace_seconds = 120
        self.fake_proc(10, sockets=[777], thread="th-run")
        self.fake_proc(11, sockets=[777], thread="th-new")
        self.fake_proc(12, sockets=[777], thread="th-fantasma")
        self.fake_proc(13, sockets=[777])
        self.set_pids([10, 11, 12, 13])
        rep = self.mkr("kill").sweep()
        sc = rep["agent_scopes"]["scopes"][0]
        self.assertEqual(sc["candidates"], [])
        self.assertEqual(sorted((h["pid"], h["why"]) for h in sc["held"]),
                         [(10, "hilo no settled"), (11, "dentro de la gracia"), (12, "hilo desconocido"), (13, "hilo desconocido")])
        self.assertEqual(self.signals, [])

    def test_cwd_gone_and_thread_found_by_worktree(self):
        gone = os.path.join(self.tmp, "worktrees", "borrado")
        self.thread("th-2", worktree=gone)
        self.fake_proc(20, cwd=os.path.join(gone, "src"))                      # sin env: se asocia por cwd bajo el worktree
        self.set_pids([20])
        rep = self.mkr("kill").sweep()
        c = rep["agent_scopes"]["scopes"][0]["candidates"][0]
        self.assertEqual((c["pid"], c["thread_id"]), (20, "th-2"))
        self.assertIn("cwd ya no existe", c["reasons"])
        self.assertIn("worktree ya no existe", c["reasons"])
        self.assertEqual(self.signals[0], (20, signal.SIGTERM))

    def test_healthy_process_is_not_candidate(self):
        self.thread("th-3")
        self.fake_proc(30, thread="th-3")                                      # settled pero sin puerto y con cwd vivo
        self.set_pids([30])
        rep = self.mkr("kill").sweep()
        self.assertEqual(rep["agent_scopes"]["scopes"][0]["candidates"], [])
        self.assertEqual(self.signals, [])

    def test_signal_reverifies_cgroup_membership(self):
        r = self.mkr("kill")
        self.set_pids([100, 200])
        self.assertFalse(r._signal(self.scope, 300, signal.SIGTERM))           # no está en el cgroup.procs
        self.assertFalse(r._signal(self.scope, 1, signal.SIGTERM))
        self.assertFalse(r._signal(self.scope, os.getpid(), signal.SIGTERM))
        self.assertEqual(self.signals, [])
        self.assertTrue(r._signal(self.scope, 100, signal.SIGTERM))
        self.assertEqual(self.signals, [(100, signal.SIGTERM)])

    def test_pid_that_left_the_cgroup_before_kill_is_not_signaled(self):
        self.setup_processes()
        r = self.mkr("kill")
        orig = r._terminate

        def racing(scope_dir, pids):
            self.set_pids([4243])                                              # 4242 terminó (y su PID podría reciclarse)
            return orig(scope_dir, pids)
        r._terminate = racing
        r.sweep()
        self.assertEqual(self.signals, [])

    def test_missing_cgroup_is_reported_not_fatal(self):
        r = self.mk(cgroup_root=os.path.join(self.tmp, "no-hay-cgroup"))
        rep = r.sweep()
        self.assertFalse(rep["agent_scopes"]["available"])
        self.assertEqual(rep["agent_scopes"]["scopes"], [])


class TestSources(unittest.TestCase):
    def test_no_name_based_kill(self):
        src = os.path.join(os.path.dirname(__file__), "..", "chopshop", "agent", "resources.py")
        with open(src, encoding="utf-8") as f:
            tree = ast.parse(f.read())
        docs = {id(n.body[0].value) for n in ast.walk(tree)
                if isinstance(n, (ast.Module, ast.FunctionDef, ast.ClassDef)) and n.body and isinstance(n.body[0], ast.Expr)}
        used = set()
        for n in ast.walk(tree):
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in docs:
                used.add(n.value)
            elif isinstance(n, ast.Attribute):
                used.add(n.attr)
            elif isinstance(n, ast.Name):
                used.add(n.id)
            elif isinstance(n, ast.keyword) and n.arg == "shell":
                used.add("shell")
        for word in ("pkill", "killall", "killpg", "system", "shell"):
            self.assertNotIn(word, used)


if __name__ == "__main__":
    unittest.main()
