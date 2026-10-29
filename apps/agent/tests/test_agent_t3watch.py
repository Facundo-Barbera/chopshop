"""Pruebas de chopshop.agent.t3watch con un cliente MCP falso (sin T3, sin red) y de chopshop.answers.
Fixtures: tests/fixtures/t3/."""
import copy
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import answers, t3mcp  # noqa: E402
from chopshop.agent import config as agent_config, db, envelope, events, t3watch  # noqa: E402

FIX = os.path.join(os.path.dirname(__file__), "fixtures", "t3")


def fixture(name):
    with open(os.path.join(FIX, name + ".json"), encoding="utf-8") as f:
        return json.load(f)


class FakeServer:
    """Cliente MCP falso: `call(tool, args)` contesta según el estado en memoria (como `t3mcp.Client`)."""

    def __init__(self):
        self.projects = fixture("project_list")
        self.threads = {"p-0001": fixture("thread_list")["threads"], "p-0002": []}
        self.reads = {"t-run": fixture("thread_read")}
        self.pending = {}            # thread_id -> {request_id: respuesta de t3_pending_request read}
        self.down = False
        self.fail = {}               # tool -> mensaje: esa herramienta falla con T3Error
        self.calls = []              # (tool, args)
        self.pages = None            # si se define: lista de páginas para t3_thread_list de p-0001

    def set(self, tid, **fields):
        for ths in self.threads.values():
            for t in ths:
                if t["threadId"] == tid:
                    t.update(fields)
        if tid in self.reads:
            self.reads[tid]["thread"].update({k: v for k, v in fields.items() if k in self.reads[tid]["thread"]})

    def add_pending(self, tid, rid="req-0001", approvals=0):
        q = fixture("pending_read")
        q.update(threadId=tid, requestId=rid)
        self.pending.setdefault(tid, {})[rid] = q
        self.reads[tid]["thread"]["pendingRequestCount"] = len(self.pending[tid]) + approvals

    def count(self, tool):
        return sum(1 for t, _ in self.calls if t == tool)

    def call(self, tool, args=None):
        args = copy.deepcopy(args or {})
        self.calls.append((tool, args))
        if self.down:
            raise t3mcp.T3Error("error de red con T3 (/mcp): Connection refused")
        if tool in self.fail:
            raise t3mcp.T3Error("%s falló: %s" % (tool, self.fail[tool]))
        out = getattr(self, "_" + tool)(args)
        if isinstance(out, list) and out and "_tag" in out[0].get("text", "")[:20]:   # como hace t3mcp.Client
            raise t3mcp.T3Error("%s: %s" % (tool, out[0]["text"]))
        return copy.deepcopy(out)

    def _t3_project_list(self, a):
        return self.projects

    def _t3_thread_list(self, a):
        if a["projectId"] == "p-0001" and self.pages:
            i = a.get("cursor", 0)
            return {"projectId": "p-0001", "threads": self.pages[i], "nextCursor": i + 1 if i + 1 < len(self.pages) else None}
        return {"projectId": a["projectId"], "threads": self.threads.get(a["projectId"], []), "nextCursor": None}

    def _t3_thread_read(self, a):
        if a["threadId"] not in self.reads:
            return [{"type": "text", "text": '{"_tag":"OrchestratorMcpFailure","code":"not_found","message":"no existe"}'}]
        return self.reads[a["threadId"]]

    def _t3_pending_request(self, a):
        tid, act = a["threadId"], a["action"]
        if act == "list":
            return {"requestIds": list(self.pending.get(tid, {}))}
        if act == "read":
            return self.pending[tid][a["requestId"]]
        if act == "respond":
            self.pending[tid].pop(a["requestId"])
            return {"ok": True}
        raise AssertionError(act)

    def _t3_thread_organize(self, a):
        self.set(a["threadId"], settled=True)
        return {"ok": True}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cfg = copy.deepcopy(agent_config.DEFAULTS)
        self.conn = db.connect(os.path.join(self.tmp.name, "agent.db"))
        self.srv = FakeServer()
        self.now = [1_800_000_000.0]
        self.t3 = t3watch.T3(self.cfg, client=self.srv, clock=lambda: self.now[0])
        self.events = []

    def emit(self, event, project, body=None):
        self.events.append((event, project, body or {}))
        return len(self.events)

    def poll(self, advance=60):
        self.now[0] += advance
        return t3watch.poll(self.conn, self.cfg, self.t3, self.emit)

    def names(self):
        return [e[0] for e in self.events]

    def row(self, tid):
        r = self.conn.execute("SELECT * FROM t3_threads WHERE thread_id=?", (tid,)).fetchone()
        return dict(r) if r else None


class TestCall(Base):
    def test_delega_en_el_cliente(self):
        self.assertEqual(self.t3.call("t3_project_list", {"limit": 5}), self.srv.projects)
        self.assertEqual(self.srv.calls, [("t3_project_list", {"limit": 5})])
        self.t3.call("t3_project_list")
        self.assertEqual(self.srv.calls[-1], ("t3_project_list", {}))

    def test_errores(self):
        self.srv.down = True
        with self.assertRaisesRegex(t3watch.T3Error, "red"):
            self.t3.call("t3_project_list")
        self.srv.down = False
        with self.assertRaisesRegex(t3watch.T3Error, "not_found"):
            self.t3.read("t-nada")

    def test_error_inesperado_del_cliente_es_t3error(self):
        class Roto:
            def call(self, tool, args):
                raise ConnectionResetError("se cortó")

        with self.assertRaisesRegex(t3watch.T3Error, "t3_project_list: se cortó"):
            t3watch.T3(self.cfg, client=Roto()).call("t3_project_list")

    def test_t3error_es_el_del_cliente_nativo(self):
        self.assertIs(t3watch.T3Error, t3mcp.T3Error)
        self.assertTrue(issubclass(t3watch.AnswerError, t3mcp.T3Error))

    def test_cliente_por_defecto_desde_config(self):
        self.cfg["t3"].update(origin="http://100.64.0.10:3773", t3_bin="~/bin/t3", access="full-access",
                              credential_file="/tmp/no-existe/cred.json")
        c = t3watch.T3(self.cfg).client
        self.assertIsInstance(c, t3mcp.Client)
        self.assertEqual(c.origin, "http://100.64.0.10:3773")
        self.assertEqual(c.access, "full-access")
        self.assertEqual(c.t3_bin, os.path.expanduser("~/bin/t3"))
        self.assertEqual(c.credential_file, "/tmp/no-existe/cred.json")
        d = t3watch.T3(dict(self.cfg, t3={})).client
        self.assertEqual((d.access, d.t3_bin, d.credential_file), ("approval-required", "t3", None))

    def test_organize_archivar_lo_frena_el_cliente_nativo(self):
        hits = []

        def http(*a):
            hits.append(a)
            raise AssertionError("no debe llegar a la red")

        t3 = t3watch.T3(self.cfg, client=t3mcp.Client(origin="http://127.0.0.1:9", http=http))
        for action in ("archive", "unarchive", "pin", None):
            with self.assertRaises(t3watch.T3Error):
                t3.call("t3_thread_organize", {"threadId": "t-run", "action": action})
        self.assertEqual(hits, [])

    def test_projects_omite_borrados(self):
        self.assertEqual([p["title"] for p in self.t3.projects()], ["proyecto-demo"])


class TestPoll(Base):
    def test_linea_base_silenciosa_y_upsert(self):
        r = self.poll()
        self.assertEqual(r["threads"], 2)
        self.assertEqual(self.events, [])
        run = self.row("t-run")
        self.assertEqual((run["project"], run["t3_project_id"], run["status"], run["settled"]), ("proyecto-demo", "p-0001", "running", 0))
        self.assertEqual(run["worktree"], "/srv/worktrees/proyecto-demo/wt-demo")
        self.assertEqual(run["branch"], "wt-demo")
        self.assertEqual(db.jload(run["pending"]), [])
        self.assertGreater(run["last_seen"], 0)
        self.assertEqual(run["first_seen"], run["last_seen"])
        self.assertEqual(self.row("t-old")["settled"], 1)
        self.assertIsNone(self.row("t-old")["worktree"])

    def test_solo_lee_hilos_activos(self):
        self.poll()
        reads = [a["threadId"] for t, a in self.srv.calls if t == "t3_thread_read"]
        self.assertEqual(reads, ["t-run"])
        self.srv.calls.clear()
        self.poll()
        self.assertEqual([a["threadId"] for t, a in self.srv.calls if t == "t3_thread_read"], ["t-run"])

    def test_max_reads(self):
        self.srv.threads["p-0001"] = [dict(copy.deepcopy(self.srv.threads["p-0001"][0]), threadId="t-run%d" % i) for i in range(5)]
        for i in range(5):
            self.srv.reads["t-run%d" % i] = copy.deepcopy(self.srv.reads["t-run"])
        t3watch.poll(self.conn, self.cfg, self.t3, self.emit, max_reads=2)
        self.assertEqual(self.srv.count("t3_thread_read"), 2)

    def test_started_done_settled(self):
        self.poll()
        self.srv.threads["p-0001"].insert(0, dict(copy.deepcopy(self.srv.threads["p-0001"][0]), threadId="t-new", title="Nuevo"))
        self.srv.reads["t-new"] = copy.deepcopy(self.srv.reads["t-run"])
        self.srv.reads["t-new"]["thread"].update(threadId="t-new", branch="wt-nuevo")
        self.srv.set("t-new", createdAt="2030-01-01T00:00:00.000Z")
        self.poll()
        self.assertEqual(self.names(), ["thread_started"])
        ev = self.events[0]
        self.assertEqual((ev[1], ev[2]["thread_id"], ev[2]["title"], ev[2]["branch"]), ("proyecto-demo", "t-new", "Nuevo", "wt-nuevo"))
        self.poll()
        self.assertEqual(self.names(), ["thread_started"])        # sin transición, sin eventos

        self.srv.set("t-run", status="completed", updatedAt="2026-10-28T11:00:00.000Z")
        self.poll()
        self.assertEqual(self.names()[1:], ["thread_done"])
        done = self.events[-1][2]
        self.assertEqual((done["thread_id"], done["result"]), ("t-run", "Listo: demo terminada."))
        self.assertEqual(done["worktree"], "/srv/worktrees/proyecto-demo/wt-demo")
        self.assertEqual(self.row("t-run")["status"], "completed")

        self.srv.set("t-run", settled=True, updatedAt="2026-10-28T11:05:00.000Z")
        self.poll()
        self.assertEqual(self.names()[2:], ["thread_settled"])
        self.poll()
        self.assertEqual(len(self.events), 3)

    def test_failed(self):
        self.poll()
        self.srv.set("t-run", status="failed", updatedAt="2026-10-28T11:00:00.000Z")
        self.poll()
        self.assertEqual(self.names(), ["thread_failed"])
        self.assertEqual(self.events[0][2]["status"], "failed")

    def test_hilo_nuevo_ya_terminado(self):
        self.poll()
        self.srv.threads["p-0001"].insert(0, dict(copy.deepcopy(self.srv.threads["p-0001"][1]), threadId="t-rapido",
                                                  createdAt="2030-01-01T00:00:00.000Z", settled=False, settledAt=None))
        self.srv.reads["t-rapido"] = copy.deepcopy(self.srv.reads["t-run"])
        self.srv.reads["t-rapido"]["thread"].update(threadId="t-rapido", status="completed")
        self.poll()
        self.assertEqual(self.names(), ["thread_started", "thread_done"])

    def test_nuevo_antiguo_no_emite(self):
        self.poll()
        self.srv.threads["p-0001"].append(dict(copy.deepcopy(self.srv.threads["p-0001"][1]), threadId="t-viejo-2"))
        self.poll()
        self.assertEqual(self.events, [])
        self.assertIsNotNone(self.row("t-viejo-2"))

    def test_reactivado(self):
        self.poll()
        self.srv.set("t-run", status="completed", updatedAt="2026-10-28T11:00:00.000Z")
        self.poll()
        self.srv.set("t-run", status="running", updatedAt="2026-10-28T12:00:00.000Z")
        self.poll()
        self.assertEqual(self.names(), ["thread_done", "thread_started"])

    def test_pending_question(self):
        self.poll()
        self.srv.add_pending("t-run")
        self.poll()
        self.assertEqual(self.names(), ["pending_question"])
        ev = self.events[0]
        self.assertEqual(ev[1], "proyecto-demo")
        self.assertEqual(ev[2]["request_id"], "req-0001")
        self.assertEqual(ev[2]["thread_id"], "t-run")
        self.assertEqual(ev[2]["questions"][0]["question"], "¿Qué rama uso?")
        stored = db.jload(self.row("t-run")["pending"])
        self.assertEqual(stored[0]["request_id"], "req-0001")
        self.poll()
        self.assertEqual(self.names(), ["pending_question"])        # no se repite
        reads = [a for t, a in self.srv.calls if t == "t3_pending_request" and a["action"] == "read"]
        self.assertEqual(len(reads), 1)                              # la pregunta ya conocida no se vuelve a leer
        self.srv.pending["t-run"].clear()
        self.srv.reads["t-run"]["thread"]["pendingRequestCount"] = 0
        self.poll()
        self.assertEqual(db.jload(self.row("t-run")["pending"]), [])
        self.assertEqual(self.names(), ["pending_question"])

    def test_pending_en_linea_base_si_avisa(self):
        self.srv.add_pending("t-run")
        self.poll()
        self.assertEqual(self.names(), ["pending_question"])

    def test_pending_approval(self):
        self.poll()
        self.srv.add_pending("t-run", approvals=1)
        self.poll()
        self.assertEqual(self.names(), ["pending_question", "pending_approval"])
        self.poll()
        self.assertEqual(len(self.events), 2)

    def test_paginacion(self):
        base = self.srv.threads["p-0001"]
        self.srv.pages = [[base[0]], [base[1]]]
        self.assertEqual(self.poll()["threads"], 2)
        self.srv.calls.clear()
        self.poll()     # la 1ª página ya es conocida y estable: no hace falta pedir la 2ª
        lists = [a for t, a in self.srv.calls if t == "t3_thread_list" and a["projectId"] == "p-0001"]
        self.assertEqual(len(lists), 1)
        self.assertNotIn("cursor", lists[0])

    def test_activo_fuera_del_listado_se_lee_directo(self):
        self.poll()
        self.srv.threads["p-0001"] = [self.srv.threads["p-0001"][1]]
        self.srv.set("t-run", status="completed")
        self.srv.reads["t-run"]["thread"]["status"] = "completed"
        self.poll()
        self.assertEqual(self.names(), ["thread_done"])

    def test_error_en_un_hilo_no_frena_el_resto(self):
        self.poll()
        self.srv.set("t-run", updatedAt="2026-10-28T11:00:00.000Z")
        del self.srv.reads["t-run"]
        r = self.poll()
        self.assertTrue(r["errors"])
        self.assertTrue(r["reachable"])

    def test_emit_que_falla_reintenta(self):
        self.poll()
        self.srv.set("t-run", status="failed", updatedAt="2026-10-28T11:00:00.000Z")
        calls = []

        def bad(event, project, body):
            calls.append(event)
            raise RuntimeError("fallo de entrega")

        self.now[0] += 60
        r = t3watch.poll(self.conn, self.cfg, self.t3, bad)
        self.assertEqual(calls, ["thread_failed"])
        self.assertTrue(r["errors"])
        self.assertEqual(self.row("t-run")["status"], "running")    # no avanzó: se reintenta
        self.poll()
        self.assertEqual(self.names(), ["thread_failed"])


class TestEnvelopes(Base):
    """t3watch emitiendo por el bus real: cada transición queda como sobre con sujeto, needs y severidad."""

    def setUp(self):
        super().setUp()
        self.cfg["machine_id"] = "host-a"
        self.addCleanup(events.flush)
        self.level = (None, None)

    def bus_poll(self, advance=60):
        self.now[0] += advance
        return t3watch.poll(self.conn, self.cfg, self.t3, lambda e, pr, b: events.emit(self.conn, self.cfg, e, pr, b),
                            level_fn=lambda project, text: self.level)

    def envs(self, after=0):
        out = events.list_after(self.conn, after)
        for e in out:
            envelope.validate(e)
        return out

    def test_task_state_question_approval(self):
        self.bus_poll()
        self.srv.set("t-run", status="failed", updatedAt="2026-10-28T11:00:00.000Z")
        self.bus_poll()
        e = self.envs()[-1]
        self.assertEqual((e["type"], e["severity"], e["needs"], e["body"]["phase"], e["body"]["legacy"]),
                         ("task.state", "error", None, "failed", "thread_failed"))
        self.assertEqual((e["subject"]["kind"], e["subject"]["id"], e["project"]), ("task", "t-run", "proyecto-demo"))
        self.srv.set("t-run", status="running", updatedAt="2026-10-28T12:00:00.000Z")
        self.bus_poll()
        head = events.last_seq(self.conn)
        self.srv.add_pending("t-run", approvals=1)
        self.bus_poll()
        got = [(e["type"], e["needs"], e["body"].get("attention")) for e in self.envs(head)]
        self.assertEqual(got, [("task.state", "human", "ask"), ("question.opened", "human", None),
                               ("task.state", "approval", "approval"), ("approval.requested", "approval", None)])
        q = self.envs(head)[1]
        self.assertEqual((q["body"]["request_id"], q["body"]["summary"], q["body"]["options"], q["severity"]),
                         ("req-0001", "¿Qué rama uso?", ["main", "dev"], "notice"))

    def test_question_for_bot_by_reaction(self):
        self.bus_poll()
        self.level = ("bot", "bot-demo")
        self.srv.add_pending("t-run")
        self.bus_poll()
        ts, q = self.envs()[-2:]
        self.assertEqual((q["type"], q["needs"], q["body"]["level"], q["body"]["notify"]), ("question.opened", "bot", "bot", "bot-demo"))
        self.assertEqual((ts["type"], ts["needs"], ts["body"]["attention"], ts["body"]["phase"]), ("task.state", "bot", "bot", "waiting"))

    def test_reaction_level_reads_profile(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, "profiles"))
            with open(os.path.join(home, "profiles", "proyecto-demo.yaml"), "w") as f:
                f.write("project: proyecto-demo\nreactions:\n  - on: pending_question\n    match: rama\n    level: bot\n"
                        "    notify: bot-demo\n")
            old = os.environ.get("CHOPSHOP_HOME")
            os.environ["CHOPSHOP_HOME"] = home
            try:
                self.assertEqual(t3watch.reaction_level("proyecto-demo", "¿Qué rama uso?"), ("bot", "bot-demo"))
                self.assertEqual(t3watch.reaction_level("proyecto-demo", "¿Borro la base?"), (None, None))
                self.assertEqual(t3watch.reaction_level("otro", "rama"), (None, None))
            finally:
                if old is None:
                    os.environ.pop("CHOPSHOP_HOME")
                else:
                    os.environ["CHOPSHOP_HOME"] = old

    def test_machine_health_down_and_recovered(self):
        self.bus_poll()
        self.srv.down = True
        self.bus_poll()
        self.srv.down = False
        self.bus_poll(advance=t3watch.BACKOFF_MAX + 1)
        down, up = self.envs()[-2:]
        self.assertEqual((down["type"], down["body"]["state"], down["body"]["t3_ok"], down["severity"], down["subject"]["kind"]),
                         ("machine.health", "degraded", False, "warn", "machine"))
        self.assertEqual((up["type"], up["body"]["state"], up["body"]["t3_ok"], up["severity"]), ("machine.health", "ok", True, "info"))
        self.assertGreater(up["body"]["down_seconds"], 0)
        self.assertEqual(down["subject"]["id"], "host-a")


class TestUnreachable(Base):
    def test_una_emision_backoff_y_recuperacion(self):
        self.poll()
        self.srv.down = True
        r = self.poll()
        self.assertFalse(r["reachable"])
        self.assertEqual(self.names(), ["t3_unreachable"])
        self.assertEqual(self.t3.backoff, t3watch.BACKOFF_BASE)
        self.assertIsNone(self.events[0][1])
        # aún en backoff: no llama a T3 y no emite
        n = len(self.srv.calls)
        r = self.poll(advance=1)
        self.assertEqual(r.get("skipped"), "backoff")
        self.assertEqual(len(self.srv.calls), n)
        # reintenta, vuelve a fallar: backoff exponencial y NO repite el evento
        r = self.poll(advance=t3watch.BACKOFF_BASE + 1)
        self.assertFalse(r["reachable"])
        self.assertEqual(self.t3.backoff, 2 * t3watch.BACKOFF_BASE)
        self.assertEqual(self.names(), ["t3_unreachable"])
        for _ in range(10):
            self.poll(advance=t3watch.BACKOFF_MAX + 1)
        self.assertEqual(self.t3.backoff, t3watch.BACKOFF_MAX)
        self.assertEqual(self.names(), ["t3_unreachable"])
        # vuelve
        self.srv.down = False
        r = self.poll(advance=t3watch.BACKOFF_MAX + 1)
        self.assertTrue(r["reachable"])
        self.assertEqual(self.names(), ["t3_unreachable", "t3_recovered"])
        self.assertEqual(self.t3.backoff, 0)
        self.assertGreater(self.events[1][2]["down_seconds"], 0)
        self.poll()
        self.assertEqual(len(self.events), 2)

    def test_caida_persistente_no_repite_tras_reinicio(self):
        self.srv.down = True
        self.poll()
        t3b = t3watch.T3(self.cfg, client=self.srv, clock=lambda: self.now[0])   # "reinicio" del agente
        self.now[0] += 60
        t3watch.poll(self.conn, self.cfg, t3b, self.emit)
        self.assertEqual(self.names(), ["t3_unreachable"])

    def test_sin_linea_base_hasta_alcanzar_t3(self):
        self.srv.down = True
        self.poll()
        self.srv.down = False
        self.poll(advance=1000)
        self.assertEqual(self.names(), ["t3_unreachable", "t3_recovered"])     # los hilos se siembran en silencio

    def test_todos_los_listados_fallan_es_caida(self):
        self.srv.fail["t3_thread_list"] = "boom"
        r = t3watch.poll(self.conn, self.cfg, self.t3, self.emit)
        self.assertFalse(r["reachable"])
        self.assertEqual(self.names(), ["t3_unreachable"])


class TestSettle(Base):
    def test_settle(self):
        t3watch.settle(self.t3, "t-run")
        self.assertEqual(self.srv.calls, [("t3_thread_organize", {"threadId": "t-run", "action": "settle"})])

    def test_settle_solo_envia_settle(self):
        for tid in ("t-run", "t-otro"):
            t3watch.settle(self.t3, tid)
        self.assertEqual({t for t, _ in self.srv.calls}, {"t3_thread_organize"})
        self.assertEqual({a["action"] for _, a in self.srv.calls}, {"settle"})

    def test_settle_vacio(self):
        for bad in ("", "  ", None):
            with self.assertRaises(t3watch.T3Error):
                t3watch.settle(self.t3, bad)
        self.assertEqual(self.srv.calls, [])


class TestAnswer(Base):
    def setUp(self):
        super().setUp()
        self.srv.add_pending("t-run")

    def sent(self):
        return [a for t, a in self.srv.calls if t == "t3_pending_request" and a["action"] == "respond"]

    def test_por_numero_etiqueta_y_valor(self):
        r = t3watch.answer(self.t3, "t-run", "2")
        self.assertEqual(r["answers"], {"q1": "develop"})        # opción con value distinto de la etiqueta
        self.assertEqual(r["request_id"], "req-0001")
        self.assertEqual(self.sent()[0]["answers"], {"q1": "develop"})
        self.srv.add_pending("t-run")
        self.assertEqual(t3watch.answer(self.t3, "t-run", "MAIN")["answers"], {"q1": "main"})
        self.srv.add_pending("t-run")
        self.assertEqual(t3watch.answer(self.t3, "t-run", "develop")["answers"], {"q1": "develop"})

    def test_texto_libre_y_opcion_invalida(self):
        self.assertEqual(t3watch.answer(self.t3, "t-run", "otra")["answers"], {"q1": "otra"})
        self.srv.add_pending("t-run")
        self.srv.pending["t-run"]["req-0001"]["questions"][0]["allowCustomAnswer"] = False
        with self.assertRaises(t3watch.AnswerError):
            t3watch.answer(self.t3, "t-run", "otra")
        self.assertEqual(len(self.sent()), 1)

    def test_multiselect(self):
        self.srv.pending["t-run"]["req-0001"]["questions"][0]["multiSelect"] = True
        r = t3watch.answer(self.t3, "t-run", "1, develop, extra")
        self.assertEqual(r["answers"], {"q1": ["main", "develop", "extra"]})

    def test_sin_pendientes(self):
        with self.assertRaisesRegex(t3watch.AnswerError, "no tiene preguntas"):
            t3watch.answer(self.t3, "t-otro", "1") if False else (self.srv.pending.update({"t-otro": {}}), t3watch.answer(self.t3, "t-otro", "1"))

    def test_varias_peticiones_exigen_request(self):
        self.srv.add_pending("t-run", rid="req-0002")
        with self.assertRaisesRegex(t3watch.AnswerError, "indica request"):
            t3watch.answer(self.t3, "t-run", "1")
        with self.assertRaises(t3watch.AnswerError):
            t3watch.answer(self.t3, "t-run", "1", request="zzz")
        r = t3watch.answer(self.t3, "t-run", "1", request="req-0002")
        self.assertEqual(r["request_id"], "req-0002")
        self.assertEqual(list(self.srv.pending["t-run"]), ["req-0001"])

    def test_varias_preguntas_en_una_peticion(self):
        qs = self.srv.pending["t-run"]["req-0001"]["questions"]
        qs.append({"id": "q2", "question": "¿Tests?", "options": [{"label": "sí"}, {"label": "no"}]})
        with self.assertRaisesRegex(t3watch.AnswerError, "preguntas"):
            t3watch.answer(self.t3, "t-run", "1")
        with self.assertRaises(t3watch.AnswerError):
            t3watch.answer(self.t3, "t-run", {"q1": "1"})            # faltan respuestas
        r = t3watch.answer(self.t3, "t-run", {"q1": "1", "q2": "2"})
        self.assertEqual(r["answers"], {"q1": "main", "q2": "no"})


if __name__ == "__main__":
    unittest.main()



class TestAnswers(unittest.TestCase):
    Q = {"id": "q1", "options": [{"label": "main"}, {"label": "Desarrollo", "value": "develop"}]}

    def test_resolve(self):
        self.assertEqual(answers.resolve(self.Q, "2"), "develop")
        self.assertEqual(answers.resolve(self.Q, "MAIN"), "main")
        self.assertEqual(answers.resolve(self.Q, "desarrollo"), "develop")
        self.assertEqual(answers.resolve(self.Q, "develop"), "develop")
        self.assertEqual(answers.resolve(self.Q, "9"), "9")                 # fuera de rango = texto libre
        self.assertEqual(answers.resolve(self.Q, "otra cosa"), "otra cosa")
        with self.assertRaises(answers.InvalidChoice):
            answers.resolve(dict(self.Q, allowCustomAnswer=False), "otra cosa")
        self.assertEqual(answers.resolve({"id": "q", "allowCustomAnswer": False}, "libre"), "libre")   # sin opciones

    def test_resolve_multiselect(self):
        self.assertEqual(answers.resolve(dict(self.Q, multiSelect=True), "1, Desarrollo ,x"), ["main", "develop", "x"])

    def test_resolve_all(self):
        q2 = {"id": "q2", "options": [{"label": "sí"}, {"label": "no"}]}
        self.assertEqual(answers.resolve_all([self.Q], 1), {"q1": "main"})
        self.assertEqual(answers.resolve_all([self.Q, q2], {"q1": "2", "q2": "no"}), {"q1": "develop", "q2": "no"})
        for qs, choice in (([], "1"), ([self.Q, q2], "1"), ([self.Q, q2], {"q1": "1"}), ([self.Q], {"zz": "1"})):
            with self.assertRaises(answers.InvalidChoice):
                answers.resolve_all(qs, choice)
        self.assertTrue(issubclass(answers.InvalidChoice, ValueError))

    def test_motor_usa_el_mismo_modulo(self):
        from chopshop import engine, profile
        self.assertEqual(engine._resolve_answer(self.Q, "2"), "develop")
        with self.assertRaises(profile.ProfileError):
            engine._resolve_answer(dict(self.Q, allowCustomAnswer=False), "nada")
