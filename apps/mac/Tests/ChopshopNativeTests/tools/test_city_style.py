"""Pruebas de la referencia del estilo de los edificios (city_style.py ≡ City/CityStyle.swift) y de su dorada.

    python3 -m unittest discover -s apps/mac/Tests/ChopshopNativeTests/tools -p 'test_*.py'"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import city_style as cs  # noqa: E402

FOOTPRINT_W = 4.6 * cs.TILE
FOOTPRINT_D = 3.2 * cs.TILE
OFFICE_INSET = 0.32 * cs.TILE


class CityStyleTests(unittest.TestCase):
    def test_hash_is_fnv1a_64(self):
        # mismos vectores que CityLights.hash
        self.assertEqual(cs.fnv1a(""), 0xcbf29ce484222325)
        self.assertEqual(cs.fnv1a("a"), 0xaf63dc4c8601ec8c)
        self.assertEqual(cs.fnv1a("foobar"), 0x85944171f73967e8)

    def test_golden_is_up_to_date(self):
        with open(cs.GOLDEN_PATH, encoding="utf-8") as f:
            self.assertEqual(json.load(f), json.loads(json.dumps(cs.golden())),
                             "regenera con: python3 apps/mac/Tests/ChopshopNativeTests/tools/city_style.py")

    def test_deterministic(self):
        self.assertEqual(cs.style("ozom"), cs.style("ozom"))
        self.assertEqual(cs.building("ozom", ["a", "b"]), cs.building("ozom", ["a", "b"]))

    def test_city_buildings_are_recognizable(self):
        seeds = [s for s, _ in cs.GOLDEN]
        looks = [(cs.style(s)["material"], cs.style(s)["windows"], cs.style(s)["roof"]) for s in seeds]
        self.assertEqual(len(set(looks)), len(looks), looks)

    def test_every_table_entry_is_reachable(self):
        seen = {k: set() for k in ["material", "windows", "roof", "plinth_h", "ground_scale", "door_bay", "setback_level",
                                   "setback_inset"]}
        heights, blinds = set(), set()
        for i in range(400):
            st = cs.style("empresa-%d" % i)
            for k in seen:
                seen[k].add(st[k])
            heights.add(cs.floor_scale(st, "p%d" % i))
            blinds.add(cs.blind(st, "p", i % 11))
        self.assertEqual(seen["material"], set(cs.MATERIALS))
        self.assertEqual(seen["windows"], set(cs.WINDOWS))
        self.assertEqual(seen["roof"], set(cs.ROOFS))
        self.assertEqual(seen["plinth_h"], set(cs.PLINTH_H))
        self.assertEqual(seen["ground_scale"], set(cs.GROUND_SCALE))
        self.assertEqual(seen["door_bay"], set(cs.DOOR_BAY))
        self.assertEqual(seen["setback_level"], set(cs.SETBACK_LEVEL))
        self.assertEqual(seen["setback_inset"], set(cs.SETBACK_INSET))
        self.assertEqual(heights, set(cs.FLOOR_SCALE))
        self.assertEqual(blinds, set(cs.BLIND))

    def test_door_is_never_on_a_corner(self):
        for b in cs.DOOR_BAY:
            self.assertTrue(0 < b < cs.WINDOWS_LEFT - 1)

    def test_floors_stack_without_gaps_and_ground_floor_is_tallest(self):
        ids = ["lobby:X", "x#0", "x#1", "x#2", "x#3"]
        for i in range(100):
            st = cs.style("e%d" % i)
            z = st["plinth_h"]
            for k in range(len(ids)):
                self.assertAlmostEqual(cs.floor_z(st, ids, k), z)
                z += cs.floor_height(st, ids, k)
                if k > 0:
                    self.assertGreater(cs.floor_height(st, ids, 0), cs.floor_height(st, ids, k))
            self.assertAlmostEqual(cs.floor_z(st, ids, len(ids)), z)

    def test_existing_floors_do_not_move_when_floors_are_added(self):
        # la ciudad en vivo gana pisos arriba: lo que ya está no salta
        for i in range(50):
            st = cs.style("e%d" % i)
            short, tall = ["lobby:E", "e#0"], ["lobby:E", "e#0", "e#1", "e#2"]
            for k in range(len(short)):
                self.assertEqual(cs.floor_z(st, short, k), cs.floor_z(st, tall, k))
                self.assertEqual(cs.floor_height(st, short, k), cs.floor_height(st, tall, k))

    def test_setback_never_on_the_two_lowest_floors_and_office_still_fits(self):
        for i in range(100):
            st = cs.style("e%d" % i)
            self.assertEqual(cs.inset(st, 0), 0)
            self.assertEqual(cs.inset(st, 1), 0, "la planta baja y el primer piso llevan la fachada entera")
            for k in range(5):
                i_ = cs.inset(st, k)
                # la planta de un piso retirado: se retira entero por delante y la mitad por detrás
                self.assertGreater(FOOTPRINT_W - 1.5 * i_ - 2 * OFFICE_INSET, 0.6 * FOOTPRINT_W)
                self.assertGreater(FOOTPRINT_D - 1.5 * i_ - 2 * OFFICE_INSET, 0.5 * FOOTPRINT_D)
                self.assertLessEqual(cs.inset(st, k), cs.inset(st, k + 1), "un retranqueo no vuelve a salir")

    def test_seed_override_changes_the_look(self):
        # gancho de la personalización: otra semilla, otro edificio
        self.assertNotEqual(cs.style("Personal"), cs.style("Personal·2"))


if __name__ == "__main__":
    unittest.main()
