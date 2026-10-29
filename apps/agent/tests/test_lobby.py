"""Pruebas del vestíbulo (chopshop.agent.lobby vía projection.apply): hilos activos sin rol, espera por rol, salida al subir a
un escritorio o al desvanecerse, y que `fold` siga siendo igual a aplicar uno a uno."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from chopshop.agent import projection  # noqa: E402

OFFICE = {"company": "Awesome GB", "half_life_s": 600, "floors": [{"index": 0, "name": "Producto", "rooms": [
    {"role": "backend", "permanent": False, "desks": [
        {"id": "awesome-gb/0/backend/0", "slot": 0, "retired": False, "occupant": None, "lineage": [], "notes_pending": 0}]}]}]}


class Seq:
    def __init__(self):
        self.n = 0

    def env(self, typ, body, project="awesome-gb", kind="task", sid=None):
        self.n += 1
        return {"v": 1, "id": "e%d" % self.n, "seq": self.n, "ts": "2026-10-29T16:%02d:00.000Z" % self.n, "machine": "contabo-dev",
                "project": project, "type": typ, "severity": "info", "needs": None,
                "subject": {"kind": kind, "id": sid or body.get("thread_id")}, "cause": {"id": None, "depth": 0}, "body": body}

    def task(self, tid, phase, role=None, project="awesome-gb", **kw):
        return self.env("task.state", dict({"thread_id": tid, "phase": phase, "attention": None, "settled": False,
                                            "title": "t " + tid, "role": role}, **kw), project)


def tids(st):
    return [(x["thread_id"], x["waiting_role"]) for x in st["lobby"]]


class TestLobby(unittest.TestCase):
    def setUp(self):
        self.s = Seq()

    def fold(self, envs):
        st = projection.fold(envs, "contabo-dev")
        one = projection.empty("contabo-dev")
        for e in envs:
            one = projection.apply(one, e)
        self.assertEqual(st, one)
        return st

    def test_empty_has_lobby(self):
        self.assertEqual(projection.empty()["lobby"], [])

    def test_active_roleless_enters_and_fades_in_place(self):
        s = self.s
        st = self.fold([s.task("mcp:a", "queued"), s.task("mcp:a", "running")])
        self.assertEqual(st["lobby"], [{"thread_id": "mcp:a", "project": "awesome-gb", "company": None, "half_life_s": 1800,
                                        "waiting_role": None, "since": "2026-10-29T16:01:00.000Z", "title": "t mcp:a",
                                        "phase": "running", "attention": None, "ended_at": None, "touched_at": None}])
        st = self.fold([s.task("mcp:a", "queued"), s.task("mcp:a", "done", ended_at="2026-10-29T16:09:00Z")])
        self.assertEqual((st["lobby"][0]["phase"], st["lobby"][0]["ended_at"]), ("done", "2026-10-29T16:09:00Z"))

    def test_terminal_outside_or_with_role_does_not_enter(self):
        s = self.s
        st = self.fold([s.task("mcp:a", "done"), s.task("mcp:b", "running", role="backend"), s.task("mcp:c", "failed")])
        self.assertEqual(st["lobby"], [])

    def test_waiting_for_desk_then_assigned(self):
        s = self.s
        envs = [s.task("mcp:w", "running", role="backend", title="[be] x"),
                s.env("desk.waiting", {"thread_id": "mcp:w", "role": "backend", "phase": "running"}, kind="thread")]
        st = self.fold(envs)
        self.assertEqual(tids(st), [("mcp:w", "backend")])
        self.assertEqual(st["lobby"][0]["title"], "[be] x")                 # de la última task.state, no del cuerpo
        envs.append(s.task("mcp:w", "waiting", role="backend", attention="ask"))
        st = self.fold(envs)
        self.assertEqual((tids(st), st["lobby"][0]["phase"], st["lobby"][0]["attention"]),
                         ([("mcp:w", "backend")], "waiting", "ask"))       # se refresca y conserva el rol esperado
        self.assertEqual(st["lobby"][0]["since"], envs[1]["ts"])
        envs.append(s.env("desk.assigned", {"desk": "awesome-gb/0/backend/0", "thread_id": "mcp:w", "role": "backend",
                                            "reason": "start"}, kind="desk", sid="awesome-gb/0/backend/0"))
        self.assertEqual(self.fold(envs)["lobby"], [])

    def test_waiting_without_task_uses_body(self):
        s = self.s
        st = self.fold([s.env("desk.waiting", {"thread_id": "mcp:z", "role": "frontend", "title": "[fe] y"}, kind="thread")])
        self.assertEqual((st["lobby"][0]["title"], st["lobby"][0]["phase"]), ("[fe] y", "running"))

    def test_released_without_desk_leaves(self):
        s = self.s
        envs = [s.task("mcp:a", "done"), s.task("mcp:b", "running"),
                s.env("desk.released", {"desk": None, "thread_id": "mcp:b", "reason": "faded"}, kind="thread"),
                s.env("desk.released", {"desk": "awesome-gb/0/backend/0", "thread_id": "mcp:c", "reason": "faded"},
                      kind="desk", sid="awesome-gb/0/backend/0")]
        self.assertEqual(self.fold(envs)["lobby"], [])

    def test_desk_occupant_is_not_in_lobby_and_office_fields(self):
        s = self.s
        st = projection.fold([s.task("mcp:o", "running"), s.task("mcp:p", "running")], "contabo-dev")
        office = {**OFFICE, "floors": [dict(OFFICE["floors"][0], rooms=[dict(OFFICE["floors"][0]["rooms"][0], desks=[
            dict(OFFICE["floors"][0]["rooms"][0]["desks"][0], occupant={"thread_id": "mcp:o"})])])]}
        st["projects"][0]["office"] = office                    # como lo dejaría office.changed + desk.assigned
        st = projection.apply(st, s.task("mcp:o", "running"))
        st = projection.apply(st, s.task("mcp:p", "running"))
        self.assertEqual(tids(st), [("mcp:p", None)])
        self.assertEqual((st["lobby"][0]["company"], st["lobby"][0]["half_life_s"]), ("Awesome GB", 600))

    def test_sorted_by_company_project_since_and_filter(self):
        s = self.s
        st = self.fold([s.task("mcp:1", "running", project="zeta"), s.task("mcp:2", "running", project="alpha"),
                        s.task("mcp:3", "running", project="alpha")])
        self.assertEqual([x["thread_id"] for x in st["lobby"]], ["mcp:2", "mcp:3", "mcp:1"])
        self.assertEqual([x["thread_id"] for x in projection.filter_project(st, "zeta")["lobby"]], ["mcp:1"])

    def test_no_thread_id_is_ignored(self):
        st = self.fold([self.s.env("task.state", {"phase": "queued", "attention": None, "thread_id": None, "settled": False},
                                   sid="x")])
        self.assertEqual(st["lobby"], [])


if __name__ == "__main__":
    unittest.main()
