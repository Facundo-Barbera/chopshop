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
    except Exception as e:
        return False, type(e).__name__


def recipients(st, event, project, adhoc_files, only=None):
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
    tok = _current.set(emit_fn) if emit_fn is not None else None
    try:
        yield
    finally:
        if tok is not None:
            _current.reset(tok)


def send(st, event, project, body, adhoc_files=None, log=True, only=None):
    return (_current.get() or emit)(st, event, project, body, adhoc_files, log=log, only=only)
