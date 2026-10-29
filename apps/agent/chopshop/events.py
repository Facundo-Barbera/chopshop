"""Paso 3: eventos. Se registran en ~/.chopshop/events.jsonl y se mandan por POST a webhooks.
La URL del webhook se lee SIEMPRE de un archivo local (--webhook-file); nunca se imprime ni se registra.

El motor (engine/reactions/graph) emite con `send(...)`, que usa la función inyectada con `using(emit_fn)` (misma firma que
`emit`) o, por defecto, `emit`. Dentro del agente se inyecta el puente al bus (`agent/service.py::engine_emitter`)."""
import contextlib
import contextvars
import json
import os
import urllib.error
import urllib.request

from . import home, state


def _read_url(path):
    with open(os.path.expanduser(path)) as f:
        url = f.read().strip()
    if not url.startswith(("http://", "https://")):
        raise ValueError("el archivo no contiene una URL http(s)")
    return url


def post(webhook_file, payload, timeout=10):
    """Devuelve (ok, motivo). El motivo nunca incluye la URL."""
    try:
        url = _read_url(webhook_file)
    except (OSError, ValueError) as e:
        return False, "archivo de webhook ilegible (%s)" % type(e).__name__
    req = urllib.request.Request(url, data=json.dumps(payload, ensure_ascii=False).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "chopshop/0.1"},
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return (200 <= r.status < 300), "HTTP %d" % r.status
    except urllib.error.HTTPError as e:
        return False, "HTTP %d" % e.code
    except Exception as e:  # noqa: BLE001 - el mensaje de urllib puede traer la URL: solo el tipo
        return False, type(e).__name__


def recipients(st, event, project, adhoc_files, only=None):
    """(nombre, archivo) de cada suscripción que aplica + los --webhook-file ad hoc.
    `only` (lista de nombres) restringe a esas suscripciones, sin filtrar por evento (lo usan las reacciones)."""
    out = []
    if only is not None:
        return [(n, st["subscriptions"][n]["webhook_file"]) for n in only if n in st.get("subscriptions", {})]
    for name, s in st.get("subscriptions", {}).items():
        if s.get("project") in ("*", project) and event in s.get("events", []):
            out.append((name, s["webhook_file"]))
    for i, f in enumerate(adhoc_files or []):
        out.append(("adhoc%d" % (i + 1), f))
    return out


def emit(st, event, project, body, adhoc_files=None, log=True, only=None, ts=None):
    """Registra y entrega. Devuelve (entregado_a_todos, hubo_destinatarios, resultados). `ts` = ISO (por defecto ahora)."""
    payload = {"event": event, "project": project, "ts": ts or state.now()}
    payload.update(body)
    rcpts = recipients(st, event, project, adhoc_files, only)
    results = {}
    for name, f in rcpts:
        ok, why = post(f, payload)
        results[name] = "ok" if ok else "fallo: " + why
    if log:
        home.ensure_home()
        with open(home.events_log(), "a") as lf:
            lf.write(json.dumps(dict(payload, delivery=results), ensure_ascii=False) + "\n")
        try:
            os.chmod(home.events_log(), 0o600)
        except OSError:
            pass
    return (all(v == "ok" for v in results.values()), bool(rcpts), results)


_current = contextvars.ContextVar("chopshop_emit_fn", default=None)


@contextlib.contextmanager
def using(emit_fn):
    """Durante el bloque, `send` usa `emit_fn(st, event, project, body, adhoc_files=None, log=True, only=None)`."""
    tok = _current.set(emit_fn) if emit_fn is not None else None
    try:
        yield
    finally:
        if tok is not None:
            _current.reset(tok)


def send(st, event, project, body, adhoc_files=None, log=True, only=None):
    """Emite con la función inyectada (`using`) o con `emit`. Mismo resultado que `emit`."""
    return (_current.get() or emit)(st, event, project, body, adhoc_files, log=log, only=only)
