"""Estado propio mínimo: lotes, tareas y suscripciones en un JSON local (~/.chopshop/state.json, 0600)."""
import contextlib
import fcntl
import json
import os
import time

from . import home


def _empty():
    return {"version": 1, "counter": 0, "batches": {}, "subscriptions": {}}


@contextlib.contextmanager
def locked():
    """Carga el estado con lock exclusivo; guarda al salir sin error."""
    home.ensure_home()
    lock = open(os.path.join(home.home(), "state.lock"), "a")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        p = home.state_path()
        st = _empty()
        if os.path.exists(p):
            with open(p) as f:
                st.update(json.load(f))
        yield st
        tmp = p + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(st, f, indent=1, ensure_ascii=False)
        os.replace(tmp, p)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def read():
    p = home.state_path()
    if not os.path.exists(p):
        return _empty()
    with open(p) as f:
        st = _empty()
        st.update(json.load(f))
        return st


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def new_batch_id(st):
    st["counter"] += 1
    return "b-%04d" % st["counter"]
