import json
import logging
import re
import time

from .. import profile as profile_mod
from . import db

log = logging.getLogger("chopshop.agent.github")

GH_TIMEOUT = 20
MAX_BACKOFF = 900.0
MAX_TEXT = 2048
MAX_TITLE = 300
MAX_PRS = 30
PER_PAGE = 100
_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_FAIL = {"failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"}
_SECRET = [
    (re.compile(r"(?i)authorization\s*[:=]\s*(?:(?:bearer|token|basic)\s+)?\S+"), "[redactado]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{10,}"), "[redactado]"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{10,}"), "[redactado]"),
    (re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+(?::[^/\s@]*)?@"), r"\1"),
]


class GitHubError(Exception):
    def __init__(self, kind, status=None, wait=None):
        super().__init__("%s%s" % (kind, " (HTTP %s)" % status if status else ""))
        self.kind, self.status, self.wait = kind, status, wait


def norm_repo(value):
    if not isinstance(value, str):
        return None
    s = value.strip()
    s = re.sub(r"^(?:https?://|ssh://)?(?:[^@/]+@)?(?:www\.)?github\.com[:/]", "", s, flags=re.I)
    s = re.sub(r"\.git$", "", s.strip("/"))
    return s.lower() if _REPO.match(s) else None


def scrub(s):
    for rx, rep in _SECRET:
        s = rx.sub(rep, s)
    return s


def clip(s, limit=MAX_TEXT):
    if s is None:
        return None
    s = scrub(str(s))
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s
    return b[:limit].decode("utf-8", "ignore") + "…"


def _clean(o):
    if isinstance(o, str):
        return scrub(o)
    if isinstance(o, dict):
        return {k: _clean(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_clean(v) for v in o]
    return o


def parse_include(out):
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
    runs = [r for r in check_runs or [] if isinstance(r, dict)]
    if not runs:
        return None
    if any(r.get("status") != "completed" for r in runs):
        return "pending"
    if any((r.get("conclusion") or "") in _FAIL for r in runs):
        return "failure"
    return "success"


def project_map(cfg, profiles=None):
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
    out = {}
    for name in profile_mod.list_projects():
        try:
            d = profile_mod.load(name)
        except Exception:
            continue
        if d.get("repo"):
            out[name] = d["repo"]
    return out


class GitHubPoller:
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
        self.poll_interval = 0.0
        self.failures = 0
        self.until = 0.0
        self.degraded_since = None
        self._warned = set()

    def _api(self, path, etag=None):
        argv = [self.gh, "api", "-i", "-H", "Accept: application/vnd.github+json"]
        if etag:
            argv += ["-H", "If-None-Match: " + etag]
        rc, out, _err = self.runner(argv + [path], GH_TIMEOUT)
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

    def poll_once(self):
        now = self.clock()
        if now < self.until:
            return {"skipped": "backoff", "emitted": 0}
        self.poll_interval = 0.0
        try:
            projects = project_map(self.cfg, self.projects_fn() if self.projects_fn else None)
        except Exception:
            projects = project_map(self.cfg)
        res = {"emitted": 0, "seeded": [], "errors": {}}
        error = None
        for repo in self.repos:
            try:
                res["emitted"] += self._poll_repo(repo, projects.get(repo), res)
            except GitHubError as e:
                if e.kind == "not_found":
                    if repo not in self._warned:
                        self._warned.add(repo)
                        log.warning("github: %s no existe o no es accesible (HTTP %s)", repo, e.status)
                    res["errors"][repo] = e.kind
                    continue
                error = e
                res["errors"][repo] = e.kind
                break
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
            if done or not seed:
                st["prs"] = prs
                self._set({key: db.jdump(st)})
        return emitted

    def _degrade(self, e, now):
        self.failures += 1
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
        left = self.until - self.clock()
        if left > 0:
            return left
        return max(self.interval, self.poll_interval)


def _default_runner(argv, timeout=GH_TIMEOUT):
    from .server import default_runner
    return default_runner(argv, timeout)


def check(cfg, which=None):
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
