import threading
from typing import Any

from . import t3mcp

T3Error = t3mcp.T3Error

_lock = threading.Lock()
_clients: dict[Any, Any] = {}
_factory = None


def is_local(host_cfg):
    return not (host_cfg or {}).get("origin")


def _key(host_cfg, host_name):
    return (host_name, host_cfg.get("origin") or "", host_cfg.get("access") or "approval-required",
            host_cfg.get("credential_file") or "")


def _default_factory(host_cfg, host_name, timeout):
    return t3mcp.Client(origin=host_cfg.get("origin") or None,
                        access=host_cfg.get("access") or "approval-required",
                        credential_file=host_cfg.get("credential_file") or None,
                        t3_bin=host_cfg.get("t3_bin") or "t3", timeout=timeout)


def set_client_factory(fn=None):
    global _factory
    with _lock:
        _factory = fn
        _clients.clear()


def reset():
    with _lock:
        _clients.clear()


def client(host_cfg, host_name, timeout=90):
    host_cfg = host_cfg or {}
    k = _key(host_cfg, host_name)
    with _lock:
        c = _clients.get(k)
        if c is None:
            c = _clients[k] = (_factory or _default_factory)(host_cfg, host_name, timeout)
    return c


def call(host_cfg, host_name, tool, args=None, timeout=90):
    c = client(host_cfg, host_name, timeout)
    if hasattr(c, "timeout"):
        c.timeout = timeout
    try:
        return c.call(tool, args or {})
    except T3Error as e:
        raise T3Error("%s: %s" % (host_name, e))
