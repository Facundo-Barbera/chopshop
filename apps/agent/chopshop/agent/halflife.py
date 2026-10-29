"""Semivida de hilos terminados (docs/plans/office-redesign.md §7, docs/agent-api.md «Semivida»).

- `opacity(phase, attention, ended_at, touched_at, half_life_s, now)`: función pura compartida con `HalfLife.swift` (tabla
  `tests/fixtures/office/halflife.json`). `exit_at(...)` = momento en que baja de `FADE_OUT`; `gone(...)` = ya bajó.
  Fechas en epoch o ISO-8601.
- Tocar (`touch(conn, thread_id, now)`) reinicia el reloj: guarda `touched_at` en `thread_touch` (tabla propia, se crea
  al usarla). `stamp(conn, event, body)` añade ese `touched_at` a los `task.state` que emite el agente, para que la app
  pinte la misma opacidad.
- `due(state, now, touches)`: ocupantes de escritorio y elementos del vestíbulo de la proyección v3 (`GET /state`) que ya
  se desvanecieron. Un hilo con `attention` (en su `task.state` o abierta en `projects[].attention`) nunca sale.
- `Fader`: el temporizador del agente. Cada `sweep()` emite `desk.released reason: faded` (con `desk: null` si sale del
  vestíbulo) por cada uno de `due`; `next_delay()` dice cuándo volver a mirar. Es solo visual: no archiva ni toca T3."""
import math
import threading
import time

from . import db, envelope

FADE_OUT = 0.1
FAILED_FACTOR = 2
DEFAULT_HALF_LIFE = 30 * 60      # s (igual que layout.DEFAULT_HALF_LIFE)
TERMINAL = ("done", "failed", "settled", "skipped")
MIN_DELAY, MAX_DELAY = 1.0, 30.0  # s entre barridos del temporizador

_LOG2_10 = math.log2(1 / FADE_OUT)


def _t(v):
    return None if v is None else envelope.epoch(v)


def _period(phase, half_life_s):
    t = float(half_life_s or DEFAULT_HALF_LIFE)
    return t * FAILED_FACTOR if phase == "failed" else t


def base(phase, attention, ended_at, touched_at):
    """Desde cuándo corre el reloj: `max(ended_at, touched_at)`; None si no se desvanece (activo, con atención o sin fechas)."""
    if phase not in TERMINAL or attention:
        return None
    ts = [x for x in (_t(ended_at), _t(touched_at)) if x is not None]
    return max(ts) if ts else None


def opacity(phase, attention, ended_at, touched_at, half_life_s, now):
    b = base(phase, attention, ended_at, touched_at)
    if b is None:
        return 1.0
    return 0.5 ** (max(0.0, float(now) - b) / _period(phase, half_life_s))


def exit_at(phase, attention, ended_at, touched_at, half_life_s):
    b = base(phase, attention, ended_at, touched_at)
    return None if b is None else b + _period(phase, half_life_s) * _LOG2_10


def gone(phase, attention, ended_at, touched_at, half_life_s, now):
    return opacity(phase, attention, ended_at, touched_at, half_life_s, now) < FADE_OUT


# ---------------------------------------------------------------- tocar

_SCHEMA = "CREATE TABLE IF NOT EXISTS thread_touch (thread_id TEXT PRIMARY KEY, touched_at REAL NOT NULL)"


def _ensure(conn):
    conn.execute(_SCHEMA)


def touch(conn, thread_id, now=None):
    """Reinicia el reloj del hilo. Devuelve `touched_at` (epoch)."""
    now = time.time() if now is None else float(now)
    with db.tx():
        _ensure(conn)
        conn.execute("INSERT OR REPLACE INTO thread_touch(thread_id, touched_at) VALUES(?,?)", (thread_id, now))
    return now


def touched_at(conn, thread_id):
    with db.tx():
        _ensure(conn)
        r = conn.execute("SELECT touched_at FROM thread_touch WHERE thread_id=?", (thread_id,)).fetchone()
    return r["touched_at"] if r else None


def touches(conn):
    """{thread_id: touched_at} de todos los hilos tocados."""
    with db.tx():
        _ensure(conn)
        return {r["thread_id"]: r["touched_at"] for r in conn.execute("SELECT thread_id, touched_at FROM thread_touch")}


def stamp(conn, event, body):
    """Cuerpo con `touched_at` (ISO) si el evento acaba en `task.state` de un hilo tocado y no lo trae ya."""
    if not isinstance(body, dict) or "touched_at" in body or envelope.LEGACY_MAP.get(event, event) != "task.state":
        return body
    tid = body.get("thread_id") or body.get("thread")
    t = touched_at(conn, tid) if tid else None
    return body if t is None else dict(body, touched_at=envelope.iso(t))


# ---------------------------------------------------------------- proyección v3 -> salidas

def _attention_open(project, thread_id):
    return any((a.get("subject") or {}).get("id") == thread_id for a in project.get("attention") or [])


def _occupants(state):
    """(project, desk_id | None, item) por ocupante de escritorio y por elemento del vestíbulo."""
    for p in state.get("projects") or []:
        for fl in ((p.get("office") or {}).get("floors") or []):
            for room in fl.get("rooms") or []:
                for d in room.get("desks") or []:
                    if d.get("occupant"):
                        yield p, d.get("id"), d["occupant"]
    byname = {p.get("name"): p for p in state.get("projects") or []}
    for it in state.get("lobby") or []:
        yield byname.get(it.get("project")) or {"name": it.get("project")}, None, it


def _exit(project, item, touches):
    """exit_at del elemento (None si no se desvanece). El `touched_at` local gana si es más nuevo que el del sobre."""
    tid = item.get("thread_id")
    if not tid or _attention_open(project, tid):
        return None
    tt = [x for x in (_t(item.get("touched_at")), (touches or {}).get(tid)) if x is not None]
    return exit_at(item.get("phase"), item.get("attention"), item.get("ended_at"), max(tt) if tt else None,
                   item.get("half_life_s"))


def schedule(state, touches=None):
    """[(exit_at, project, desk | None, thread_id)] de todo lo que se está desvaneciendo, del primero al último."""
    out = []
    for p, desk, it in _occupants(state):
        at = _exit(p, it, touches)
        if at is not None:
            out.append((at, p.get("name"), desk, it["thread_id"]))
    return sorted(out, key=lambda x: (x[0], x[1] or "", x[2] or "", x[3]))


def due(state, now, touches=None):
    """[(project, desk | None, thread_id)] que ya bajaron de FADE_OUT."""
    return [(proj, desk, tid) for at, proj, desk, tid in schedule(state, touches) if at <= now]


class Fader:
    """Temporizador de salida. `state_fn()` -> proyección v3; `emit_fn(type, project, body)` -> bus."""

    def __init__(self, conn, state_fn, emit_fn, clock=time.time):
        self.conn, self.state_fn, self.emit_fn, self.clock = conn, state_fn, emit_fn, clock
        self._sent = set()           # (project, desk, thread_id, exit_at): no repetir si la proyección aún no lo sacó
        self._next = None
        self._lock = threading.Lock()

    def sweep(self):
        """Emite `desk.released reason: faded` por cada salida vencida. Devuelve [(project, desk, thread_id)]."""
        with self._lock:
            now, tt = self.clock(), touches(self.conn)
            plan = schedule(self.state_fn(), tt)
            out, live = [], set()
            for at, proj, desk, tid in plan:
                key = (proj, desk, tid, round(at, 3))
                live.add(key)
                if at > now or key in self._sent:
                    continue
                self.emit_fn("desk.released", proj, {"desk": desk, "thread_id": tid, "reason": "faded"})
                self._sent.add(key)
                out.append((proj, desk, tid))
            self._sent &= live
            pending = [at for at, proj, desk, tid in plan if at > now]
            self._next = min(pending) if pending else None
            return out

    def next_delay(self):
        """Segundos hasta el próximo barrido (entre MIN_DELAY y MAX_DELAY: un toque o un hilo nuevo pueden adelantarlo)."""
        if self._next is None:
            return MAX_DELAY
        return min(MAX_DELAY, max(MIN_DELAY, self._next - self.clock()))
