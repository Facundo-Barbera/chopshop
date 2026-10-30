from typing import Optional

LIGHT_GREEN, LIGHT_AMBER, LIGHT_RED, LIGHT_GRAY = "green", "amber", "red", "gray"
RUN_STATUSES = ("queued", "in_progress", "completed")
FAIL = frozenset(("failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"))
PR_EVENTS = ("pull_request", "pull_request_target")


class ProviderError(Exception):
    def __init__(self, kind, status=None, wait=None, degraded=True):
        super().__init__("%s%s" % (kind, " (HTTP %s)" % status if status else ""))
        self.kind, self.status, self.wait, self.degraded = kind, status, wait, degraded


class ForgeProvider:
    name: Optional[str] = None

    def norm_repo(self, value):
        raise NotImplementedError

    def repo_url(self, repo):
        raise NotImplementedError

    def poll_events(self, repo, project):
        raise NotImplementedError

    def poll_runs(self, repo, branch=None):
        raise NotImplementedError

    def repo_status(self, repo):
        raise NotImplementedError

    def next_delay(self):
        return 0.0


def latest_per(runs, key):
    out = {}
    for i, r in enumerate(runs or ()):
        k = key(r)
        stamp = (r.get("created_at") or "", -i)
        if k not in out or stamp > out[k][0]:
            out[k] = (stamp, r)
    return [r for _s, r in out.values()]


def branch_ci(runs, branch):
    done = [r for r in runs or () if r.get("head_branch") == branch and r.get("status") == "completed"]
    last = latest_per(done, lambda r: r.get("workflow") or "?")
    if not last:
        return None
    return "failure" if any((r.get("conclusion") or "") in FAIL for r in last) else "success"


def pr_failing(runs, default_branch):
    prs = [r for r in runs or () if r.get("event") in PR_EVENTS and r.get("head_branch") != default_branch]
    done = [r for r in prs if r.get("status") == "completed"]
    last = latest_per(done, lambda r: (r.get("head_branch"), r.get("workflow") or "?"))
    return sorted({r.get("head_branch") or "?" for r in last if (r.get("conclusion") or "") in FAIL})


def active(runs):
    return [r for r in runs or () if r.get("status") in ("queued", "in_progress", "waiting", "requested", "pending")]


def light(status):
    if not isinstance(status, dict) or status.get("error"):
        return LIGHT_GRAY
    if status.get("ci") == "failure" or status.get("pr_failing"):
        return LIGHT_RED
    if status.get("active"):
        return LIGHT_AMBER
    if status.get("ci") == "success":
        return LIGHT_GREEN
    return LIGHT_GRAY
