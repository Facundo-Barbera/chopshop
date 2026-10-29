"""Pruebas de los roles permanentes (agent/roles.py, fase 6): modelo desde el perfil, despertar por cron y por sobres del bus
(polling de GitHub), lanzamiento como lote de una tarea, asiento en el escritorio (`desk.assigned reason: wake`), una sola
instancia viva por escritorio con despertar pendiente, herencia y topes. Fixture: el triage de Awesome GB despierta por cron
(lun-vie 08:30) y por issue sin `triaged`. Sin T3 ni red: lanzamiento y lectura de la tarea son falsos."""
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop import miniyaml, profile  # noqa: E402
from chopshop.agent import automations, db, events, roles as R  # noqa: E402
from test_agent_server import ServerBase  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
EXAMPLE = os.path.join(ROOT, "examples", "profiles", "awesome-gb.example.yaml")
TRIAGE = "awesome-gb/0/triage/0"


def local_ts(*ymdhm):
    return time.mktime(tuple(ymdhm) + (0, 0, 0, -1))


class Clock:
    def __init__(self, t):
        self.t = t

    def __call__(self):
        return self.t


class FakeEngine:
    """`launch_fn` + `task_fn`: lotes en memoria (como state.json)."""

    def __init__(self):
        self.items, self.tasks, self.fail = [], {}, None

    def launch(self, prof, item):
        if self.fail:
            raise RuntimeError(self.fail)
        bid = "b-%04d" % (len(self.items) + 1)
        self.items.append(item)
        self.tasks[(bid, "t-%s-1" % bid[2:])] = {"id": "t-%s-1" % bid[2:], "title": item["title"], "threadId": None,
                                                  "done": False, "status": "queued"}
        return bid, "t-%s-1" % bid[2:]

    def task(self, bid, tid):
        return self.tasks.get((bid, tid))

    def last(self):
        return self.tasks[sorted(self.tasks)[-1]]


def example_profile():
    with open(EXAMPLE, encoding="utf-8") as f:
        return miniyaml.loads(f.read())


def issue(labels=(), depth=0, number=7):
    return {"v": 1, "id": "EV-issue-%d" % number, "seq": number, "ts": "2026-11-02T09:00:00.000Z", "machine": "box",
            "project": "awesome-gb", "type": "github.issue.opened", "severity": "info", "needs": None,
            "subject": {"kind": "issue", "id": "o/r#%d" % number, "title": "Se rompe el login"},
            "cause": {"id": None, "depth": depth},
            "body": {"repo": "o/r", "action": "opened", "number": number, "title": "Se rompe el login", "labels": list(labels),
                     "url": "https://github.com/o/r/issues/%d" % number}}


class RolesBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-roles-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = db.connect(os.path.join(self.tmp, "agent.db"))
        self.addCleanup(self.conn.close)
        R.ensure_schema(self.conn)
        self.root = os.path.join(self.tmp, "automations")
        d = automations.project_dir("awesome-gb", self.root, create=True)
        os.makedirs(os.path.join(d, "roles"))
        with open(os.path.join(d, "roles", "triage.md"), "w") as f:
            f.write("Eres el triage de Awesome GB: clasifica issues nuevas.\n")
        self.prof = example_profile()
        self.eng, self.emitted = FakeEngine(), []
        self.clock = Clock(local_ts(2026, 11, 2, 8, 0))          # lunes 08:00 hora local

    def emit(self, env):
        self.emitted.append(env)
        return dict(env, id="E%d" % len(self.emitted), seq=len(self.emitted))

    def make(self, **kw):
        opts = dict(profiles_fn=lambda: [self.prof], launch_fn=self.eng.launch, task_fn=self.eng.task,
                    clock=self.clock, store={}, root=self.root)
        opts.update(kw)
        r = R.Roles(self.conn, self.emit, **opts)
        r.reload()
        return r

    def types(self):
        return [e["type"] for e in self.emitted]


class TestWake(RolesBase):
    def test_permanent_roles_from_example(self):
        rs = R.permanent_roles(self.prof)
        self.assertEqual([(r["role"], r["desks"]) for r in rs], [("triage", [TRIAGE])])
        self.assertEqual([t["type"] for t in rs[0]["triggers"]], ["schedule", "github.issue.opened", "desk.note"])

    def test_cron_wakes_once_and_launches(self):
        r = self.make()
        self.assertEqual(r.tick(), [])                                     # primera pasada: siembra
        self.clock.t = local_ts(2026, 11, 2, 8, 29)
        self.assertEqual(r.tick(), [])
        self.clock.t = local_ts(2026, 11, 2, 8, 31)
        self.assertEqual(r.tick(), [("awesome-gb", "triage", "launched")])
        self.assertEqual(r.tick(), [])                                     # no repite el mismo minuto
        item = self.eng.items[0]
        self.assertEqual((item["role"], item["desk"]), ("triage", TRIAGE))
        self.assertIn("Eres el triage de Awesome GB", item["prompt"])
        self.assertIn("No comentes", item["prompt"].replace("no comentes", "No comentes"))
        self.clock.t = local_ts(2026, 11, 7, 8, 31)                        # sábado: el cron es de lunes a viernes
        self.assertEqual(r.tick(), [])

    def test_issue_without_triaged_wakes(self):
        r = self.make()
        self.assertEqual(r.on_event(issue(["triaged"])), [])
        self.assertEqual(r.on_event(issue(depth=3)), [])                   # anti-bucles
        self.assertEqual(r.on_event(dict(issue(), project="otro")), [])
        self.assertEqual(r.on_event(issue(["bug"])), [("awesome-gb", "triage", "launched")])
        self.assertIn("github.issue.opened o/r#7 · Se rompe el login", self.eng.items[0]["prompt"])

    def test_disabled_does_nothing(self):
        r = self.make(enabled=False)
        self.assertEqual(r.on_event(issue()), [])
        self.assertEqual(r.tick(), [])
        self.assertEqual(self.eng.items, [])

    def test_note_wakes_free_desk_and_is_consumed(self):
        """Integración con notes.py: `desk.note` despierta el escritorio libre; las notas vivas van al prompt y se consumen."""
        from chopshop.agent import notes  # noqa: PLC0415
        r = self.make()
        now = self.clock()
        notes.add(self.conn, TRIAGE, "Grok · Facundo", "Prioriza pagos", None, now)
        env = {"id": "N1", "type": "desk.note", "project": "awesome-gb", "cause": {"id": None, "depth": 0},
               "body": {"desk": TRIAGE, "from": "Grok · Facundo", "text": "Prioriza pagos", "pending": 1}}
        self.assertEqual(r.on_event(env), [("awesome-gb", "triage", "launched")])
        self.assertIn("Prioriza pagos", self.eng.items[0]["prompt"])
        self.assertEqual(notes.count(self.conn, TRIAGE, now), 0)
        notes.add(self.conn, TRIAGE, "Grok · Facundo", "Y revisa el CI", None, now)  # ocupado: la nota espera en la bandeja
        self.assertEqual(r.on_event(dict(env, id="N2")), [("awesome-gb", "triage", "noted")])
        self.assertEqual(len(self.eng.items), 1)
        self.assertEqual(notes.count(self.conn, TRIAGE, now), 1)
        other = dict(env, id="N3", body=dict(env["body"], desk="awesome-gb/0/backend/0"))
        self.assertEqual(r.on_event(other), [])                              # escritorio sin rol permanente

    def test_single_instance_pending_and_rewake(self):
        r = self.make()
        r.on_event(issue(number=1))
        self.assertEqual(r.on_event(issue(number=2)), [("awesome-gb", "triage", "pending")])
        self.assertEqual(r.on_event(issue(number=3)), [("awesome-gb", "triage", "pending")])
        self.assertEqual(len(self.eng.items), 1)
        self.assertEqual(self.types(), [])                                  # el pendiente no emite sobres
        # el motor lanza el hilo -> se sienta en el escritorio
        self.eng.last().update(threadId="mcp:t1", status="launched")
        self.assertEqual(r.sync(), [(TRIAGE, "assigned")])
        assigned = [e for e in self.emitted if e["type"] == "desk.assigned"][0]["body"]
        self.assertEqual((assigned["desk"], assigned["thread_id"], assigned["reason"], assigned["role"], assigned["inheritance"]),
                         (TRIAGE, "mcp:t1", "wake", "triage", None))
        self.assertEqual(r.sync(), [])                                       # nada nuevo mientras vive
        # termina -> cierra y lanza el despertar pendiente (fusionado) con la herencia
        self.eng.last().update(done=True, t3status="completed", result="Clasifiqué 2 issues.")
        self.assertEqual(r.sync(), [(TRIAGE, "ended"), (TRIAGE, "rewake:launched")])
        p = self.eng.items[-1]["prompt"]
        for s_ in ("mcp:t1", "Clasifiqué 2 issues.", "(2)", "o/r#2", "o/r#3"):
            self.assertIn(s_, p)
        self.assertEqual(self.eng.items[-1]["title"], "[triage] despertar · pending")
        self.eng.last().update(threadId="mcp:t2")
        r.sync()
        inh = [e for e in self.emitted if e["type"] == "desk.assigned"][-1]["body"]["inheritance"]
        self.assertEqual((inh["thread_id"], inh["summary"], inh["phase"]), ("mcp:t1", "Clasifiqué 2 issues.", "done"))
        self.eng.last().update(done=True, t3status="completed")
        self.assertEqual(r.sync(), [(TRIAGE, "ended")])                     # sin pendiente: no redespierta

    def test_failed_launch_keeps_pending(self):
        r = self.make()
        r.on_event(issue(number=1))
        r.on_event(issue(number=2))                                          # pendiente
        self.eng.fail = "host desconocido"
        self.eng.last().update(done=True, status="launch_failed", last_error="T3 caído")
        self.assertEqual(r.sync(), [(TRIAGE, "failed"), (TRIAGE, "rewake:failed")])
        self.assertEqual(R.wakes(self.conn, TRIAGE, R.LIVE), [])
        self.eng.fail = None
        self.assertEqual(r.manual("awesome-gb", "triage"), "launched")
        self.assertIn("o/r#2", self.eng.items[-1]["prompt"])                # el pendiente sobrevivió al fallo

    def test_rate_limit(self):
        r = self.make(max_wakes_per_hour=2)
        for n in range(2):
            r.on_event(issue(number=n))
            self.eng.last().update(threadId="mcp:%d" % n, done=True, t3status="completed")
            r.sync()
        self.assertEqual(r.on_event(issue(number=9)), [("awesome-gb", "triage", "rate_limited")])
        self.clock.t += 3601
        self.assertEqual(r.on_event(issue(number=10)), [("awesome-gb", "triage", "launched")])

    def test_manual(self):
        r = self.make()
        self.assertEqual(r.manual("awesome-gb", "triage"), "launched")
        with self.assertRaises(R.RolesError):
            r.manual("awesome-gb", "backend")                              # sin wake: no es un rol que despierte

    def test_prompt_file_cannot_escape(self):
        self.assertIsNone(R.read_prompt("awesome-gb", "../../etc/passwd", self.root))
        self.assertIn("triage", R.read_prompt("awesome-gb", "roles/triage.md", self.root))

    def test_once_uses_bus_cursor(self):
        cfg = {"machine_id": "box"}
        r = self.make()
        events.emit_envelope(self.conn, cfg, "github.issue.opened", "awesome-gb", issue()["body"])
        r.once(events.list_after, events.last_seq)                         # DB nueva: empieza en la cabeza
        self.assertEqual(self.eng.items, [])
        events.emit_envelope(self.conn, cfg, "github.issue.opened", "awesome-gb", issue(number=9)["body"])
        self.assertEqual(r.once(events.list_after, events.last_seq), [("awesome-gb", "triage", "launched")])
        r2 = self.make()                                                    # el cursor sobrevive al reinicio
        self.assertEqual(r2.once(events.list_after, events.last_seq), [])


class TestServiceWiring(ServerBase):
    def test_roles_off_by_default(self):
        svc = self.start()
        self.assertFalse(svc.roles.enabled)
        self.assertNotIn("chopshop-roles", [t.name for t in svc.threads])

    def test_roles_once_wakes_through_bus(self):
        eng = FakeEngine()
        svc = self.start(roles={"enabled": True})
        self.assertTrue(svc.roles.enabled)
        svc.roles.profiles_fn = lambda: [example_profile()]
        svc.roles.reload()
        svc.roles.launch_fn, svc.roles.task_fn = eng.launch, eng.task
        svc.roles_once()
        svc.emit_envelope({"type": "github.issue.opened", "project": "awesome-gb", "body": issue()["body"]})
        self.assertEqual(svc.roles_once(), [("awesome-gb", "triage", "launched")])
        svc.office.profiles_fn = lambda: [example_profile()]               # integración: la oficina sienta al despertado
        svc.office.reload()
        eng.last().update(threadId="mcp:z")
        svc.roles_once()
        self.assertEqual(svc.roles.sync(), [])
        self.assertEqual(list(svc._wake_seats), ["mcp:z"])                # la oficina aún no vio su task.state
        svc.emit_envelope({"type": "task.state", "project": "awesome-gb", "subject": {"kind": "task", "id": "mcp:z"},
                           "body": {"thread_id": "mcp:z", "phase": "running", "attention": None, "settled": False,
                                    "title": "triage", "role": None}})
        svc.office_once()
        self.assertEqual(svc._wake_seats, {})
        ev = [e for e in events.list_after(self.conn, 0, 500) if e["type"] == "desk.assigned"][-1]
        self.assertEqual((ev["body"]["thread_id"], ev["body"]["reason"]), ("mcp:z", "wake"))


class TestEngineCarriesRole(unittest.TestCase):
    def test_create_batch_keeps_role_desk_wake(self):
        from test_chopshop import Env  # noqa: PLC0415

        class T(Env):
            def runTest(self):
                pass
        t = T()
        t.setUp()
        try:
            from chopshop import engine, state  # noqa: PLC0415
            t.prof("awesome-gb", "project: awesome-gb\nscratch: true\n")
            bid = engine.create_batch(profile.load("awesome-gb"), [{"title": "x", "prompt": "y", "role": "triage",
                                                                    "desk": TRIAGE, "wake": "W1"}], "host-a", 1, [])
            task = state.read()["batches"][bid]["tasks"][0]
            self.assertEqual((task["role"], task["desk"], task["wake"]), ("triage", TRIAGE, "W1"))
            self.assertEqual(R.default_task(bid, task["id"])["id"], task["id"])
        finally:
            shutil.rmtree(t.tmp, True)


if __name__ == "__main__":
    unittest.main()
