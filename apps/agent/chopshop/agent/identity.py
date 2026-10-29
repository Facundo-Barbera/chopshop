"""Identidad visual de empresas, proyectos y pisos (docs/plans/office-personalization.md).

Bloques del perfil local (todos opcionales, aditivos al `office:` de docs/plans/office-redesign.md):
- `office.brand`: identidad de la **empresa** (nombre visible, acento, monograma, logo, edificio, materiales base). Cualquier
  perfil de la empresa puede declararla; se fusiona entre perfiles (`company_brands`) y un valor distinto para la misma clave
  en dos perfiles es un problema de `validate_brands` (gana el proyecto de nombre menor, para que el render sea estable).
- `office.look`: sobrescritura del **proyecto** (acento, materiales, luz).
- `office.floors[i].look`: sobrescritura del **piso** (misma forma que `office.look`).

`resolve(prof, brand)` da la identidad efectiva del proyecto y `floor_identity(...)` la de cada piso; lo que nadie declara se
deriva de forma determinista del nombre de la empresa (y del proyecto/piso para `variant`), así dos oficinas sin configurar ya se
ven distintas. Los acentos salen siempre como hex **contenido** (saturación y luminosidad acotadas): la personalidad va en matices
y materiales, no en colores fuertes. Puro: sin I/O."""
import colorsys
import hashlib
import re

# Acentos con nombre: tonos apagados, cercanos a los grises del sistema (modo claro; la app aclara para el oscuro).
PALETTE = {
    "graphite": "#5f6368", "slate": "#5b6b7c", "indigo": "#5a5f8f", "teal": "#4b7f82", "sage": "#6f8467",
    "olive": "#7d7a52", "ochre": "#a07d45", "clay": "#a2664f", "rose": "#9a6372", "plum": "#74607f",
}
BUILDING_STYLES = ("glass", "brick", "concrete", "timber", "stone", "metal")
ROOFS = ("flat", "terrace", "sawtooth", "garden", "antenna")
FLOOR_MATERIALS = ("oak", "walnut", "ash", "concrete", "terrazzo", "carpet", "tile", "cork")
WALL_MATERIALS = ("white", "plaster", "brick", "timber", "glass", "concrete")
FURNITURE = ("oak", "walnut", "white", "black", "steel")
LIGHTING = ("warm", "neutral", "cool")
VARIANTS = 4                      # variaciones sutiles por piso (veta, alfombra, plantas): 0..3
LOGO_EXT = (".svg", ".png", ".pdf")
MAX_SAT = 0.45                    # tope de saturación HSL del acento
MIN_LIGHT, MAX_LIGHT = 0.32, 0.62

BRAND_KEYS = ("name", "accent", "monogram", "logo_file", "building", "materials", "lighting")
LOOK_KEYS = ("accent", "materials", "lighting")
BUILDING_KEYS = ("style", "roof")
MATERIAL_KEYS = ("floor", "walls", "furniture")
_MATERIALS = {"floor": FLOOR_MATERIALS, "walls": WALL_MATERIALS, "furniture": FURNITURE}

_HEX = re.compile(r"^#[0-9a-fA-F]{6}$")
_MONOGRAM = re.compile(r"^[A-Za-z0-9]{1,3}$")


def _mapping(v):
    return isinstance(v, dict)


def _office(prof):
    o = prof.get("office")
    return o if _mapping(o) else {}


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", str(name or "").lower()).strip("-") or "empresa"


def _pick(seed, options, salt=""):
    h = int(hashlib.sha1(("%s|%s" % (salt, seed)).encode("utf-8")).hexdigest()[:8], 16)
    return options[h % len(options)]


# ---------------------------------------------------------------- acento

def restrain(hex_color):
    """`#rrggbb` -> `#rrggbb` con saturación ≤ MAX_SAT y luminosidad en [MIN_LIGHT, MAX_LIGHT] (tono intacto)."""
    r, g, b = (int(hex_color[i:i + 2], 16) / 255.0 for i in (1, 3, 5))
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    r, g, b = colorsys.hls_to_rgb(h, min(max(l, MIN_LIGHT), MAX_LIGHT), min(s, MAX_SAT))
    return "#%02x%02x%02x" % tuple(int(round(x * 255)) for x in (r, g, b))


def accent(value):
    """Valor del perfil (nombre de PALETTE o `#rrggbb`) -> `{name, hex}` (hex contenido) o None si no vale."""
    if isinstance(value, str) and value.lower() in PALETTE:
        return {"name": value.lower(), "hex": PALETTE[value.lower()]}
    if isinstance(value, str) and _HEX.match(value):
        return {"name": None, "hex": restrain(value.lower())}
    return None


def monogram(name):
    """Monograma por defecto: iniciales de las dos primeras palabras, o las dos primeras letras de una sola palabra."""
    words = re.findall(r"[A-Za-z0-9]+", str(name or ""))
    if not words:
        return "?"
    if len(words) > 1:
        return (words[0][0] + words[1][0]).upper()
    return words[0][:2]


# ---------------------------------------------------------------- validación

def _look_errs(look, at, keys):
    if not _mapping(look):
        return ["%s: se esperaba un mapa (%s)" % (at, ", ".join(keys))]
    errs = ["%s.%s desconocido (%s)" % (at, k, ", ".join(keys)) for k in look if k not in keys]
    if "accent" in look and accent(look["accent"]) is None:
        errs.append("%s.accent debe ser uno de %s o #rrggbb" % (at, ", ".join(PALETTE)))
    m = look.get("materials")
    if m is not None:
        if not _mapping(m):
            errs.append("%s.materials: se esperaba un mapa (%s)" % (at, ", ".join(MATERIAL_KEYS)))
        else:
            for k, v in m.items():
                if k not in _MATERIALS:
                    errs.append("%s.materials.%s desconocido (%s)" % (at, k, ", ".join(MATERIAL_KEYS)))
                elif v not in _MATERIALS[k]:
                    errs.append("%s.materials.%s debe ser uno de %s" % (at, k, ", ".join(_MATERIALS[k])))
    if "lighting" in look and look["lighting"] not in LIGHTING:
        errs.append("%s.lighting debe ser uno de %s" % (at, ", ".join(LIGHTING)))
    return errs


def validate(prof):
    """Problemas de `office.brand`, `office.look` y `office.floors[i].look` (lista vacía si están bien o no existen)."""
    o = _office(prof)
    errs = []
    b = o.get("brand")
    if b is not None:
        errs += _look_errs(b, "office.brand", BRAND_KEYS)
        if _mapping(b):
            if "name" in b and not (isinstance(b["name"], str) and b["name"].strip()):
                errs.append("office.brand.name debe ser texto")
            if "monogram" in b and not (isinstance(b["monogram"], str) and _MONOGRAM.match(b["monogram"])):
                errs.append("office.brand.monogram: 1-3 letras o números")
            lf = b.get("logo_file")
            if lf is not None and (not isinstance(lf, str) or not lf or lf.startswith("/")
                                   or ".." in lf.replace("\\", "/").split("/") or not lf.lower().endswith(LOGO_EXT)):
                errs.append("office.brand.logo_file: ruta relativa dentro de ~/.chopshop/brand/ (%s)" % ", ".join(LOGO_EXT))
            bd = b.get("building")
            if bd is not None:
                if not _mapping(bd):
                    errs.append("office.brand.building: se esperaba un mapa (%s)" % ", ".join(BUILDING_KEYS))
                else:
                    errs += ["office.brand.building.%s desconocido (%s)" % (k, ", ".join(BUILDING_KEYS))
                             for k in bd if k not in BUILDING_KEYS]
                    if "style" in bd and bd["style"] not in BUILDING_STYLES:
                        errs.append("office.brand.building.style debe ser uno de %s" % ", ".join(BUILDING_STYLES))
                    if "roof" in bd and bd["roof"] not in ROOFS:
                        errs.append("office.brand.building.roof debe ser uno de %s" % ", ".join(ROOFS))
    if o.get("look") is not None:
        errs += _look_errs(o["look"], "office.look", LOOK_KEYS)
    floors = o.get("floors")
    for i, f in enumerate(floors if isinstance(floors, list) else []):
        if _mapping(f) and f.get("look") is not None:
            errs += _look_errs(f["look"], "office.floors[%d].look" % i, LOOK_KEYS)
    return errs


def _flat(brand):
    """{clave plana: valor} de un `brand` (building.* y materials.* se comparan por hoja)."""
    out = {}
    for k, v in brand.items():
        if k in ("building", "materials") and _mapping(v):
            out.update({"%s.%s" % (k, kk): vv for kk, vv in v.items()})
        else:
            out[k] = v
    return out


def company_brands(profiles, company_of):
    """{empresa: brand fusionado} entre perfiles; con claves en conflicto gana el proyecto de nombre menor.
    `company_of(prof)` = `layout.company` (se inyecta para no importar layout aquí)."""
    out = {}
    for p in sorted(profiles, key=lambda p: str(p.get("project"))):
        comp, b = company_of(p), _office(p).get("brand")
        if comp is None or not _mapping(b):
            continue
        merged = out.setdefault(comp, {})
        for k, v in b.items():
            if k in ("building", "materials") and _mapping(v):
                sub = merged.setdefault(k, {})
                for kk, vv in v.items():
                    sub.setdefault(kk, vv)
            else:
                merged.setdefault(k, v)
    return out


def validate_brands(profiles, company_of):
    """Conflictos de `office.brand` entre perfiles de la misma empresa."""
    seen, errs = {}, []
    for p in sorted(profiles, key=lambda p: str(p.get("project"))):
        comp, b = company_of(p), _office(p).get("brand")
        if comp is None or not _mapping(b):
            continue
        for k, v in sorted(_flat(b).items()):
            first = seen.setdefault((comp, k), (p.get("project"), v))
            if first[1] != v:
                errs.append("empresa %s: office.brand.%s distinto en %s (%r) y %s (%r); gana %s" % (
                    comp, k, first[0], first[1], p.get("project"), v, first[0]))
    return errs


# ---------------------------------------------------------------- resolución (perfil ya validado)

def _get(m, *path):
    for k in path:
        m = m.get(k) if _mapping(m) else None
    return m


def _materials(*layers):
    out = {}
    for k in MATERIAL_KEYS:
        v = next((l[k] for l in layers if _mapping(l) and l.get(k) in _MATERIALS[k]), None)
        out[k] = v
    return out


def company_identity(company, brand=None):
    """Identidad de la empresa (lo que es igual en todo el edificio): nombre, acento, monograma, logo, edificio."""
    seed = company or ""
    b = brand if _mapping(brand) else {}
    name = b.get("name") if isinstance(b.get("name"), str) and b["name"].strip() else company
    style = _get(b, "building", "style")
    roof = _get(b, "building", "roof")
    return {
        "name": name,
        "accent": accent(b.get("accent")) or accent(_pick(seed, sorted(PALETTE), "accent")),
        "monogram": b["monogram"] if isinstance(b.get("monogram"), str) and _MONOGRAM.match(b["monogram"]) else monogram(name),
        "logo": ("/brand/%s/logo" % slug(company)) if isinstance(b.get("logo_file"), str) and company else None,
        "building": {"style": style if style in BUILDING_STYLES else _pick(seed, BUILDING_STYLES, "style"),
                     "roof": roof if roof in ROOFS else _pick(seed, ROOFS, "roof")},
    }


def _base_materials(company, brand):
    seed = company or ""
    derived = {k: _pick(seed, opts, k) for k, opts in _MATERIALS.items()}
    return _materials(_get(brand, "materials"), derived)


def resolve(prof, brand=None, company=None):
    """Identidad efectiva del proyecto: empresa (brand o derivada) <- `office.look`. Forma de `office.identity` en `/state`."""
    b = brand if _mapping(brand) else {}
    look = _office(prof).get("look")
    look = look if _mapping(look) else {}
    ident = company_identity(company, b)
    lighting = next((v for v in (look.get("lighting"), b.get("lighting")) if v in LIGHTING), "neutral")
    ident.update({
        "accent": accent(look.get("accent")) or ident["accent"],
        "materials": _materials(look.get("materials"), _base_materials(company, b)),
        "lighting": lighting,
    })
    return ident


def floor_identity(project_identity, floor, project, index):
    """Identidad de un piso: la del proyecto <- `floors[i].look`, más `variant` (0..VARIANTS-1) por (proyecto, piso)."""
    look = floor.get("look") if _mapping(floor) and _mapping(floor.get("look")) else {}
    return {
        "accent": accent(look.get("accent")) or project_identity["accent"],
        "materials": _materials(look.get("materials"), project_identity["materials"]),
        "lighting": look["lighting"] if look.get("lighting") in LIGHTING else project_identity["lighting"],
        "variant": int(hashlib.sha1(("%s/%d" % (project, index)).encode("utf-8")).hexdigest()[:8], 16) % VARIANTS,
    }
