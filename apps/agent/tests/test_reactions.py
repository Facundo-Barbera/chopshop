import http.server
import io
import json
import os
import sys
import threading
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from test_chopshop import Env, FakeT3, Hook  # noqa: E402
from chopshop import engine, profile, reactions, state  # noqa: E402

PROFILE = """project: r
scratch: true
reactions:
  - on: task_done
    level: auto
    do: settle
  - on: task_stalled
    after: 0
    level: auto
    do: retry_once
    notify: human-sim
  - on: pending_question
    match: "push|delete"
    level: human
    notify: human-sim
  - on: pending_question
    match: "color"
    level: auto
    choice: Azul
  - on: pending_question
    match: "enfoque"
    level: bot
    notify: bot-sim
"""


class FakeR(FakeT3):
    """Cada hilo pregunta el texto de self.q[n]; el hilo sin pregunta (q None) corre sin avanzar (atascado)."""
    def __init__(self, qs):
        super().__init__(); self.q = qs; self.updated = {}; self.interrupted = []

    def __call__(self, hc, host, tool, args=None, timeout=0):
        args = args or {}
        if tool == "t3_thread_launch":
            self.calls.append((tool, args)); self.n += 1; tid = "mcp:%d" % self.n
            self.status[tid] = "waiting" if self.q[self.n - 1] else "running"
            self.txt = getattr(self, "txt", {}); self.txt[tid] = self.q[self.n - 1]
            return {"threadId": tid, "link": "L" + tid, "projectId": "P", "runId": "r", "status": "running"}
        if tool == "t3_thread_read":
            s = self.status[args["threadId"]]
            pend = 1 if s == "waiting" else 0
            if getattr(self, "ghost", False) and s == "waiting":
                s = "running"          # T3 real: el hilo con pregunta abierta sigue "running"
            return {"thread": {"status": s, "pendingRequestCount": pend, "settled": False, "pullRequests": [],
                               "itemCount": 3, "updatedAt": "T0"}, "items": [{"type": "assistant_message", "text": "listo"}]}
        if tool == "t3_pending_request" and args["action"] == "read":
            return {"requestId": "req-1", "questions": [{"id": "q1", "question": self.txt[args["threadId"]],
                                                         "options": [{"label": "Sí"}, {"label": "No"}]}]}
        if tool == "t3_thread_interrupt":
            self.interrupted.append(args["threadId"]); self.status[args["threadId"]] = "interrupted"; return {}
        return super().__call__(hc, host, tool, args, timeout)


class TestReactions(Env):
    def hook(self, name):
        srv = http.server.HTTPServer(("127.0.0.1", 0), Hook)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        f = os.path.join(self.tmp, name + ".url")
        with open(f, "w") as fh:
            fh.write("http://127.0.0.1:%d/s3cret" % srv.server_port)
        os.chmod(f, 0o600)
        with state.locked() as st:
            st["subscriptions"][name] = {"project": "r", "events": ["reaction"], "webhook_file": f}

    def run_ticks(self, bid, n=1):
        for _ in range(n):
            with redirect_stdout(io.StringIO()):
                engine.tick(bid, None, log=print)

    def test_levels(self):
        Hook.got.clear()
        self.hook("bot-sim"); self.hook("human-sim")
        self.prof("r", PROFILE)
        self.assertEqual(profile.validate(profile.load("r")), [])
        fake = FakeR(["¿Qué enfoque prefieres?", "¿Hago push a main y delete de la rama?", "¿Qué color?"])
        engine.t3.call = fake
        bid = engine.create_batch(profile.load("r"), ["a", "b", "c"], "host-a", 3, [])
        self.run_ticks(bid, 2)                       # lanza y detecta preguntas
        got = {(g["level"], g["task"]) for g in Hook.got}
        self.assertEqual(got, {("bot", "t-0001-1"), ("human", "t-0001-2")})
        tasks = {t["id"]: t for t in state.read()["batches"][bid]["tasks"]}
        self.assertEqual(tasks["t-0001-1"]["level"], "bot")
        self.assertEqual(tasks["t-0001-2"]["escalation"]["status"], "open")
        self.assertEqual(tasks["t-0001-3"]["answered"][0]["by"], "auto")           # nivel auto respondió solo
        self.assertEqual(tasks["t-0001-3"]["answered"][0]["choice"], "Azul")
        snap = engine.snapshot()
        self.assertEqual({t["id"]: t["level"] for t in snap["batches"][0]["tasks"]}["t-0001-2"], "human")
        self.assertNotIn("s3cret", json.dumps(snap))
        # el bot y el humano responden
        engine.answer("t-0001-1", "Sí", by="bot-sim")
        engine.answer("t-0001-2", "No", by="humano")
        self.run_ticks(bid, 2)
        tasks = {t["id"]: t for t in state.read()["batches"][bid]["tasks"]}
        self.assertEqual(tasks["t-0001-2"]["escalation"]["status"], "resolved")
        self.assertEqual(tasks["t-0001-2"]["escalation"]["by"], "humano")
        self.assertTrue(tasks["t-0001-1"]["bot_wait"]["done"])
        self.assertTrue(all(t["settled"] for t in tasks.values()))                  # task_done -> settle auto
        self.assertFalse(any(a.get("action") == "archive" for _, a in fake.calls))

    def test_stall_retry_once_then_escalate(self):
        Hook.got.clear()
        self.hook("human-sim")
        self.prof("r", PROFILE)
        fake = FakeR([None, None, None])
        engine.t3.call = fake
        bid = engine.create_batch(profile.load("r"), ["x"], "host-a", 2, [])
        self.run_ticks(bid, 3)                       # lanza, fija huella, detecta atasco (after: 0)
        b = state.read()["batches"][bid]
        self.assertEqual(len(b["tasks"]), 2)
        self.assertEqual(b["tasks"][0]["retried_by"], "t-0001-2")
        self.assertEqual(b["tasks"][1]["retry_of"], "t-0001-1")
        self.assertEqual(fake.interrupted, ["mcp:1"])
        self.run_ticks(bid, 4)                       # el reintento también se atasca -> escalada, sin tercer intento
        b = state.read()["batches"][bid]
        self.assertEqual(len(b["tasks"]), 2)
        self.assertEqual(b["tasks"][1]["escalation"]["reason"], "reintento agotado")
        self.assertEqual(b["tasks"][1]["level"], "auto")

    def test_no_stall_while_waiting_for_answer(self):
        Hook.got.clear()
        self.hook("human-sim")
        self.prof("r", PROFILE)
        fake = FakeR(["¿Hago push a main y delete de la rama?"]); fake.ghost = True
        engine.t3.call = fake
        bid = engine.create_batch(profile.load("r"), ["x"], "host-a", 2, [])
        self.run_ticks(bid, 6)                       # stall (after: 0) NO debe disparar con una pregunta abierta
        b = state.read()["batches"][bid]
        self.assertEqual(len(b["tasks"]), 1)
        self.assertEqual(fake.interrupted, [])
        self.assertEqual(b["tasks"][0]["escalation"]["status"], "open")

    def test_old_batches_are_not_touched(self):
        self.prof("r", PROFILE)
        fake = FakeR([None]); engine.t3.call = fake
        prof = profile.load("r")
        old = dict(prof, reactions=[])
        bid = engine.create_batch(old, ["x"], "host-a", 2, [])   # lote creado sin reglas
        self.assertFalse(state.read()["batches"][bid].get("rx"))
        self.run_ticks(bid, 6)
        b = state.read()["batches"][bid]
        self.assertEqual(len(b["tasks"]), 1)
        self.assertEqual(fake.interrupted, [])


if __name__ == "__main__":
    unittest.main()
