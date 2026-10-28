"""Buzón local: la UI (o un bot sin red hacia T3) deja respuestas en ~/.chopshop/inbox y `watch`/`poll`
las envía a T3. Así la app de escritorio solo lee y escribe archivos locales; la red la hace un proceso aparte
(en macOS un proceso hijo de una app GUI hereda sus permisos de privacidad de red local, y puede quedarse colgado)."""
import json
import os
import time

from . import home, state


def _dir(name):
    d = os.path.join(home.home(), name)
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def _write(path, obj):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def enqueue_answer(task, choice, request=None, by=None):
    ident = "a-%d" % int(time.time() * 1000)
    _write(os.path.join(_dir("inbox"), ident + ".json"),
           {"id": ident, "op": "answer", "task": task, "choice": choice, "request": request, "by": by, "ts": state.now()})
    return ident


def _items(name):
    d = os.path.join(home.home(), name)
    out = []
    if os.path.isdir(d):
        for fn in sorted(os.listdir(d)):
            if fn.endswith(".json"):
                try:
                    with open(os.path.join(d, fn)) as f:
                        out.append(json.load(f))
                except (OSError, ValueError):
                    pass
    return out


def drain(answer_fn, log=print):
    """Envía las respuestas en cola. Cada resultado queda en outbox/ (se conservan las últimas 20)."""
    sent = 0
    for it in _items("inbox"):
        try:
            ans = answer_fn(it["task"], it["choice"], it.get("request"), it.get("by"))
            res = {"ok": True, "answer": ans}
            log("buzón: %s -> %s enviada (%s)" % (it["id"], it["task"], it["choice"]))
        except Exception as e:  # el error se devuelve a quien encoló, no rompe el ciclo
            res = {"ok": False, "error": str(e)[:300]}
            log("buzón: %s -> %s falló: %s" % (it["id"], it["task"], str(e)[:200]))
        res.update(id=it["id"], task=it["task"], choice=it["choice"], ts=state.now())
        _write(os.path.join(_dir("outbox"), it["id"] + ".json"), res)
        try:
            os.remove(os.path.join(home.home(), "inbox", it["id"] + ".json"))
        except OSError:
            pass
        sent += 1
    out = os.path.join(home.home(), "outbox")
    if os.path.isdir(out):
        for fn in sorted(os.listdir(out))[:-20]:
            try:
                os.remove(os.path.join(out, fn))
            except OSError:
                pass
    return sent


def heartbeat(interval):
    _write(os.path.join(home.home(), "watch.json"), {"ts": state.now(), "epoch": time.time(), "interval": interval, "pid": os.getpid()})


def status():
    w = None
    try:
        with open(os.path.join(home.home(), "watch.json")) as f:
            w = json.load(f)
        w["alive"] = (time.time() - w.get("epoch", 0)) < max(3 * w.get("interval", 20), 60)
    except (OSError, ValueError):
        pass
    return {"pending": _items("inbox"), "results": _items("outbox")[-10:], "watcher": w}
