"""Pruebas de chopshop.agent.forge: luz del rack (pura), adaptador GitHub sobre `actions/runs` con ETag y 304, y el hilo
`forge` (emite `forge.repo.state` solo al cambiar, gris con proveedor degradado + backoff, 404 solo afecta a su repo, sobre
válido con severidad). Nada de red ni de `gh` real: un runner falso con rutas exactas."""
import copy
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import settings  # noqa: E402
from chopshop.agent import db, envelope, events, forge, service  # noqa: E402
from chopshop.agent.forge import base, rack  # noqa: E402
from chopshop.agent.forge import github as fgh  # noqa: E402

R = "acme/widget"
R2 = "acme/docs"


def run(i, status="completed", conclusion="success", branch="main", event="push", name="ci", created="2026-10-29T10:00:%02dZ"):
    return {"id": i, "name": name, "status": status, "conclusion": conclusion if status == "completed" else None,
            "event": event, "head_branch": branch, "head_sha": "sha%d" % i, "html_url": "https://github.com/x/runs/%d" % i,
            "created_at": created % (i % 60), "updated_at": created % (i % 60), "actor": {"login": "dev"}}


class FakeGh:
    """`gh api -i` por ruta EXACTA: (cuerpo, etag); 304 si `If-None-Match` coincide. `fail` = [(status, headers)] forzados."""

    def __init__(self):
        self.routes, self.fail, self.calls = {}, [], []

    def set(self, path, body, etag):
        self.routes[path] = (json.dumps(body), etag)

    def repo(self, repo, runs, branch_runs=None, default="main", etag="1"):
        self.set("/repos/%s" % repo, {"default_branch": default, "html_url": "https://github.com/" + repo}, "r" + etag)
        self.set("/repos/%s/actions/runs?per_page=50" % repo, {"workflow_runs": runs}, "a" + etag)
        self.set("/repos/%s/actions/runs?per_page=20&branch=%s" % (repo, default),
                 {"workflow_runs": runs if branch_runs is None else branch_runs}, "b" + etag)

    def __call__(self, argv, timeout=None):
        self.calls.append(list(argv))
        path = argv[-1]
        inm = next((a.split(": ", 1)[1] for a in argv if a.startswith("If-None-Match: ")), None)
        if self.fail:
            status, hdrs = self.fail.pop(0)
            h = "".join("%s: %s\n" % kv for kv in hdrs.items())
            return 1, "HTTP/2.0 %d Error\n%s\n{}" % (status, h), ""
        if path not in self.routes:
            return 1, "HTTP/2.0 404 Not Found\n\n{\"message\":\"Not Found\"}", ""
        body, etag = self.routes[path]
        if inm and inm == etag:
            return 1, "HTTP/2.0 304 Not Modified\nEtag: %s\n\n" % etag, ""
        return 0, "HTTP/2.0 200 OK\nEtag: %s\n\n%s" % (etag, body), ""


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def status(**kw):
    s = {"default_branch": "main", "ci": None, "active": 0, "pr_failing": [], "error": None}
    s.update(kw)
    return s


class TestLight(unittest.TestCase):
    def test_tabla(self):
        cases = [
            (None, "gray"),
            (status(), "gray"),                                         # sin datos
            (status(ci="success"), "green"),
            (status(ci="success", active=2), "amber"),
            (status(ci="pending", active=1), "amber"),
            (status(ci="failure"), "red"),
            (status(ci="failure", active=1), "red"),                    # un arreglo en curso no tapa el rojo
            (status(ci="success", pr_failing=["be/x"]), "red"),
            (status(ci="success", error="rate_limit"), "gray"),
        ]
        for st, want in cases:
            self.assertEqual(base.light(st), want, st)
            self.assertIn(want, envelope.LIGHTS)

    def test_branch_ci_ultimo_por_workflow(self):
        runs = [fgh.map_run(r) for r in (run(3, conclusion="success"), run(2, conclusion="failure"),
                                         run(1, conclusion="failure", name="lint"), run(4, branch="be/x", conclusion="failure"))]
        self.assertEqual(base.branch_ci(runs, "main"), "failure")      # lint sigue rojo
        runs.insert(0, fgh.map_run(run(5, name="lint")))
        self.assertEqual(base.branch_ci(runs, "main"), "success")
        self.assertIsNone(base.branch_ci(runs, "otra"))
        self.assertEqual(base.branch_ci([fgh.map_run(run(6, conclusion="skipped"))], "main"), "success")

    def test_pr_failing_solo_el_ultimo(self):
        runs = [fgh.map_run(r) for r in (run(3, branch="be/x", event="pull_request", conclusion="success"),
                                         run(2, branch="be/x", event="pull_request", conclusion="failure"),
                                         run(1, branch="fe/y", event="pull_request", conclusion="timed_out"),
                                         run(4, branch="main", event="pull_request", conclusion="failure"))]
        self.assertEqual(base.pr_failing(runs, "main"), ["fe/y"])

    def test_map_run(self):
        r = run(7, status="in_progress")
        r["triggering_actor"] = {"login": "grok-bot"}
        m = fgh.map_run(r)
        self.assertEqual(m, {"run_id": "7", "workflow": "ci", "status": "in_progress", "conclusion": None, "event": "push",
                             "actor": "grok-bot", "head_branch": "main", "head_sha": "sha7",
                             "url": "https://github.com/x/runs/7", "created_at": "2026-10-29T10:00:07Z",
                             "updated_at": "2026-10-29T10:00:07Z"})

    def test_registro(self):
        self.assertIs(forge.PROVIDERS["github"], fgh.GitHubProvider)
        self.assertTrue(issubclass(fgh.GitHubProvider, base.ForgeProvider))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-forge-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = db.connect(os.path.join(self.tmp, "agent.db"))
        self.addCleanup(self.conn.close)
        self.cfg = {"machine_id": "host-a", "github": {"enabled": True, "repos": [], "interval_s": 45},
                    "forge": {"interval_s": 60}}
        self.gh = FakeGh()
        self.clock = Clock()
        self.emitted = []
        self.entries = [{"provider": "github", "repo": "Acme/Widget", "project": "widget", "kind": "main", "label": "Widget"}]

    def emit(self, type, project, body, severity=None):
        json.dumps(body)
        self.emitted.append((type, project, body, severity))

    def rack(self):
        return rack.Rack(self.conn, self.cfg, self.emit, clock=self.clock, provider_opts={"runner": self.gh},
                         entries_fn=lambda: list(self.entries))


class TestProvider(Base):
    def provider(self):
        return fgh.GitHubProvider(self.conn, self.cfg, runner=self.gh, clock=self.clock)

    def test_repo_status_y_304(self):
        self.gh.repo(R, [run(2, status="in_progress"), run(1)])
        p = self.provider()
        st = p.repo_status(R)
        self.assertEqual((st["default_branch"], st["ci"], st["active"], st["pr_failing"], st["error"]),
                         ("main", "success", 1, [], None))
        self.assertEqual(st["url"], "https://github.com/" + R)
        self.assertEqual(base.light(st), "amber")
        n = len(self.gh.calls)
        self.assertEqual(p.repo_status(R), st)                          # recién pedido: sin preguntar
        self.assertEqual(len(self.gh.calls), n)
        self.clock.t += 60
        st2 = p.repo_status(R)                                          # todo 304: mismo estado desde meta
        self.assertEqual(st2, st)
        self.assertEqual(len(self.gh.calls), n + 3)
        self.assertTrue(all(any(a.startswith("If-None-Match: ") for a in c) for c in self.gh.calls[n:]))

    def test_ci_de_la_rama_por_defecto_aunque_no_este_en_la_pagina_general(self):
        many = [run(i, branch="be/x", status="in_progress") for i in range(10, 20)]
        self.gh.repo(R, many, branch_runs=[run(1, conclusion="failure")])
        st = self.provider().repo_status(R)
        self.assertEqual((st["ci"], st["active"]), ("failure", 10))
        self.assertEqual(base.light(st), "red")

    def test_pending_sin_completados(self):
        self.gh.repo(R, [run(1, status="queued")])
        self.assertEqual(self.provider().repo_status(R)["ci"], "pending")

    def test_errores(self):
        p = self.provider()
        with self.assertRaises(base.ProviderError) as cm:
            p.repo_status(R)                                            # 404
        self.assertEqual((cm.exception.kind, cm.exception.degraded), ("not_found", False))
        self.gh.fail = [(403, {"X-RateLimit-Remaining": "0", "Retry-After": "120"})]
        with self.assertRaises(base.ProviderError) as cm:
            p.repo_status(R)
        self.assertEqual((cm.exception.kind, cm.exception.degraded, cm.exception.wait), ("rate_limit", True, 120))


class TestRack(Base):
    def test_emite_solo_al_cambiar(self):
        self.gh.repo(R, [run(1)])
        rk = self.rack()
        res = rk.poll_once()
        self.assertEqual(res["emitted"], 1)
        typ, project, body, sev = self.emitted[0]
        self.assertEqual((typ, project, sev), ("forge.repo.state", "widget", None))
        self.assertEqual(body, {"provider": "github", "repo": R, "project": "widget", "kind": "main", "label": "Widget",
                                "light": "green", "default_branch": "main", "ci": "success",
                                "url": "https://github.com/" + R, "error": None, "active_runs": 0, "pr_failing": []})
        self.clock.t += 60
        self.assertEqual(rk.poll_once()["emitted"], 0)                  # nada cambió (304)
        self.gh.repo(R, [run(2, conclusion="failure"), run(1)], etag="2")
        self.clock.t += 60
        rk.poll_once()
        self.assertEqual(len(self.emitted), 2)
        self.assertEqual((self.emitted[1][2]["light"], self.emitted[1][3]), ("red", "warn"))
        self.assertEqual(self.rack().poll_once()["emitted"], 0)         # el último cuerpo vive en meta (reinicio)

    def test_degradado_pinta_gris_y_hace_backoff(self):
        self.entries.append({"provider": "github", "repo": R2, "project": "widget", "kind": "docs", "label": "Docs"})
        self.gh.repo(R, [run(1)])
        self.gh.repo(R2, [run(1)])
        rk = self.rack()
        rk.poll_once()
        self.assertEqual([b["light"] for _t, _p, b, _s in self.emitted], ["green", "green"])
        self.gh.routes.clear()
        self.gh.fail = [(429, {"Retry-After": "300"})]
        self.clock.t += 60
        n = len(self.gh.calls)
        res = rk.poll_once()
        self.assertEqual(len(self.gh.calls), n + 1)                     # al segundo repo ya no se le pregunta
        self.assertEqual(res["errors"], {"github:" + R: "rate_limit", "github:" + R2: "rate_limit"})
        grays = self.emitted[2:]
        self.assertEqual([(b["light"], b["error"], b["default_branch"], b["ci"]) for _t, _p, b, _s in grays],
                         [("gray", "rate_limit", "main", None)] * 2)
        self.assertGreaterEqual(rk.next_delay(), 300)
        self.assertEqual(rk.poll_once(), {"skipped": "backoff", "emitted": 0})
        self.clock.t += 301
        self.gh.repo(R, [run(1)], etag="3")
        self.gh.repo(R2, [run(1)], etag="3")
        rk.poll_once()
        self.assertEqual([b["light"] for _t, _p, b, _s in self.emitted[4:]], ["green", "green"])
        self.assertEqual(rk.until, 0.0)

    def test_404_solo_su_repo_sin_backoff(self):
        self.entries.insert(0, {"provider": "github", "repo": "acme/ghost", "project": "widget", "kind": "other"})
        self.gh.repo(R, [run(1)])
        rk = self.rack()
        res = rk.poll_once()
        self.assertEqual(res["lights"], {"github:acme/ghost": "gray", "github:" + R: "green"})
        self.assertEqual(rk.until, 0.0)

    def test_entradas_dedupe_invalidas_y_sin_proveedor(self):
        self.entries += [{"provider": "github", "repo": "acme/WIDGET", "project": "otro", "kind": "docs"},
                         {"provider": "github", "repo": "<org>/<repo>"},
                         {"provider": "gitea", "repo": "acme/widget", "project": "widget"}]
        self.gh.repo(R, [run(1)])
        rk = self.rack()
        with self.assertLogs("chopshop.agent.forge", "WARNING"):
            got = rk.entries()
        self.assertEqual([(e["provider"], e["repo"], e["project"]) for e in got],
                         [("github", R, "widget"), ("gitea", "acme/widget", "widget")])
        res = rk.poll_once()
        self.assertEqual(res["errors"], {"gitea:acme/widget": "provider"})

    def test_config_entries(self):
        cfg = {"github": {"enabled": True, "repos": ["Acme/Widget", "nope"]}, "projects": {"w": {"repo": "acme/widget"}}}
        self.assertEqual(rack.config_entries(cfg), [{"provider": "github", "repo": R, "project": "w", "kind": "main",
                                                     "label": "widget"}])
        self.assertEqual(rack.config_entries({"github": {"enabled": False, "repos": ["acme/widget"]}}), [])

    def test_enabled_y_check(self):
        self.assertEqual(settings.DEFAULTS["agent"]["forge"]["enabled"], "auto")
        self.assertTrue(rack.enabled({"github": {"enabled": True}, "forge": {"enabled": "auto"}}))
        self.assertFalse(rack.enabled({"github": {"enabled": False}, "forge": {}}))
        self.assertTrue(rack.enabled({"github": {"enabled": False}, "forge": {"enabled": True}}))
        self.assertFalse(rack.enabled({"github": {"enabled": True}, "forge": {"enabled": False}}))
        self.assertEqual(rack.check({"forge": {"interval_s": 60}}), [])
        self.assertEqual(len(rack.check({"forge": {"interval_s": 5, "enabled": "si"}})), 2)

    def test_sobre_valido_en_el_bus(self):
        self.gh.repo(R, [run(1, conclusion="failure")])
        cfg = dict(self.cfg)
        out = []
        rk = rack.Rack(self.conn, cfg, lambda t, p, b, s=None: out.append(
            events.emit_envelope(self.conn, cfg, t, p, b, severity=s)), clock=self.clock,
            provider_opts={"runner": self.gh}, entries_fn=lambda: list(self.entries))
        rk.poll_once()
        env = out[0]
        envelope.validate(env)
        self.assertEqual((env["type"], env["severity"], env["needs"]), ("forge.repo.state", "warn", None))
        self.assertEqual(env["subject"], {"kind": "repo", "id": "github:" + R, "title": "Widget",
                                          "url": "https://github.com/" + R})


class TestServicio(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-forge-svc-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def cfg(self, **over):
        cfg = copy.deepcopy(settings.DEFAULTS["agent"])
        cfg.update(machine_id="host-a", db_path=os.path.join(self.tmp, "agent", "agent.db"),
                   token_file=os.path.join(self.tmp, "token"), projects_root=self.tmp, worktrees_root=self.tmp,
                   t3_enabled=False, import_legacy=False, port=0, bind="127.0.0.1")
        cfg.update(over)
        return cfg

    def svc(self, cfg, **kw):
        s = service.AgentService(cfg, maint_first=3600, gh_projects_fn=lambda: {}, **kw)
        self.addCleanup(s.stop)
        return s

    def test_sin_github_no_hay_rack(self):
        self.assertIsNone(self.svc(self.cfg()).forge)

    def test_emit_forge_publica_en_el_bus(self):
        gh = FakeGh()
        gh.repo(R, [run(1)])
        cfg = self.cfg(github={"enabled": True, "repos": [], "interval_s": 45, "gh_bin": "gh", "ci": False})
        s = self.svc(cfg, gh_runner=gh, forge_entries_fn=lambda: [{"provider": "github", "repo": R, "project": "w"}])
        self.assertIsNotNone(s.forge)
        self.assertEqual(s.forge.poll_once()["emitted"], 1)
        rows = events.list_after(s.conn, 0)
        self.assertTrue(any(e.get("type") == "forge.repo.state" for e in rows))


if __name__ == "__main__":
    unittest.main()
