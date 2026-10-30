"""API de estructura de la oficina para los bots (fase 7 de docs/plans/office-redesign.md): `PUT /office/<proyecto>`.

- `read(conn, project) -> {project, rev, office, rack, structure, limits}`: lo que un bot necesita para editar.
- `apply(conn, project, office, rack=None, by=..., base_rev=None, reactivate=()) -> resultado`: valida igual que
  `chopshop profile check` (bloques `office:`/`rack:` + tope de pisos por edificio), reescribe SOLO esos bloques del perfil
  local (`~/.chopshop/profiles/<proyecto>.yaml`, escritura atómica, resto del archivo intacto) y calcula el diff de
  escritorios. Nunca borra escritorios: los que el perfil deja de declarar quedan `retired`. Reactivar uno retirado exige
  nombrarlo en `reactivate` (lo pide un humano). `base_rev` (opcional) evita pisar la edición de otro bot (409).
- Escritorios conocidos por proyecto en `meta` (`office_desks:<proyecto>` = {"known": [...], "retired": [...]}); si falta,
  se reconstruye del último `office.changed` del proyecto y de los escritorios del perfil actual.
El emisor del sobre `office.changed` es el llamador (server.AgentApp). Errores -> `StructureError(status, message, problems)`."""
import hashlib
import json
import os
import re
import threading

from .. import miniyaml, profile as profile_mod
from . import db, layout

META_KEY = "office_desks:%s"
_lock = threading.Lock()                         # un PUT a la vez (lectura, validación y escritura del perfil)
_TOP = re.compile(r"^(?P<k>[A-Za-z_][A-Za-z0-9_]*)\s*:")
_PLAIN_KEY = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")
LIMITS = {"floors_per_project": layout.MAX_FLOORS_PER_PROJECT, "rooms_per_floor": layout.MAX_ROOMS_PER_FLOOR,
          "desks_per_room": layout.MAX_DESKS_PER_ROOM, "desks_per_floor": layout.MAX_DESKS_PER_FLOOR,
          "building_floors": layout.MAX_BUILDING_FLOORS, "flex_per_floor": layout.MAX_FLEX_PER_FLOOR,
          "extra_floors": layout.MAX_EXTRA_FLOORS, "outsourced_floors": layout.MAX_OUTSOURCED_FLOORS}


class StructureError(Exception):
    def __init__(self, status, message, problems=None):
        super().__init__(message)
        self.status, self.message, self.problems = status, message, list(problems or [])


# ---------------------------------------------------------------- YAML (subconjunto que entiende miniyaml)

def _key(k):
    if not isinstance(k, str) or not k or any(ord(c) < 32 for c in k) or '"' in k or "\\" in k:
        raise StructureError(400, "clave no representable en el perfil: %r" % (k,))
    return k if _PLAIN_KEY.match(k) else '"%s"' % k


def _scalar(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        if v != v or v in (float("inf"), float("-inf")):
            raise StructureError(400, "número no representable en el perfil")
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list) and not v:
        return "[]"
    if isinstance(v, dict) and not v:
        return "{}"
    return None


def dump(v, indent=0):
    """Valor JSON -> líneas YAML en bloque (miniyaml las vuelve a leer igual; `write` lo comprueba)."""
    pad = " " * indent
    out = []
    if isinstance(v, dict):
        for k, x in v.items():
            s = _scalar(x)
            if s is not None:
                out.append("%s%s: %s" % (pad, _key(k), s))
            else:
                out.append("%s%s:" % (pad, _key(k)))
                out += dump(x, indent + 2)
    elif isinstance(v, list):
        for x in v:
            s = _scalar(x)
            if s is not None:
                out.append("%s- %s" % (pad, s))
            elif isinstance(x, dict):
                sub = dump(x, indent + 2)
                out.append("%s- %s" % (pad, sub[0][indent + 2:]))
                out += sub[1:]
            else:
                out.append("%s-" % pad)
                out += dump(x, indent + 2)
    else:
        raise StructureError(400, "valor no representable en el perfil: %s" % type(v).__name__)
    return out


def replace_blocks(text, blocks):
    """Sustituye (o añade al final) los bloques de primer nivel `blocks` = {clave: valor} en el texto del perfil."""
    lines = text.splitlines()
    for key, value in blocks.items():
        new = ["%s:" % key] + dump(value, 2) if _scalar(value) is None else ["%s: %s" % (key, _scalar(value))]
        start = next((i for i, ln in enumerate(lines) if (_TOP.match(ln) and _TOP.match(ln).group("k")) == key), None)
        if start is None:
            if lines and lines[-1].strip():
                lines.append("")
            lines += new
            continue
        end = start + 1
        while end < len(lines) and (not lines[end].strip() or lines[end][0] in " \t"):
            end += 1
        while end > start + 1 and not lines[end - 1].strip():      # conserva las líneas en blanco antes del siguiente bloque
            end -= 1
        lines[start:end] = new
    return "\n".join(lines) + "\n"


def rev(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


# ---------------------------------------------------------------- escritorios conocidos

def _known(conn, project, prof):
    """(known, retired): ids de escritorios que alguna vez existieron y los que hoy están retirados."""
    with db.tx():
        row = conn.execute("SELECT value FROM meta WHERE key=?", (META_KEY % project,)).fetchone()
        last = None if row else conn.execute(
            "SELECT body FROM events WHERE type='office.changed' AND subject_id=? ORDER BY seq DESC LIMIT 1",
            (project,)).fetchone()
    if row:
        d = db.jload(row["value"], {}) or {}
        known, retired = set(d.get("known") or []), set(d.get("retired") or [])
    else:
        known, retired = set(), set()
        body = db.jload(last["body"], {}) if last else {}
        for f in (body or {}).get("floors") or []:
            for r in (f or {}).get("rooms") or []:
                for dk in (r or {}).get("desks") or []:
                    if isinstance(dk, dict) and isinstance(dk.get("id"), str):
                        known.add(dk["id"])
                        if dk.get("retired"):
                            retired.add(dk["id"])
    current = {d["id"] for d in layout.desks(prof)}
    known |= current
    retired -= current
    return known, retired


def _known_saved(conn, project):
    with db.tx():
        row = conn.execute("SELECT value FROM meta WHERE key=?", (META_KEY % project,)).fetchone()
    return set((db.jload(row["value"], {}) or {}).get("known") or []) if row else None


def _save_known(conn, project, known, retired):
    with db.tx():
        conn.execute("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)",
                     (META_KEY % project, db.jdump({"known": sorted(known), "retired": sorted(retired)})))


# ---------------------------------------------------------------- lectura y escritura

def _load(project):
    try:
        prof = profile_mod.load(project)
    except profile_mod.ProfileError as e:
        status = 404 if "no existe" in str(e) else (400 if "inválido" in str(e) else 500)
        raise StructureError(status, str(e) if status != 500 else "el perfil local no se puede leer")
    with open(prof["_path"], encoding="utf-8") as f:
        text = f.read()
    return prof, text


def read(conn, project):
    prof, text = _load(project)
    _, retired = _known(conn, project, prof)
    return {"project": project, "rev": rev(text), "office": prof.get("office"), "rack": prof.get("rack"),
            "machine_rooms": prof.get("machine_rooms"), "structure": layout.structure(prof, retired), "limits": LIMITS}


def _building_errs(project, candidate):
    profs = [candidate]
    for name in profile_mod.list_projects():
        if name == project:
            continue
        try:
            profs.append(profile_mod.load(name))
        except profile_mod.ProfileError:
            continue
    comp = layout.company(candidate)
    return layout.validate_building([p for p in profs if layout.company(p) == comp])


def apply(conn, project, office, rack=None, by="bot", base_rev=None, reactivate=()):
    """Valida y escribe. -> {project, rev, changed, by, structure, diff}. `structure` lleva los retirados."""
    if not isinstance(office, dict):
        raise StructureError(400, "office debe ser un mapa (el bloque office: del perfil)")
    if rack is not None and not isinstance(rack, dict):
        raise StructureError(400, "rack debe ser un mapa (el bloque rack: del perfil)")
    with _lock:
        prof, text = _load(project)
        if base_rev is not None and base_rev != rev(text):
            raise StructureError(409, "el perfil cambió desde base_rev (vuelve a leer GET /office/%s)" % project)
        candidate = {k: v for k, v in prof.items() if not k.startswith("_")}
        candidate["office"] = office
        if rack is not None:
            candidate["rack"] = rack
        problems = layout.validate(candidate)
        if not problems:
            problems = _building_errs(project, candidate)
        if problems:
            raise StructureError(400, "estructura inválida (%d problemas)" % len(problems), problems)

        known, retired = _known(conn, project, prof)
        new_ids = [d["id"] for d in layout.desks(candidate)]
        new = set(new_ids)
        reactivated = sorted(new & retired)
        missing = [d for d in reactivated if d not in set(reactivate or ())]
        if missing:
            raise StructureError(409, "reactivar escritorios retirados lo pide un humano: nómbralos en `reactivate`",
                                 ["%s está retirado" % d for d in missing])
        old_current = {d["id"] for d in layout.desks(prof)}
        diff = {"added": [d for d in new_ids if d not in known],
                "retired": sorted(old_current - new),
                "reactivated": reactivated}
        retired_after = (retired | (known - new)) - new
        known_after = known | new

        blocks = {"office": office}
        if rack is not None:
            blocks["rack"] = rack
        before = miniyaml.loads(text) or {}
        if all(before.get(k) == v for k, v in blocks.items()):         # mismo contenido: no se reescribe ni se emite
            if known != _known_saved(conn, project):
                _save_known(conn, project, known, retired)
            candidate["project"] = project
            return {"project": project, "rev": rev(text), "changed": False, "by": by,
                    "structure": layout.structure(candidate, retired), "diff": diff}
        out = replace_blocks(text, blocks)
        try:
            parsed = miniyaml.loads(out)
        except miniyaml.YamlError as e:
            raise StructureError(400, "la estructura no se puede escribir en el perfil: %s" % e)
        if parsed != dict(before, **blocks):
            raise StructureError(400, "la estructura no se puede escribir en el perfil sin cambiar su contenido "
                                      "(texto con comillas o barras invertidas que el perfil no admite)")
        _write(prof["_path"], out)
        _save_known(conn, project, known_after, retired_after)
        candidate["project"] = project
        return {"project": project, "rev": rev(out), "changed": True, "by": by,
                "structure": layout.structure(candidate, retired_after), "diff": diff}


def _write(path, text):
    """Escritura atómica que conserva el modo del archivo (los perfiles son locales y privados)."""
    mode = os.stat(path).st_mode & 0o777
    tmp = "%s.tmp-%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def changed_body(res):
    """Cuerpo del sobre `office.changed` (docs/event-envelope.md) a partir del resultado de `apply`."""
    s = res["structure"]
    return {"project": res["project"], "by": res["by"], "company": s["company"], "half_life_s": s["half_life_s"],
            "floors": s["floors"], "machine_rooms": s["machine_rooms"], "capacity": s["capacity"],
            "outsourced": s["outsourced"], "diff": res["diff"]}
