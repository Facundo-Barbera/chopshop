import json
import logging
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import cloudsync, miniyaml, profile, relaycfg  # noqa: E402
from chopshop.agent import db, events, registry, relay, roles, server  # noqa: E402

EXAMPLE = os.path.join(os.path.dirname(__file__), "..", "..", "..", "examples", "profiles", "awesome-gb.example.yaml")
W1 = "7c2e9f14-3a6b-4d5e-8f17-2b9c4e6a0d31"
W2 = "0b1d6e2a-9c4f-4a8e-b5d3-6f7a8b9c0d1e"
MID = "c3f8a2d1-6e4b-4a97-b2c5-8d1e7f3a9b52"
P1 = "4a1b2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
P2 = "5b2c3d4e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"
CORE = {"project", "t3_project", "repo", "runtime_mode", "model", "host", "overflow_host", "office", "floors", "half_life",
        "capacity", "machine_rooms"}


def example():
    d = miniyaml.load(EXAMPLE)
    d["project"] = "awesome-gb"
    return d


def to_sync(prof, workspace_id, pid=P1, prompts=None):
    office = prof.get("office") or {}
    layout = {k: office[k] for k in ("floors", "half_life") if k in office}
    layout.update({k: prof[k] for k in ("capacity", "machine_rooms") if k in prof})
    roles_out = []
    for name, spec in (office.get("roles") or {}).items():
        roles_out.append({"name": name, "prompt": (prompts or {}).get(name, "") if spec.get("prompt_file") else "",
                          "model": spec.get("model"), "match_rules": spec.get("match") or {}, "wake": spec.get("wake") or [],
                          "settings": {k: v for k, v in spec.items() if k not in ("prompt_file", "match", "wake", "model")}})
    return {"id": pid, "name": prof["project"], "workspace_id": workspace_id, "title": None,
            "t3_project": prof.get("t3_project"), "repo": prof.get("repo"),
            "runtime_mode": prof.get("runtime_mode") or "approval-required", "model": prof.get("model"), "disabled": False,
            "settings": {k: v for k, v in prof.items() if k not in CORE}, "layout": layout, "roles": roles_out, "rev": 3}


def sync_doc(projects, rev=7):
    return {"v": 2, "type": "sync", "id": "s-1", "ts": "2026-10-30T14:02:11.250Z", "rev": rev,
            "machine": {"id": MID, "name": "mini"},
            "workspaces": [{"id": W1, "name": "Awesome GB", "slug": "awesome-gb"}, {"id": W2, "name": "Beta", "slug": "beta"}],
            "projects": projects}


def plain(name):
    return {"id": P2, "name": name, "workspace_id": W2, "title": "Plano", "t3_project": name, "repo": None,
            "runtime_mode": "approval-required", "model": None, "disabled": False, "settings": {}, "layout": {},
            "roles": [], "rev": 1}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = os.path.join(self.tmp.name, "home")
        env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": os.path.join(self.tmp.name, "cfg"), "CHOPSHOP_HOME": self.home,
                                           "CHOPSHOP_CONFIG": os.path.join(self.tmp.name, "cfg", "chopshop", "config.toml")})
        env.start()
        self.addCleanup(env.stop)
        registry._cache.clear()
        self.addCleanup(registry._cache.clear)

    def write_local(self, name, text):
        os.makedirs(os.path.join(self.home, "profiles"), exist_ok=True)
        with open(os.path.join(self.home, "profiles", name), "w", encoding="utf-8") as f:
            f.write(text)


class TestMaterialize(Base):
    def test_example_round_trip(self):
        original = example()
        res = cloudsync.apply(sync_doc([to_sync(original, W1, prompts={"triage": "Clasifica issues."})]))
        self.assertEqual(res, {"rev": 7, "applied": ["awesome-gb"], "errors": []})
        with open(cloudsync.profile_path("awesome-gb"), encoding="utf-8") as f:
            self.assertIsInstance(json.load(f), dict)
        self.assertEqual(oct(os.stat(cloudsync.state_path()).st_mode & 0o777), "0o600")
        loaded = profile.load("awesome-gb")
        self.assertEqual(loaded["_path"], cloudsync.profile_path("awesome-gb"))
        self.assertEqual(loaded["office"]["roles"]["triage"]["prompt_file"], "triage.md")
        self.assertEqual(roles.read_prompt("awesome-gb", "triage.md"), "Clasifica issues.")
        back = {k: v for k, v in loaded.items() if not k.startswith("_") and k not in ("host", "provider")}
        self.assertEqual(to_sync(back, W1, prompts={"triage": "Clasifica issues."}),
                         to_sync(original, W1, prompts={"triage": "Clasifica issues."}))
        back["office"]["roles"]["triage"]["prompt_file"] = original["office"]["roles"]["triage"]["prompt_file"]
        self.assertEqual(back, dict(original, runtime_mode="approval-required"))

    def test_cloud_wins_over_local_yaml_and_lists_both(self):
        self.write_local("awesome-gb.yaml", "project: awesome-gb\nrepo: local/otro\n")
        self.write_local("solo-local.yaml", "project: solo-local\nrepo: local/solo\n")
        cloudsync.apply(sync_doc([to_sync(example(), W1)]))
        self.assertEqual(profile.load("awesome-gb")["repo"], "<org>/<repo-principal>")
        self.assertEqual(profile.list_projects(), ["awesome-gb", "solo-local"])
        self.assertEqual(profile.load("solo-local")["repo"], "local/solo")

    def test_removes_projects_no_longer_sent(self):
        cloudsync.apply(sync_doc([to_sync(example(), W1, prompts={"triage": "x"}), plain("beta")]))
        self.assertTrue(os.path.isdir(cloudsync.prompts_dir("awesome-gb")))
        res = cloudsync.apply(sync_doc([plain("beta")], rev=8))
        self.assertEqual(res["applied"], ["beta"])
        self.assertFalse(os.path.exists(cloudsync.profile_path("awesome-gb")))
        self.assertFalse(os.path.exists(cloudsync.prompts_dir("awesome-gb")))
        self.assertEqual(profile.list_projects(), ["beta"])
        with self.assertRaises(profile.ProfileError):
            profile.load("awesome-gb")
        self.assertEqual(cloudsync.read_state()["rev"], 8)

    def test_invalid_project_reported_in_errors(self):
        bad = dict(plain("roto"), runtime_mode="yolo")
        res = cloudsync.apply(sync_doc([plain("beta"), bad]))
        self.assertEqual(res["applied"], ["beta"])
        self.assertEqual([e["project"] for e in res["errors"]], ["roto"])
        self.assertIn("runtime_mode", res["errors"][0]["message"])

    def test_override_only_allowed_keys(self):
        cloudsync.apply(sync_doc([dict(plain("beta"), settings={"integration": {"test_cmd": ["make", "test"]}})]))
        self.write_local("beta.local.yaml", "worktree_root: /srv/wt\nt3_project: beta-local\nrepo: hack/otro\n"
                                            "integration:\n  test_cwd: apps/x\n  test_cmd: [rm]\n")
        with self.assertLogs("chopshop.cloudsync", logging.WARNING) as logs:
            d = profile.load("beta")
        self.assertEqual(d["worktree_root"], "/srv/wt")
        self.assertEqual(d["t3_project"], "beta-local")
        self.assertIsNone(d.get("repo"))
        self.assertEqual(d["integration"], {"test_cmd": ["make", "test"], "test_cwd": "apps/x"})
        self.assertEqual(len(logs.output), 2)
        self.assertEqual(profile.list_projects(), ["beta"])

    def test_without_state_local_mode(self):
        self.write_local("solo-local.yaml", "project: solo-local\nrepo: local/solo\n")
        self.write_local("solo-local.local.yaml", "repo: ignorado\n")
        self.assertFalse(cloudsync.active())
        self.assertEqual(profile.list_projects(), ["solo-local"])
        self.assertEqual(profile.load("solo-local")["repo"], "local/solo")


class TestRegistry(Base):
    def test_cloud_listing_and_409(self):
        self.write_local("solo-local.yaml", "project: solo-local\nrepo: local/solo\noffice:\n  company: Casa\n")
        cloudsync.apply(sync_doc([to_sync(example(), W1), dict(plain("beta"), disabled=True)]))
        names = {p["name"]: p for p in registry.api_list()["projects"]}
        self.assertEqual(names["awesome-gb"]["company"], "Awesome GB")
        self.assertEqual(names["awesome-gb"]["host"], "local")
        self.assertFalse(names["beta"]["enabled"])
        self.assertEqual(names["solo-local"]["company"], "Casa")
        self.assertEqual(registry.profiles(), ["awesome-gb", "solo-local"])
        for fn in (lambda: registry.api_register({"name": "awesome-gb", "company": "X"}),
                   lambda: registry.api_disable("beta")):
            with self.assertRaises(registry.RegistryError) as cm:
                fn()
            self.assertEqual(cm.exception.status, 409)
            self.assertIn("gestionado en la nube", cm.exception.message)
        with self.assertRaises(server.ApiError) as cm:
            server.AgentApp.r_office_put(None, None, {}, {"by": "bot", "office": {}}, "awesome-gb")
        self.assertEqual(cm.exception.status, 409)
        self.assertEqual(registry.api_disable("solo-local")["project"]["enabled"], False)
        with open(registry.path(), encoding="utf-8") as f:
            self.assertNotIn("awesome-gb", f.read())


class Sock:
    def settimeout(self, t):
        pass


class Client:
    def __init__(self, stop, inbound):
        self.stop, self.inbound, self.sock, self.sent = stop, list(inbound), Sock(), []

    def connect(self):
        return self

    def send_text(self, text):
        self.sent.append(json.loads(text))

    def recv(self):
        import socket
        if self.inbound:
            return 1, json.dumps(self.inbound.pop(0))
        self.stop.set()
        raise socket.timeout()

    def close(self, *a, **k):
        pass


class Stop:
    def __init__(self):
        self.flag = False

    def is_set(self):
        return self.flag

    def set(self):
        self.flag = True

    def wait(self, t):
        return self.flag


class TestRelaySync(Base):
    def setUp(self):
        super().setUp()
        self.conn = db.connect(os.path.join(self.tmp.name, "agent", "agent.db"))
        self.addCleanup(self.conn.close)
        self.addCleanup(events.flush)
        self.addCleanup(events.cancel_pending)
        self.t = 0.0

    def clock(self):
        self.t += 0.5
        return self.t

    def link(self, factory):
        return relay.RelayLink("wss://api.example.test/v1/connect", "cm1_" + "a" * 43, "host-a", self.conn, lambda: {},
                               lambda: None, lambda: [], self.stop, clock=self.clock, factory=factory,
                               backoff=lambda n: 1.0, jitter=lambda d: d, tick=1.0)

    def test_sync_materializes_and_acks(self):
        self.stop = Stop()
        welcome = {"v": 2, "type": "welcome", "id": "w", "ts": "2026-10-30T14:02:11.250Z", "session_id": "s",
                   "protocol": 2, "machine": {"id": MID, "name": "mini"}, "rev": 7}
        doc = sync_doc([to_sync(example(), W1, prompts={"triage": "Clasifica."}), dict(plain("roto"), runtime_mode="yolo")])
        client = Client(self.stop, [welcome, doc])
        self.link(lambda: client).run()
        acks = [m for m in client.sent if m["type"] == "sync.ack"]
        self.assertEqual(len(acks), 1)
        self.assertEqual({k: acks[0][k] for k in ("v", "re", "rev", "applied")},
                         {"v": 2, "re": "s-1", "rev": 7, "applied": ["awesome-gb"]})
        self.assertEqual([e["project"] for e in acks[0]["errors"]], ["roto"])
        self.assertEqual(profile.load("awesome-gb")["office"]["company"], "Awesome GB")

    def test_offline_uses_cache(self):
        cloudsync.apply(sync_doc([to_sync(example(), W1), plain("beta")]))
        relaycfg.write_machine({"api_url": "https://api.example.test", "machine_id": MID, "local_machine_id": "host-a",
                                "credential": "cm1_" + "a" * 43})
        self.stop = Stop()

        def factory():
            self.stop.set()
            raise OSError("sin red")
        link = self.link(factory)
        self.assertEqual(link.ws_map, {"awesome-gb": W1, "beta": W2})
        self.assertEqual(link.rev, 7)
        link.run()
        self.assertFalse(link.connected)
        self.assertEqual(profile.list_projects(), ["awesome-gb", "beta"])
        self.assertEqual(profile.load("beta")["office"]["company"], "Beta")


if __name__ == "__main__":
    unittest.main()
