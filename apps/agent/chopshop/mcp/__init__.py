import argparse
import logging
import signal
import socket
import sys

from .. import settings


def _ensure(err):
    from . import config
    cfg, mcp = config.load()
    token, created = config.ensure_token(mcp["token_file"])
    print("token {}: {}".format("generado" if created else "en", mcp["token_file"]), file=err)
    return cfg, mcp, token


def _terminate(*_):
    raise KeyboardInterrupt


def cmd_serve(a, out, err):
    from . import fleet as fleet_mod
    from . import hooks as hooks_mod
    from . import server
    from . import tools as tools_mod
    logging.basicConfig(level=logging.INFO, stream=err, format="%(levelname)s %(name)s: %(message)s")
    cfg, mcp, token = _ensure(err)
    port = a.port or mcp["port"]
    fleet = fleet_mod.Fleet()
    hooks = hooks_mod.Hooks(fleet, mcp)
    app = server.McpApp(tools_mod.Tools(fleet, hooks), token, mcp["path"], mcp.get("allowed_hosts") or [])
    srv = server.make(port, app)
    hooks.start()
    names = ", ".join(f"{n} ({u})" for n, u in fleet_mod.specs(cfg, mcp)) or "ninguna"
    print(f"chopshop-mcp en http://{server.BIND}:{port}{mcp['path']}; máquinas: {names}", file=err)
    signal.signal(signal.SIGTERM, _terminate)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        hooks.stop()
        srv.server_close()
    return 0


def cmd_token(a, out, err):
    _ensure(out)
    return 0


def cmd_pair(a, out, err):
    from ..agent import client as agent_client
    from . import config
    from . import fleet as fleet_mod
    cfg, mcp = config.load()
    url = dict(fleet_mod.specs(cfg, mcp)).get(a.machine)
    if not url:
        print(f"máquina desconocida: {a.machine} (ver [app.agents.<nombre>])", file=err)
        return 2
    host = socket.gethostname()
    c = agent_client.AgentClient(url=url, token_file="")
    try:
        res = c.post("/pair", {"code": a.code, "device_name": f"chopshop-mcp@{host}",
                               "device_id": f"chopshop-mcp-{host}"})
    except agent_client.AgentError as e:
        print(f"error: {e}", file=err)
        return 1
    cred = res.get("credential")
    if not cred:
        print("error: el agente no devolvió credencial", file=err)
        return 1
    config.save_credential(mcp, url, cred)
    print("emparejado con {}; credencial guardada en {}".format(a.machine, mcp["credentials_file"]), file=out)
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="chopshop mcp", description="Servidor MCP multi-máquina (Streamable HTTP, 127.0.0.1)")
    sp = p.add_subparsers(dest="cmd", required=True)
    x = sp.add_parser("serve", help="arranca el servidor MCP")
    x.add_argument("--port", type=int, help=f"puerto (por defecto [mcp] port = {settings.DEFAULTS['mcp']['port']})")
    x.set_defaults(f=cmd_serve)
    x = sp.add_parser("token", help="genera el bearer si falta y muestra solo su ruta")
    x.set_defaults(f=cmd_token)
    x = sp.add_parser("pair", help="empareja el servidor MCP con el agente de otra máquina (código de `chopshop pair create`)")
    x.add_argument("machine")
    x.add_argument("code")
    x.set_defaults(f=cmd_pair)
    return p


def main(argv, stdout=None, stderr=None):
    from .config import ConfigError
    out, err = stdout or sys.stdout, stderr or sys.stderr
    a = build_parser().parse_args(argv)
    try:
        return a.f(a, out, err) or 0
    except (ConfigError, settings.SettingsError) as e:
        print(f"error: {e}", file=err)
        return 1
