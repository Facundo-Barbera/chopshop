"""Semivida de hilos terminados (docs/plans/office-redesign.md §7, docs/agent-api.md «Semivida»). Puro y compartido con la
app (`HalfLife.swift`, misma tabla: tests/fixtures/office/halflife.json).

- `opacity(phase, attention, ended_at, touched_at, half_life_s, now)`: 1.0 si la fase no es terminal, si hay `attention` o si
  no hay fechas; si no, `0.5 ^ (t / T)` con `t = max(0, now - max(ended_at, touched_at))` y `T = half_life_s` (× 2 si `failed`).
- `exit_at(...)`: instante en que la opacidad baja de `FADE_OUT` (`base + T·log2(10)`); None si no se desvanece.
- `gone(...)`: `opacity < FADE_OUT` (el agente lo usa para emitir `desk.released reason: faded`).
Las fechas pueden ser epoch (s) o ISO-8601."""
import math

from . import envelope

TERMINAL = ("done", "failed", "settled", "skipped")
FADE_OUT = 0.1
FAILED_FACTOR = 2
DEFAULT_HALF_LIFE = 30 * 60


def _t(v):
    return None if v is None else envelope.epoch(v)


def _params(phase, attention, ended_at, touched_at, half_life_s):
    """(base, T) o None si no se desvanece."""
    if phase not in TERMINAL or attention:
        return None
    dates = [x for x in (_t(ended_at), _t(touched_at)) if x is not None]
    if not dates:
        return None
    t_half = float(half_life_s or DEFAULT_HALF_LIFE) * (FAILED_FACTOR if phase == "failed" else 1)
    return max(dates), t_half


def opacity(phase, attention, ended_at, touched_at, half_life_s, now):
    p = _params(phase, attention, ended_at, touched_at, half_life_s)
    if p is None:
        return 1.0
    base, t_half = p
    return 0.5 ** (max(0.0, float(now) - base) / t_half)


def exit_at(phase, attention, ended_at, touched_at, half_life_s):
    p = _params(phase, attention, ended_at, touched_at, half_life_s)
    if p is None:
        return None
    base, t_half = p
    return base + t_half * math.log2(1 / FADE_OUT)


def gone(phase, attention, ended_at, touched_at, half_life_s, now):
    return opacity(phase, attention, ended_at, touched_at, half_life_s, now) < FADE_OUT


def fading(phase, attention):
    """El ocupante está en semivida (terminal y sin atención): su escritorio se puede heredar."""
    return phase in TERMINAL and not attention
