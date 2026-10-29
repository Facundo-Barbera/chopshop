"""Estado explícito de los hilos de fondo del agente para la sala de máquinas: sobre `listener.state`.

`Listeners.report(nombre, estado, error, backoff_s)` se llama tras cada ciclo de un hilo. Emite solo cuando cambia el
estado o el error, y como latido cada `HEARTBEAT` s (para que `last_ok`/`last_cycle` no queden viejos sin llenar el bus).
Nombres públicos (`NAMES`): los hilos internos del servicio se traducen (`t3` -> `t3watch`, `github` -> `forge`, `sampler`
-> `collector`); los que no están en la tabla no se publican."""
import threading
import time

from . import envelope

HEARTBEAT = 3600.0
NAMES = {"t3": "t3watch", "github": "forge", "automations": "automations", "engine": "engine", "sampler": "collector",
         "webhooks": "webhooks", "office": "office"}
STATES = envelope.HEALTH


class Listeners:
    def __init__(self, emit, clock=time.time, heartbeat=HEARTBEAT):
        self.emit, self.clock, self.heartbeat = emit, clock, heartbeat
        self._lock = threading.Lock()
        self._st = {}                 # nombre público -> {state, error, last_ok, emitted}

    def report(self, thread, state="ok", error=None, backoff_s=0):
        """Ciclo terminado del hilo `thread` (nombre interno o público). Devuelve el seq emitido o None."""
        name = NAMES.get(thread, thread if thread in NAMES.values() else None)
        if name is None:
            return None
        state = state if state in STATES else "degraded"
        error = str(error)[:200] if error else None
        now = self.clock()
        with self._lock:
            prev = self._st.get(name) or {}
            last_ok = now if state == "ok" else prev.get("last_ok")
            changed = prev.get("state") != state or prev.get("error") != error
            due = changed or now - (prev.get("emitted") or 0) >= self.heartbeat
            self._st[name] = {"state": state, "error": error, "last_ok": last_ok,
                              "emitted": now if due else prev.get("emitted")}
        if not due:
            return None
        return self.emit("listener.state", None, {
            "name": name, "state": state, "last_ok": envelope.iso(last_ok) if last_ok else None,
            "last_cycle": envelope.iso(now), "backoff_s": int(max(0, backoff_s or 0)), "error": error})

    def snapshot(self):
        with self._lock:
            return {k: dict(v) for k, v in self._st.items()}
