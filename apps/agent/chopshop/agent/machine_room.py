import fnmatch
import re

from . import db, envelope, webhooks

RACK_DONE = 5
_URL = re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://\S+")


def empty():
    return {"listeners": [], "automations": [], "subscriptions": [], "rack": []}


def _room(state):
    mr = state.get("machine_room")
    if not isinstance(mr, dict):
        mr = state["machine_room"] = empty()
    for k, v in empty().items():
        mr.setdefault(k, v)
    return mr


def _clean(body):
    return {k: v for k, v in (body or {}).items() if k not in ("legacy", "context")}


def apply(state, env):
    typ, body, ts = env.get("type") or "", env.get("body") or {}, env.get("ts")
    if typ == "listener.state" and body.get("name"):
        mr = _room(state)
        mr["listeners"] = [l for l in mr["listeners"] if l.get("name") != body["name"]] + [dict(_clean(body), ts=ts)]
        mr["listeners"].sort(key=lambda l: l.get("name") or "")
        return True
    if typ == "automation.ran" and body.get("automation"):
        mr = _room(state)
        proj = env.get("project")
        item = {"project": proj, "name": body["automation"], "trigger": body.get("trigger"), "exit": body.get("exit"),
                "duration_ms": body.get("duration_ms"), "error": body.get("error"), "next_run": body.get("next_run"),
                "severity": env.get("severity"), "ts": ts}
        mr["automations"] = [a for a in mr["automations"] if (a.get("project"), a.get("name")) != (proj, item["name"])]
        mr["automations"].append(item)
        mr["automations"].sort(key=lambda a: (a.get("project") or "", a.get("name") or ""))
        return True
    if typ == "forge.repo.state" and body.get("provider") and body.get("repo"):
        unit = _unit(_room(state), body["provider"], body["repo"], env)
        runs = unit.get("runs") or []
        unit.update(_clean(body), ts=ts, runs=runs)
        if not unit.get("project"):
            unit["project"] = env.get("project")
        _sort(_room(state))
        return True
    if typ == "forge.run.state" and body.get("provider") and body.get("repo") and body.get("run_id") not in (None, ""):
        unit = _unit(_room(state), body["provider"], body["repo"], env)
        run = {k: v for k, v in _clean(body).items() if k not in ("provider", "repo", "project")}
        runs = [r for r in unit.get("runs") or [] if str(r.get("run_id")) != str(body["run_id"])]
        old = next((i for i, r in enumerate(unit.get("runs") or []) if str(r.get("run_id")) == str(body["run_id"])), None)
        runs.insert(old, run) if old is not None else runs.append(run)
        unit["runs"] = _trim(runs)
        _sort(_room(state))
        return True
    return False


def _unit(mr, provider, repo, env):
    for u in mr["rack"]:
        if u.get("provider") == provider and u.get("repo") == repo:
            return u
    u = {"provider": provider, "repo": repo, "project": (env.get("body") or {}).get("project") or env.get("project"),
         "kind": None, "label": None, "light": "gray", "default_branch": None, "ci": None, "url": None,
         "ts": env.get("ts"), "runs": []}
    mr["rack"].append(u)
    return u


def _trim(runs):
    done = [(i, r) for i, r in enumerate(runs) if r.get("status") == "completed"]
    if len(done) <= RACK_DONE:
        return runs
    keep = {i for i, _ in sorted(done, key=lambda x: (x[1].get("updated_at") or "", x[0]), reverse=True)[:RACK_DONE]}
    return [r for i, r in enumerate(runs) if r.get("status") != "completed" or i in keep]


def _sort(mr):
    mr["rack"].sort(key=lambda u: (u.get("project") or "", 0 if u.get("kind") == "main" else 1, u.get("repo") or ""))


def filter_project(mr, project):
    if not isinstance(mr, dict):
        return mr
    return dict(mr, automations=[a for a in mr.get("automations") or [] if a.get("project") == project],
                rack=[u for u in mr.get("rack") or [] if u.get("project") == project])


def _picks(name, pats):
    return any(fnmatch.fnmatchcase(name or "", p) for p in pats or [])


def scope(mr, project, cfg):
    mr, cfg = mr if isinstance(mr, dict) else empty(), cfg or {}
    return {"name": cfg.get("name"), "floor": cfg.get("floor", 0),
            "listeners": [l for l in mr.get("listeners") or [] if _picks(l.get("name"), cfg.get("listeners"))],
            "automations": [a for a in mr.get("automations") or []
                            if a.get("project") == project and _picks(a.get("name"), cfg.get("automations"))],
            "subscriptions": [s for s in mr.get("subscriptions") or [] if _picks(s.get("name"), cfg.get("subscriptions"))],
            "rack": [u for u in mr.get("rack") or [] if u.get("project") == project and _picks(u.get("repo"), cfg.get("repos"))]}


def rooms(state):
    mr = state.get("machine_room")
    for p in state.get("projects") or []:
        cfgs = (p.get("office") or {}).get("machine_rooms") or []
        p["machine_rooms"] = [scope(mr, p.get("name"), c) for c in cfgs]
        p["machine_room"] = p["machine_rooms"][0] if p["machine_rooms"] else None
    return state


def subscriptions(conn):
    with db.tx():
        subs = db.rows(conn.execute("SELECT * FROM subscriptions ORDER BY name"))
        out = []
        for s in subs:
            ok = conn.execute("SELECT MAX(ts) FROM deliveries WHERE name=? AND ok=1", (s["name"],)).fetchone()[0]
            bad = conn.execute("SELECT ts, detail FROM deliveries WHERE name=? AND ok=0 ORDER BY ts DESC LIMIT 1",
                               (s["name"],)).fetchone()
            err = None
            if bad is not None and (ok is None or bad["ts"] > ok):
                err = _URL.sub("[url]", str(bad["detail"] or "fallo"))[:160]
            out.append({"name": s["name"], "projects": webhooks.effective(s)["projects"], "last_ok": envelope.iso(ok) if ok else None, "last_error": err,
                        "last_error_at": envelope.iso(bad["ts"]) if err else None, "signed": bool(s.get("secret_file"))})
    return out


def live(state, conn):
    try:
        _room(state)["subscriptions"] = subscriptions(conn)
    except Exception:
        _room(state)["subscriptions"] = []
    return rooms(state)
