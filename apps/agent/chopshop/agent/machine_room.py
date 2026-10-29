"""`machine_room` de `GET /state` v3 (docs/agent-api.md, «api_version 3»): listeners, automatizaciones, webhooks y rack.

`apply(state, env)` pliega en sitio los sobres que le tocan (`projection._apply` lo llama con cada sobre; misma regla que
`LiveState.swift`):
- `listener.state` -> upsert en `listeners` por `name` (cuerpo + `ts`), por nombre.
- `automation.ran` -> upsert en `automations` por `(project, automation)`.
- `forge.repo.state` -> upsert del módulo por `(provider, repo)` conservando `runs`; `forge.run.state` -> upsert del run por
  `run_id` (crea el módulo en gris si no existe); se guardan los no completados y los `KEEP_DONE` completados más nuevos.
  `rack` se ordena por `(project, kind == main ? 0 : 1, repo)`.
`subscriptions` no sale de sobres: `live(state, conn)` la rellena desde SQLite (nunca la URL)."""
import re

from . import db, envelope

KEEP_DONE = 5
_RUN_SKIP = ("provider", "repo", "project")
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


def _module(rack, provider, repo):
    key = (provider, (repo or "").lower())
    return next((m for m in rack if (m.get("provider"), (m.get("repo") or "").lower()) == key), None)


def _rack_key(m):
    return (m.get("project") or "", 0 if m.get("kind") == "main" else 1, (m.get("repo") or "").lower())


def _trim(runs):
    done = [r for r in runs if r.get("status") == "completed"]
    # más nuevo primero por updated_at; a igualdad (o sin fecha) gana el que llegó después
    ranked = sorted(enumerate(done), key=lambda ir: (ir[1].get("updated_at") or "", ir[0]), reverse=True)
    keep = {id(r) for _, r in ranked[:KEEP_DONE]}
    return [r for r in runs if r.get("status") != "completed" or id(r) in keep]


def apply(state, env):
    """Aplica en sitio. Devuelve True si el sobre era de la sala de máquinas."""
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
        mr = _room(state)
        old = _module(mr["rack"], body["provider"], body["repo"])
        new = dict(_clean(body), ts=ts, runs=(old or {}).get("runs") or [])
        mr["rack"] = [m for m in mr["rack"] if m is not old] + [new]
        mr["rack"].sort(key=_rack_key)
        return True
    if typ == "forge.run.state" and body.get("provider") and body.get("repo") and body.get("run_id") is not None:
        mr = _room(state)
        m = _module(mr["rack"], body["provider"], body["repo"])
        if m is None:
            m = {"provider": body["provider"], "repo": body["repo"], "project": body.get("project") or env.get("project"),
                 "kind": None, "label": body["repo"].split("/")[-1], "light": "gray", "default_branch": None, "ci": None,
                 "url": None, "error": None, "ts": ts, "runs": []}
            mr["rack"].append(m)
            mr["rack"].sort(key=_rack_key)
        run = {k: v for k, v in _clean(body).items() if k not in _RUN_SKIP}
        run["run_id"] = str(run["run_id"])
        runs = [r for r in m.get("runs") or [] if r.get("run_id") != run["run_id"]] + [run]
        m["runs"] = sorted(_trim(runs), key=lambda r: r.get("updated_at") or "", reverse=True)
        return True
    return False


def filter_project(mr, project):
    """Sala de máquinas vista desde un proyecto: rack y automatizaciones de ese proyecto; listeners y webhooks enteros."""
    if not isinstance(mr, dict):
        return mr
    return dict(mr, rack=[m for m in mr.get("rack") or [] if m.get("project") == project],
                automations=[a for a in mr.get("automations") or [] if a.get("project") == project])


def subscriptions(conn):
    """[{name, last_ok, last_error, signed}] desde `subscriptions` + la última entrega de cada una. Nunca la URL."""
    with db.tx():
        subs = db.rows(conn.execute("SELECT name, secret_file FROM subscriptions ORDER BY name"))
        out = []
        for s in subs:
            ok = conn.execute("SELECT MAX(ts) FROM deliveries WHERE name=? AND ok=1", (s["name"],)).fetchone()[0]
            bad = conn.execute("SELECT ts, detail FROM deliveries WHERE name=? AND ok=0 ORDER BY ts DESC LIMIT 1",
                               (s["name"],)).fetchone()
            err = None
            if bad is not None and (ok is None or bad["ts"] > ok):
                err = _URL.sub("[url]", str(bad["detail"] or "fallo"))[:160]
            out.append({"name": s["name"], "last_ok": envelope.iso(ok) if ok else None, "last_error": err,
                        "last_error_at": envelope.iso(bad["ts"]) if err else None, "signed": bool(s.get("secret_file"))})
    return out


def live(state, conn):
    """Rellena `machine_room.subscriptions` (lo único que no viene de sobres). En sitio; devuelve `state`."""
    try:
        _room(state)["subscriptions"] = subscriptions(conn)
    except Exception:  # noqa: BLE001 - una DB vieja sin columnas v4 no rompe /state
        _room(state)["subscriptions"] = []
    return state
