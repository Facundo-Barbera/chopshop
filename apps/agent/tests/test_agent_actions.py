"""Pruebas de chopshop.agent.actions: runs de GitHub Actions con disparador y origen (hilo, automatización, bot, cron,
persona), `forge.run.state` validado, 304 con reatribución, poda de lo publicado, origen pegajoso, repos de `rack.repos` e
integración con el servicio. Sin red ni `gh` real: el `FakeGh` de test_agent_github."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import settings  # noqa: E402
from chopshop.agent import actions, db, envelope, service  # noqa: E402
from test_agent_github import Clock, FakeGh, base_cfg  # noqa: E402

REPO = "Acme/Widget"
R = "acme/widget"
RUNS = "/repos/%s/actions/runs" % R
SHA_THREAD = "a" * 40
T0 = "2027-01-15T08:00:00Z"            # = Clock() por defecto (1_800_000_000)


def run(id, event="push", status="completed", conclusion="success", branch="feature/x", sha="b" * 40, actor="octo",
        name="ci", title="commit", created=T0, updated=T0, path=".github/workflows/ci.yml", triggering=None):
    return {"id": id, "name": name, "path": path, "workflow_id": 77, "display_title": title, "event": event,
            "status": status, "conclusion": conclusion, "head_branch": branch, "head_sha": sha, "run_attempt": 1,
            "actor": {"login": actor} if actor else None, "triggering_actor": {"login": triggering or actor} if actor else None,
            "html_url": "https://github.com/Acme/Widget/actions/runs/%d" % id, "created_at": created, "updated_at": updated}


PROFILE = {"project": "widget", "repo": REPO,
           "rack": {"repos": [{"provider": "github", "repo": REPO, "kind": "main"}],
                    "actors": {"grok-fb": {"kind": "bot", "label": "Grok · Facundo"},
                               "juanma": {"kind": "human", "label": "Juan Manuel"}}}}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-actions-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = db.connect(os.path.join(self.tmp, "agent.db"))
        self.addCleanup(self.conn.close)
        self.cfg = {"machine_id": "host-a", "github": {"enabled": True, "repos": [], "interval_s": 45}}
        self.gh = FakeGh()
        self.gh.set("/repos/%s" % R, json.dumps({"default_branch": "trunk"}), '"r"')
        self.clock = Clock()
        self.emitted = []
        self.heads = {}

    def emit(self, type, project, body, severity=None):
        env = envelope.build(type, project, json.loads(json.dumps(body)), severity, machine="host-a")
        envelope.validate(env)                                 # cumple el contrato v3
        self.emitted.append(env)

    def poller(self, profiles=None):
        return actions.ActionsPoller(self.conn, self.cfg, self.emit, runner=self.gh, clock=self.clock,
                                     profiles_fn=lambda: {"widget": PROFILE} if profiles is None else profiles,
                                     head_fn=lambda wt: self.heads.get(wt))

    def runs(self, items, etag, **over):
        items = [dict(r, **over) for r in items]
        # `/repos/acme/widget` es prefijo de la ruta de runs: la de runs va primero para que FakeGh la elija
        self.gh.routes = dict([(RUNS, (json.dumps({"workflow_runs": items}), etag))] +
                              [(k, v) for k, v in self.gh.routes.items() if k != RUNS])

    def thread(self, tid, branch=None, worktree=None, project="widget", title="hilo", settled=0, extra=None):
        self.conn.execute("INSERT OR REPLACE INTO t3_threads(thread_id, project, title, status, settled, worktree, branch,"
                          " last_seen, extra) VALUES(?,?,?,?,?,?,?,?,?)",
                          (tid, project, title, "running", settled, worktree, branch, self.clock(),
                           json.dumps(extra) if extra else None))

    def dispatch(self, nonce, workflow="ci.yml", ref="trunk", automation="nightly", ts=None):
        from chopshop.agent import events
        events.emit_envelope(self.conn, self.cfg, "forge.dispatch", "widget",
                             {"provider": "github", "repo": REPO, "workflow": workflow, "ref": ref, "nonce": nonce,
                              "inputs": {"chopshop_nonce": nonce}, "automation": automation},
                             ts=self.clock() - 30 if ts is None else ts)

    def origins(self):
        return {e["body"]["run_id"]: (e["body"]["origin"]["kind"], e["body"]["origin"]["label"]) for e in self.emitted}


class TestAtribucion(Base):
    def test_cada_origen(self):
        self.thread("mcp:b7", branch="be/login", title="[be] login", extra={"role": "backend"})
        self.thread("mcp:c3", worktree="/wt/c3")
        self.heads["/wt/c3"] = SHA_THREAD
        self.dispatch("n-7f3a")
        self.dispatch("n-other", workflow="docs.yml")
        self.runs([
            run(1, branch="be/login"),                                                  # hilo por rama
            run(2, branch="trunk", sha=SHA_THREAD),                                     # hilo por sha (push a trunk)
            run(3, event="workflow_dispatch", branch="trunk", title="ci n-7f3a"),       # automatización por nonce
            run(4, event="workflow_dispatch", branch="trunk", name="docs", path=".github/workflows/docs.yml"),  # por ventana
            run(5, branch="trunk", actor="grok-fb"),                                    # bot declarado
            run(6, event="pull_request", branch="deps", actor="dependabot[bot]"),       # cuenta [bot]
            run(7, event="schedule", branch="trunk", actor="grok-fb"),                  # cron (el actor no cuenta)
            run(8, branch="trunk", actor="juanma"),                                     # persona declarada
            run(9, branch="trunk", actor=None),                                         # nadie
            run(10, event="schedule", branch="trunk", sha=SHA_THREAD),                  # un cron no es del hilo
        ], '"e1"', status="in_progress")
        res = self.poller().poll_once()
        self.assertEqual(res["emitted"], 10)
        o = self.origins()
        self.assertEqual(o["1"], ("thread", "backend"))
        self.assertEqual(o["2"][0], "thread")
        self.assertEqual(o["3"], ("automation", "nightly · ci.yml"))
        self.assertEqual(o["4"], ("automation", "nightly · docs.yml"))
        self.assertEqual(o["5"], ("bot", "Grok · Facundo"))
        self.assertEqual(o["6"], ("bot", "dependabot[bot]"))
        self.assertEqual(o["7"][0], "schedule")
        self.assertEqual(o["8"], ("human", "Juan Manuel"))
        self.assertEqual(o["9"], ("unknown", None))
        self.assertEqual(o["10"][0], "schedule")
        by = {e["body"]["run_id"]: e for e in self.emitted}
        b = by["1"]["body"]
        self.assertEqual((b["provider"], b["repo"], b["project"], b["event"], b["workflow"], b["origin"]["id"]),
                         ("github", REPO, "widget", "push", "ci", "mcp:b7"))
        self.assertEqual(by["1"]["subject"], {"kind": "run", "id": "github:%s#1" % REPO, "title": "ci",
                                              "url": "https://github.com/Acme/Widget/actions/runs/1"})
        self.assertEqual(by["3"]["body"]["origin"]["id"], "n-7f3a")

    def test_rama_por_defecto_no_es_de_ningun_hilo(self):
        self.thread("mcp:m", branch="trunk")
        self.thread("mcp:x", branch="main")
        self.runs([run(1, branch="trunk"), run(2, branch="main")], '"e1"')
        self.poller().poll_once()
        self.assertEqual({k: v[0] for k, v in self.origins().items()}, {"1": "human", "2": "human"})

    def test_dispatch_fuera_de_ventana_o_ya_reclamado(self):
        self.dispatch("n-1", ts=self.clock() - 30)
        self.runs([run(1, event="workflow_dispatch", branch="trunk"),
                   run(2, event="workflow_dispatch", branch="trunk", created="2027-01-15T08:00:05Z"),
                   run(3, event="workflow_dispatch", branch="trunk", created="2027-01-15T09:00:00Z")], '"e1"')
        self.poller().poll_once()
        self.assertEqual({k: v[0] for k, v in self.origins().items()}, {"1": "automation", "2": "human", "3": "human"})

    def test_hilo_con_escritorio_y_rol(self):
        self.conn.execute("CREATE TABLE desk_occupancy(desk_id TEXT, thread_id TEXT, since REAL, until REAL, reason TEXT,"
                          " inheritance TEXT)")
        self.conn.execute("INSERT INTO desk_occupancy VALUES('widget/0/backend/0','mcp:b7',0,NULL,'start',NULL)")
        self.thread("mcp:b7", branch="be/login", extra={"role": "backend"})
        self.runs([run(1, branch="be/login")], '"e1"')
        self.poller().poll_once()
        self.assertEqual(self.origins()["1"], ("thread", "backend · widget/0/backend/0"))


class TestPolling(Base):
    def test_304_no_emite_y_reatribuye_en_curso(self):
        self.runs([run(1, status="in_progress", conclusion=None, branch="be/late"), run(2, branch="be/late")], '"e1"')
        p = self.poller()
        p.poll_once()
        self.assertEqual({k: v[0] for k, v in self.origins().items()}, {"1": "human", "2": "human"})
        self.emitted.clear()
        p.poll_once()
        self.assertIn('If-None-Match: "e1"', [a for c in self.gh.calls for a in c if c[-1].startswith(RUNS)])
        self.assertEqual(self.emitted, [])
        self.thread("mcp:late", branch="be/late")                     # el hilo aparece después del push
        p.poll_once()
        self.assertEqual({k: v[0] for k, v in self.origins().items()}, {"1": "thread"})   # el completado no se toca

    def test_cambio_de_estado_y_fallo_con_warn(self):
        self.runs([run(1, status="in_progress", conclusion=None)], '"e1"')
        p = self.poller()
        p.poll_once()
        self.runs([run(1, conclusion="failure", updated="2027-01-15T08:05:00Z")], '"e2"')
        p.poll_once()
        self.assertEqual([(e["body"]["status"], e["severity"]) for e in self.emitted],
                         [("in_progress", "info"), ("completed", "warn")])
        self.runs([run(1, conclusion="failure", updated="2027-01-15T08:05:00Z")], '"e3"')   # misma foto, ETag nuevo
        p.poll_once()
        self.assertEqual(len(self.emitted), 2)

    def test_origen_pegajoso_y_reinicio_sin_reemitir(self):
        self.thread("mcp:c3", worktree="/wt/c3")
        self.heads["/wt/c3"] = SHA_THREAD
        self.runs([run(1, status="queued", conclusion=None, branch="trunk", sha=SHA_THREAD)], '"e1"')
        self.poller().poll_once()
        self.heads["/wt/c3"] = "c" * 40                                # el worktree avanzó
        self.runs([run(1, branch="trunk", sha=SHA_THREAD, updated="2027-01-15T08:03:00Z")], '"e2"')
        self.poller().poll_once()
        self.assertEqual([e["body"]["origin"]["kind"] for e in self.emitted], ["thread", "thread"])
        self.poller().poll_once()                                     # proceso nuevo, misma DB
        self.assertEqual(len(self.emitted), 2)

    def test_solo_se_publican_en_curso_y_cinco_completados(self):
        items = [run(i, updated="2027-01-15T08:%02d:00Z" % i) for i in range(1, 9)]
        items.append(run(20, status="in_progress", conclusion=None))
        self.runs(items, '"e1"')
        self.poller().poll_once()
        self.assertEqual(sorted(int(e["body"]["run_id"]) for e in self.emitted), [4, 5, 6, 7, 8, 20])
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM forge_runs").fetchone()[0], 9)

    def test_repos_de_config_y_rack_sin_duplicar(self):
        self.cfg["github"]["repos"] = ["acme/widget", "acme/otro"]
        got = actions.repos_for(self.cfg, {"widget": PROFILE})
        self.assertEqual(got, [(REPO, "widget", R), ("acme/otro", None, "acme/otro")])

    def test_error_de_gh_hace_backoff_sin_machine_health(self):
        self.gh.fail = [(None, {})]
        p = self.poller()
        with self.assertLogs("chopshop.agent.actions", "WARNING"):
            res = p.poll_once()
        self.assertEqual(res["errors"], {REPO: "gh"})
        self.assertEqual(p.poll_once()["skipped"], "backoff")
        self.assertEqual(self.emitted, [])


class TestServicio(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-actions-svc-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _cfg(self, **gh):
        cfg = base_cfg(self.tmp)
        cfg["github"] = dict(cfg["github"], **gh)
        return cfg

    def test_hilo_solo_con_github_y_emite_al_bus(self):
        self.assertTrue(settings.DEFAULTS["agent"]["github"]["actions"])
        svc = service.AgentService(self._cfg(), maint_first=3600, gh_projects_fn=lambda: {}, gh_profiles_fn=lambda: {})
        self.addCleanup(svc.stop)
        self.assertIsNone(svc.actions)
        off = service.AgentService(self._cfg(enabled=True, actions=False), maint_first=3600, gh_projects_fn=lambda: {},
                                   gh_profiles_fn=lambda: {})
        self.addCleanup(off.stop)
        self.assertIsNone(off.actions)
        gh = FakeGh()
        gh.set(RUNS, json.dumps({"workflow_runs": [run(1, event="schedule")]}), '"e1"')
        gh.set("/repos/%s" % R, json.dumps({"default_branch": "main"}), '"r"')
        on = service.AgentService(self._cfg(enabled=True, repos=[REPO]), maint_first=3600, gh_projects_fn=lambda: {},
                                  gh_profiles_fn=lambda: {}, gh_runner=gh)
        self.addCleanup(on.stop)
        self.assertEqual(on.actions.poll_once()["emitted"], 1)
        row = on.conn.execute("SELECT type, severity, body FROM events WHERE type='forge.run.state'").fetchone()
        self.assertEqual((row["type"], json.loads(row["body"])["origin"]["kind"]), ("forge.run.state", "schedule"))


if __name__ == "__main__":
    unittest.main()
