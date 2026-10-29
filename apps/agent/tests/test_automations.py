"""Pruebas de chopshop.agent.automations: validación del perfil, `where`, disparadores (evento, schedule con reloj inyectado,
manual), runner (grupo de procesos, timeout, entorno limpio, topes), JSONL -> sobres, anti-bucles, límites, hilo del servicio,
CLI `chopshop automation ...` y el ejemplo `examples/automations/triage`. Sin servicios reales ni red: scripts locales en tmp."""
import copy
import io
import json
import os
import shutil
import sys
import tempfile
import textwrap
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from test_chopshop import Env  # noqa: E402
from chopshop import cli, profile, settings  # noqa: E402
from chopshop.agent import automations as A, db, envelope as envmod, events, service  # noqa: E402

PY = sys.executable
EXAMPLE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "examples", "automations", "triage"))


def auto(**over):
    a = {"name": "a1", "on": [{"type": "github.issue.opened"}], "run": [PY, "s.py"], "emits": ["a1.result"]}
    a.update(over)
    return a


def errs_of(*items):
    return A.validate({"project": "p", "automations": list(items)})


def spec(**over):
    """Spec ya normalizado (pasa por `specs`, como en el agente)."""
    ss = A.specs({"project": "p", "automations": [auto(**over)]})
    assert ss, errs_of(auto(**over))
    return ss[0]


GH = {"repo": "o/r", "action": "opened", "url": "https://github.com/o/r/issues/1", "title": "t", "number": 1}


def envelope(type_="github.issue.opened", project="p", depth=0, **body):
    return {"v": 1, "id": "EV%s" % type_, "seq": 1, "ts": "2026-10-29T16:00:00Z", "machine": "host-a", "project": project,
            "type": type_, "severity": "info", "needs": None, "subject": {"kind": "issue", "id": "o/r#%s" % body.get("number", 1)},
            "cause": {"id": None, "depth": depth}, "body": body}


class Collect:
    def __init__(self):
        self.items, self.lock = [], threading.Lock()

    def __call__(self, env):
        with self.lock:
            self.items.append(copy.deepcopy(env))

    def types(self):
        return [e["type"] for e in self.items]

    def ran(self):
        return [e for e in self.items if e["type"] == "automation.ran"]


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-auto-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = os.path.join(self.tmp, "automations")
        self.secrets = os.path.join(self.tmp, "secrets")
        self.pdir = A.project_dir("p", self.root, create=True)

    def script(self, code, name="s.py", project="p"):
        d = A.project_dir(project, self.root, create=True)
        with open(os.path.join(d, name), "w") as f:
            f.write(textwrap.dedent(code))
        return os.path.join(d, name)

    def run1(self, s, trig=None, **kw):
        c = Collect()
        r = A.run_once(s, c, "test", trig, self.root, self.secrets, kw.pop("environ", {}), kw.pop("grace", 0.5))
        return r, c


# ---------------------------------------------------------------- validación

class TestValidate(unittest.TestCase):
    def test_ok_and_absent(self):
        self.assertEqual(A.validate({}), [])
        self.assertEqual(errs_of(auto()), [])
        self.assertEqual(errs_of(auto(on=["manual", {"type": "schedule", "every": "6h"}, {"type": "schedule", "cron": "*/15 9-18 * * 1-5"},
                                          {"type": "task.*", "where": {"needs": "bot"}}, {"type": "a1.result"}])), [])

    def test_argv(self):
        for bad in ("python3 s.py", [], [""], [PY, 3], None, [PY, "a\0b"]):
            self.assertTrue(any(".run " in e for e in errs_of(auto(run=bad))), bad)

    def test_emits(self):
        for bad in (["task.state"], ["automation.ran"], ["sinpunto"], ["Mayus.x"], ["a.*"], "a1.result", [3]):
            self.assertTrue(any("emits" in e for e in errs_of(auto(emits=bad))), bad)

    def test_timeout_and_limits(self):
        for bad in (0, 0.5, 901, "60", True, -1):
            self.assertTrue(any("timeout" in e for e in errs_of(auto(timeout=bad))), bad)
        self.assertEqual(errs_of(auto(timeout=1)), [])
        self.assertEqual(errs_of(auto(timeout=900)), [])
        self.assertTrue(errs_of(auto(max_runs_per_hour=0)))
        self.assertTrue(errs_of(auto(concurrency=9)))
        self.assertTrue(errs_of(auto(env=["PATH"])))
        self.assertTrue(errs_of(auto(env=["minus"])))
        self.assertTrue(errs_of(auto(secrets=["../x"])))
        self.assertTrue(errs_of(auto(cwd="../fuera")))
        self.assertTrue(errs_of(auto(cwd="/abs")))
        self.assertTrue(errs_of(auto(enabled="sí")))
        self.assertTrue(errs_of(auto(on_failure={"needs": "nadie"})))
        self.assertTrue(errs_of(auto(clave_rara=1)))

    def test_where(self):
        bad = [{"labels": "x"}, {"body": "x"}, {"subject.": 1}, {"body.x": {"igual": 1}}, {"body.x": {"regex": "("}},
               {"body.x": {"in": "no-lista"}}, {"project.x": 1}, {}, "texto", {"body.x": {}}, {"body.x": [{"a": 1}]}]
        for w in bad:
            self.assertTrue(any("where" in e for e in errs_of(auto(on=[{"type": "github.*", "where": w}]))), w)
        self.assertEqual(errs_of(auto(on=[{"type": "github.*", "where": {"body.labels": {"not": {"in": ["a", "b"]}},
                                                                       "subject.id": {"regex": "^o/"}, "severity": ["warn", "error"]}}])), [])

    def test_triggers(self):
        cases = [[], [{"every": "6h"}], [{"type": "schedule"}], [{"type": "schedule", "every": "6h", "cron": "* * * * *"}],
                 [{"type": "schedule", "every": "10s"}], [{"type": "schedule", "every": "mañana"}],
                 [{"type": "schedule", "cron": "* * *"}], [{"type": "schedule", "cron": "61 * * * *"}],
                 [{"type": "schedule", "cron": "*/0 * * * *"}], [{"type": "schedule", "every": "6h", "where": {"needs": "bot"}}],
                 [{"type": "manual", "every": "1h"}], [{"type": "desconocido.algo"}], [{"type": "GitHub.Issue"}],
                 [{"type": "github.*", "every": "1h"}], [{"type": "github.*", "filtro": 1}], [3]]
        for on in cases:
            self.assertTrue(errs_of(auto(on=on)), on)

    def test_names(self):
        self.assertTrue(any("repetido" in e for e in errs_of(auto(), auto())))
        self.assertTrue(errs_of(auto(name="con espacio")))
        self.assertEqual(A.validate({"automations": "x"}), ["automations: se esperaba una lista"])
        # las inválidas no llegan a `specs`; las válidas sí
        self.assertEqual([s["name"] for s in A.specs({"project": "p", "automations": [auto(), auto(name="b", run="mal")]})], ["a1"])


class TestProfileIntegration(Env):
    def test_profile_validate(self):
        self.assertIn("automations", profile.KNOWN)
        self.prof("p", "project: p\nscratch: true\nautomations:\n  - name: x\n    on: [manual]\n    run: python3 x.py\n")
        p = profile.load("p")
        self.assertEqual(p["_unknown"], [])
        self.assertTrue(any("automations.x.run" in e for e in profile.validate(p)))


# ---------------------------------------------------------------- where y cron

class TestWhere(unittest.TestCase):
    def test_table(self):
        env = envelope(number=7, labels=["bug", "ui"], title="Crash al abrir", state="open", draft=False, n=3)
        env.update(severity="warn", needs="bot")
        cases = [
            ({}, True),
            ({"project": "p"}, True), ({"project": "q"}, False),
            ({"severity": "warn"}, True), ({"severity": ["warn", "error"]}, True), ({"severity": {"in": ["info"]}}, False),
            ({"needs": "bot"}, True), ({"needs": {"not": "bot"}}, False),
            ({"type": "github.issue.opened"}, True),
            ({"subject.kind": "issue"}, True), ({"subject.id": {"regex": r"#7$"}}, True), ({"subject.id": {"regex": "#8$"}}, False),
            ({"body.labels": "bug"}, True), ({"body.labels": "docs"}, False),
            ({"body.labels": {"not": "triaged"}}, True), ({"body.labels": {"not": "ui"}}, False),
            ({"body.labels": {"in": ["docs", "ui"]}}, True), ({"body.labels": {"not": {"in": ["docs", "ui"]}}}, False),
            ({"body.title": {"regex": "(?i)crash"}}, True), ({"body.title": {"regex": "^Error"}}, False),
            ({"body.n": 3}, True), ({"body.n": "3"}, True), ({"body.n": 4}, False),
            ({"body.draft": False}, True), ({"body.draft": 0}, False),
            ({"body.falta": "x"}, False), ({"body.falta": {"not": "x"}}, True), ({"body.falta": {"regex": "."}}, False),
            ({"body.labels.sub": "x"}, False),
            ({"body.state": "open", "body.labels": "bug"}, True), ({"body.state": "open", "body.labels": "docs"}, False),
            ({"body.title": {"regex": "Crash", "not": {"regex": "abrir"}}}, False),
        ]
        for where, want in cases:
            self.assertEqual(A.where_match(where, env), want, where)


class TestCron(unittest.TestCase):
    def ts(self, y, mo, d, h, mi):
        return time.mktime((y, mo, d, h, mi, 0, 0, 0, -1))       # hora local de la máquina

    def test_match(self):
        c = A.parse_cron("*/15 9-18 * * 1-5")
        self.assertTrue(A.cron_match(c, self.ts(2026, 10, 29, 9, 30)))     # jueves
        self.assertFalse(A.cron_match(c, self.ts(2026, 10, 29, 9, 31)))
        self.assertFalse(A.cron_match(c, self.ts(2026, 10, 29, 19, 0)))
        self.assertFalse(A.cron_match(c, self.ts(2026, 11, 1, 9, 30)))      # domingo
        sun = A.parse_cron("0 0 * * 7")
        self.assertTrue(A.cron_match(sun, self.ts(2026, 11, 1, 0, 0)))
        either = A.parse_cron("0 12 1 * 1")                                   # día 1 O lunes (como cron)
        self.assertTrue(A.cron_match(either, self.ts(2026, 10, 1, 12, 0)))
        self.assertTrue(A.cron_match(either, self.ts(2026, 10, 26, 12, 0)))
        self.assertFalse(A.cron_match(either, self.ts(2026, 10, 27, 12, 0)))
        self.assertEqual(A.parse_cron("5,10-12 * * * *")["min"], {5, 10, 11, 12})
        self.assertEqual(A.parse_every("6h"), 21600)
        self.assertIsNone(A.parse_every("0m"))


# ---------------------------------------------------------------- disparadores

class TestTriggers(Tmp):
    def engine(self, items, clock=None, store=None):
        c = Collect()
        e = A.Automations(c, profiles_fn=lambda: [{"project": "p", "automations": items}], root=self.root,
                          secrets_root=self.secrets, clock=clock or time.time, store=store, environ={}, grace=0.5)
        e.reload()
        return e, c

    def test_event_and_where(self):
        e, _ = self.engine([auto(name="t", on=[{"type": "github.issue.*", "where": {"body.labels": {"not": "triaged"}}}]),
                            auto(name="todo", on=["*"], emits=["todo.x"]), auto(name="off", enabled=False)])
        hit = lambda env: sorted(n for _, n in ((s["project"], s["name"]) for s, _ in e.matches(env)))  # noqa: E731
        self.assertEqual(hit(envelope(labels=["bug"])), ["t", "todo"])
        self.assertEqual(hit(envelope(labels=["triaged"])), ["todo"])
        self.assertEqual(hit(envelope("github.pr.opened")), ["todo"])
        self.assertEqual(hit(envelope(project="otro")), [])                    # solo sobres de su proyecto
        e.enabled = False                                                       # interruptor global
        self.assertEqual(hit(envelope()), [])

    def test_anti_loops(self):
        e, _ = self.engine([auto(name="t", on=["*"], emits=["t.result"]), auto(name="u", on=["t.result"], emits=["u.result"])])
        names = lambda env: sorted(s["name"] for s, _ in e.matches(env))  # noqa: E731
        self.assertEqual(names(envelope(depth=2)), ["t"])
        self.assertEqual(names(envelope(depth=3)), [])                          # cause.depth >= 3 no dispara
        self.assertEqual(names(envelope(depth=7)), [])
        self.assertEqual(names(envelope("t.result")), ["u"])                    # t no se dispara con sus emits
        ran = envelope("automation.ran", automation="t")
        self.assertEqual(names(ran), [])                                        # t no oye su propio automation.ran
        e2, _ = self.engine([auto(name="t", on=["automation.ran"], emits=["t.result"])])
        self.assertEqual(e2.matches(envelope("automation.ran", automation="t")), [])
        self.assertEqual(len(e2.matches(envelope("automation.ran", automation="otra"))), 1)

    def test_legacy_rows(self):
        """Un dict con el nombre viejo (`event`, sin `type`) se traduce con envelope.from_legacy."""
        e, _ = self.engine([auto(name="q", on=[{"type": "question.opened", "where": {"needs": "bot"}}])])
        row = {"seq": 9, "ts": 1.0, "machine_id": "h", "event": "pending_question", "project": "p",
               "body": {"summary": "?", "request": "rq-1", "level": "bot"}}
        self.assertEqual(len(e.matches(row)), 1)
        self.assertEqual(e.matches(dict(row, cause={"id": "X", "depth": 3})), [])
        env = A.normalize(row)
        self.assertEqual((env["type"], env["id"], env["needs"], env["body"]["legacy"]), ("question.opened", "seq-9", "bot", "pending_question"))

    def test_schedule_every_with_clock(self):
        self.script("print('{\"type\": \"a1.result\"}')\n")
        now = [1_000_000.0]
        store = {}
        e, c = self.engine([auto(on=[{"type": "schedule", "every": "6h"}])], clock=lambda: now[0], store=store)
        self.assertEqual(e.tick(), [])                                          # primera vez: siembra sin disparar
        now[0] += 6 * 3600 - 1
        self.assertEqual(e.tick(), [])
        now[0] += 1
        self.assertEqual(e.tick(), [("p", "a1")])
        self.assertEqual(e.tick(), [])
        e.wait_idle(10)
        self.assertEqual(c.types(), ["a1.result", "automation.ran"])
        self.assertEqual(c.ran()[0]["body"]["trigger"], "schedule")
        now[0] += 3 * 86400                                                     # caída larga: una sola vez
        self.assertEqual(e.tick(), [("p", "a1")])
        self.assertEqual(e.tick(), [])
        e.wait_idle(10)

    def test_schedule_cron_with_clock(self):
        self.script("pass\n")
        base = time.mktime((2026, 10, 29, 8, 58, 10, 0, 0, -1))
        now = [base]
        e, c = self.engine([auto(on=[{"type": "schedule", "cron": "0 9 * * *"}])], clock=lambda: now[0])
        self.assertEqual(e.tick(), [])
        now[0] = base + 60                                                      # 08:59:10
        self.assertEqual(e.tick(), [])
        now[0] = base + 115                                                     # 09:00:05
        self.assertEqual(e.tick(), [("p", "a1")])
        now[0] = base + 150
        self.assertEqual(e.tick(), [])                                          # mismo minuto: no repite
        now[0] = base + 86400 + 3600                                            # al día siguiente, tarde: se recupera una vez
        self.assertEqual(e.tick(), [("p", "a1")])
        e.wait_idle(10)
        self.assertEqual(len(c.ran()), 2)

    def test_event_dispatch_end_to_end(self):
        self.script("""
            import json, os
            env = json.load(open(os.environ["CHOPSHOP_EVENT_FILE"]))
            print(json.dumps({"type": "a1.result", "body": {"n": env["body"]["number"]}}))
        """)
        e, c = self.engine([auto()])
        self.assertEqual(e.on_event(envelope(number=42)), [("p", "a1")])
        e.wait_idle(10)
        res, ran = c.items
        self.assertEqual(res["body"], {"n": 42})
        self.assertEqual(res["cause"], {"id": "EVgithub.issue.opened", "depth": 1})
        self.assertEqual((ran["body"]["trigger"], ran["body"]["trigger_event"], ran["body"]["emitted"]),
                         ("github.issue.opened", "EVgithub.issue.opened", 1))


# ---------------------------------------------------------------- runner

def _dead(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().split(")")[-1].split()[0] in ("Z", "X")
    except FileNotFoundError:
        return True


class TestRunner(Tmp):
    def test_success_and_output_rules(self):
        self.script("""
            import json
            print(json.dumps({"type": "a1.result", "severity": "notice", "needs": "bot", "subject": {"kind": "issue", "id": "x"}, "body": {"k": 1}}))
            print("esto no es json")
            print(json.dumps({"type": "otro.tipo", "body": {}}))
            print(json.dumps(["lista"]))
            print(json.dumps({"type": "a1.result", "severity": "rara", "needs": "nadie", "body": "no-mapa"}))
            print()
        """)
        r, c = self.run1(spec(), envelope(depth=1))
        self.assertEqual((r["exit"], r["emitted"], r["discarded"]), (0, 2, 3))
        a, b, ran = c.items
        self.assertEqual((a["type"], a["severity"], a["needs"], a["body"], a["project"]), ("a1.result", "notice", "bot", {"k": 1}, "p"))
        self.assertEqual(a["cause"]["depth"], 2)
        self.assertEqual((b["severity"], b["needs"], b["body"]), ("info", None, {}))
        self.assertEqual(b["subject"], {"kind": "automation", "id": "a1"})
        ids = [x["id"] for x in r["envelopes"]] + [r["ran"]["id"]]
        self.assertEqual(len(set(ids)), 3)
        self.assertEqual(ran["type"], "automation.ran")
        self.assertEqual((ran["severity"], ran["body"]["exit"], ran["body"]["discarded"]), ("warn", 0, 3))
        self.assertIn("3 líneas descartadas", ran["body"]["error"])
        logs = A.read_log("p", "a1", root=self.root)
        self.assertEqual((logs[-1]["emitted"], logs[-1]["discarded"]), (2, 3))

    def test_failure_emits_ran(self):
        self.script("import sys\nprint('{\"type\": \"a1.result\"}')\nsys.stderr.write('se rompió')\nsys.exit(3)\n")
        r, c = self.run1(spec(on_failure={"needs": "bot"}))
        self.assertEqual(c.types(), ["a1.result", "automation.ran"])
        ran = c.ran()[0]
        self.assertEqual((ran["severity"], ran["needs"], ran["body"]["exit"], ran["body"]["error"]), ("error", "bot", 3, "exit 3"))
        self.assertIn("se rompió", ran["body"]["stderr_tail"])

    def test_missing_executable_emits_ran(self):
        r, c = self.run1(spec(run=["/no/existe/bin"]))
        self.assertEqual(c.types(), ["automation.ran"])
        self.assertEqual(c.ran()[0]["severity"], "error")
        self.assertIn("no se pudo ejecutar", c.ran()[0]["body"]["error"])

    def test_timeout_kills_whole_group(self):
        self.script("""
            import os, subprocess, sys, time
            kid = "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
            ps = [subprocess.Popen([sys.executable, "-c", kid]) for _ in range(2)]
            open("pids", "w").write(" ".join(str(x) for x in [p.pid for p in ps] + [os.getpid()]))
            print('{"type": "a1.result"}', flush=True)
            time.sleep(60)
        """)
        t0 = time.monotonic()
        r, c = self.run1(spec(timeout=1), grace=0.3)
        self.assertLess(time.monotonic() - t0, 10)
        self.assertTrue(r["timed_out"], r)
        with open(os.path.join(self.pdir, "pids")) as f:
            pids = [int(x) for x in f.read().split()]
        end = time.monotonic() + 5
        while time.monotonic() < end and not all(_dead(p) for p in pids):
            time.sleep(0.05)
        self.assertTrue(all(_dead(p) for p in pids), pids)                      # hijo y nietos (que ignoran SIGTERM)
        self.assertEqual(c.types(), ["automation.ran"])                         # lo escrito antes del timeout no se publica
        ran = c.ran()[0]
        self.assertEqual((ran["severity"], ran["body"]["timed_out"], ran["body"]["error"]), ("error", True, "timeout (1s)"))

    def test_clean_env(self):
        os.makedirs(self.secrets)
        with open(os.path.join(self.secrets, "triage_token"), "w") as f:
            f.write("no-se-lee")
        environ = {"GITHUB_REPO": "o/r", "HOME": "/casa/x", "SECRET_X": "filtrado", "PATH": "/opt/raro:/usr/bin",
                   "CHOPSHOP_HOME": "/x", "LD_PRELOAD": "/x.so"}
        r, c = self.run1(spec(run=["env"], env=["GITHUB_REPO", "NO_DEFINIDA"], secrets=["triage_token", "falta"]), envelope(),
                         environ=environ)
        got = dict(line.split("=", 1) for line in r["stdout"].splitlines())
        self.assertEqual(set(got), {"PATH", "GITHUB_REPO", "TRIAGE_TOKEN_FILE", "CHOPSHOP_EVENT_FILE", "CHOPSHOP_PROJECT",
                                    "CHOPSHOP_AUTOMATION"})
        self.assertEqual((got["PATH"], got["GITHUB_REPO"], got["CHOPSHOP_PROJECT"], got["CHOPSHOP_AUTOMATION"]),
                         (A.MIN_PATH, "o/r", "p", "a1"))
        self.assertEqual(got["TRIAGE_TOKEN_FILE"], os.path.join(self.secrets, "triage_token"))
        self.assertFalse(os.path.exists(got["CHOPSHOP_EVENT_FILE"]))            # el archivo del sobre se borra al terminar
        self.assertNotIn("no-se-lee", json.dumps(c.items))
        self.assertEqual(r["discarded"], 6)                                     # líneas de `env` no son JSON

    def test_event_file_stdin_cwd_limits(self):
        os.makedirs(os.path.join(self.pdir, "sub"))
        self.script("""
            import json, os, resource, stat, sys
            p = os.environ["CHOPSHOP_EVENT_FILE"]
            out = {"cwd": os.getcwd(), "mode": oct(stat.S_IMODE(os.stat(p).st_mode)), "type": json.load(open(p))["type"],
                   "stdin": sys.stdin.read(), "pgid_is_pid": os.getpgid(0) == os.getpid(),
                   "nofile": resource.getrlimit(resource.RLIMIT_NOFILE)[0], "as": resource.getrlimit(resource.RLIMIT_AS)[0],
                   "cpu": resource.getrlimit(resource.RLIMIT_CPU)[0]}
            print(json.dumps({"type": "a1.result", "body": out}))
        """, name="sub/s.py")
        r, c = self.run1(spec(cwd="sub", timeout=10), envelope())
        b = c.items[0]["body"]
        self.assertEqual(b["cwd"], os.path.realpath(os.path.join(self.pdir, "sub")))
        self.assertEqual((b["mode"], b["type"], b["stdin"], b["pgid_is_pid"]), ("0o600", "github.issue.opened", "", True))
        self.assertLessEqual(b["nofile"], A.NOFILE_LIMIT)
        self.assertLessEqual(b["as"], A.AS_LIMIT)
        self.assertEqual(b["cpu"], 15)

    def test_output_cap(self):
        self.script("import sys\nsys.stdout.write('x' * (600 * 1024))\nsys.stderr.write('y' * (300 * 1024))\n")
        r, c = self.run1(spec())
        self.assertEqual((len(r["stdout"]), len(r["stderr"]), r["truncated"], r["exit"]), (A.OUT_CAP, A.OUT_CAP, True, 0))
        self.assertTrue(c.ran()[0]["body"]["truncated"])
        self.assertLessEqual(len(c.ran()[0]["body"]["stdout_tail"]), A.TAIL)


# ---------------------------------------------------------------- límites

class TestLimits(Tmp):
    def engine(self, item, clock=time.time):
        c = Collect()
        e = A.Automations(c, profiles_fn=lambda: [{"project": "p", "automations": [item]}], root=self.root,
                          clock=clock, environ={}, grace=0.5)
        e.reload()
        return e, e.specs[0], c

    def test_max_runs_per_hour(self):
        self.script("pass\n")
        now = [1000.0]
        e, s, c = self.engine(auto(max_runs_per_hour=2), clock=lambda: now[0])
        self.assertEqual([e.submit(s, "manual", None, wait=True) for _ in range(3)], ["started", "started", "rate_limited"])
        now[0] += 1800
        self.assertEqual(e.submit(s, "manual", None), "rate_limited")
        now[0] += 1801
        self.assertEqual(e.submit(s, "manual", None, wait=True), "started")
        self.assertEqual(len(c.ran()), 3)
        self.assertEqual(e.stats[("p", "a1")]["rate_limited"], 2)

    def test_concurrency_one_serializes_and_dedupes(self):
        self.script("import time\ntime.sleep(0.4)\n")
        e, s, c = self.engine(auto())
        out = [e.submit(s, "t", envelope(number=1)), e.submit(s, "t", envelope(number=1)),   # mismo sujeto en curso
               e.submit(s, "t", envelope(number=2)), e.submit(s, "t", envelope(number=2)),   # mismo sujeto en cola
               e.submit(s, "t", envelope(number=3))]
        self.assertEqual(out, ["started", "duplicate", "queued", "duplicate", "queued"])
        self.assertTrue(e.wait_idle(20))
        self.assertEqual(e.stats[("p", "a1")]["peak"], 1)
        self.assertEqual([r["body"]["trigger_event"] for r in c.ran()], ["EVgithub.issue.opened"] * 3)
        self.assertEqual(e.stats[("p", "a1")]["runs"], 3)

    def test_concurrency_two(self):
        self.script("import time\ntime.sleep(0.4)\n")
        e, s, c = self.engine(auto(concurrency=2))
        out = [e.submit(s, "t", envelope(number=n)) for n in range(4)]
        self.assertEqual(out, ["started", "started", "queued", "queued"])
        self.assertTrue(e.wait_idle(20))
        self.assertEqual(e.stats[("p", "a1")]["peak"], 2)
        self.assertEqual(len(c.ran()), 4)


# ---------------------------------------------------------------- ejemplo triage + CLI

class CliBase(Env):
    def setUp(self):
        super().setUp()
        self.root = os.path.join(self.tmp, "automations")

    def cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        code = A.main(list(argv), out, err)
        return code, out.getvalue(), err.getvalue()

    def install_example(self):
        shutil.copy(os.path.join(EXAMPLE, "profile.yaml"), os.path.join(self.tmp, "profiles", "demo.yaml"))
        code, out, err = self.cli("add", "demo", "triage", "--script", os.path.join(EXAMPLE, "triage.py"))
        self.assertEqual(code, 0, err)


class TestExampleTriage(CliBase):
    def test_check_passes(self):
        self.install_example()
        prof = profile.load("demo")
        self.assertEqual(profile.validate(prof), [])
        code, out, _ = self.cli("check", "demo")
        self.assertEqual(code, 0, out)
        self.assertIn("ok: demo", out)
        self.assertEqual(oct(os.stat(os.path.join(self.root, "demo")).st_mode & 0o777), "0o700")

    def test_end_to_end(self):
        self.install_example()
        ev = {"v": 1, "id": "01JC9Z3K8Q2X4T7M5N6P8R0VWA", "seq": 1842, "ts": "2026-10-29T16:12:03Z", "machine": "host-a",
              "project": "demo", "type": "github.issue.opened", "severity": "info", "needs": None,
              "subject": {"kind": "issue", "id": "o/r#42"}, "cause": {"id": None, "depth": 0},
              "body": {"repo": "o/r", "number": 42, "title": "Crash al abrir la app", "url": "https://github.com/o/r/issues/42",
                       "labels": ["bug"], "state": "open"}}
        c = Collect()
        e = A.Automations(c, root=self.root, environ={})
        e.reload()
        self.assertEqual(e.on_event(ev), [("demo", "triage")])
        self.assertEqual(e.on_event(dict(ev, body=dict(ev["body"], labels=["triaged"]))), [])   # where
        e.wait_idle(20)
        res, ran = c.items
        self.assertEqual((res["type"], res["needs"], res["severity"]), ("triage.result", "bot", "notice"))
        self.assertEqual((res["body"]["kind"], res["body"]["priority"], res["body"]["number"]), ("bug", "alta", 42))
        self.assertEqual(res["subject"]["id"], "o/r#42")
        self.assertEqual(res["cause"], {"id": ev["id"], "depth": 1})
        self.assertEqual((ran["body"]["exit"], ran["body"]["emitted"], ran["severity"]), (0, 1, "info"))
        # y por la CLI, con --event-file y sin publicar
        p = os.path.join(self.tmp, "ev.json")
        with open(p, "w") as f:
            json.dump(ev, f)
        code, out, err = self.cli("run", "demo", "triage", "--event-file", p, "--dry-run", "--json")
        self.assertEqual(code, 0, err)
        r = json.loads(out)
        self.assertEqual([x["type"] for x in r["envelopes"]], ["triage.result", "automation.ran"])
        code, out, _ = self.cli("logs", "demo", "triage")
        self.assertEqual(len(out.strip().splitlines()), 2)


class TestCli(CliBase):
    def test_list_check_errors_and_add_append(self):
        self.prof("p", "project: p\nscratch: true\n")
        src = os.path.join(self.tmp, "job.py")
        with open(src, "w") as f:
            f.write("print('{\"type\": \"job.done\"}')\n")
        code, out, err = self.cli("add", "p", "job", "--script", src, "--on", "github.*", "--on", "every:6h", "--emits", "job.done",
                                  "--timeout", "30", "--append")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.cli("add", "p", "job", "--script", src)[0], 1)    # ya existe sin --force
        code, out, _ = self.cli("list", "p")
        self.assertIn("p/job  github.*, schedule(6h)", out)
        self.assertEqual(self.cli("check", "p")[0], 0)
        code, out, err = self.cli("run", "p", "job", "--dry-run")
        self.assertEqual(code, 0, err)
        self.assertIn("emitidos=1", out)
        # perfil roto: check falla y lo dice
        self.prof("p", "project: p\nscratch: true\nautomations:\n  - name: job\n    on: [nada.raro]\n    run: [python3, falta.py]\n"
                       "    timeout: 5000\n    emits: [task.state]\n")
        code, out, _ = self.cli("check", "p")
        self.assertEqual(code, 1)
        for frag in ("timeout", "emits", "type desconocido"):
            self.assertIn(frag, out)
        self.assertEqual(self.cli("run", "p", "job")[0], 1)

    def test_check_runtime(self):
        self.prof("p", "project: p\nscratch: true\nautomations:\n  - name: job\n    on: [manual]\n    run: [python3, falta.py]\n"
                       "    secrets: [tok]\n")
        code, out, _ = self.cli("check", "p")
        self.assertEqual(code, 1)
        self.assertIn("no existe la carpeta", out)
        A.project_dir("p", self.root, create=True)
        code, out, _ = self.cli("check", "p")
        self.assertIn("falta el script falta.py", out)
        self.assertIn("aviso: p: job: falta el secreto tok", out)

    def test_dispatch_from_main_cli(self):
        self.prof("p", "project: p\nscratch: true\n")
        out = io.StringIO()
        from contextlib import redirect_stdout
        with redirect_stdout(out):
            self.assertEqual(cli.main(["automation", "list", "p"]), 0)


# ---------------------------------------------------------------- hilo del servicio

class TestService(Env):
    def setUp(self):
        super().setUp()
        cfg = copy.deepcopy(settings.DEFAULTS["agent"])
        cfg.update(machine_id="host-a", db_path=os.path.join(self.tmp, "agent", "agent.db"), token_file=os.path.join(self.tmp, "tok"),
                   projects_root=self.tmp, worktrees_root=self.tmp, t3_enabled=False, import_legacy=False)
        self.conn = db.connect(cfg["db_path"])
        self.addCleanup(self.conn.close)
        self.addCleanup(events.flush)
        self.svc = service.AgentService(cfg, conn=self.conn)
        self.svc.automations.environ = {}
        d = A.project_dir("p", None, create=True)
        with open(os.path.join(d, "t.py"), "w") as f:
            f.write("import json, os\nenv = json.load(open(os.environ['CHOPSHOP_EVENT_FILE']))\n"
                    "print(json.dumps({'type': 't.result', 'body': {'from': env.get('type')}}))\n")
        with open(os.path.join(d, "u.py"), "w") as f:
            f.write("print('{\"type\": \"u.result\"}')\n")
        # t escucha github.* y u.result; u escucha t.result: cadena t -> u -> t ... que el anti-bucle corta
        self.prof("p", "project: p\nscratch: true\nautomations:\n"
                       "  - name: t\n    on: ['github.*', u.result]\n    run: [%s, t.py]\n    emits: [t.result]\n"
                       "  - name: u\n    on: [t.result]\n    run: [%s, u.py]\n    emits: [u.result]\n" % (PY, PY))

    def rows(self):
        return [A.normalize(r) for r in events.list_after(self.conn, 0, 1000)]

    def pump(self):
        for _ in range(10):
            fired = self.svc.automations_once()
            self.svc.automations.wait_idle(20)
            if not fired:
                break

    def test_bus_to_scripts_and_back(self):
        self.svc.emit("agent_started", None, {"version": "x"})                   # historial previo: no se reprocesa
        self.svc.automations_once()
        A.bus_emit(self.conn, self.svc.cfg, {"type": "github.issue.opened", "project": "p", "id": "G1", "severity": "info",
                                             "needs": None, "subject": {"kind": "issue", "id": "o/r#1"},
                                             "cause": {"id": None, "depth": 0}, "body": GH})
        self.pump()
        chain = [(e["type"], e["cause"]["depth"]) for e in self.rows() if e["project"] == "p"]
        self.assertEqual(chain, [("github.issue.opened", 0),
                                 ("t.result", 1), ("automation.ran", 1),
                                 ("u.result", 2), ("automation.ran", 2),
                                 ("t.result", 3), ("automation.ran", 3)])           # depth 3: u ya no se dispara
        for e in events.list_after(self.conn, 0, 1000):                           # todo cumple el contrato de A
            self.assertEqual(envmod.errors({k: v for k, v in e.items() if k not in ("event", "machine_id")}), [], e)
        t1 = [e for e in self.rows() if e["type"] == "t.result"][0]
        self.assertEqual(t1["body"], {"from": "github.issue.opened"})
        self.assertEqual(t1["cause"]["id"], self.rows()[1]["id"])                 # el id que el bus dio al sobre de GitHub
        # el cursor sobrevive: un servicio nuevo no reprocesa
        svc2 = service.AgentService(self.svc.cfg, conn=self.conn)
        self.assertEqual(svc2.automations_once(), [])

    def test_disabled_globally(self):
        cfg = dict(self.svc.cfg, automations={"enabled": False, "interval": 2})
        svc = service.AgentService(cfg, conn=self.conn)
        svc.automations_once()
        A.bus_emit(self.conn, cfg, {"type": "github.issue.opened", "project": "p", "body": GH})
        self.assertEqual(svc.automations_once(), [])


if __name__ == "__main__":
    unittest.main()
