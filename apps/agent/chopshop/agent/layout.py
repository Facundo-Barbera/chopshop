"""Estructura de la oficina y del rack desde el perfil local (bloques `office:` y `rack:`, docs/plans/office-redesign.md).

- `validate(prof) -> [problema]`: lo llama `profile.validate` (y `chopshop profile check`); aplica los topes
  (`MAX_FLOORS_PER_PROJECT`, `MAX_ROOMS_PER_FLOOR`, `MAX_DESKS_PER_ROOM`, `MAX_DESKS_PER_FLOOR`).
- `validate_building(profiles) -> [problema]`: tope de pisos de proyecto por edificio (empresa) entre todos los perfiles.
- `desks(prof) -> [desk]`: escritorios declarados, con id estable `<proyecto>/<piso>/<rol>/<n>` (piso y n desde 0).
- `structure(prof)`: forma de `office` para el sobre `office.changed` y para `GET /state` (sin ocupantes).
- `roles(prof)`, `wake_triggers(prof, role)`, `match_rules(prof)`, `half_life_s(prof)`, `rack_repos(prof)`, `rack_actors(prof)`.
- `machine_rooms(prof)`: salas de máquinas del bloque opcional `machine_rooms:` (0..N por proyecto; cada una en un piso de
  `office.floors`, con los repos del rack, listeners, automatizaciones y webhooks que aloja, por nombre o glob). Van en
  `structure()` como `machine_rooms` (y de ahí al sobre `office.changed` y a `projects[].office`).
Puro: sin I/O (el perfil ya viene cargado por `chopshop.profile.load`)."""
import re

from . import automations

MAX_FLOORS_PER_PROJECT = 4
MAX_ROOMS_PER_FLOOR = 6
MAX_DESKS_PER_ROOM = 6
MAX_DESKS_PER_FLOOR = 24
MAX_BUILDING_FLOORS = 16          # pisos de proyecto por edificio (más la planta baja = vestíbulo)
DEFAULT_HALF_LIFE = 30 * 60       # s
MIN_HALF_LIFE = 60
MAX_HALF_LIFE = 7 * 86400
DEFAULT_FLEX_PER_FLOOR = 4
MAX_FLEX_PER_FLOOR = 8
DEFAULT_EXTRA_FLOORS = 2
MAX_EXTRA_FLOORS = 4
MAX_OUTSOURCED_FLOORS = 4
MIN_ELASTIC_FLOOR_DESKS = 4
FLEX_ROLE = "_flex"
OUT_ROLE = "_out"
OUTSOURCED_LABEL = "Contratista"

OFFICE_KEYS = ("company", "half_life", "floors", "roles")
FLOOR_KEYS = ("name", "rooms")
ROOM_KEYS = ("role", "desks", "permanent")
ROLE_KEYS = ("prompt_file", "wake", "match")
MATCH_KEYS = ("title", "branch", "label")
RACK_KEYS = ("repos", "actors")
REPO_KEYS = ("provider", "repo", "kind", "label")
PROVIDERS = ("github",)           # se suman con su adaptador en agent/forge/
REPO_KINDS = ("main", "docs", "service", "lib", "other")
ACTOR_KEYS = ("kind", "label")
ACTOR_KINDS = ("bot", "human")
MACHINE_ROOM_KEYS = ("name", "floor", "repos", "listeners", "automations", "subscriptions")
MACHINE_ROOM_LISTS = MACHINE_ROOM_KEYS[2:]
CAPACITY_KEYS = ("flex_per_floor", "max_extra_floors", "outsourcing")
WAKE_EVENT = "desk.note"          # disparador extra de `wake`: una nota nueva en el escritorio

_ROLE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
_REPO = re.compile(r"^[^/\s]+/[^/\s]+$")


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _mapping(v):
    return isinstance(v, dict)


def parse_duration(v):
    """`30m` / `2h` / `90s` / `1d` / segundos -> segundos (None si no vale)."""
    return automations.parse_every(v)


# ---------------------------------------------------------------- validación

def validate(prof):
    """Problemas de los bloques `office:` y `rack:` (lista vacía si están bien o no existen)."""
    return _office_errs(prof) + _rack_errs(prof) + _machine_errs(prof) + _capacity_errs(prof)


def _capacity_errs(prof):
    c = prof.get("capacity")
    if c is None:
        return []
    if not _mapping(c):
        return ["capacity: se esperaba un mapa (%s)" % ", ".join(CAPACITY_KEYS)]
    errs = ["capacity.%s desconocido (%s)" % (k, ", ".join(CAPACITY_KEYS)) for k in c if k not in CAPACITY_KEYS]
    if "flex_per_floor" in c and not (_int(c["flex_per_floor"]) and 0 <= c["flex_per_floor"] <= MAX_FLEX_PER_FLOOR):
        errs.append("capacity.flex_per_floor debe ser un entero 0-%d" % MAX_FLEX_PER_FLOOR)
    if "max_extra_floors" in c and not (_int(c["max_extra_floors"]) and 0 <= c["max_extra_floors"] <= MAX_EXTRA_FLOORS):
        errs.append("capacity.max_extra_floors debe ser un entero 0-%d" % MAX_EXTRA_FLOORS)
    if "outsourcing" in c and not isinstance(c["outsourcing"], bool):
        errs.append("capacity.outsourcing debe ser true o false")
    return errs


def _office_errs(prof):
    o = prof.get("office")
    if o is None:
        return []
    if not _mapping(o):
        return ["office: se esperaba un mapa"]
    errs = ["office.%s desconocido (%s)" % (k, ", ".join(OFFICE_KEYS)) for k in o if k not in OFFICE_KEYS]
    if "company" in o and not (isinstance(o["company"], str) and o["company"].strip()):
        errs.append("office.company debe ser un nombre")
    if "half_life" in o:
        hl = parse_duration(o["half_life"])
        if hl is None or not MIN_HALF_LIFE <= hl <= MAX_HALF_LIFE:
            errs.append("office.half_life inválido (p. ej. 30m; entre %ds y 7d)" % MIN_HALF_LIFE)
    floors = o.get("floors")
    if floors is None:
        floors = []
    if not isinstance(floors, list):
        errs.append("office.floors: se esperaba una lista")
        floors = []
    if len(floors) > MAX_FLOORS_PER_PROJECT:
        errs.append("office.floors: %d pisos (máximo %d por proyecto)" % (len(floors), MAX_FLOORS_PER_PROJECT))
    declared, permanent = set(), set()
    for i, f in enumerate(floors):
        at = "office.floors[%d]" % i
        if not _mapping(f):
            errs.append("%s: se esperaba un mapa {name, rooms}" % at)
            continue
        errs += ["%s.%s desconocido (%s)" % (at, k, ", ".join(FLOOR_KEYS)) for k in f if k not in FLOOR_KEYS]
        if "name" in f and not isinstance(f["name"], str):
            errs.append("%s.name debe ser texto" % at)
        rooms = f.get("rooms")
        if not isinstance(rooms, list) or not rooms:
            errs.append("%s.rooms: se esperaba una lista no vacía de {role, desks}" % at)
            continue
        if len(rooms) > MAX_ROOMS_PER_FLOOR:
            errs.append("%s.rooms: %d departamentos (máximo %d por piso)" % (at, len(rooms), MAX_ROOMS_PER_FLOOR))
        total, seen = 0, set()
        for j, r in enumerate(rooms):
            rat = "%s.rooms[%d]" % (at, j)
            if not _mapping(r):
                errs.append("%s: se esperaba un mapa {role, desks, permanent?}" % rat)
                continue
            errs += ["%s.%s desconocido (%s)" % (rat, k, ", ".join(ROOM_KEYS)) for k in r if k not in ROOM_KEYS]
            role = r.get("role")
            if not isinstance(role, str) or not _ROLE.match(role):
                errs.append("%s.role inválido (minúsculas, números, _ -; máx. 32)" % rat)
            elif role in seen:
                errs.append("%s.role repetido en el piso: %s" % (rat, role))
            else:
                seen.add(role)
                declared.add(role)
            n = r.get("desks", 1)
            if not _int(n) or not 1 <= n <= MAX_DESKS_PER_ROOM:
                errs.append("%s.desks debe ser un entero 1-%d" % (rat, MAX_DESKS_PER_ROOM))
            else:
                total += n
            if "permanent" in r:
                if not isinstance(r["permanent"], bool):
                    errs.append("%s.permanent debe ser true o false" % rat)
                elif r["permanent"] and isinstance(role, str):
                    permanent.add(role)
        if total > MAX_DESKS_PER_FLOOR:
            errs.append("%s: %d escritorios (máximo %d por piso)" % (at, total, MAX_DESKS_PER_FLOOR))
    roles = o.get("roles")
    if roles is None:
        return errs
    if not _mapping(roles):
        return errs + ["office.roles: se esperaba un mapa {rol: {...}}"]
    for name, spec in roles.items():
        at = "office.roles.%s" % name
        if name not in declared:
            errs.append("%s: el rol no tiene departamento en office.floors" % at)
        if not _mapping(spec):
            errs.append("%s: se esperaba un mapa (%s)" % (at, ", ".join(ROLE_KEYS)))
            continue
        errs += ["%s.%s desconocido (%s)" % (at, k, ", ".join(ROLE_KEYS)) for k in spec if k not in ROLE_KEYS]
        pf = spec.get("prompt_file")
        if pf is not None and (not isinstance(pf, str) or not pf or pf.startswith("/")
                               or ".." in pf.replace("\\", "/").split("/")):
            errs.append("%s.prompt_file debe ser una ruta relativa dentro de ~/.chopshop/automations/<proyecto>/" % at)
        m = spec.get("match")
        if m is not None:
            if not _mapping(m) or not m:
                errs.append("%s.match: se esperaba un mapa {title|branch|label: regex}" % at)
            else:
                for k, rx in m.items():
                    if k not in MATCH_KEYS:
                        errs.append("%s.match.%s desconocido (%s)" % (at, k, ", ".join(MATCH_KEYS)))
                        continue
                    try:
                        re.compile(str(rx))
                    except re.error as e:
                        errs.append("%s.match.%s no es regex: %s" % (at, k, e))
        wake = spec.get("wake")
        if wake is not None:
            if name not in permanent:
                errs.append("%s.wake: solo los roles con un departamento permanent: true se despiertan" % at)
            if not isinstance(wake, list) or not wake:
                errs.append("%s.wake: se esperaba una lista de disparadores" % at)
            else:
                for k, t in enumerate(_normalize_wake(wake)):
                    tat = "%s.wake[%d]" % (at, k)
                    if isinstance(t, dict) and t.get("type") == WAKE_EVENT:
                        errs += ["%s.%s no aplica a desk.note" % (tat, x) for x in t if x != "type"]
                    else:
                        errs += automations.trigger_errs(t, tat)
    return errs


def _rack_errs(prof):
    r = prof.get("rack")
    if r is None:
        return []
    if not _mapping(r):
        return ["rack: se esperaba un mapa"]
    errs = ["rack.%s desconocido (%s)" % (k, ", ".join(RACK_KEYS)) for k in r if k not in RACK_KEYS]
    repos = r.get("repos") or []
    if not isinstance(repos, list):
        errs.append("rack.repos: se esperaba una lista")
        repos = []
    seen = set()
    for i, e in enumerate(repos):
        at = "rack.repos[%d]" % i
        if not _mapping(e):
            errs.append("%s: se esperaba un mapa {provider, repo, kind}" % at)
            continue
        errs += ["%s.%s desconocido (%s)" % (at, k, ", ".join(REPO_KEYS)) for k in e if k not in REPO_KEYS]
        prov = e.get("provider", "github")
        if prov not in PROVIDERS:
            errs.append("%s.provider desconocido %r (%s)" % (at, prov, ", ".join(PROVIDERS)))
        repo = e.get("repo")
        if not isinstance(repo, str) or not _REPO.match(repo):
            errs.append("%s.repo debe ser <dueño>/<repo>" % at)
        elif (prov, repo) in seen:
            errs.append("%s.repo repetido: %s" % (at, repo))
        else:
            seen.add((prov, repo))
        if e.get("kind", "main") not in REPO_KINDS:
            errs.append("%s.kind debe ser uno de %s" % (at, ", ".join(REPO_KINDS)))
        if "label" in e and not isinstance(e["label"], str):
            errs.append("%s.label debe ser texto" % at)
    actors = r.get("actors") or {}
    if not _mapping(actors):
        errs.append("rack.actors: se esperaba un mapa {login: {kind, label}}")
        actors = {}
    for login, a in actors.items():
        at = "rack.actors.%s" % login
        if not _mapping(a):
            errs.append("%s: se esperaba un mapa {kind, label}" % at)
            continue
        errs += ["%s.%s desconocido (%s)" % (at, k, ", ".join(ACTOR_KEYS)) for k in a if k not in ACTOR_KEYS]
        if a.get("kind", "bot") not in ACTOR_KINDS:
            errs.append("%s.kind debe ser bot o human" % at)
        if "label" in a and not isinstance(a["label"], str):
            errs.append("%s.label debe ser texto" % at)
    return errs


def _machine_errs(prof):
    m = prof.get("machine_rooms")
    if m is None:
        return []
    if not isinstance(m, list):
        return ["machine_rooms: se esperaba una lista de {name, floor, repos, listeners, automations, subscriptions}"]
    fl = floors(prof)
    depts = [len(f.get("rooms") or []) if isinstance(f.get("rooms"), list) else 0 for f in fl]
    errs, seen = [], set()
    for i, r in enumerate(m):
        at = "machine_rooms[%d]" % i
        if not _mapping(r):
            errs.append("%s: se esperaba un mapa {name, floor, ...}" % at)
            continue
        errs += ["%s.%s desconocido (%s)" % (at, k, ", ".join(MACHINE_ROOM_KEYS)) for k in r if k not in MACHINE_ROOM_KEYS]
        name = r.get("name")
        if not isinstance(name, str) or not name.strip():
            errs.append("%s.name debe ser un nombre" % at)
        elif name in seen:
            errs.append("%s.name repetido: %s" % (at, name))
        else:
            seen.add(name)
        f = r.get("floor", 0)
        if not _int(f) or not 0 <= f < len(fl):
            errs.append("%s.floor debe ser un piso de office.floors (0..%d)" % (at, len(fl) - 1) if fl else
                        "%s: una sala de máquinas necesita office.floors" % at)
        else:
            depts[f] += 1
        for k in MACHINE_ROOM_LISTS:
            v = r.get(k, [])
            if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
                errs.append("%s.%s: se esperaba una lista de nombres (o globs)" % (at, k))
    errs += ["office.floors[%d]: %d departamentos + salas de máquinas (máximo %d por piso)" % (i, n, MAX_ROOMS_PER_FLOOR)
             for i, n in enumerate(depts) if n > MAX_ROOMS_PER_FLOOR]
    return errs


def validate_building(profiles):
    """Tope de pisos de proyecto por edificio: `profiles` = perfiles cargados; agrupa por `company(prof)`."""
    per = {}
    for p in profiles:
        n = len(floors(p))
        if n:
            per.setdefault(company(p), []).append((p.get("project"), n, _explicit_extra(p)))
    errs = []
    for comp, items in sorted(per.items(), key=lambda kv: str(kv[0])):
        total = sum(n for _, n, _ in items)
        if total > MAX_BUILDING_FLOORS:
            errs.append("edificio %s: %d pisos de proyecto (máximo %d): %s" % (
                comp, total, MAX_BUILDING_FLOORS, ", ".join("%s=%d" % x[:2] for x in items)))
            continue
        errs += ["edificio %s: %s pide capacity.max_extra_floors=%d pero solo caben %d pisos temporales (%d de %d ocupados)" % (
            comp, proj, extra, MAX_BUILDING_FLOORS - total, total, MAX_BUILDING_FLOORS)
                 for proj, _, extra in items if extra is not None and total + extra > MAX_BUILDING_FLOORS]
    return errs


def building_floors(profiles, prof):
    comp = company(prof)
    return len(floors(prof)) + sum(len(floors(p)) for p in profiles
                                   if company(p) == comp and p.get("project") != prof.get("project"))


# ---------------------------------------------------------------- lectura (perfil ya validado)

def _office(prof):
    o = prof.get("office")
    return o if _mapping(o) else {}


def company(prof):
    """Empresa del edificio: `office.company`, o el `company` suelto del perfil, o None (la app usa su tabla de respaldo)."""
    c = _office(prof).get("company") or prof.get("company")
    return c if isinstance(c, str) and c.strip() else None


def half_life_s(prof):
    return parse_duration(_office(prof).get("half_life")) or float(DEFAULT_HALF_LIFE)


def _capacity(prof):
    c = prof.get("capacity")
    return c if _mapping(c) else {}


def _explicit_extra(prof):
    v = _capacity(prof).get("max_extra_floors")
    return v if _int(v) and 0 <= v <= MAX_EXTRA_FLOORS else None


def capacity(prof, building=None):
    c = _capacity(prof)
    flex, extra, out = c.get("flex_per_floor"), c.get("max_extra_floors"), c.get("outsourcing")
    flex = flex if _int(flex) and 0 <= flex <= MAX_FLEX_PER_FLOOR else DEFAULT_FLEX_PER_FLOOR
    extra = extra if _int(extra) and 0 <= extra <= MAX_EXTRA_FLOORS else DEFAULT_EXTRA_FLOORS
    room = MAX_BUILDING_FLOORS - (len(floors(prof)) if building is None else building)
    return {"flex_per_floor": flex, "max_extra_floors": max(0, min(extra, room)),
            "outsourcing": out if isinstance(out, bool) else True}


def _room_desks(f):
    rs = f.get("rooms") if isinstance(f.get("rooms"), list) else []
    return sum(r.get("desks", 1) for r in rs if _mapping(r) and isinstance(r.get("role"), str) and _int(r.get("desks", 1))
               and r.get("desks", 1) > 0)


def flex_count(prof, f):
    return max(0, min(capacity(prof)["flex_per_floor"], MAX_DESKS_PER_FLOOR - _room_desks(f)))


def elastic_floor_desks(prof):
    sizes = [_room_desks(f) + flex_count(prof, f) for f in floors(prof)]
    return min(MAX_DESKS_PER_FLOOR, max([MIN_ELASTIC_FLOOR_DESKS] + sizes))


def is_elastic(role):
    return role in (FLEX_ROLE, OUT_ROLE)


def is_temporary(floor, role, declared):
    return role == OUT_ROLE or (role == FLEX_ROLE and floor >= declared)


def zone(floor, role, declared):
    if role == OUT_ROLE:
        return "outsourced"
    if role == FLEX_ROLE:
        return "extra" if floor >= declared else "flex"
    return "room"


def floors(prof):
    f = _office(prof).get("floors")
    return [x for x in f if _mapping(x)] if isinstance(f, list) else []


def desk_id(project, floor, role, slot):
    return "%s/%d/%s/%d" % (project, floor, role, slot)


def parse_desk_id(did):
    """`<proyecto>/<piso>/<rol>/<n>` -> (proyecto, piso, rol, n) o None."""
    parts = str(did or "").split("/")
    if len(parts) != 4 or not parts[1].isdigit() or not parts[3].isdigit() or not parts[0] or not parts[2]:
        return None
    return parts[0], int(parts[1]), parts[2], int(parts[3])


def desks(prof):
    """Escritorios declarados, en orden de asignación (piso más bajo, orden de departamentos, n creciente)."""
    project, out = prof.get("project"), []
    for fi, f in enumerate(floors(prof)):
        for r in f.get("rooms") or []:
            if not _mapping(r) or not isinstance(r.get("role"), str):
                continue
            n = r.get("desks", 1)
            for slot in range(n if _int(n) and n > 0 else 0):
                out.append({"id": desk_id(project, fi, r["role"], slot), "project": project, "floor": fi,
                            "role": r["role"], "slot": slot, "permanent": bool(r.get("permanent")), "zone": "room"})
        for slot in range(flex_count(prof, f)):
            out.append({"id": desk_id(project, fi, FLEX_ROLE, slot), "project": project, "floor": fi,
                        "role": FLEX_ROLE, "slot": slot, "permanent": False, "zone": "flex"})
    return out


def _elastic_room(project, fi, role, n):
    return {"role": role, "permanent": False, "flex": True,
            "desks": [{"id": desk_id(project, fi, role, s), "slot": s, "retired": False} for s in range(n)]}


def structure(prof, retired=(), extra_floors=0, outsourced_floors=0, building=None):
    """`office` del sobre `office.changed` / `GET /state` sin ocupantes. `retired` = ids de escritorios que ya no declara el
    perfil (se conservan, `retired: true`, en su piso/departamento si aún existe; si no, en un departamento al final del piso)."""
    project, declared = prof.get("project"), len(floors(prof))
    retired = sorted((d for d in set(retired) if not is_temporary(*(parse_desk_id(d) or ("", 0, "", 0))[1:3], declared)),
                     key=lambda d: (parse_desk_id(d) or ("", 0, "", 0))[1:])
    fl = []
    for fi, f in enumerate(floors(prof)):
        rooms = []
        for r in f.get("rooms") or []:
            if not _mapping(r) or not isinstance(r.get("role"), str):
                continue
            n = r.get("desks", 1) if _int(r.get("desks", 1)) else 0
            rooms.append({"role": r["role"], "permanent": bool(r.get("permanent")), "flex": False,
                          "desks": [{"id": desk_id(project, fi, r["role"], s), "slot": s, "retired": False}
                                    for s in range(n)]})
        nf = flex_count(prof, f)
        if nf:
            rooms.append(_elastic_room(project, fi, FLEX_ROLE, nf))
        fl.append({"index": fi, "name": f.get("name") if isinstance(f.get("name"), str) else None, "rooms": rooms,
                   "temporary": False})
    for did in retired:
        p = parse_desk_id(did)
        if not p:
            continue
        _, fi, role, slot = p
        while len(fl) <= fi:
            fl.append({"index": len(fl), "name": None, "rooms": [], "temporary": False})
        room = next((r for r in fl[fi]["rooms"] if r["role"] == role), None)
        if room is None:
            room = {"role": role, "permanent": False, "flex": is_elastic(role), "desks": []}
            fl[fi]["rooms"].append(room)
        if not any(d["id"] == did for d in room["desks"]):
            room["desks"].append({"id": did, "slot": slot, "retired": True})
            room["desks"].sort(key=lambda d: d["slot"])
    n = elastic_floor_desks(prof)
    for k in range(extra_floors):
        fi = declared + k
        floor = next((x for x in fl if x["index"] == fi), None)
        if floor is None:
            floor = {"index": fi, "name": None, "rooms": [], "temporary": True}
            fl.append(floor)
        floor["temporary"] = True
        floor["rooms"].append(_elastic_room(project, fi, FLEX_ROLE, n))
    fl.sort(key=lambda x: x["index"])
    out = {"label": OUTSOURCED_LABEL,
           "floors": [{"index": k, "name": None, "temporary": False, "rooms": [_elastic_room(project, k, OUT_ROLE, n)]}
                      for k in range(outsourced_floors)]} if outsourced_floors else None
    return {"company": company(prof), "half_life_s": half_life_s(prof), "floors": fl, "machine_rooms": machine_rooms(prof),
            "capacity": capacity(prof, building), "outsourced": out}


def machine_rooms(prof):
    """[{name, floor, repos, listeners, automations, subscriptions}] del perfil (solo las válidas; vacío si no declara)."""
    m, n, out = prof.get("machine_rooms"), len(floors(prof)), []
    for r in m if isinstance(m, list) else []:
        f = r.get("floor", 0) if _mapping(r) else None
        if not _mapping(r) or not isinstance(r.get("name"), str) or not r["name"].strip() or not _int(f) or not 0 <= f < n:
            continue
        if any(x["name"] == r["name"] for x in out):
            continue
        out.append(dict({"name": r["name"], "floor": f},
                        **{k: [x for x in r.get(k) or [] if isinstance(x, str) and x] if isinstance(r.get(k), list) else []
                           for k in MACHINE_ROOM_LISTS}))
    return out


def roles(prof):
    r = _office(prof).get("roles")
    return r if _mapping(r) else {}


def _normalize_wake(wake):
    return [{"type": t} if isinstance(t, str) else t for t in wake]


def wake_triggers(prof, role):
    """Disparadores de `wake` del rol, normalizados como los de `automations` (`schedule` con `_every`/`_cron`)."""
    spec = roles(prof).get(role)
    wake = spec.get("wake") if _mapping(spec) else None
    out = []
    for t in _normalize_wake(wake if isinstance(wake, list) else []):
        if not _mapping(t):
            continue
        t = dict(t)
        if t.get("type") == "schedule":
            t["_every"] = automations.parse_every(t["every"]) if "every" in t else None
            t["_cron"] = automations.parse_cron(t["cron"]) if "cron" in t else None
        out.append(t)
    return out


def match_rules(prof):
    """[(rol, {title|branch|label: regex compilada})] en el orden del perfil."""
    out = []
    for name, spec in roles(prof).items():
        m = spec.get("match") if _mapping(spec) else None
        if _mapping(m) and m:
            try:
                out.append((name, {k: re.compile(str(v)) for k, v in m.items() if k in MATCH_KEYS}))
            except re.error:
                continue
    return out


def role_for(prof, title=None, branch=None, labels=()):
    """Rol por reglas `match` (cualquier campo que coincida). None si ninguna."""
    for name, rules in match_rules(prof):
        for k, rx in rules.items():
            vals = list(labels or ()) if k == "label" else [title if k == "title" else branch]
            if any(isinstance(v, str) and rx.search(v) for v in vals):
                return name
    return None


def rack_repos(prof):
    """[{provider, repo, project, kind, label}] del perfil (solo las entradas válidas)."""
    r = prof.get("rack")
    out = []
    for e in (r.get("repos") if _mapping(r) and isinstance(r.get("repos"), list) else []):
        if _mapping(e) and isinstance(e.get("repo"), str) and _REPO.match(e["repo"]):
            out.append({"provider": e.get("provider", "github"), "repo": e["repo"], "project": prof.get("project"),
                        "kind": e.get("kind", "main"), "label": e.get("label") or e["repo"].split("/")[-1]})
    return out


def rack_actors(prof):
    """{login: {kind, label}} del perfil."""
    r = prof.get("rack")
    a = r.get("actors") if _mapping(r) else None
    return {str(k): {"kind": v.get("kind", "bot"), "label": v.get("label") or str(k)}
            for k, v in (a.items() if _mapping(a) else ()) if _mapping(v)}
