import json
import os
import threading

from .. import home, minitoml, profile, settings

DEFAULT_COMPANY = "Personal"
FIELDS = ("company", "t3_project", "repo", "host", "enabled")

_lock = threading.Lock()


class RegistryError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def path():
    p = (settings.load().get("agent") or {}).get("projects_file")
    if p:
        return os.path.expanduser(p)
    return os.path.join(os.path.dirname(settings.path()), "projects.toml")


def exists():
    return os.path.exists(path())


def _entry(name, raw):
    raw = raw if isinstance(raw, dict) else {}
    return {"name": name, "company": str(raw.get("company") or DEFAULT_COMPANY),
            "t3_project": str(raw.get("t3_project") or name), "repo": raw.get("repo") or None,
            "host": str(raw.get("host") or settings.general("default_host") or "local"),
            "enabled": raw.get("enabled", True) is not False}


def _from_profiles():
    from . import layout
    out = {}
    for name in profile.list_projects():
        try:
            prof = profile.load(name)
        except profile.ProfileError:
            continue
        out[name] = _entry(name, {"company": layout.company(prof), "t3_project": prof.get("t3_project"),
                                  "repo": prof.get("repo"), "host": prof.get("host")})
    return out


def _read():
    try:
        data = minitoml.load(path())
    except (minitoml.TomlError, OSError) as e:
        raise RegistryError(500, "registro de proyectos ilegible (%s): %s" % (path(), e))
    projs = data.get("projects") if isinstance(data.get("projects"), dict) else {}
    return {n: _entry(n, v) for n, v in projs.items()}


_cache = {}


def load():
    try:
        st = os.stat(path())
    except OSError:
        return _from_profiles()
    key = (path(), st.st_mtime_ns, st.st_size)
    if _cache.get("key") != key:
        _cache["key"], _cache["entries"] = key, _read()
    return {n: dict(e) for n, e in _cache["entries"].items()}


def _dump(entries):
    lines = []
    for name in sorted(entries):
        e = entries[name]
        lines.append("[projects.%s]" % json.dumps(name))
        for k in FIELDS:
            v = e.get(k)
            if v is None:
                continue
            lines.append("%s = %s" % (k, ("true" if v else "false") if isinstance(v, bool) else json.dumps(str(v), ensure_ascii=False)))
        lines.append("")
    return "\n".join(lines)


def _write(entries):
    p = path()
    os.makedirs(os.path.dirname(p) or ".", mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (p, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(_dump(entries))
    os.replace(tmp, p)


def migrate():
    with _lock:
        if exists():
            return False
        _write(_from_profiles())
        return True


def enabled_names():
    return {n for n, e in load().items() if e["enabled"]}


def counts(name):
    return not exists() or name in enabled_names()


def profiles(names=None):
    names = names if names is not None else profile.list_projects()
    if not exists():
        return list(names)
    allowed = enabled_names()
    return [n for n in names if n in allowed]


def visible(st):
    if not exists():
        return st
    allowed = enabled_names()
    out = dict(st)
    out["projects"] = [p for p in st.get("projects") or [] if p.get("name") in allowed]
    out["lobby"] = [x for x in st.get("lobby") or [] if x.get("project") in allowed]
    out["recent"] = [e for e in st.get("recent") or [] if e.get("project") is None or e.get("project") in allowed]
    return out


def t3_matcher():
    if not exists():
        return None
    entries = [e for e in load().values() if e["enabled"]]

    def match(pr):
        root = (pr.get("workspaceRoot") or "").rstrip("/")
        keys = {pr.get("id"), pr.get("title"), os.path.basename(root) if root else None} - {None, ""}
        hit = next((e for e in entries if e["t3_project"] in keys), None) or next((e for e in entries if e["name"] in keys), None)
        return hit["name"] if hit else None
    return match


def public(e, roles=None):
    return {"name": e["name"], "company": e["company"], "t3_project": e["t3_project"], "host": e["host"],
            "enabled": e["enabled"], "roles": roles if roles is not None else _roles(e["name"])}


def _roles(name):
    from . import layout
    try:
        prof = profile.load(name)
    except profile.ProfileError:
        return []
    out = []
    for d in layout.desks(prof):
        if d["zone"] == "room" and d["role"] not in out:
            out.append(d["role"])
    return out


def _name(name):
    try:
        return profile._safe(name)
    except profile.ProfileError as e:
        raise RegistryError(400, str(e))


def _text(v, key, required=False):
    if v is None or v == "":
        if required:
            raise RegistryError(400, "%s es obligatorio" % key)
        return None
    if not isinstance(v, str) or len(v) > 200 or any(ord(c) < 32 for c in v):
        raise RegistryError(400, "%s debe ser texto (máx. 200 caracteres, sin controles)" % key)
    return v.strip()


def minimal_profile(name, company, t3_project=None, repo=None, host=None):
    p = profile.profile_path(name)
    if os.path.exists(p):
        return False
    lines = ["project: %s" % name]
    for k, v in (("t3_project", t3_project), ("repo", repo), ("host", host)):
        if v:
            lines.append("%s: %s" % (k, json.dumps(v, ensure_ascii=False)))
    lines += ["office:", "  company: %s" % json.dumps(company, ensure_ascii=False), "  floors:", "    - name: Principal",
              "      rooms:", "        - role: general", "          desks: 2", ""]
    home.ensure_home()
    os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return True


def register(name, company=None, t3_project=None, repo=None, host=None):
    name = _name(name)
    company = _text(company, "company")
    t3_project, repo, host = _text(t3_project, "t3_project"), _text(repo, "repo"), _text(host, "host")
    if host and host not in profile.hosts():
        raise RegistryError(400, "host desconocido: %s" % host)
    with _lock:
        entries = load()
        old = entries.get(name)
        if old is None and not company:
            raise RegistryError(400, "company es obligatorio")
        raw = dict(old or {}, enabled=True)
        for k, v in (("company", company), ("t3_project", t3_project), ("repo", repo), ("host", host)):
            if v:
                raw[k] = v
        entries[name] = _entry(name, raw)
        _write(entries)
    e = entries[name]
    made = minimal_profile(name, e["company"], t3_project, repo, host)
    return e, old is None, made


def set_enabled(name, flag):
    name = _name(name)
    with _lock:
        entries = load()
        if name not in entries:
            raise RegistryError(404, "proyecto no registrado: %s" % name)
        entries[name] = dict(entries[name], enabled=bool(flag))
        _write(entries)
    return entries[name]


def listing():
    return [public(e) for _n, e in sorted(load().items())]


def api_list():
    return {"projects": listing()}


def api_register(body):
    e, created, made = register(body.get("name"), body.get("company"), body.get("t3_project"), body.get("repo"), body.get("host"))
    return {"ok": True, "project": public(e), "created": created, "profile_created": made}


def api_disable(name):
    return {"ok": True, "project": public(set_enabled(name, False))}
