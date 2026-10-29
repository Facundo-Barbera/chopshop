"""Pruebas de /stream (SSE), la proyección `state` y el emparejamiento por dispositivo. Servidor REAL en 127.0.0.1 con puerto
efímero dentro del test (sin servidores de desarrollo); relojes inyectados para heartbeat y caducidades; DB temporal."""
import copy
import io
import json
import os
import socket
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop.agent import db, envelope, events, pairing, projection, server, stream  # noqa: E402
from test_agent_server import TOKEN, ServerBase  # noqa: E402

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "events", "ui-fixture.jsonl")   # dorado del bus


def load_fixture():
    with open(FIXTURE, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


class Mono:
    """Reloj monotónico falso (heartbeat)."""

    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def until(cond, timeout=5.0, step=0.02):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(step)
    return cond()


class SSE:
    """Cliente SSE mínimo sobre un socket crudo: lee frames `{event,id,data}` y comentarios `{comment}`."""

    def __init__(self, host, port, path="/stream", headers=None, rcvbuf=None, timeout=5):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if rcvbuf:
            self.s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        self.s.settimeout(timeout)
        self.s.connect((host, port))
        hdrs = {"Host": "%s:%s" % (host, port), "Accept": "text/event-stream"}
        hdrs.update(headers or {})
        self.s.sendall(("GET %s HTTP/1.1\r\n%s\r\n" % (path, "".join("%s: %s\r\n" % kv for kv in hdrs.items()))).encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                break
            self.buf += chunk
        head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        self.status = int(lines[0].split()[1])
        self.headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}

    def body(self):
        """Resto de la respuesta (para respuestas no SSE con Connection: close)."""
        while True:
            chunk = self.s.recv(65536)
            if not chunk:
                return self.buf
            self.buf += chunk

    def frame(self, timeout=5):
        self.s.settimeout(timeout)
        while b"\n\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError("cerrado")
            self.buf += chunk
        block, _, self.buf = self.buf.partition(b"\n\n")
        out = {}
        for line in block.decode("utf-8").split("\n"):
            if line.startswith(":"):
                out["comment"] = line[1:].strip()
            else:
                k, _, v = line.partition(": ")
                out[k] = json.loads(v) if k == "data" else (int(v) if k in ("id", "retry") else v)
        return out

    def envelope_frames(self, n, timeout=5):
        out = []
        while len(out) < n:
            f = self.frame(timeout)
            if f.get("event") == "envelope":
                out.append(f)
        return out

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def insert_envelope(conn, env):
    """Guarda un sobre del dorado con su `seq` (columnas v3 del bus)."""
    s, c = env["subject"], env["cause"]
    with db.tx():
        conn.execute("INSERT INTO events(seq,ts,machine_id,event,project,body,id,type,severity,needs,subject_kind,subject_id,"
                     "subject,cause_id,cause_depth) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                     (env["seq"], envelope.epoch(env["ts"]), env["machine"], env["type"], env["project"], db.jdump(env["body"]),
                      env["id"], env["type"], env["severity"], env["needs"], s["kind"], s["id"], db.jdump(s), c["id"], c["depth"]))


# ---------------------------------------------------------------- proyección pura

class TestProjection(unittest.TestCase):
    def setUp(self):
        self.envs = load_fixture()

    def test_apply_is_pure(self):
        st = projection.empty("host-a")
        env = self.envs[4]
        before_st, before_env = copy.deepcopy(st), copy.deepcopy(env)
        new = projection.apply(st, env)
        self.assertEqual((st, env), (before_st, before_env))
        self.assertEqual(new["head_seq"], env["seq"])

    def test_fold_of_fixture(self):
        st = projection.fold(self.envs, "contabo-dev")
        self.assertEqual(st["api_version"], 2)
        self.assertEqual(st["head_seq"], self.envs[-1]["seq"])
        self.assertEqual(st["machine_health"]["state"], "ok")
        self.assertEqual([p["name"] for p in st["projects"]], ["bixku-utilities", "chopshop", "nuskills"])
        bx, cs, nu = st["projects"]
        self.assertEqual(nu["attention"], [])                    # pregunta respondida y tareas terminadas
        self.assertEqual(nu["counts"], {"running": 0, "queued": 0, "waiting": 0, "stuck": 0, "needs_human": 0, "waiting_bot": 0,
                                        "done": 2, "failed": 1})
        self.assertEqual({t["id"]: t["phase"] for t in nu["tasks"]}, {"mcp:a1": "settled", "mcp:b7": "failed", "mcp:a036": "done"})
        self.assertEqual([(b["id"], b["status"]) for b in nu["batches"]], [("b-0007", "done")])
        g = nu["graphs"][0]
        self.assertEqual((g["id"], g["status"]), ("g-2", "failed"))
        self.assertEqual({n["id"]: n["phase"] for n in g["nodes"]}, {"n-2": "done", "n-3": "failed", "n-4": "running"})
        self.assertEqual([(a["subject"]["id"], a["type"], a["needs"]) for a in cs["attention"]],
                         [("Facundo-Barbera/chopshop#51", "triage.result", "bot")])
        self.assertEqual(cs["counts"]["waiting_bot"], 1)
        self.assertEqual(bx["counts"]["running"], 1)
        self.assertEqual([e["seq"] for e in st["recent"]], [e["seq"] for e in reversed(self.envs)][:projection.RECENT])

    def test_attention_open_and_close(self):
        by_seq = {e["seq"]: i for i, e in enumerate(self.envs)}
        upto = lambda seq: projection.fold(self.envs[:by_seq[seq] + 1], "contabo-dev")  # noqa: E731
        att = lambda st, name: [(a["subject"]["id"], a["type"], a["needs"])  # noqa: E731
                                for a in next(p for p in st["projects"] if p["name"] == name)["attention"]]
        st = upto(1816)                                        # pregunta al bot + reaction.applied (no cierra)
        self.assertEqual(att(st, "nuskills"), [("mcp:b7", "question.opened", "bot")])
        self.assertEqual(next(p for p in st["projects"] if p["name"] == "nuskills")["counts"]["waiting_bot"], 1)
        st = upto(1820)
        self.assertEqual(att(st, "chopshop"), [("mcp:c41", "approval.requested", "approval")])
        self.assertEqual(att(st, "bixku-utilities"), [("mcp:x9", "question.opened", "human")])
        a = next(p for p in st["projects"] if p["name"] == "nuskills")["attention"][0]
        self.assertEqual(a["since"], self.envs[by_seq[1814]]["ts"])           # abierta desde el task.state con atención
        self.assertEqual(a["summary"], self.envs[by_seq[1815]]["body"]["summary"])
        self.assertEqual(att(upto(1822), "nuskills"), [])                     # question.answered cierra
        self.assertEqual(att(upto(1833), "chopshop"), [("Facundo-Barbera/chopshop#51", "triage.result", "bot")])

    def test_one_by_one_equals_fold_and_is_idempotent(self):
        st = projection.empty("host-a")
        for e in self.envs:
            st = projection.apply(st, e)
        self.assertEqual(st, projection.fold(self.envs, "host-a"))
        # repetir o reordenar sobres ya vistos no cambia nada (seq <= head_seq)
        again = projection.fold(self.envs + list(reversed(self.envs)) + self.envs[3:9], "host-a")
        self.assertEqual(again, st)

    def test_filter_project(self):
        st = projection.fold(self.envs, "host-a")
        f = projection.filter_project(st, "chopshop")
        self.assertEqual([p["name"] for p in f["projects"]], ["chopshop"])
        self.assertTrue(f["recent"] and all(e["project"] == "chopshop" for e in f["recent"]))
        self.assertEqual(f["machine_health"], st["machine_health"])


# ---------------------------------------------------------------- proyección desde SQLite

class TestStateFromDb(unittest.TestCase):
    def setUp(self):
        import tempfile, shutil
        self.tmp = tempfile.mkdtemp(prefix="chopshop-proj-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = db.connect(os.path.join(self.tmp, "a.db"))
        self.addCleanup(self.conn.close)
        self.cfg = {"machine_id": "host-a"}

    def test_state_equals_fold_with_ui_fixture(self):
        envs = load_fixture()
        for e in envs:
            insert_envelope(self.conn, e)
        self.assertEqual(projection.envelopes_after(self.conn, 0), envs)
        self.assertEqual(projection.state(self.conn, self.cfg), projection.fold(envs, "host-a"))
        # paginado: igual con páginas de 5
        old = projection.PAGE
        projection.PAGE = 5
        try:
            self.assertEqual(projection.state(self.conn, self.cfg), projection.fold(envs, "host-a"))
            pr = projection.Projector(self.conn, self.cfg)
            self.assertEqual(pr.current(), projection.fold(envs, "host-a"))
        finally:
            projection.PAGE = old

    def test_state_equals_fold_with_legacy_rows(self):
        cfg = dict(self.cfg, webhook_files={})
        pr = projection.Projector(self.conn, self.cfg)
        events.emit(self.conn, cfg, "agent_started", None, {"version": "0.6.0"})
        events.emit(self.conn, cfg, "thread_started", "demo", {"thread_id": "t-1", "title": "Uno", "status": "running"})
        events.emit(self.conn, cfg, "pending_question", "demo", {"thread_id": "t-1", "title": "Uno", "request_id": "r1",
                                                                   "questions": [{"question": "¿Seguimos?", "options": []}]})
        mid = pr.current()
        self.assertEqual(mid["projects"][0]["attention"][0]["summary"], "¿Seguimos?")
        events.emit(self.conn, cfg, "thread_done", "demo", {"thread_id": "t-1", "title": "Uno", "status": "completed", "result": "ok"})
        events.emit(self.conn, cfg, "t3_unreachable", None, {"down_seconds": 0})
        envs = projection.envelopes_after(self.conn, 0)
        self.assertEqual([e["type"] for e in envs], ["agent.started", "task.state", "task.state", "question.opened", "task.state",
                                                     "machine.health"])
        self.assertEqual(envs[1]["body"]["legacy"], "thread_started")
        full = projection.state(self.conn, self.cfg)
        self.assertEqual(full, projection.fold(envs, "host-a"))
        self.assertEqual(pr.current(), full)                       # incremental == completo
        demo = full["projects"][0]
        self.assertEqual((demo["attention"], demo["counts"]["done"]), ([], 1))
        self.assertEqual(full["machine_health"]["state"], "degraded")


# ---------------------------------------------------------------- Bus

class TestBus(unittest.TestCase):
    def test_publish_wakes_waiters_and_close(self):
        bus = stream.Bus()
        got = []
        t = threading.Thread(target=lambda: got.append(bus.wait(0, 5)))
        t.start()
        time.sleep(0.05)
        t0 = time.monotonic()
        bus.publish(7)
        t.join(2)
        self.assertEqual(got, [7])
        self.assertLess(time.monotonic() - t0, 1)
        self.assertEqual(bus.wait(3, 5), 7)                        # ya hay algo más nuevo: no espera
        t = threading.Thread(target=lambda: got.append(bus.wait(7, 5)))
        t.start()
        bus.close()
        t.join(2)
        self.assertFalse(t.is_alive())


# ---------------------------------------------------------------- /stream con servidor real

class StreamBase(ServerBase):
    def start_stream(self, stream_opts=None, **over):
        self.mono = Mono()
        o = {"clock": self.mono, "poll": 0.05}
        o.update(stream_opts or {})
        return self.start(svc_kw={"stream_opts": o}, **over)

    def sse(self, path="/stream", **kw):
        c = SSE(self.host, self.port, path, **kw)
        self.addCleanup(c.close)
        return c

    def open_stream(self, path="/stream", **kw):
        c = self.sse(path, **kw)
        self.assertEqual(c.status, 200)
        self.assertTrue(c.headers["content-type"].startswith("text/event-stream"))
        self.assertEqual(c.frame(), {"retry": 3000})
        return c

    def emit(self, n=1, project="proyecto-demo", event="thread_started", **body):
        return [self.svc.emit(event, project, dict({"thread_id": "t-%d" % i, "title": "Hilo %d" % i}, **body))
                for i in range(n)]


class TestStream(StreamBase):
    def test_new_connection_hello_state_then_deltas_in_order(self):
        self.start_stream()
        self.emit(3)
        head = events.last_seq(self.conn)
        c = self.open_stream()
        hello = c.frame()
        self.assertEqual((hello["event"], hello["data"]), ("hello", {"api_version": 2, "machine": "host-a", "head_seq": head,
                                                                      "resume": "snapshot"}))
        st = c.frame()
        self.assertEqual((st["event"], st["id"], st["data"]["head_seq"]), ("state", head, head))
        self.assertEqual(len(st["data"]["projects"][0]["tasks"]), 3)
        t0 = time.monotonic()
        seqs = self.emit(4, event="thread_done")
        got = c.envelope_frames(4)
        self.assertLess(time.monotonic() - t0, 2)
        self.assertEqual([f["id"] for f in got], seqs)
        self.assertEqual([f["data"]["seq"] for f in got], seqs)
        self.assertEqual({f["data"]["type"] for f in got}, {"task.state"})
        self.assertEqual(got[0]["data"]["body"]["phase"], "done")

    def test_resume_with_last_event_id_no_loss_no_dups(self):
        self.start_stream()
        self.emit(2)
        c = self.open_stream()
        c.frame(), c.frame()
        first = self.emit(5)
        seen = [f["id"] for f in c.envelope_frames(5)]
        self.assertEqual(seen, first)
        last = seen[2]                                              # el cliente solo procesó 3 antes de caerse
        c.close()
        burst = self.emit(60, event="thread_done")                 # ráfaga durante la desconexión
        c2 = self.open_stream(headers={"Last-Event-ID": str(last)})
        hello = c2.frame()
        self.assertEqual(hello["data"]["resume"], "events")
        more = self.emit(3, event="thread_settled")
        got = [f["id"] for f in c2.envelope_frames(2 + 60 + 3)]
        self.assertEqual(got, seen[3:] + burst + more)
        self.assertEqual(len(got), len(set(got)))
        # ?after= equivale (la cabecera manda si están las dos)
        c3 = self.open_stream("/stream?after=%d" % burst[-1], headers={"Last-Event-ID": str(more[0])})
        c3.frame()
        self.assertEqual([f["id"] for f in c3.envelope_frames(2)], more[1:])

    def test_after_too_old_or_too_far_behind_sends_state(self):
        self.start_stream()
        self.emit(5)
        with db.tx():
            self.conn.execute("DELETE FROM events WHERE seq<=3")       # retención
        c = self.open_stream("/stream?after=1")
        self.assertEqual(c.frame()["data"]["resume"], "snapshot")
        self.assertEqual(c.frame()["event"], "state")
        old = stream.MAX_BACKLOG
        stream.MAX_BACKLOG = 1
        self.addCleanup(setattr, stream, "MAX_BACKLOG", old)
        c = self.open_stream("/stream?after=3")
        self.assertEqual(c.frame()["data"]["resume"], "snapshot")
        c = self.open_stream("/stream?after=999999")                    # cursor de otra DB
        self.assertEqual(c.frame()["data"]["resume"], "snapshot")

    def test_client_fold_equals_state(self):
        self.start_stream()
        self.emit(2)
        self.svc.emit("pending_question", "proyecto-demo", {"thread_id": "t-0", "request_id": "r1",
                                                            "questions": [{"question": "¿Sí?", "options": []}]})
        c = self.open_stream()
        c.frame()
        st = c.frame()["data"]
        seqs = self.emit(3, event="thread_done") + [self.svc.emit("agent_started", None, {"version": "x"})]
        self.svc.emit("pending_question", "otro", {"thread_id": "t-9", "request_id": "r2", "questions": []})
        head = events.last_seq(self.conn)                          # una pregunta son 2 sobres (task.state + question.opened)
        for f in c.envelope_frames(head - st["head_seq"]):
            st = projection.apply(st, f["data"])
        code, body, _ = self.get("/state")
        self.assertEqual(code, 200)
        self.assertEqual(st, body)
        self.assertEqual(body["head_seq"], head)
        code, body, _ = self.get("/state?project=otro")
        self.assertEqual([p["name"] for p in body["projects"]], ["otro"])

    def test_filters_project_and_types(self):
        self.start_stream()
        c = self.open_stream("/stream?project=proyecto-demo&types=question.*,machine.*")
        c.frame(), c.frame()
        self.emit(2)                                                               # task.state: fuera por tipo
        self.svc.emit("pending_question", "otro", {"thread_id": "x", "questions": []})        # fuera por proyecto
        want = self.svc.emit("pending_question", "proyecto-demo", {"thread_id": "y", "questions": []})
        f = c.envelope_frames(1)[0]
        self.assertEqual((f["id"], f["data"]["type"], f["data"]["project"]), (want, "question.opened", "proyecto-demo"))
        c2 = self.open_stream("/stream?types=agent.started")
        c2.frame(), c2.frame()
        want = self.svc.emit("agent_started", None, {})
        self.assertEqual(c2.envelope_frames(1)[0]["id"], want)

    def test_heartbeat_with_injected_clock(self):
        self.start_stream({"heartbeat": 15})
        c = self.open_stream()
        c.frame(), c.frame()
        with self.assertRaises(socket.timeout):
            c.frame(timeout=0.4)                                       # el reloj no avanzó: no hay ping
        self.mono.t += 16
        self.assertEqual(c.frame(timeout=3), {"comment": "ping"})
        with self.assertRaises(socket.timeout):
            c.frame(timeout=0.3)
        self.mono.t += 15
        self.assertEqual(c.frame(timeout=3), {"comment": "ping"})

    def test_ninth_client_gets_503(self):
        self.start_stream()
        clients = []
        for _ in range(8):
            c = self.open_stream()
            c.frame(), c.frame()
            clients.append(c)
        self.assertEqual(self.svc.app.stream.active, 8)
        c9 = self.sse()
        self.assertEqual(c9.status, 503)
        self.assertIn("demasiadas conexiones", json.loads(c9.body().decode())["error"])
        self.assertEqual(self.get("/health")[0], 200)                    # el resto de rutas no cuenta
        clients[0].close()
        until(lambda: self.emit(1) and self.svc.app.stream.active < 8)  # el cierre se detecta al escribir
        c10 = self.open_stream()
        self.assertEqual(c10.frame()["event"], "hello")

    def test_closed_client_is_dropped(self):
        self.start_stream()
        c = self.open_stream()
        c.frame(), c.frame()
        self.assertEqual(self.svc.app.stream.active, 1)
        c.close()
        self.assertTrue(until(lambda: self.emit(1) and self.svc.app.stream.active == 0))

    def test_slow_client_is_cut_without_blocking_bus(self):
        self.start_stream({"write_timeout": 0.5, "sndbuf": 4096})
        slow = self.open_stream(rcvbuf=4096)
        slow.frame(), slow.frame()                                     # luego ya no lee
        fast = self.open_stream()
        fast.frame(), fast.frame()
        big = "x" * 8000
        t0 = time.monotonic()
        seqs = [self.svc.emit("thread_started", "proyecto-demo", {"thread_id": "t-%d" % i, "pad": big}) for i in range(150)]
        self.assertLess(time.monotonic() - t0, 3)                      # emitir no espera a los clientes
        self.assertEqual([f["id"] for f in fast.envelope_frames(150)], seqs)
        self.assertTrue(until(lambda: self.svc.app.stream.active == 1, timeout=8))   # el lento se cortó; el rápido sigue

    def test_stop_closes_streams(self):
        self.start_stream()
        c = self.open_stream()
        c.frame(), c.frame()
        t0 = time.monotonic()
        self.svc.stop()
        self.assertLess(time.monotonic() - t0, 5)
        with self.assertRaises((EOFError, OSError)):
            for _ in range(5):
                c.frame(timeout=3)
        self.assertEqual(self.svc.app.stream.active, 0)

    def test_snapshot_v1_unchanged(self):
        self.start_stream()
        self.emit(1)
        st, body, _ = self.get("/snapshot")
        self.assertEqual(st, 200)
        self.assertEqual(set(body), {"api_version", "machine_id", "ts", "generated", "machine", "apps", "projects", "threads",
                                     "pending_questions", "events", "subscriptions", "orchestrator", "agent"})
        self.assertEqual(body["api_version"], 1)
        old = {"seq", "ts", "machine_id", "event", "project", "body"}       # campos v1 (el bus añade los del sobre)
        self.assertLessEqual(old, set(body["events"][0]))
        self.assertEqual(body["events"][0]["event"], "thread_started")
        st, body, _ = self.get("/events?after=0")
        self.assertLessEqual(old, set(body["events"][0]))
        self.assertEqual(self.get("/health")[1]["api_version"], 1)


# ---------------------------------------------------------------- emparejamiento (unidad)

class TestPairingUnit(unittest.TestCase):
    def setUp(self):
        import tempfile, shutil
        self.tmp = tempfile.mkdtemp(prefix="chopshop-pair-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.path = os.path.join(self.tmp, "a.db")
        self.conn = db.connect(self.path)
        self.addCleanup(self.conn.close)
        self.clock = Mono(1_800_000_000.0)
        self.p = pairing.Pairing(self.conn, self.clock)

    def test_code_format_and_single_use(self):
        c = self.p.create_code("Mac")
        self.assertRegex(c["code"], r"^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$")
        self.assertEqual(c["expires_at"], self.clock.t + 600)
        res = self.p.redeem(c["code"].lower().replace("-", " "), "MacBook", "dev-1", "100.64.0.5")
        self.assertEqual(res["device_id"], "dev-1")
        self.assertRegex(res["credential"], r"^cs1_[A-Za-z0-9_-]{43}$")
        self.assertEqual(self.p.check(res["credential"]), "dev-1")
        with self.assertRaises(pairing.PairError) as cm:
            self.p.redeem(c["code"], "Otro", "dev-2", "100.64.0.6")
        self.assertEqual(cm.exception.status, 410)
        self.assertIsNone(self.p.check(res["credential"][:-1] + ("A" if res["credential"][-1] != "A" else "B")))
        self.assertIsNone(self.p.check("Bearer basura"))

    def test_expired_invalid_and_ttl_limits(self):
        c = self.p.create_code(ttl=60)
        self.clock.t += 61
        with self.assertRaises(pairing.PairError) as cm:
            self.p.redeem(c["code"], ip="a")
        self.assertEqual(cm.exception.status, 410)
        with self.assertRaises(pairing.PairError) as cm:
            self.p.redeem("ZZZZ-ZZZZ", ip="b")
        self.assertEqual(cm.exception.status, 401)
        with self.assertRaises(pairing.PairError) as cm:
            self.p.redeem(None, ip="b")
        self.assertEqual(cm.exception.status, 401)
        for bad in (0, 3601):
            with self.assertRaises(pairing.PairError):
                self.p.create_code(ttl=bad)
        self.assertEqual(pairing.parse_ttl("10m"), 600)
        self.assertEqual(pairing.parse_ttl("1h"), 3600)
        with self.assertRaises(ValueError):
            pairing.parse_ttl("2h")

    def test_rate_limits(self):
        c = self.p.create_code()
        for _ in range(5):
            with self.assertRaises(pairing.PairError) as cm:
                self.p.redeem("0000-0000", ip="100.64.0.7")
            self.assertEqual(cm.exception.status, 401)
        with self.assertRaises(pairing.PairError) as cm:               # bloqueada aunque traiga el código bueno
            self.p.redeem(c["code"], ip="100.64.0.7")
        self.assertEqual(cm.exception.status, 429)
        self.clock.t += 61
        self.assertEqual(self.p.redeem(c["code"], device_id="d", ip="100.64.0.7")["device_id"], "d")
        # 20 fallos (desde IPs distintas) invalidan el código vivo
        c2 = self.p.create_code()
        for i in range(20):
            with self.assertRaises(pairing.PairError):
                self.p.redeem("0000-0000", ip="192.0.2.%d" % i)
        with self.assertRaises(pairing.PairError) as cm:
            self.p.redeem(c2["code"], ip="198.51.100.1")
        self.assertEqual(cm.exception.status, 410)
        self.assertEqual(self.p.list()["codes"], [])

    def test_only_hashes_are_stored_and_cli_hides_secrets(self):
        out = io.StringIO()
        self.assertEqual(pairing.main(["create", "--name", "Mac", "--ttl", "5m"], stdout=out, conn=self.conn, clock=self.clock), 0)
        code = out.getvalue().split("código: ")[1].split()[0]
        res = self.p.redeem(code, "MacBook", "dev-1", "100.64.0.5")
        self.p.create_code("pendiente")
        self.conn.execute("PRAGMA wal_checkpoint(FULL)")
        blob = b""
        for suffix in ("", "-wal"):
            if os.path.exists(self.path + suffix):
                with open(self.path + suffix, "rb") as f:
                    blob += f.read()
        for secret in (code, code.replace("-", ""), res["credential"], res["credential"][4:]):
            self.assertNotIn(secret.encode(), blob)
        out = io.StringIO()
        self.assertEqual(pairing.main(["list"], stdout=out, conn=self.conn, clock=self.clock), 0)
        out2 = io.StringIO()
        pairing.main(["list", "--json"], stdout=out2, conn=self.conn, clock=self.clock)
        listing = json.loads(out2.getvalue())
        self.assertEqual([d["id"] for d in listing["devices"]], ["dev-1"])
        self.assertEqual(len(listing["codes"]), 1)
        with db.tx():
            hashes = [r[0] for r in self.conn.execute("SELECT cred_hash FROM devices")] + \
                     [r[0] for r in self.conn.execute("SELECT code_hash FROM pair_codes")] + \
                     [r[0] for r in self.conn.execute("SELECT salt FROM pair_codes")]
        for text in (out.getvalue(), out2.getvalue()):
            self.assertIn("dev-1", text)
            for secret in [code, res["credential"]] + hashes:
                self.assertNotIn(secret, text)
            self.assertNotIn("hash", text)
            self.assertNotIn("salt", text)

    def test_revoke_and_prune(self):
        c = self.p.create_code()
        res = self.p.redeem(c["code"], device_id="dev-1", ip="x")
        live = self.p.create_code()
        out = io.StringIO()
        self.assertEqual(pairing.main(["revoke", "dev-1"], stdout=out, conn=self.conn, clock=self.clock), 0)
        self.assertIsNone(self.p.check(res["credential"]))
        self.assertFalse(self.p.active("dev-1"))
        self.assertEqual(self.p.revoke(live["id"]), "code")
        self.assertEqual(pairing.main(["revoke", "nada"], stdout=out, stderr=io.StringIO(), conn=self.conn, clock=self.clock), 1)
        self.clock.t += 8 * 86400
        self.assertEqual(self.p.prune(), {"codes": 2, "devices": 1})
        self.assertEqual(self.p.list(), {"devices": [], "codes": []})


# ---------------------------------------------------------------- emparejamiento y auth por HTTP

class TestPairingHttp(StreamBase):
    def setUp(self):
        super().setUp()
        self.start_stream(auth="tailscale+token", trust_local=False)
        self.ts.logins["127.0.0.1"] = "yo@github"

    def pair(self, name="Mac", device_id="dev-mac"):
        code = self.svc.pairing.create_code(name)["code"]
        st, body, _ = self.post("/pair", {"code": code, "device_name": name, "device_id": device_id})
        self.assertEqual(st, 200, body)
        return code, body

    def auth(self, cred):
        return {"Authorization": "Bearer " + cred}

    def test_pair_then_credential_required_everywhere(self):
        code, body = self.pair()
        self.assertEqual(set(body), {"device_id", "credential", "api_version"})
        self.assertEqual((body["device_id"], body["api_version"]), ("dev-mac", 2))
        cred = body["credential"]
        self.assertEqual(self.post("/pair", {"code": code, "device_id": "otro"})[0], 410)        # un solo uso
        self.assertEqual(self.post("/pair", {"code": "ZZZZ-ZZZZ"})[0], 401)
        for path in ("/snapshot", "/state", "/events", "/threads", "/metrics", "/subscriptions"):
            st, b, r = self.get(path)
            self.assertEqual(st, 401, path)
            self.assertEqual(r.getheader("WWW-Authenticate"), 'Bearer realm="chopshop-agent"')
            self.assertEqual(self.get(path, headers=self.auth(cred))[0], 200, path)
        self.assertEqual(self.sse().status, 401)
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"})[0], 401)
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"}, headers=self.auth(cred))[0], 200)
        st, b, _ = self.get("/health", headers=self.auth(cred))
        self.assertEqual(b["whoami"], {"login": "yo@github", "via": "tailscale", "write": True, "device": "dev-mac"})
        c = self.open_stream(headers=self.auth(cred))
        self.assertEqual(c.frame()["event"], "hello")
        # el token legado sigue valiendo (CLI y bots)
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"}, headers=self.auth(TOKEN))[0], 200)
        # whois sigue siendo la segunda barrera: credencial buena desde una identidad ajena -> 403
        self.ts.logins["127.0.0.1"] = "intruso@github"
        self.svc.auth._whois.clear()
        self.assertEqual(self.get("/state", headers=self.auth(cred))[0], 403)
        self.assertEqual(self.post("/pair", {"code": "ZZZZ-ZZZZ"})[0], 403)

    def test_reader_device_is_read_only(self):
        self.ts.logins["127.0.0.1"] = "lector@github"
        _, body = self.pair("iPad", "dev-ipad")
        h = self.auth(body["credential"])
        self.assertEqual(self.get("/state", headers=h)[0], 200)
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"}, headers=h)[0], 403)

    def test_revoke_is_immediate_and_closes_sse(self):
        _, body = self.pair()
        cred = body["credential"]
        c = self.open_stream(headers=self.auth(cred))
        c.frame(), c.frame()
        other = self.open_stream(headers=self.auth(TOKEN))
        other.frame(), other.frame()
        # la CLI revoca en otro "proceso" (su propia conexión a la DB)
        conn2 = db.connect(self.cfg["db_path"])
        self.addCleanup(conn2.close)
        self.assertEqual(pairing.main(["revoke", "dev-mac"], stdout=io.StringIO(), conn=conn2), 0)
        self.assertEqual(self.get("/state", headers=self.auth(cred))[0], 401)
        with self.assertRaises((EOFError, OSError)):
            for _ in range(5):
                c.frame(timeout=3)
        self.assertTrue(until(lambda: self.svc.app.stream.active == 1))
        seq = self.svc.emit("agent_started", None, {})
        self.assertEqual(other.envelope_frames(1)[0]["id"], seq)        # los demás siguen
        self.assertEqual(self.svc.app.stream.revoke("nadie"), 0)

    def test_pair_rate_limit_over_http(self):
        for _ in range(5):
            self.assertEqual(self.post("/pair", {"code": "0000-0000"})[0], 401)
        code = self.svc.pairing.create_code()["code"]
        st, body, _ = self.post("/pair", {"code": code})
        self.assertEqual(st, 429)
        self.assertEqual(self.post("/pair", {"code": code, "device_id": "x/../y"})[0], 429)

    def test_no_secrets_in_logs_or_db(self):
        code, body = self.pair()
        cred = body["credential"]
        self.get("/state", headers=self.auth(cred))
        self.post("/pair", {"code": code})
        until(lambda: any("POST /pair -> 410" in l for l in self.logs))
        text = "\n".join(self.logs)
        for secret in (code, code.replace("-", ""), cred, TOKEN):
            self.assertNotIn(secret, text)
        self.conn.execute("PRAGMA wal_checkpoint(FULL)")
        blob = b""
        for suffix in ("", "-wal"):
            p = self.cfg["db_path"] + suffix
            if os.path.exists(p):
                with open(p, "rb") as f:
                    blob += f.read()
        for secret in (code, code.replace("-", ""), cred):
            self.assertNotIn(secret.encode(), blob)


class TestWebGuards(StreamBase):
    def test_guards(self):
        self.start_stream(auth="tailscale+token", trust_local=False)
        self.ts.logins["127.0.0.1"] = "yo@github"
        h = {"Authorization": "Bearer " + TOKEN}
        st, b, _ = self.req("POST", "/settle", raw=b'{"thread_id":"t-1"}', headers=dict(h, **{"Content-Type": "text/plain"}))
        self.assertEqual((st, b["error"]), (403, "las escrituras exigen Content-Type: application/json"))
        self.assertEqual(self.req("POST", "/settle", raw=b'{"thread_id":"t-1"}',
                                  headers=dict(h, **{"Content-Type": "application/json; charset=utf-8"}))[0], 200)
        st, b, _ = self.post("/settle", {"thread_id": "t-1"}, headers=dict(h, Origin="https://malo.example"))
        self.assertEqual((st, b["error"]), (403, "no se aceptan peticiones con cabecera Origin (navegadores)"))
        self.assertEqual(self.get("/state", headers=dict(h, Origin="null"))[0], 403)
        st, b, _ = self.post("/settle", {"thread_id": "t-1"}, headers=dict(h, Host="malo.example:%d" % self.port))
        self.assertEqual((st, b["error"]), (403, "Host no reconocido"))
        self.assertEqual(self.get("/state", headers=dict(h, Host="malo.example"))[0], 403)
        self.assertEqual(self.post("/pair", {"code": "x"}, headers={"Origin": "https://malo.example"})[0], 403)
        self.assertEqual(self.req("POST", "/pair", raw=b'{"code":"x"}', headers={"Content-Type": "text/plain"})[0], 403)
        for host in ("localhost:%d" % self.port, "host-a", "HOST-A:1", socket.gethostname()):
            self.assertEqual(self.get("/state", headers=dict(h, Host=host))[0], 200, host)
        self.assertEqual(self.req("DELETE", "/subscriptions/nada", headers=h)[0], 404)           # DELETE sin cuerpo: sin Content-Type

    def test_local_origin_intact_but_guarded(self):
        self.start_stream()
        self.assertEqual(self.get("/state")[0], 200)                               # local: sin credencial
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"})[0], 200)
        c = self.open_stream()
        self.assertEqual(c.frame()["event"], "hello")
        self.assertEqual(self.post("/settle", {"thread_id": "t-1"}, headers={"Origin": "http://127.0.0.1"})[0], 403)
        self.assertEqual(self.get("/snapshot", headers={"Host": "rebind.example"})[0], 403)

    def test_allowed_hosts(self):
        a = server.Authenticator({"machine_id": "host-a", "allowed_hosts": ["agente.ejemplo.internal"]})
        local = {"100.64.0.9"}
        for h, ok in (("100.64.0.9:3790", True), ("127.0.0.1", True), ("[::1]:3790", True), ("100.64.0.8", False),
                      ("agente.ejemplo.internal", True), ("agente.ejemplo.internal.", True), ("host-a.malo.example", False),
                      ("", False), (None, False)):
            self.assertEqual(a.host_ok(h, local), ok, h)


if __name__ == "__main__":
    unittest.main()
