"""Rutas locales de Chopshop. Estado en ~/.chopshop (o general.home de ~/.config/chopshop/config.toml); fuera del repo, sin versionar."""
import os

from . import settings


def home():
    return os.path.expanduser(os.environ.get("CHOPSHOP_HOME") or settings.general("home") or "~/.chopshop")


def profiles_dir():
    return os.path.join(home(), "profiles")


def state_path():
    return os.path.join(home(), "state.json")


def events_log():
    return os.path.join(home(), "events.jsonl")


def config_path():
    return os.path.join(home(), "config.yaml")


def ensure_home():
    os.makedirs(home(), mode=0o700, exist_ok=True)
    return home()
