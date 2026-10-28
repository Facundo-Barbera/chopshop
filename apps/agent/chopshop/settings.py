"""Configuración local de Chopshop: ~/.config/chopshop/config.toml (NUNCA en el repo; el repo solo trae config.example.toml).

Orden de precedencia (de menor a mayor): valores por defecto genéricos < config.toml < variables de entorno.
- Archivo: `CHOPSHOP_CONFIG` o `$XDG_CONFIG_HOME/chopshop/config.toml` (por defecto `~/.config/chopshop/config.toml`).
- Entorno: `CHOPSHOP_<SECCION>__<CLAVE>[__<SUBCLAVE>]` (doble guion bajo separa niveles; el guion `-` de un nombre se escribe `_`).
  Ejemplos: `CHOPSHOP_AGENT__PORT=3791`, `CHOPSHOP_GENERAL__OVERFLOW_HOST=host-b`, `CHOPSHOP_HOSTS__HOST_B__CAP=6`.
  Valores: entero/decimal/true/false, `[json, ...]` para listas, o texto.
- Atajos históricos: `CHOPSHOP_HOME` (directorio de estado), `CHOPSHOP_FLEET` (binario fleet).
Las URLs de webhook nunca van aquí: solo rutas a archivos que las contienen."""
import copy
import json
import os
import re

from . import minitoml

DEFAULTS = {
    "general": {
        "home": "~/.chopshop",         # estado local: perfiles, lotes, eventos (CHOPSHOP_HOME tiene prioridad)
        "default_host": "local",       # host de T3 por defecto de los perfiles
        "overflow_host": "",           # host donde se desbordan lotes grandes (vacío = no hay)
        "fleet_bin": "",               # ruta del CLI `fleet` si algún host usa transporte fleet (vacío = buscar en PATH)
    },
    "hosts": {
        "local": {"transport": "local", "cap": 2, "purpose": "dev", "node": "node",
                  "t3_bin": "~/.t3/bin/t3", "helper": "~/.local/share/fleet/t3mcp.mjs", "access": "approval-required"},
    },
    "app": {                           # la app de macOS
        "agent_url": "",               # URL del chopshop-agent remoto (p. ej. http://<ip-tailscale>:3790)
        "token_file": "",              # archivo con el bearer del agente (nunca el token en sí)
        "refresh_seconds": 3,          # segundos entre sondeos de /snapshot (1-300)
        "agents": {},                  # varias máquinas: [app.agents.<nombre>] con url y token_file
    },
    "agent": {
        "machine_id": "",              # vacío = hostname
        "bind": "127.0.0.1",           # IP de escucha: "auto" = IP de Tailscale, o una IP concreta (nunca 0.0.0.0 / ::)
        "port": 3790,
        "auth": "tailscale+token",     # "tailscale+token" | "token" | "none-local" (ver docs/agent-service.md)
        "trust_local": True,           # aceptar el origen local (MCP/CLI) sin identidad ni bearer
        "local_listener": True,        # si bind no es loopback, escuchar además en 127.0.0.1:<port> para MCP/CLI locales
        "tailscale_bin": "tailscale",  # CLI de Tailscale (whois / ip)
        "owner_login": "",             # login Tailscale completo con permiso total (vacío = solo origen local)
        "allowed_logins": [],          # logins con acceso de solo lectura
        "allow_request_cmd": False,    # permitir que POST /leases/request traiga su propio `cmd` (por defecto solo el de la config)
        "t3_enabled": True,            # vigilar T3 (false = máquina solo sensor)
        "import_legacy": True,         # al arrancar, importar <home>/events.jsonl del motor viejo si existe
        "service": {"read_write_paths": []},   # rutas extra de escritura para la unidad systemd (ProtectSystem=strict)
        "token_file": "~/.chopshop/agent/token",
        "db_path": "~/.chopshop/agent/agent.db",
        "sample_interval": 10,
        "t3_poll_interval": 5,
        "t3": {"node": "node", "helper": "~/.local/share/fleet/t3mcp.mjs", "t3_bin": "~/.local/bin/t3", "access": "full-access"},
        "projects_root": "~/projects",
        "worktrees_root": "~/.t3/worktrees",
        "projects": {},
        "ports": {"range": [41000, 45999], "per_worktree": 10},
        "capacity": {"max_servers": 4, "max_per_project": 1, "max_cpu_pct": 700, "min_ram_avail_mb": 6000,
                     "default_idle_seconds": 900, "queue_ttl_seconds": 1800},
        "sweep": {"interval": 60, "agent_scopes": "report", "grace_seconds": 120, "agent_cgroup": ""},
        "webhook_files": {},           # nombre -> ruta a un archivo (0600) con la URL
        "retention": {"raw_hours": 24, "m1_days": 30, "h1_days": 365, "events_days": 90},
    },
}

_cache = {}


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
    """Aplica CHOPSHOP_<A>__<B>... sobre cfg (en sitio)."""
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
    """Configuración efectiva (dict). Se cachea por (ruta, mtime, entorno CHOPSHOP_*)."""
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
        if fcfg.get("hosts"):          # [hosts.*] del archivo reemplazan al host genérico `local` (no se mezclan)
            cfg["hosts"] = copy.deepcopy(fcfg["hosts"])
    apply_env(cfg)
    _cache["key"], _cache["cfg"] = key, copy.deepcopy(cfg)
    return cfg



def section(name):
    return load().get(name, {})


def general(key):
    return load()["general"].get(key)
