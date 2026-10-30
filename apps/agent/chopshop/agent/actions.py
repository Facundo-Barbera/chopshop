import calendar
import logging
import os
import re
import time

from . import db, github, layout
from .forge import github as forge_gh

log = logging.getLogger("chopshop.agent.actions")

PROVIDER = "github"
KEEP_DONE = 5
KEEP_ROWS = 100
DISPATCH_WINDOW = 600.0
DISPATCH_LOOKBACK = 86400.0
THREAD_LOOKBACK = 3 * 86400.0
DEFAULT_BRANCHES = ("main", "master")
SHA_EVENTS = ("push", "pull_request", "pull_request_target", "merge_group")

SCHEMA = """
CREATE TABLE IF NOT EXISTS forge_runs (
  provider TEXT NOT NULL, repo TEXT NOT NULL, run_id TEXT NOT NULL, workflow TEXT, status TEXT, conclusion TEXT,
  event TEXT, actor TEXT, head_branch TEXT, head_sha TEXT, url TEXT, origin TEXT, updated REAL, extra TEXT,
  PRIMARY KEY (provider, repo, run_id));
"""


def ensure_schema(conn):
    with db.tx():
        conn.executescript(SCHEMA)


def _iso_epoch(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        return float(calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")))
    except ValueError:
        return None


def map_run(run, repo, project=None):
    if not isinstance(run, dict) or run.get("id") is None:
        return None
    path = run.get("path") or ""
    return {
        "provider": PROVIDER, "repo": repo, "project": project, "run_id": str(run["id"]),
        "workflow": github.clip(run.get("name") or os.path.basename(path) or None, github.MAX_TITLE),
        "workflow_path": path or None, "workflow_id": str(run["workflow_id"]) if run.get("workflow_id") else None,
        "title": github.clip(run.get("display_title"), github.MAX_TITLE),
        "status": run.get("status") or "queued", "conclusion": run.get("conclusion"), "event": run.get("event"),
        "actor": github._login(run.get("actor")), "triggering_actor": github._login(run.get("triggering_actor")),
        "head_branch": run.get("head_branch"), "head_sha": run.get("head_sha"), "url": run.get("html_url"),
        "attempt": github._int(run.get("run_attempt"), 1), "created_at": run.get("created_at"),
        "updated_at": run.get("updated_at"),
    }


def origin(kind, id=None, label=None):
    return {"kind": kind, "id": id, "label": label}


def _thread_label(t):
    role, desk = t.get("role"), t.get("desk")
    if role and desk:
        return "%s · %s" % (role, desk)
    return role or t.get("title") or t.get("thread_id")


def _match_thread(run, threads, default_branch, project):
    branch, sha = run.get("head_branch"), run.get("head_sha")
    defaults = set(DEFAULT_BRANCHES) | ({default_branch} if default_branch else set())
    hits = []
    if branch and branch not in defaults and run.get("event") != "schedule":
        hits = [t for t in threads if t.get("branch") == branch]
    if not hits and sha and run.get("event") in SHA_EVENTS:
        hits = [t for t in threads if t.get("head_sha") and t["head_sha"] == sha]
    if not hits:
        return None
    hits.sort(key=lambda t: (t.get("project") != project, bool(t.get("settled")), -(t.get("last_seen") or 0)))
    return hits[0]


def _workflow_matches(run, wf):
    if not wf:
        return False
    wf = str(wf)
    path = run.get("workflow_path") or ""
    return wf in (run.get("workflow"), path, os.path.basename(path), run.get("workflow_id"))


def _match_dispatch(run, dispatches, claimed):
    if run.get("event") != "workflow_dispatch":
        return None
    title = run.get("title") or ""
    for d in dispatches:
        if d.get("nonce") and d["nonce"] in title:
            return d
    created = _iso_epoch(run.get("created_at"))
    if created is None:
        return None
    for d in sorted(dispatches, key=lambda d: d.get("ts") or 0):
        key = d.get("nonce") or d.get("id")
        ref = re.sub(r"^refs/heads/", "", d.get("ref") or "")
        if key in claimed or ref != run.get("head_branch") or not _workflow_matches(run, d.get("workflow")):
            continue
        if (d.get("ts") or 0) - 5 <= created <= (d.get("ts") or 0) + DISPATCH_WINDOW:
            return d
    return None


def attribute(run, threads=(), dispatches=(), actors=None, default_branch=None, claimed=(), project=None):
    t = _match_thread(run, list(threads), default_branch, project)
    if t:
        return origin("thread", t["thread_id"], _thread_label(t))
    d = _match_dispatch(run, list(dispatches), set(claimed))
    if d:
        name = d.get("automation") or "automation"
        return origin("automation", d.get("nonce") or d.get("id"), "%s · %s" % (name, d.get("workflow")))
    actors = actors or {}
    who = [a for a in (run.get("triggering_actor"), run.get("actor")) if a]
    for a in who if run.get("event") != "schedule" else ():
        decl = actors.get(a) or {}
        if (decl and decl.get("kind", "bot") == "bot") or a.endswith("[bot]"):
            return origin("bot", a, decl.get("label") or a)
    if run.get("event") == "schedule":
        return origin("schedule", run.get("workflow_path") or run.get("workflow"), run.get("workflow"))
    if who:
        decl = actors.get(who[0]) or {}
        return origin("human", who[0], decl.get("label") or who[0])
    return origin("unknown")


def published(runs):
    done = sorted((r for r in runs if r.get("status") == "completed"),
                  key=lambda r: (r.get("updated_at") or "", r["run_id"]), reverse=True)
    return {r["run_id"] for r in runs if r.get("status") != "completed"} | {r["run_id"] for r in done[:KEEP_DONE]}


def repos_for(cfg, profiles):
    out, seen = [], {}
    for name, prof in sorted((profiles or {}).items()):
        for e in layout.rack_repos(prof or {}):
            n = github.norm_repo(e["repo"])
            if e["provider"] == PROVIDER and n and n not in seen:
                seen[n] = len(out)
                out.append((e["repo"], e.get("project") or name, n))
    pmap = github.project_map(cfg, {k: (v or {}).get("repo") for k, v in (profiles or {}).items()})
    for r in (cfg.get("github") or {}).get("repos") or []:
        n = github.norm_repo(r)
        if n and n not in seen:
            seen[n] = len(out)
            out.append((n, pmap.get(n), n))
    return out


def load_profiles():
    out = {}
    for name in github.profile_mod.list_projects():
        try:
            out[name] = github.profile_mod.load(name)
        except Exception:
            continue
    return out


class ActionsPoller(github.GitHubPoller):
    def __init__(self, conn, cfg, emit, runner=None, clock=time.time, profiles_fn=load_profiles, head_fn=None, feed=None):
        super().__init__(conn, cfg, emit, runner=runner, clock=clock, projects_fn=None)
        self.profiles_fn = profiles_fn
        self.head_fn = head_fn or self._git_head
        self.feed = feed or forge_gh.RunsFeed(clock=clock)
        ensure_schema(conn)

    def _emit(self, event, project, body, severity=None):
        self.emit(event, project, github._clean(body), severity)

    def _degrade(self, e, now):
        self.failures += 1
        wait = min(github.MAX_BACKOFF, self.interval * (2 ** min(self.failures - 1, 6)))
        if e.wait:
            wait = min(max(wait, float(e.wait)), 3600.0)
        self.until = now + wait
        if self.degraded_since is None:
            self.degraded_since = now
            log.warning("actions: %s; reintento en %ds", e, wait)

    def _recover(self, now):
        if self.degraded_since is not None:
            log.info("actions: recuperado tras %ds", int(now - self.degraded_since))
        self.failures, self.until, self.degraded_since = 0, 0.0, None

    def _git_head(self, worktree):
        if not worktree or not os.path.isdir(worktree):
            return None
        rc, out, _err = self.runner(["git", "-C", worktree, "rev-parse", "HEAD"], 5)
        sha = (out or "").strip()
        return sha if rc == 0 and re.match(r"^[0-9a-f]{40}$", sha) else None

    def _threads(self, now):
        try:
            rows = db.rows(self.conn.execute(
                "SELECT * FROM t3_threads WHERE (branch IS NOT NULL OR worktree IS NOT NULL) AND (settled=0 OR last_seen>=?)",
                (now - THREAD_LOOKBACK,)))
        except Exception:
            return []
        desks = {}
        try:
            for r in self.conn.execute("SELECT desk_id, thread_id FROM desk_occupancy WHERE until IS NULL"):
                desks[r["thread_id"]] = r["desk_id"]
        except Exception:
            pass
        for t in rows:
            t["desk"] = desks.get(t["thread_id"])
            if not t.get("role"):
                t["role"] = (db.jload(t.get("extra"), {}) or {}).get("role") if t.get("extra") else None
            t["head_sha"] = None
        return rows

    def _with_heads(self, threads):
        for t in threads:
            if t.get("worktree") and not t.get("settled") and t["head_sha"] is None:
                try:
                    t["head_sha"] = self.head_fn(t["worktree"]) or ""
                except Exception:
                    t["head_sha"] = ""
        return threads

    def _dispatches(self, now):
        out = []
        try:
            cur = self.conn.execute("SELECT id, ts, body, subject FROM events WHERE type='forge.dispatch' AND ts>=? ORDER BY seq",
                                    (now - DISPATCH_LOOKBACK,))
        except Exception:
            return out
        for r in cur:
            b = db.jload(r["body"], {}) or {}
            s = db.jload(r["subject"], {}) or {}
            nonce = b.get("nonce") or (b.get("inputs") or {}).get("chopshop_nonce")
            out.append({"id": r["id"], "ts": r["ts"], "provider": b.get("provider") or PROVIDER,
                        "repo": github.norm_repo(b.get("repo")), "workflow": b.get("workflow"), "ref": b.get("ref"),
                        "nonce": nonce, "automation": b.get("automation") or (s.get("id") if s.get("kind") == "automation" else None)})
        return out

    def _stored(self, repo):
        with db.tx():
            rows = db.rows(self.conn.execute("SELECT * FROM forge_runs WHERE provider=? AND repo=?", (PROVIDER, repo)))
        out = {}
        for r in rows:
            body = db.jload(r.get("extra"), {}) or {}
            body["origin"] = db.jload(r.get("origin"), None)
            out[r["run_id"]] = body
        return out

    def _store(self, repo, bodies):
        with db.tx():
            for b in bodies:
                self.conn.execute(
                    "INSERT OR REPLACE INTO forge_runs(provider, repo, run_id, workflow, status, conclusion, event, actor,"
                    " head_branch, head_sha, url, origin, updated, extra) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (PROVIDER, repo, b["run_id"], b.get("workflow"), b.get("status"), b.get("conclusion"), b.get("event"),
                     b.get("actor"), b.get("head_branch"), b.get("head_sha"), b.get("url"), db.jdump(b.get("origin")),
                     self.clock(), db.jdump({k: v for k, v in b.items() if k != "origin"})))
            self.conn.execute(
                "DELETE FROM forge_runs WHERE provider=? AND repo=? AND run_id NOT IN (SELECT run_id FROM forge_runs"
                " WHERE provider=? AND repo=? ORDER BY CAST(run_id AS INTEGER) DESC LIMIT ?)",
                (PROVIDER, repo, PROVIDER, repo, KEEP_ROWS))

    def poll_once(self):
        now = self.clock()
        if now < self.until:
            return {"skipped": "backoff", "emitted": 0}
        self.poll_interval = 0.0
        try:
            profiles = self.profiles_fn() if self.profiles_fn else {}
        except Exception:
            profiles = {}
        actors = {}
        for prof in profiles.values():
            actors.update(layout.rack_actors(prof or {}))
        ctx = {"threads": self._threads(now), "dispatches": self._dispatches(now), "actors": actors, "heads": False}
        res = {"emitted": 0, "errors": {}}
        error = None
        for repo, project, api in repos_for(self.cfg, profiles):
            try:
                res["emitted"] += self._poll_repo(repo, project, api, ctx)
            except github.GitHubError as e:
                if e.kind == "not_found":
                    if api not in self._warned:
                        self._warned.add(api)
                        log.warning("actions: %s no existe o no es accesible (HTTP %s)", api, e.status)
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

    def _poll_repo(self, repo, project, api, ctx):
        k_seen = "actions_seen:%s:%s" % (PROVIDER, api)
        stored = self._stored(repo)
        raw, version = self.feed.runs(self, api)
        if stored and version is not None and version == self._get(k_seen):
            fresh = [dict(b) for b in stored.values() if b.get("status") != "completed"]
        else:
            fresh = [b for b in (map_run(r, repo, project) for r in raw) if b]
        if not fresh:
            self._set({k_seen: version})
            return 0
        default = self.feed.repo(self, api).get("default_branch")
        if not ctx["heads"] and any(b.get("event") in SHA_EVENTS for b in fresh):
            self._with_heads(ctx["threads"])
            ctx["heads"] = True
        dispatches = [d for d in ctx["dispatches"] if d["provider"] == PROVIDER and d["repo"] == github.norm_repo(api)]
        claimed = {(b.get("origin") or {}).get("id") for rid, b in stored.items()
                   if (b.get("origin") or {}).get("kind") == "automation"}
        show = published(fresh + [b for rid, b in stored.items() if rid not in {f["run_id"] for f in fresh}])
        emitted, changed = 0, []
        for b in sorted(fresh, key=lambda b: (b.get("created_at") or "", b["run_id"])):
            old = stored.get(b["run_id"]) or {}
            prev = old.get("origin") or {}
            if prev.get("kind") in ("thread", "automation"):
                b["origin"] = prev
            else:
                b["origin"] = attribute(b, ctx["threads"], dispatches, ctx["actors"], default,
                                        claimed - {prev.get("id")}, project)
            if b["origin"]["kind"] == "automation":
                claimed.add(b["origin"]["id"])
            if all(old.get(k) == b.get(k) for k in ("status", "conclusion", "origin", "updated_at", "attempt")):
                continue
            changed.append(b)
            if b["run_id"] in show:
                failed = b.get("status") == "completed" and (b.get("conclusion") or "") in github._FAIL
                self._emit("forge.run.state", project, b, "warn" if failed else None)
                emitted += 1
        if changed:
            self._store(repo, changed)
        self._set({k_seen: version})
        return emitted
