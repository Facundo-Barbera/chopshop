"""Colector de métricas del agente: CPU/RAM de la máquina y de los procesos agrupados por **app** y por **proyecto**.

Solo lee `/proc` (stat, cmdline, cwd, cgroup, environ, meminfo, loadavg, uptime) y `os.statvfs`; nunca ejecuta `ps`.
Persiste crudo en `machine_samples`/`samples`, agrega a `samples_agg` (1 min y 1 h) y aplica la retención de `cfg["retention"]`.

Diseño para costar < 1 % de CPU:
- solo se recorren los procesos (no los hilos): el `stat` del proceso ya suma todos sus hilos;
- una lectura de `stat` por proceso y muestra; `cmdline`, `cgroup` y `environ` se leen una vez y se cachean por
  (pid, starttime, comm) (un `exec` cambia `comm`, así que invalida el caché);
- los hilos del kernel y los zombis se ignoran;
- el intervalo se espacia (`Collector.interval()`) cuando la máquina está cargada.

El parseo está en funciones puras de módulo (testeables sin /proc); `Collector(cfg, conn, proc_root=...)` acepta un
árbol /proc falso."""
import json
import os
import re
import threading
import time

from . import db

GROUPS = ("machine", "app", "project")
PF_KTHREAD = 0x00200000          # flag de hilo del kernel en /proc/<pid>/stat
MACHINE_NAME = "machine"         # nombre de la serie/fila agregada de la máquina
MAX_BACKOFF = 60.0               # tope (s) del intervalo con retroceso, salvo que sample_interval ya sea mayor
TOP_N = 25                       # apps persistidas por muestra: las N con más CPU unidas a las N con más RAM
DISK_EVERY = 60.0                # s entre lecturas de statvfs
DEFAULT_STEP = 10.0              # paso crudo asumido si no hay datos para estimarlo
THREAD_ENV = "T3CODE_THREAD_ID"

DEFAULT_RETENTION = {"raw_hours": 24, "m1_days": 30, "h1_days": 365}

try:
    CLK_TCK = os.sysconf("SC_CLK_TCK")
except (ValueError, OSError, AttributeError):
    CLK_TCK = 100


class CollectorError(ValueError):
    """Parámetros inválidos del colector (grupo desconocido, rango invertido...)."""


# ---------------------------------------------------------------------------------------------------------------
# Parseo puro de /proc
# ---------------------------------------------------------------------------------------------------------------

def parse_stat(text):
    """`/proc/<pid>/stat` -> dict o None. `comm` puede llevar espacios y paréntesis: se corta en el último ')'."""
    i, j = text.find("("), text.rfind(")")
    if i < 0 or j < i:
        return None
    rest = text[j + 2:].split()
    if len(rest) < 22:
        return None
    try:
        return {"pid": int(text[:i]), "comm": text[i + 1:j], "state": rest[0], "ppid": int(rest[1]),
                "flags": int(rest[6]), "ticks": int(rest[11]) + int(rest[12]),   # utime + stime (ticks de CLK_TCK)
                "starttime": int(rest[19]), "rss_pages": int(rest[21])}
    except ValueError:
        return None


def parse_cpu_stat(text):
    """`/proc/stat` -> {"busy","total","cpus"} (jiffies agregados) o None."""
    out = None
    cpus = 0
    for line in text.splitlines():
        if line.startswith("cpu "):
            try:
                v = [int(x) for x in line.split()[1:]]
            except ValueError:
                return None
            if len(v) < 4:
                return None
            total = sum(v[:8])                      # user..steal; guest ya está dentro de user/nice
            idle = v[3] + (v[4] if len(v) > 4 else 0)   # idle + iowait
            out = {"busy": total - idle, "total": total}
        elif line.startswith("cpu") and line[3:4].isdigit():
            cpus += 1
    if out is not None:
        out["cpus"] = cpus
    return out


def parse_meminfo(text):
    """`/proc/meminfo` -> {clave: kB}."""
    kv = {}
    for line in text.splitlines():
        p = line.split()
        if len(p) >= 2:
            try:
                kv[p[0].rstrip(":")] = int(p[1])
            except ValueError:
                pass
    return kv


def parse_loadavg(text):
    """`/proc/loadavg` -> (l1, l5, l15) o None."""
    p = text.split()
    try:
        return float(p[0]), float(p[1]), float(p[2])
    except (IndexError, ValueError):
        return None


def parse_uptime(text):
    """`/proc/uptime` -> segundos desde el arranque o None."""
    try:
        return float(text.split()[0])
    except (IndexError, ValueError):
        return None


def parse_cmdline(raw):
    """Bytes de `/proc/<pid>/cmdline` -> lista de argumentos."""
    if not raw:
        return []
    return [a.decode("utf-8", "replace") for a in raw.rstrip(b"\0").split(b"\0")]


def parse_environ_var(raw, name):
    """Valor de `name` en los bytes de `/proc/<pid>/environ` o None."""
    prefix = name.encode() + b"="
    for item in raw.split(b"\0"):
        if item.startswith(prefix):
            return item[len(prefix):].decode("utf-8", "replace")
    return None


def parse_cgroup(text):
    """`/proc/<pid>/cgroup` -> ruta del cgroup ('/user.slice/...'); cgroup v2 ('0::') o la jerarquía systemd de v1."""
    first = None
    for line in text.splitlines():
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        if parts[0] == "0" and parts[1] == "":
            return parts[2]
        if parts[1] == "name=systemd":
            return parts[2]
        if first is None and parts[2] != "/":
            first = parts[2]
    return first or "/"


_GENERIC_CG = {"-.slice", "user.slice", "system.slice", "app.slice", "session.slice", "background.slice",
               "init.scope", "machine.slice"}
_GENERIC_CG_RX = re.compile(r"^(?:user-\d+\.slice|user@\d+\.service|session-\w+\.scope)$")
_INSTANCE_SLICE_RX = re.compile(r"^(.+)-[0-9a-f]{8,}\.slice$")   # 'app-t3code-agents-2523669e90f4.slice'


def _cg_components(path):
    return [c for c in path.strip("/").split("/") if c]


def cgroup_label(path):
    """Nombre corto del cgroup que se reporta: la unidad `chopshop-*` más interna; si no, el slice no genérico más
    interno (ignorando slices por instancia como `app-t3code-agents-<hex>.slice`, que se reportan como su padre);
    si no, el service/scope más interno. None si solo hay cgroups genéricos."""
    comps = _cg_components(path or "")
    rev = list(reversed(comps))
    for c in rev:
        if c.startswith("chopshop-"):
            return c
    slices = []
    for c in rev:
        if not c.endswith(".slice") or c in _GENERIC_CG or _GENERIC_CG_RX.match(c):
            continue
        m = _INSTANCE_SLICE_RX.match(c)
        if m and (m.group(1) + ".slice") in comps:
            continue
        slices.append(c)
    if slices:
        return slices[0]
    for c in rev:
        if c not in _GENERIC_CG and not _GENERIC_CG_RX.match(c) and not c.endswith(".slice"):
            return c
    return None


_TS_UNIT_RX = re.compile(r"^chopshop-ts-(.+?)-(l-\d+)$")
_TS_UNIT_FALLBACK_RX = re.compile(r"^chopshop-ts-(.+)-[^-]+$")


def project_from_cgroup(path):
    """Proyecto de una unidad `chopshop-ts-<proyecto>-<id>[.service|.scope]` en la ruta del cgroup, o None."""
    for c in reversed(_cg_components(path or "")):
        if not c.startswith("chopshop-ts-"):
            continue
        base = re.sub(r"\.(?:service|scope|slice)$", "", c)
        m = _TS_UNIT_RX.match(base) or _TS_UNIT_FALLBACK_RX.match(base)
        if m:
            return m.group(1)
    return None


# Herramientas que corren sobre node/bun/deno y se reportan con su propio nombre de app.
NODE_TOOLS = {"claude", "codex", "tsc", "tsserver", "vitest", "vite", "jest", "eslint", "prettier", "turbo", "pnpm",
              "npm", "npx", "yarn", "next", "esbuild", "webpack", "playwright", "storybook", "nodemon", "tsx"}
_TOOL_ALIAS = {"claude-code": "claude"}
_NODE_LIKE = {"node", "bun", "deno"}
_NODE_SKIP_WITH_VALUE = {"-r", "--require", "--import", "--loader", "--experimental-loader"}
_NODE_INLINE_CODE = {"-e", "--eval", "-p", "--print"}
_INTERP_RX = re.compile(r"^(python|ruby|perl|php|node)[\d.]*$")
_SCRIPT_EXT_RX = re.compile(r"\.(?:c|m)?[jt]s$|\.cjs$|\.mjs$")


def normalize_exe(name):
    """Nombre de ejecutable -> nombre de app normalizado (python3.12 -> python, google-chrome-stable -> chrome...)."""
    n = name.strip().lstrip("-").lower()
    if n.endswith(".exe"):
        n = n[:-4]
    m = _INTERP_RX.match(n)
    if m:
        n = m.group(1)
    if n == "nodejs":
        n = "node"
    if n.startswith(("google-chrome", "chromium", "chrome-")) or n in ("chrome_crashpad_handler", "chrome-sandbox"):
        return "chrome"
    if n.startswith("firefox"):
        return "firefox"
    return n[:40]


def _node_tool(args):
    """Herramienta detrás de `node <script>`: busca el nombre de la herramienta en la ruta del script (de atrás a delante)."""
    script = None
    it = iter(args)
    for a in it:
        if a in _NODE_INLINE_CODE:
            return None
        if a in _NODE_SKIP_WITH_VALUE:
            next(it, None)
            continue
        if a.startswith("-"):
            continue
        script = a
        break
    if not script:
        return None
    for comp in reversed(script.replace("\\", "/").split("/")):
        base = _SCRIPT_EXT_RX.sub("", comp.lower())
        base = _TOOL_ALIAS.get(base, base)
        if base in NODE_TOOLS:
            return base
    return None


def app_name(comm, cmdline):
    """Nombre de app normalizado para un proceso: ejecutable de argv[0] (o `comm`); node + herramienta conocida -> la herramienta."""
    exe = ""
    if cmdline and cmdline[0]:
        first = cmdline[0]
        if len(cmdline) == 1 and " " in first and not first.startswith("/"):
            first = first.split(" ", 1)[0]          # títulos de proceso tipo 'next-server (v14)'
        exe = os.path.basename(first.rstrip("/"))
    name = normalize_exe(exe or comm or "")
    if name in _NODE_LIKE and len(cmdline) > 1:
        name = _node_tool(cmdline[1:]) or name
    return name or "unknown"


def _norm_path(p):
    if not p:
        return ""
    p = os.path.normpath(os.path.expanduser(str(p)))
    return "" if p in ("", ".", "/") else p


def build_matchers(cfg):
    """Prefijos para asignar un cwd a un proyecto -> (explicit [(prefijo, nombre)], roots [raíz])."""
    explicit, roots = [], set()
    for name, p in (cfg.get("projects") or {}).items():
        if isinstance(p, dict):
            for key in ("root", "worktrees"):
                for v in {_norm_path(p.get(key)), _norm_path(os.path.realpath(os.path.expanduser(p[key]))) if p.get(key) else ""}:
                    if v:
                        explicit.append((v, name))
    for key in ("worktrees_root", "projects_root"):
        v = cfg.get(key)
        if v:
            roots.update(x for x in (_norm_path(v), _norm_path(os.path.realpath(os.path.expanduser(v)))) if x)
    explicit.sort(key=lambda x: -len(x[0]))
    return explicit, sorted(roots, key=len, reverse=True)


def project_for_path(cwd, explicit, roots):
    """Proyecto de un cwd: raíz/worktrees de un proyecto configurado, o `<worktrees_root|projects_root>/<proyecto>/...`."""
    if not cwd:
        return None
    if cwd.endswith(" (deleted)"):
        cwd = cwd[:-len(" (deleted)")]
    for prefix, name in explicit:
        if cwd == prefix or cwd.startswith(prefix + "/"):
            return name
    for r in roots:
        if cwd.startswith(r + "/"):
            first = cwd[len(r) + 1:].split("/", 1)[0]
            if first:
                return first
    return None


# ---------------------------------------------------------------------------------------------------------------
# E/S de /proc
# ---------------------------------------------------------------------------------------------------------------

def _read(path, limit=65536):
    """Lee hasta `limit` bytes de un archivo de /proc; None si no existe o no hay permiso."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return None
    try:
        chunks, total = [], 0
        while total < limit:
            b = os.read(fd, min(65536, limit - total))
            if not b:
                break
            chunks.append(b)
            total += len(b)
        return b"".join(chunks)
    except OSError:
        return None
    finally:
        os.close(fd)


class _Info(object):
    """Datos estáticos de un proceso (cacheados por pid+starttime+comm)."""
    __slots__ = ("app", "cg", "cg_project", "tid")

    def __init__(self, app, cg, cg_project):
        self.app, self.cg, self.cg_project = app, cg, cg_project
        self.tid = None      # None = environ sin leer; "" = leído y sin T3CODE_THREAD_ID


class _Group(object):
    __slots__ = ("ticks", "rss", "procs", "cgs")

    def __init__(self):
        self.ticks, self.rss, self.procs, self.cgs = 0, 0, 0, {}


class Collector(object):
    """Muestrea /proc, persiste y compacta. Seguro entre hilos (un candado interno + `db.tx()` para escribir)."""

    def __init__(self, cfg, conn, proc_root="/proc", clock=time.time, disk_path="/", page_size=None, clk_tck=None):
        self.cfg, self.conn = cfg, conn
        self.proc_root = proc_root
        self.disk_path = disk_path
        self._clock = clock
        self.page_size = page_size or _page_size()
        self.clk_tck = clk_tck or CLK_TCK
        self.top_n = TOP_N
        self.last_ts = None             # ts de la última muestra
        self.last_error = None          # repr de la última excepción en run_forever
        self._explicit, self._roots = build_matchers(cfg)
        self._lock = threading.RLock()
        self._info = {}                 # (pid, starttime, comm) -> _Info
        self._prev = {}                 # (pid, starttime) -> ticks de la muestra anterior
        self._prev_ts = None
        self._prev_uptime = None
        self._prev_cpu = None
        self._thread_proj = {}          # thread_id -> proyecto (válido solo durante una muestra)
        self._disk = None               # (ts, used_gb, total_gb)
        self._latest = None

    # -- utilidades ---------------------------------------------------------------------------------------------

    def _path(self, *parts):
        return os.path.join(self.proc_root, *parts)

    def _text(self, name):
        raw = _read(self._path(name), 1 << 20)
        return raw.decode("utf-8", "replace") if raw else ""

    def interval(self):
        """Segundos hasta la próxima muestra: `sample_interval`, x3 si load1 > 0.5*cpus y x6 si load1 > cpus (tope 60 s)."""
        try:
            base = float(self.cfg.get("sample_interval") or 10)
        except (TypeError, ValueError):
            base = 10.0
        m = (self._latest or {}).get("machine")
        if not m or not m.get("load"):
            return base
        load1, cpus = m["load"][0], max(1, m.get("cpus") or 1)
        mult = 6 if load1 > cpus else 3 if load1 > 0.5 * cpus else 1
        return min(base * mult, max(base, MAX_BACKOFF))

    # -- muestreo -----------------------------------------------------------------------------------------------

    def _read_machine(self, now):
        cpu = parse_cpu_stat(self._text("stat"))
        mem = parse_meminfo(self._text("meminfo"))
        load = parse_loadavg(self._text("loadavg")) or (0.0, 0.0, 0.0)
        uptime = parse_uptime(self._text("uptime"))
        cpu_pct = 0.0
        if cpu:
            if self._prev_cpu:
                dt = cpu["total"] - self._prev_cpu[1]
                if dt > 0:
                    cpu_pct = max(0.0, min(100.0, 100.0 * (cpu["busy"] - self._prev_cpu[0]) / dt))
            self._prev_cpu = (cpu["busy"], cpu["total"])
        total = mem.get("MemTotal", 0) // 1024
        avail = mem.get("MemAvailable", mem.get("MemFree", 0)) // 1024
        swap = max(0, mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)) // 1024
        used_gb, total_gb = self._disk_usage(now)
        return {"ts": now, "cpus": (cpu or {}).get("cpus") or os.cpu_count() or 1,
                "load": [round(x, 2) for x in load], "cpu_pct": round(cpu_pct, 1),
                "ram_total_mb": total, "ram_avail_mb": avail,
                "ram_pct": round(100.0 * (1 - avail / total)) if total else 0,
                "swap_used_mb": swap, "disk_used_gb": used_gb, "disk_total_gb": total_gb,
                "disk_pct": round(100.0 * used_gb / total_gb) if total_gb else 0,
                "os": os.uname().sysname, "uptime": int(uptime or 0)}, uptime

    def _disk_usage(self, now):
        if self._disk is None or now - self._disk[0] >= DISK_EVERY or now < self._disk[0]:
            try:
                st = os.statvfs(self.disk_path)
                total = st.f_blocks * st.f_frsize
                used = (st.f_blocks - st.f_bfree) * st.f_frsize
                self._disk = (now, round(used / 1024 ** 3, 1), round(total / 1024 ** 3, 1))
            except OSError:
                self._disk = (now, 0.0, 0.0)
        return self._disk[1], self._disk[2]

    def _thread_project(self, tid):
        if tid in self._thread_proj:
            return self._thread_proj[tid]
        proj = None
        try:
            with db.tx():
                row = self.conn.execute("SELECT project FROM t3_threads WHERE thread_id=?", (tid,)).fetchone()
            proj = row[0] if row and row[0] else None
        except Exception:    # DB ocupada o sin tabla: el proceso simplemente queda sin proyecto por este camino
            proj = None
        self._thread_proj[tid] = proj
        return proj

    def _classify(self, pid_dir, st):
        cmd = parse_cmdline(_read(os.path.join(pid_dir, "cmdline"), 4096) or b"")
        cgpath = parse_cgroup((_read(os.path.join(pid_dir, "cgroup"), 4096) or b"").decode("utf-8", "replace"))
        return _Info(app_name(st["comm"], cmd), cgroup_label(cgpath), project_from_cgroup(cgpath))

    def _scan(self, uptime, dt):
        """Recorre los procesos -> (apps {nombre: _Group}, projects {nombre: _Group}, n_procs)."""
        apps, projects = {}, {}
        info_cache, prev = self._info, self._prev
        new_info, new_prev = {}, {}
        first = self._prev_ts is None or dt <= 0
        prev_uptime = self._prev_uptime
        page, tck = self.page_size, self.clk_tck
        n = 0
        try:
            entries = os.listdir(self.proc_root)
        except OSError:
            entries = []
        for entry in entries:
            if not entry.isdigit():
                continue
            pid_dir = os.path.join(self.proc_root, entry)
            raw = _read(os.path.join(pid_dir, "stat"), 4096)
            if not raw:
                continue
            st = parse_stat(raw.decode("utf-8", "replace"))
            if st is None or st["flags"] & PF_KTHREAD or st["state"] in ("Z", "X"):
                continue
            pk = (st["pid"], st["starttime"])
            ik = (st["pid"], st["starttime"], st["comm"])
            info = info_cache.get(ik)
            if info is None:
                info = self._classify(pid_dir, st)
            new_info[ik] = info
            new_prev[pk] = st["ticks"]
            # delta de CPU: contra la muestra anterior; un proceso nacido entre muestras cuenta todo lo que ha gastado
            if first:
                delta = 0
            elif pk in prev:
                delta = max(0, st["ticks"] - prev[pk])
            elif prev_uptime is not None and st["starttime"] / tck >= prev_uptime:
                delta = st["ticks"]
            else:
                delta = 0
            rss = st["rss_pages"] * page
            n += 1
            g = apps.get(info.app)
            if g is None:
                g = apps[info.app] = _Group()
            self._add(g, delta, rss, info.cg)
            proj = self._project_of(pid_dir, info)
            if proj:
                g = projects.get(proj)
                if g is None:
                    g = projects[proj] = _Group()
                self._add(g, delta, rss, info.cg)
        self._info, self._prev = new_info, new_prev
        return apps, projects, n

    @staticmethod
    def _add(g, delta, rss, cg):
        g.ticks += delta
        g.rss += rss
        g.procs += 1
        if cg:
            g.cgs[cg] = g.cgs.get(cg, 0) + 1

    def _project_of(self, pid_dir, info):
        """cwd bajo un proyecto -> T3CODE_THREAD_ID (tabla t3_threads) -> unidad chopshop-ts-<proyecto>-..."""
        try:
            cwd = os.readlink(os.path.join(pid_dir, "cwd"))
        except OSError:
            cwd = None
        proj = project_for_path(cwd, self._explicit, self._roots) if cwd else None
        if proj:
            return proj
        if info.tid is None:
            raw = _read(os.path.join(pid_dir, "environ"), 262144)
            info.tid = (parse_environ_var(raw, THREAD_ENV) or "") if raw else ""
        if info.tid:
            proj = self._thread_project(info.tid)
            if proj:
                return proj
        return info.cg_project

    def _finish(self, groups, dt, limit=None):
        out = []
        for name, g in groups.items():
            cpu = 100.0 * g.ticks / (self.clk_tck * dt) if dt > 0 else 0.0
            cgs = sorted(g.cgs, key=lambda c: (-g.cgs[c], c))[:5]
            out.append({"name": name, "cpu_pct": round(cpu, 1), "rss_mb": round(g.rss / 1048576.0, 1),
                        "procs": g.procs, "cgroups": cgs})
        out.sort(key=lambda a: (-a["cpu_pct"], -a["rss_mb"], a["name"]))
        if limit and len(out) > 2 * limit:
            keep = {a["name"] for a in out[:limit]}
            keep.update(a["name"] for a in sorted(out, key=lambda a: (-a["rss_mb"], a["name"]))[:limit])
            out = [a for a in out if a["name"] in keep]
        return out

    def sample_once(self):
        """Toma una muestra, la persiste y devuelve {"machine","apps","projects"}. La primera muestra tiene cpu_pct = 0."""
        with self._lock:
            now = self._clock()
            dt = (now - self._prev_ts) if self._prev_ts is not None else 0.0
            self._thread_proj = {}
            machine, uptime = self._read_machine(now)
            apps, projects, n = self._scan(uptime, dt)
            machine["procs"] = n
            snap = {"machine": machine, "apps": self._finish(apps, dt, self.top_n),
                    "projects": self._finish(projects, dt)}
            self._prev_ts, self._prev_uptime = now, uptime
            self._persist(now, snap)
            self.last_ts = now
            self._latest = snap
            return snap

    def _persist(self, ts, snap):
        m = snap["machine"]
        extra = db.jdump({k: m[k] for k in ("os", "uptime", "ram_pct", "disk_pct", "procs")})
        rows = [(ts, kind, g["name"], g["cpu_pct"], g["rss_mb"], g["procs"], db.jdump({"cgroups": g["cgroups"]}))
                for kind, key in (("app", "apps"), ("project", "projects")) for g in snap[key]]
        with db.tx():
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                self.conn.execute(
                    "INSERT OR REPLACE INTO machine_samples(ts,load1,load5,load15,cpus,cpu_pct,ram_total_mb,ram_avail_mb,"
                    "swap_used_mb,disk_used_gb,disk_total_gb,extra) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                    (ts, m["load"][0], m["load"][1], m["load"][2], m["cpus"], m["cpu_pct"], m["ram_total_mb"],
                     m["ram_avail_mb"], m["swap_used_mb"], m["disk_used_gb"], m["disk_total_gb"], extra))
                self.conn.executemany("INSERT INTO samples(ts,kind,name,cpu_pct,rss_mb,procs,extra) VALUES (?,?,?,?,?,?,?)", rows)
                self.conn.execute("COMMIT")
            except Exception:
                self.conn.execute("ROLLBACK")
                raise

    def latest(self):
        """Última muestra en memoria; tras un reinicio, la última guardada en la DB; vacía si no hay ninguna."""
        # Sin `self._lock`: Resources llama aquí con `db.tx()` tomado y `sample_once` toma `_lock` y luego `db.tx()`
        # (inversión de orden = interbloqueo). Leer la referencia es atómico y `_latest` se reemplaza entera, no se muta.
        snap = self._latest
        if snap is not None:
            return snap
        snap = self._latest_from_db()
        return snap if snap is not None else {"machine": {}, "apps": [], "projects": []}

    def _latest_from_db(self):
        with db.tx():
            r = self.conn.execute("SELECT * FROM machine_samples ORDER BY ts DESC LIMIT 1").fetchone()
            if r is None:
                return None
            srows = db.rows(self.conn.execute(
                "SELECT kind,name,cpu_pct,rss_mb,procs,extra FROM samples WHERE ts=? ORDER BY cpu_pct DESC, rss_mb DESC", (r["ts"],)))
        ex = db.jload(r["extra"], {})
        machine = {"ts": r["ts"], "cpus": r["cpus"], "load": [r["load1"], r["load5"], r["load15"]], "cpu_pct": r["cpu_pct"],
                   "ram_total_mb": r["ram_total_mb"], "ram_avail_mb": r["ram_avail_mb"], "ram_pct": ex.get("ram_pct", 0),
                   "swap_used_mb": r["swap_used_mb"], "disk_used_gb": r["disk_used_gb"], "disk_total_gb": r["disk_total_gb"],
                   "disk_pct": ex.get("disk_pct", 0), "os": ex.get("os", ""), "uptime": ex.get("uptime", 0), "procs": ex.get("procs", 0)}
        snap = {"machine": machine, "apps": [], "projects": []}
        for s in srows:
            snap["apps" if s["kind"] == "app" else "projects"].append(
                {"name": s["name"], "cpu_pct": s["cpu_pct"], "rss_mb": s["rss_mb"], "procs": s["procs"],
                 "cgroups": db.jload(s["extra"], {}).get("cgroups", [])})
        return snap

    def run_forever(self, stop, compact_every=300.0):
        """Bucle de fondo para el servidor: muestrea, compacta cada `compact_every` s y espera `interval()`.
        `stop` es un threading.Event. Un fallo no mata el hilo: queda en `last_error`."""
        last_compact = None
        while not stop.is_set():
            try:
                self.sample_once()
                mono = time.monotonic()
                if last_compact is None or mono - last_compact >= compact_every:
                    last_compact = mono
                    self.compact()
                self.last_error = None
            except Exception as e:
                self.last_error = repr(e)
            if stop.wait(self.interval()):
                break

    # -- compactación y retención ---------------------------------------------------------------------------------

    def compact(self, now=None):
        """Agrega lo crudo a `samples_agg` 1m y lo de 1m a 1h (solo cubetas completas, de forma incremental e idempotente) y
        aplica la retención de `cfg["retention"]`. Devuelve {"m1": filas, "h1": filas, "purged": filas}."""
        now = self._clock() if now is None else now
        with self._lock, db.tx():
            m1 = self._compact_m1(now)
            h1 = self._compact_h1(now)
            purged = self._retain(now)
        return {"m1": m1, "h1": h1, "purged": purged}

    def _meta_get(self, key):
        return _meta(self.conn, key)

    def _meta_set(self, key, value):
        self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES (?,?)", (key, repr(float(value))))

    def _compact_m1(self, now):
        upper = int(now // 60) * 60
        lo = self._meta_get("collector.m1_wm")
        if lo is None:
            r = self.conn.execute("SELECT MIN(ts) FROM machine_samples").fetchone()
            if r[0] is None:
                return 0
            lo = int(r[0] // 60) * 60
        if upper <= lo:
            return 0
        rows = _agg_raw(self.conn, lo, upper, 60)
        self.conn.execute("BEGIN IMMEDIATE")
        try:
            self.conn.executemany("INSERT OR REPLACE INTO samples_agg(res,ts,kind,name,cpu_avg,cpu_max,rss_avg,rss_max,procs_max,n)"
                                  " VALUES ('1m',?,?,?,?,?,?,?,?,?)", rows)
            self._meta_set("collector.m1_wm", upper)
            self.conn.execute("COMMIT")
        except Exception:
            self.conn.execute("ROLLBACK")
            raise
        return len(rows)

    def _compact_h1(self, now):
        m1_wm = self._meta_get("collector.m1_wm")
        if m1_wm is None:
            return 0
        upper = int(min(now, m1_wm) // 3600) * 3600
        lo = self._meta_get("collector.h1_wm")
        if lo is None:
            r = self.conn.execute("SELECT MIN(ts) FROM samples_agg WHERE res='1m'").fetchone()
            if r[0] is None:
                return 0
            lo = int(r[0] // 3600) * 3600
        if upper <= lo:
            return 0
        rows = self.conn.execute(
            "SELECT CAST(ts/3600 AS INTEGER)*3600, kind, name, SUM(cpu_avg*n)/SUM(n), MAX(cpu_max), SUM(rss_avg*n)/SUM(n),"
            " MAX(rss_max), MAX(procs_max), SUM(n) FROM samples_agg WHERE res='1m' AND ts>=? AND ts<? AND n>0"
            " GROUP BY 1,kind,name", (lo, upper)).fetchall()
        rows = [tuple(r) for r in rows]
        self.conn.execute("BEGIN IMMEDIATE")
        try:
            self.conn.executemany("INSERT OR REPLACE INTO samples_agg(res,ts,kind,name,cpu_avg,cpu_max,rss_avg,rss_max,procs_max,n)"
                                  " VALUES ('1h',?,?,?,?,?,?,?,?,?)", rows)
            self._meta_set("collector.h1_wm", upper)
            self.conn.execute("COMMIT")
        except Exception:
            self.conn.execute("ROLLBACK")
            raise
        return len(rows)

    def _retain(self, now):
        ret = dict(DEFAULT_RETENTION)
        ret.update(self.cfg.get("retention") or {})
        m1_wm, h1_wm = self._meta_get("collector.m1_wm"), self._meta_get("collector.h1_wm")
        purged = 0
        # lo crudo y los 1m solo se borran si ya están agregados al nivel siguiente (no se pierde nada sin compactar)
        if m1_wm is not None:
            cut = min(now - float(ret["raw_hours"]) * 3600, m1_wm)
            purged += self.conn.execute("DELETE FROM machine_samples WHERE ts<?", (cut,)).rowcount
            purged += self.conn.execute("DELETE FROM samples WHERE ts<?", (cut,)).rowcount
        if h1_wm is not None:
            cut = min(now - float(ret["m1_days"]) * 86400, h1_wm)
            purged += self.conn.execute("DELETE FROM samples_agg WHERE res='1m' AND ts<?", (cut,)).rowcount
        cut = now - float(ret["h1_days"]) * 86400
        purged += self.conn.execute("DELETE FROM samples_agg WHERE res='1h' AND ts<?", (cut,)).rowcount
        return max(0, purged)


def _page_size():
    try:
        return os.sysconf("SC_PAGE_SIZE")
    except (ValueError, OSError, AttributeError):
        return 4096


# ---------------------------------------------------------------------------------------------------------------
# Agregación y consulta
# ---------------------------------------------------------------------------------------------------------------

def _agg_raw(conn, lo, hi, step):
    """Agrega lo crudo con ts en [lo, hi) en cubetas de `step` s ->
    filas (ts_cubeta, kind, name, cpu_avg, cpu_max, rss_avg, rss_max, procs_max, n). La media de apps/proyectos se divide
    entre las muestras de máquina de la cubeta: una app ausente en una muestra cuenta como 0."""
    b = "CAST(ts/%d AS INTEGER)*%d" % (step, step)
    mrows = conn.execute(
        "SELECT %s, COUNT(*), AVG(cpu_pct), MAX(cpu_pct), AVG(ram_total_mb-ram_avail_mb), MAX(ram_total_mb-ram_avail_mb)"
        " FROM machine_samples WHERE ts>=? AND ts<? GROUP BY 1" % b, (lo, hi)).fetchall()
    counts = {r[0]: r[1] for r in mrows}
    out = [(r[0], "machine", MACHINE_NAME, r[2], r[3], r[4], r[5], None, r[1]) for r in mrows]
    for r in conn.execute(
            "SELECT %s, kind, name, SUM(cpu_pct), MAX(cpu_pct), SUM(rss_mb), MAX(rss_mb), MAX(procs), COUNT(*)"
            " FROM samples WHERE ts>=? AND ts<? GROUP BY 1,kind,name" % b, (lo, hi)).fetchall():
        n = counts.get(r[0]) or r[8]
        out.append((r[0], r[1], r[2], (r[3] or 0) / n, r[4], (r[5] or 0) / n, r[6], r[7], n))
    return out


def _merge_rows(rows, step):
    """Re-cubetea filas (name, ts, cpu, rss, peso) a `step` s con media ponderada."""
    acc = {}
    for name, ts, cpu, rss, w in rows:
        k = (name, int(ts // step) * step)
        a = acc.get(k)
        if a is None:
            a = acc[k] = [0.0, 0.0, 0.0]
        a[0] += (cpu or 0) * w
        a[1] += (rss or 0) * w
        a[2] += w
    return [(k[0], k[1], a[0] / a[2], a[1] / a[2], a[2]) for k, a in sorted(acc.items(), key=lambda x: (x[0][1], x[0][0])) if a[2] > 0]


def _meta(conn, key):
    r = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    try:
        return float(r[0]) if r else None
    except (TypeError, ValueError):
        return None


def _load(conn, group, res, lo, hi, name=None):
    """Filas (name, ts, cpu, rss, peso) de un grupo a la resolución `res` ('raw'|'1m'|'1h') en [lo, hi]. En 1m/1h
    se completa con lo todavía no compactado (cola) calculado al vuelo desde el nivel inferior."""
    nf = " AND name=?" if name else ""
    na = (name,) if name else ()
    if res == "raw":
        if group == "machine":
            cur = conn.execute("SELECT ts, cpu_pct, ram_total_mb-ram_avail_mb FROM machine_samples WHERE ts>=? AND ts<=? ORDER BY ts", (lo, hi))
            return [(MACHINE_NAME, r[0], r[1], r[2], 1) for r in cur.fetchall()]
        cur = conn.execute("SELECT name, ts, cpu_pct, rss_mb FROM samples WHERE kind=? AND ts>=? AND ts<=?" + nf + " ORDER BY ts",
                           (group, lo, hi) + na)
        return [(r[0], r[1], r[2], r[3], 1) for r in cur.fetchall()]
    wm = _meta(conn, "collector.m1_wm" if res == "1m" else "collector.h1_wm")
    cond = " AND ts<?" if wm is not None else ""
    args = (res, group, lo, hi) + ((wm,) if wm is not None else ()) + na
    cur = conn.execute("SELECT name, ts, cpu_avg, rss_avg, n FROM samples_agg WHERE res=? AND kind=? AND ts>=? AND ts<=?" + cond + nf +
                       " ORDER BY ts", args)
    rows = [(r[0], r[1], r[2], r[3], r[4] or 1) for r in cur.fetchall()]
    tail_lo = max(lo, wm) if wm is not None else lo
    if tail_lo <= hi:
        if res == "1m":
            for r in _agg_raw(conn, tail_lo, hi + 1e-6, 60):
                if r[1] == group and (not name or r[2] == name) and r[0] + 60 > lo:
                    rows.append((r[2], r[0], r[3], r[5], r[8]))
        else:
            rows += _merge_rows(_load(conn, group, "1m", tail_lo, hi, name), 3600)
    return rows


_NATIVE_STEP = {"1m": 60.0, "1h": 3600.0}


def _pick_res(span, step):
    if step is not None:
        return "1h" if step >= 3600 else "1m" if step >= 60 else "raw"
    return "raw" if span <= 2 * 3600 else "1m" if span <= 3 * 86400 else "1h"


def _raw_step(conn, lo, hi):
    ts = [r[0] for r in conn.execute("SELECT ts FROM machine_samples WHERE ts>=? AND ts<=? ORDER BY ts LIMIT 200", (lo, hi))]
    diffs = sorted(b - a for a, b in zip(ts, ts[1:]) if b > a)
    return float(round(diffs[len(diffs) // 2])) if diffs else DEFAULT_STEP


def query(conn, frm, to, group="machine", step=None, name=None):
    """Series de métricas en [frm, to] (epoch s) -> {"group","step","res","series":[{"name","points":[[ts,cpu,rss],...]}]}.
    Elige la resolución según el rango (<=2 h crudo, <=3 d 1m, si no 1h) o según `step`; si esa resolución no tiene datos
    prueba la siguiente más gruesa. Si `step` es mayor que el paso nativo, re-agrega con media. `rss` de la máquina = RAM usada
    (MB). `name` filtra una sola serie de app/proyecto."""
    if group not in GROUPS:
        raise CollectorError("group debe ser uno de %s" % ", ".join(GROUPS))
    try:
        lo, hi = float(frm), float(to)
        step = float(step) if step not in (None, "", 0) else None
    except (TypeError, ValueError):
        raise CollectorError("from, to y step deben ser numéricos")
    if hi < lo:
        raise CollectorError("to debe ser >= from")
    if step is not None and step <= 0:
        raise CollectorError("step debe ser > 0")
    order = ["raw", "1m", "1h"]
    res = _pick_res(hi - lo, step)
    rows, used = [], res
    with db.tx():
        for used in order[order.index(res):]:
            rows = _load(conn, group, used, lo, hi, name)
            if rows:
                break
        native = _raw_step(conn, lo, hi) if used == "raw" else _NATIVE_STEP[used]
    out_step = native
    if step is not None and step > native:
        rows = _merge_rows(rows, step)
        out_step = step
    series = {}
    for n, ts, cpu, rss, _w in rows:
        series.setdefault(n, []).append([round(ts, 3), round(cpu or 0, 2), round(rss or 0, 1)])
    ordered = sorted(series.items(), key=lambda kv: (-sum(p[1] for p in kv[1]) / len(kv[1]), kv[0]))
    return {"group": group, "step": out_step, "res": used,
            "series": [{"name": n, "points": sorted(pts)} for n, pts in ordered]}
