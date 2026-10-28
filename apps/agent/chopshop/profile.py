"""Paso 1: cargador de perfiles locales ~/.chopshop/profiles/<proyecto>.yaml (nunca en el repo)."""
import os
import re

from . import home, miniyaml, settings

KNOWN = {"project", "company", "repo", "host", "overflow_host", "remote_repos", "t3_project", "scratch",
         "provider", "model", "runtime_mode", "workspace", "base_ref", "tracker", "ready", "branches",
         "decider", "approvers", "can_run", "cannot_run", "autonomy", "reactions", "max_parallel", "graph"}


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
    m = d.get("model")
    if m and "/" not in str(m):
        errs.append("model debe ser 'instancia/modelo' (p. ej. claudeAgent/claude-haiku-5-5)")
    return errs
