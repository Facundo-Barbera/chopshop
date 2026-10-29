"""chopshop-agent: servicio headless por máquina. API HTTP por Tailscale, SQLite, métricas por app/proyecto,
hilos de T3 y eventos/webhooks. Solo observa y resume: los worktrees, servers y comandos son cosa de T3."""
from .. import __version__  # noqa: F401  (única fuente: chopshop/__init__.py)

API_VERSION = 2           # `/health`, `/state`, `/stream`, `/pair` (única fuente; projection.py la reexporta)
SNAPSHOT_API_VERSION = 1  # `/snapshot` conserva su forma v1 (el cliente web avisa si ve una API más nueva)
