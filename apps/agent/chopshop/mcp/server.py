import hmac
import json
import logging
import socket
import socketserver
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ..agent import __version__
from .fleet import ToolError

log = logging.getLogger("chopshop.mcp")

BIND = "127.0.0.1"
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
MAX_BODY = 512 * 1024
CONN_TIMEOUT = 30
LOCAL_HOSTS = ("127.0.0.1", "localhost", "[::1]")


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


class McpApp:
    def __init__(self, tools, token, path, allowed_hosts=()):
        self.tools, self.token, self.path = tools, token, path
        self.allowed_hosts = {h.lower() for h in allowed_hosts if h}

    def host_ok(self, host):
        if not host:
            return False
        name = host.lower()
        if name.startswith("["):
            name = name.split("]")[0] + "]"
        else:
            name = name.rsplit(":", 1)[0] if name.count(":") == 1 else name
        return name in LOCAL_HOSTS or name in self.allowed_hosts

    def auth_ok(self, header):
        if not header or not header.startswith("Bearer "):
            return False
        return hmac.compare_digest(header[7:].strip().encode("utf-8"), self.token.encode("utf-8"))

    def handle(self, msg):
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
            return _error(msg.get("id") if isinstance(msg, dict) else None, -32600, "petición JSON-RPC inválida")
        mid, method, params = msg.get("id"), msg["method"], msg.get("params") or {}
        if "id" not in msg:
            return None
        try:
            return {"jsonrpc": "2.0", "id": mid, "result": self.dispatch(method, params)}
        except RpcError as e:
            return _error(mid, e.code, e.message)

    def dispatch(self, method, params):
        if method == "initialize":
            asked = params.get("protocolVersion")
            return {"protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "chopshop-mcp", "version": __version__},
                    "instructions": "Orquesta los agentes de Chopshop de todas las máquinas: empieza por machines_list."}
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": self.tools.list()}
        if method == "tools/call":
            return self.call_tool(params.get("name"), params.get("arguments") or {})
        raise RpcError(-32601, f"método no soportado: {method}")

    def call_tool(self, name, args):
        if not isinstance(args, dict):
            raise RpcError(-32602, "arguments debe ser un objeto")
        try:
            res = self.tools.call(name, args)
            log.info("herramienta %s -> ok", name)
            return {"content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, default=str)}],
                    "structuredContent": res, "isError": False}
        except ToolError as e:
            log.info("herramienta %s -> error", name)
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
        except TypeError as e:
            log.info("herramienta %s -> argumentos inválidos", name)
            return {"content": [{"type": "text", "text": f"argumentos inválidos: {e}"}], "isError": True}
        except Exception:
            log.exception("herramienta %s -> fallo interno", name)
            return {"content": [{"type": "text", "text": "error interno del servidor MCP"}], "isError": True}


def _error(mid, code, message):
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}


class Handler(BaseHTTPRequestHandler):
    server_version = "chopshop-mcp"
    sys_version = ""
    timeout = CONN_TIMEOUT
    protocol_version = "HTTP/1.1"

    def log_request(self, code="-", size="-"):
        pass

    def log_message(self, fmt, *args):
        log.debug("http.server: error de protocolo")

    def _reply(self, status, obj=None, headers=None):
        data = b"" if obj is None else json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if obj is not None:
            self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if data:
            self.wfile.write(data)
        return status

    def _gate(self):
        app = self.server.app
        if self.path.split("?", 1)[0].rstrip("/") != app.path:
            return self._reply(404, {"error": "ruta desconocida"})
        if not app.host_ok(self.headers.get("Host")):
            return self._reply(403, {"error": "Host no permitido"})
        if self.headers.get("Origin"):
            return self._reply(403, {"error": "Origin no permitido"})
        if not app.auth_ok(self.headers.get("Authorization")):
            return self._reply(401, {"error": "bearer requerido"}, {"WWW-Authenticate": 'Bearer realm="chopshop-mcp"'})
        return None

    def _drain(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 0:
            self.rfile.read(min(n, MAX_BODY))

    def do_GET(self):
        self._drain()
        self.close_connection = True
        self._gate() or self._reply(405, {"error": "sin flujo SSE: usa POST"}, {"Allow": "POST"})

    def do_DELETE(self):
        self._drain()
        self.close_connection = True
        self._gate() or self._reply(405, {"error": "sesiones sin estado"}, {"Allow": "POST"})

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or -1)
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            self.close_connection = True
            self._reply(413 if n > MAX_BODY else 411, {"error": f"Content-Length requerido (máx. {MAX_BODY})"})
            return
        raw = self.rfile.read(n) if n else b""
        if self._gate():
            return
        try:
            msg = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._reply(400, _error(None, -32700, "JSON inválido"))
            return
        app = self.server.app
        headers = {}
        if isinstance(msg, list):
            out = [r for r in (app.handle(m) for m in msg) if r is not None]
            if not out:
                self._reply(202)
                return
            self._reply(200, out)
            return
        if isinstance(msg, dict) and msg.get("method") == "initialize":
            headers["Mcp-Session-Id"] = uuid.uuid4().hex
        res = app.handle(msg)
        if res is None:
            self._reply(202)
            return
        self._reply(200, res, headers)


class McpHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port, app):
        self.app = app
        super().__init__((BIND, port), Handler)

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name, self.server_port = host, port


def make(port, app):
    srv = McpHTTPServer(port, app)
    srv.socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    return srv
