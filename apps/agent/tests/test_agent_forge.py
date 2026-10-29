"""Pruebas de la sala de máquinas en el agente: forja agnóstica (`agent/forge`), rack de Actions con luz y origen,
`listener.state` (`listeners.py`), reductor `machine_room` (fold de tests/fixtures/events/machine-room-fixture.jsonl contra su
proyección dorada, la misma que usa la app) y `next_run` de `automation.ran`. Sin red ni `gh` real (FakeGh de
test_agent_github)."""
import copy
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop.agent import automations, db, envelope, events, forge, github, listeners, machine_room, projection, service  # noqa: E402
from test_agent_github import Clock, FakeGh, base_cfg  # noqa: E402


class Gh(FakeGh):
    """FakeGh con la ruta más larga primero (`/repos/x` es prefijo de `/repos/x/actions/runs`)."""

    def __call__(self, argv, timeout=None):
        self.routes = dict(sorted(self.routes.items(), key=lambda kv: -len(kv[0])))
        return super().__call__(argv, timeout)

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "events")
MR_FIXTURE = os.path.join(FIX, "machine-room-fixture.jsonl")
MR_GOLDEN = os.path.join(FIX, "machine-room-fixture.state.json")
R = "acme/widget"
RUNS = "/repos/%s/actions/runs" % R
REPO = "/repos/%s" % R


def gh_run(rid, status="completed", conclusion="success", event="push", actor="alice", branch="main", name="ci",
           created="2026-10-29T16:00:00Z", updated=None, title=None):
    return {"id": rid, "name": name, "path": ".github/workflows/%s.yml" % name, "display_title": title or "run %d" % rid,
            "status": status, "conclusion": conclusion, "event": event, "actor": {"login": actor},
            "triggering_actor": {"login": actor}, "head_branch": branch, "head_sha": "%040x" % rid,
            "html_url": "https://github.com/%s/actions/runs/%d" % (R, rid), "created_at": created,
            "updated_at": updated or created}


def load_mr():
    with open(MR_FIXTURE, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


# ---------------------------------------------------------------- funciones puras

class TestLight(unittest.TestCase):
    def r(self, rid, status="completed", conclusion="success", branch="main", wf="ci", created="2026-10-29T16:00:00Z"):
        return {"run_id": str(rid), "status": status, "conclusion": conclusion, "head_branch": branch, "workflow": wf,
                "created_at": created}

    def test_table(self):
        cases = [
            ("sin datos", [], (), None, ("gray", None)),
            ("error del proveedor", [self.r(1)], (), "rate_limit", ("gray", "success")),
            ("verde", [self.r(1)], (), None, ("green", "success")),
            ("en curso", [self.r(1), self.r(2, "in_progress", None, "be/x")], (), None, ("amber", "success")),
            ("en cola en la por defecto", [self.r(1, "queued", None)], (), None, ("amber", "pending")),
            ("último de la por defecto fallido",
             [self.r(1, created="2026-10-29T15:00:00Z"), self.r(2, conclusion="failure", created="2026-10-29T16:00:00Z")], (), None,
             ("red", "failure")),
            ("arreglado después", [self.r(1, conclusion="failure", created="2026-10-29T15:00:00Z"), self.r(2)], (), None,
             ("green", "success")),
            ("otro workflow fallido", [self.r(1), self.r(2, conclusion="failure", wf="docs")], (), None, ("red", "failure")),
            ("rojo gana a ámbar", [self.r(1, conclusion="failure"), self.r(2, "in_progress", None, "be/x")], (), None,
             ("red", "failure")),
            ("rama de feature fallida no pinta rojo", [self.r(1), self.r(2, conclusion="failure", branch="be/x")], (), None,
             ("green", "success")),
            ("PR con CI rojo", [self.r(1)], ("success", "failure"), None, ("red", "success")),
            ("solo PRs verdes", [], ("success",), None, ("green", None)),
        ]
        for name, runs, pr_ci, err, want in cases:
            self.assertEqual(forge.light(runs, "main", pr_ci, err), want, name)


class TestOrigin(unittest.TestCase):
    TH = [{"thread_id": "mcp:b7", "branch": "be/login", "title": "[be] login", "role": "backend", "desk": "awesome-gb/0/backend/0"},
          {"thread_id": "mcp:z1", "branch": "main", "title": "en main"}]
    DISP = [{"id": "01X", "nonce": "n-7f3a", "repo": "Acme/Widget", "workflow": "docs.yml", "ref": "main", "ts": 1000.0,
             "automation": "docs-sync"},
            {"id": "01Y", "repo": "acme/widget", "workflow": "ci.yml", "ref": "main", "ts": 2000.0}]
    ACT = {"grok-fb": {"kind": "bot", "label": "Grok · Facundo"}, "jm": {"kind": "human", "label": "Juan Manuel"}}

    def o(self, claimed=(), **run):
        base = {"run_id": "1", "workflow": "ci", "workflow_path": ".github/workflows/ci.yml", "event": "push", "actor": None,
                "head_branch": "main", "created_at": envelope.iso(1010)}
        base.update(run)
        return forge.origin(base, R, self.TH, self.DISP, self.ACT, "main", claimed)

    def test_priority(self):
        self.assertEqual(self.o(head_branch="be/login", actor="grok-fb"),
                         {"kind": "thread", "id": "mcp:b7", "label": "backend · awesome-gb/0/backend/0"})
        # la rama por defecto nunca se atribuye a un hilo
        self.assertEqual(self.o(actor="jm")["kind"], "human")
        self.assertEqual(self.o(actor="jm")["label"], "Juan Manuel")
        # nonce en el título del run
        self.assertEqual(self.o(event="workflow_dispatch", title="docs n-7f3a", workflow="docs", actor="grok-fb"),
                         {"kind": "automation", "id": "n-7f3a", "label": "docs-sync · docs.yml"})
        # sin nonce: mismo workflow (archivo), ref y ventana de tiempo
        self.assertEqual(self.o(event="workflow_dispatch", created_at=envelope.iso(2030))["kind"], "automation")
        self.assertEqual(self.o(event="workflow_dispatch", created_at=envelope.iso(2030))["id"], "01Y")
        # fuera de la ventana o ya reclamado -> sigue la cadena
        self.assertEqual(self.o(event="workflow_dispatch", actor="grok-fb", created_at=envelope.iso(9000))["kind"], "bot")
        self.assertEqual(self.o(claimed={"01Y"}, event="workflow_dispatch", created_at=envelope.iso(2030))["kind"], "unknown")
        self.assertEqual(self.o(event="schedule", actor="alice")["kind"], "schedule")
        self.assertEqual(self.o(actor="dependabot[bot]")["kind"], "bot")
        self.assertEqual(self.o(), {"kind": "unknown", "id": None, "label": None})
        self.assertEqual(self.o(head_branch="be/login")["kind"], "thread")
        self.assertEqual(self.o(head_branch="otra", actor="alice"), {"kind": "human", "id": "alice", "label": "alice"})

    def test_origin_kinds_valid(self):
        for run in ({"head_branch": "be/login"}, {"event": "schedule"}, {"actor": "x"}, {}):
            self.assertIn(self.o(**run)["kind"], envelope.ORIGIN_KINDS)

    def test_keep(self):
        runs = [{"run_id": str(i), "status": "completed", "updated_at": "2026-10-29T15:%02d:00Z" % i} for i in range(10)]
        runs.append({"run_id": "x", "status": "queued", "updated_at": None})
        self.assertEqual([r["run_id"] for r in forge.keep(runs)], ["5", "6", "7", "8", "9", "x"])

    def test_map_run(self):
        m = github.map_run(gh_run(9, status="waiting", conclusion=None))
        self.assertEqual((m["run_id"], m["status"], m["workflow"], m["workflow_path"], m["actor"]),
                         ("9", "queued", "ci", ".github/workflows/ci.yml", "alice"))
        self.assertIsNone(github.map_run({"name": "sin id"}))


# ---------------------------------------------------------------- rack

class RackBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-forge-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = db.connect(os.path.join(self.tmp, "agent.db"))
        self.addCleanup(self.conn.close)
        self.cfg = {"machine_id": "host-a", "github": {"enabled": True, "repos": [], "interval_s": 45, "ci": False}}
        self.gh, self.clock, self.emitted = Gh(), Clock(), []
        self.profiles = [{"project": "widget", "repo": "Acme/Widget",
                          "rack": {"repos": [{"provider": "github", "repo": "Acme/Widget", "kind": "main"},
                                             {"provider": "gitlab", "repo": "acme/docs", "kind": "docs", "label": "Docs"}],
                                   "actors": {"grok-fb": {"kind": "bot", "label": "Grok · Facundo"}}}}]
        self.gh.set(REPO, json.dumps({"default_branch": "main", "html_url": "https://github.com/Acme/Widget"}), '"r1"')
        self.prov = github.GitHubProvider(self.conn, self.cfg, self.emit, runner=self.gh, clock=self.clock,
                                          projects_fn=lambda: {})
        self.rack = forge.Rack(self.conn, self.cfg, self.emit, {"github": self.prov}, clock=self.clock,
                               profiles_fn=lambda: copy.deepcopy(self.profiles))

    def emit(self, event, project, body):
        json.dumps(body)
        self.emitted.append((event, project, body))

    def set_runs(self, runs, etag):
        self.gh.set(RUNS, json.dumps({"total_count": len(runs), "workflow_runs": runs}), etag)

    def of(self, typ):
        return [b for t, _p, b in self.emitted if t == typ]


class TestRack(RackBase):
    def test_entries(self):
        cfg = dict(self.cfg, github=dict(self.cfg["github"], repos=["Acme/Widget", "Acme/Other"]))
        ents = forge.rack_entries(cfg, self.profiles)
        self.assertEqual([(e["provider"], e["repo"], e["project"], e["kind"]) for e in ents],
                         [("github", "Acme/Widget", "widget", "main"), ("gitlab", "acme/docs", "widget", "docs"),
                          ("github", "acme/other", None, "main")])

    def test_seed_change_and_304(self):
        runs = [gh_run(100 + i, updated="2026-10-29T15:%02d:00Z" % i) for i in range(8)]
        runs.append(gh_run(200, status="in_progress", conclusion=None, branch="be/x", updated="2026-10-29T16:00:00Z"))
        self.set_runs(list(reversed(runs)), '"a"')
        self.rack.poll_once()
        got = self.of("forge.run.state")
        self.assertEqual([b["run_id"] for b in got], ["103", "104", "105", "106", "107", "200"])   # viejo -> nuevo
        self.assertTrue(all(b["provider"] == "github" and b["project"] == "widget" for b in got))
        repo_states = self.of("forge.repo.state")
        self.assertEqual([(b["repo"], b["light"]) for b in repo_states],
                         [("Acme/Widget", "amber"), ("acme/docs", "gray")])
        self.assertEqual(repo_states[0]["default_branch"], "main")
        self.assertEqual(repo_states[1]["error"], "proveedor no soportado")
        for b in got + repo_states:
            env = envelope.build("forge.run.state" if "run_id" in b else "forge.repo.state", "widget", b, machine="m")
            envelope.validate(env)
        # sin cambios: 304, nada nuevo
        self.emitted.clear()
        self.rack.poll_once()
        self.assertEqual(self.emitted, [])
        self.assertIn('If-None-Match: "a"', self.gh.calls[-1])
        # el run en curso termina mal en la rama por defecto -> solo ese run y la luz roja
        runs[-1] = gh_run(200, conclusion="failure", branch="main", updated="2026-10-29T16:05:00Z", created="2026-10-29T16:01:00Z")
        self.set_runs(list(reversed(runs)), '"b"')
        self.rack.poll_once()
        self.assertEqual([(b["run_id"], b["conclusion"]) for b in self.of("forge.run.state")], [("200", "failure")])
        self.assertEqual([b["light"] for b in self.of("forge.repo.state")], ["red"])

    def test_origins_from_threads_dispatch_and_actors(self):
        self.conn.execute("INSERT INTO t3_threads(thread_id, title, branch, updated) VALUES('mcp:b7','[be] login','be/login',1)")
        events.emit(self.conn, self.cfg, "forge.dispatch", "widget",
                    {"provider": "github", "repo": "Acme/Widget", "workflow": "docs.yml", "ref": "main", "nonce": "n-1",
                     "automation": "docs-sync"}, ts=self.clock() - 30)
        self.set_runs([
            gh_run(3, event="workflow_dispatch", name="docs", title="docs n-1", actor="grok-fb", created=envelope.iso(self.clock())),
            gh_run(2, branch="be/login", actor="alice"),
            gh_run(1, event="push", actor="grok-fb"),
        ], '"o"')
        self.rack.poll_once()
        orig = {b["run_id"]: b["origin"] for b in self.of("forge.run.state")}
        self.assertEqual(orig["1"], {"kind": "bot", "id": "grok-fb", "label": "Grok · Facundo"})
        self.assertEqual(orig["2"], {"kind": "thread", "id": "mcp:b7", "label": "[be] login"})
        self.assertEqual(orig["3"], {"kind": "automation", "id": "n-1", "label": "docs-sync · docs.yml"})
        # el origen de hilo/automatización es estable aunque el hilo desaparezca
        self.conn.execute("DELETE FROM t3_threads")
        self.set_runs([gh_run(2, branch="be/login", actor="alice", updated="2026-10-29T17:00:00Z")], '"o2"')
        self.emitted.clear()
        self.rack.poll_once()
        self.assertEqual(self.of("forge.run.state")[0]["origin"]["kind"], "thread")

    def test_rate_limit_grays_out_and_recovers(self):
        self.set_runs([gh_run(1)], '"a"')
        self.rack.poll_once()
        self.assertEqual(self.of("forge.repo.state")[0]["light"], "green")
        self.emitted.clear()
        self.gh.fail = [(403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(int(self.clock()) + 120)})]
        self.clock.t += 4000                                   # fuerza releer /repos
        self.rack.poll_once()
        st = [b for b in self.of("forge.repo.state") if b["repo"] == "Acme/Widget"]
        self.assertEqual((st[0]["light"], st[0]["error"]), ("gray", "rate_limit"))
        self.assertEqual([b["state"] for b in self.of("machine.health")], ["degraded"])
        self.assertTrue(self.prov.in_backoff())
        self.emitted.clear()
        self.rack.poll_once()                                  # en backoff: no llama ni reemite
        self.assertEqual(self.emitted, [])
        self.clock.t += 200
        self.prov.poll_events()                                # pasada completa de eventos: recupera
        self.rack.poll_once()
        self.assertEqual([b["light"] for b in self.of("forge.repo.state") if b["repo"] == "Acme/Widget"], ["green"])

    def test_no_secrets(self):
        self.set_runs([gh_run(1, title="token ghp_abcdefghijklmnopqrstuvwxyz0123")], '"s"')
        self.rack.poll_once()
        self.assertNotIn("ghp_", json.dumps(self.emitted))


# ---------------------------------------------------------------- listeners

class TestListeners(unittest.TestCase):
    def test_transitions_and_heartbeat(self):
        out, clock = [], Clock()
        ls = listeners.Listeners(lambda *a: out.append(a) or len(out), clock, heartbeat=600)
        self.assertEqual(ls.report("t3"), 1)
        self.assertIsNone(ls.report("t3"))                     # sin cambios
        self.assertIsNone(ls.report("legacy"))                 # hilo interno sin nombre público
        clock.t += 10
        ls.report("t3", "down", "T3Error: caído", 30)
        clock.t += 10
        ls.report("t3", "down", "T3Error: caído", 60)          # mismo estado y error: no emite
        clock.t += 700
        ls.report("t3", "down", "T3Error: caído", 60)          # latido
        ls.report("github", "degraded", "rate_limit", 90)
        names = [(b["name"], b["state"], b["backoff_s"]) for _t, _p, b in out]
        self.assertEqual(names, [("t3watch", "ok", 0), ("t3watch", "down", 30), ("t3watch", "down", 60), ("forge", "degraded", 90)])
        last = out[2][2]
        self.assertEqual(last["last_ok"], envelope.iso(Clock().t))
        for t, p, b in out:
            envelope.validate(envelope.build(t, p, b, machine="m"))


# ---------------------------------------------------------------- reductor

class TestMachineRoomProjection(unittest.TestCase):
    def test_fold_matches_golden(self):
        """fold(machine-room-fixture.jsonl) == machine-room-fixture.state.json (CHOPSHOP_UPDATE_GOLDEN=1 lo regenera; la app usa el mismo)."""
        envs = load_mr()
        for e in envs:
            envelope.validate(e)
        st = projection.fold(envs, "contabo-dev")
        text = json.dumps(st["machine_room"], sort_keys=True, indent=2, ensure_ascii=False) + "\n"
        if os.environ.get("CHOPSHOP_UPDATE_GOLDEN") == "1":
            with open(MR_GOLDEN, "w", encoding="utf-8") as f:
                f.write(text)
        with open(MR_GOLDEN, encoding="utf-8") as f:
            self.assertEqual(f.read(), text)

    def test_rules(self):
        st = projection.fold(load_mr(), "contabo-dev")
        mr = st["machine_room"]
        self.assertEqual([(l["name"], l["state"]) for l in mr["listeners"]], [("forge", "ok"), ("t3watch", "ok")])
        self.assertEqual([(m["project"], m["kind"], m["repo"], m["light"]) for m in mr["rack"]],
                         [("awesome-gb", "main", "<org>/<repo-principal>", "amber"),
                          ("awesome-gb", "docs", "<org>/<engine-cx>", "red"),
                          ("chopshop", "main", "facundo-barbera/chopshop", "gray")])
        main = mr["rack"][0]
        done = [r for r in main["runs"] if r["status"] == "completed"]
        self.assertEqual(len(done), 5)
        self.assertEqual({r["run_id"] for r in main["runs"]}, {"104", "105", "106", "107", "200", "201"})
        self.assertNotIn("provider", main["runs"][0])
        self.assertEqual(mr["rack"][1]["label"], "Engine CX")              # el repo.state completa el módulo creado en gris
        self.assertEqual([(a["name"], a["exit"], a["severity"]) for a in mr["automations"]], [("docs-sync", 1, "error")])
        self.assertEqual(mr["automations"][0]["next_run"], "2026-10-30T07:30:00.000Z")
        # idempotente y por prefijos
        envs = load_mr()
        self.assertEqual(projection.fold(envs + envs, "contabo-dev"), st)
        self.assertEqual(projection.fold(envs[10:], "contabo-dev", projection.fold(envs[:10], "contabo-dev")), st)
        # la sala de máquinas no abre atención
        self.assertTrue(all(not p["attention"] for p in st["projects"]))
        # vista de un proyecto: su rack y sus automatizaciones
        f = projection.filter_project(st, "chopshop")["machine_room"]
        self.assertEqual(([m["repo"] for m in f["rack"]], f["automations"], len(f["listeners"])),
                         (["facundo-barbera/chopshop"], [], 2))

    def test_subscriptions_live(self):
        tmp = tempfile.mkdtemp(prefix="chopshop-mr-")
        self.addCleanup(shutil.rmtree, tmp, True)
        conn = db.connect(os.path.join(tmp, "agent.db"))
        self.addCleanup(conn.close)
        conn.execute("INSERT INTO subscriptions(name, webhook_file, created, secret_file) VALUES('bots','/x/hook',1,'/x/secret')")
        conn.execute("INSERT INTO subscriptions(name, webhook_file, created) VALUES('chat','/x/hook2',1)")
        conn.execute("INSERT INTO deliveries(event_seq,name,ok,detail,ts) VALUES(1,'bots',1,'204',100)")
        conn.execute("INSERT INTO deliveries(event_seq,name,ok,detail,ts) VALUES(2,'chat',0,'HTTP 500 https://hooks.example/abc',200)")
        subs = machine_room.subscriptions(conn)
        self.assertEqual(subs[0], {"name": "bots", "last_ok": envelope.iso(100), "last_error": None, "last_error_at": None,
                                   "signed": True})
        self.assertEqual((subs[1]["last_error"], subs[1]["signed"]), ("HTTP 500 [url]", False))
        st = projection.Projector(conn, {"machine_id": "m"}).current()
        self.assertEqual([s["name"] for s in st["machine_room"]["subscriptions"]], ["bots", "chat"])
        self.assertEqual(projection.state(conn, {"machine_id": "m"})["machine_room"]["subscriptions"], [])  # fold puro


# ---------------------------------------------------------------- automatizaciones y servicio

class TestNextRun(unittest.TestCase):
    def test_every_and_cron(self):
        s = {"project": "p", "name": "a", "on": [{"type": "schedule", "_every": 600, "_cron": None}]}
        self.assertEqual(automations.next_run(s, {"sched:p:a:0": 1000.0}, 1200.0), 1600.0)
        self.assertEqual(automations.next_run(s, {}, 1200.0), 1800.0)
        c = {"project": "p", "name": "a", "on": [{"type": "schedule", "_every": None,
                                                  "_cron": automations.parse_cron("30 8 * * *")}]}
        now = envelope.epoch("2026-10-29T12:00:00Z")
        nxt = automations.next_run(c, {}, now)                 # cron en hora local de la box
        self.assertTrue(0 < nxt - now <= 86400)
        self.assertEqual(time.localtime(nxt)[3:6], (8, 30, 0))
        self.assertIsNone(automations.next_run({"project": "p", "name": "a", "on": [{"type": "manual"}]}, {}, now))


class TestService(RackBase):
    def test_forge_once_and_listener_state(self):
        tmp = tempfile.mkdtemp(prefix="chopshop-svc-")
        self.addCleanup(shutil.rmtree, tmp, True)
        cfg = base_cfg(tmp, github={"enabled": True, "repos": [], "interval_s": 45, "ci": False})
        svc = service.AgentService(cfg, gh_runner=self.gh, gh_projects_fn=lambda: {}, clock=self.clock,
                                   rack_profiles_fn=lambda: copy.deepcopy(self.profiles))
        self.addCleanup(svc.stop)
        self.assertIsInstance(svc.github, github.GitHubProvider)
        self.set_runs([gh_run(1)], '"a"')
        res = svc.forge_once()
        self.assertEqual(res["rack"]["repos"], 2)
        svc._listener("github", res)
        svc._listener("t3", {"reachable": False, "backoff": 30})
        rows = {r["type"]: db.jload(r["body"]) for r in svc.conn.execute("SELECT type, body FROM events")}
        self.assertEqual(rows["forge.run.state"]["run_id"], "1")
        st = svc.app.projector.current()
        self.assertEqual([(l["name"], l["state"]) for l in st["machine_room"]["listeners"]], [("forge", "ok"), ("t3watch", "down")])
        self.assertEqual([m["light"] for m in st["machine_room"]["rack"]], ["green", "gray"])
        self.assertEqual(st["api_version"], 3)


if __name__ == "__main__":
    unittest.main()
