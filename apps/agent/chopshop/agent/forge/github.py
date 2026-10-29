"""Adaptador de GitHub para `ForgeProvider`: el cliente `gh api -i` de `agent/github.py` (mismo `gh` autenticado, mismos
límites, ETag y limpieza de credenciales) más `actions/runs` para el rack.

- `poll_events(repo, project)`: delega en `GitHubPoller._poll_repo` (emite los `github.*` de siempre; cursores `gh_*`).
- `poll_runs(repo, branch)`: `GET /repos/{r}/actions/runs` con `If-None-Match`; la última respuesta se guarda en `meta`
  (`forge_etag:github:<repo>:runs[@rama]` + `forge_body:…`, ya normalizada) para que un 304 devuelva lo mismo sin gastar cuota.
- `repo_status(repo)`: `GET /repos/{r}` (rama por defecto, también con ETag) + runs de todas las ramas + runs de la rama por
  defecto -> `{default_branch, url, ci, active, pr_failing, error: None}`.
Los errores de `gh`/HTTP salen como `ProviderError` (404 no degrada: solo ese repo queda gris)."""
from urllib.parse import quote

from .. import db, github as gh
from . import base

RUNS_PAGE = 50                    # runs recientes de todas las ramas (en curso + PRs)
BRANCH_RUNS_PAGE = 20             # runs de la rama por defecto (CI)


def map_run(r):
    """Run de `actions/runs` -> run normalizado (base.py)."""
    return {"run_id": str(r.get("id")), "workflow": gh.clip(r.get("name") or r.get("display_title"), gh.MAX_TITLE),
            "status": r.get("status") if r.get("status") in base.RUN_STATUSES else ("completed" if r.get("conclusion")
                                                                                    else r.get("status") or "queued"),
            "conclusion": r.get("conclusion"), "event": r.get("event"),
            "actor": gh._login(r.get("triggering_actor")) or gh._login(r.get("actor")),
            "head_branch": r.get("head_branch"), "head_sha": r.get("head_sha"), "url": r.get("html_url"),
            "created_at": r.get("created_at"), "updated_at": r.get("updated_at")}


def _runs(data):
    runs = data.get("workflow_runs") if isinstance(data, dict) else None
    return [map_run(r) for r in runs or [] if isinstance(r, dict) and r.get("id") is not None]


def _repo(data):
    d = data if isinstance(data, dict) else {}
    return {"default_branch": d.get("default_branch"), "html_url": d.get("html_url")}


class GitHubProvider(base.ForgeProvider):
    name = "github"

    def __init__(self, conn, cfg, emit=None, runner=None, clock=None, projects_fn=None):
        kw = {"runner": runner, "projects_fn": projects_fn}
        if clock is not None:
            kw["clock"] = clock
        self.conn = conn
        self.client = gh.GitHubPoller(conn, cfg, emit or (lambda *a: None), **kw)

    def norm_repo(self, value):
        return gh.norm_repo(value)

    def repo_url(self, repo):
        return "https://github.com/%s" % repo

    def _api(self, path, etag=None):
        try:
            return self.client._api(path, etag)
        except gh.GitHubError as e:
            raise base.ProviderError(e.kind, e.status, e.wait, degraded=e.kind not in ("not_found",))

    def _cached(self, key, path, shrink):
        """GET con ETag. `shrink(datos)` de la última 200 vive en `meta` (`forge_body:<key>`) para servir el 304."""
        k_etag, k_body = "forge_etag:" + key, "forge_body:" + key
        body = self.client._get(k_body)
        status, headers, data = self._api(path, self.client._get(k_etag) if body is not None else None)
        if status == 304:
            return db.jload(body, None)
        out = shrink(data)
        self.client._set({k_etag: headers.get("etag"), k_body: db.jdump(out)})
        return out

    def poll_events(self, repo, project):
        return self.client._poll_repo(repo, project, {"seeded": []})

    def poll_runs(self, repo, branch=None):
        path = "/repos/%s/actions/runs?per_page=%d" % (repo, BRANCH_RUNS_PAGE if branch else RUNS_PAGE)
        if branch:
            path += "&branch=" + quote(branch, safe="")
        return self._cached("github:%s:runs%s" % (repo, "@" + branch if branch else ""), path, _runs) or []

    def repo_status(self, repo):
        meta = self._cached("github:%s:repo" % repo, "/repos/%s" % repo, _repo) or {}
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
