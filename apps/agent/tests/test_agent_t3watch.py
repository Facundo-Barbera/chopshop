"""Pruebas de chopshop.agent.t3watch con un runner falso (sin node, sin T3, sin red). Fixtures: tests/fixtures/t3/."""
import copy
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop.agent import config as agent_config, db, t3watch  # noqa: E402

FIX = os.path.join(os.path.dirname(__file__), "fixtures", "t3")


def fixture(name):
    with open(os.path.join(FIX, name + ".json"), encoding="utf-8") as f:
        return json.load(f)


class FakeServer:
    """Simula el helper t3mcp.mjs: `runner(cmd, env, timeout)` contesta según el estado en memoria."""

    def __init__(self):
        self.projects = fixture("project_list")
        self.threads = {"p-0001": fixture("thread_list")["threads"], "p-0002": []}
        self.reads = {"t-run": fixture("thread_read")}
        self.pending = {}            # thread_id -> {request_id: respuesta de t3_pending_request read}
        self.down = False
        self.raw = None              # fuerza una salida cruda (p. ej. truncada)
        self.calls = []              # (tool, args)
        self.envs = []
        self.cmds = []
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

    def runner(self, cmd, env=None, timeout=None):
        self.cmds.append(cmd)
        self.envs.append(env)
        tool, args = cmd[2], json.loads(cmd[3])
        self.calls.append((tool, args))
        if self.down:
            return types.SimpleNamespace(returncode=1, stdout="ERROR: fetch failed", stderr="")
        if self.raw is not None:
            return types.SimpleNamespace(returncode=0, stdout=self.raw, stderr="")
        out = getattr(self, "_" + tool)(args)
        return types.SimpleNamespace(returncode=0, stdout=json.dumps(out), stderr="")

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
        self.t3 = t3watch.T3(self.cfg, runner=self.srv.runner, clock=lambda: self.now[0])
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
    def test_comando_y_entorno(self):
        self.cfg["t3"].update(helper="~/ayuda/t3mcp.mjs", t3_bin="~/bin/t3", access="full-access", node="nodo")
        t3 = t3watch.T3(self.cfg, runner=self.srv.runner)
        t3.call("t3_project_list", {"limit": 5})
        cmd, env = self.srv.cmds[-1], self.srv.envs[-1]
        self.assertEqual(cmd[0], "nodo")
        self.assertEqual(cmd[1], os.path.expanduser("~/ayuda/t3mcp.mjs"))
        self.assertEqual(cmd[2], "t3_project_list")
        self.assertEqual(json.loads(cmd[3]), {"limit": 5})
        self.assertEqual(env["T3MCP_ACCESS"], "full-access")
        self.assertEqual(env["T3_BIN"], os.path.expanduser("~/bin/t3"))

    def test_errores(self):
        self.srv.down = True
        with self.assertRaises(t3watch.T3Error):
            self.t3.call("t3_project_list")
        self.srv.down = False
        self.srv.raw = '{"projects": [{"id": "p-00'          # salida truncada
        with self.assertRaisesRegex(t3watch.T3Error, "no es JSON"):
            self.t3.call("t3_project_list")
        self.srv.raw = json.dumps([{"type": "text", "text": '{"_tag":"OrchestratorMcpFailure","code":"target_required"}'}])
        with self.assertRaisesRegex(t3watch.T3Error, "target_required"):
            self.t3.call("t3_thread_list")

    def test_timeout_y_oserror(self):
        def boom(cmd, env, timeout):
            raise subprocess.TimeoutExpired(cmd, timeout)

        with self.assertRaisesRegex(t3watch.T3Error, "tiempo agotado"):
            t3watch.T3(self.cfg, runner=boom).call("t3_project_list")

        def nonode(cmd, env, timeout):
            raise FileNotFoundError("node")

        with self.assertRaisesRegex(t3watch.T3Error, "helper"):
            t3watch.T3(self.cfg, runner=nonode).call("t3_project_list")

    def test_organize_solo_settle(self):
        for action in ("archive", "unarchive", "pin", None):
            with self.assertRaises(t3watch.T3Error):
                self.t3.call("t3_thread_organize", {"threadId": "t-run", "action": action})
        self.assertEqual(self.srv.calls, [])      # ni siquiera llega al helper
        self.t3.call("t3_thread_organize", {"threadId": "t-run", "action": "settle"})
        self.assertEqual(self.srv.count("t3_thread_organize"), 1)

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
        t3b = t3watch.T3(self.cfg, runner=self.srv.runner, clock=lambda: self.now[0])   # "reinicio" del agente
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
        self.srv._t3_thread_list = lambda a: (_ for _ in ()).throw(AssertionError)
        orig = self.srv.runner

        def runner(cmd, env=None, timeout=None):
            if cmd[2] == "t3_thread_list":
                return types.SimpleNamespace(returncode=1, stdout="", stderr="boom")
            return orig(cmd, env, timeout)

        t3 = t3watch.T3(self.cfg, runner=runner, clock=lambda: self.now[0])
        r = t3watch.poll(self.conn, self.cfg, t3, self.emit)
        self.assertFalse(r["reachable"])
        self.assertEqual(self.names(), ["t3_unreachable"])


class TestSettle(Base):
    def test_settle(self):
        t3watch.settle(self.t3, "t-run")
        self.assertEqual(self.srv.calls, [("t3_thread_organize", {"threadId": "t-run", "action": "settle"})])

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
