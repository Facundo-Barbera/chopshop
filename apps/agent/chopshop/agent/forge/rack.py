"""Hilo `forge` del agente: el rack de repos de la sala de máquinas (docs/plans/office-redesign.md §4).

Repos del rack = `rack.repos` de cada perfil (`layout.rack_repos`: proyecto, kind, label) más `[agent.github] repos` si
`[agent.github] enabled` (kind `main`, proyecto por `github.project_map`; gana el perfil). En cada pasada pide a su proveedor
`repo_status` y emite `forge.repo.state` **solo si cambió** (último cuerpo en `meta` `forge_repo:<proveedor>:<repo>`), así que
un repo quieto no genera sobres. Sin proveedor, slug inválido o proveedor degradado -> luz gris con `error`.
Un error que degrada la cuenta (cuota, `gh` caído) deja de preguntar a ese proveedor en la pasada (sus demás repos van grises)
y aplica backoff exponencial (respeta `wait`). Inyectable: `providers` {nombre: ForgeProvider}, `entries_fn`, `clock`,
`emit(type, project, body, severity)`."""
import logging
import time

from .. import db, github as gh, layout
from ... import profile as profile_mod
from . import base

log = logging.getLogger("chopshop.agent.forge")

MAX_BACKOFF = 900.0
BODY_KEYS = ("provider", "repo", "project", "kind", "label", "light", "default_branch", "ci", "url", "error",
             "active_runs", "pr_failing")


def enabled(cfg):
    """`[agent.forge] enabled`; `"auto"` (o sin valor) sigue a `[agent.github] enabled` (mismo `gh`, mismo opt-in)."""
    v = (cfg.get("forge") or {}).get("enabled", "auto")
    return bool((cfg.get("github") or {}).get("enabled")) if v in ("auto", None) else v is True


def check(cfg):
    """Errores de `[agent.forge]` (lo usa `check_config`)."""
    f = cfg.get("forge") or {}
    errs = []
    if f.get("enabled", "auto") not in ("auto", None, True, False):
        errs.append("agent.forge.enabled debe ser true, false o \"auto\" (es %r)" % (f.get("enabled"),))
    iv = f.get("interval_s", 60)
    if isinstance(iv, bool) or not isinstance(iv, (int, float)) or iv < 10:
        errs.append("agent.forge.interval_s debe ser un número >= 10 (es %r)" % (iv,))
    return errs


def profile_entries():
    """[{provider, repo, project, kind, label}] de `rack.repos` de ~/.chopshop/profiles/*.yaml (un perfil roto se ignora)."""
    out = []
    for name in profile_mod.list_projects():
        try:
            prof = profile_mod.load(name)
        except Exception:  # noqa: BLE001 - un perfil roto no tumba el hilo
            continue
        prof.setdefault("project", name)
        out += layout.rack_repos(prof)
    return out


def config_entries(cfg, profiles=None):
    """Repos de `[agent.github] repos` como módulos del rack (solo con `[agent.github] enabled`)."""
    g = cfg.get("github") or {}
    if not g.get("enabled"):
        return []
    projects = gh.project_map(cfg, profiles)
    out = []
    for r in g.get("repos") or []:
        n = gh.norm_repo(r)
        if n:
            out.append({"provider": "github", "repo": n, "project": projects.get(n), "kind": "main",
                        "label": n.split("/")[-1]})
    return out


def body_of(entry, status, light, prev=None):
    """Cuerpo de `forge.repo.state`. Con error se conservan rama por defecto y url del último cuerpo bueno."""
    prev = prev or {}
    st = status or {}
    return {"provider": entry["provider"], "repo": entry["repo"], "project": entry.get("project"),
            "kind": entry.get("kind") or "main", "label": entry.get("label") or entry["repo"].split("/")[-1],
            "light": light, "default_branch": st.get("default_branch") or prev.get("default_branch"),
            "ci": st.get("ci") if not st.get("error") else None, "url": st.get("url") or prev.get("url"),
            "error": st.get("error"), "active_runs": int(st.get("active") or 0), "pr_failing": list(st.get("pr_failing") or [])}


class Rack:
    def __init__(self, conn, cfg, emit, providers=None, entries_fn=None, clock=time.time, provider_opts=None):
        fcfg = cfg.get("forge") or {}
        self.conn, self.cfg, self.emit, self.clock = conn, cfg, emit, clock
        self.interval = max(10.0, float(fcfg.get("interval_s") or 60))
        self.providers = dict(providers or {})
        self.provider_opts = provider_opts or {}
        self.entries_fn = entries_fn or self._default_entries
        self.failures, self.until = 0, 0.0
        self._warned = set()

    def _default_entries(self):
        prof = profile_entries()
        try:
            repos = gh.profile_repos()
        except Exception:  # noqa: BLE001
            repos = None
        return prof + config_entries(self.cfg, repos)

    def _provider(self, name):
        if name not in self.providers:
            from . import PROVIDERS  # noqa: PLC0415 - evita el ciclo forge/__init__ -> rack
            cls = PROVIDERS.get(name)
            self.providers[name] = cls(self.conn, self.cfg, clock=self.clock, **self.provider_opts) if cls else None
        return self.providers[name]

    def entries(self):
        """Repos únicos por (proveedor, slug canónico); el primero gana (perfiles antes que config)."""
        try:
            raw = self.entries_fn() or []
        except Exception:  # noqa: BLE001
            log.exception("forge: no pude leer los repos del rack")
            raw = []
        out, seen = [], set()
        for e in raw:
            prov = self._provider(e.get("provider") or "github")
            repo = prov.norm_repo(e.get("repo")) if prov else e.get("repo")
            if not repo:
                key = (e.get("provider"), e.get("repo"))
                if key not in self._warned:
                    self._warned.add(key)
                    log.warning("forge: repo inválido en el rack: %s:%s", *key)
                continue
            key = (e.get("provider") or "github", repo)
            if key not in seen:
                seen.add(key)
                out.append(dict(e, provider=key[0], repo=repo))
        return out

    # -- meta
    def _get(self, key):
        with db.tx():
            r = self.conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return db.jload(r["value"], None) if r else None

    def _set(self, key, value):
        with db.tx():
            self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (key, db.jdump(value)))

    # -- una pasada
    def poll_once(self):
        now = self.clock()
        if now < self.until:
            return {"skipped": "backoff", "emitted": 0}
        res = {"emitted": 0, "errors": {}, "lights": {}}
        down, worst = {}, None
        for e in self.entries():
            name, prov = e["provider"], self._provider(e["provider"])
            if prov is None:
                status = {"error": "provider"}
            elif name in down:
                status = {"error": down[name]}
            else:
                try:
                    status = prov.repo_status(e["repo"])
                except base.ProviderError as err:
                    status = {"error": err.kind}
                    if err.degraded:
                        down[name] = err.kind
                        if worst is None or (err.wait or 0) > (worst.wait or 0):
                            worst = err
                except Exception:  # noqa: BLE001 - un adaptador roto no tumba el hilo
                    log.exception("forge: %s:%s", name, e["repo"])
                    status = {"error": "provider"}
            key = "forge_repo:%s:%s" % (name, e["repo"])
            prev = self._get(key)
            body = gh._clean(body_of(e, status, base.light(status), prev))
            ident = "%s:%s" % (name, e["repo"])
            res["lights"][ident] = body["light"]
            if body["error"]:
                res["errors"][ident] = body["error"]
            if body != prev:
                self.emit("forge.repo.state", body["project"], body, "warn" if body["light"] == base.LIGHT_RED else None)
                self._set(key, body)
                res["emitted"] += 1
        self._backoff(worst, now)
        return res

    def _backoff(self, err, now):
        if err is None:
            self.failures, self.until = 0, 0.0
            return
        self.failures += 1
        wait = min(MAX_BACKOFF, self.interval * (2 ** min(self.failures - 1, 6)))
        if err.wait:
            wait = min(max(wait, float(err.wait)), 3600.0)
        if self.failures == 1:
            log.warning("forge: %s; reintento en %ds", err, wait)
        self.until = now + wait

    def next_delay(self):
        left = self.until - self.clock()
        if left > 0:
            return left
        return max([self.interval] + [p.next_delay() or 0 for p in self.providers.values() if p is not None])
