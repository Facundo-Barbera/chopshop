import json
import os
import secrets

from .. import settings


class ConfigError(Exception):
    pass


def load():
    cfg = settings.load()
    mcp = dict(cfg.get("mcp") or {})
    for k in ("token_file", "credentials_file", "state_dir"):
        mcp[k] = os.path.expanduser(mcp[k])
    mcp["path"] = "/" + str(mcp.get("path") or "/mcp").strip("/")
    mcp["port"] = int(mcp.get("port") or settings.DEFAULTS["mcp"]["port"])
    return cfg, mcp


def _private_dir(path):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, mode=0o700, exist_ok=True)


def write_private(path, text):
    _private_dir(path)
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def check_private(path):
    mode = os.stat(path).st_mode
    if mode & 0o077:
        raise ConfigError(f"{path} tiene permisos abiertos ({mode & 0o777:o}): chmod 600 {path}")


def ensure_token(path):
    created = False
    if not os.path.exists(path):
        _private_dir(path)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            fd = None
        if fd is not None:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(secrets.token_urlsafe(32) + "\n")
            created = True
    check_private(path)
    with open(path, encoding="utf-8") as f:
        token = f.read().strip()
    if len(token) < 24:
        raise ConfigError(f"{path} está vacío o es demasiado corto (mínimo 24 caracteres)")
    return token, created


def read_json_private(path, default):
    if not os.path.exists(path):
        return default
    check_private(path)
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise ConfigError(f"{path} ilegible ({type(e).__name__})")
    return data if isinstance(data, type(default)) else default


def write_json_private(path, data):
    write_private(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


def credentials(mcp):
    return read_json_private(mcp["credentials_file"], {})


def save_credential(mcp, url, credential):
    creds = credentials(mcp)
    creds[url] = credential
    write_json_private(mcp["credentials_file"], creds)
