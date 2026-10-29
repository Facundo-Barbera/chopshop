import contextlib
import http.server
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import cli, home, integrate, profile, state, t3  # noqa: E402

CONFIG = """[general]
default_host = "host-a"

[hosts.host-a]
cap = 2
"""
TESTS = ["python3", "-m", "unittest", "discover", "-s", "tests"]


class FakeRunner:
    """Runner falso: responde según el primer argumento de git; `push` sigue un guion de respuestas."""
    def __init__(self, branch="chopshop/t-1-arreglo", dirty="", rebase=0, tests=0, pushes=None):
        self.calls = []
        self.branch, self.dirty, self.rebase, self.tests = branch, dirty, rebase, tests
        self.pushes = list(pushes or [(0, "")])

    def __call__(self, argv, cwd):
        self.calls.append((argv, cwd))
        if argv[0] != "git":
            return self.tests, "Ran 3 tests\n" + ("OK" if self.tests == 0 else "FAILED")
        cmd = argv[1]
        if cmd == "status":
            return 0, self.dirty
        if cmd == "rev-parse":
            return 0, (self.branch if "--abbrev-ref" in argv else "abc1234def") + "\n"
        if cmd == "fetch":
            return 0, ""
        if cmd == "rebase":
            return (0, "") if "--abort" in argv else (self.rebase, "CONFLICT (content)" if self.rebase else "")
        if cmd == "push":
            return self.pushes.pop(0) if len(self.pushes) > 1 else self.pushes[0]
        raise AssertionError(argv)

    def argvs(self, first):
        return [a for a, _ in self.calls if a[:2] == ["git", first]]


class FakeT3:
    def __init__(self, status="completed", pending=0, branch="chopshop/t-1-arreglo", worktree=None):
        self.calls = []
        self.thread = {"status": status, "pendingRequestCount": pending, "branch": branch, "worktreePath": worktree}

    def call(self, tool, args=None):
        self.calls.append((tool, args))
        if tool == "t3_thread_read":
            return {"thread": dict(self.thread, threadId=args["threadId"]), "items": []}
        if tool == "t3_thread_organize":
            assert args["action"] == "settle"
            return {}
        raise AssertionError(tool)

    def tools(self):
        return [c[0] for c in self.calls]


class Hook(http.server.BaseHTTPRequestHandler):
    got = []

    def do_POST(self):
        Hook.got.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *a):
        pass


class Env(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        env = {"CHOPSHOP_HOME": os.path.join(self.tmp, "home"), "CHOPSHOP_CONFIG": os.path.join(self.tmp, "config.toml")}
        p = mock.patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)
        with open(env["CHOPSHOP_CONFIG"], "w") as f:
            f.write(CONFIG)
        os.makedirs(home.profiles_dir())
        self.worktree = os.path.join(self.tmp, "wt")
        os.makedirs(self.worktree)
        self.fake = FakeT3(worktree=self.worktree)
        t3.set_client_factory(lambda hc, host, timeout: self.fake)
        self.addCleanup(t3.set_client_factory, None)
        self.set_profile(tests=True)
        with state.locked() as st:
            st["batches"]["b-0001"] = {"id": "b-0001", "project": "demo", "host": "host-a", "max_parallel": 1, "tasks": [
                {"id": "t-1", "title": "arreglo", "status": "launched", "threadId": "mcp:1", "t3status": "completed",
                 "done": True, "notified": [], "pending": None}]}

    def set_profile(self, tests=True, extra=""):
        txt = "project: demo\nhost: host-a\nbase_ref: main\n" + extra
        if tests:
            txt += "integration:\n  test_cmd: [%s]\n  test_cwd: apps/agent\n  timeout: 60\n" % ", ".join(TESTS)
        with open(os.path.join(home.profiles_dir(), "demo.yaml"), "w") as f:
            f.write(txt)

    def task(self):
        return state.read()["batches"]["b-0001"]["tasks"][0]

    def go(self, runner, **kw):
        return integrate.run("t-1", runner=runner, log=lambda *a: None, **kw)[0]


class TestGuard(unittest.TestCase):
    def test_rejects_history_rewrite(self):
        for bad in (["--force"], ["-f"], ["-uf"], ["--force-with-lease"], ["--force-with-lease=main"],
                    ["--force-if-includes"], ["+HEAD:main"]):
            with self.assertRaises(integrate.IntegrateError, msg=bad):
                integrate.check_push(["git", "push", "origin"] + bad + ["HEAD:main"])

    def test_allows_normal_push_and_other_commands(self):
        integrate.check_push(["git", "push", "origin", "HEAD:main"])
        integrate.check_push(["git", "fetch", "-f", "origin"])   # solo se vigila push

    def test_guard_runs_before_runner(self):
        r = FakeRunner()
        with mock.patch.object(integrate, "check_push", side_effect=integrate.IntegrateError("x")):
            with self.assertRaises(integrate.IntegrateError):
                integrate.integrate_worktree("/wt", "b", "main", ["true"], runner=r, log=lambda *a: None)
        self.assertEqual(r.calls, [])


class TestStates(Env):
    def test_ok_settles_marks_and_emits(self):
        srv = http.server.HTTPServer(("127.0.0.1", 0), Hook)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        hook = os.path.join(self.tmp, "hook")
        with open(hook, "w") as f:
            f.write("http://127.0.0.1:%d/h" % srv.server_port)
        with state.locked() as st:
            st["subscriptions"]["bot"] = {"project": "*", "events": ["task_integrated"], "webhook_file": hook}
        Hook.got.clear()
        r = FakeRunner()
        res = self.go(r)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(r.argvs("push"), [["git", "push", "origin", "HEAD:main"]])
        self.assertIn(["git", "rebase", "origin/main"], [a for a, _ in r.calls])
        tests = [(a, c) for a, c in r.calls if a[0] != "git"]
        self.assertEqual(tests, [(TESTS, os.path.join(self.worktree, "apps/agent"))])
        self.assertEqual(self.fake.tools(), ["t3_thread_read", "t3_thread_organize"])
        t = self.task()
        self.assertTrue(t["integrated"]); self.assertTrue(t["settled"]); self.assertEqual(t["integratedCommit"], "abc1234def")
        self.assertEqual(len(Hook.got), 1)
        ev = Hook.got[0]
        self.assertEqual((ev["event"], ev["task"], ev["batch"], ev["base"]), ("task_integrated", "t-1", "b-0001", "main"))
        with open(home.events_log()) as f:
            self.assertIn("task_integrated", f.read())
        # segunda vez: ya integrada, no toca git
        r2 = FakeRunner()
        self.assertEqual(self.go(r2)["status"], "already")
        self.assertEqual(r2.calls, [])

    def assert_not_integrated(self, r):
        self.assertNotIn("t3_thread_organize", self.fake.tools())
        self.assertFalse(self.task().get("integrated"))
        self.assertFalse(os.path.exists(home.events_log()))

    def test_conflict_aborts(self):
        r = FakeRunner(rebase=1)
        res = self.go(r)
        self.assertEqual(res["status"], "conflict")
        self.assertIn(["git", "rebase", "--abort"], [a for a, _ in r.calls])
        self.assertEqual(r.argvs("push"), [])
        self.assertFalse([a for a, _ in r.calls if a[0] != "git"])   # no corre tests
        self.assert_not_integrated(r)

    def test_tests_failed(self):
        r = FakeRunner(tests=1)
        self.assertEqual(self.go(r)["status"], "tests_failed")
        self.assertEqual(r.argvs("push"), [])
        self.assert_not_integrated(r)

    def test_no_tests(self):
        self.set_profile(tests=False)
        r = FakeRunner()
        self.assertEqual(self.go(r)["status"], "no_tests")
        self.assertEqual(r.calls, [])
        self.assert_not_integrated(r)

    def test_dirty(self):
        r = FakeRunner(dirty=" M a.py\n")
        self.assertEqual(self.go(r)["status"], "dirty")
        self.assertEqual(r.argvs("fetch"), [])
        self.assert_not_integrated(r)

    def test_wrong_branch(self):
        self.assertEqual(self.go(FakeRunner(branch="otra"))["status"], "wrong_branch")

    def test_push_rejected_after_two_retries(self):
        rej = (1, " ! [rejected]        HEAD -> main (non-fast-forward)")
        r = FakeRunner(pushes=[rej])
        res = self.go(r)
        self.assertEqual(res["status"], "push_rejected")
        self.assertEqual(len(r.argvs("push")), 3)            # 1 intento + 2 reintentos
        self.assertEqual(len(r.argvs("fetch")), 3)
        self.assertEqual(len([a for a, _ in r.calls if a[0] != "git"]), 3)
        self.assert_not_integrated(r)

    def test_push_rejected_then_ok(self):
        rej = (1, "! [rejected] (fetch first)")
        r = FakeRunner(pushes=[rej, (0, "")])
        self.assertEqual(self.go(r)["status"], "ok")
        self.assertEqual(len(r.argvs("push")), 2)
        self.assertTrue(self.task()["integrated"])

    def test_push_failed_other_error_no_retry(self):
        r = FakeRunner(pushes=[(128, "fatal: could not read from remote")])
        self.assertEqual(self.go(r)["status"], "push_failed")
        self.assertEqual(len(r.argvs("push")), 1)
        self.assert_not_integrated(r)

    def test_dry_run(self):
        r = FakeRunner()
        res = self.go(r, dry_run=True)
        self.assertEqual(res["status"], "dry_run")
        self.assertEqual(r.argvs("push"), [])
        self.assertEqual(len([a for a, _ in r.calls if a[0] != "git"]), 1)
        self.assert_not_integrated(r)

    def test_rejects_unfinished_or_pending(self):
        self.fake.thread["status"] = "running"
        r = FakeRunner()
        self.assertEqual(self.go(r)["status"], "not_ready")
        self.fake.thread.update(status="completed", pendingRequestCount=1)
        self.assertEqual(self.go(r)["status"], "not_ready")
        self.assertEqual(r.calls, [])

    def test_rejects_missing_branch_or_worktree(self):
        r = FakeRunner()
        self.fake.thread["branch"] = None
        self.assertEqual(self.go(r)["status"], "no_worktree")
        self.fake.thread.update(branch="chopshop/t-1-arreglo", worktreePath=os.path.join(self.tmp, "no-existe"))
        self.assertEqual(self.go(r)["status"], "no_worktree")
        self.assertEqual(r.calls, [])

    def test_thread_mode_needs_host_and_project(self):
        with self.assertRaises(integrate.IntegrateError):
            integrate.run(thread="mcp:9", host="host-a")
        res = integrate.run(thread="mcp:1", host="host-a", project="demo", runner=FakeRunner(), log=lambda *a: None)
        self.assertEqual(res[0]["status"], "ok")
        self.assertTrue(self.task()["integrated"])          # el hilo era de una tarea conocida: se marca

    def test_profile_validation(self):
        self.set_profile(tests=False, extra="integration:\n  test_cmd: python3\n  otra: 1\n")
        errs = profile.validate(profile.load("demo"))
        self.assertTrue(any("test_cmd" in e for e in errs))
        self.assertTrue(any("integration.otra" in e for e in errs))
        self.assertNotIn("integration", profile.load("demo")["_unknown"])

    def test_cli_exit_codes(self):
        with mock.patch.object(integrate, "subprocess_runner", return_value=FakeRunner(tests=1)):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = cli.main(["integrate", "t-1", "--json"])
        self.assertEqual(rc, 1)
        self.assertEqual(json.loads(out.getvalue())[0]["status"], "tests_failed")
        with mock.patch.object(integrate, "subprocess_runner", return_value=FakeRunner()):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                rc = cli.main(["integrate", "b-0001"])
        self.assertEqual(rc, 0)
        self.assertIn("t-1: ok", out.getvalue())


def _git(cwd, *args):
    subprocess.run(["git"] + list(args), cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class TestRealGit(Env):
    """Repos temporales: un remoto bare, el worktree del hilo y otro clon que hace avanzar main. Sin red."""
    def setUp(self):
        super().setUp()
        genv = {"GIT_AUTHOR_NAME": "Prueba", "GIT_AUTHOR_EMAIL": "prueba", "GIT_COMMITTER_NAME": "Prueba",
                "GIT_COMMITTER_EMAIL": "prueba", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        p = mock.patch.dict(os.environ, genv)
        p.start()
        self.addCleanup(p.stop)
        self.remote = os.path.join(self.tmp, "remote.git")
        _git(self.tmp, "init", "-q", "--bare", "-b", "main", self.remote)
        seed = os.path.join(self.tmp, "seed")
        _git(self.tmp, "clone", "-q", self.remote, seed)
        _git(seed, "checkout", "-q", "-b", "main")
        self.write(seed, "base.txt", "base\n")
        _git(seed, "add", "."); _git(seed, "commit", "-q", "-m", "base"); _git(seed, "push", "-q", "origin", "main")
        os.rmdir(self.worktree)
        _git(self.tmp, "clone", "-q", self.remote, self.worktree)
        _git(self.worktree, "checkout", "-q", "-b", "chopshop/t-1-arreglo")
        self.write(self.worktree, "feature.txt", "nuevo\n")
        _git(self.worktree, "add", "."); _git(self.worktree, "commit", "-q", "-m", "feature")
        self.other = os.path.join(self.tmp, "other")
        _git(self.tmp, "clone", "-q", self.remote, self.other)
        self.n = 0
        with open(os.path.join(home.profiles_dir(), "demo.yaml"), "w") as f:
            f.write("project: demo\nhost: host-a\nintegration:\n  test_cmd: [%s, -c, \"import os; assert os.path.exists('feature.txt')\"]\n"
                    % sys.executable)

    def write(self, d, name, text):
        with open(os.path.join(d, name), "w") as f:
            f.write(text)

    def advance_main(self):
        self.n += 1
        _git(self.other, "pull", "-q", "--rebase", "origin", "main")
        self.write(self.other, "otro%d.txt" % self.n, "x\n")
        _git(self.other, "add", "."); _git(self.other, "commit", "-q", "-m", "otro %d" % self.n)
        _git(self.other, "push", "-q", "origin", "HEAD:main")

    def remote_log(self):
        return subprocess.run(["git", "--git-dir", self.remote, "log", "--format=%s", "main"],
                              stdout=subprocess.PIPE, text=True, check=True).stdout.splitlines()

    def racing_runner(self, races):
        """Runner real que, antes de los primeros `races` push, hace avanzar main desde otro clon."""
        real = integrate.subprocess_runner(60)
        left = [races]

        def run(argv, cwd):
            if argv[:2] == ["git", "push"] and left[0] > 0:
                left[0] -= 1
                self.advance_main()
            return real(argv, cwd)
        return run

    def test_happy_path(self):
        self.advance_main()            # main avanzó antes: hace falta rebase
        res = self.go(integrate.subprocess_runner(60))
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.remote_log(), ["feature", "otro 1", "base"])
        self.assertTrue(self.task()["integrated"])

    def test_non_fast_forward_retries(self):
        res = self.go(self.racing_runner(1))
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(len([s for s in res["steps"] if s["cmd"].startswith("git push")]), 2)
        self.assertEqual(self.remote_log()[0], "feature")
        self.assertIn("otro 1", self.remote_log())

    def test_non_fast_forward_gives_up(self):
        res = self.go(self.racing_runner(3))
        self.assertEqual(res["status"], "push_rejected", res)
        self.assertNotIn("feature", self.remote_log())
        self.assertFalse(self.task().get("integrated"))
        self.assertNotIn("t3_thread_organize", self.fake.tools())

    def test_conflict_real(self):
        self.write(self.other, "feature.txt", "distinto\n")
        _git(self.other, "add", "."); _git(self.other, "commit", "-q", "-m", "choque"); _git(self.other, "push", "-q", "origin", "HEAD:main")
        res = self.go(integrate.subprocess_runner(60))
        self.assertEqual(res["status"], "conflict")
        st = subprocess.run(["git", "status", "--porcelain"], cwd=self.worktree, stdout=subprocess.PIPE, text=True).stdout
        self.assertEqual(st, "")                       # rebase abortado: worktree intacto
        self.assertNotIn("feature", self.remote_log())


if __name__ == "__main__":
    unittest.main()
