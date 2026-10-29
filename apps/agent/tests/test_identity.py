"""Pruebas de chopshop.agent.identity (docs/plans/office-personalization.md): validación de `office.brand`/`office.look`/
`floors[].look`, acentos contenidos, identidad derivada estable, fusión de `brand` entre perfiles de la misma empresa y
`identity` en `structure`, en `office.changed` y en `GET /state` (aditivo: sin identidad en el sobre, la proyección no la añade)."""
import copy
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from chopshop import miniyaml  # noqa: E402
from chopshop.agent import config as agent_config, db, events, identity as I, layout as L, office, projection  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
EXAMPLE = os.path.join(ROOT, "examples", "profiles", "ozom-gv.example.yaml")


def prof(project="p", company="Acme", brand=None, look=None, floor_looks=(None,)):
    floors = []
    for fl in floor_looks:
        f = {"name": "F", "rooms": [{"role": "backend", "desks": 2}]}
        if fl is not None:
            f["look"] = fl
        floors.append(f)
    o = {"company": company, "floors": floors}
    if brand is not None:
        o["brand"] = brand
    if look is not None:
        o["look"] = look
    return {"project": project, "office": o}


def hls(hex_color):
    import colorsys
    return colorsys.rgb_to_hls(*(int(hex_color[i:i + 2], 16) / 255.0 for i in (1, 3, 5)))


class TestValidate(unittest.TestCase):
    def test_absent_ok(self):
        self.assertEqual(L.validate(prof()), [])

    def test_example_is_valid(self):
        p = miniyaml.load(EXAMPLE)
        self.assertEqual(L.validate(p), [])
        self.assertEqual(p["office"]["brand"]["building"]["style"], "brick")

    def test_good_blocks(self):
        p = prof(brand={"name": "ozom", "accent": "teal", "monogram": "oz", "logo_file": "ozom/logo.svg",
                        "building": {"style": "brick", "roof": "garden"},
                        "materials": {"floor": "oak", "walls": "plaster", "furniture": "walnut"}, "lighting": "warm"},
                 look={"accent": "#336699", "materials": {"floor": "terrazzo"}},
                 floor_looks=({"lighting": "cool"}, {"materials": {"walls": "glass"}}))
        self.assertEqual(L.validate(p), [])

    def test_errors(self):
        p = prof(brand={"accent": "neon", "monogram": "ozom!", "logo_file": "../x.svg", "building": {"style": "castle", "x": 1},
                        "materials": {"floor": "lava", "ceiling": "oak"}, "lighting": "disco", "slogan": "hi"},
                 look={"monogram": "x", "accent": "#12345"}, floor_looks=("oak",))
        errs = "\n".join(L.validate(p))
        for frag in ("office.brand.accent", "office.brand.monogram", "office.brand.logo_file",
                     "office.brand.building.style", "office.brand.building.x desconocido", "office.brand.materials.floor",
                     "office.brand.materials.ceiling desconocido", "office.brand.lighting", "office.brand.slogan desconocido",
                     "office.look.monogram desconocido", "office.look.accent", "office.floors[0].look: se esperaba un mapa"):
            self.assertIn(frag, errs)

    def test_logo_needs_known_extension(self):
        self.assertTrue(L.validate(prof(brand={"logo_file": "logo.gif"})))
        self.assertTrue(L.validate(prof(brand={"logo_file": "/abs/logo.svg"})))


class TestAccent(unittest.TestCase):
    def test_palette_names(self):
        self.assertEqual(I.accent("Teal"), {"name": "teal", "hex": I.PALETTE["teal"]})
        for name, hx in I.PALETTE.items():
            _, l, s = hls(hx)
            self.assertLessEqual(s, I.MAX_SAT + 0.01, name)
            self.assertTrue(I.MIN_LIGHT - 0.01 <= l <= I.MAX_LIGHT + 0.01, name)

    def test_hex_is_restrained(self):
        a = I.accent("#FF0000")                     # rojo puro -> rojo apagado, mismo tono
        self.assertIsNone(a["name"])
        h, l, s = hls(a["hex"])
        self.assertAlmostEqual(h, 0.0, places=2)
        self.assertLessEqual(s, I.MAX_SAT + 0.01)
        self.assertLessEqual(l, I.MAX_LIGHT + 0.01)
        self.assertEqual(I.accent("#5b6b7c")["hex"], "#5b6b7c")   # ya contenido: intacto

    def test_bad(self):
        for v in ("neon", "#abc", 3, None):
            self.assertIsNone(I.accent(v))


class TestResolve(unittest.TestCase):
    def test_derived_is_stable_and_complete(self):
        a = L.structure(prof(company="ozom"))["identity"]
        self.assertEqual(a, L.structure(prof(company="ozom"))["identity"])
        self.assertEqual(a["name"], "ozom")
        self.assertEqual(a["monogram"], "oz")
        self.assertIsNone(a["logo"])
        self.assertIn(a["accent"]["name"], I.PALETTE)
        self.assertIn(a["building"]["style"], I.BUILDING_STYLES)
        self.assertIn(a["building"]["roof"], I.ROOFS)
        self.assertTrue(all(a["materials"][k] in I._MATERIALS[k] for k in I.MATERIAL_KEYS))
        self.assertEqual(a["lighting"], "neutral")

    def test_companies_differ(self):
        looks = {c: L.structure(prof(company=c))["identity"] for c in ("ozom", "iAware", "Bixku", "Personal", "Awesome GB")}
        sig = {c: (i["accent"]["name"], i["building"]["style"], i["building"]["roof"], tuple(sorted(i["materials"].items())))
               for c, i in looks.items()}
        self.assertEqual(len(set(sig.values())), len(sig))
        self.assertEqual(looks["Awesome GB"]["monogram"], "AG")
        self.assertEqual(looks["iAware"]["monogram"], "iA")

    def test_layers(self):
        p = prof(company="ozom", brand={"name": "Ozom Labs", "accent": "sage", "monogram": "OZ", "logo_file": "ozom.svg",
                                        "building": {"style": "timber"}, "materials": {"floor": "oak", "walls": "plaster"},
                                        "lighting": "warm"},
                 look={"accent": "clay", "materials": {"floor": "terrazzo"}},
                 floor_looks=(None, {"accent": "slate", "materials": {"furniture": "steel"}, "lighting": "cool"}))
        s = L.structure(p)
        i = s["identity"]
        self.assertEqual((i["name"], i["monogram"], i["logo"]), ("Ozom Labs", "OZ", "/brand/ozom/logo"))
        self.assertEqual(i["building"]["style"], "timber")
        self.assertEqual(i["accent"]["name"], "clay")                       # proyecto sobre empresa
        self.assertEqual((i["materials"]["floor"], i["materials"]["walls"]), ("terrazzo", "plaster"))
        self.assertEqual(i["lighting"], "warm")
        f0, f1 = (f["identity"] for f in s["floors"])
        self.assertEqual(f0["accent"]["name"], "clay")                      # piso sin look: hereda el proyecto
        self.assertEqual(f0["materials"], i["materials"])
        self.assertEqual(f1["accent"]["name"], "slate")
        self.assertEqual(f1["materials"], dict(i["materials"], furniture="steel"))
        self.assertEqual(f1["lighting"], "cool")
        for f in (f0, f1):
            self.assertIn(f["variant"], range(I.VARIANTS))

    def test_floor_variants_spread(self):
        s = L.structure(prof(floor_looks=(None,) * 4))
        vs = [f["identity"]["variant"] for f in s["floors"]]
        self.assertGreater(len(set(vs)), 1)

    def test_retired_extra_floor_gets_identity(self):
        s = L.structure(prof(), retired=["p/2/old/0"])
        self.assertEqual(len(s["floors"]), 3)
        self.assertIn("variant", s["floors"][2]["identity"])


class TestBrands(unittest.TestCase):
    def test_merge_across_profiles(self):
        a = prof("ozom-gv", "ozom", brand={"accent": "teal", "building": {"style": "brick"}})
        b = prof("ozom-trade", "ozom", brand={"monogram": "oz", "building": {"roof": "garden"}})
        c = prof("nuskills", "iAware", brand={"accent": "plum"})
        br = L.brands([b, c, a])
        self.assertEqual(br["ozom"], {"accent": "teal", "monogram": "oz", "building": {"style": "brick", "roof": "garden"}})
        self.assertEqual(br["iAware"], {"accent": "plum"})
        self.assertEqual(L.validate_building([a, b, c]), [])
        ia, ib = (L.structure(p, brand=br["ozom"])["identity"] for p in (a, b))
        for k in ("name", "accent", "monogram", "building"):
            self.assertEqual(ia[k], ib[k])                                   # mismo edificio, misma fachada

    def test_conflict_reported_and_lowest_project_wins(self):
        a = prof("ozom-gv", "ozom", brand={"accent": "teal", "building": {"style": "brick"}})
        b = prof("ozom-trade", "ozom", brand={"accent": "sage", "building": {"style": "brick"}})
        errs = L.validate_building([b, a])
        self.assertEqual(len(errs), 1)
        self.assertIn("office.brand.accent", errs[0])
        self.assertIn("gana ozom-gv", errs[0])
        self.assertEqual(L.brands([b, a])["ozom"]["accent"], "teal")


class TestStateAndEnvelope(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cfg = dict(copy.deepcopy(agent_config.DEFAULTS), machine_id="contabo-dev")
        self.conn = db.connect(os.path.join(self.tmp.name, "agent.db"))
        self.addCleanup(self.conn.close)
        self.profs = [prof("ozom-gv", "ozom", brand={"accent": "teal"}, look={"materials": {"floor": "cork"}}),
                      prof("ozom-trade", "ozom", brand={"building": {"style": "glass"}})]

    def emit(self, type, project, body, **kw):
        return events.emit_envelope(self.conn, self.cfg, type, project, body, ts=1_800_000_000.0, **kw)

    def test_office_changed_and_state_carry_identity(self):
        off = office.Office(self.conn, self.cfg, self.emit, profiles_fn=lambda: self.profs, clock=lambda: 1_800_000_000.0)
        self.assertEqual(sorted(off.reload()), ["ozom-gv", "ozom-trade"])
        st = projection.state(self.conn, self.cfg)
        by = {p["name"]: p["office"] for p in st["projects"]}
        gv, tr = by["ozom-gv"]["identity"], by["ozom-trade"]["identity"]
        self.assertEqual((gv["accent"]["name"], tr["accent"]["name"]), ("teal", "teal"))      # brand fusionado
        self.assertEqual((gv["building"]["style"], tr["building"]["style"]), ("glass", "glass"))
        self.assertEqual(gv["materials"]["floor"], "cork")
        self.assertNotEqual(tr["materials"]["floor"], "cork")
        self.assertIn("variant", by["ozom-gv"]["floors"][0]["identity"])
        self.assertEqual(off.reload(), [])                                  # sin cambios: no reemite
        self.profs[1]["office"]["look"] = {"lighting": "warm"}
        self.assertEqual(off.reload(), ["ozom-trade"])                      # cambiar el look reemite office.changed

    def test_projection_without_identity_stays_as_before(self):
        env = {"seq": 1, "type": "office.changed", "project": "p", "ts": "t", "subject": {"kind": "office", "id": "p"},
               "body": {"project": "p", "company": "Acme", "half_life_s": 1800, "floors": []}}
        st = projection.apply(projection.empty("m"), env)
        self.assertNotIn("identity", st["projects"][0]["office"])


if __name__ == "__main__":
    unittest.main()
