"""Forja agnóstica de proveedor: rack de repos de la sala de máquinas (docs/plans/office-redesign.md §4, fase 4).

- `ForgeProvider` (`base.py`) es lo único que conoce a cada forja; hoy `github.GitHubProvider`. El resto habla de
  `provider` + `repo` + `runs`.
- `Rack.poll_once()` recorre los repos del rack (bloque `rack.repos` de los perfiles + `[agent.github] repos` como
  `kind: main`), pide los runs y el estado del repo a su proveedor, atribuye el **origen** de cada run (`origin`) y emite
  `forge.run.state` (solo si el run cambió) y `forge.repo.state` (solo si cambió la luz o el resto del cuerpo). Lo último
  emitido vive en la tabla `forge_runs` y en `meta` (`forge_state:<proveedor>:<repo>`), así un reinicio no reemite nada.
  Solo se publican los runs activos y los `KEEP_DONE` completados más nuevos de cada respuesta (lo que pinta el rack).
- Proveedor caído o en backoff -> sus repos pasan a luz gris con `error` (una emisión) y se recuperan solos.
- `light()` y `origin()` son funciones puras (tests con tablas).

Origen de un run, por prioridad: `thread` (la rama del run es la de un hilo de T3 y no es la rama por defecto),
`automation` (un `forge.dispatch` de una automatización: el nonce aparece en el título del run, o mismo repo + workflow + ref
dentro de `DISPATCH_WINDOW` s), `bot` (actor declarado `kind: bot` en `rack.actors`, o login `…[bot]`), `schedule`,
`human` (hay actor) y `unknown`."""
import logging
import re
import time

from ... import profile as profile_mod
from .. import db, envelope, layout
from .base import ForgeError, ForgeProvider, RUN_FIELDS  # noqa: F401 - API pública del paquete

log = logging.getLogger("chopshop.agent.forge")

KEEP_DONE = 5                     # completados que se conservan por repo (igual que la proyección)
KEEP_ROWS = 50                    # filas de forge_runs por repo
DISPATCH_WINDOW = 600.0           # s entre un forge.dispatch y el run que lo atiende (sin nonce en el título)
DISPATCH_LOOKBACK = 86400.0       # s de forge.dispatch que se miran
_FAIL = {"failure", "timed_out", "cancelled", "startup_failure"}
_DISPATCH_EVENTS = ("workflow_dispatch", "repository_dispatch")

SCHEMA = """
CREATE TABLE IF NOT EXISTS forge_runs (
  provider TEXT NOT NULL, repo TEXT NOT NULL, run_id TEXT NOT NULL, workflow TEXT, status TEXT, conclusion TEXT,
  event TEXT, actor TEXT, head_branch TEXT, head_sha TEXT, url TEXT, origin TEXT, body TEXT, updated REAL,
  PRIMARY KEY (provider, repo, run_id));
"""


def ensure_schema(conn):
    """Crea `forge_runs` si falta (idempotente; no depende del `user_version` de db.py)."""
    with db.tx():
        conn.executescript(SCHEMA)


# ---------------------------------------------------------------- funciones puras

def repo_key(provider, repo):
    return "%s:%s" % (provider, (repo or "").lower())


def light(runs, default_branch=None, pr_ci=(), error=None):
    """(luz, ci) de un módulo del rack.

    luz: `gray` si hay `error` o no hay datos; `red` si el último run de algún workflow en la rama por defecto falló o algún
    PR abierto tiene CI rojo; `amber` si hay runs en curso o en cola; si no, `green`. ci = agregado de la rama por defecto
    (`success`, `failure`, `pending` o None)."""
    runs = [r for r in runs or [] if isinstance(r, dict)]
    latest = {}
    for r in sorted(runs, key=lambda r: (r.get("created_at") or "", r.get("run_id") or "")):
        if default_branch and r.get("head_branch") == default_branch:
            latest[r.get("workflow_path") or r.get("workflow")] = r
    dflt = list(latest.values())
    if any(r.get("status") != "completed" for r in dflt):
        ci = "pending"
    elif any((r.get("conclusion") or "") in _FAIL for r in dflt):
        ci = "failure"
    else:
        ci = "success" if dflt else None
    if error:
        return "gray", ci
    if not runs and not any(pr_ci or ()):
        return "gray", ci
    if any((r.get("conclusion") or "") in _FAIL for r in dflt if r.get("status") == "completed") or "failure" in (pr_ci or ()):
        return "red", ci
    if any(r.get("status") != "completed" for r in runs):
        return "amber", ci
    return "green", ci


def _thread_label(t):
    role, desk = t.get("role"), t.get("desk")
    if role and desk:
        return "%s · %s" % (role, desk)
    return role or desk or t.get("title") or t.get("thread_id")


def _dispatch_matches(d, run, repo):
    if (d.get("repo") or "").lower() != (repo or "").lower():
        return False
    if d.get("nonce") and d["nonce"] in " ".join(filter(None, (run.get("title"), run.get("workflow")))):
        return True
    wf = d.get("workflow") or ""
    names = {run.get("workflow"), (run.get("workflow_path") or "").rsplit("/", 1)[-1], run.get("workflow_path")}
    if wf not in names or (d.get("ref") and d["ref"] != run.get("head_branch")):
        return False
    created, ts = envelope.epoch(run.get("created_at")), d.get("ts")
    return created is not None and ts is not None and -30 <= created - ts <= DISPATCH_WINDOW


def origin(run, repo, threads=(), dispatches=(), actors=None, default_branch=None, claimed=()):
    """Origen `{kind, id, label}` de un run normalizado (ver el docstring del módulo para la prioridad).

    threads: [{thread_id, branch, title, role, desk}] (el más reciente primero); dispatches: [{nonce, repo, workflow, ref, ts,
    automation}]; actors: {login: {kind, label}}; claimed: nonces ya atribuidos a otro run."""
    branch = run.get("head_branch")
    if branch and branch != default_branch:
        for t in threads:
            if t.get("branch") == branch:
                return {"kind": "thread", "id": t.get("thread_id"), "label": _thread_label(t)}
    if run.get("event") in _DISPATCH_EVENTS:
        for d in dispatches:
            if (d.get("nonce") or d.get("id")) not in claimed and _dispatch_matches(d, run, repo):
                name = d.get("automation")
                return {"kind": "automation", "id": d.get("nonce") or d.get("id"),
                        "label": "%s · %s" % (name, d.get("workflow")) if name else d.get("workflow")}
    actors = actors or {}
    for login in (run.get("triggering_actor"), run.get("actor")):
        a = actors.get(login) if login else None
        if a and a.get("kind") == "bot":
            return {"kind": "bot", "id": login, "label": a.get("label") or login}
    if run.get("event") == "schedule":
        return {"kind": "schedule", "id": run.get("workflow_path") or run.get("workflow"), "label": "cron"}
    login = run.get("triggering_actor") or run.get("actor")
    if login and login.endswith("[bot]"):
        return {"kind": "bot", "id": login, "label": login}
    if login:
        return {"kind": "human", "id": login, "label": (actors.get(login) or {}).get("label") or login}
    return {"kind": "unknown", "id": None, "label": None}


def keep(runs, done=KEEP_DONE):
    """Runs que pinta el rack: todos los no completados + los `done` completados más nuevos (por `updated_at`)."""
    active = [r for r in runs if r.get("status") != "completed"]
    finished = sorted((r for r in runs if r.get("status") == "completed"),
                      key=lambda r: r.get("updated_at") or "", reverse=True)[:done]
    ids = {r["run_id"] for r in active + finished}
    return [r for r in runs if r["run_id"] in ids]


# ---------------------------------------------------------------- repos del rack

def load_profiles():
    """Perfiles de ~/.chopshop/profiles (un perfil roto se ignora)."""
    out = []
    for name in profile_mod.list_projects():
        try:
            out.append(profile_mod.load(name))
        except Exception:  # noqa: BLE001
            continue
    return out


def rack_entries(cfg, profiles=()):
    """[{provider, repo, project, kind, label}] = `rack.repos` de los perfiles + `[agent.github] repos` (sin duplicar)."""
    from . import github
    out, seen = [], set()
    for prof in profiles:
        for e in layout.rack_repos(prof):
            k = repo_key(e["provider"], e["repo"])
            if k not in seen:
                seen.add(k)
                out.append(e)
    pmap = github.project_map(cfg, {p.get("project"): p.get("repo") for p in profiles if p.get("project") and p.get("repo")})
    for r in (cfg.get("github") or {}).get("repos") or []:
        n = github.norm_repo(r)
        if n and repo_key("github", n) not in seen:
            seen.add(repo_key("github", n))
            out.append({"provider": "github", "repo": n, "project": pmap.get(n), "kind": "main", "label": n.split("/")[-1]})
    return out


def rack_actors(profiles):
    out = {}
    for prof in profiles or []:
        out.update(layout.rack_actors(prof))
    return out


# ---------------------------------------------------------------- poller

class Rack:
    """Sondeo del rack. `providers` = {nombre: ForgeProvider}; `profiles_fn() -> [perfil]`; `emit(tipo, proyecto, cuerpo)`."""

    def __init__(self, conn, cfg, emit, providers, clock=time.time, profiles_fn=None):
        self.conn, self.cfg, self.emit, self.providers, self.clock = conn, cfg, emit, providers, clock
        self.profiles_fn = profiles_fn or load_profiles
        ensure_schema(conn)

    # -- contexto para el origen
    def _threads(self):
        with db.tx():
            rows = db.rows(self.conn.execute(
                "SELECT thread_id, title, branch, extra FROM t3_threads WHERE branch IS NOT NULL AND branch != '' "
                "ORDER BY COALESCE(updated, last_seen, 0) DESC LIMIT 500"))
        desks = {}
        try:                                    # tablas de la oficina (fase 1); si aún no existen, sin escritorio
            with db.tx():
                for r in self.conn.execute("SELECT o.thread_id, d.id, d.role FROM desk_occupancy o JOIN desks d "
                                           "ON d.id = o.desk_id WHERE o.until IS NULL"):
                    desks[r[0]] = (r[1], r[2])
        except Exception:  # noqa: BLE001
            pass
        out = []
        for r in rows:
            extra = db.jload(r.get("extra"), {}) or {}
            desk, role = desks.get(r["thread_id"], (None, None))
            out.append({"thread_id": r["thread_id"], "branch": r["branch"], "title": r.get("title"),
                        "role": role or extra.get("role"), "desk": desk})
        return out

    def _dispatches(self):
        since = self.clock() - DISPATCH_LOOKBACK
        with db.tx():
            rows = db.rows(self.conn.execute(
                "SELECT id, ts, body FROM events WHERE type='forge.dispatch' AND ts >= ? ORDER BY seq", (since,)))
        out = []
        for r in rows:
            b = db.jload(r["body"], {}) or {}
            out.append(dict(b, id=r["id"], ts=r["ts"]))
        return out

    def _claimed(self, provider):
        with db.tx():
            rows = self.conn.execute("SELECT origin FROM forge_runs WHERE provider=?", (provider,)).fetchall()
        out = set()
        for r in rows:
            o = db.jload(r["origin"], {}) or {}
            if o.get("kind") == "automation" and o.get("id"):
                out.add(o["id"])
        return out

    # -- meta
    def _meta(self, key):
        with db.tx():
            r = self.conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return db.jload(r["value"], None) if r else None

    def _set_meta(self, key, value):
        with db.tx():
            self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (key, db.jdump(value)))

    def _rows(self, provider, repo):
        with db.tx():
            rows = db.rows(self.conn.execute("SELECT * FROM forge_runs WHERE provider=? AND repo=?", (provider, repo.lower())))
        return {r["run_id"]: r for r in rows}

    # -- una pasada
    def poll_once(self):
        try:
            profiles = self.profiles_fn() or []
        except Exception:  # noqa: BLE001
            profiles = []
        entries = rack_entries(self.cfg, profiles)
        actors = rack_actors(profiles)
        ctx = None
        res = {"repos": len(entries), "emitted": 0, "errors": {}}
        failed = set()
        for e in entries:
            prov = self.providers.get(e["provider"])
            if prov is None:
                res["emitted"] += self._repo_state(e, [], {}, "proveedor no soportado")
                res["errors"][e["repo"]] = "unsupported"
                continue
            if e["provider"] in failed or prov.in_backoff():
                res["emitted"] += self._repo_state(e, None, {}, prov.error() or "backoff")
                continue
            try:
                if ctx is None:
                    ctx = {"threads": self._threads(), "dispatches": self._dispatches()}
                res["emitted"] += self._poll_repo(prov, e, ctx, actors)
            except ForgeError as err:
                res["errors"][e["repo"]] = err.kind
                if err.kind == "not_found":
                    res["emitted"] += self._repo_state(e, None, {}, "no encontrado")
                    continue
                failed.add(e["provider"])
                prov.degrade(err)
                res["emitted"] += self._repo_state(e, None, {}, prov.error() or err.kind)
        return res

    def _poll_repo(self, prov, e, ctx, actors):
        provider, repo = e["provider"], e["repo"]
        stored = self._rows(provider, repo)
        status = prov.repo_status(repo)
        runs = prov.poll_runs(repo, fresh=not stored)
        emitted = 0
        if runs is not None:
            claimed = self._claimed(provider)
            for run in reversed(keep(runs)):         # del más viejo al más nuevo; lo que el rack no pinta no se publica
                old = stored.get(run["run_id"])
                o = db.jload(old["origin"], None) if old else None
                if not o or o.get("kind") not in ("thread", "automation"):
                    o = origin(run, repo, ctx["threads"], ctx["dispatches"], actors, status.get("default_branch"), claimed)
                    if o["kind"] == "automation":
                        claimed.add(o["id"])
                body = dict({k: run.get(k) for k in RUN_FIELDS}, provider=provider, repo=repo, project=e.get("project"),
                            origin=o)
                if old and db.jload(old["body"], None) == body:
                    continue
                self._store(provider, repo, run, o, body)
                self.emit("forge.run.state", e.get("project"), body)
                emitted += 1
            self._prune(provider, repo)
        all_runs = [db.jload(r["body"], {}) for r in self._rows(provider, repo).values()]
        emitted += self._repo_state(e, all_runs, status, None)
        return emitted

    def _store(self, provider, repo, run, o, body):
        with db.tx():
            self.conn.execute(
                "INSERT OR REPLACE INTO forge_runs(provider, repo, run_id, workflow, status, conclusion, event, actor, head_branch,"
                " head_sha, url, origin, body, updated) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (provider, repo.lower(), run["run_id"], run.get("workflow"), run.get("status"), run.get("conclusion"),
                 run.get("event"), run.get("actor"), run.get("head_branch"), run.get("head_sha"), run.get("url"),
                 db.jdump(o), db.jdump(body), self.clock()))

    def _prune(self, provider, repo):
        with db.tx():
            self.conn.execute(
                "DELETE FROM forge_runs WHERE provider=? AND repo=? AND status='completed' AND run_id NOT IN ("
                " SELECT run_id FROM forge_runs WHERE provider=? AND repo=? ORDER BY updated DESC, CAST(run_id AS INTEGER) DESC"
                " LIMIT ?)", (provider, repo.lower(), provider, repo.lower(), KEEP_ROWS))

    def _repo_state(self, e, runs, status, error):
        """Emite `forge.repo.state` si cambió. `runs=None` = conservar la última luz conocida salvo que haya error."""
        key = "forge_state:" + repo_key(e["provider"], e["repo"])
        prev = self._meta(key) or {}
        if runs is None:
            runs = [db.jload(r["body"], {}) for r in self._rows(e["provider"], e["repo"]).values()]
        lt, ci = light(runs, status.get("default_branch") or prev.get("default_branch"), status.get("pr_ci") or (), error)
        body = {"provider": e["provider"], "repo": e["repo"], "project": e.get("project"), "kind": e.get("kind"),
                "label": e.get("label"), "light": lt,
                "default_branch": status.get("default_branch") or prev.get("default_branch"),
                "ci": ci, "url": status.get("url") or prev.get("url"), "error": error}
        if body == prev:
            return 0
        self._set_meta(key, body)
        self.emit("forge.repo.state", e.get("project"), body)
        return 1


# alias para el contrato del plan: `forge.github.GitHubProvider`
from . import github  # noqa: E402,F401
