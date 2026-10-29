"""Ingreso de GitHub por polling con ETag (diseño §6, opción 1): hilo `github` del agente.

Por cada repo de `[agent.github] repos`:
- `GET /repos/{o}/{r}/events` con `If-None-Match` (un 304 no gasta cuota ni emite). Cursor en `meta`:
  `gh_etag:<repo>` y `gh_last_event_id:<repo>`; solo se emiten eventos con id mayor que el cursor.
- `GET /repos/{o}/{r}/pulls?state=open` + check-runs del HEAD de cada PR abierto -> `github.ci.completed` cuando el
  agregado de CI de ese HEAD pasa a `success|failure`. Estado (ETags, HEADs y CI por PR) en `meta` `gh_ci:<repo>` (JSON).
- La primera pasada de cada repo siembra los cursores SIN emitir (como `t3watch`).
- `X-Poll-Interval` de GitHub sube el intervalo; 403/429/rate-limit/5xx/fallo de `gh` -> backoff exponencial (respeta
  `Retry-After` y `X-RateLimit-Reset`) y UNA emisión `machine.health` degradada (y otra `ok` al recuperar). El hilo sigue.

Desde la v3 (`GitHubProvider`, adaptador de `ForgeProvider` para el rack de la sala de máquinas) además:
- `GET /repos/{o}/{r}/actions/runs` con ETag (`forge_etag:github:<repo>` en `meta`) -> runs normalizados;
- `GET /repos/{o}/{r}` (como mucho una vez por hora, `forge_repo:github:<repo>`) -> rama por defecto.
El mismo backoff y la misma `machine.health` cubren las dos cosas (la cuota es de toda la cuenta).

Se usa el `gh` ya autenticado de la máquina (`gh api -i`): este módulo nunca lee, pasa ni imprime el token. Los logs solo
llevan repo, código HTTP y motivo; los cuerpos emitidos son metadatos (texto largo truncado a 2 KB) y se les quitan
patrones de credenciales (`gh?_…`, `github_pat_…`, `Authorization: …`, `usuario:clave@` en URLs).
Inyectable: `runner(argv, timeout) -> (rc, stdout, stderr)`, `clock`, `emit(event, project, body)`, `projects_fn()`."""
import json
import logging
import re
import time

from ... import profile as profile_mod
from .. import db
from .base import ForgeError, ForgeProvider

log = logging.getLogger("chopshop.agent.github")

GH_TIMEOUT = 20                   # s por llamada a `gh api`
MAX_BACKOFF = 900.0               # s, tope del backoff
MAX_TEXT = 2048                   # bytes del texto largo (cuerpo del issue/PR, mensaje de commit)
MAX_TITLE = 300
MAX_PRS = 30                      # PRs abiertos por repo a los que se mira el CI
PER_PAGE = 100
_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_FAIL = {"failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"}
_SECRET = [
    (re.compile(r"(?i)authorization\s*[:=]\s*(?:(?:bearer|token|basic)\s+)?\S+"), "[redactado]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{10,}"), "[redactado]"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{10,}"), "[redactado]"),
    (re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+(?::[^/\s@]*)?@"), r"\1"),
]


class GitHubError(ForgeError):
    """Respuesta no utilizable de `gh api`. `kind`: rate_limit | forbidden | server_error | not_found | gh | http."""


# ---------------------------------------------------------------- utilidades puras

def norm_repo(value):
    """'Owner/Name', URL https/ssh de GitHub o 'github.com/Owner/Name(.git)' -> 'owner/name' (o None)."""
    if not isinstance(value, str):
        return None
    s = value.strip()
    s = re.sub(r"^(?:https?://|ssh://)?(?:[^@/]+@)?(?:www\.)?github\.com[:/]", "", s, flags=re.I)
    s = re.sub(r"\.git$", "", s.strip("/"))
    return s.lower() if _REPO.match(s) else None


def scrub(s):
    """Quita patrones de credenciales de un texto."""
    for rx, rep in _SECRET:
        s = rx.sub(rep, s)
    return s


def clip(s, limit=MAX_TEXT):
    """Texto limpio y truncado a `limit` BYTES UTF-8 (sin romper un carácter)."""
    if s is None:
        return None
    s = scrub(str(s))
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s
    return b[:limit].decode("utf-8", "ignore") + "…"


def _clean(o):
    """Limpieza recursiva de los cuerpos emitidos (cinturón y tirantes: nada con forma de credencial sale)."""
    if isinstance(o, str):
        return scrub(o)
    if isinstance(o, dict):
        return {k: _clean(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_clean(v) for v in o]
    return o


def parse_include(out):
    """Salida de `gh api -i` -> (status, {cabecera_minúsculas: valor}, cuerpo). status None si no hay línea HTTP."""
    text = (out or "").replace("\r\n", "\n")
    head, sep, body = text.partition("\n\n")
    lines = head.split("\n")
    m = re.match(r"^HTTP/[\d.]+\s+(\d{3})", lines[0] if lines else "")
    if not m:
        return None, {}, text
    headers = {}
    for line in lines[1:]:
        k, colon, v = line.partition(":")
        if colon:
            headers[k.strip().lower()] = v.strip()
    return int(m.group(1)), headers, body if sep else ""


def _int(v, default=None):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _login(o):
    return (o or {}).get("login") if isinstance(o, dict) else None


def _labels(o):
    return [l.get("name") for l in (o or {}).get("labels") or [] if isinstance(l, dict) and l.get("name")]


def _base_body(repo, **kw):
    body = {"repo": repo, "number": None, "title": None, "url": None, "actor": None, "action": None, "labels": [],
            "head": None, "base": None, "state": None, "ci": None, "etag_source": "events"}
    body.update(kw)
    if body.get("title") is not None:
        body["title"] = clip(body["title"], MAX_TITLE)
    return body


def map_event(ev, repo):
    """Un evento de `/repos/{r}/events` -> (tipo, cuerpo) o None si no se publica."""
    t = ev.get("type")
    p = ev.get("payload") or {}
    actor = _login(ev.get("actor"))
    action = p.get("action")
    if t == "IssuesEvent":
        i = p.get("issue") or {}
        if i.get("pull_request"):
            return None
        kind = {"opened": "opened", "closed": "closed"}.get(action, "updated")
        return "github.issue." + kind, _base_body(
            repo, number=i.get("number"), title=i.get("title"), url=i.get("html_url"), actor=actor, action=action,
            labels=_labels(i), state=i.get("state"), text=clip(i.get("body")))
    if t == "PullRequestEvent":
        pr = p.get("pull_request") or {}
        merged = action == "closed" and bool(pr.get("merged") or pr.get("merged_at"))
        kind = "merged" if merged else ("opened" if action == "opened" else "updated")
        return "github.pr." + kind, _base_body(
            repo, number=pr.get("number") or p.get("number"), title=pr.get("title"), url=pr.get("html_url"), actor=actor,
            action="merged" if merged else action, labels=_labels(pr), head=(pr.get("head") or {}).get("ref"),
            base=(pr.get("base") or {}).get("ref"), state="merged" if merged else pr.get("state"), text=clip(pr.get("body")))
    if t == "PullRequestReviewEvent":
        pr, rv = p.get("pull_request") or {}, p.get("review") or {}
        return "github.pr.review", _base_body(
            repo, number=pr.get("number"), title=pr.get("title"), url=rv.get("html_url") or pr.get("html_url"), actor=actor,
            action=action, labels=_labels(pr), head=(pr.get("head") or {}).get("ref"), base=(pr.get("base") or {}).get("ref"),
            state=pr.get("state"), review=(rv.get("state") or "").lower() or None, text=clip(rv.get("body")))
    if t == "PushEvent":
        ref = p.get("ref") or ""
        commits = p.get("commits") or []
        last = commits[-1] if commits and isinstance(commits[-1], dict) else {}
        msg = (last.get("message") or "").split("\n", 1)[0] or None
        before, head = p.get("before"), p.get("head")
        url = "https://github.com/%s/compare/%s...%s" % (repo, before[:12], head[:12]) if before and head else None
        return "github.push", _base_body(
            repo, title=msg, url=url, actor=actor, action="push",
            head=ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref or None,
            sha=head, commits=_int(p.get("size"), len(commits)))
    return None


def ci_state(check_runs):
    """Agregado de check-runs: None (sin CI) | pending | failure | success."""
    runs = [r for r in check_runs or [] if isinstance(r, dict)]
    if not runs:
        return None
    if any(r.get("status") != "completed" for r in runs):
        return "pending"
    if any((r.get("conclusion") or "") in _FAIL for r in runs):
        return "failure"
    return "success"


def project_map(cfg, profiles=None):
    """{'owner/name': proyecto} desde `[agent.projects.<p>] repo` y los perfiles (`profile.repo`, ganan los perfiles)."""
    out = {}
    for name, p in (cfg.get("projects") or {}).items():
        r = norm_repo(p.get("repo")) if isinstance(p, dict) else None
        if r:
            out[r] = name
    for name, repo in (profiles or {}).items():
        r = norm_repo(repo)
        if r:
            out[r] = name
    return out


def profile_repos():
    """{proyecto: repo} de ~/.chopshop/profiles/*.yaml. Un perfil roto se ignora."""
    out = {}
    for name in profile_mod.list_projects():
        try:
            d = profile_mod.load(name)
        except Exception:  # noqa: BLE001 - un perfil roto no tumba el hilo
            continue
        if d.get("repo"):
            out[name] = d["repo"]
    return out


# ---------------------------------------------------------------- poller

class GitHubPoller:
    """Estado del sondeo. `poll_once()` hace una pasada (nunca lanza por errores de GitHub); `next_delay()` = espera."""

    def __init__(self, conn, cfg, emit, runner=None, clock=time.time, projects_fn=profile_repos):
        gcfg = cfg.get("github") or {}
        self.conn, self.cfg, self.emit, self.clock = conn, cfg, emit, clock
        self.runner = runner or _default_runner
        self.projects_fn = projects_fn
        self.gh = gcfg.get("gh_bin") or "gh"
        self.interval = max(10.0, float(gcfg.get("interval_s") or 45))
        self.ci = gcfg.get("ci", True)
        self.repos = []
        for r in gcfg.get("repos") or []:
            n = norm_repo(r)
            if n and n not in self.repos:
                self.repos.append(n)
        self.poll_interval = 0.0      # X-Poll-Interval más alto visto en la pasada
        self.failures = 0
        self.until = 0.0              # no sondear antes de este instante (backoff)
        self.degraded_since = None
        self._warned = set()
        self.last_error = None

    # -- gh api
    def _api(self, path, etag=None):
        """-> (status, headers, datos JSON o None). Lanza GitHubError para todo lo que no sea 2xx/304."""
        argv = [self.gh, "api", "-i", "-H", "Accept: application/vnd.github+json"]
        if etag:
            argv += ["-H", "If-None-Match: " + etag]
        rc, out, _err = self.runner(argv + [path], GH_TIMEOUT)     # stderr no se usa ni se registra
        status, headers, body = parse_include(out)
        if status is None:
            raise GitHubError("gh", wait=None)
        pi = _int(headers.get("x-poll-interval"))
        if pi:
            self.poll_interval = max(self.poll_interval, float(pi))
        if status == 304:
            return status, headers, None
        if 200 <= status < 300:
            try:
                return status, headers, json.loads(body) if body.strip() else None
            except ValueError:
                raise GitHubError("http", status)
        wait = _int(headers.get("retry-after"))
        if (status in (403, 429)) and (headers.get("x-ratelimit-remaining") == "0" or status == 429 or wait):
            reset = _int(headers.get("x-ratelimit-reset"))
            if wait is None and reset:
                wait = max(0, reset - int(self.clock()))
            raise GitHubError("rate_limit", status, wait)
        if status == 403:
            raise GitHubError("forbidden", status)
        if status in (404, 410):
            raise GitHubError("not_found", status)
        if status >= 500:
            raise GitHubError("server_error", status)
        raise GitHubError("http", status)

    # -- meta
    def _get(self, key):
        with db.tx():
            r = self.conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return r["value"] if r else None

    def _set(self, items):
        with db.tx():
            for k, v in items.items():
                if v is None:
                    self.conn.execute("DELETE FROM meta WHERE key=?", (k,))
                else:
                    self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (k, str(v)))

    def _emit(self, event, project, body):
        self.emit(event, project, _clean(body))

    # -- una pasada
    def poll_once(self):
        now = self.clock()
        if now < self.until:
            return {"skipped": "backoff", "emitted": 0}
        self.poll_interval = 0.0
        try:
            projects = project_map(self.cfg, self.projects_fn() if self.projects_fn else None)
        except Exception:  # noqa: BLE001
            projects = project_map(self.cfg)
        res = {"emitted": 0, "seeded": [], "errors": {}}
        error = None
        for repo in self.repos:
            try:
                res["emitted"] += self._poll_repo(repo, projects.get(repo), res)
            except GitHubError as e:
                if e.kind == "not_found":          # repo mal escrito o sin acceso: aviso una vez, no degrada
                    if repo not in self._warned:
                        self._warned.add(repo)
                        log.warning("github: %s no existe o no es accesible (HTTP %s)", repo, e.status)
                    res["errors"][repo] = e.kind
                    continue
                error = e
                res["errors"][repo] = e.kind
                break                               # cuota y fallos de gh son de toda la cuenta: se para la pasada
        if error is not None:
            self._degrade(error, now)
        else:
            self._recover(now)
        return res

    def _poll_repo(self, repo, project, res):
        emitted = 0
        k_etag, k_last = "gh_etag:" + repo, "gh_last_event_id:" + repo
        last = self._get(k_last)
        etag = self._get(k_etag) if last is not None else None
        status, headers, data = self._api("/repos/%s/events?per_page=%d" % (repo, PER_PAGE), etag)
        if status != 304:
            evs = [e for e in data or [] if isinstance(e, dict) and _int(e.get("id")) is not None]
            evs.sort(key=lambda e: _int(e["id"]))
            top = max([_int(e["id"]) for e in evs] + [_int(last, 0)])
            if last is None:
                res["seeded"].append(repo)
            else:
                for e in evs:
                    if _int(e["id"]) <= _int(last, 0):
                        continue
                    m = map_event(e, repo)
                    if m:
                        self._emit(m[0], project, m[1])
                        emitted += 1
            self._set({k_etag: headers.get("etag"), k_last: top})
        if self.ci:
            emitted += self._poll_ci(repo, project)
        return emitted

    def _poll_ci(self, repo, project):
        key = "gh_ci:" + repo
        raw = self._get(key)
        st = db.jload(raw, None) if raw else None
        seed = not isinstance(st, dict)
        st = st if not seed else {"etag": None, "prs": {}}
        prs = st.get("prs") or {}
        status, headers, data = self._api("/repos/%s/pulls?state=open&per_page=%d" % (repo, MAX_PRS),
                                          None if seed else st.get("etag"))
        if status != 304:
            fresh = {}
            for pr in (data or [])[:MAX_PRS]:
                if not isinstance(pr, dict) or not pr.get("number"):
                    continue
                n = str(pr["number"])
                old = prs.get(n) or {}
                sha = (pr.get("head") or {}).get("sha")
                fresh[n] = {"sha": sha, "head": (pr.get("head") or {}).get("ref"), "base": (pr.get("base") or {}).get("ref"),
                            "title": clip(pr.get("title"), MAX_TITLE), "url": pr.get("html_url"), "actor": _login(pr.get("user")),
                            "labels": _labels(pr),
                            "ci": old.get("ci") if old.get("sha") == sha else None,
                            "etag": old.get("etag") if old.get("sha") == sha else None}
            prs = fresh
            st["etag"] = headers.get("etag")
        emitted, done = 0, False
        try:
            for n, pr in prs.items():
                if not pr.get("sha"):
                    continue
                s, h, d = self._api("/repos/%s/commits/%s/check-runs?per_page=%d" % (repo, pr["sha"], PER_PAGE), pr.get("etag"))
                if s == 304:
                    continue
                pr["etag"] = h.get("etag")
                ci = ci_state((d or {}).get("check_runs"))
                prev, pr["ci"] = pr.get("ci"), ci
                if not seed and ci in ("success", "failure") and ci != prev:
                    self._emit("github.ci.completed", project, _base_body(
                        repo, number=_int(n), title=pr.get("title"), url=pr.get("url"), actor=pr.get("actor"),
                        action="completed", labels=pr.get("labels") or [], head=pr.get("head"), base=pr.get("base"),
                        state="open", ci=ci, sha=pr["sha"], etag_source="check-runs"))
                    emitted += 1
            done = True
        finally:
            if done or not seed:                   # una siembra a medias no se guarda: se repite entera
                st["prs"] = prs
                self._set({key: db.jdump(st)})
        return emitted

    # -- salud
    def _degrade(self, e, now):
        self.failures += 1
        self.last_error = e.kind
        wait = min(MAX_BACKOFF, self.interval * (2 ** min(self.failures - 1, 6)))
        if e.wait:
            wait = min(max(wait, float(e.wait)), 3600.0)
        self.until = now + wait
        if self.degraded_since is None:
            self.degraded_since = now
            log.warning("github: %s; reintento en %ds", e, wait)
            self._emit("machine.health", None, {"state": "degraded", "source": "github", "reason": e.kind,
                                                "status": e.status, "retry_in_s": int(wait), "down_seconds": None})

    def _recover(self, now):
        if self.degraded_since is not None:
            down = int(now - self.degraded_since)
            log.info("github: recuperado tras %ds", down)
            self._emit("machine.health", None, {"state": "ok", "source": "github", "reason": None, "status": None,
                                                "retry_in_s": None, "down_seconds": down})
        self.failures, self.until, self.degraded_since = 0, 0.0, None

    def next_delay(self):
        """Segundos hasta la próxima pasada: backoff vigente o max(interval_s, X-Poll-Interval)."""
        left = self.until - self.clock()
        if left > 0:
            return left
        return max(self.interval, self.poll_interval)


# ---------------------------------------------------------------- adaptador del rack

RUNS_PAGE = 20                    # runs por repo y pasada (los activos y los últimos completados caben de sobra)
REPO_REFRESH = 3600.0             # s entre lecturas de /repos/{r} (rama por defecto)


def run_status(s):
    """Estado de un run de Actions -> queued | in_progress | completed (waiting/requested/pending cuentan como cola)."""
    return s if s in ("in_progress", "completed") else "queued"


def map_run(r):
    """Un run de `/actions/runs` -> forma normalizada de `base.RUN_FIELDS` (None si no sirve)."""
    if not isinstance(r, dict) or r.get("id") is None:
        return None
    path = r.get("path") or ""
    return {"run_id": str(r["id"]), "workflow": clip(r.get("name"), MAX_TITLE) or path.rsplit("/", 1)[-1] or None,
            "workflow_path": path or None, "title": clip(r.get("display_title"), MAX_TITLE),
            "status": run_status(r.get("status")), "conclusion": r.get("conclusion"), "event": r.get("event"),
            "actor": _login(r.get("actor")), "triggering_actor": _login(r.get("triggering_actor")),
            "head_branch": r.get("head_branch"), "head_sha": r.get("head_sha"), "url": r.get("html_url"),
            "created_at": r.get("created_at") or r.get("run_started_at"), "updated_at": r.get("updated_at")}


class GitHubProvider(GitHubPoller, ForgeProvider):
    """`GitHubPoller` (eventos `github.*`) + lo que pide el rack (runs de Actions y rama por defecto)."""

    name = "github"

    def poll_events(self):
        return self.poll_once()

    def poll_runs(self, repo, fresh=False):
        n = norm_repo(repo)
        if not n:
            raise GitHubError("not_found")
        key = "forge_etag:github:" + n
        status, headers, data = self._api("/repos/%s/actions/runs?per_page=%d" % (n, RUNS_PAGE),
                                          None if fresh else self._get(key))
        if status == 304:
            return None
        runs = [m for m in (map_run(r) for r in ((data or {}).get("workflow_runs") or [])) if m]
        self._set({key: headers.get("etag")})
        return _clean(runs)

    def repo_status(self, repo):
        n = norm_repo(repo)
        if not n:
            raise GitHubError("not_found")
        key = "forge_repo:github:" + n
        st = db.jload(self._get(key), None) or {}
        if not st or self.clock() - float(st.get("at") or 0) >= REPO_REFRESH:
            status, headers, data = self._api("/repos/" + n, st.get("etag"))
            if status != 304 and isinstance(data, dict):
                st = {"default_branch": data.get("default_branch"), "url": data.get("html_url"), "etag": headers.get("etag")}
            st["at"] = self.clock()
            self._set({key: db.jdump(st)})
        ci = db.jload(self._get("gh_ci:" + n), None) or {}
        return {"default_branch": st.get("default_branch"), "url": st.get("url") or "https://github.com/" + n,
                "pr_ci": [p.get("ci") for p in (ci.get("prs") or {}).values() if isinstance(p, dict)]}

    def in_backoff(self):
        return self.clock() < self.until

    def degrade(self, err):
        self._degrade(err, self.clock())

    def recover(self):
        self._recover(self.clock())

    def error(self):
        return self.last_error if self.degraded_since is not None else None


def _default_runner(argv, timeout=GH_TIMEOUT):
    from ..server import default_runner
    return default_runner(argv, timeout)


def check(cfg, which=None):
    """(errores, avisos) de `[agent.github]` (lo usa `check_config`)."""
    g = cfg.get("github") or {}
    errs, warns = [], []
    if not g.get("enabled"):
        return errs, warns
    repos = g.get("repos")
    if not isinstance(repos, list) or not repos:
        warns.append("agent.github.enabled = true pero agent.github.repos está vacío")
    else:
        for r in repos:
            if not norm_repo(r):
                errs.append("agent.github.repos: %r no es 'dueño/repo'" % (r,))
    iv = g.get("interval_s")
    if isinstance(iv, bool) or not isinstance(iv, (int, float)) or iv < 10:
        errs.append("agent.github.interval_s debe ser un número >= 10 (es %r)" % (iv,))
    if which is not None and not which(g.get("gh_bin") or "gh"):
        warns.append("no encuentro el CLI de GitHub (agent.github.gh_bin): el hilo github avisará machine.health degradado")
    return errs, warns
