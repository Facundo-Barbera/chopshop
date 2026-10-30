"""Referencia en Python del estilo de los edificios de la ciudad (City/CityStyle.swift): MISMA derivación, para probarla y
generar la dorada sin Swift.

    python3 apps/mac/Tests/ChopshopNativeTests/tools/city_style.py    # reescribe Resources/city-styles.json

`CityStyleTests` (Swift) comprueba que `CityBuildingStyle(seed:)` y la geometría por piso dan lo mismo que esta dorada.
Todo sale de tablas y de FNV-1a de 64 bits (`CityLights.hash`): nada aleatorio, estable entre procesos y lenguajes."""
import json
import os

TILE = 34.0
FLOOR_H = 42.0
SLAB_H = 5.0
WINDOWS_LEFT = 6
WINDOWS_RIGHT = 5

MATERIALS = ["concrete", "limestone", "brick", "slate"]
WINDOWS = ["ribbon", "punched", "paired", "vertical"]
ROOFS = ["units", "tank", "penthouse", "mast"]
PLINTH_H = [4.0, 6.0, 8.0]
GROUND_SCALE = [1.15, 1.25, 1.35]
DOOR_BAY = [1, 2, 3, 4]
SETBACK_LEVEL = [None, 2, 3]
SETBACK_INSET = [0.22 * TILE, 0.34 * TILE]
FLOOR_SCALE = [0.94, 1.0, 1.0, 1.08]
BLIND = [0.0, 0.0, 0.0, 0.3, 0.55]
# alto de la azotea por encima del último piso (losa + pretil + lo que lleve encima)
ROOF_H = {"units": 13.0, "tank": 28.0, "penthouse": 24.0, "mast": 42.0}


def fnv1a(s):
    h = 0xcbf29ce484222325
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


M64 = 0xFFFFFFFFFFFFFFFF


def mix(h):
    """Finalizador de splitmix64: los bits bajos de FNV-1a se parecen mucho entre sales que solo cambian al final."""
    h = ((h ^ (h >> 30)) * 0xbf58476d1ce4e5b9) & M64
    h = ((h ^ (h >> 27)) * 0x94d049bb133111eb) & M64
    return h ^ (h >> 31)


def pick(seed, salt, table):
    return table[mix(fnv1a("%s|%s" % (seed, salt))) % len(table)]


def style(seed):
    return {
        "seed": seed,
        "material": pick(seed, "material", MATERIALS),
        "windows": pick(seed, "windows", WINDOWS),
        "roof": pick(seed, "roof", ROOFS),
        "plinth_h": pick(seed, "plinth", PLINTH_H),
        "ground_scale": pick(seed, "ground", GROUND_SCALE),
        "door_bay": pick(seed, "door", DOOR_BAY),
        "setback_level": pick(seed, "setback", SETBACK_LEVEL),
        "setback_inset": pick(seed, "inset", SETBACK_INSET),
    }


def floor_scale(st, floor_id):
    return pick("%s|%s" % (st["seed"], floor_id), "height", FLOOR_SCALE)


def blind(st, floor_id, window):
    return pick("%s|%s#%d" % (st["seed"], floor_id, window), "blind", BLIND)


def floor_height(st, floor_ids, level):
    if level < 0 or level >= len(floor_ids):
        return FLOOR_H
    return FLOOR_H * (st["ground_scale"] if level == 0 else floor_scale(st, floor_ids[level]))


def floor_z(st, floor_ids, level):
    z = st["plinth_h"]
    for k in range(max(0, level)):
        z += floor_height(st, floor_ids, k)
    return z


def inset(st, level):
    lv = st["setback_level"]
    return st["setback_inset"] if lv is not None and level >= lv else 0.0


def building(seed, floor_ids):
    """Geometría de un edificio (lo que la dorada fija por piso)."""
    st = style(seed)
    return {
        "style": st,
        "floors": [{"id": f, "z": floor_z(st, floor_ids, k), "h": floor_height(st, floor_ids, k), "inset": inset(st, k),
                    "blinds": [blind(st, f, i) for i in range(WINDOWS_LEFT + WINDOWS_RIGHT)]}
                   for k, f in enumerate(floor_ids)],
        "height": floor_z(st, floor_ids, len(floor_ids)),
        "roof_h": ROOF_H[st["roof"]],
    }


# Edificios de la dorada: los de las escenas de la ciudad (city-fixture.jsonl y CityOfficeFixture).
GOLDEN = [
    ("Personal", ["chopshop", "life", "orchestrator"]),
    ("iAware", ["nuskills"]),
    ("ozom", ["ozom-gv", "ozom-trade"]),
    ("Bixku", ["bixku-utilities"]),
    ("Otros", ["alfa-lab", "zeta"]),
    ("Awesome GB", ["lobby:Awesome GB", "awesome-gb#0", "awesome-gb#1", "awesome-gb#2", "awesome-gb#3"]),
]


def golden():
    return {"buildings": [building(seed, ids) for seed, ids in GOLDEN]}


GOLDEN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "city-styles.json")


def write_golden(path=GOLDEN_PATH):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(golden(), f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    write_golden()
    for b in golden()["buildings"]:
        s = b["style"]
        print("%-11s %-9s %-8s %-9s plinto %g planta baja ×%g puerta %d retranqueo %s alto %.1f" % (
            s["seed"], s["material"], s["windows"], s["roof"], s["plinth_h"], s["ground_scale"], s["door_bay"],
            s["setback_level"], b["height"]))
