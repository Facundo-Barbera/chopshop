import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import dispatcher, employees, home, profile, queue as equeue, state, t3  # noqa: E402
from chopshop.agent import db  # noqa: E402
from chopshop.mcp import tools as mcp_tools  # noqa: E402

CONFIG = """[general]
default_host = "host-a"

[hosts.host-a]
cap = 4
purpose = "dev"
t3_bin = "t3"
"""

PROFILE = """project: dp
scratch: true
office:
  floors:
    - name: P
      rooms:
        - role: alpha
          desks: 1
          permanent: true
        - role: beta
          desks: 1
          permanent: true
        - role: gamma
          desks: 1
          permanent: true
"""


class _Client:
    def __init__(self, fake, host):
        self.fake, self.host = fake, host

    def call(self, tool, args=None):
        return self.fake(self.host, tool, args or {})


class FakeT3:
    def __init__(self):
        self.calls, self.status, self.n = [], {}, 0
        self.fail_launch, self.fail_settle = set(), 0

    def __call__(self, host, tool, args):
        self.calls.append((tool, args))
        if tool == "t3_thread_launch":
            if any(m in args["message"] for m in self.fail_launch):
                raise t3.T3Error("launch boom")
            self.n += 1
            tid = "th-%d" % self.n
            self.status[tid] = "running"
            return {"threadId": tid, "link": "L" + tid, "status": "running"}
        if tool == "t3_thread_read":
            return {"thread": {"status": self.status[args["threadId"]], "pendingRequestCount": 0, "pullRequests": []},
                    "items": [{"type": "assistant_message", "text": "ok"}]}
        if tool == "t3_pending_request":
            return {"requestIds": []}
        if tool == "t3_thread_organize":
            if self.fail_settle:
                self.fail_settle -= 1
                raise t3.T3Error("settle boom")
            return {}
        if tool == "t3_thread_interrupt":
            self.status[args["threadId"]] = "interrupted"
            return {}
        raise AssertionError(tool)

    def tools(self, name):
        return [a for t, a in self.calls if t == name]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="chopshop-disp-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        saved = {k: v for k, v in os.environ.items() if k.startswith("CHOPSHOP_")}
        self.addCleanup(self._restore, saved)
        os.environ["CHOPSHOP_HOME"] = os.path.join(self.tmp, "home")
        os.environ["CHOPSHOP_CONFIG"] = os.path.join(self.tmp, "config.toml")
        with open(os.environ["CHOPSHOP_CONFIG"], "w") as f:
            f.write(CONFIG + '\n[agent]\ndb_path = "%s"\n' % os.path.join(self.tmp, "agent.db"))
        os.makedirs(home.profiles_dir())
        with open(os.path.join(home.profiles_dir(), "dp.yaml"), "w") as f:
            f.write(PROFILE)
        self.fake = FakeT3()
        t3.set_client_factory(lambda hc, host, timeout: _Client(self.fake, host))
        self.addCleanup(t3.set_client_factory, None)
        self.conn = db.connect(os.path.join(self.tmp, "agent.db"))
        self.addCleanup(self.conn.close)
        self.prof = profile.load("dp")
        employees.ensure_schema(self.conn)
        employees.sync(self.conn, self.prof)
        self.emps = [e["id"] for e in employees.listing(self.conn, self.prof)]
        self.queue = equeue.Queue(self.conn)

    def _restore(self, saved):
        for k in [k for k in os.environ if k.startswith("CHOPSHOP_")]:
            del os.environ[k]
        os.environ.update(saved)

    def disp(self, slots=None, **kw):
        return dispatcher.Dispatcher(self.conn, self.queue, self.prof, slots=slots, **kw)

    def enqueue(self, emp, title):
        return self.queue.enqueue(emp, title, "human")[0]["task"]

    def finish_all(self, status="completed"):
        for tid in self.fake.status:
            if self.fake.status[tid] == "running":
                self.fake.status[tid] = status
        dispatcher.launch(None)

    def launched_titles(self):
        return [a["message"].rsplit("\n", 1)[-1] for a in self.fake.tools("t3_thread_launch")]


class TestMaxThreads(Base):
    def test_slots_cap_parallel_threads(self):
        for i, e in enumerate(self.emps):
            self.enqueue(e, "t%d" % i)
        d = self.disp(slots=2)
        out = d.tick()
        self.assertEqual([o["employee"] for o in out], self.emps[:2])
        self.assertEqual(len(self.fake.tools("t3_thread_launch")), 2)
        self.assertEqual(d.tick(), [])
        self.assertEqual(self.queue.length(self.emps[2]), 1)
        self.finish_all()
        out = d.tick()
        self.assertEqual([o["employee"] for o in out], [self.emps[2]])
        self.assertEqual(self.launched_titles(), ["t0", "t1", "t2"])

    def test_max_threads_from_settings(self):
        self.assertEqual(dispatcher.max_threads(), dispatcher.DEFAULT_MAX_THREADS)
        with open(os.environ["CHOPSHOP_CONFIG"], "a") as f:
            f.write("\n[agent.dispatcher]\nmax_threads = 1\n")
        self.assertEqual(dispatcher.max_threads(), 1)
        for e in self.emps:
            self.enqueue(e, "x")
        self.assertEqual(len(self.disp().tick()), 1)

    def test_free_never_negative(self):
        d = self.disp(slots=1)
        self.assertEqual(d.free({"a": 1, "b": 2}), 0)


class TestQueueOrder(Base):
    def test_one_thread_per_employee_in_fifo_order(self):
        e = self.emps[0]
        tasks = [self.enqueue(e, "paso-%d" % i) for i in range(3)]
        d = self.disp(slots=3)
        out = d.tick()
        self.assertEqual([o["task"] for o in out], tasks[:1])
        self.assertEqual(d.tick(), [])
        for i in (1, 2):
            self.finish_all()
            out = d.tick()
            self.assertEqual([o["task"] for o in out], [tasks[i]])
        self.finish_all()
        d.tick()
        self.assertEqual(self.launched_titles(), ["paso-0", "paso-1", "paso-2"])
        self.assertEqual([self.queue.get(t)["state"] for t in tasks], ["done"] * 3)

    def test_priority_then_seq(self):
        e = self.emps[0]
        low = self.enqueue(e, "baja")
        high = self.queue.enqueue(e, "alta", "human", priority=5)[0]["task"]
        self.assertEqual(self.disp(slots=1).tick()[0]["task"], high)
        self.assertEqual(self.queue.get(low)["state"], "queued")

    def test_prompt_from_extra(self):
        self.queue.enqueue(self.emps[0], "titulo", "human", extra={"prompt": "haz la cosa"})
        self.disp().tick()
        self.assertTrue(self.fake.tools("t3_thread_launch")[0]["message"].endswith("haz la cosa"))


class TestCancelRunning(Base):
    def test_cancel_interrupts_and_closes_as_cancelled(self):
        e = self.emps[0]
        task = self.enqueue(e, "larga")
        nxt = self.enqueue(e, "siguiente")
        d = self.disp(slots=2)
        d.tick()
        tools = mcp_tools.Tools(None, None, conn=self.conn)
        r = tools.task_cancel(task, reason="manual", note="ya no")
        self.assertEqual((r["state"], r["phase"], r["thread_id"]), ("cancelled", "running", "th-1"))
        self.assertEqual(self.fake.tools("t3_thread_interrupt"), [{"threadId": "th-1", "reason": "chopshop: tarea %s cancelada" % task}])
        closed = d.close()
        self.assertEqual(len(closed), 1)
        self.assertEqual((closed[0]["state"], closed[0]["task"], closed[0]["settled"]), ("cancelled", task, True))
        self.assertIn("cancelada por human", closed[0]["reason"])
        self.assertEqual(self.queue.get(task)["state"], "cancelled")
        out = d.dispatch()
        self.assertEqual([o["task"] for o in out], [nxt])

    def test_cancel_before_thread_is_rejected(self):
        task = self.enqueue(self.emps[0], "x")
        self.disp(launch_fn=None).tick()
        with self.assertRaises(mcp_tools.ToolError):
            mcp_tools.Tools(None, None, conn=self.conn).task_cancel(task)
        self.assertEqual(self.fake.tools("t3_thread_interrupt"), [])


class TestLaunchFailure(Base):
    def test_launch_failure_fails_task_once_and_frees_employee(self):
        e = self.emps[0]
        bad = self.enqueue(e, "rompe")
        good = self.enqueue(e, "sana")
        self.fake.fail_launch.add("rompe")
        d = self.disp(slots=1)
        self.assertEqual([o["task"] for o in d.tick()], [bad])
        for _ in range(3):
            dispatcher.launch(None)
        closed = d.close()
        self.assertEqual([(c["task"], c["state"], c["thread_id"]) for c in closed], [(bad, "failed", None)])
        self.assertIn("launch boom", closed[0]["reason"])
        q = self.queue.get(bad)
        self.assertEqual(q["state"], "failed")
        self.assertTrue(q["note"].startswith("launch_failed"))
        self.assertEqual([o["task"] for o in d.dispatch()], [good])
        for _ in range(3):
            d.tick()
        launches = self.launched_titles()
        self.assertEqual(launches.count("rompe"), 1)
        self.assertEqual(launches.count("sana"), 1)
        self.assertEqual(self.fake.tools("t3_thread_organize"), [])


class TestClose(Base):
    def test_close_settles_and_finishes_done(self):
        task = self.enqueue(self.emps[0], "x")
        d = self.disp()
        d.tick()
        self.assertEqual(d.close(), [])
        self.finish_all()
        closed = d.close()
        self.assertEqual(closed, [{"employee": self.emps[0], "task": task, "state": "done", "reason": None,
                                   "settled": True, "thread_id": "th-1"}])
        self.assertEqual(self.fake.tools("t3_thread_organize"), [{"threadId": "th-1", "action": "settle"}])
        self.assertEqual(self.queue.get(task)["state"], "done")
        t = state.read()["batches"]["b-0001"]["tasks"][0]
        self.assertTrue(t["closed"] and t["settled"])
        self.assertEqual(d.close(), [])
        self.assertEqual(len(self.fake.tools("t3_thread_organize")), 1)

    def test_failed_thread_closes_failed(self):
        task = self.enqueue(self.emps[0], "x")
        d = self.disp()
        d.tick()
        self.finish_all("failed")
        closed = d.close()
        self.assertEqual((closed[0]["state"], closed[0]["reason"], closed[0]["settled"]), ("failed", "failed", True))
        self.assertEqual(self.queue.get(task)["state"], "failed")

    def test_settle_retries_then_closes_with_reason(self):
        task = self.enqueue(self.emps[0], "x")
        d = self.disp()
        d.tick()
        self.finish_all()
        self.fake.fail_settle = 99
        for _ in range(dispatcher.SETTLE_TRIES - 1):
            self.assertEqual(d.close(), [])
            self.assertEqual(self.queue.get(task)["state"], "dequeued")
        closed = d.close()
        self.assertEqual((closed[0]["state"], closed[0]["settled"]), ("done", False))
        self.assertEqual(closed[0]["reason"], "settle: host-a: settle boom")
        self.assertEqual(self.queue.get(task)["state"], "done")
        self.assertEqual(len(self.fake.tools("t3_thread_organize")), dispatcher.SETTLE_TRIES)
        self.assertEqual(d.close(), [])

    def test_settle_recovers_after_transient_error(self):
        self.enqueue(self.emps[0], "x")
        d = self.disp()
        d.tick()
        self.finish_all()
        self.fake.fail_settle = 1
        self.assertEqual(d.close(), [])
        closed = d.close()
        self.assertEqual((closed[0]["state"], closed[0]["settled"], closed[0]["reason"]), ("done", True, None))

    def test_busy_employee_waits_until_thread_done(self):
        e = self.emps[0]
        self.enqueue(e, "a")
        self.enqueue(e, "b")
        d = self.disp(slots=3)
        d.tick()
        dispatcher.launch(None)
        self.assertEqual(d.dispatch(), [])
        self.finish_all()
        self.assertEqual(len(d.dispatch()), 1)
        self.assertEqual(len(dispatcher.live(state.read())), 1)


class TestOutcome(unittest.TestCase):
    def test_outcome(self):
        self.assertEqual(dispatcher.outcome({"cancelled": True, "last_error": "x"}), ("cancelled", "x"))
        self.assertEqual(dispatcher.outcome({"status": "launched", "t3status": "completed"}), ("done", None))
        self.assertEqual(dispatcher.outcome({"status": "launched", "t3status": "interrupted"}), ("failed", "interrupted"))
        self.assertEqual(dispatcher.outcome({"status": "skipped", "skip_reason": "falta label"}), ("failed", "skipped: falta label"))
        self.assertLessEqual(len(dispatcher.outcome({"status": "launch_failed", "last_error": "e" * 999})[1]), 300)


if __name__ == "__main__":
    unittest.main()
