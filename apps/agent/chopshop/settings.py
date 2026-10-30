import copy
import json
import os
import re
from typing import Any

from . import minitoml

DEFAULTS = {
    "general": {
        "home": "~/.chopshop",
        "default_host": "local",
        "overflow_host": "",
    },
    "hosts": {
        "local": {"cap": 2, "purpose": "dev", "t3_bin": "t3", "access": "approval-required"},
    },
    "app": {
        "agent_url": "",
        "refresh_seconds": 3,
        "agents": {},
    },
    "agent": {
        "machine_id": "",
        "bind": "127.0.0.1",
        "port": 3790,
        "auth": "tailscale+token",
        "trust_local": True,
        "local_listener": True,
        "tailscale_bin": "tailscale",
        "owner_login": "",
        "allowed_logins": [],
        "allowed_hosts": [],
        "t3_enabled": True,
        "import_legacy": True,
        "legacy_interval": 5,
        "engine_enabled": True,
        "engine_interval": 5,
        "service": {"read_write_paths": []},
        "token_file": "~/.chopshop/agent/token",
        "db_path": "~/.chopshop/agent/agent.db",
        "sample_interval": 10,
        "t3_poll_interval": 5,
        "t3": {"origin": "", "t3_bin": "t3", "access": "full-access", "credential_file": ""},
        "projects_root": "~/projects",
        "worktrees_root": "~/.t3/worktrees",
        "projects": {},
        "webhook_files": {},
        "automations": {"enabled": True, "interval": 2},
        "office": {"enabled": True, "interval": 2},

        "roles": {"enabled": False, "interval": 5, "max_wakes_per_hour": 6},
        "github": {"enabled": False, "repos": [], "interval_s": 45, "gh_bin": "gh", "ci": True, "actions": True},
        "forge": {"enabled": "auto", "interval_s": 60},
        "retention": {"raw_hours": 24, "m1_days": 30, "h1_days": 365, "events_days": 90},
    },
}

_cache: dict[Any, Any] = {}


class SettingsError(Exception):
    pass


def path():
    p = os.environ.get("CHOPSHOP_CONFIG")
    if p:
        return os.path.expanduser(p)
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "chopshop", "config.toml")


def merge(a, b):
    out = copy.deepcopy(a)
    for k, v in (b or {}).items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else copy.deepcopy(v)
    return out


def _norm(k):
    return k.upper().replace("-", "_")


def _scalar(v):
    s = v.strip()
    if s.lower() in ("true", "false"):
        return s.lower() == "true"
    if re.fullmatch(r"[+-]?\d+", s):
        return int(s)
    try:
        return float(s) if re.fullmatch(r"[+-]?\d+\.\d+", s) else _list_or_text(s)
    except ValueError:
        return s


def _list_or_text(s):
    if s.startswith("["):
        try:
            return json.loads(s)
        except ValueError:
            pass
    return s


def apply_env(cfg, environ=None):
    for name, val in (environ if environ is not None else os.environ).items():
        if not name.startswith("CHOPSHOP_") or "__" not in name:
            continue
        parts = name[len("CHOPSHOP_"):].split("__")
        d = cfg
        for p in parts[:-1]:
            hit = next((k for k in d if isinstance(d[k], dict) and _norm(k) == p.upper()), None)
            if hit is None:
                hit = p.lower()
                d[hit] = {}
            d = d[hit]
        last = next((k for k in d if _norm(k) == parts[-1].upper()), parts[-1].lower())
        d[last] = _scalar(val)
    return cfg


def load(force=False):
    p = path()
    try:
        mt = os.stat(p).st_mtime
    except OSError:
        mt = None
    envsig = tuple(sorted((k, v) for k, v in os.environ.items() if k.startswith("CHOPSHOP_")))
    key = (p, mt, envsig)
    if not force and _cache.get("key") == key:
        return copy.deepcopy(_cache["cfg"])
    cfg = copy.deepcopy(DEFAULTS)
    if mt is not None:
        try:
            fcfg = minitoml.load(p)
        except (minitoml.TomlError, OSError) as e:
            raise SettingsError("%s: %s" % (p, e))
        cfg = merge(cfg, fcfg)
        if fcfg.get("hosts"):
            cfg["hosts"] = copy.deepcopy(fcfg["hosts"])
    apply_env(cfg)
    _cache["key"], _cache["cfg"] = key, copy.deepcopy(cfg)
    return cfg


def section(name):
    return load().get(name, {})


def general(key):
    return load()["general"].get(key)
