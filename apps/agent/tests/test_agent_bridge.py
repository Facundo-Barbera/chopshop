"""Puente motor -> bus: `engine.tick` corre en el hilo `engine` del agente con el bus inyectado; lo que emite aparece en la
tabla `events` y en `GET /events` sin reiniciar. También `question.answered` (CLI y POST /answer) e `import_legacy`
periódico. T3 simulado (fábrica de clientes falsos), perfil y estado en un CHOPSHOP_HOME temporal; puertos efímeros."""
import json
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop import engine, events as legacy_events, home, profile, state, t3  # noqa: E402
from chopshop.agent import envelope, events, service  # noqa: E402
from test_agent_server import ServerBase  # noqa: E402
from test_chopshop import TEST_CONFIG, FakeT3, use_fake  # noqa: E402


def wait_for(pred, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.02)
    return pred()


class Bridge(ServerBase):
    def setUp(self):
        super().setUp()
        old = os.environ.get("CHOPSHOP_CONFIG")
        os.environ["CHOPSHOP_CONFIG"] = os.path.join(self.tmp, "config.toml")
        self.addCleanup(lambda: os.environ.__setitem__("CHOPSHOP_CONFIG", old) if old is not None
                        else os.environ.pop("CHOPSHOP_CONFIG", None))
        with open(os.environ["CHOPSHOP_CONFIG"], "w") as f:
            f.write(TEST_CONFIG)
        os.makedirs(home.profiles_dir())
        with open(os.path.join(home.profiles_dir(), "p.yaml"), "w") as f:
            f.write("project: p\nscratch: true\n")
        self.fake = FakeT3()
        use_fake(self.fake)
        self.addCleanup(t3.set_client_factory, None)

    def batch(self):
        prof = profile.load("p")
        return engine.create_batch(prof, ["Primera tarea"], "host-a", 2, [])

    def envs(self, **q):
        st, body, _ = self.get("/events?limit=1000")
        self.assertEqual(st, 200)
        return body["events"]

    def of(self, legacy=None, typ=None):
        return [e for e in self.envs() if (legacy is None or e["event"] == legacy) and (typ is None or e["type"] == typ)]


class TestEngineThread(Bridge):
    def test_tick_events_reach_bus_without_restart(self):
        self.start(background=True, t3_enabled=False, engine_interval=0.05, import_legacy=True, legacy_interval=0.05)
        self.assertIn("chopshop-engine", {t.name for t in self.svc.threads})
        time.sleep(0.15)
        self.assertEqual(self.of("pending_question"), [])            # sin lotes, el motor no hace nada
        bid = self.batch()                                             # aparece un lote con el agente ya corriendo
        self.assertTrue(wait_for(lambda: self.of("pending_question")))
        q = self.of("pending_question")[0]
        envelope.validate(q)
        self.assertEqual((q["type"], q["needs"], q["project"], q["subject"]["id"]), ("question.opened", "human", "p", "mcp:1"))
        self.assertEqual((q["body"]["batch"], q["body"]["request_id"], q["body"]["options"]), (bid, "req-1", ["A", "B"]))
        att = self.of(typ="task.state")[0]
        self.assertEqual((att["body"]["phase"], att["body"]["attention"], att["seq"]), ("waiting", "ask", q["seq"] - 1))
        # en la tabla events también, con las columnas del sobre
        row = self.conn.execute("SELECT type, needs, subject_id FROM events WHERE seq=?", (q["seq"],)).fetchone()
        self.assertEqual(tuple(row), ("question.opened", "human", "mcp:1"))
        # la misma línea va a events.jsonl, pero la importación periódica no la duplica
        with open(home.events_log()) as f:
            self.assertIn("pending_question", f.read())
        time.sleep(0.3)
        self.assertEqual(len(self.of("pending_question")), 1)
        # respuesta por la CLI (sin agente de por medio): llega por events.jsonl + import periódico
        tid = state.read()["batches"][bid]["tasks"][0]["id"]
        engine.answer(tid, "A", by="bot-p")
        self.assertTrue(wait_for(lambda: self.of(typ="question.answered")))
        a = self.of(typ="question.answered")[0]
        envelope.validate(a)
        self.assertEqual((a["needs"], a["body"]["choice"], a["body"]["by"], a["body"]["request_id"], a["subject"]["id"]),
                         (None, "A", "bot-p", "req-1", "mcp:1"))
        # el hilo termina: task.state done + batch.done
        self.assertTrue(wait_for(lambda: self.of("batch_done")))
        done = self.of("task_done")[0]
        self.assertEqual((done["type"], done["body"]["phase"], done["body"]["result"]), ("task.state", "done", "listo"))
        self.assertEqual(self.of("batch_done")[0]["type"], "batch.done")
        evs = self.envs()
        self.assertEqual([e["seq"] for e in evs], sorted(e["seq"] for e in evs))
        self.assertEqual([e["id"] for e in evs], sorted(e["id"] for e in evs))
        self.assertEqual(len({e["id"] for e in evs}), len(evs))
        n = len(evs)
        time.sleep(0.2)
        self.assertEqual(len(self.envs()), n)                          # lotes terminados: el motor deja de emitir

    def test_engine_disabled(self):
        self.start(background=True, t3_enabled=False, engine_enabled=False)
        self.assertNotIn("chopshop-engine", {t.name for t in self.svc.threads})

    def test_engine_once_without_state_does_nothing(self):
        calls = []
        self.start(svc_kw={"engine_tick": lambda *a, **k: calls.append(k)})
        self.assertIsNone(self.svc.engine_once())
        self.batch()
        self.svc.engine_once()
        self.assertEqual(len(calls), 1)
        self.assertIs(calls[0]["emit_fn"], self.svc.engine_emit)


class TestEmitFn(Bridge):
    def test_default_emit_fn_is_events_emit(self):
        """Fuera del agente el motor sigue igual: events.jsonl y suscripciones de state.json."""
        self.batch()
        for _ in range(2):                                              # 1.ª pasada lanza, 2.ª ve la pregunta
            engine.tick(None, None, log=lambda m: None)
        with open(home.events_log()) as f:
            names = [json.loads(l)["event"] for l in f]
        self.assertIn("pending_question", names)

    def test_injected_emit_fn_replaces_default(self):
        got = []

        def fn(st, event, project, body, adhoc_files=None, log=True, only=None):
            got.append((event, project, only))
            return True, False, {}
        self.batch()
        for _ in range(2):
            engine.tick(None, None, log=lambda m: None, emit_fn=fn)
        self.assertEqual(got, [("pending_question", "p", None)])
        self.assertFalse(os.path.exists(home.events_log()))             # nada pasó por el emit por defecto
        self.assertIsNone(legacy_events._current.get())                # el contexto se restaura

    def test_reaction_bot_goes_through_emit_fn_and_sets_needs(self):
        with open(os.path.join(home.profiles_dir(), "p.yaml"), "w") as f:
            f.write("project: p\nscratch: true\nreactions:\n  - on: pending_question\n    level: bot\n    notify: bot-p\n")
        with state.locked() as st:
            st["subscriptions"]["bot-p"] = {"webhook_file": os.path.join(self.tmp, "no-existe.url"), "project": "*", "events": []}
        self.start()
        got = []
        bridge = service.engine_emitter(self.conn, self.cfg)

        def fn(st, event, project, body, adhoc_files=None, log=True, only=None):
            got.append((event, only))
            return bridge(st, event, project, body, adhoc_files, log=log, only=only)
        self.batch()
        for _ in range(2):
            engine.tick(None, None, log=lambda m: None, emit_fn=fn)
        self.assertEqual(got, [("reaction", ["bot-p"]), ("pending_question", None)])
        r, q = self.of("reaction")[0], self.of("pending_question")[0]
        self.assertEqual((r["type"], r["body"]["level"], r["body"]["on"]), ("reaction.applied", "bot", "pending_question"))
        self.assertEqual((q["needs"], q["body"]["level"], q["body"]["notify"]), ("bot", "bot", "bot-p"))
        self.assertEqual(self.of(typ="task.state")[-1]["body"]["attention"], "bot")

    def test_bridge_dedups_with_import(self):
        self.start()
        emit_fn = service.engine_emitter(self.conn, self.cfg)
        res = emit_fn(state.read(), "batch_done", "p", {"batch": "b-0009", "host": "host-a", "tasks": {}})
        self.assertEqual(res[1], False)                                 # sin destinatarios en state.json
        self.assertEqual(events.import_legacy(self.conn, home.events_log(), "host-a"), {"imported": 0, "skipped": 1})
        self.assertEqual(len(self.of("batch_done")), 1)


class TestEventsRoute(Bridge):
    def test_envelopes_ids_seq_and_cause_depth(self):
        self.start()
        root = events.emit_envelope(self.conn, self.cfg, "github.issue.opened", "p",
                                    {"repo": "o/r", "number": 7, "action": "opened", "title": "t", "url": None})
        child = events.emit_envelope(self.conn, self.cfg, "automation.ran", "p",
                                     {"automation": "triage", "trigger": "github.issue.opened", "exit": 0,
                                      "duration_ms": 5, "error": None}, cause=root)
        events.emit_envelope(self.conn, self.cfg, "triage.result", "p", {"ok": True}, cause=child)
        evs = self.envs()
        for e in evs:
            envelope.validate(e)
        self.assertEqual([e["type"] for e in evs[-3:]], ["github.issue.opened", "automation.ran", "triage.result"])
        self.assertEqual([e["cause"] for e in evs[-3:]], [{"id": None, "depth": 0}, {"id": root["id"], "depth": 1},
                                                          {"id": child["id"], "depth": 2}])
        self.assertEqual([e["seq"] for e in evs], list(range(evs[0]["seq"], evs[0]["seq"] + len(evs))))
        self.assertEqual([e["id"] for e in evs], sorted({e["id"] for e in evs}))
        snap = self.get("/snapshot")[1]["events"]
        self.assertEqual(snap[0]["id"], evs[-1]["id"])                  # /snapshot.events: sobres, el más nuevo primero


class TestAnswerRoute(Bridge):
    def test_post_answer_emits_question_answered(self):
        self.start()
        self.add_thread("t-1", project="proyecto-demo", title="Hilo uno")
        self.svc.emit("pending_question", "proyecto-demo", {"thread_id": "t-1", "request_id": "req-0001", "questions": []})
        self.t3calls.pending["t-1"] = ["req-0001"]
        st, body, _ = self.post("/answer", {"thread_id": "t-1", "choice": "1", "by": "bot-demo"})
        self.assertEqual(st, 200)
        a = self.of(typ="question.answered")
        self.assertEqual(len(a), 1)
        envelope.validate(a[0])
        self.assertEqual((a[0]["project"], a[0]["needs"], a[0]["subject"]["id"]), ("proyecto-demo", None, "t-1"))
        self.assertEqual((a[0]["body"]["choice"], a[0]["body"]["by"], a[0]["body"]["request_id"]), ("Sí", "bot-demo", "req-0001"))
        self.assertIsInstance(a[0]["body"]["latency_s"], int)
        # sin `by`: el login de quien responde (origen local = "human")
        self.t3calls.pending["t-1"] = ["req-0002"]
        self.post("/answer", {"thread_id": "t-1", "choice": "2"})
        self.assertEqual(self.of(typ="question.answered")[-1]["body"]["by"], "human")

    def test_failed_answer_emits_nothing(self):
        self.start()
        self.assertEqual(self.post("/answer", {"thread_id": "t-1", "choice": "1"})[0], 400)
        self.assertEqual(self.of(typ="question.answered"), [])


if __name__ == "__main__":
    unittest.main()
