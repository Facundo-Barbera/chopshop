"""Transporte a T3: herramientas MCP de T3 vía el helper t3mcp.mjs (local) o `fleet t3mcp` (remoto).
Chopshop no reimplementa nada de T3: solo llama t3_thread_launch / read / organize / pending_request."""
import json
import os
import shutil
import subprocess

from . import settings


class T3Error(Exception):
    pass


def _expand(p):
    return os.path.expanduser(p)


def _parse(out):
    try:
        return json.loads(out)
    except ValueError:
        return out


def call(host_cfg, host_name, tool, args=None, timeout=90):
    args = args or {}
    tr = host_cfg.get("transport", "local")
    if tr == "local":
        env = dict(os.environ, T3MCP_ACCESS=host_cfg.get("access", "approval-required"),
                   T3_BIN=_expand(host_cfg.get("t3_bin", "~/.t3/bin/t3")))
        cmd = [host_cfg.get("node", "node"), _expand(host_cfg["helper"]), tool, "-"]
        r = subprocess.run(cmd, input=json.dumps(args), capture_output=True, text=True, env=env, timeout=timeout)
    elif tr == "fleet":
        fleet = os.environ.get("CHOPSHOP_FLEET") or settings.general("fleet_bin") or shutil.which("fleet")
        if not fleet:
            raise T3Error("el host %s usa transporte 'fleet' pero el CLI `fleet` no está en PATH aquí "
                          "(define CHOPSHOP_FLEET o cambia el transporte en ~/.config/chopshop/config.toml)" % host_name)
        cmd = [fleet, "t3mcp", host_cfg.get("fleet_host", host_name), tool, json.dumps(args)]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    else:
        raise T3Error("transporte desconocido: %s" % tr)
    out = (r.stdout or "").strip()
    if r.returncode != 0 or out.startswith("ERROR"):
        raise T3Error("%s en %s falló: %s" % (tool, host_name, (r.stderr or out).strip()[:600]))
    data = _parse(out)
    # errores de herramienta MCP llegan como content=[{type:text,text:'{"_tag":...Failure...}'}]
    if isinstance(data, list) and data and isinstance(data[0], dict) and "_tag" in str(data[0].get("text", ""))[:20]:
        raise T3Error("%s en %s: %s" % (tool, host_name, data[0]["text"][:600]))
    return data
