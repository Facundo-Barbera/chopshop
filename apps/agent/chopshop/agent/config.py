"""Configuración del agente: sección [agent] de ~/.config/chopshop/config.toml (ver config.example.toml) + entorno
(`CHOPSHOP_AGENT__PORT=3791`, ...). Valores por defecto genéricos en `settings.DEFAULTS["agent"]`.
Las URLs de webhook NUNCA van aquí: solo rutas a archivos que contienen la URL."""
import os
import socket

from .. import home, settings

DEFAULTS = settings.DEFAULTS["agent"]


def path():
    return settings.path()


def _merge(a, b):
    return settings.merge(a, b)


def load(overrides=None):
    cfg = settings.load()["agent"]
    if overrides:
        cfg = _merge(cfg, overrides)
    cfg["machine_id"] = cfg.get("machine_id") or socket.gethostname()
    for k in ("db_path", "token_file", "projects_root", "worktrees_root"):
        cfg[k] = os.path.expanduser(cfg[k])
    return cfg


def agent_dir():
    d = os.path.join(home.home(), "agent")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d
