"""Paso 1: cargador de perfiles locales ~/.chopshop/profiles/<proyecto>.yaml (nunca en el repo)."""
import os
import re

from . import home, miniyaml, settings

KNOWN = {"project", "company", "repo", "host", "overflow_host", "remote_repos", "t3_project", "scratch",
         "provider", "model", "runtime_mode", "workspace", "base_ref", "tracker", "ready", "branches",
         "decider", "approvers", "can_run", "cannot_run", "autonomy", "reactions", "max_parallel", "graph", "integration",
         "automations", "office", "rack", "machine_rooms", "capacity"}


class ProfileError(Exception):
    pass


def _safe(name):
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name or ""):
        raise ProfileError("nombre de proyecto inválido: %r" % name)
    return name


def profile_path(project):
    return os.path.join(home.profiles_dir(), _safe(project) + ".yaml")


def hosts():
    """Hosts de T3: sección [hosts.*] de ~/.config/chopshop/config.toml (más el legado ~/.chopshop/config.yaml)."""
    h = {k: dict(v) for k, v in settings.load()["hosts"].items()}
    p = home.config_path()
    if os.path.exists(p):
        for k, v in ((miniyaml.load(p) or {}).get("hosts") or {}).items():
            h.setdefault(k, {}).update(v or {})
    return h


def load(project):
    p = profile_path(project)
    if not os.path.exists(p):
        raise ProfileError("no existe el perfil %s (créalo en %s)" % (project, p))
    try:
        d = miniyaml.load(p) or {}
    except miniyaml.YamlError as e:
        raise ProfileError("%s: %s" % (p, e))
    if not isinstance(d, dict):
        raise ProfileError("%s: se esperaba un mapa" % p)
    d.setdefault("project", project)
    if d["project"] != project:
        raise ProfileError("%s: project=%r no coincide con el nombre del archivo" % (p, d["project"]))
    d.setdefault("host", settings.general("default_host") or "local")
    d.setdefault("runtime_mode", "approval-required")
    d.setdefault("provider", "any")
    d["_path"] = p
    d["_unknown"] = sorted(set(d) - KNOWN - {"_path", "_unknown"})
    return d


def list_projects():
    d = home.profiles_dir()
    return sorted(f[:-5] for f in os.listdir(d) if f.endswith(".yaml")) if os.path.isdir(d) else []


def _all():
    profs = []
    for name in list_projects():
        try:
            profs.append(load(name))
        except ProfileError:
            continue
    return profs


def building_floors(project):
    from .agent import layout
    profs = _all()
    mine = next((p for p in profs if p["project"] == project), None)
    return layout.building_floors(profs, mine) if mine else None


def validate_building(project):
    """Tope de pisos por edificio entre todos los perfiles locales que comparten empresa con `project`."""
    from .agent import layout
    profs = _all()
    mine = next((p for p in profs if p["project"] == project), None)
    if mine is None:
        return []
    comp = layout.company(mine)
    return layout.validate_building([p for p in profs if layout.company(p) == comp])


def validate(d):
    """Devuelve lista de problemas (vacía si el perfil es usable)."""
    errs = []
    hs = hosts()
    if d["host"] not in hs:
        errs.append("host desconocido: %s" % d["host"])
    ov = d.get("overflow_host")
    if ov and ov not in hs:
        errs.append("overflow_host desconocido: %s" % ov)
    if d.get("runtime_mode") not in ("approval-required", "auto-accept-edits", "auto", "full-access"):
        errs.append("runtime_mode inválido: %s" % d.get("runtime_mode"))
    if not d.get("scratch") and not (d.get("t3_project") or d.get("repo") or d.get("project")):
        errs.append("falta repo o t3_project")
    from . import reactions
    errs += reactions.validate(d)
    from . import graph
    errs += graph.validate(d)
    errs += validate_integration(d)
    from .agent import automations
    errs += automations.validate(d)
    from .agent import layout
    errs += layout.validate(d)
    m = d.get("model")
    if m and "/" not in str(m):
        errs.append("model debe ser 'instancia/modelo' (p. ej. claudeAgent/claude-haiku-5-5)")
    return errs


INTEGRATION_KEYS = ("test_cmd", "test_cwd", "timeout")


def validate_integration(d):
    """Bloque opcional `integration:` (lo usa `chopshop integrate`)."""
    g = d.get("integration")
    if g is None:
        return []
    if not isinstance(g, dict):
        return ["integration: se esperaba un mapa"]
    errs = ["integration.%s desconocido (%s)" % (k, ", ".join(INTEGRATION_KEYS)) for k in g if k not in INTEGRATION_KEYS]
    tc = g.get("test_cmd")
    if tc is not None and not (isinstance(tc, list) and tc and all(isinstance(x, str) and x for x in tc)):
        errs.append("integration.test_cmd debe ser una lista argv no vacía (p. ej. [python3, -m, unittest])")
    if "test_cwd" in g and not isinstance(g["test_cwd"], str):
        errs.append("integration.test_cwd debe ser una ruta relativa al worktree")
    if "timeout" in g and (not isinstance(g["timeout"], (int, float)) or isinstance(g["timeout"], bool) or g["timeout"] <= 0):
        errs.append("integration.timeout debe ser un número de segundos > 0")
    return errs
