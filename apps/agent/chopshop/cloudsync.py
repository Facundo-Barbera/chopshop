import json
import logging
import os
import re
import shutil

from . import home

log = logging.getLogger("chopshop.cloudsync")

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
LAYOUT_OFFICE = ("floors", "half_life")
LAYOUT_TOP = ("capacity", "machine_rooms")
OVERRIDE_KEYS = ("worktree_root", "t3_project")
OVERRIDE_INTEGRATION = ("test_cwd",)
SUMMARY = ("id", "name", "workspace_id", "title", "t3_project", "repo", "disabled", "rev")
MESSAGE_MAX = 512

_cache = {}


def root():
    return os.path.join(home.home(), "cloud")


def state_path():
    return os.path.join(root(), "state.json")


def profiles_dir():
    return os.path.join(root(), "profiles")


def prompts_dir(name=None):
    base = os.path.join(root(), "prompts")
    return os.path.join(base, name) if name else base


def profile_path(name):
    return os.path.join(profiles_dir(), name + ".json")


def _write(path, text):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def _dump(d):
    return json.dumps(d, ensure_ascii=False, indent=2) + "\n"


def read_state():
    p = state_path()
    try:
        st = os.stat(p)
    except OSError:
        return None
    key = (p, st.st_mtime_ns, st.st_size, st.st_ino)
    if _cache.get("key") != key:
        try:
            with open(p, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            log.warning("cloud/state.json ilegible: %s", e)
            data = None
        _cache["key"], _cache["state"] = key, data if isinstance(data, dict) else None
    return _cache["state"]


def active():
    return read_state() is not None


def projects():
    st = read_state() or {}
    ws = {w.get("id"): w.get("name") for w in st.get("workspaces") or [] if isinstance(w, dict)}
    out = []
    for p in st.get("projects") or []:
        if isinstance(p, dict) and isinstance(p.get("name"), str) and NAME_RE.match(p["name"]):
            out.append(dict(p, company=ws.get(p.get("workspace_id"))))
    return out


def names():
    return sorted(p["name"] for p in projects())


def is_cloud(name):
    return isinstance(name, str) and name in names()


def profile_file(name):
    return profile_path(name) if is_cloud(name) else None


def read_profile(path):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise ValueError("%s: se esperaba un objeto" % path)
    return d


def apply_override(prof, override, source="override"):
    if not isinstance(override, dict):
        return prof
    out = dict(prof)
    for k, v in override.items():
        if k in OVERRIDE_KEYS:
            out[k] = v
        elif k == "integration" and isinstance(v, dict):
            integ = dict(out.get("integration") or {})
            for ik, iv in v.items():
                if ik in OVERRIDE_INTEGRATION:
                    integ[ik] = iv
                else:
                    log.warning("%s: integration.%s no se puede sobrescribir localmente; se ignora", source, ik)
            out["integration"] = integ
        else:
            log.warning("%s: la clave %s no se puede sobrescribir localmente; se ignora", source, k)
    return out


def _obj(v):
    return v if isinstance(v, dict) else {}


def to_profile(p, company):
    layout, settings = _obj(p.get("layout")), _obj(p.get("settings"))
    prof = {k: v for k, v in settings.items() if k != "office"}
    prof["project"] = p["name"]
    for k in ("title", "t3_project", "repo", "model"):
        if p.get(k) is not None:
            prof[k] = p[k]
    prof["runtime_mode"] = p.get("runtime_mode") or "approval-required"
    office = dict(_obj(settings.get("office")))
    if company:
        office["company"] = company
    for k in LAYOUT_OFFICE:
        if k in layout:
            office[k] = layout[k]
    for k in LAYOUT_TOP:
        if k in layout:
            prof[k] = layout[k]
    roles, prompts = {}, {}
    for r in p.get("roles") or []:
        name = r.get("name") if isinstance(r, dict) else None
        if not isinstance(name, str) or not NAME_RE.match(name):
            raise ValueError("rol inválido: %r" % (name,))
        spec = dict(_obj(r.get("settings")))
        if r.get("prompt"):
            spec["prompt_file"] = name + ".md"
            prompts[name] = r["prompt"]
        if r.get("match_rules"):
            spec["match"] = r["match_rules"]
        if r.get("wake"):
            spec["wake"] = r["wake"]
        if r.get("model"):
            spec["model"] = r["model"]
        roles[name] = spec
    if roles:
        office["roles"] = roles
    if office:
        prof["office"] = office
    return prof, prompts


def _materialize(p, company):
    prof, prompts = to_profile(p, company)
    name = p["name"]
    shutil.rmtree(prompts_dir(name), ignore_errors=True)
    for role, text in prompts.items():
        _write(os.path.join(prompts_dir(name), role + ".md"), text)
    _write(profile_path(name), _dump(prof))


def _prune(keep):
    d = profiles_dir()
    for f in os.listdir(d) if os.path.isdir(d) else []:
        if f.endswith(".json") and f[:-5] not in keep:
            os.remove(os.path.join(d, f))
    d = prompts_dir()
    for f in os.listdir(d) if os.path.isdir(d) else []:
        if f not in keep:
            shutil.rmtree(os.path.join(d, f), ignore_errors=True)


def _error(name, message):
    return {"project": name, "message": (message or "error")[:MESSAGE_MAX]}


def apply(sync):
    from . import profile
    sync = sync if isinstance(sync, dict) else {}
    workspaces = [w for w in sync.get("workspaces") or [] if isinstance(w, dict)]
    ws = {w.get("id"): w.get("name") for w in workspaces}
    keep, errors, summary = [], [], []
    for p in sync.get("projects") or []:
        name = p.get("name") if isinstance(p, dict) else None
        if not isinstance(name, str) or not NAME_RE.match(name) or name in keep:
            log.warning("sync: proyecto con nombre inválido o repetido: %r", name)
            continue
        try:
            _materialize(p, ws.get(p.get("workspace_id")))
        except (OSError, TypeError, ValueError) as e:
            errors.append(_error(name, str(e)))
            continue
        keep.append(name)
        summary.append({k: p.get(k) for k in SUMMARY})
    _prune(set(keep))
    _write(state_path(), _dump({"rev": sync.get("rev"), "machine": sync.get("machine"), "workspaces": workspaces,
                                "projects": summary}))
    applied = []
    for name in keep:
        try:
            problems = profile.validate(profile.load(name))
        except profile.ProfileError as e:
            problems = [str(e)]
        if problems:
            errors.append(_error(name, "; ".join(problems)))
        else:
            applied.append(name)
    return {"rev": sync.get("rev"), "applied": applied, "errors": errors}
