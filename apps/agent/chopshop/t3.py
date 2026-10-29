"""Fachada del motor hacia T3: llama herramientas MCP de T3 con el cliente nativo `t3mcp.Client`.
Chopshop no reimplementa nada de T3: solo llama t3_thread_launch / read / organize / pending_request.

Config de host (`[hosts.<nombre>]`):
- `origin`: URL base del MCP de T3 (p. ej. http://100.64.0.10:3773). Vacío = host local: el origen se lee del
  archivo runtime de T3 (~/.t3/userdata/server-runtime.json).
- `access`: nivel de acceso pedido a T3 ("approval-required" por defecto).
- `credential_file`: caché de la credencial (vacío = <CHOPSHOP_HOME>/t3-credential.json, 0600).
- `t3_bin`: CLI de T3 con el que se emite el pairing local del flujo OAuth+PKCE.
Se mantiene un `t3mcp.Client` por host (reutiliza credencial y sesión MCP); `reset()` vacía el caché."""
import threading

from . import t3mcp

T3Error = t3mcp.T3Error

_lock = threading.Lock()
_clients = {}
_factory = None


def is_local(host_cfg):
    """Un host es local si no declara `origin` (el cliente lee el origen del runtime de T3)."""
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
    """Para tests: `fn(host_cfg, host_name, timeout) -> objeto con .call(tool, args)`. None = cliente real."""
    global _factory
    with _lock:
        _factory = fn
        _clients.clear()


def reset():
    """Olvida los clientes cacheados (y con ello sus sesiones MCP)."""
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
