"""Interfaz agnóstica de proveedor y la luz del rack (pura).

Un run normalizado (lo que devuelve `poll_runs` y viaja en `forge.run.state` sin `origin`):
  {run_id, workflow, status (queued|in_progress|completed), conclusion, event, actor, head_branch, head_sha, url,
   created_at, updated_at}
Un estado de repo (lo que devuelve `repo_status`; `light()` lo resume):
  {default_branch, url, ci (None|success|failure|pending), active (runs en curso o en cola), pr_failing (PRs con CI rojo),
   error (None | rate_limit | forbidden | not_found | server_error | gh | http)}"""

LIGHT_GREEN, LIGHT_AMBER, LIGHT_RED, LIGHT_GRAY = "green", "amber", "red", "gray"
RUN_STATUSES = ("queued", "in_progress", "completed")
# conclusiones que ponen el CI en rojo (las mismas que `github._FAIL`); `skipped`/`neutral` no cuentan
FAIL = frozenset(("failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"))
PR_EVENTS = ("pull_request", "pull_request_target")


class ProviderError(Exception):
    """Fallo de un proveedor. `kind` como `github.GitHubError`; `degraded` = afecta a toda la cuenta (cuota, CLI caído):
    el rack deja de preguntarle en la pasada y pinta gris sus módulos. `wait` = s sugeridos antes de reintentar."""

    def __init__(self, kind, status=None, wait=None, degraded=True):
        super().__init__("%s%s" % (kind, " (HTTP %s)" % status if status else ""))
        self.kind, self.status, self.wait, self.degraded = kind, status, wait, degraded


class ForgeProvider:
    """Contrato de un adaptador. `name` es el `provider` de `rack.repos` y de los sobres `forge.*`."""

    name = None

    def norm_repo(self, value):
        """Texto del perfil/config -> slug canónico `dueño/repo` (o None si no vale)."""
        raise NotImplementedError

    def repo_url(self, repo):
        raise NotImplementedError

    def poll_events(self, repo, project):
        """Eventos nuevos del repo (issues, PRs, pushes) -> nº emitidos. El adaptador emite sus tipos propios
        (`github.*` mientras dure la compatibilidad)."""
        raise NotImplementedError

    def poll_runs(self, repo, branch=None):
        """Runs recientes (los más nuevos primero) normalizados; `branch` filtra por rama. Lanza ProviderError."""
        raise NotImplementedError

    def repo_status(self, repo):
        """Estado del repo para el rack (forma de arriba). Lanza ProviderError."""
        raise NotImplementedError

    def next_delay(self):
        """s mínimos hasta la próxima pasada que pide el proveedor (p. ej. `X-Poll-Interval`); 0 = sin preferencia."""
        return 0.0


# ---------------------------------------------------------------- puro

def latest_per(runs, key):
    """Último run (por `created_at`, si no por orden: los más nuevos primero) de cada clave `key(run)`."""
    out = {}
    for i, r in enumerate(runs or ()):
        k = key(r)
        stamp = (r.get("created_at") or "", -i)
        if k not in out or stamp > out[k][0]:
            out[k] = (stamp, r)
    return [r for _s, r in out.values()]


def branch_ci(runs, branch):
    """CI de `branch`: el último run COMPLETADO de cada workflow en esa rama. None si no hay ninguno;
    failure si alguno falló; success si no. (Los runs en curso no cuentan: eso es `active`.)"""
    done = [r for r in runs or () if r.get("head_branch") == branch and r.get("status") == "completed"]
    last = latest_per(done, lambda r: r.get("workflow") or "?")
    if not last:
        return None
    return "failure" if any((r.get("conclusion") or "") in FAIL for r in last) else "success"


def pr_failing(runs, default_branch):
    """Ramas (no la por defecto) cuyo último run de PR completado de algún workflow falló."""
    prs = [r for r in runs or () if r.get("event") in PR_EVENTS and r.get("head_branch") != default_branch]
    done = [r for r in prs if r.get("status") == "completed"]
    last = latest_per(done, lambda r: (r.get("head_branch"), r.get("workflow") or "?"))
    return sorted({r.get("head_branch") or "?" for r in last if (r.get("conclusion") or "") in FAIL})


def active(runs):
    """Runs en curso o en cola (cualquier rama)."""
    return [r for r in runs or () if r.get("status") in ("queued", "in_progress", "waiting", "requested", "pending")]


def light(status):
    """Luz del módulo. Prioridad: gris (sin datos o proveedor degradado) > rojo (CI de la rama por defecto fallido o un PR
    con CI rojo) > ámbar (runs en curso o en cola) > verde (CI de la rama por defecto en success). Rojo gana a ámbar: un
    arreglo en curso no tapa el fallo (el run en curso se ve igual en el módulo)."""
    if not isinstance(status, dict) or status.get("error"):
        return LIGHT_GRAY
    if status.get("ci") == "failure" or status.get("pr_failing"):
        return LIGHT_RED
    if status.get("active"):
        return LIGHT_AMBER
    if status.get("ci") == "success":
        return LIGHT_GREEN
    return LIGHT_GRAY
