"""Pruebas de chopshop.agent.layout (fase 0 del rediseño de la oficina): bloques `office:`/`rack:` del perfil, topes,
ids de escritorio, `structure`, reglas `match`, `wake` y el ejemplo `examples/profiles/awesome-gb.example.yaml`.
También los tipos nuevos del sobre (`desk.*`, `office.changed`, `forge.*`, `listener.state`) y la tabla de semivida."""
import copy
import io
import json
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from test_chopshop import Env  # noqa: E402
from chopshop import cli, miniyaml, profile  # noqa: E402
from chopshop.agent import automations, envelope, layout as L  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
EXAMPLE = os.path.join(ROOT, "examples", "profiles", "awesome-gb.example.yaml")
HALFLIFE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "office", "halflife.json")


def office(*floors, **extra):
    o = {"company": "Acme", "floors": list(floors)}
    o.update(extra)
    return {"project": "p", "office": o}


def floor(*rooms, name="F"):
    return {"name": name, "rooms": [dict(r) for r in rooms]}


def room(role, desks=1, **kw):
    return dict(role=role, desks=desks, **kw)


class TestValidate(unittest.TestCase):
    def test_example_is_valid(self):
        prof = miniyaml.load(EXAMPLE)
        self.assertEqual(L.validate(prof), [])
        self.assertEqual(automations.validate(prof), [])

    def test_absent_blocks_ok(self):
        self.assertEqual(L.validate({"project": "p"}), [])

    def test_floor_cap(self):
        p = office(*[floor(room("be")) for _ in range(L.MAX_FLOORS_PER_PROJECT + 1)])
        self.assertTrue(any("máximo 4 por proyecto" in e for e in L.validate(p)))
        p = office(*[floor(room("be")) for _ in range(L.MAX_FLOORS_PER_PROJECT)])
        self.assertEqual(L.validate(p), [])

    def test_desk_caps(self):
        p = office(floor(*[room("r%d" % i, 6) for i in range(5)]))            # 30 escritorios
        self.assertTrue(any("máximo 24 por piso" in e for e in L.validate(p)))
        p = office(floor(*[room("r%d" % i, 4) for i in range(6)]))            # 24: justo
        self.assertEqual(L.validate(p), [])
        p = office(floor(*[room("r%d" % i) for i in range(7)]))
        self.assertTrue(any("máximo 6 por piso" in e for e in L.validate(p)))
        p = office(floor(room("be", 7)))
        self.assertTrue(any("desks debe ser un entero 1-6" in e for e in L.validate(p)))
        p = office(floor(room("be", 0)))
        self.assertTrue(L.validate(p))

    def test_room_errors(self):
        errs = L.validate(office(floor(room("Back End"), room("x", permanent="sí"), {"role": "x", "foo": 1})))
        self.assertTrue(any("role inválido" in e for e in errs))
        self.assertTrue(any("permanent debe ser" in e for e in errs))
        self.assertTrue(any("foo desconocido" in e for e in errs))
        self.assertTrue(any("role repetido" in e for e in errs))
        self.assertTrue(L.validate(office(floor())))                          # piso sin departamentos
        self.assertTrue(L.validate({"project": "p", "office": {"floors": "x"}}))
        self.assertTrue(L.validate({"project": "p", "office": {"bogus": 1}}))

    def test_same_role_on_two_floors_ok(self):
        self.assertEqual(L.validate(office(floor(room("be", 6)), floor(room("be", 6)))), [])

    def test_half_life(self):
        self.assertEqual(L.validate(office(floor(room("be")), half_life="45m")), [])
        self.assertTrue(L.validate(office(floor(room("be")), half_life="5s")))
        self.assertTrue(L.validate(office(floor(room("be")), half_life="nunca")))
        self.assertEqual(L.half_life_s(office(floor(room("be")), half_life="45m")), 2700.0)
        self.assertEqual(L.half_life_s({"project": "p"}), 1800.0)

    def test_roles(self):
        ok = office(floor(room("triage", permanent=True), room("be", 2)), roles={
            "triage": {"prompt_file": "roles/triage.md",
                       "wake": [{"type": "schedule", "cron": "30 8 * * 1-5"}, "desk.note", "manual",
                                {"type": "github.issue.opened", "where": {"body.labels": {"not": "triaged"}}}]},
            "be": {"match": {"title": "^\\[be\\]", "branch": "^be/", "label": "backend"}}})
        self.assertEqual(L.validate(ok), [])
        bad = copy.deepcopy(ok)
        bad["office"]["roles"]["be"]["wake"] = ["manual"]                        # no permanente
        bad["office"]["roles"]["ghost"] = {}                                    # sin departamento
        bad["office"]["roles"]["triage"]["prompt_file"] = "../fuera.md"
        bad["office"]["roles"]["triage"]["wake"].append({"type": "schedule", "cron": "nope"})
        bad["office"]["roles"]["triage"]["wake"].append({"type": "desk.note", "cron": "* * * * *"})
        bad["office"]["roles"]["be"]["match"] = {"title": "(", "author": "x"}
        errs = L.validate(bad)
        for frag in ("be.wake: solo los roles", "ghost: el rol no tiene departamento", "prompt_file debe ser",
                     "cron necesita 5 campos", "no aplica a desk.note", "match.title no es regex", "match.author desconocido"):
            self.assertTrue(any(frag in e for e in errs), (frag, errs))

    def test_rack(self):
        ok = {"project": "p", "rack": {"repos": [{"provider": "github", "repo": "o/a", "kind": "main"},
                                                  {"repo": "o/b", "kind": "docs", "label": "Engine CX"}],
                                       "actors": {"bot-1": {"kind": "bot", "label": "Grok"}}}}
        self.assertEqual(L.validate(ok), [])
        self.assertEqual([r["label"] for r in L.rack_repos(ok)], ["a", "Engine CX"])
        self.assertEqual(L.rack_actors(ok), {"bot-1": {"kind": "bot", "label": "Grok"}})
        bad = {"project": "p", "rack": {"repos": [{"provider": "svn", "repo": "nope", "kind": "x"},
                                                   {"repo": "o/a"}, {"repo": "o/a"}],
                                        "actors": {"x": {"kind": "robot"}}, "extra": 1}}
        errs = L.validate(bad)
        for frag in ("provider desconocido", "<dueño>/<repo>", "kind debe ser", "repo repetido", "bot o human",
                     "rack.extra desconocido"):
            self.assertTrue(any(frag in e for e in errs), (frag, errs))

    def test_building_cap(self):
        profs = [dict(office(*[floor(room("be")) for _ in range(4)]), project="p%d" % i) for i in range(5)]
        errs = L.validate_building(profs)
        self.assertTrue(errs and "20 pisos" in errs[0], errs)
        self.assertEqual(L.validate_building(profs[:4]), [])
        profs[4]["office"]["company"] = "Otra"
        self.assertEqual(L.validate_building(profs), [])


class TestMachineRooms(unittest.TestCase):
    def test_optional_and_many(self):
        p = office(floor(room("be")), floor(room("docs")))
        self.assertEqual((L.validate(p), L.machine_rooms(p), L.structure(p)["machine_rooms"]), ([], [], []))
        p["machine_rooms"] = [{"name": "A", "repos": ["o/*"]}, {"name": "B", "floor": 1, "listeners": ["forge"]},
                              {"name": "C", "floor": 1}]
        self.assertEqual(L.validate(p), [])
        self.assertEqual([(r["name"], r["floor"]) for r in L.structure(p)["machine_rooms"]], [("A", 0), ("B", 1), ("C", 1)])
        self.assertEqual(L.machine_rooms(p)[0], {"name": "A", "floor": 0, "repos": ["o/*"], "listeners": [], "automations": [],
                                                 "subscriptions": []})

    def test_errors(self):
        p = office(floor(*[room("r%d" % i) for i in range(6)]))
        p["machine_rooms"] = [{"name": "A"}, {"name": "A", "floor": 3, "rack": []}, {"floor": 0, "repos": "o/r"}, "x"]
        errs = L.validate(p)
        for frag in ("machine_rooms[1].name repetido", "machine_rooms[1].floor debe ser un piso", "machine_rooms[1].rack desconocido",
                     "machine_rooms[2].name", "machine_rooms[2].repos", "machine_rooms[3]: se esperaba un mapa",
                     "office.floors[0]: 8 departamentos + salas"):
            self.assertTrue(any(frag in e for e in errs), (frag, errs))
        self.assertEqual([r["name"] for r in L.machine_rooms(p)], ["A"])      # la lectura se queda con las válidas
        self.assertTrue(any("necesita office.floors" in e for e in L.validate({"project": "p", "machine_rooms": [{"name": "A"}]})))
        self.assertTrue(L.validate({"project": "p", "machine_rooms": {"name": "A"}}))

    def test_example(self):
        rs = L.machine_rooms(miniyaml.load(EXAMPLE))
        self.assertEqual([(r["name"], r["floor"]) for r in rs], [("Sala de máquinas", 0), ("Sala de docs", 1)])


class TestDesks(unittest.TestCase):
    def setUp(self):
        self.prof = miniyaml.load(EXAMPLE)

    def test_ids_and_order(self):
        ds = [d for d in L.desks(self.prof) if d["role"] != L.FLEX_ROLE]
        self.assertEqual(len(ds), 11)
        self.assertEqual(ds[0], {"id": "awesome-gb/0/triage/0", "project": "awesome-gb", "floor": 0, "role": "triage",
                                 "slot": 0, "permanent": True, "zone": "room"})
        self.assertEqual([d["id"] for d in ds if d["role"] == "backend"],
                         ["awesome-gb/0/backend/%d" % i for i in range(4)])
        self.assertEqual(ds[-1]["id"], "awesome-gb/1/release/0")
        self.assertEqual(L.parse_desk_id("awesome-gb/0/backend/2"), ("awesome-gb", 0, "backend", 2))
        self.assertIsNone(L.parse_desk_id("awesome-gb/x/backend/2"))

    def test_structure_keeps_retired(self):
        st = L.structure(self.prof, retired=["awesome-gb/0/backend/5", "awesome-gb/2/qa/0", "awesome-gb/0/backend/1"])
        self.assertEqual(st["company"], "Awesome GB")
        self.assertEqual(st["half_life_s"], 1800.0)
        be = next(r for r in st["floors"][0]["rooms"] if r["role"] == "backend")
        self.assertEqual([(d["slot"], d["retired"]) for d in be["desks"]], [(0, False), (1, False), (2, False), (3, False),
                                                                            (5, True)])
        self.assertEqual(st["floors"][2]["rooms"], [{"role": "qa", "permanent": False, "flex": False,
                                                     "desks": [{"id": "awesome-gb/2/qa/0", "slot": 0, "retired": True}]}])
        self.assertTrue(st["floors"][0]["rooms"][0]["permanent"])

    def test_role_for(self):
        self.assertEqual(L.role_for(self.prof, title="[be] arreglar login"), "backend")
        self.assertEqual(L.role_for(self.prof, branch="be/login"), "backend")
        self.assertIsNone(L.role_for(self.prof, title="docs", branch="main"))

    def test_wake_triggers(self):
        w = L.wake_triggers(self.prof, "triage")
        self.assertEqual([t["type"] for t in w], ["schedule", "github.issue.opened", "desk.note"])
        self.assertIsNotNone(w[0]["_cron"])
        self.assertEqual(L.wake_triggers(self.prof, "backend"), [])

    def test_company_fallback(self):
        self.assertEqual(L.company({"project": "p", "company": "iAware"}), "iAware")
        self.assertIsNone(L.company({"project": "p"}))


class TestProfileCheck(Env):
    def test_profile_check_reports_caps(self):
        floors = "".join("    - rooms:\n        - {role: be, desks: 1}\n" for _ in range(5))
        self.prof("p", "project: p\nrepo: /tmp/p\noffice:\n  floors:\n" + floors)
        err = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            rc = cli.main(["profile", "check", "p"])
        self.assertEqual(rc, 1)
        self.assertIn("máximo 4 por proyecto", err.getvalue())

    def test_profile_check_example(self):
        with open(EXAMPLE) as f:
            self.prof("awesome-gb", f.read())
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            rc = cli.main(["profile", "check", "awesome-gb"])
        self.assertEqual(rc, 0, out.getvalue())
        self.assertEqual(profile.load("awesome-gb")["_unknown"], [])

    def test_building_cap_across_profiles(self):
        floors = "".join("    - rooms:\n        - {role: be, desks: 1}\n" for _ in range(4))
        for i in range(5):
            self.prof("p%d" % i, "project: p%d\nrepo: /tmp/p\noffice:\n  company: Acme\n  floors:\n%s" % (i, floors))
        err = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            rc = cli.main(["profile", "check", "p0"])
        self.assertEqual(rc, 1)
        self.assertIn("edificio Acme", err.getvalue())


class TestEnvelopeTypes(unittest.TestCase):
    def env(self, typ, body, project="p"):
        return envelope.build(typ, project, body, machine="m")

    def test_new_types_validate(self):
        ok = [
            ("desk.assigned", {"desk": "p/0/be/0", "thread_id": "t1", "role": "be", "reason": "inherited",
                               "inheritance": {"thread_id": "t0", "summary": "x", "branch": "be/x"}}, "desk"),
            ("desk.released", {"desk": "p/0/be/0", "thread_id": "t0", "reason": "inherited"}, "desk"),
            ("desk.released", {"desk": None, "thread_id": "t9", "reason": "faded"}, "thread"),
            ("desk.waiting", {"thread_id": "t2", "role": "be"}, "thread"),
            ("desk.note", {"desk": "p/0/triage/0", "from": "grok", "text": "hola", "pending": 1}, "desk"),
            ("office.changed", {"project": "p", "by": "profile", "floors": []}, "office"),
            ("forge.repo.state", {"provider": "github", "repo": "o/a", "light": "amber"}, "repo"),
            ("forge.run.state", {"provider": "github", "repo": "o/a", "run_id": "9", "workflow": "ci", "status": "in_progress",
                                 "event": "push", "origin": {"kind": "thread", "id": "t1", "label": "be"}}, "run"),
            ("forge.dispatch", {"provider": "github", "repo": "o/a", "workflow": "ci.yml", "ref": "main", "nonce": "n1"}, "run"),
            ("listener.state", {"name": "t3watch", "state": "ok"}, "listener"),
        ]
        for typ, body, kind in ok:
            e = self.env(typ, body)
            self.assertEqual(envelope.errors(e), [], typ)
            self.assertEqual(e["subject"]["kind"], kind, typ)
            self.assertIsNone(e["needs"])
        self.assertTrue(envelope.errors(self.env("desk.assigned", {"desk": "d", "thread_id": "t", "role": "r", "reason": "x"})))
        self.assertTrue(envelope.errors(self.env("forge.repo.state", {"provider": "github", "repo": "o/a", "light": "blue"})))
        self.assertTrue(envelope.errors(self.env("forge.run.state", {"provider": "github", "repo": "o/a", "run_id": "1",
                                                                     "workflow": None, "status": "x", "event": None,
                                                                     "origin": {"kind": "alien"}})))

    def test_reserved_namespaces(self):
        for ns in ("desk", "office", "forge", "listener"):
            self.assertIn(ns, automations.RESERVED)
        errs = automations.validate({"project": "p", "automations": [
            {"name": "a", "on": ["manual"], "run": ["x"], "emits": ["desk.assigned", "forge.dispatch"]}]})
        self.assertEqual(len(errs), 1)
        self.assertIn("desk.assigned", errs[0])


class TestHalfLifeTable(unittest.TestCase):
    """La tabla es el contrato compartido con `HalfLife.swift`; aquí solo se comprueba que es coherente."""

    def test_table_shape(self):
        with open(HALFLIFE) as f:
            doc = json.load(f)
        self.assertEqual(doc["fade_out"], 0.1)
        names = set()
        for c in doc["cases"]:
            self.assertNotIn(c["name"], names)
            names.add(c["name"])
            self.assertEqual(c["gone"], c["opacity"] < 0.1, c["name"])
            self.assertTrue(0 < c["opacity"] <= 1, c["name"])


if __name__ == "__main__":
    unittest.main()
