"""Servidor MCP (stdio) y comando de liberación de chopshop-agent.

MCP: JSON-RPC 2.0, un mensaje JSON por línea, `protocolVersion` 2024-11-05. Métodos: `initialize`,
`notifications/initialized`, `ping`, `tools/list`, `tools/call`. Habla con la API HTTP del agente (`client.AgentClient`).

Funciones para el CLI (`cli.py` las invoca con `argv` sin el nombre del comando):

    main_mcp(argv=None, stdin=None, stdout=None, client=None, cwd=None, environ=None) -> int
        `chopshop mcp [--url URL] [--token-file F] [--cwd DIR]`: sirve MCP por stdin/stdout hasta EOF. Devuelve 0.
    main_release(argv=None, client=None, environ=None, stderr=None) -> int
        `chopshop release [--worktree DIR] [--thread ID] [--lease ID] [--url URL] [--token-file F]` (para `runOnSettle`
        de T3). SIEMPRE devuelve 0: si el agente está caído o falla algo, avisa por stderr y sigue.

Tools (los errores del agente salen como `isError: true` en el resultado, nunca como excepción):
    chopshop_request_test_server{project?, worktree?, wait_seconds?}   POST /leases/request (kind=test_server)
    chopshop_request_port{project?, worktree?}                         POST /leases/request (kind=port)
    chopshop_release{lease_id? | worktree?}                            POST /leases/release
    chopshop_status{}                                                  GET /leases

project/worktree se infieren de `cwd`: `<worktrees_root>/<proyecto>/<wt>` (T3) o `<projects_root>/<proyecto>`; el hilo
sale de la variable `T3CODE_THREAD_ID`. Stdout es solo para el protocolo; los avisos van a stderr.
"""
import argparse
import json
import os
import sys

from . import __version__
from .client import AgentClient, AgentError, load_cfg

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "chopshop"
THREAD_ENV = "T3CODE_THREAD_ID"

# códigos JSON-RPC
PARSE_ERROR, INVALID_REQUEST, METHOD_NOT_FOUND, INVALID_PARAMS, INTERNAL_ERROR = -32700, -32600, -32601, -32602, -32603

TOOLS = [
    {
        "name": "chopshop_request_test_server",
        "description": ("Pide al agente de Chopshop un servidor de pruebas (dev server) para este proyecto/worktree, con puerto "
                        "asignado y límites de CPU/RAM. Si no hay capacidad queda en cola. NO levantes dev servers por tu "
                        "cuenta: usa esta tool y libera con chopshop_release al terminar. project y worktree se infieren del "
                        "directorio actual."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {"type": "string", "description": "Nombre del proyecto (por defecto, inferido del cwd)."},
                "worktree": {"type": "string", "description": "Ruta del worktree (por defecto, inferida del cwd)."},
                "wait_seconds": {"type": "number", "minimum": 0,
                                 "description": "Segundos máximos a esperar si queda en cola (0 = no esperar)."},
            },
        },
    },
    {
        "name": "chopshop_request_port",
        "description": "Pide un puerto reservado y estable para este worktree (sin levantar ningún proceso).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {"type": "string", "description": "Nombre del proyecto (por defecto, inferido del cwd)."},
                "worktree": {"type": "string", "description": "Ruta del worktree (por defecto, inferida del cwd)."},
            },
        },
    },
    {
        "name": "chopshop_release",
        "description": ("Libera el servidor de pruebas o puerto: por lease_id, o por worktree (por defecto el del directorio "
                        "actual). Llámala al terminar de probar."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "lease_id": {"type": "string", "description": "Id del lease (p. ej. l-0001)."},
                "worktree": {"type": "string", "description": "Ruta del worktree cuyos leases se liberan."},
            },
        },
    },
    {
        "name": "chopshop_status",
        "description": "Estado de servidores de prueba y puertos de esta máquina: activos, en cola y capacidad.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


class ToolError(Exception):
    """Entrada inválida de una tool: se devuelve como resultado con isError."""


# ---------------------------------------------------------------- inferencia de proyecto/worktree

def _real(p):
    return os.path.realpath(os.path.expanduser(p))


def _under(path, root):
    """Partes de `path` relativas a `root` si está dentro (o igual), si no None."""
    rel = os.path.relpath(path, root)
    if rel == os.pardir or rel.startswith(os.pardir + os.sep) or os.path.isabs(rel):
        return None
    return [] if rel == os.curdir else rel.split(os.sep)


def infer_context(cwd, cfg):
    """{"project", "worktree"} a partir de `cwd`; claves None si no se reconoce.

    Orden: proyectos de `[agent.projects.*]` (root / worktrees), `worktrees_root/<proyecto>/<wt>` y `projects_root/<proyecto>`."""
    here = _real(cwd)
    for name, p in sorted((cfg.get("projects") or {}).items()):
        if not isinstance(p, dict):
            continue
        wts = p.get("worktrees")
        parts = _under(here, _real(wts)) if wts else None
        if parts:
            return {"project": name, "worktree": os.path.join(_real(wts), parts[0])}
        root = p.get("root")
        if root and _under(here, _real(root)) is not None:
            return {"project": name, "worktree": _real(root)}
    wroot = cfg.get("worktrees_root")
    parts = _under(here, _real(wroot)) if wroot else None
    if parts and len(parts) >= 2:
        return {"project": parts[0], "worktree": os.path.join(_real(wroot), parts[0], parts[1])}
    proot = cfg.get("projects_root")
    parts = _under(here, _real(proot)) if proot else None
    if parts:
        return {"project": parts[0], "worktree": os.path.join(_real(proot), parts[0])}
    return {"project": None, "worktree": None}


# ---------------------------------------------------------------- tools

def _text(args, key):
    v = args.get(key)
    if v is None or v == "":
        return None
    if not isinstance(v, str):
        raise ToolError("%s debe ser texto" % key)
    return v


class Tools:
    """Implementación de las tools sobre un cliente (`get`/`post`) del agente."""

    def __init__(self, client, cfg, cwd=None, environ=None):
        self.client, self.cfg = client, cfg
        self.cwd = cwd or os.getcwd()
        self.environ = os.environ if environ is None else environ

    def _context(self, args):
        """project/worktree explícitos o inferidos del cwd; un worktree relativo cuelga del cwd."""
        guess = infer_context(self.cwd, self.cfg)
        project, worktree = _text(args, "project"), _text(args, "worktree")
        if worktree:
            worktree = _real(os.path.join(self.cwd, os.path.expanduser(worktree)))
            if not project:
                project = infer_context(worktree, self.cfg)["project"]
        else:
            worktree = guess["worktree"] if not project or project == guess["project"] else None
        if not project:
            project = guess["project"]
        if not project:
            raise ToolError("no pude inferir el proyecto desde %s: pásalo en el argumento project" % self.cwd)
        return project, worktree

    def _lease_request(self, args, kind):
        project, worktree = self._context(args)
        body = {"project": project, "kind": kind}
        if worktree:
            body["worktree"] = worktree
        thread = (self.environ.get(THREAD_ENV) or "").strip()
        if thread:
            body["thread_id"] = thread
        timeout = None
        if kind == "test_server":
            wait = args.get("wait_seconds")
            if wait is not None:
                if isinstance(wait, bool) or not isinstance(wait, (int, float)) or wait < 0:
                    raise ToolError("wait_seconds debe ser un número >= 0")
                body["wait_seconds"] = wait
                timeout = self.client.timeout + wait
        return self.client.post("/leases/request", body, timeout=timeout)

    def chopshop_request_test_server(self, args):
        return self._lease_request(args, "test_server")

    def chopshop_request_port(self, args):
        return self._lease_request(args, "port")

    def chopshop_release(self, args):
        lease_id, worktree = _text(args, "lease_id"), _text(args, "worktree")
        if lease_id:
            body = {"lease_id": lease_id}
        else:
            if not worktree:
                worktree = infer_context(self.cwd, self.cfg)["worktree"]
                if not worktree:
                    raise ToolError("indica lease_id o worktree (no pude inferirlo desde %s)" % self.cwd)
            body = {"worktree": _real(os.path.join(self.cwd, os.path.expanduser(worktree)))}
        return self.client.post("/leases/release", body)

    def chopshop_status(self, args):
        return self.client.get("/leases")

    def call(self, name, args):
        """Ejecuta la tool y devuelve el `result` MCP; errores del agente o de entrada -> isError."""
        try:
            data = getattr(self, name)(args)
            return {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False, indent=2)}], "isError": False}
        except ToolError as e:
            msg = str(e)
        except AgentError as e:
            msg = "chopshop-agent: %s" % e
        return {"content": [{"type": "text", "text": msg}], "isError": True}


# ---------------------------------------------------------------- JSON-RPC

class McpServer:
    def __init__(self, tools, log=None):
        self.tools = tools
        self.log = log or (lambda msg: None)

    @staticmethod
    def _error(rid, code, message):
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}

    def handle(self, msg):
        """Respuesta (dict) a un mensaje ya decodificado, o None si es una notificación."""
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
            return self._error(msg.get("id") if isinstance(msg, dict) else None, INVALID_REQUEST, "petición JSON-RPC inválida")
        method, rid = msg["method"], msg.get("id")
        notification = "id" not in msg
        params = msg.get("params") or {}
        if not isinstance(params, dict):
            return None if notification else self._error(rid, INVALID_PARAMS, "params debe ser un objeto")
        try:
            result = self._dispatch(method, params)
        except _RpcError as e:
            return None if notification else self._error(rid, e.code, e.message)
        except Exception as e:  # el servidor no debe caerse por una tool
            self.log("error interno en %s: %s" % (method, e))
            return None if notification else self._error(rid, INTERNAL_ERROR, "error interno: %s" % e)
        return None if notification else {"jsonrpc": "2.0", "id": rid, "result": result}

    def _dispatch(self, method, params):
        if method == "initialize":
            return {"protocolVersion": PROTOCOL_VERSION, "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER_NAME, "version": __version__}}
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": TOOLS}
        if method == "tools/call":
            name, args = params.get("name"), params.get("arguments") or {}
            if name not in {t["name"] for t in TOOLS}:
                raise _RpcError(INVALID_PARAMS, "tool desconocida: %s" % name)
            if not isinstance(args, dict):
                raise _RpcError(INVALID_PARAMS, "arguments debe ser un objeto")
            return self.tools.call(name, args)
        if method.startswith("notifications/"):  # initialized, cancelled... : sin respuesta
            return {}
        raise _RpcError(METHOD_NOT_FOUND, "método no soportado: %s" % method)

    def handle_line(self, line):
        """Línea de texto -> línea de respuesta (str) o None."""
        line = line.strip()
        if not line:
            return None
        try:
            msg = json.loads(line)
        except ValueError:
            return json.dumps(self._error(None, PARSE_ERROR, "JSON inválido"))
        if isinstance(msg, list):  # lote JSON-RPC
            out = [r for r in (self.handle(m) for m in msg) if r is not None]
            return json.dumps(out, ensure_ascii=False) if out else None
        resp = self.handle(msg)
        return json.dumps(resp, ensure_ascii=False) if resp is not None else None

    def serve(self, stdin, stdout):
        for line in stdin:
            out = self.handle_line(line)
            if out is not None:
                stdout.write(out + "\n")
                stdout.flush()


class _RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


# ---------------------------------------------------------------- CLI

class _Parser(argparse.ArgumentParser):
    def error(self, message):  # nunca salir con exit 2 (runOnSettle debe terminar en 0)
        raise ValueError(message)


def _build_client(a, cfg):
    return AgentClient(url=a.url, token_file=a.token_file, cfg=cfg)


def main_mcp(argv=None, stdin=None, stdout=None, client=None, cwd=None, environ=None):
    p = _Parser(prog="chopshop mcp", description="Servidor MCP (stdio) de Chopshop")
    p.add_argument("--url", help="URL del agente (por defecto CHOPSHOP_AGENT_URL o 127.0.0.1:<puerto>)")
    p.add_argument("--token-file", help="archivo con el bearer del agente (por defecto agent.token_file)")
    p.add_argument("--cwd", help="directorio desde el que inferir proyecto/worktree (por defecto el actual)")
    try:
        a = p.parse_args(argv or [])
    except ValueError as e:
        print("error: %s" % e, file=sys.stderr)
        return 2
    cfg = load_cfg()
    client = client or _build_client(a, cfg)
    tools = Tools(client, cfg, cwd=a.cwd or cwd, environ=environ)
    server = McpServer(tools, log=lambda m: print("chopshop mcp: %s" % m, file=sys.stderr))
    try:
        server.serve(stdin or sys.stdin, stdout or sys.stdout)
    except KeyboardInterrupt:
        pass
    return 0


def main_release(argv=None, client=None, environ=None, stderr=None):
    """Libera los leases de un worktree/hilo (`runOnSettle`). Devuelve siempre 0."""
    err = stderr or sys.stderr

    def warn(msg):
        print("chopshop release: %s" % msg, file=err)

    try:
        p = _Parser(prog="chopshop release", description="Libera los servidores de prueba de un worktree o hilo")
        p.add_argument("--worktree", help="ruta del worktree ('.' = el actual)")
        p.add_argument("--thread", help="id del hilo de T3 (p. ej. $T3CODE_THREAD_ID)")
        p.add_argument("--lease", help="id de un lease concreto")
        p.add_argument("--url")
        p.add_argument("--token-file")
        a = p.parse_args(argv or [])
        env = os.environ if environ is None else environ
        thread = (a.thread or "").strip()
        bodies = []
        if a.lease:
            bodies.append({"lease_id": a.lease})
        if a.worktree or not (a.lease or thread):
            bodies.append({"worktree": _real(a.worktree or ".")})
        if thread:
            bodies.append({"thread_id": thread})
        client = client or _build_client(a, load_cfg())
        released = []
        # una llamada por selector: no depende de cómo combine el agente varios filtros
        for body in bodies:
            try:
                res = client.post("/leases/release", body)
                released += res.get("released") or []
            except AgentError as e:
                warn("el agente no respondió (%s); no se liberó nada con %s" % (e, "/".join(sorted(body))))
        if released:
            print("chopshop: %d lease(s) liberado(s)" % len(released))
    except Exception as e:  # SIEMPRE exit 0
        warn("aviso: %s" % e)
    return 0
