#!/usr/bin/env python3
"""Agente FICTICIO para probar la app de Mac con varias máquinas, sin T3 ni datos reales.

Sirve uno de los agentes de tools/screenshots/fixture.json (host-a, host-b…) en loopback, con la forma de
docs/agent-api.md: `GET /health`, `GET /snapshot` (con `ts`, CPU y RAM que se mueven en cada petición) y
`POST /pair` (cualquier código no vacío da una credencial `cs1_…` aleatoria que solo vive en memoria; nunca se
imprime). El resto de rutas da 404 (la app sigue funcionando: `/stream` falla y la oficina nativa lo muestra).

    python3 tools/mock_agent/mock_agent.py --agent host-a --port 3791
    python3 tools/mock_agent/mock_agent.py --agent host-b --port 3792 --require-pairing

Sin `--require-pairing` no pide credencial (para verificar sin emparejar); con él, `/snapshot` da 401 hasta
canjear un código, como un agente real con api_version 2. Solo stdlib.
"""
import argparse
import json
import math
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "screenshots", "fixture.json")
MAX_BODY = 64 * 1024


def load_snapshot(agent, path=FIXTURE):
    """Snapshot del agente `agent` en el fixture (ValueError si no existe o no tiene snapshot)."""
    with open(path, encoding="utf-8") as f:
        fx = json.load(f)
    for a in fx.get("agents", []):
        if a.get("name") == agent and isinstance(a.get("snapshot"), dict):
            return a["snapshot"]
    names = ", ".join(a.get("name", "?") for a in fx.get("agents", []) if isinstance(a.get("snapshot"), dict))
    raise ValueError(f"agente desconocido en el fixture: {agent} (hay: {names})")


class MockAgent:
    """Estado del agente ficticio. Las credenciales emitidas se guardan solo como conjunto en memoria."""

    def __init__(self, snapshot, require_pairing=False, clock=time.time):
        self.base = snapshot
        self.machine_id = snapshot.get("machine_id") or "mock"
        self.require_pairing = require_pairing
        self.clock = clock
        self.started = clock()
        self._creds = set()
        self._lock = threading.Lock()
        self._tick = 0

    def authorized(self, header):
        if not self.require_pairing:
            return True
        if not header or not header.startswith("Bearer "):
            return False
        token = header[len("Bearer "):].strip()
        with self._lock:
            return any(secrets.compare_digest(token, c) for c in self._creds)

    def pair(self, body):
        code = body.get("code") if isinstance(body, dict) else None
        if not isinstance(code, str) or not code.strip():
            return 400, {"error": "falta code"}
        cred = "cs1_" + secrets.token_urlsafe(32)
        with self._lock:
            self._creds.add(cred)
        device = body.get("device_id") if isinstance(body.get("device_id"), str) and body.get("device_id") else secrets.token_hex(8)
        return 200, {"device_id": device, "credential": cred, "api_version": 2}

    def health(self):
        now = self.clock()
        return {"ok": True, "api_version": 2, "version": "mock", "machine_id": self.machine_id, "ts": now,
                "uptime": round(now - self.started, 1), "whoami": {"mock": True}}

    def snapshot(self):
        """El snapshot del fixture con hora actual y CPU/RAM oscilando (para que las minigráficas se muevan)."""
        with self._lock:
            self._tick += 1
            t = self._tick
        snap = json.loads(json.dumps(self.base))
        now = self.clock()
        snap["ts"] = now
        snap["generated"] = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))
        m = snap.setdefault("machine", {})
        phase = sum(map(ord, self.machine_id)) % 7
        cpu, ram = float(m.get("cpu_pct", 20)), float(m.get("ram_pct", 40))
        m["cpu_pct"] = round(min(100.0, max(0.0, cpu + 12 * math.sin(t / 3.0 + phase))), 1)
        m["ram_pct"] = round(min(100.0, max(0.0, ram + 4 * math.sin(t / 7.0 + phase))), 1)
        total = m.get("ram_total_mb")
        if isinstance(total, (int, float)) and total > 0:
            m["ram_avail_mb"] = int(total * (1 - m["ram_pct"] / 100.0))
        return snap


def make_handler(agent):
    class Handler(BaseHTTPRequestHandler):
        server_version = "chopshop-mock-agent"

        def log_message(self, fmt, *args):
            # Método, ruta y código; nunca cabeceras (Authorization) ni cuerpos (credenciales).
            sys.stderr.write("%s %s\n" % (agent.machine_id, fmt % args))

        def _send(self, status, obj):
            data = json.dumps(obj).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            if status == 401:
                self.send_header("WWW-Authenticate", "Bearer")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/health":
                return self._send(200, agent.health())
            if not agent.authorized(self.headers.get("Authorization")):
                return self._send(401, {"error": "sin credencial: empareja este dispositivo"})
            if path == "/snapshot":
                return self._send(200, agent.snapshot())
            return self._send(404, {"error": "no existe en el agente ficticio"})

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            try:
                n = int(self.headers.get("Content-Length") or "-1")
            except ValueError:
                n = -1
            if n < 0:
                return self._send(411, {"error": "falta Content-Length"})
            if n > MAX_BODY:
                return self._send(413, {"error": "cuerpo demasiado grande"})
            try:
                body = json.loads(self.rfile.read(n).decode("utf-8") or "{}")
            except (ValueError, UnicodeDecodeError):
                return self._send(400, {"error": "JSON no válido"})
            if not isinstance(body, dict):
                return self._send(400, {"error": "se esperaba un objeto JSON"})
            if path == "/pair":
                return self._send(*agent.pair(body))
            if not agent.authorized(self.headers.get("Authorization")):
                return self._send(401, {"error": "sin credencial: empareja este dispositivo"})
            if path in ("/answer", "/settle"):
                return self._send(200, {"ok": True, "thread_id": body.get("thread_id"), "mock": True})
            return self._send(404, {"error": "no existe en el agente ficticio"})

    return Handler


def serve(agent, host="127.0.0.1", port=0):
    """Arranca el servidor (port 0 = libre) y lo devuelve; `server.server_address[1]` es el puerto."""
    return ThreadingHTTPServer((host, port), make_handler(agent))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agent", default="host-a", help="nombre del agente en el fixture (host-a, host-b…)")
    ap.add_argument("--port", type=int, default=3791)
    ap.add_argument("--host", default="127.0.0.1", help="solo loopback por defecto")
    ap.add_argument("--fixture", default=FIXTURE)
    ap.add_argument("--require-pairing", action="store_true", help="exigir credencial (401 hasta POST /pair)")
    a = ap.parse_args(argv)
    try:
        agent = MockAgent(load_snapshot(a.agent, a.fixture), require_pairing=a.require_pairing)
    except (OSError, ValueError) as e:
        ap.error(str(e))
    srv = serve(agent, a.host, a.port)
    print(f"agente ficticio {agent.machine_id} en http://{a.host}:{srv.server_address[1]}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
