"""Suscripciones v2 del agente (chopshop.agent.webhooks + events): filtros, firma HMAC, only_changes, debounce, contexto,
reintentos, compatibilidad con suscripciones viejas, migración v4, API y CLI. Sin red: poster y reloj inyectados."""
import contextlib
import hashlib
import hmac
import io
import json
import logging
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop import cli  # noqa: E402
from chopshop.agent import db, events, webhooks  # noqa: E402
from test_agent_server import ServerBase  # noqa: E402

URL = "https://hooks.example.invalid/url-canario-7f3e"
SECRET = "secreto-hmac-canario-91ab"
TOKEN = "Bearer token-canario-c0ffee"


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


class Poster:
    """poster(url, data, timeout, headers): guarda (url, payload, headers, data) y responde según `result(url, n)`."""

    def __init__(self, result=204):
        self.result = result
        self.calls = []
        self.lock = threading.Lock()

    def __call__(self, url, data, timeout, headers=None):
        with self.lock:
            self.calls.append((url, json.loads(data.decode("utf-8")), dict(headers or {}), data))
            n = len(self.calls)
        r = self.result(url, n) if callable(self.result) else self.result
        if isinstance(r, BaseException):
            raise r
        return r

    def to(self, url):
        return [c for c in self.calls if c[0] == url]


def env(type="task.state", project="p1", severity="info", needs=None, legacy=None, subject="t1", **body):
    b = dict(body)
    if legacy:
        b["legacy"] = legacy
    return {"v": 1, "id": "id-1", "seq": 1, "ts": "2026-10-29T16:12:03.412Z", "machine": "host-a", "project": project,
            "type": type, "severity": severity, "needs": needs,
            "subject": {"kind": "task", "id": subject} if subject else None, "cause": {"id": None, "depth": 0}, "body": b}


def sub(**kw):
    row = {"name": "s", "webhook_file": "/x", "project": kw.pop("project", "*"),
           "events": json.dumps(kw.pop("events", []))}
    for k in webhooks.JSON_FIELDS:
        if k in kw:
            row[k] = json.dumps(kw.pop(k))
    row.update(kw)
    return webhooks.effective(row)


class TestMatrix(unittest.TestCase):
    """Filtros sin estado sobre sobres hechos a mano."""

    def check(self, s, cases):
        for e, want in cases:
            with self.subTest(sub=s, env=(e["project"], e["type"], e["severity"], e["needs"], webhooks.legacy_name(e))):
                self.assertIs(webhooks.matches(s, e), want)

    def test_everything_by_default(self):
        self.check(sub(), [(env(), True), (env(project=None, type="machine.health"), True)])

    def test_projects(self):
        self.check(sub(project="p1"), [(env(), True), (env(project="p2"), False), (env(project=None), False)])
        self.check(sub(projects=["nu*", "p1"]), [(env(project="nuskills"), True), (env(), True),
                                                 (env(project="otro"), False), (env(project=None), False)])
        self.check(sub(projects=["*"]), [(env(project=None), True), (env(project="x"), True)])

    def test_types_globs_and_exclude(self):
        s = sub(types=["question.*", "approval.requested", "github.*"], exclude_types=["github.push"])
        self.check(s, [(env(type="question.opened"), True), (env(type="question.answered"), True),
                       (env(type="approval.requested"), True), (env(type="github.pr.merged"), True),
                       (env(type="github.push"), False), (env(type="task.state"), False),
                       (env(type="questions"), False)])
        self.check(sub(exclude_types=["machine.*"]), [(env(type="machine.health"), False), (env(), True)])
        self.check(sub(types=[]), [(env(type="cualquiera"), True)])          # lista vacía = todos

    def test_min_severity(self):
        s = sub(min_severity="notice")
        self.check(s, [(env(severity="info"), False), (env(severity="notice"), True), (env(severity="warn"), True),
                       (env(severity="error"), True), (env(severity=None), False)])
        self.check(sub(min_severity="error"), [(env(severity="warn"), False), (env(severity="error"), True)])

    def test_needs(self):
        s = sub(needs=["bot", "human"])
        self.check(s, [(env(needs="bot"), True), (env(needs="human"), True), (env(needs="approval"), False),
                       (env(needs=None), False)])
        self.check(sub(needs=["bot", "none"]), [(env(needs=None), True), (env(needs="bot"), True),
                                                (env(needs="human"), False)])
        self.check(sub(needs=[]), [(env(needs="approval"), True), (env(needs=None), True)])

    def test_combination(self):
        s = sub(projects=["nuskills"], types=["question.*", "approval.requested", "task.state"],
                exclude_types=["machine.health"], min_severity="notice", needs=["bot", "human"])
        ok = dict(project="nuskills", type="question.opened", severity="notice", needs="bot")
        self.check(s, [(env(**ok), True),
                       (env(**dict(ok, project="chopshop")), False),
                       (env(**dict(ok, type="batch.done")), False),
                       (env(**dict(ok, severity="info")), False),
                       (env(**dict(ok, needs="approval")), False),
                       (env(**dict(ok, type="task.state", severity="warn", needs="human")), True)])

    def test_legacy_events(self):
        s = sub(project="p1", events=["pending_question"])
        self.check(s, [(env(type="question.opened", legacy="pending_question"), True),
                       (env(type="question.opened"), True),                     # tipo nuevo sin nombre viejo: LEGACY_MAP
                       (env(type="task.state", legacy="thread_done"), False),
                       (env(type="question.opened", legacy="pending_question", project="p2"), False)])
        s = sub(events=["thread_done"])                                           # no se ensancha a todo task.state
        self.check(s, [(env(legacy="thread_done"), True), (env(legacy="thread_started"), False)])
        self.check(sub(types=["thread_*"]), [(env(legacy="thread_done"), True), (env(), False)])

    def test_validate(self):
        bad = [{"min_severity": "alta"}, {"needs": ["robot"]}, {"types": ["con espacio"]}, {"types": "x" * 200},
               {"only_changes": "sí"}, {"debounce_s": -1}, {"debounce_s": True}, {"debounce_s": 99999},
               {"secret_file": "https://x.invalid/s"}, {"secret_file": ""}, {"projects": [1]}, {"batch_window_s": 5},
               {"types": ["a"] * 40}]
        for o in bad:
            with self.subTest(o=o), self.assertRaises(webhooks.WebhookError):
                webhooks.validate(o)
        self.assertEqual(webhooks.validate({"types": "question.*, task.state"})["types"], ["question.*", "task.state"])


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conn = db.connect(os.path.join(self.tmp.name, "agent", "agent.db"))
        self.addCleanup(self.conn.close)
        self.clock = Clock()
        self.d = webhooks.Dispatcher(clock=self.clock)
        old = events.set_dispatcher(self.d)
        self.addCleanup(events.set_dispatcher, old)
        self.addCleanup(self.d.cancel)
        self.addCleanup(self.d.flush, 5)
        self.cfg = {"machine_id": "host-a", "webhook_files": {}}
        self.logs = []
        h = logging.Handler()
        h.emit = lambda rec: self.logs.append(rec.getMessage())
        root = logging.getLogger()
        root.addHandler(h)
        self.addCleanup(root.removeHandler, h)

    def file(self, name, content, mode=0o600):
        p = os.path.join(self.tmp.name, name)
        with open(p, "w") as f:
            f.write(content + "\n")
        os.chmod(p, mode)
        return p

    def hook(self, name, url=URL):
        return self.file(name + ".url", url)

    def emit(self, event, project="p1", body=None, poster=None, wait=True):
        return events.emit(self.conn, self.cfg, event, project, body, poster=poster, wait=wait)

    def deliveries(self):
        return {(r["event_seq"], r["name"]): dict(r) for r in
                self.conn.execute("SELECT event_seq,name,ok,detail,attempts,next_retry FROM deliveries")}

    def advance(self, s):
        self.clock.t += s
        self.d.pump()
        self.assertTrue(self.d.flush(5))

    def dump(self):
        return "\n".join(repr(tuple(r)) for t in ("events", "deliveries", "subscriptions", "meta")
                         for r in self.conn.execute("SELECT * FROM " + t))


class TestDeliveryV2(Base):
    def test_filters_with_poster(self):
        f = self.hook("a")
        events.subscribe(self.conn, "preguntas", f, projects=["p*"], types=["question.*"], needs=["human", "bot"])
        events.subscribe(self.conn, "errores", f, min_severity="error", exclude_types=["machine.*"])
        events.subscribe(self.conn, "todo", f)
        p = Poster()
        s1 = self.emit("pending_question", "p1", {"thread_id": "t1"}, p)          # question.opened, needs human
        s2 = self.emit("thread_failed", "p1", {"thread_id": "t1"}, p)             # task.state, error
        s3 = self.emit("question.opened", "otro", {"thread_id": "t2"}, p)
        names = {}
        for (seq, name) in self.deliveries():
            names.setdefault(seq, set()).add(name)
        self.assertEqual(names[s1], {"preguntas", "todo"})
        self.assertEqual(names[s2], {"errores", "todo"})
        self.assertEqual(names[s3], {"todo"})
        # una pregunta trae antes su task.state acompañante (attention): solo lo recibe "todo"
        self.assertEqual(names[s1 - 1], {"todo"})
        self.assertEqual(len(p.calls), 7)

    def test_headers_and_hmac(self):
        events.subscribe(self.conn, "firmado", self.hook("a"), secret_file=self.file("s.key", SECRET))
        events.subscribe(self.conn, "plano", self.hook("b", "https://hooks.example.invalid/b"))
        p = Poster(200)
        seq = self.emit("pending_question", "p1", {"thread_id": "t1"}, p)
        q = lambda url: [c for c in p.to(url) if c[1]["type"] == "question.opened"][0]   # noqa: E731
        signed, plain = q(URL), q("https://hooks.example.invalid/b")
        _url, payload, headers, data = signed
        self.assertEqual(headers["X-Chopshop-Event"], "question.opened")
        self.assertEqual(headers["X-Chopshop-Id"], payload["id"])
        self.assertEqual(headers["X-Chopshop-Delivery"], "1")
        want = "sha256=" + hmac.new(SECRET.encode(), data, hashlib.sha256).hexdigest()
        self.assertTrue(hmac.compare_digest(headers["X-Chopshop-Signature"], want))
        self.assertNotIn("X-Chopshop-Signature", plain[2])
        self.assertEqual(payload["seq"], seq)
        # el secreto nunca sale: ni en la DB, ni en el listado, ni en el cuerpo enviado, ni en logs
        everything = self.dump() + repr(events.list_subscriptions(self.conn)) + data.decode() + "\n".join(self.logs)
        self.assertNotIn(SECRET, everything)
        self.assertNotIn(URL, self.dump() + repr(events.list_subscriptions(self.conn)) + "\n".join(self.logs))
        self.assertTrue(events.list_subscriptions(self.conn)["firmado"]["signed"])
        self.assertNotIn("s.key", repr(events.list_subscriptions(self.conn)))

    def test_secret_with_open_permissions_or_missing_is_not_sent(self):
        events.subscribe(self.conn, "abierto", self.hook("a"), secret_file=self.file("s.key", SECRET, 0o644))
        events.subscribe(self.conn, "falta", self.hook("b"), secret_file=os.path.join(self.tmp.name, "nada.key"))
        p = Poster()
        seq = self.emit("x", poster=p)
        self.assertEqual(p.calls, [])
        d = self.deliveries()
        self.assertEqual(d[(seq, "abierto")]["detail"], "archivo de secreto ilegible (PermissionError)")
        self.assertEqual(d[(seq, "falta")]["detail"], "archivo de secreto ilegible (FileNotFoundError)")
        self.assertIsNone(d[(seq, "falta")]["next_retry"])                        # no se reintenta
        self.assertNotIn(SECRET, self.dump())

    def test_headers_file_adds_authorization(self):
        hfile = self.file("h.headers", "# Grok pide Authorization\n\nAuthorization: %s\nX-Tenant:  chop " % TOKEN)
        events.subscribe(self.conn, "grok", self.hook("a"), headers_file=hfile, secret_file=self.file("s.key", SECRET))
        events.subscribe(self.conn, "plano", self.hook("b", "https://hooks.example.invalid/b"))
        p = Poster(200)
        with self.assertLogs("chopshop.agent.webhooks", "INFO") as cm:
            seq = self.emit("x", poster=p)
        h = p.to(URL)[0][2]
        self.assertEqual((h["Authorization"], h["X-Tenant"]), (TOKEN, "chop"))
        self.assertEqual(h["X-Chopshop-Delivery"], "1")
        self.assertTrue(h["X-Chopshop-Signature"].startswith("sha256="))
        self.assertNotIn("Authorization", p.to("https://hooks.example.invalid/b")[0][2])
        self.assertEqual(self.deliveries()[(seq, "grok")]["ok"], 1)
        subs = events.list_subscriptions(self.conn)
        self.assertEqual((subs["grok"]["headers"], subs["plano"]["headers"]), (True, False))
        shown = repr(subs) + "\n".join(self.logs + cm.output)
        for leak in ("token-canario", URL, SECRET):
            self.assertNotIn(leak, shown + self.dump())
        self.assertNotIn("h.headers", shown)                        # la ruta solo vive en la DB

    def test_bad_headers_file_is_not_sent(self):
        cases = {"abierto": ("Authorization: %s" % TOKEN, 0o644, "PermissionError"),
                 "malo": ("Authorization %s" % TOKEN, 0o600, "ValueError"),
                 "reservado": ("Content-Type: text/plain", 0o600, "ValueError"),
                 "propio": ("X-Chopshop-Signature: sha256=00", 0o600, "ValueError"),
                 "repetido": ("Authorization: a\nauthorization: b", 0o600, "ValueError")}
        for name, (content, mode, _err) in cases.items():
            events.subscribe(self.conn, name, self.hook(name), headers_file=self.file(name + ".h", content, mode))
        events.subscribe(self.conn, "falta", self.hook("falta"), headers_file=os.path.join(self.tmp.name, "nada.h"))
        p = Poster()
        with self.assertLogs("chopshop.agent.webhooks", "WARNING") as cm:
            seq = self.emit("x", poster=p)
        self.assertEqual(p.calls, [])
        d = self.deliveries()
        for name, (_c, _m, err) in dict(cases, falta=(None, None, "FileNotFoundError")).items():
            self.assertEqual(d[(seq, name)]["detail"], "archivo de cabeceras ilegible (%s)" % err, name)
            self.assertIsNone(d[(seq, name)]["next_retry"])
        self.assertNotIn("token-canario", self.dump() + "\n".join(cm.output))

    def test_read_headers(self):
        f = self.file("ok.h", "Authorization: Bearer a:b \r\n# x\nX-Api-Key:k")
        self.assertEqual(webhooks.read_headers(f), {"Authorization": "Bearer a:b", "X-Api-Key": "k"})
        for bad in ("Mal nombre: x", "Vacio:", ": x", "Host: evil", "User-Agent: x"):
            with self.subTest(bad=bad), self.assertRaises(ValueError) as cm:
                webhooks.read_headers(self.file("bad.h", "Ok: 1\n" + bad))
            self.assertEqual(str(cm.exception).split(":")[0], "línea 2")       # solo el número, nunca el contenido
            self.assertNotIn("evil", str(cm.exception))

    def test_every_attempt_is_logged_without_url(self):
        events.subscribe(self.conn, "a", self.hook("a"), headers_file=self.file("h", "Authorization: %s" % TOKEN))
        with self.assertLogs("chopshop.agent.webhooks", "INFO") as cm:
            ok = self.emit("x", poster=Poster(204))
            rejected = self.emit("x", poster=Poster(401))
        self.assertRegex(cm.output[0], r"^INFO:chopshop\.agent\.webhooks:webhook a: seq=%d type=\S+ intento=1/4 "
                                       r"HTTP 204 \d+ms ok$" % ok)
        self.assertRegex(cm.output[1], r"^WARNING:.*webhook a: seq=%d .*intento=1/4 HTTP 401 \d+ms sin reintento$"
                         % rejected)

        def boom(url, data, timeout, headers=None):
            raise urllib.error.URLError(ConnectionRefusedError("%s %s" % (url, headers)))
        with self.assertLogs("chopshop.agent.webhooks", "INFO") as cm:
            seq = self.emit("x", poster=boom)
            for s in (2, 10, 60):
                self.advance(s)
        self.assertEqual(len(cm.output), 4)
        self.assertIn("intento=1/4 URLError/ConnectionRefusedError", cm.output[0])
        self.assertTrue(cm.output[0].endswith("reintento 2 en 2s"))
        self.assertTrue(cm.output[2].endswith("reintento 4 en 60s"))
        self.assertIn("seq=%d" % seq, cm.output[3])
        self.assertTrue(cm.output[3].endswith("reintentos agotados"))
        for leak in ("url-canario", "token-canario"):
            self.assertNotIn(leak, "\n".join(cm.output) + self.dump())

    def test_only_changes_with_debounce_logs_the_attempt(self):
        """Caso de contabo-dev: `*`, only_changes, debounce 30 s; un thread_done (task.state completed) que el receptor
        rechaza con 401 se intenta al cerrar la ventana y queda en el log (antes solo en `deliveries`)."""
        events.subscribe(self.conn, "grok-chopshop", self.hook("g"), "*", None, only_changes=True, debounce_s=30)
        p = Poster(401)
        self.emit("thread_started", "chopshop", {"thread_id": "t-plan", "title": "Plan rediseño oficina"}, p)
        self.advance(30)
        with self.assertLogs("chopshop.agent.webhooks", "INFO") as cm:
            seq = self.emit("thread_done", "chopshop", {"thread_id": "t-plan", "status": "completed"}, p)
            self.advance(29)
            self.assertEqual(len(p.calls), 1)
            self.advance(1)
        self.assertEqual([c[1]["seq"] for c in p.calls], [seq - 1, seq])
        self.assertEqual(self.deliveries()[(seq, "grok-chopshop")]["detail"], "HTTP 401")
        self.assertIn("webhook grok-chopshop: seq=%d type=task.state intento=1/4 HTTP 401" % seq,
                      [o for o in cm.output if o.startswith("WARNING")][0])

    def test_exceptions_never_leak_url_or_secret(self):
        events.subscribe(self.conn, "a", self.hook("a"), secret_file=self.file("s.key", SECRET))

        def boom(url, data, timeout, headers=None):
            raise urllib.error.URLError(ConnectionRefusedError("%s %s" % (url, headers)))
        seq = self.emit("x", poster=boom)
        d = self.deliveries()[(seq, "a")]
        self.assertEqual(d["detail"], "URLError/ConnectionRefusedError")
        self.assertNotIn(SECRET, self.dump())
        self.assertNotIn("url-canario", self.dump())

    def test_only_changes(self):
        events.subscribe(self.conn, "cambios", self.hook("a"), only_changes=True)
        events.subscribe(self.conn, "todo", self.hook("b", "https://hooks.example.invalid/b"))
        p = Poster()
        seqs = [self.emit("task.state", "p1", {"thread_id": "t1", "phase": ph, "attention": att}, p)
                for ph, att in [("running", None), ("running", None), ("waiting", "ask"), ("waiting", "ask"),
                                ("running", None)]]
        seqs.append(self.emit("task.state", "p1", {"thread_id": "t2", "phase": "running", "attention": None}, p))
        # cada pregunta trae antes un task.state (waiting, ask): el 1.º cambia (venía de running), el 2.º no
        seqs.append(self.emit("question.opened", "p1", {"thread_id": "t1"}, p))      # otros tipos no se omiten
        seqs.append(self.emit("question.opened", "p1", {"thread_id": "t1"}, p))
        got = [c[1]["seq"] for c in p.to(URL)]
        self.assertEqual(got, [seqs[0], seqs[2], seqs[4], seqs[5], seqs[6] - 1, seqs[6], seqs[7]])
        self.assertEqual(len(p.to("https://hooks.example.invalid/b")), 10)

    def test_debounce_per_subject_with_clock(self):
        events.subscribe(self.conn, "calmado", self.hook("a"), debounce_s=5)
        p = Poster()
        a1 = self.emit("task.state", "p1", {"thread_id": "t1", "phase": "running"}, p)
        self.clock.t += 1
        b1 = self.emit("task.state", "p1", {"thread_id": "t2", "phase": "running"}, p)
        self.clock.t += 1
        a2 = self.emit("task.state", "p1", {"thread_id": "t1", "phase": "waiting"}, p)
        self.advance(2)                                                            # t+4: nada vence aún
        self.assertEqual(p.calls, [])
        self.advance(1)                                                            # t+5: vence t1 (ventana desde el 1.º)
        self.assertEqual([c[1]["seq"] for c in p.calls], [a2])
        self.assertEqual(p.calls[0][1]["body"]["phase"], "waiting")
        self.advance(1)                                                            # t+6: vence t2
        self.assertEqual([c[1]["seq"] for c in p.calls], [a2, b1])
        self.assertEqual(set(self.deliveries()), {(a2, "calmado"), (b1, "calmado")})   # a1 quedó colapsado
        a3 = self.emit("task.state", "p1", {"thread_id": "t1", "phase": "done"}, p)    # ventana nueva
        self.advance(5)
        self.assertEqual(p.calls[-1][1]["seq"], a3)
        self.assertNotIn((a1, "calmado"), self.deliveries())

    def test_context_has_last_five_of_subject(self):
        events.subscribe(self.conn, "ctx", self.hook("a"), types=["question.opened"], context=True)
        events.subscribe(self.conn, "sin", self.hook("b", "https://hooks.example.invalid/b"), types=["question.opened"])
        p = Poster()
        prev = []
        for i in range(7):
            prev.append(self.emit("task.state", "p1", {"thread_id": "t1", "phase": "running", "n": i}, p))
            self.emit("task.state", "p1", {"thread_id": "t2", "phase": "waiting", "attention": "bot"}, p)
        self.emit("task.state", "otro", {"thread_id": "t1", "phase": "done"}, p)         # otro proyecto
        seq = self.emit("question.opened", "p1", {"thread_id": "t1", "summary": "¿Sí?"}, p)
        payload = p.to(URL)[0][1]
        ctx = payload["body"]["context"]
        self.assertEqual(payload["body"]["summary"], "¿Sí?")
        # los 5 previos del sujeto t1: los 4 últimos task.state + el acompañante (waiting, ask) de la pregunta
        self.assertEqual([e["seq"] for e in ctx["recent"]], prev[-4:] + [seq - 1])
        self.assertTrue(all(e["subject"]["id"] == "t1" and e["seq"] < seq for e in ctx["recent"]))
        self.assertNotIn("context", ctx["recent"][0]["body"])
        counts = ctx["project_summary"]["counts"]
        self.assertEqual((counts["tasks"], counts.get("running", 0), counts["waiting"], counts["needs_human"],
                          counts["waiting_bot"]), (2, 0, 2, 1, 1))
        self.assertNotIn("context", p.to("https://hooks.example.invalid/b")[0][1]["body"])

    def test_retries_2_10_60_recorded(self):
        events.subscribe(self.conn, "caido", self.hook("a"))
        p = Poster(lambda url, n: 503 if n < 4 else 200)
        seq = self.emit("x", poster=p)
        t0 = self.clock.t
        d = self.deliveries()[(seq, "caido")]
        self.assertEqual((d["ok"], d["detail"], d["attempts"], d["next_retry"]), (0, "HTTP 503", 1, t0 + 2))
        self.advance(1.9)
        self.assertEqual(len(p.calls), 1)
        self.advance(0.1)
        d = self.deliveries()[(seq, "caido")]
        self.assertEqual((len(p.calls), d["attempts"], d["next_retry"]), (2, 2, t0 + 12))
        self.advance(10)
        d = self.deliveries()[(seq, "caido")]
        self.assertEqual((len(p.calls), d["attempts"], d["next_retry"]), (3, 3, t0 + 72))
        self.advance(59)
        self.assertEqual(len(p.calls), 3)
        self.advance(1)
        d = self.deliveries()[(seq, "caido")]
        self.assertEqual((d["ok"], d["detail"], d["attempts"], d["next_retry"]), (1, "HTTP 200", 4, None))
        self.assertEqual([c[2]["X-Chopshop-Delivery"] for c in p.calls], ["1", "2", "3", "4"])
        self.assertEqual(len({c[1]["id"] for c in p.calls}), 1)                  # mismo sobre (idempotencia)

    def test_retries_give_up_and_4xx_is_final(self):
        events.subscribe(self.conn, "caido", self.hook("a"))
        events.subscribe(self.conn, "rechaza", self.hook("b", "https://hooks.example.invalid/b"))
        p = Poster(lambda url, n: 404 if url.endswith("/b") else ConnectionResetError("x"))
        seq = self.emit("x", poster=p)
        for s in (2, 10, 60, 600):
            self.advance(s)
        d = self.deliveries()
        self.assertEqual((d[(seq, "caido")]["attempts"], d[(seq, "caido")]["detail"]), (4, "ConnectionResetError"))
        self.assertIsNone(d[(seq, "caido")]["next_retry"])
        self.assertEqual((d[(seq, "rechaza")]["attempts"], d[(seq, "rechaza")]["detail"]), (1, "HTTP 404"))
        self.assertEqual(len(p.to(URL)), 4)
        self.assertEqual(self.d.scheduler.pending(), [])

    def test_slow_or_down_destination_does_not_delay_another(self):
        events.subscribe(self.conn, "lento", self.hook("a"))
        events.subscribe(self.conn, "caido", self.hook("c", "https://hooks.example.invalid/c"))
        events.subscribe(self.conn, "rapido", self.hook("b", "https://hooks.example.invalid/b"))
        gate, fast = threading.Event(), threading.Event()
        self.addCleanup(gate.set)

        def poster(url, data, timeout, headers=None):
            if url == URL:
                gate.wait(10)
                return 200
            if url.endswith("/c"):
                return 503
            fast.set()
            return 200
        seqs = [self.emit("x", poster=poster, wait=False) for _ in range(3)]
        self.assertTrue(fast.wait(5))
        deadline = threading.Event()
        for _ in range(50):
            d = self.deliveries()
            if all((s, "rapido") in d and (s, "caido") in d for s in seqs):
                break
            deadline.wait(0.05)
        d = self.deliveries()
        self.assertTrue(all(d[(s, "rapido")]["ok"] == 1 for s in seqs))
        self.assertTrue(all(d[(s, "caido")]["next_retry"] for s in seqs))         # reintentos programados, sin hilo
        self.assertFalse(any((s, "lento") in d for s in seqs))                    # el lento sigue en su carril
        gate.set()
        self.assertTrue(self.d.flush(5))
        self.assertTrue(all(self.deliveries()[(s, "lento")]["ok"] == 1 for s in seqs))

    def test_legacy_subscription_still_delivers(self):
        events.subscribe(self.conn, "viejo", self.hook("a"), project="p1", events=["pending_question"])
        p = Poster()
        seq = self.emit("pending_question", "p1", {"thread_id": "t1", "request_id": "rq-1"}, p)
        self.emit("thread_done", "p1", {"thread_id": "t1"}, p)
        self.emit("pending_question", "p2", {"thread_id": "t9"}, p)
        self.assertEqual(len(p.calls), 1)
        payload = p.calls[0][1]
        self.assertEqual((payload["event"], payload["machine_id"], payload["seq"]), ("pending_question", "host-a", seq))
        self.assertEqual((payload["type"], payload["body"]["request_id"]), ("question.opened", "rq-1"))
        subs = events.list_subscriptions(self.conn)["viejo"]
        self.assertEqual((subs["project"], subs["events"], subs["types"], subs["projects"]),
                         ("p1", ["pending_question"], None, ["p1"]))

    def test_old_three_argument_poster_still_works(self):
        events.subscribe(self.conn, "a", self.hook("a"), secret_file=self.file("s.key", SECRET))
        calls = []
        seq = self.emit("x", poster=lambda url, data, timeout: calls.append(url) or 200)
        self.assertEqual(calls, [URL])
        self.assertEqual(self.deliveries()[(seq, "a")]["ok"], 1)


class TestMigrationV4(unittest.TestCase):
    def test_v3_and_v2_databases_keep_subscriptions(self):
        for version in (2, 3):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as tmp:
                path = os.path.join(tmp, "agent", "agent.db")
                os.makedirs(os.path.dirname(path))
                hook = os.path.join(tmp, "a.url")
                with open(hook, "w") as f:
                    f.write(URL + "\n")
                if version == 3:                                              # v3 real: la actual sin columnas v4
                    db.connect(path).close()
                    old = sqlite3.connect(path)
                    for table, cols in db.V4_COLUMNS.items():
                        for name, _typ in cols:
                            old.execute("ALTER TABLE %s DROP COLUMN %s" % (table, name))
                    script = ""
                else:
                    old = sqlite3.connect(path)
                    script = db.SCHEMA
                old.executescript(script + "INSERT INTO subscriptions(name,webhook_file,project,events,created) "
                                  "VALUES('viejo','%s','p1','[\"pending_question\"]',1.0);"
                                  "INSERT INTO deliveries(event_seq,name,ok,detail,ts) VALUES(1,'viejo',1,'HTTP 200',1.0);"
                                  "PRAGMA user_version=%d;" % (hook, version))
                old.close()
                conn = db.connect(path)
                try:
                    self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], db.SCHEMA_VERSION)
                    cols = {r[1] for r in conn.execute("PRAGMA table_info(subscriptions)")}
                    self.assertLessEqual(set(webhooks.FIELDS), cols)
                    s = events.list_subscriptions(conn)["viejo"]
                    self.assertEqual((s["project"], s["events"], s["created"]), ("p1", ["pending_question"], 1.0))
                    r = conn.execute("SELECT attempts, detail FROM deliveries").fetchone()
                    self.assertEqual((r[0], r[1]), (None, "HTTP 200"))
                    p = Poster()
                    events.emit(conn, {"machine_id": "h"}, "pending_question", "p1", {"thread_id": "t"}, poster=p, wait=True)
                    self.assertEqual(len(p.calls), 1)
                finally:
                    events.flush()
                    conn.close()
                db.connect(path).close()                                      # reabrir una v4 no toca nada

    def test_v4_database_gets_headers_file(self):
        for version in (4, 5):                                                # 5 = oficina sin headers_file (ahora v6)
            with self.subTest(version=version), tempfile.TemporaryDirectory() as tmp:
                path = os.path.join(tmp, "agent", "agent.db")
                db.connect(path).close()
                old = sqlite3.connect(path)
                old.execute("ALTER TABLE subscriptions DROP COLUMN headers_file")
                old.execute("INSERT INTO subscriptions(name,webhook_file,created,debounce_s) VALUES('v4','/x',1.0,30)")
                old.execute("PRAGMA user_version=%d" % version)
                old.commit()
                old.close()
                conn = db.connect(path)
                try:
                    self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], db.SCHEMA_VERSION)
                    s = events.list_subscriptions(conn)["v4"]
                    self.assertEqual((s["debounce_s"], s["headers"]), (30.0, False))
                finally:
                    conn.close()


class TestApi(ServerBase):
    def setUp(self):
        super().setUp()
        self.start()
        self.sfile = os.path.join(self.tmp, "s.key")
        with open(self.sfile, "w") as f:
            f.write(SECRET + "\n")
        os.chmod(self.sfile, 0o600)

    def test_post_and_get_v2(self):
        st, body, _ = self.post("/subscriptions", {
            "name": "bot-nuskills", "webhook_file": self.wfile, "projects": ["nuskills"],
            "types": ["question.*", "approval.requested", "task.state"], "exclude_types": ["machine.health"],
            "min_severity": "notice", "needs": ["bot", "human"], "only_changes": True, "context": True, "debounce_s": 5,
            "secret_file": self.sfile, "batch_window_s": 0})
        self.assertEqual(st, 200, body)
        s = self.get("/subscriptions")[1]["subscriptions"]["bot-nuskills"]
        self.assertEqual((s["projects"], s["types"], s["min_severity"], s["needs"], s["only_changes"], s["context"],
                          s["debounce_s"], s["signed"]),
                         (["nuskills"], ["question.*", "approval.requested", "task.state"], "notice", ["bot", "human"],
                          True, True, 5.0, True))
        everything = "\n".join(self.responses) + "\n".join(self.logs)
        for leak in (self.sfile, self.wfile, SECRET, "canary-url-secreta"):
            self.assertNotIn(leak, everything)

    def test_post_headers_file(self):
        hfile = os.path.join(self.tmp, "grok.headers")
        with open(hfile, "w") as f:
            f.write("Authorization: %s\n" % TOKEN)
        os.chmod(hfile, 0o600)
        st, body, _ = self.post("/subscriptions", {"name": "grok", "webhook_file": self.wfile, "headers_file": hfile})
        self.assertEqual(st, 200, body)
        self.assertTrue(self.get("/subscriptions")[1]["subscriptions"]["grok"]["headers"])
        for content, mode in (("Authorization: %s" % TOKEN, 0o644), ("Authorization %s" % TOKEN, 0o600)):
            with open(hfile, "w") as f:
                f.write(content)
            os.chmod(hfile, mode)
            st, body, _ = self.post("/subscriptions", {"name": "otro", "webhook_file": self.wfile, "headers_file": hfile})
            self.assertEqual(st, 400, body)
        st, body, _ = self.post("/subscriptions", {"name": "otro", "webhook_file": self.wfile, "headers_file": "/no/h"})
        self.assertEqual(st, 400, body)
        everything = "\n".join(self.responses) + "\n".join(self.logs)
        for leak in ("token-canario", hfile):
            self.assertNotIn(leak, everything)

    def test_post_validation(self):
        base = {"name": "x", "webhook_file": self.wfile}
        open_secret = os.path.join(self.tmp, "abierto.key")
        with open(open_secret, "w") as f:
            f.write(SECRET)
        os.chmod(open_secret, 0o644)
        for extra in ({"min_severity": "alta"}, {"needs": ["robot"]}, {"types": "x y"}, {"debounce_s": "5"},
                      {"secret_file": "https://hooks.example.test/s"}, {"secret_file": "/no/existe"},
                      {"secret_file": open_secret}, {"batch_window_s": 10}, {"only_changes": 1}):
            with self.subTest(extra=extra):
                st, body, _ = self.post("/subscriptions", dict(base, **extra))
                self.assertEqual(st, 400, body)
        self.assertEqual(self.get("/subscriptions")[1]["subscriptions"], {})
        self.assertNotIn(SECRET, "\n".join(self.responses) + "\n".join(self.logs))


class FakeAgentClient:
    def __init__(self):
        self.calls = []

    def post(self, path, body=None, timeout=None):
        self.calls.append(("POST", path, body))
        return {"ok": True, "subscription": {"types": body.get("types"), "signed": "secret_file" in body}}

    def get(self, path, params=None, timeout=None):
        self.calls.append(("GET", path, None))
        return {"subscriptions": {"bot": {"types": ["question.*"], "signed": True, "created": 1.0}}}


class TestCli(unittest.TestCase):
    def run_cli(self, argv):
        fake = FakeAgentClient()
        old = cli._agent_client
        cli._agent_client = lambda: fake
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                rc = cli.main(argv)
        finally:
            cli._agent_client = old
        return rc, fake.calls, out.getvalue()

    def test_subscribe_v2_goes_to_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            hook, key = os.path.join(tmp, "h.url"), os.path.join(tmp, "s.key")
            for p, c in ((hook, URL), (key, SECRET)):
                with open(p, "w") as f:
                    f.write(c)
                os.chmod(p, 0o600)
            rc, calls, out = self.run_cli(["subscribe", "bot", "--project", "nuskills,chop*", "--types", "question.*,task.state",
                                           "--exclude-types", "machine.health", "--min-severity", "notice",
                                           "--needs", "bot,human", "--only-changes", "--context", "--debounce", "5",
                                           "--secret-file", key, "--webhook-file", hook])
            self.assertEqual(rc, 0)
            self.assertEqual(calls[0][:2], ("POST", "/subscriptions"))
            body = calls[0][2]
            self.assertEqual(body, {"name": "bot", "webhook_file": hook, "project": "*", "projects": ["nuskills", "chop*"],
                                    "types": ["question.*", "task.state"], "exclude_types": ["machine.health"],
                                    "min_severity": "notice", "needs": ["bot", "human"], "only_changes": True,
                                    "context": True, "debounce_s": 5.0, "secret_file": key})
            self.assertNotIn(URL, out)
            self.assertNotIn(SECRET, out)
            rc, calls, out = self.run_cli(["subscribe", "--list", "--agent"])
            self.assertEqual((rc, calls[0][:2]), (0, ("GET", "/subscriptions")))
            self.assertIn("question.*", out)

    def test_subscribe_headers_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            hook, hdrs = os.path.join(tmp, "h.url"), os.path.join(tmp, "grok.headers")
            for p, c in ((hook, URL), (hdrs, "Authorization: " + TOKEN)):
                with open(p, "w") as f:
                    f.write(c)
                os.chmod(p, 0o600)
            rc, calls, out = self.run_cli(["subscribe", "grok", "--webhook-file", hook, "--headers-file", hdrs,
                                           "--only-changes", "--debounce", "30"])
            self.assertEqual(rc, 0)
            self.assertEqual(calls[0][2], {"name": "grok", "webhook_file": hook, "project": "*", "only_changes": True,
                                           "debounce_s": 30.0, "headers_file": hdrs})
            self.assertNotIn("token-canario", out)
            rc, calls, _ = self.run_cli(["subscribe", "grok", "--webhook-file", hook, "--headers-file", "/no/h"])
            self.assertEqual((rc, calls), (1, []))

    def test_missing_file_is_an_error(self):
        rc, calls, _ = self.run_cli(["subscribe", "bot", "--types", "x", "--webhook-file", "/no/existe.url"])
        self.assertEqual((rc, calls), (1, []))


if __name__ == "__main__":
    unittest.main()
