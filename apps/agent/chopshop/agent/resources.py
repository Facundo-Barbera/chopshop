"""Recursos compartidos entre hilos: puertos deterministas por worktree, servers de pruebas bajo demanda con cola por
capacidad (`systemd-run --user`), apagado por inactividad y barrido de huérfanos.

Reglas duras: jamás `pkill`/`killall`/kill por nombre. Solo (a) `systemctl --user stop <unidad exacta>` o (b) señales a PIDs
EXACTOS leídos del `cgroup.procs` de un scope concreto, re-verificados justo antes de señalar. Todo lo externo es inyectable
(`runner`, `kill_fn`, `clock`, `sleep`, `cgroup_root`, `proc_root`), así que los tests no tocan systemd ni procesos reales."""
import hashlib
import os
import re
import shlex
import signal
import subprocess
import time

from .. import settings
from . import db

UNIT_PREFIX = "chopshop-ts-"            # solo se barren/paran unidades con este prefijo (nunca `chopshop-agent` etc.)
SLICE = "chopshop-servers.slice"
DEFAULT_CPU_QUOTA = "200%"
DEFAULT_MEM_MAX = "2G"
KINDS = ("test_server", "port")
LIVE = ("active", "activating", "reloading", "deactivating")   # ActiveState de systemd que cuenta como "vivo"
_UNIT_RX = re.compile(r"^" + re.escape(UNIT_PREFIX) + r"(.+)-(l-\d+)\.service$")


class ResourcesError(Exception):
    pass


class LeaseNotFound(ResourcesError):
    pass


def default_runner(argv, timeout=20):
    """Ejecuta argv SIN shell. Devuelve (rc, stdout, stderr); un fallo al lanzar es rc=127."""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)
    return p.returncode, p.stdout, p.stderr


def _sanitize(name):
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", name or "").strip("-.") or "x"


def _svc(unit):
    return unit if unit.endswith(".service") else unit + ".service"


def _short(s, n=400):
    s = (s or "").strip()
    return s if len(s) <= n else s[:n] + "…"


def _parse_show(out):
    d = {}
    for line in (out or "").splitlines():
        k, _, v = line.partition("=")
        d[k.strip()] = v.strip()
    return d


def parse_listening(text):
    """Contenido de /proc/net/tcp[6] -> {inode: puerto} de los sockets en LISTEN."""
    res = {}
    for line in (text or "").splitlines()[1:]:
        f = line.split()
        if len(f) < 10 or f[3] != "0A":
            continue
        try:
            res[int(f[9])] = int(f[1].rsplit(":", 1)[1], 16)
        except (ValueError, IndexError):
            continue
    return res


class Resources:
    def __init__(self, cfg, conn, emit_fn=None, collector=None, runner=None, clock=None, sleep=None,
                 cgroup_root=None, proc_root="/proc", kill_fn=None, poll_interval=1.0, term_wait=5.0):
        self.cfg = cfg
        self.conn = conn
        self.emit_fn = emit_fn
        self.collector = collector
        self.runner = runner or default_runner
        self.clock = clock or time.time
        self.sleep = sleep or time.sleep
        self.proc_root = proc_root
        self.kill_fn = kill_fn or os.kill
        self.poll_interval = poll_interval
        self.term_wait = term_wait
        d = settings.DEFAULTS["agent"]
        self.ports_cfg = settings.merge(d["ports"], cfg.get("ports"))
        self.cap = settings.merge(d["capacity"], cfg.get("capacity"))
        self.sweep_cfg = settings.merge(d["sweep"], cfg.get("sweep"))
        self.cgroup_root = cgroup_root or self.sweep_cfg.get("agent_cgroup") or self._default_cgroup_root()
        self._seen = set()          # huérfanos ya anunciados (evita repetir orphan_found en cada barrido)
        self._last_sweep = None

    # ------------------------------------------------------------------ utilidades

    @staticmethod
    def _default_cgroup_root():
        uid = os.getuid()
        return "/sys/fs/cgroup/user.slice/user-%d.slice/user@%d.service/app.slice/app-t3code-agents.slice" % (uid, uid)

    def _run(self, argv):
        try:
            rc, out, err = self.runner(argv)
        except Exception as e:      # un runner roto no debe tumbar al hilo de recursos
            return 127, "", str(e)
        return rc, out or "", err or ""

    def _flush(self, evs):
        """Emite los eventos acumulados FUERA del candado (la entrega por webhook puede tardar)."""
        for ev, project, body in evs:
            if not self.emit_fn:
                continue
            try:
                self.emit_fn(ev, project, body)
            except Exception:
                pass

    def _project_cfg(self, project):
        return (self.cfg.get("projects") or {}).get(project) or {}

    def _ts_cfg(self, project):
        return self._project_cfg(project).get("test_server") or {}

    def _worktree(self, project, worktree):
        if not worktree:
            pc = self._project_cfg(project)
            worktree = pc.get("root") or os.path.join(self.cfg.get("projects_root") or "~/projects", project)
        return os.path.normpath(os.path.abspath(os.path.expanduser(worktree)))

    def _machine(self):
        if not self.collector:
            return {}
        try:
            return (self.collector.latest() or {}).get("machine") or {}
        except Exception:
            return {}

    @staticmethod
    def _cpu_used(machine):
        """CPU usada en % de núcleo (100 = 1 núcleo): `machine.cpu_pct` (0-100 de toda la máquina) × `cpus`."""
        pct = machine.get("cpu_pct")
        if pct is None:
            return None
        return pct * machine["cpus"] if machine.get("cpus") else pct

    def _listening(self):
        """{inode: puerto} de los sockets TCP en LISTEN (IPv4 + IPv6)."""
        res = {}
        for name in ("tcp", "tcp6"):
            try:
                with open(os.path.join(self.proc_root, "net", name)) as f:
                    res.update(parse_listening(f.read()))
            except OSError:
                pass
        return res

    # ------------------------------------------------------------------ puertos

    def ports_for(self, project, worktree=None):
        """Bloque de puertos del worktree: `{"base": n, "range": [n, n+per_worktree-1]}`. Determinista y persistido."""
        wt = self._worktree(project, worktree)
        with db.tx():
            base = self._port_base(project, wt)
        return self._block(base)

    def _block(self, base):
        return {"base": base, "range": [base, base + int(self.ports_cfg["per_worktree"]) - 1]}

    def _port_base(self, project, wt):
        row = self.conn.execute("SELECT port FROM ports WHERE project=? AND worktree=? AND role='base'", (project, wt)).fetchone()
        if row:
            return row["port"]
        lo, hi = (int(x) for x in self.ports_cfg["range"])
        per = int(self.ports_cfg["per_worktree"])
        nslots = (hi - lo + 1) // per
        if per < 1 or nslots < 1:
            raise ResourcesError("rango de puertos inválido: %r / %r" % (self.ports_cfg["range"], per))
        taken = [r["port"] for r in self.conn.execute("SELECT port FROM ports")]
        listening = set(self._listening().values())
        start = int(hashlib.sha256(wt.encode("utf-8")).hexdigest()[:12], 16) % nslots
        for i in range(nslots):             # sondeo lineal desde el slot que dicta el hash
            cand = lo + ((start + i) % nslots) * per
            if any(abs(p - cand) < per for p in taken):
                continue
            if any(cand <= p < cand + per for p in listening):
                continue
            self.conn.execute("INSERT INTO ports(port, project, worktree, role, lease_id, assigned) VALUES (?,?,?,'base',NULL,?)",
                              (cand, project, wt, self.clock()))
            return cand
        raise ResourcesError("no quedan bloques de puertos libres en %s-%s" % (lo, hi))

    # ------------------------------------------------------------------ leases: lectura

    def _get(self, lease_id):
        row = self.conn.execute("SELECT * FROM leases WHERE id=?", (lease_id,)).fetchone()
        if not row:
            raise LeaseNotFound(lease_id)
        return dict(row)

    def _queue_ids(self):
        return [r["id"] for r in self.conn.execute(
            "SELECT id FROM leases WHERE state='queued' AND kind='test_server' ORDER BY requested, id")]

    def _view(self, lease, queue=None):
        out = dict(lease)
        if lease["state"] == "queued":
            q = queue if queue is not None else self._queue_ids()
            out["position"] = q.index(lease["id"]) + 1 if lease["id"] in q else None
        if lease.get("port"):
            out["port_range"] = self._block(lease["port"])["range"]
        return out

    def _active(self, kind="test_server"):
        return [dict(r) for r in self.conn.execute(
            "SELECT * FROM leases WHERE state='active' AND kind=? ORDER BY started, id", (kind,))]

    # ------------------------------------------------------------------ request

    def request(self, project, worktree=None, thread_id=None, kind="test_server", cmd=None, wait=False, wait_seconds=None):
        """Pide un server de pruebas (o solo un bloque de puertos con kind="port"). Devuelve el lease: `active` si hay
        capacidad, `queued` (con `position`) si no, `failed` si no hay comando que lanzar. Idempotente por
        (proyecto, worktree, kind): si ya hay un lease vivo, lo devuelve (renovando su uso). Con `wait`/`wait_seconds`
        espera (sondeo con `sleep` inyectable) a que la cola lo promueva."""
        if kind not in KINDS:
            raise ValueError("kind debe ser uno de %s" % (KINDS,))
        if not project:
            raise ValueError("project es obligatorio")
        wt = self._worktree(project, worktree)
        evs = []
        with db.tx():
            now = self.clock()
            lease = self._existing(project, wt, kind)
            if lease:
                sets, args = [], []
                if lease["state"] == "active":
                    sets.append("last_used=?")
                    args.append(now)
                if thread_id and not lease["thread_id"]:
                    sets.append("thread_id=?")
                    args.append(thread_id)
                if sets:
                    self.conn.execute("UPDATE leases SET %s WHERE id=?" % ",".join(sets), args + [lease["id"]])
                lease = self._get(lease["id"])
            else:
                lease = self._create(project, wt, thread_id, kind, cmd, now, evs)
            lease_id = lease["id"]
        self._flush(evs)
        if (wait or wait_seconds) and lease["state"] == "queued":
            lease = self._wait(lease_id, wait_seconds if wait_seconds else 60)
        with db.tx():
            return self._view(self._get(lease_id))

    def _existing(self, project, wt, kind):
        row = self.conn.execute(
            "SELECT * FROM leases WHERE project=? AND worktree=? AND kind=? AND state IN ('queued','active') ORDER BY requested LIMIT 1",
            (project, wt, kind)).fetchone()
        return dict(row) if row else None

    def _next_id(self):
        row = self.conn.execute("SELECT MAX(CAST(substr(id, 3) AS INTEGER)) AS n FROM leases").fetchone()
        return "l-%04d" % ((row["n"] or 0) + 1)

    def _create(self, project, wt, thread_id, kind, cmd, now, evs):
        ts = self._ts_cfg(project)
        lease_id = self._next_id()
        base = self._port_base(project, wt)
        cmd = cmd or ts.get("cmd") or self._project_cfg(project).get("test_cmd") or None
        cwd = os.path.normpath(os.path.join(wt, ts.get("cwd") or "."))
        idle = int(ts.get("idle_seconds") or self.cap["default_idle_seconds"])
        fields = dict(id=lease_id, kind=kind, project=project, worktree=wt, thread_id=thread_id, state="queued", port=base,
                      cmd=cmd if kind == "test_server" else None, cwd=cwd, requested=now, last_used=now, idle_seconds=idle,
                      cpu_quota=str(ts.get("cpu_quota") or DEFAULT_CPU_QUOTA), mem_max=str(ts.get("mem_max") or DEFAULT_MEM_MAX))
        if kind == "port":
            fields.update(state="active", started=now, cmd=None, cwd=None, cpu_quota=None, mem_max=None)
        elif not cmd:
            fields.update(state="failed", ended=now,
                          reason="sin comando de pruebas: define agent.projects.%s.test_server.cmd o pasa cmd" % project)
        self._insert(fields)
        if kind == "port":
            self.conn.execute("UPDATE ports SET lease_id=? WHERE port=?", (lease_id, base))
            evs.append(("lease_active", project, self._body(fields)))
        elif fields["state"] == "failed":
            evs.append(("lease_failed", project, self._body(fields)))
        else:
            self._promote(evs)
            fields = self._get(lease_id)
            if fields["state"] == "queued":
                evs.append(("lease_queued", project, dict(self._body(fields), position=self._queue_ids().index(lease_id) + 1)))
        return self._get(lease_id)

    def _insert(self, fields):
        cols = list(fields)
        self.conn.execute("INSERT INTO leases(%s) VALUES (%s)" % (",".join(cols), ",".join("?" * len(cols))),
                          [fields[c] for c in cols])

    @staticmethod
    def _body(lease):
        keys = ("id", "kind", "thread_id", "worktree", "port", "unit", "state", "reason")
        body = {k: lease.get(k) for k in keys if lease.get(k) is not None}
        body["lease_id"] = body.pop("id", None)
        return body

    def _wait(self, lease_id, seconds):
        deadline = self.clock() + seconds
        while True:
            with db.tx():
                lease = self._get(lease_id)
            if lease["state"] != "queued":
                return lease
            remaining = deadline - self.clock()
            if remaining <= 0:
                return lease
            self.sleep(min(self.poll_interval, remaining))
            self.tick(sweep=False)

    # ------------------------------------------------------------------ capacidad y arranque

    def _fits(self, lease, active, machine):
        """None si cabe; "project" si lo frena el tope por proyecto (no bloquea a los demás); "global" si lo frena un tope
        de la máquina (la cola es FIFO: nadie se salta al primero)."""
        cap = self.cap
        if sum(1 for a in active if a["project"] == lease["project"]) >= int(cap["max_per_project"]):
            return "project"
        if len(active) >= int(cap["max_servers"]):
            return "global"
        cpu = self._cpu_used(machine)
        if cpu is not None and cpu >= float(cap["max_cpu_pct"]):
            return "global"
        ram = machine.get("ram_avail_mb")
        if ram is not None and ram < float(cap["min_ram_avail_mb"]):
            return "global"
        return None

    def _promote(self, evs, promoted=None):
        """Arranca de la cola, en orden FIFO, lo que quepa. Con métricas de la máquina arranca uno por pasada (las
        métricas aún no reflejan el server recién lanzado)."""
        machine = self._machine()
        active = self._active()
        queued = [dict(r) for r in self.conn.execute(
            "SELECT * FROM leases WHERE state='queued' AND kind='test_server' ORDER BY requested, id")]
        for q in queued:
            why = self._fits(q, active, machine)
            if why == "project":
                continue
            if why == "global":
                break
            lease = self._start(q, evs)
            if promoted is not None:
                promoted.append(lease["id"])
            if lease["state"] == "active":
                active.append(lease)
                if machine.get("cpu_pct") is not None or machine.get("ram_avail_mb") is not None:
                    break

    def _start(self, lease, evs):
        ts = self._ts_cfg(lease["project"])
        now = self.clock()
        unit = UNIT_PREFIX + _sanitize(lease["project"]) + "-" + lease["id"]

        def fail(reason, detail=None):
            self.conn.execute("UPDATE leases SET state='failed', ended=?, reason=?, detail=? WHERE id=?",
                              (now, reason, detail, lease["id"]))
            self.conn.execute("UPDATE ports SET lease_id=NULL WHERE lease_id=?", (lease["id"],))
            row = self._get(lease["id"])
            evs.append(("lease_failed", row["project"], self._body(row)))
            return row

        if not lease.get("cwd") or not os.path.isdir(lease["cwd"]):
            return fail("el directorio de trabajo no existe")
        try:
            cmd_argv = shlex.split(lease["cmd"] or "")
        except ValueError as e:
            return fail("comando inválido: %s" % e)
        if not cmd_argv:
            return fail("comando vacío")
        port_env = ts.get("port_env") or "PORT"
        argv = ["systemd-run", "--user", "--unit=" + unit, "--collect",
                "-p", "CPUQuota=" + (lease["cpu_quota"] or DEFAULT_CPU_QUOTA),
                "-p", "MemoryMax=" + (lease["mem_max"] or DEFAULT_MEM_MAX),
                "-p", "Slice=" + SLICE,
                "-p", "Environment=%s=%d" % (port_env, lease["port"]),
                "--working-directory=" + lease["cwd"], "--"] + cmd_argv
        rc, out, err = self._run(argv)
        if rc != 0:
            return fail("systemd-run falló (rc=%s)" % rc, _short(err or out))
        pid = None
        rc, out, _ = self._run(["systemctl", "--user", "show", _svc(unit), "-p", "ActiveState,MainPID"])
        if rc == 0:
            try:
                pid = int(_parse_show(out).get("MainPID") or 0) or None
            except ValueError:
                pass
        self.conn.execute("UPDATE leases SET state='active', unit=?, pid=?, started=?, last_used=? WHERE id=?",
                          (unit, pid, now, now, lease["id"]))
        self.conn.execute("UPDATE ports SET lease_id=? WHERE port=?", (lease["id"], lease["port"]))
        row = self._get(lease["id"])
        evs.append(("lease_active", row["project"], self._body(row)))
        return row

    def _stop_unit(self, unit):
        """`systemctl --user stop <unidad exacta>`. Devuelve (ok, detalle)."""
        rc, out, err = self._run(["systemctl", "--user", "stop", _svc(unit)])
        return rc == 0, (None if rc == 0 else _short(err or out))

    def _finish(self, lease, state, reason, event, evs, stop=True):
        """Cierra un lease (released/expired): para su unidad exacta, libera el puerto y anota el evento."""
        detail = None
        if stop and lease.get("unit"):
            ok, detail = self._stop_unit(lease["unit"])   # si falla, el barrido la reintenta como huérfana
        self.conn.execute("UPDATE leases SET state=?, ended=?, reason=?, detail=COALESCE(?, detail) WHERE id=?",
                          (state, self.clock(), reason, detail, lease["id"]))
        self.conn.execute("UPDATE ports SET lease_id=NULL WHERE lease_id=?", (lease["id"],))
        row = self._get(lease["id"])
        evs.append((event, row["project"], self._body(row)))
        return row

    # ------------------------------------------------------------------ release / touch

    def release(self, lease_id=None, worktree=None, thread_id=None, project=None):
        """Libera leases vivos (queued/active). `lease_id` es exclusivo; si no, coinciden los de ese `worktree` O ese
        `thread_id` (lo que pide `runOnSettle`), acotados por `project` si se da. Sin criterio -> ValueError."""
        if not (lease_id or worktree or thread_id or project):
            raise ValueError("indica lease_id, worktree, thread_id o project")
        evs, out = [], []
        with db.tx():
            if lease_id:
                where, args = "id=?", [lease_id]
            else:
                ors, args = [], []
                if worktree:
                    ors.append("worktree=?")
                    args.append(self._worktree(project or "", worktree))
                if thread_id:
                    ors.append("thread_id=?")
                    args.append(thread_id)
                where = "(%s)" % " OR ".join(ors) if ors else "1=1"
                if project:
                    where += " AND project=?"
                    args.append(project)
            rows = [dict(r) for r in self.conn.execute(
                "SELECT * FROM leases WHERE state IN ('queued','active') AND " + where + " ORDER BY id", args)]
            for lease in rows:
                out.append(self._view(self._finish(lease, "released", "release", "lease_released", evs)))
        self._flush(evs)
        return out

    def touch(self, lease_id):
        """Renueva el uso de un lease activo (aplaza el apagado por inactividad)."""
        with db.tx():
            lease = self._get(lease_id)
            if lease["state"] == "active":
                self.conn.execute("UPDATE leases SET last_used=? WHERE id=?", (self.clock(), lease_id))
            return self._view(self._get(lease_id))

    # ------------------------------------------------------------------ tick

    def tick(self, sweep=None):
        """Un paso de mantenimiento: reaper de unidades muertas, apagado por inactividad, vencimiento de la cola,
        promoción de la cola y (según `sweep.interval`) barrido de huérfanos. `sweep=True/False` lo fuerza."""
        evs = []
        out = {"released": [], "expired": [], "promoted": [], "sweep": None}
        with db.tx():
            now = self.clock()
            ttl = float(self.cap["queue_ttl_seconds"])
            for lease in self._active_all():
                if lease["unit"] and self._unit_dead(lease):
                    self._finish(lease, "released", "exited", "lease_released", evs, stop=False)
                    out["released"].append(lease["id"])
                elif now - (lease["last_used"] or lease["started"] or now) > (lease["idle_seconds"] or self.cap["default_idle_seconds"]):
                    self._finish(lease, "expired", "idle", "lease_expired", evs)
                    out["expired"].append(lease["id"])
            for lease in [dict(r) for r in self.conn.execute("SELECT * FROM leases WHERE state='queued'")]:
                if now - lease["requested"] > ttl:
                    self._finish(lease, "expired", "queue_ttl", "lease_expired", evs)
                    out["expired"].append(lease["id"])
            self._promote(evs, out["promoted"])
        self._flush(evs)
        if sweep is None:
            sweep = self._last_sweep is None or self.clock() - self._last_sweep >= float(self.sweep_cfg["interval"])
        if sweep:
            try:
                out["sweep"] = self.sweep()
            except Exception as e:
                out["sweep"] = {"error": str(e)}
        return out

    def _active_all(self):
        return [dict(r) for r in self.conn.execute("SELECT * FROM leases WHERE state='active' ORDER BY id")]

    def _unit_dead(self, lease):
        """True solo si systemd confirma que la unidad ya no está viva (si la consulta falla, no se asume nada)."""
        rc, out, _ = self._run(["systemctl", "--user", "show", _svc(lease["unit"]), "-p", "ActiveState,MainPID"])
        if rc != 0:
            return False
        info = _parse_show(out)
        state = info.get("ActiveState")
        if not state:
            return False
        if state in LIVE:
            try:
                pid = int(info.get("MainPID") or 0) or None
            except ValueError:
                pid = None
            if pid and pid != lease["pid"]:
                self.conn.execute("UPDATE leases SET pid=? WHERE id=?", (pid, lease["id"]))
            return False
        return True

    # ------------------------------------------------------------------ status

    def status(self):
        with db.tx():
            queue = self._queue_ids()
            rows = [dict(r) for r in self.conn.execute("SELECT * FROM leases WHERE state IN ('active','queued') ORDER BY requested, id")]
            active = [self._view(r) for r in rows if r["state"] == "active"]
            queued = sorted((self._view(r, queue) for r in rows if r["state"] == "queued"), key=lambda v: v["position"] or 0)
            ports = []
            for r in self.conn.execute("SELECT * FROM ports ORDER BY port"):
                p = dict(r)
                p["range"] = self._block(p["port"])["range"]
                ports.append(p)
            machine = self._machine()
            cpu = self._cpu_used(machine)
            cap = {"max_servers": int(self.cap["max_servers"]), "max_per_project": int(self.cap["max_per_project"]),
                   "used": sum(1 for a in active if a["kind"] == "test_server"),
                   "max_cpu_pct": self.cap["max_cpu_pct"], "min_ram_avail_mb": self.cap["min_ram_avail_mb"],
                   "cpu_pct_used": round(cpu) if cpu is not None else None, "ram_avail_mb": machine.get("ram_avail_mb")}
        return {"active": active, "queued": queued, "ports": ports, "capacity": cap}

    # ------------------------------------------------------------------ barrido

    def sweep(self, dry_run=False):
        """Busca huérfanos. Unidades `chopshop-ts-*` sin lease activo: `systemctl --user stop <exacta>`. Scopes de agentes de
        T3: en modo "report" solo informa; en "kill" señala PIDs exactos del cgroup.procs (ver `_sweep_scopes`).
        Con dry_run no cambia nada ni emite eventos."""
        evs = []
        found = set()
        report = {"dry_run": bool(dry_run), "ts": self.clock()}
        with db.tx():
            report["units"] = self._sweep_units(dry_run, evs, found)
            report["ports"] = self._sweep_ports(dry_run)
        report["agent_scopes"] = self._sweep_scopes(dry_run, evs, found)
        if not dry_run:
            self._seen &= found     # olvida los que ya desaparecieron (si reaparecen, se vuelven a anunciar)
            self._last_sweep = self.clock()
        self._flush(evs)
        report["orphans"] = len(report["units"]) + sum(len(s["candidates"]) for s in report["agent_scopes"]["scopes"])
        return report

    def _announce(self, key, dry_run, found, evs, project, body):
        found.add(key)
        if not dry_run and key not in self._seen:
            self._seen.add(key)
            evs.append(("orphan_found", project, body))

    def _sweep_units(self, dry_run, evs, found):
        rc, out, _ = self._run(["systemctl", "--user", "list-units", "--type=service", "--no-legend", "--plain", "--no-pager",
                                UNIT_PREFIX + "*"])
        if rc != 0:
            return []
        mine = {_svc(r["unit"]) for r in self.conn.execute("SELECT unit FROM leases WHERE state='active' AND unit IS NOT NULL")}
        res = []
        for line in out.splitlines():
            f = line.split()
            if len(f) < 3:
                continue
            name, active = f[0], f[2]
            m = _UNIT_RX.match(name)
            if not m or name in mine or active in ("inactive", "failed"):
                continue
            project = m.group(1)
            entry = {"unit": name, "project": project, "active": active}
            self._announce(("unit", name), dry_run, found, evs, project, {"kind": "unit", "unit": name})
            if dry_run:
                entry["action"] = "would_stop"
            else:
                ok, detail = self._stop_unit(name)
                entry.update(action="stop", ok=ok)
                if ok:
                    evs.append(("orphan_stopped", project, {"kind": "unit", "unit": name}))
                else:
                    entry["detail"] = detail
            res.append(entry)
        return res

    def _sweep_ports(self, dry_run):
        """Bloques sin lease cuyo worktree ya no existe: se devuelven al pool."""
        res = []
        for r in self.conn.execute("SELECT * FROM ports WHERE lease_id IS NULL"):
            if not os.path.isdir(r["worktree"]):
                res.append({"port": r["port"], "project": r["project"], "worktree": r["worktree"]})
        if not dry_run:
            for p in res:
                self.conn.execute("DELETE FROM ports WHERE port=? AND lease_id IS NULL", (p["port"],))
        return res

    # --- scopes de agentes (cgroup v2)

    @staticmethod
    def _read_pids(scope_dir):
        """PIDs listados ahora mismo en el `cgroup.procs` de ese scope (solo enteros > 1)."""
        try:
            with open(os.path.join(scope_dir, "cgroup.procs")) as f:
                return [int(x) for x in f.read().split() if x.isdigit() and int(x) > 1]
        except OSError:
            return []

    def _scope_dirs(self):
        res = []
        for d, _dirs, files in os.walk(self.cgroup_root):
            if "cgroup.procs" in files:
                res.append(d)
        return sorted(res)

    def _proc_info(self, pid, listening):
        """Puertos en LISTEN del proceso, cwd (y si ya no existe) y T3CODE_THREAD_ID, leyendo /proc/<pid>."""
        base = os.path.join(self.proc_root, str(pid))
        ports = []
        try:
            for fd in os.listdir(os.path.join(base, "fd")):
                try:
                    tgt = os.readlink(os.path.join(base, "fd", fd))
                except OSError:
                    continue
                m = re.match(r"socket:\[(\d+)\]$", tgt)
                if m and int(m.group(1)) in listening:
                    ports.append(listening[int(m.group(1))])
        except OSError:
            pass
        cwd, gone = None, False
        try:
            cwd = os.readlink(os.path.join(base, "cwd"))
            if cwd.endswith(" (deleted)"):
                cwd, gone = cwd[:-len(" (deleted)")], True
            elif not os.path.isdir(cwd):
                gone = True
        except OSError:
            pass
        thread_id = None
        try:
            with open(os.path.join(base, "environ"), "rb") as f:
                for kv in f.read().split(b"\0"):
                    if kv.startswith(b"T3CODE_THREAD_ID="):
                        thread_id = kv.split(b"=", 1)[1].decode("utf-8", "replace") or None
        except OSError:
            pass
        return {"ports": sorted(set(ports)), "cwd": cwd, "cwd_gone": gone, "thread_id": thread_id}

    def _thread_for(self, info, threads):
        if info["thread_id"] and info["thread_id"] in threads:
            return threads[info["thread_id"]]
        cwd = info["cwd"]
        best = None
        for t in threads.values():
            wt = t.get("worktree")
            if cwd and wt and (cwd == wt or cwd.startswith(wt.rstrip("/") + "/")) and (best is None or len(wt) > len(best["worktree"])):
                best = t
        return best

    def _sweep_scopes(self, dry_run, evs, found):
        mode = self.sweep_cfg.get("agent_scopes")
        mode = mode if mode in ("report", "kill") else "report"
        res = {"mode": mode, "root": self.cgroup_root, "available": os.path.isdir(self.cgroup_root), "scopes": []}
        if not res["available"]:
            return res
        grace = float(self.sweep_cfg["grace_seconds"])
        now = self.clock()
        with db.tx():
            threads = {r["thread_id"]: dict(r) for r in self.conn.execute("SELECT * FROM t3_threads")}
        listening = self._listening()
        for sdir in self._scope_dirs():
            pids = self._read_pids(sdir)
            if not pids:
                continue
            scope = os.path.relpath(sdir, self.cgroup_root)
            entry = {"scope": scope, "procs": len(pids), "candidates": [], "held": []}
            for pid in pids:
                info = self._proc_info(pid, listening)
                thread = self._thread_for(info, threads)
                reasons = []
                if info["ports"]:
                    reasons.append("escucha puerto")
                if info["cwd_gone"]:
                    reasons.append("cwd ya no existe")
                if thread and thread.get("worktree") and not os.path.isdir(thread["worktree"]):
                    reasons.append("worktree ya no existe")
                if not reasons:
                    continue
                item = {"pid": pid, "reasons": reasons, "ports": info["ports"], "cwd": info["cwd"],
                        "thread_id": thread["thread_id"] if thread else info["thread_id"]}
                if not thread:
                    entry["held"].append(dict(item, why="hilo desconocido"))
                elif not thread.get("settled"):
                    entry["held"].append(dict(item, why="hilo no settled"))
                elif thread.get("updated") is None or now - thread["updated"] < grace:
                    entry["held"].append(dict(item, why="dentro de la gracia"))
                else:
                    entry["candidates"].append(item)
                    self._announce(("pid", scope, pid), dry_run, found, evs, thread.get("project"),
                                   {"kind": "scope_process", "scope": scope, "pid": pid, "reasons": reasons,
                                    "thread_id": item["thread_id"]})
            if mode == "kill" and not dry_run and entry["candidates"]:
                killed, survivors = self._terminate(sdir, [c["pid"] for c in entry["candidates"]])
                entry.update(killed=killed, survivors=survivors)
                for c in entry["candidates"]:
                    if c["pid"] in killed:
                        evs.append(("orphan_stopped", threads.get(c["thread_id"], {}).get("project"),
                                    {"kind": "scope_process", "scope": scope, "pid": c["pid"], "thread_id": c["thread_id"]}))
            res["scopes"].append(entry)
        return res

    def _signal(self, scope_dir, pid, sig):
        """Señala SOLO si el PID sigue listado ahora mismo en el cgroup.procs de ese scope (evita PIDs reciclados)."""
        if pid <= 1 or pid == os.getpid() or pid not in self._read_pids(scope_dir):
            return False
        try:
            self.kill_fn(pid, sig)
        except ProcessLookupError:
            return False
        except OSError:
            return False
        return True

    def _terminate(self, scope_dir, pids):
        """SIGTERM -> espera -> SIGKILL, solo a `pids` exactos. Devuelve (terminados, supervivientes)."""
        sent = [p for p in pids if self._signal(scope_dir, p, signal.SIGTERM)]
        for _ in range(max(1, int(self.term_wait / 0.5))):
            if not [p for p in sent if p in self._read_pids(scope_dir)]:
                break
            self.sleep(0.5)
        for p in [p for p in sent if p in self._read_pids(scope_dir)]:
            self._signal(scope_dir, p, signal.SIGKILL)
        if sent:
            self.sleep(0.2)
        left = set(self._read_pids(scope_dir))
        return [p for p in sent if p not in left], [p for p in sent if p in left]
