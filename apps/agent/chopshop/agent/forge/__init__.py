"""Forjas (proveedores de repos) detrás de una interfaz común (docs/plans/office-redesign.md §4, fase 4).

- `base.ForgeProvider`: lo que la proyección y el rack necesitan de un proveedor (`poll_events`, `poll_runs`,
  `repo_status`), sin saber cuál es. `base.light(status)` = luz del módulo del rack (pura).
- `github.GitHubProvider`: adaptador de GitHub (`gh api` con ETag; reutiliza el cliente de `agent/github.py`).
- `rack.Rack`: hilo `forge` del agente; por cada repo del rack pide `repo_status` y emite `forge.repo.state` al cambiar.
GitLab/Gitea/Forgejo se suman con su adaptador registrándolo en `PROVIDERS` sin tocar el rack, la proyección ni la app."""
from . import base, github

PROVIDERS = {"github": github.GitHubProvider}


def make(name, conn, cfg, **kw):
    """Instancia el proveedor `name` (KeyError si no hay adaptador)."""
    return PROVIDERS[name](conn, cfg, **kw)


__all__ = ["PROVIDERS", "base", "github", "make"]
