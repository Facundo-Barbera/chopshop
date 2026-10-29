"""Interfaz común de los proveedores de forja (GitHub hoy; GitLab/Gitea/Forgejo después con su adaptador).

El rack (`forge/__init__.py`) y la proyección solo hablan de `provider` + `repo` + `runs`: un adaptador nuevo implementa
`ForgeProvider` y no toca nada más. Los runs que devuelve `poll_runs` ya vienen normalizados (ver `RUN_FIELDS`)."""

RUN_STATUSES = ("queued", "in_progress", "completed")
RUN_FIELDS = ("run_id", "workflow", "workflow_path", "title", "status", "conclusion", "event", "actor", "triggering_actor",
              "head_branch", "head_sha", "url", "created_at", "updated_at")


class ForgeError(Exception):
    """Fallo de un proveedor. `kind`: rate_limit | forbidden | server_error | not_found | gh | http | unsupported."""

    def __init__(self, kind, status=None, wait=None):
        super().__init__("%s%s" % (kind, " (HTTP %s)" % status if status else ""))
        self.kind, self.status, self.wait = kind, status, wait


class ForgeProvider:
    """Lo que el rack necesita de un proveedor. Ningún método lanza salvo `ForgeError`."""

    name = "?"

    def poll_events(self):
        """Una pasada de eventos del proveedor (emite sus tipos propios, p. ej. `github.*`)."""
        return {}

    def poll_runs(self, repo):
        """Runs recientes de `repo` normalizados (`RUN_FIELDS`), el más nuevo primero; None si no cambió desde la última vez."""
        raise NotImplementedError

    def repo_status(self, repo):
        """{default_branch, url, pr_ci: [ci de cada PR abierto]} (lo que haga falta para la luz)."""
        raise NotImplementedError

    def in_backoff(self):
        return False

    def degrade(self, err):
        """Registra un fallo de cuenta (cuota, CLI caído): el proveedor decide el backoff."""

    def recover(self):
        """Pasada completa sin fallos."""

    def error(self):
        """Motivo corto del último fallo vigente (None si está bien)."""
        return None
