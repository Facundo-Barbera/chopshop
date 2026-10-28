#!/usr/bin/env python3
"""Receptores SIMULADOS para probar las reacciones en local (sin bots reales, sin red externa).
  bot   -> recibe el webhook de nivel `bot`, decide con una heurística y responde con `chopshop answer --by bot-sim`
  human -> recibe el webhook de nivel `human` y solo lo registra (una persona/test lo resuelve después)
Escucha en 127.0.0.1 (puertos libres); escribe las URLs en archivos 0600 dentro de <home>/sim/ y los eventos en *.jsonl.
Uso: sim_receivers.py [--home DIR]   (se detiene con SIGTERM/Ctrl-C; el PID lo imprime al arrancar)"""
import http.server
import json
import os
import subprocess
import sys
import threading
import time

HOME = os.environ.get("CHOPSHOP_HOME") or os.path.expanduser("~/.chopshop")
BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "chopshop")
SIM = os.path.join(HOME, "sim")


def decide(options, summary):
    """Heurística del 'bot' simulado: prefiere lo simple/mínimo; si no hay pista, la primera opción."""
    for o in options or []:
        if any(k in str(o).lower() for k in ("simple", "minimal", "sin caché", "no cache", "recommended")):
            return str(o)
    return str((options or ["Sí"])[0])


def log(name, obj):
    with open(os.path.join(SIM, name + ".jsonl"), "a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def make(kind):
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
            log(kind, {"ts": time.strftime("%H:%M:%S"), "recv": {k: body.get(k) for k in ("level", "task", "summary", "options", "reason")}})
            if kind == "bot" and body.get("level") == "bot" and body.get("task"):
                threading.Thread(target=self.respond, args=(body,), daemon=True).start()

        def respond(self, body):
            time.sleep(1)
            choice = decide(body.get("options"), body.get("summary"))
            r = subprocess.run([BIN, "answer", body["task"], choice, "--by", "bot-sim"],
                               capture_output=True, text=True, env=dict(os.environ, CHOPSHOP_HOME=HOME))
            log("bot", {"ts": time.strftime("%H:%M:%S"), "answered": body["task"], "choice": choice, "rc": r.returncode,
                        "out": (r.stdout + r.stderr).strip()[:200]})

        def log_message(self, *a):
            pass
    return H


def main():
    os.makedirs(SIM, mode=0o700, exist_ok=True)
    servers = []
    for kind in ("bot", "human"):
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make(kind))
        p = os.path.join(SIM, kind + ".url")
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write("http://127.0.0.1:%d/%s" % (srv.server_port, kind))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
    print("receptores simulados activos, pid %d" % os.getpid(), flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
