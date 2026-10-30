import hashlib
import os
import re

DEFAULT_POOL = (
    "Ada", "Alan", "Alba", "Bruno", "Carla", "Dario", "Elena", "Emilio", "Fabio", "Gala",
    "Hugo", "Ines", "Iris", "Jana", "Julio", "Kai", "Lara", "Leo", "Luna", "Marco",
    "Mia", "Nadia", "Nico", "Olga", "Omar", "Paula", "Pablo", "Quim", "Rita", "Raul",
    "Sara", "Simon", "Tea", "Tomas", "Ugo", "Vera", "Vito", "Wanda", "Xenia", "Yago",
    "Zoe", "Zeno",
)
MODES = ("extend", "replace")
KEYS = ("mode", "names")
NAME_RE = re.compile(r"[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ' -]{0,31}")


class NamesError(ValueError):
    pass


def profile_path(home_dir, project):
    if not re.fullmatch(r"[A-Za-z0-9._-]+", project or ""):
        raise NamesError("nombre de proyecto inválido: %r" % project)
    return os.path.join(home_dir, "names", project + ".yaml")


def validate(data):
    if not isinstance(data, dict):
        return ["se esperaba un mapa con names: [...] (y mode: extend|replace opcional)"]
    errs = ["campo desconocido: %s (%s)" % (k, ", ".join(KEYS)) for k in data if k not in KEYS]
    mode = data.get("mode", "extend")
    if mode not in MODES:
        errs.append("mode inválido: %r (extend o replace)" % (mode,))
    ns = data.get("names")
    if not isinstance(ns, list) or not ns:
        errs.append("names debe ser una lista no vacía de nombres")
        return errs
    seen = set()
    for i, n in enumerate(ns):
        if not isinstance(n, str) or not NAME_RE.fullmatch(n.strip()) or n != n.strip():
            errs.append("names[%d] inválido: %r (letras, espacios, ' o -, máx. 32)" % (i, n))
            continue
        if n.casefold() in seen:
            errs.append("names[%d] repetido: %s" % (i, n))
        seen.add(n.casefold())
    return errs


def pool(data=None):
    if data is None:
        return list(DEFAULT_POOL)
    errs = validate(data)
    if errs:
        raise NamesError("; ".join(errs))
    base = [] if data.get("mode", "extend") == "replace" else list(DEFAULT_POOL)
    out, seen = [], set()
    for n in base + data["names"]:
        if n.casefold() not in seen:
            seen.add(n.casefold())
            out.append(n)
    return out


def _slot(project, role, size):
    h = hashlib.sha256(("%s\0%s" % (project, role)).encode("utf-8")).digest()
    return int.from_bytes(h[:8], "big") % size


def resolve(project, roles, names=None):
    names = list(DEFAULT_POOL) if names is None else list(names)
    roles = sorted(set(roles))
    if len(roles) > len(names):
        raise NamesError("hay %d roles y solo %d nombres en el pool de %s" % (len(roles), len(names), project))
    taken, out = set(), {}
    for role in roles:
        i = _slot(project, role, len(names))
        while i in taken:
            i = (i + 1) % len(names)
        taken.add(i)
        out[role] = names[i]
    return out


def project_pool(home_dir, project, load):
    p = profile_path(home_dir, project)
    return pool(load(p)) if os.path.exists(p) else pool()
