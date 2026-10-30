"""Pruebas del registro de la sala de máquinas en el agente: `listener.state` (`listeners.py` y los hilos del servicio),
reductor `machine_room` (listeners y automatizaciones; fold de tests/fixtures/events/machine-room-fixture.jsonl contra su
proyección dorada, la misma que usa la app), webhooks en vivo desde SQLite y `next_run` de `automation.ran`."""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop.agent import automations, db, envelope, listeners, machine_room, projection, service  # noqa: E402
from test_agent_github import Clock, base_cfg  # noqa: E402

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "events")
MR_FIXTURE = os.path.join(FIX, "machine-room-fixture.jsonl")
MR_GOLDEN = os.path.join(FIX, "machine-room-fixture.state.json")
MR_ROOMS = os.path.join(FIX, "machine-room-fixture.rooms.json")      # {proyecto: projects[].machine_rooms}


def load_mr():
    with open(MR_FIXTURE, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


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
        self.assertEqual(out[2][2]["last_ok"], envelope.iso(Clock().t))
        for t, p, b in out:
            envelope.validate(envelope.build(t, p, b, machine="m"))


class TestMachineRoomProjection(unittest.TestCase):
    def test_fold_matches_golden(self):
        """fold(machine-room-fixture.jsonl) == machine-room-fixture.state.json, y las salas de cada proyecto ==
        machine-room-fixture.rooms.json (CHOPSHOP_UPDATE_GOLDEN=1 los regenera; la app usa los mismos)."""
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
        rooms = json.dumps({p["name"]: p["machine_rooms"] for p in st["projects"]}, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
        if os.environ.get("CHOPSHOP_UPDATE_GOLDEN") == "1":
            with open(MR_ROOMS, "w", encoding="utf-8") as f:
                f.write(rooms)
        with open(MR_ROOMS, encoding="utf-8") as f:
            self.assertEqual(f.read(), rooms)

    def test_rules(self):
        envs = load_mr()
        st = projection.fold(envs, "contabo-dev")
        mr = st["machine_room"]
        self.assertEqual([(l["name"], l["state"]) for l in mr["listeners"]],
                         [("automations", "ok"), ("forge", "ok"), ("t3watch", "down")])
        self.assertEqual(mr["listeners"][2]["backoff_s"], 30)
        self.assertEqual([(a["project"], a["name"], a["exit"], a["severity"]) for a in mr["automations"]],
                         [("awesome-gb", "docs-sync", 1, "error"), ("chopshop", "triage", 0, "info")])
        self.assertEqual(mr["automations"][0]["next_run"], "2026-10-30T07:30:00.000Z")
        self.assertEqual(mr["subscriptions"], [])                           # no sale de sobres
        self.assertEqual([(u["label"], u["kind"], u["light"], [r["origin"]["kind"] for r in u["runs"]]) for u in mr["rack"]],
                         [("repo-principal", "main", "red", ["thread", "schedule", "bot"]),
                          ("Engine CX", "docs", "amber", ["automation"])])
        self.assertEqual(projection.fold(envs + envs, "contabo-dev"), st)
        self.assertEqual(projection.fold(envs[4:], "contabo-dev", projection.fold(envs[:4], "contabo-dev")), st)
        self.assertTrue(all(not p["attention"] for p in st["projects"]))      # no abren atención
        f = projection.filter_project(st, "chopshop")["machine_room"]
        self.assertEqual(([a["name"] for a in f["automations"]], len(f["listeners"])), (["triage"], 3))

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
        self.assertEqual(subs[0], {"name": "bots", "projects": ["*"], "last_ok": envelope.iso(100), "last_error": None,
                                   "last_error_at": None, "signed": True})
        self.assertEqual((subs[1]["last_error"], subs[1]["signed"]), ("HTTP 500 [url]", False))
        st = projection.Projector(conn, {"machine_id": "m"}).current()
        self.assertEqual([s["name"] for s in st["machine_room"]["subscriptions"]], ["bots", "chat"])
        self.assertEqual(projection.state(conn, {"machine_id": "m"})["machine_room"]["subscriptions"], [])  # fold puro

    def test_rooms_per_project_from_profile(self):
        """0..N salas por proyecto, las que declara su perfil (llegan con `office.changed`): cada una con lo que aloja."""
        tmp = tempfile.mkdtemp(prefix="chopshop-mr-")
        self.addCleanup(shutil.rmtree, tmp, True)
        conn = db.connect(os.path.join(tmp, "agent.db"))
        self.addCleanup(conn.close)
        conn.execute("INSERT INTO subscriptions(name, webhook_file, created) VALUES('bots','/x/h',1)")
        conn.execute("INSERT INTO subscriptions(name, webhook_file, created) VALUES('chat','/x/h',1)")
        envs = load_mr()
        st = projection.fold(envs, "m")
        rooms = {p["name"]: p["machine_rooms"] for p in st["projects"]}
        mr = st["machine_room"]
        self.assertEqual(rooms["chopshop"], [])                               # sin salas declaradas: ninguna
        self.assertIsNone(next(p for p in st["projects"] if p["name"] == "chopshop")["machine_room"])
        main, docs = rooms["awesome-gb"]
        self.assertEqual((main["name"], main["floor"], docs["name"], docs["floor"]), ("Sala de máquinas", 0, "Sala de docs", 1))
        self.assertEqual(next(p for p in st["projects"] if p["name"] == "awesome-gb")["machine_room"], main)  # clientes viejos
        self.assertEqual(main["listeners"], mr["listeners"])
        self.assertEqual([l["name"] for l in docs["listeners"]], ["forge"])
        self.assertEqual([u["label"] for u in main["rack"]], ["repo-principal"])
        self.assertEqual([u["label"] for u in docs["rack"]], ["Engine CX"])
        self.assertEqual([a["name"] for a in main["automations"]], ["docs-sync"])  # solo las de su proyecto
        self.assertEqual([a["name"] for a in docs["automations"]], ["docs-sync"])
        self.assertEqual(projection.apply(st, envs[0]), st)                     # ya plegado: igual
        # en vivo: webhooks por nombre o glob
        live = machine_room.live(json.loads(json.dumps(st)), conn)
        subs = {p["name"]: [[s["name"] for s in r["subscriptions"]] for r in p["machine_rooms"]] for p in live["projects"]}
        self.assertEqual(subs, {"awesome-gb": [["bots", "chat"], ["bots"]], "chopshop": []})
        self.assertEqual(projection.filter_project(live, "awesome-gb")["projects"][0]["machine_room"]["name"], "Sala de máquinas")
        # sin office (agente/perfil anterior): ninguna sala
        bare = projection.fold([e for e in envs if e["type"] != "office.changed"], "m")
        self.assertEqual({p["name"]: (p["machine_rooms"], p["machine_room"]) for p in bare["projects"]},
                         {"awesome-gb": ([], None), "chopshop": ([], None)})


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


class TestService(unittest.TestCase):
    def test_listener_state_from_loops(self):
        tmp = tempfile.mkdtemp(prefix="chopshop-svc-")
        self.addCleanup(shutil.rmtree, tmp, True)
        svc = service.AgentService(base_cfg(tmp), maint_first=3600)
        self.addCleanup(svc.stop)
        svc._listener("t3", {"reachable": False, "backoff": 30})
        svc._listener("engine", None, RuntimeError("boom"))
        svc._listener("legacy", None)                            # sin nombre público: no se publica
        st = svc.app.projector.current()
        self.assertEqual([(l["name"], l["state"], l["backoff_s"]) for l in st["machine_room"]["listeners"]],
                         [("engine", "degraded", 0), ("t3watch", "down", 30)])
        self.assertEqual(st["machine_room"]["listeners"][0]["error"], "RuntimeError: boom")
        self.assertEqual(st["api_version"], 3)


if __name__ == "__main__":
    unittest.main()


class TestRackFold(unittest.TestCase):
    """Integración or-rack + or-actions: `forge.repo.state`/`forge.run.state` -> `machine_room.rack` (misma regla que
    MachineRoomModel.swift: módulo gris si el run llega antes que su repo, activos + 5 completados, orden del rack)."""

    def env(self, seq, typ, body, project="awesome-gb"):
        e = envelope.build(typ, project, body, machine="box", seq=seq, ts=1793290000 + seq)
        envelope.validate(e)
        return e

    def run_env(self, seq, rid, status="completed", updated=None, repo="<org>/<repo-principal>"):
        return self.env(seq, "forge.run.state", {
            "provider": "github", "repo": repo, "project": "awesome-gb", "run_id": str(rid), "workflow": "ci",
            "status": status, "conclusion": "success" if status == "completed" else None, "event": "push",
            "updated_at": updated, "origin": {"kind": "unknown", "id": None, "label": None}})

    def test_rack(self):
        envs = [self.run_env(1, 1, "in_progress")]                     # el run llega antes que su repo
        envs += [self.run_env(2 + i, 10 + i, updated="2026-10-29T16:0%d:00Z" % i) for i in range(7)]
        envs.append(self.env(20, "forge.repo.state", {"provider": "github", "repo": "<org>/<engine-cx>", "light": "green",
                                                      "kind": "docs", "label": "Engine CX"}))
        envs.append(self.env(21, "forge.repo.state", {"provider": "github", "repo": "<org>/<repo-principal>", "light": "amber",
                                                      "kind": "main", "default_branch": "main"}))
        st = projection.fold(envs)
        rack = st["machine_room"]["rack"]
        self.assertEqual([(u["repo"], u["kind"], u["light"]) for u in rack],
                         [("<org>/<repo-principal>", "main", "amber"), ("<org>/<engine-cx>", "docs", "green")])
        main = rack[0]
        self.assertEqual([r["run_id"] for r in main["runs"]], ["1", "12", "13", "14", "15", "16"])   # activo + 5 nuevos
        self.assertNotIn("provider", main["runs"][0])
        self.assertEqual(main["project"], "awesome-gb")
        # el run activo termina: se reemplaza en su sitio y el más viejo de los completados sale
        st = projection.fold([self.run_env(30, 1, updated="2026-10-29T17:00:00Z")], state=st)
        self.assertEqual([r["run_id"] for r in st["machine_room"]["rack"][0]["runs"]], ["1", "13", "14", "15", "16"])
        self.assertEqual(projection.filter_project(st, "otro")["machine_room"]["rack"], [])

    def test_module_created_by_run_is_gray(self):
        st = projection.fold([self.run_env(1, 5, "queued")])
        u = st["machine_room"]["rack"][0]
        self.assertEqual((u["light"], u["kind"], u["label"], len(u["runs"])), ("gray", None, None, 1))
