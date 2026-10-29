"""Alias de compatibilidad: el adaptador de GitHub vive en `agent/forge/github.py` (docs/plans/office-redesign.md §4).
`from chopshop.agent import github` sigue dando el mismo módulo (mismo objeto: los parches de los tests valen igual)."""
import sys

from .forge import github as _impl

sys.modules[__name__] = _impl
