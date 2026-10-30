import threading
import time
from urllib.parse import quote

from .. import db
from .. import github as gh
from . import base

RUNS_PAGE = 50
BRANCH_RUNS_PAGE = 20


RUN_KEYS = ("id", "name", "path", "workflow_id", "display_title", "status", "conclusion", "event", "head_branch",
            "head_sha", "html_url", "run_attempt", "created_at", "updated_at")


def map_run(r):
    return {"run_id": str(r.get("id")), "workflow": gh.clip(r.get("name") or r.get("display_title"), gh.MAX_TITLE),
            "status": r.get("status") if r.get("status") in base.RUN_STATUSES else ("completed" if r.get("conclusion")
                                                                                    else r.get("status") or "queued"),
            "conclusion": r.get("conclusion"), "event": r.get("event"),
            "actor": gh._login(r.get("triggering_actor")) or gh._login(r.get("actor")),
            "head_branch": r.get("head_branch"), "head_sha": r.get("head_sha"), "url": r.get("html_url"),
            "created_at": r.get("created_at"), "updated_at": r.get("updated_at")}


def trim_runs(data):
    runs = data.get("workflow_runs") if isinstance(data, dict) else None
    out = []
    for r in runs or []:
        if isinstance(r, dict) and r.get("id") is not None:
            t = {k: r.get(k) for k in RUN_KEYS}
            t["actor"] = {"login": gh._login(r.get("actor"))} if gh._login(r.get("actor")) else None
            t["triggering_actor"] = ({"login": gh._login(r.get("triggering_actor"))}
                                     if gh._login(r.get("triggering_actor")) else None)
            out.append(t)
    return out


def _runs(raw):
    return [map_run(r) for r in raw or [] if isinstance(r, dict) and r.get("id") is not None]


def _repo(data):
    d = data if isinstance(data, dict) else {}
    return {"default_branch": d.get("default_branch"), "html_url": d.get("html_url")}


class RunsFeed:
    def __init__(self, clock=time.time, max_age=30.0):
        self.clock, self.max_age = clock, float(max_age)
        self.memo = {}
        self._lock = threading.Lock()
        self._locks = {}

    def _key_lock(self, key):
        with self._lock:
            return self._locks.setdefault(key, threading.Lock())

    def fetch(self, client, key, path, shrink):
        with self._key_lock(key):
            now = self.clock()
            hit = self.memo.get(key)
            if hit and 0 <= now - hit[0] < self.max_age:
                return hit[2], hit[1]
            k_etag, k_body = "forge_etag:" + key, "forge_body:" + key
            body = client._get(k_body)
            etag = client._get(k_etag) if body is not None else None
            status, headers, data = client._api(path, etag)
            if status == 304:
                out = db.jload(body, None)
            else:
                out, etag = shrink(data), headers.get("etag")
                client._set({k_etag: etag, k_body: db.jdump(out)})
            self.memo[key] = (now, etag, out)
            return out, etag

    def runs(self, client, repo, branch=None):
        path = "/repos/%s/actions/runs?per_page=%d" % (repo, BRANCH_RUNS_PAGE if branch else RUNS_PAGE)
        if branch:
            path += "&branch=" + quote(branch, safe="")
        key = "github:%s:runs/raw%s" % (repo, "@" + branch if branch else "")
        out, version = self.fetch(client, key, path, trim_runs)
        return out or [], version

    def repo(self, client, repo):
        out, _v = self.fetch(client, "github:%s:repo" % repo, "/repos/%s" % repo, _repo)
        return out or {}


class GitHubProvider(base.ForgeProvider):
    name = "github"

    def __init__(self, conn, cfg, emit=None, runner=None, clock=None, projects_fn=None, feed=None):
        kw = {"runner": runner, "projects_fn": projects_fn}
        if clock is not None:
            kw["clock"] = clock
        self.conn = conn
        self.client = gh.GitHubPoller(conn, cfg, emit or (lambda *a: None), **kw)
        self.feed = feed or RunsFeed(clock=self.client.clock)

    def norm_repo(self, value):
        return gh.norm_repo(value)

    def repo_url(self, repo):
        return "https://github.com/%s" % repo

    def _feed(self, method, *args):
        try:
            return getattr(self.feed, method)(self.client, *args)
        except gh.GitHubError as e:
            raise base.ProviderError(e.kind, e.status, e.wait, degraded=e.kind not in ("not_found",))

    def poll_events(self, repo, project):
        return self.client._poll_repo(repo, project, {"seeded": []})

    def poll_runs(self, repo, branch=None):
        return _runs(self._feed("runs", repo, branch)[0])

    def repo_status(self, repo):
        meta = self._feed("repo", repo)
        branch = meta.get("default_branch")
        runs = self.poll_runs(repo)
        mine = self.poll_runs(repo, branch) if branch else []
        seen = {r["run_id"] for r in runs}
        runs = runs + [r for r in mine if r["run_id"] not in seen]
        ci = base.branch_ci(runs, branch) if branch else None
        act = base.active(runs)
        if ci is None and any(r.get("head_branch") == branch for r in act):
            ci = "pending"
        return {"default_branch": branch, "url": meta.get("html_url") or self.repo_url(repo), "ci": ci, "active": len(act), "pr_failing": base.pr_failing(runs, branch),
                "runs": runs, "error": None}

    def next_delay(self):
        return self.client.poll_interval
