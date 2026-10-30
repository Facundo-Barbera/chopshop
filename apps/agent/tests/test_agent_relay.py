import json
import os
import socket
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import relaycfg, relaysync, wsclient  # noqa: E402
from chopshop.agent import db, events, relay  # noqa: E402

W1 = "7c2e9f14-3a6b-4d5e-8f17-2b9c4e6a0d31"
W2 = "0b1d6e2a-9c4f-4a8e-b5d3-6f7a8b9c0d1e"
MID = "c3f8a2d1-6e4b-4a97-b2c5-8d1e7f3a9b52"
CRED_A = "cm1_" + "a" * 43
CRED_B = "cm1_" + "b" * 43
CR1 = "cr1_" + "c" * 43


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class Stop:
    def __init__(self, on_wait=None):
        self.flag, self.waits, self.on_wait = False, [], on_wait

    def is_set(self):
        return self.flag

    def set(self):
        self.flag = True

    def wait(self, t):
        self.waits.append(t)
        if self.on_wait:
            self.on_wait(self)
        return self.flag


class Sock:
    def settimeout(self, t):
        pass


class Client:
    def __init__(self, clock, stop, inbound=(), connect_error=None, idle=3):
        self.clock, self.stop, self.inbound = clock, stop, list(inbound)
        self.connect_error, self.idle = connect_error, idle
        self.sock, self.sent = Sock(), []

    def connect(self):
        if self.connect_error:
            raise self.connect_error
        return self

    def send_text(self, text):
        self.sent.append(json.loads(text))

    def recv(self):
        self.clock.t += 1.0
        if self.inbound:
            item = self.inbound.pop(0)
            if isinstance(item, BaseException):
                raise item
            if callable(item):
                item = item(self)
            if item is not None:
                return wsclient.OP_TEXT, json.dumps(item)
        else:
            self.idle -= 1
            if self.idle <= 0:
                self.stop.set()
        raise socket.timeout()

    def close(self, *a, **k):
        pass

    def of(self, kind):
        return [m for m in self.sent if m.get("type") == kind]


def welcome(hello_v=2):
    return {"v": hello_v, "type": "welcome", "id": "x", "ts": "2026-10-30T14:02:11.250Z", "session_id": "s1",
            "protocol": hello_v, "snapshot_ttl_s": 120, "ping_interval_s": 25, "machine": {"id": MID, "name": "mini"},
            "rev": 42}


def sync():
    return {"v": 2, "type": "sync", "id": "y", "ts": "2026-10-30T14:02:11.250Z", "rev": 42,
            "machine": {"id": MID, "name": "mini"},
            "workspaces": [{"id": W1, "name": "Acme", "slug": "acme"}, {"id": W2, "name": "Beta", "slug": "beta"}],
            "projects": [{"id": "p1", "name": "alpha", "workspace_id": W1, "rev": 1},
                         {"id": "p2", "name": "beta", "workspace_id": W2, "rev": 1}]}


def snap():
    return {"projects": [{"name": "alpha", "threads_running": 1}, {"name": "beta", "threads_running": 2},
                         {"name": "gamma", "threads_running": 3}],
            "threads": [{"thread_id": "t-a", "project": "alpha", "title": "A", "status": "running"},
                        {"thread_id": "t-g", "project": "gamma", "title": "G", "status": "running"}]}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": os.path.join(self.tmp.name, "cfg"),
                                       "CHOPSHOP_HOME": os.path.join(self.tmp.name, "home")})
        env.start()
        self.addCleanup(env.stop)
        self.conn = db.connect(os.path.join(self.tmp.name, "agent", "agent.db"))
        self.addCleanup(self.conn.close)
        self.addCleanup(events.flush)
        self.addCleanup(events.cancel_pending)
        self.clock = Clock()
        self.clients = []

    def write_machine(self, cred):
        relaycfg.write_machine({"api_url": "https://api.example.test", "machine_id": MID, "local_machine_id": "host-a",
                                "credential": cred})

    def link(self, stop, scripts, token=CRED_A):
        def factory():
            if not scripts:
                stop.set()
            c = scripts.pop(0)(stop) if scripts else Client(self.clock, stop, connect_error=OSError("sin red"))
            self.clients.append(c)
            return c
        return relay.RelayLink("wss://api.example.test/v1/connect", token, "host-a", self.conn, snap, lambda: None,
                               lambda: [], stop, clock=self.clock, factory=factory, backoff=lambda n: 1.0,
                               jitter=lambda d: d, tick=1.0)


class TestV2Session(Base):
    def test_hello_v2_and_one_snapshot_per_workspace(self):
        stop = Stop()
        link = self.link(stop, [lambda s: Client(self.clock, s, [welcome(), sync()])])
        link.run()
        c = self.clients[0]
        hello = c.of("hello")[0]
        self.assertEqual(hello["v"], 2)
        self.assertEqual(hello["protocol"], [2])
        self.assertEqual(hello["machine_id"], "host-a")
        snaps = c.of("snapshot")
        by_ws = {m["workspace_id"]: m for m in snaps}
        self.assertEqual(len(snaps), 3)
        self.assertEqual(set(by_ws), {W1, W2, None})
        self.assertTrue(all(m["v"] == 2 for m in snaps))
        self.assertEqual([p["name"] for p in by_ws[W1]["projects"]], ["alpha"])
        self.assertEqual([p["name"] for p in by_ws[W2]["projects"]], ["beta"])
        self.assertEqual([p["name"] for p in by_ws[None]["projects"]], ["gamma"])
        self.assertEqual(by_ws[W1]["health"], by_ws[None]["health"])
        state = relaysync.decode([p for p in by_ws[W1]["parts"] if p["name"] == "state"][0])
        self.assertEqual({t["project"] for t in state["threads"]}, {"alpha"})
        self.assertEqual(link.rev, 42)
        self.assertEqual(link.machine, {"id": MID, "name": "mini"})

    def test_no_unmigrated_snapshot_when_all_projects_are_in_workspaces(self):
        stop = Stop()
        link = self.link(stop, [lambda s: Client(self.clock, s, [welcome(), sync()])])
        link.snapshot_fn = lambda: {"projects": [{"name": "alpha"}]}
        link.run()
        self.assertEqual({m["workspace_id"] for m in self.clients[0].of("snapshot")}, {W1, W2})

    def test_events_carry_workspace_id(self):
        cfg = {"machine_id": "host-a", "webhook_files": {}}

        def emit(_c):
            events.emit(self.conn, cfg, "thread_started", "alpha", {"thread_id": "t1"})
            events.emit(self.conn, cfg, "thread_started", "gamma", {"thread_id": "t2"})
            events.emit(self.conn, cfg, "thread_done", None)
            return None

        stop = Stop()
        link = self.link(stop, [lambda s: Client(self.clock, s, [welcome(), sync(), emit])])
        link.run()
        evs = self.clients[0].of("event")
        self.assertEqual([(e["project"], e["workspace_id"], e["v"]) for e in evs],
                         [("alpha", W1, 2), ("gamma", None, 2), (None, None, 2)])

    def test_without_sync_everything_goes_to_null_workspace(self):
        stop = Stop()
        link = self.link(stop, [lambda s: Client(self.clock, s, [welcome()], idle=8)])
        link.run()
        snaps = self.clients[0].of("snapshot")
        self.assertEqual({m["workspace_id"] for m in snaps}, {None})
        self.assertEqual([p["name"] for p in snaps[0]["projects"]], ["alpha", "beta", "gamma"])

    def test_v1_token_keeps_protocol_1(self):
        stop = Stop()
        link = self.link(stop, [lambda s: Client(self.clock, s, [welcome(1)])], token=CR1)
        link.run()
        c = self.clients[0]
        self.assertEqual(c.of("hello")[0]["protocol"], [1])
        snaps = c.of("snapshot")
        self.assertEqual(len(snaps), 1)
        self.assertNotIn("workspace_id", snaps[0])


class TestRefusals(Base):
    def test_4401_stops_retrying_until_machine_json_changes(self):
        self.write_machine(CRED_A)

        def on_wait(stop):
            if len(stop.waits) == 3:
                self.write_machine(CRED_B)
            if len(self.clients) >= 2:
                stop.set()

        stop = Stop(on_wait)
        refused = {"v": 2, "type": "error", "id": "e", "ts": "2026-10-30T14:02:11.250Z", "code": "unauthorized",
                   "message": "revocada", "close": True}
        link = self.link(stop, [lambda s: Client(self.clock, s, [welcome(), sync(), refused]),
                                lambda s: Client(self.clock, s, connect_error=wsclient.WSError(
                                    "handshake failed: HTTP/1.1 503 Unavailable"))])
        link.run()
        self.assertEqual(stop.waits[:3], [relay.WATCH_EVERY] * 3)
        self.assertEqual(len(self.clients), 2)
        self.assertEqual(link._token, CRED_B)
        self.assertEqual(link.url, "wss://api.example.test/v1/connect")
        self.assertTrue(os.path.exists(relaycfg.machine_path()))

    def test_upgrade_401_marks_revoked_and_keeps_machine_json(self):
        self.write_machine(CRED_A)

        def on_wait(stop):
            if len(stop.waits) >= 5:
                stop.set()

        stop = Stop(on_wait)
        link = self.link(stop, [lambda s: Client(self.clock, s, connect_error=wsclient.WSError(
            "handshake failed: HTTP/1.1 401 Unauthorized"))])
        link.run()
        self.assertEqual(len(self.clients), 1)
        self.assertEqual(stop.waits, [relay.WATCH_EVERY] * 5)
        self.assertEqual(link.last_error, "revocada")
        self.assertEqual(relaycfg.read_machine()["credential"], CRED_A)

    def test_4403_waits_600s(self):
        def on_wait(stop):
            stop.set()

        stop = Stop(on_wait)
        link = self.link(stop, [lambda s: Client(self.clock, s, [welcome(), sync(), wsclient.WSClosed(4403, "pausada")])])
        link.run()
        self.assertEqual(stop.waits, [600.0])
        self.assertEqual(link.last_error, "pausada")

    def test_upgrade_403_and_4409_wait_600s(self):
        def on_wait(stop):
            if len(stop.waits) >= 2:
                stop.set()

        stop = Stop(on_wait)
        link = self.link(stop, [
            lambda s: Client(self.clock, s, connect_error=wsclient.WSError("handshake failed: HTTP/1.1 403 Forbidden")),
            lambda s: Client(self.clock, s, [welcome(), wsclient.WSClosed(4409, "conflicto")])])
        link.run()
        self.assertEqual(stop.waits, [600.0, 600.0])
        self.assertEqual(link.last_error, "conflicto")

    def test_other_errors_use_backoff(self):
        def on_wait(stop):
            stop.set()

        stop = Stop(on_wait)
        link = self.link(stop, [lambda s: Client(self.clock, s, [welcome(), wsclient.WSClosed(1011, "x")])])
        link.run()
        self.assertEqual(stop.waits, [1.0])


class TestConfigured(Base):
    def test_machine_json_wins_and_derives_wss(self):
        self.write_machine(CRED_A)
        self.assertEqual(relay.configured(), ("wss://api.example.test/v1/connect", CRED_A))


if __name__ == "__main__":
    unittest.main()
