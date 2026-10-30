import os
import re
import shutil
import subprocess
import time

from . import profile, t3

REMOTE_REASON = "sin métricas: consulta el agente de esa máquina"


def _sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _mem_mb():
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


def read(now=None):
    now = now or time.time()
    out = {}
    for name, cfg in profile.hosts().items():
        loc = t3.is_local(cfg)
        d = local() if loc else {"ok": False, "reason": REMOTE_REASON}
        d["transport"] = "local" if loc else "remote"
        d["purpose"] = cfg.get("purpose")
        if d.get("ok") and d.get("load") and d.get("cpus"):
            d["cpu_pct"] = round(100 * d["load"][0] / d["cpus"])
        if d.get("ok") and d.get("ram_mb_total") and d.get("ram_mb_avail") is not None:
            d["ram_pct"] = round(100 * (1 - d["ram_mb_avail"] / d["ram_mb_total"]))
        out[name] = d
    return {"ts": now, "hosts": out}
