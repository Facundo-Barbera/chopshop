"""Monitor de máquinas: CPU≈load1/cpus, RAM, load y disco.
- Host con transporte `local`: se lee del propio sistema (stdlib; macOS vía sysctl/vm_stat, Linux vía /proc), sin red.
- Host remoto (`fleet`): se toma de `fleet status` y se deja en ~/.chopshop/metrics-remote.json. Lo recoge `watch`
  (proceso aparte con red); la app de escritorio solo lee ese archivo y nunca abre conexiones."""
import json
import os
import re
import shutil
import subprocess
import time

from . import home, profile, settings

STALE_AFTER = 120  # s: un dato remoto más viejo se marca obsoleto


def _remote_path():
    return os.path.join(home.home(), "metrics-remote.json")


def _sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _mem_mb():
    """(total_mb, disponible_mb) o (None, None)."""
    try:
        if os.path.exists("/proc/meminfo"):
            kv = {}
            with open("/proc/meminfo") as f:
                for l in f:
                    p = l.split()
                    if len(p) >= 2:
                        kv[p[0].rstrip(":")] = int(p[1])
            return kv["MemTotal"] // 1024, kv.get("MemAvailable", kv.get("MemFree", 0)) // 1024
        total = int((_sh("sysctl", "-n", "hw.memsize").strip() or 0)) // (1024 * 1024)
        vm = _sh("vm_stat")
        m = re.search(r"page size of (\d+) bytes", vm)
        ps = int(m.group(1)) if m else 16384
        pages = {k.strip(): int(v.strip().rstrip(".")) for k, v in re.findall(r"^(Pages [^:]+):\s+(\d+)\.?", vm, re.M)}
        avail = sum(pages.get(k, 0) for k in ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"))
        return (total, avail * ps // (1024 * 1024)) if total else (None, None)
    except (OSError, ValueError, KeyError):
        return None, None


def _fmt_gb(b):
    g = b / 1024 ** 3
    return ("%.0fG" % g) if g >= 10 else ("%.1fG" % g)


def local():
    la = os.getloadavg()
    total, avail = _mem_mb()
    du = shutil.disk_usage("/")
    return {"ok": True, "os": os.uname().sysname, "cpus": os.cpu_count() or 1,
            "load": [round(x, 2) for x in la], "ram_mb_total": total, "ram_mb_avail": avail,
            "disk": "%s/%s" % (_fmt_gb(du.used), _fmt_gb(du.total)), "disk_pct": round(100 * du.used / du.total),
            "ts": time.time()}


def parse_fleet_status(text):
    """Parsea la salida de `fleet status` -> {host: {...}}."""
    out, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"==\s*(\S+)\s*\(([^)]*)\)", line)
        if m:
            cur = out.setdefault(m.group(1), {"ok": True, "role": m.group(2).split(",")[0].strip(), "ts": time.time()})
            continue
        if cur is None:
            continue
        for k, v in re.findall(r"(\w+)=(\S+(?: \S+)*?)(?=\s+\w+=|$)", line):
            if k == "load":
                parts = v.split()
                cur["load"] = [float(x) for x in parts[:3]] if parts else None
            elif k == "cpus":
                cur["cpus"] = int(v)
            elif k in ("ram_mb_total", "ram_mb_avail"):
                cur[k] = int(v)
            elif k == "disk_used":
                m2 = re.match(r"(\S+)\s*\((\d+)%\)", v)
                if m2:
                    cur["disk"], cur["disk_pct"] = m2.group(1), int(m2.group(2))
            elif k in ("macOS", "host"):
                cur["os"] = "Darwin" if k == "macOS" else cur.get("os", "Linux")
            elif k == "t3_version":
                cur["t3"] = v
    for v in out.values():
        v.setdefault("os", "Linux")
    return out


def collect_remote(fleet_bin=None, timeout=40):
    """Ejecuta `fleet status` y guarda el resultado. Requiere red: llamarlo solo desde `watch` o a mano."""
    fleet_bin = fleet_bin or os.environ.get("CHOPSHOP_FLEET") or settings.general("fleet_bin") or shutil.which("fleet")
    if not fleet_bin:
        return None
    try:
        r = subprocess.run([fleet_bin, "status"], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    data = parse_fleet_status(r.stdout)
    if data:
        tmp = _remote_path() + ".tmp"
        os.makedirs(home.home(), mode=0o700, exist_ok=True)
        with open(tmp, "w") as f:
            json.dump({"ts": time.time(), "hosts": data}, f)
        os.replace(tmp, _remote_path())
    return data


def _read_remote():
    try:
        with open(_remote_path()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"ts": 0, "hosts": {}}


def read(now=None):
    """Métricas de todos los hosts configurados. Sin red."""
    now = now or time.time()
    rem = _read_remote()
    out = {}
    for name, cfg in profile.hosts().items():
        if cfg.get("transport", "local") == "local":
            d = local()
        else:
            d = dict(rem["hosts"].get(cfg.get("fleet_host", name)) or {})
            if not d:
                d = {"ok": False, "reason": "sin datos (ejecuta `chopshop metrics --collect` o `watch` donde exista el CLI fleet)"}
            else:
                d["age"] = round(now - d.get("ts", rem.get("ts", 0)))
                d["stale"] = d["age"] > STALE_AFTER
        d["transport"] = cfg.get("transport", "local")
        d["purpose"] = cfg.get("purpose")
        if d.get("ok") and d.get("load") and d.get("cpus"):
            d["cpu_pct"] = round(100 * d["load"][0] / d["cpus"])
        if d.get("ok") and d.get("ram_mb_total") and d.get("ram_mb_avail") is not None:
            d["ram_pct"] = round(100 * (1 - d["ram_mb_avail"] / d["ram_mb_total"]))
        out[name] = d
    return {"ts": now, "hosts": out}
