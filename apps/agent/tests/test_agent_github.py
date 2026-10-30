"""Pruebas de chopshop.agent.github: polling con ETag, cursores en `meta`, siembra silenciosa, mapeo a `github.*`, CI de PRs,
backoff con reloj inyectado y `machine.health`, limpieza de credenciales e integración con el servicio (enabled=false no crea
el hilo). Nada de red ni de `gh` real: un runner falso que imita la salida de `gh api -i` con respuestas grabadas
(tests/fixtures/github)."""
import copy
import io
import json
import logging
import os
import re
import shutil
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import settings  # noqa: E402
from chopshop.agent import db, github, service  # noqa: E402

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "github")
REPO = "Acme/Widget"
R = "acme/widget"
SECRET_RX = re.compile(r"gho_|ghp_|github_pat_|Authorization|secreto@", re.I)


def fixture(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return f.read().replace("LONGBODY", "x" * 5000)


class FakeGh:
    """Imita `gh api -i`: por ruta guarda (cuerpo, etag); con `If-None-Match` igual al etag responde 304.
    `fail` = lista de respuestas forzadas (status, headers) que se consumen antes que las normales. Registra cada argv."""

    def __init__(self):
        self.routes = {}
        self.fail = []
        self.calls = []
        self.headers = {}

    def set(self, path, body, etag):
        self.routes[path] = (body, etag)

    def __call__(self, argv, timeout=None):
        self.calls.append(list(argv))
        path = argv[-1]
        inm = next((a.split(": ", 1)[1] for a in argv if a.startswith("If-None-Match: ")), None)
        extra = "".join("%s: %s\n" % kv for kv in self.headers.items())
        if self.fail:
            status, hdrs = self.fail.pop(0)
            if status is None:
                return 127, "", "FileNotFoundError"
            h = "".join("%s: %s\n" % kv for kv in hdrs.items())
            return 1, "HTTP/2.0 %d Error\n%s\n{\"message\":\"API rate limit exceeded\"}" % (status, h), "gh: error"
        key = next((k for k in self.routes if path.startswith(k)), None)
        if key is None:
            return 1, "HTTP/2.0 404 Not Found\n\n{\"message\":\"Not Found\"}", "gh: Not Found (HTTP 404)"
        body, etag = self.routes[key]
        if inm and inm == etag:
            return 1, "HTTP/2.0 304 Not Modified\nEtag: %s\n%s\n" % (etag, extra), ""
        return 0, "HTTP/2.0 200 OK\nContent-Type: application/json\nEtag: %s\n%s\n%s" % (etag, extra, body), ""


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


EV = "/repos/%s/events" % R
PULLS = "/repos/%s/pulls" % R
CHECKS = "/repos/%s/commits/2222222222222222/check-runs" % R


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-gh-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = db.connect(os.path.join(self.tmp, "agent.db"))
        self.addCleanup(self.conn.close)
        self.cfg = {"machine_id": "host-a", "projects": {"widget-cfg": {"repo": "https://github.com/Acme/Widget.git"}},
                    "github": {"enabled": True, "repos": [REPO], "interval_s": 45, "ci": False}}
        self.gh = FakeGh()
        self.clock = Clock()
        self.emitted = []
        self.profiles = {"widget": "Acme/Widget"}

    def emit(self, event, project, body):
        json.dumps(body)                                  # debe ser serializable
        self.emitted.append((event, project, body))

    def poller(self, **cfg):
        c = copy.deepcopy(self.cfg)
        c["github"].update(cfg)
        return github.GitHubPoller(self.conn, c, self.emit, runner=self.gh, clock=self.clock,
                                   projects_fn=lambda: dict(self.profiles))

    def meta(self, key):
        r = self.conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return r["value"] if r else None


class TestPure(unittest.TestCase):
    def test_norm_repo(self):
        for v in ("Acme/Widget", "https://github.com/Acme/Widget.git", "git" "@github.com:Acme/Widget.git",
                  "github.com/acme/widget", "ssh://git" "@github.com/Acme/Widget"):
            self.assertEqual(github.norm_repo(v), R, v)
        for v in (None, "", "widget", "a/b/c", 3):
            self.assertIsNone(github.norm_repo(v))

    def test_parse_include(self):
        st, h, body = github.parse_include("HTTP/2.0 200 OK\r\nEtag: W/\"x\"\r\nX-Poll-Interval: 60\r\n\r\n[1]")
        self.assertEqual((st, h["etag"], h["x-poll-interval"], body), (200, 'W/"x"', "60", "[1]"))
        self.assertEqual(github.parse_include("gh: no auth")[0], None)

    def test_clip_y_scrub(self):
        s = github.clip("é" * 3000)
        self.assertLessEqual(len(s.encode("utf-8")), github.MAX_TEXT + 3)
        self.assertNotRegex(github.scrub("a ghp_abcdefghijklmn b github_pat_abcdefghijklmnop Authorization: token zz "
                                         "https://u:p@host/x"), SECRET_RX)
        self.assertEqual(github.scrub("https://u:p@host/x"), "https://host/x")

    def test_ci_state(self):
        self.assertIsNone(github.ci_state([]))
        self.assertEqual(github.ci_state(json.loads(fixture("check_runs_pending.json"))["check_runs"]), "pending")
        self.assertEqual(github.ci_state(json.loads(fixture("check_runs_failure.json"))["check_runs"]), "failure")
        self.assertEqual(github.ci_state([{"status": "completed", "conclusion": "skipped"}]), "success")

    def test_project_map_perfil_gana(self):
        cfg = {"projects": {"a": {"repo": "Acme/Widget"}, "b": {"root": "/x"}}}
        self.assertEqual(github.project_map(cfg), {R: "a"})
        self.assertEqual(github.project_map(cfg, {"p": "git" "@github.com:Acme/Widget.git"}), {R: "p"})


class TestPolling(Base):
    def test_primera_pasada_siembra_sin_emitir(self):
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        res = self.poller().poll_once()
        self.assertEqual(self.emitted, [])
        self.assertEqual(res["seeded"], [R])
        self.assertEqual(self.meta("gh_last_event_id:" + R), "40000000002")
        self.assertEqual(self.meta("gh_etag:" + R), '"e1"')
        self.assertFalse(any(a.startswith("If-None-Match") for a in self.gh.calls[0]))

    def test_304_no_emite(self):
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        p = self.poller()
        p.poll_once()
        res = p.poll_once()
        self.assertIn('If-None-Match: "e1"', self.gh.calls[-1])
        self.assertEqual((res["emitted"], self.emitted), (0, []))

    def test_evento_nuevo_un_sobre_e_idempotente_al_reiniciar(self):
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        self.poller().poll_once()
        one = json.loads(fixture("events_seed.json"))
        one.insert(0, {"id": "40000000003", "type": "IssuesEvent", "actor": {"login": "x"},
                       "payload": {"action": "opened", "issue": {"number": 9, "title": "Nuevo", "state": "open",
                                                                 "html_url": "https://github.com/Acme/Widget/issues/9"}}})
        self.gh.set(EV, json.dumps(one), '"e2"')
        p = self.poller()
        p.poll_once()
        self.assertEqual([(e, pr, b["number"]) for e, pr, b in self.emitted], [("github.issue.opened", "widget", 9)])
        # reinicio del hilo: poller nuevo sobre la misma DB, misma respuesta (con y sin ETag) -> nada nuevo
        self.poller().poll_once()
        self.conn.execute("DELETE FROM meta WHERE key=?", ("gh_etag:" + R,))
        self.poller().poll_once()
        self.assertEqual(len(self.emitted), 1)

    def test_mapeo_de_cada_tipo(self):
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        self.poller().poll_once()
        self.gh.set(EV, fixture("events_new.json"), '"e2"')
        res = self.poller().poll_once()
        got = [(e, b["number"], b["action"], b["state"]) for e, _, b in self.emitted]
        self.assertEqual(got, [
            ("github.issue.opened", 4, "opened", "open"),
            ("github.issue.updated", 2, "labeled", "open"),
            ("github.issue.closed", 3, "closed", "closed"),
            ("github.pr.opened", 7, "opened", "open"),
            ("github.pr.updated", 7, "synchronize", "open"),
            ("github.pr.merged", 6, "merged", "merged"),
            ("github.pr.review", 7, "created", "open"),
            ("github.push", None, "push", None),
        ])                                                   # WatchEvent no se publica; orden por id
        self.assertEqual(res["emitted"], 8)
        self.assertEqual({p for _, p, _ in self.emitted}, {"widget"})
        by = {e: b for e, _, b in self.emitted}
        for b in by.values():
            for k in ("repo", "number", "title", "url", "actor", "action", "labels", "head", "base", "state", "ci", "etag_source"):
                self.assertIn(k, b)
            self.assertEqual(b["repo"], R)
        self.assertEqual(by["github.issue.opened"]["labels"], ["bug"])
        self.assertEqual(by["github.pr.review"]["review"], "approved")
        self.assertEqual((by["github.pr.merged"]["head"], by["github.pr.merged"]["base"]), ("wt-2", "main"))
        push = by["github.push"]
        self.assertEqual((push["head"], push["sha"], push["commits"], push["title"]),
                         ("wt-3", "2222222222222222", 2, "Arregla la racha"))
        text = by["github.issue.opened"]["text"]
        self.assertLessEqual(len(text.encode("utf-8")), github.MAX_TEXT + 3)
        self.assertEqual(self.meta("gh_last_event_id:" + R), "40000000012")

    def test_project_por_config_si_no_hay_perfil(self):
        self.profiles = {}
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        self.poller().poll_once()
        self.gh.set(EV, fixture("events_new.json"), '"e2"')
        self.poller().poll_once()
        self.assertEqual({p for _, p, _ in self.emitted}, {"widget-cfg"})
        self.cfg["projects"] = {}
        self.emitted.clear()
        self.conn.execute("UPDATE meta SET value='40000000011' WHERE key=?", ("gh_last_event_id:" + R,))
        self.conn.execute("DELETE FROM meta WHERE key=?", ("gh_etag:" + R,))
        self.poller().poll_once()
        self.assertEqual([(e, p) for e, p, _ in self.emitted], [("github.push", None)])

    def test_x_poll_interval(self):
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        self.gh.headers = {"X-Poll-Interval": "120"}
        p = self.poller()
        p.poll_once()
        self.assertEqual(p.next_delay(), 120)
        self.gh.headers = {}
        p.poll_once()
        self.assertEqual(p.next_delay(), 45)

    def test_repo_inexistente_no_degrada(self):
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        p = self.poller(repos=["Acme/NoExiste", REPO])
        with self.assertLogs("chopshop.agent.github", logging.WARNING):
            res = p.poll_once()
        self.assertEqual(res["errors"], {"acme/noexiste": "not_found"})
        self.assertEqual(res["seeded"], [R])
        self.assertEqual(self.emitted, [])
        self.assertEqual(p.next_delay(), 45)


class TestCI(Base):
    def setUp(self):
        super().setUp()
        self.gh.set(EV, "[]", '"e0"')
        self.gh.set(PULLS, fixture("pulls_open.json"), '"p1"')
        self.gh.set(CHECKS, fixture("check_runs_pending.json"), '"c1"')

    def test_ci_completed_una_vez(self):
        p = self.poller(ci=True)
        p.poll_once()                                       # siembra: pendiente, sin emitir
        self.assertEqual(self.emitted, [])
        p.poll_once()                                       # todo 304
        self.assertEqual(self.emitted, [])
        self.gh.set(CHECKS, fixture("check_runs_failure.json"), '"c2"')
        p.poll_once()
        self.assertEqual(len(self.emitted), 1)
        ev, proj, b = self.emitted[0]
        self.assertEqual((ev, proj, b["number"], b["ci"], b["head"], b["base"], b["sha"], b["labels"]),
                         ("github.ci.completed", "widget", 7, "failure", "wt-3", "main", "2222222222222222", ["bug"]))
        self.poller(ci=True).poll_once()                    # reinicio: no repite
        self.gh.set(CHECKS, fixture("check_runs_failure.json"), '"c3"')     # etag distinto, mismo estado
        self.poller(ci=True).poll_once()
        self.assertEqual(len(self.emitted), 1)

    def test_ci_sembrado_terminado_no_emite(self):
        self.gh.set(CHECKS, fixture("check_runs_failure.json"), '"c2"')
        self.poller(ci=True).poll_once()
        self.poller(ci=True).poll_once()
        self.assertEqual(self.emitted, [])

    def test_ci_desactivado_no_consulta_pulls(self):
        self.poller(ci=False).poll_once()
        self.assertFalse(any(PULLS in c[-1] for c in self.gh.calls))


class TestBackoff(Base):
    def test_rate_limit_backoff_y_un_solo_health(self):
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        p = self.poller()
        p.poll_once()
        reset = int(self.clock.t) + 600
        self.gh.fail = [(403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(reset)})]
        with self.assertLogs("chopshop.agent.github", logging.WARNING):
            res = p.poll_once()
        self.assertEqual(res["errors"], {R: "rate_limit"})
        self.assertEqual(len(self.emitted), 1)
        ev, proj, b = self.emitted[0]
        self.assertEqual((ev, proj, b["state"], b["reason"], b["status"]), ("machine.health", None, "degraded", "rate_limit", 403))
        self.assertAlmostEqual(p.next_delay(), 600)
        # en backoff no se llama a gh
        n = len(self.gh.calls)
        self.clock.t += 100
        self.assertEqual(p.poll_once()["skipped"], "backoff")
        self.assertEqual(len(self.gh.calls), n)
        # siguen fallando (5xx, gh caído): backoff crece, ningún health nuevo
        delays = []
        for st in (502, None, 500):
            self.clock.t = p.until
            self.gh.fail = [(st, {})]
            p.poll_once()
            delays.append(p.next_delay())
        self.assertEqual(len(self.emitted), 1)
        self.assertEqual(delays, sorted(delays))
        self.assertLessEqual(max(delays), github.MAX_BACKOFF)
        # se recupera: un solo machine.health ok
        self.clock.t = p.until
        p.poll_once()
        p.poll_once()
        self.assertEqual([(e, b["state"]) for e, _, b in self.emitted], [("machine.health", "degraded"), ("machine.health", "ok")])
        self.assertGreater(self.emitted[1][2]["down_seconds"], 0)
        self.assertEqual(p.next_delay(), 45)

    def test_retry_after_y_429(self):
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        p = self.poller()
        self.gh.fail = [(429, {"Retry-After": "300"})]
        with self.assertLogs("chopshop.agent.github", logging.WARNING):
            p.poll_once()
        self.assertAlmostEqual(p.next_delay(), 300)
        self.assertEqual(self.emitted[0][2]["reason"], "rate_limit")


class TestSinSecretos(Base):
    def test_ni_eventos_ni_logs_llevan_credenciales(self):
        buf = io.StringIO()
        h = logging.StreamHandler(buf)
        lg = logging.getLogger("chopshop.agent.github")
        lg.addHandler(h)
        old = lg.level
        lg.setLevel(logging.DEBUG)
        self.addCleanup(lg.removeHandler, h)
        self.addCleanup(lg.setLevel, old)
        self.gh.set(EV, fixture("events_seed.json"), '"e1"')
        p = self.poller()
        p.poll_once()
        self.gh.set(EV, fixture("events_new.json"), '"e2"')
        p.poll_once()
        self.gh.fail = [(403, {"X-RateLimit-Remaining": "0", "Authorization": "token gho_fuga"})]
        self.clock.t += 1
        p.poll_once()
        self.clock.t = p.until
        p.poll_once()
        self.assertTrue(self.emitted)
        blob = json.dumps(self.emitted, ensure_ascii=False)
        self.assertNotRegex(blob, SECRET_RX)
        self.assertNotRegex(buf.getvalue(), SECRET_RX)
        for argv in self.gh.calls:                         # el token jamás se pasa en argv
            self.assertNotRegex(" ".join(argv), SECRET_RX)
            self.assertEqual(argv[:3], ["gh", "api", "-i"])


def base_cfg(tmp, **over):
    cfg = copy.deepcopy(settings.DEFAULTS["agent"])
    cfg.update(machine_id="host-a", db_path=os.path.join(tmp, "agent", "agent.db"), token_file=os.path.join(tmp, "token"),
               projects_root=tmp, worktrees_root=tmp, t3_enabled=False, import_legacy=False, port=0, bind="127.0.0.1")
    cfg.update(over)
    return cfg


class TestServicio(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-gh-svc-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        xdg = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": os.path.join(self.tmp, "xdg")})
        xdg.start()
        self.addCleanup(xdg.stop)

    def _svc(self, cfg, **kw):
        svc = service.AgentService(cfg, maint_first=3600, gh_projects_fn=lambda: {}, **kw)
        self.addCleanup(svc.stop)
        return svc

    def test_por_defecto_desactivado_y_sin_hilo(self):
        self.assertFalse(settings.DEFAULTS["agent"]["github"]["enabled"])
        self.assertEqual(settings.DEFAULTS["agent"]["github"]["interval_s"], 45)
        gh = FakeGh()
        svc = self._svc(base_cfg(self.tmp), gh_runner=gh).start()
        self.assertIsNone(svc.github)
        self.assertNotIn("chopshop-github", [t.name for t in svc.threads])
        time.sleep(0.1)
        self.assertEqual(gh.calls, [])

    def test_activado_crea_hilo_que_sobrevive_a_errores(self):
        gh = FakeGh()
        gh.fail = [(None, {})] * 3                                     # gh no responde
        cfg = base_cfg(self.tmp, github={"enabled": True, "repos": [REPO], "interval_s": 45, "gh_bin": "gh", "ci": False})
        svc = self._svc(cfg, gh_runner=gh)
        with self.assertLogs("chopshop.agent.github", logging.WARNING):
            svc.start()
            end = time.monotonic() + 5
            while not gh.calls and time.monotonic() < end:
                time.sleep(0.02)
        t = next(t for t in svc.threads if t.name == "chopshop-github")
        self.assertTrue(t.is_alive())
        rows = svc.conn.execute("SELECT event, body FROM events WHERE event='machine.health'").fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(json.loads(rows[0]["body"])["state"], "degraded")

    def test_check_config(self):
        cfg = base_cfg(self.tmp, github={"enabled": True, "repos": ["no-valido"], "interval_s": 1})
        errs, _ = github.check(cfg, which=lambda b: None)
        self.assertEqual(len(errs), 2)
        errs, warns = github.check(base_cfg(self.tmp, github={"enabled": True, "repos": [REPO], "interval_s": 45}),
                                   which=lambda b: None)
        self.assertEqual(errs, [])
        self.assertTrue(any("gh_bin" in w for w in warns))
        self.assertEqual(github.check(base_cfg(self.tmp)), ([], []))


if __name__ == "__main__":
    unittest.main()
