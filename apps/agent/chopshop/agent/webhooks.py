import fnmatch
import hashlib
import heapq
import hmac
import inspect
import itertools
import logging
import os
import re
import threading
import time
from collections import deque

from . import db, envelope

SEVERITIES = ("info", "notice", "warn", "error")
NEEDS = ("human", "bot", "approval")
NEEDS_NONE = "none"
RETRY_DELAYS = (2, 10, 60)
CONTEXT_RECENT = 5
CONTEXT_SCAN = 500
MAX_DEBOUNCE = 3600
MAX_ITEMS = 32
_PATTERN = re.compile(r"^[A-Za-z0-9_.*?\[\]!-]{1,128}$")
_URL = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
_HEADER_NAME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$")
RESERVED_HEADERS = ("content-type", "content-length", "host", "user-agent", "transfer-encoding", "connection")
MAX_HEADERS = 32
log = logging.getLogger("chopshop.agent.webhooks")


class WebhookError(Exception):
    pass


def legacy_map():
    return envelope.LEGACY_MAP


def legacy_name(env):
    if "event" in env:
        ev = env.get("event")
        return ev if isinstance(ev, str) and ev != env.get("type") else None
    b = env.get("body")
    return b.get("legacy") if isinstance(b, dict) and isinstance(b.get("legacy"), str) else None


def subject_key(env):
    s = env.get("subject")
    if isinstance(s, dict) and s.get("id") is not None:
        return "%s:%s" % (s.get("kind"), s.get("id"))
    return None


def payload(env, context=None):
    out = dict(env)
    out.setdefault("event", legacy_name(env) or env.get("type"))
    out.setdefault("machine_id", env.get("machine"))
    if context is not None:
        out["body"] = dict(env.get("body") or {}, context=context)
    return out


def _strlist(v, key, pattern=None):
    if v is None:
        return None
    if isinstance(v, str):
        v = [s.strip() for s in v.split(",") if s.strip()]
    if not isinstance(v, (list, tuple)) or len(v) > MAX_ITEMS:
        raise WebhookError("%s debe ser una lista (máx. %d)" % (key, MAX_ITEMS))
    for s in v:
        if not isinstance(s, str) or not s or len(s) > 128 or (pattern and not pattern.match(s)):
            raise WebhookError("%s: valor inválido" % key)
    return list(v)


def _path(v, key):
    if v is None:
        return None
    if not isinstance(v, str) or not v.strip() or len(v) > 1024:
        raise WebhookError("%s debe ser la ruta de un archivo" % key)
    if _URL.match(v.strip()):
        raise WebhookError("%s debe ser una ruta de archivo, no una URL" % key)
    return v.strip()


def validate(opts):
    o = dict(opts or {})
    out = {
        "projects": _strlist(o.get("projects"), "projects"),
        "types": _strlist(o.get("types"), "types", _PATTERN),
        "exclude_types": _strlist(o.get("exclude_types"), "exclude_types", _PATTERN),
        "needs": _strlist(o.get("needs"), "needs"),
        "secret_file": _path(o.get("secret_file"), "secret_file"),
        "headers_file": _path(o.get("headers_file"), "headers_file"),
    }
    if out["needs"] and not set(out["needs"]) <= set(NEEDS + (NEEDS_NONE,)):
        raise WebhookError("needs admite: %s" % ", ".join(NEEDS + (NEEDS_NONE,)))
    sev = o.get("min_severity")
    if sev is not None and sev not in SEVERITIES:
        raise WebhookError("min_severity admite: %s" % ", ".join(SEVERITIES))
    out["min_severity"] = sev
    for k in ("only_changes", "context"):
        v = o.get(k)
        if v is not None and not isinstance(v, bool):
            raise WebhookError("%s debe ser true/false" % k)
        out[k] = v
    d = o.get("debounce_s")
    if d is not None and (isinstance(d, bool) or not isinstance(d, (int, float)) or not 0 <= d <= MAX_DEBOUNCE):
        raise WebhookError("debounce_s debe ser un número entre 0 y %d" % MAX_DEBOUNCE)
    out["debounce_s"] = d
    if o.get("batch_window_s"):
        raise WebhookError("batch_window_s aún no está soportado (v1)")
    return out


FIELDS = ("projects", "types", "exclude_types", "min_severity", "needs", "only_changes", "context", "debounce_s",
          "secret_file", "headers_file")
JSON_FIELDS = ("projects", "types", "exclude_types", "needs")


def effective(row):
    r = dict(row)
    def jl(k):
        v = db.jload(r.get(k)) if isinstance(r.get(k), str) else r.get(k)
        return list(v) if isinstance(v, list) else None
    projects = jl("projects")
    return {
        "name": r["name"], "webhook_file": r.get("webhook_file"), "secret_file": r.get("secret_file"),
        "headers_file": r.get("headers_file"),
        "projects": projects if projects else [r.get("project") or "*"],
        "events": jl("events") or [], "types": jl("types"), "exclude_types": jl("exclude_types") or [],
        "min_severity": r.get("min_severity"), "needs": jl("needs") or [],
        "only_changes": bool(r.get("only_changes")), "context": bool(r.get("context")),
        "debounce_s": float(r.get("debounce_s") or 0),
    }


def public(sub):
    return {"projects": sub["projects"], "types": sub["types"], "exclude_types": sub["exclude_types"],
            "min_severity": sub["min_severity"], "needs": sub["needs"], "only_changes": sub["only_changes"],
            "context": sub["context"], "debounce_s": sub["debounce_s"], "signed": bool(sub["secret_file"]),
            "headers": bool(sub.get("headers_file"))}


def _glob(value, pat):
    return value is not None and fnmatch.fnmatchcase(value, pat)


def matches(sub, env):
    proj = env.get("project")
    if not any(p == "*" or _glob(proj, p) for p in sub["projects"]):
        return False
    typ, legacy = env.get("type"), legacy_name(env)
    if sub["types"]:
        if not any(_glob(typ, p) or _glob(legacy, p) for p in sub["types"]):
            return False
    elif sub["types"] is None and sub["events"]:
        evs = sub["events"]
        lm = legacy_map()
        if not (legacy in evs or typ in evs or (legacy is None and typ in {lm.get(e) for e in evs})):
            return False
    if any(_glob(typ, p) or _glob(legacy, p) for p in sub["exclude_types"]):
        return False
    if sub["min_severity"]:
        sev = env.get("severity") if env.get("severity") in SEVERITIES else "info"
        if SEVERITIES.index(sev) < SEVERITIES.index(sub["min_severity"]):
            return False
    if sub["needs"] and (env.get("needs") or NEEDS_NONE) not in sub["needs"]:
        return False
    return True


def build_context(conn, env):
    from .events import COLUMNS, to_envelope
    key, seq = subject_key(env), env.get("seq") or 0
    with db.tx():
        rs = conn.execute("SELECT %s FROM events WHERE seq<=? AND project IS ? ORDER BY seq DESC LIMIT ?" % COLUMNS,
                          (seq, env.get("project"), CONTEXT_SCAN)).fetchall()
    recent, latest = [], {}
    for r in rs:
        e = to_envelope(r) if r["seq"] != seq else env
        k = subject_key(e)
        if k is None:
            continue
        if r["seq"] != seq and k == key and len(recent) < CONTEXT_RECENT:
            recent.append(e)
        if e.get("type") == "task.state" and k not in latest:
            latest[k] = e
    counts = {"tasks": len(latest), "needs_human": 0, "waiting_bot": 0, "stuck": 0}
    for e in latest.values():
        b = e.get("body") or {}
        ph = b.get("phase") or "unknown"
        counts[ph] = counts.get(ph, 0) + 1
        att = b.get("attention")
        if att in ("ask", "human", "approval"):
            counts["needs_human"] += 1
        elif att == "bot":
            counts["waiting_bot"] += 1
        if e.get("severity") == "warn":
            counts["stuck"] += 1
    return {"recent": recent[::-1], "project_summary": {"project": env.get("project"), "counts": counts}}


def read_url(path):
    with open(os.path.expanduser(path), encoding="utf-8") as f:
        url = f.readline().strip()
    if not url.startswith(("http://", "https://")):
        raise ValueError("sin URL http(s)")
    return url


def read_secret(path):
    p = os.path.expanduser(path)
    if os.stat(p).st_mode & 0o077:
        raise PermissionError("permisos abiertos")
    with open(p, encoding="utf-8") as f:
        s = f.read().strip()
    if not s:
        raise ValueError("vacío")
    return s


def read_headers(path):
    p = os.path.expanduser(path)
    if os.stat(p).st_mode & 0o077:
        raise PermissionError("permisos abiertos")
    out, seen = {}, set()
    with open(p, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, sep, value = line.partition(":")
            name, value = name.strip(), value.strip()
            low = name.lower()
            if not sep or not _HEADER_NAME.match(name) or not value or any(c in value for c in "\r\n\0"):
                raise ValueError("línea %d: se espera `Nombre: valor`" % i)
            if low in RESERVED_HEADERS or low.startswith("x-chopshop-"):
                raise ValueError("línea %d: cabecera reservada" % i)
            if low in seen:
                raise ValueError("línea %d: cabecera repetida" % i)
            seen.add(low)
            out[name] = value
    if len(out) > MAX_HEADERS:
        raise ValueError("más de %d cabeceras" % MAX_HEADERS)
    return out


def sign(secret, data):
    return "sha256=" + hmac.new(secret.encode("utf-8"), data, hashlib.sha256).hexdigest()


def exc_detail(e):
    import urllib.error
    name = type(e).__name__
    reason = getattr(e, "reason", None)
    if isinstance(e, urllib.error.URLError) and reason is not None and not isinstance(reason, str):
        name += "/" + type(reason).__name__
    return name


def _accepts_headers(poster):
    try:
        ps = inspect.signature(poster).parameters.values()
    except (TypeError, ValueError):
        return False
    return any(p.name == "headers" or p.kind == p.VAR_KEYWORD for p in ps)


def attempt(webhook_file, secret_file, data, headers, poster, timeout, headers_file=None):
    try:
        url = read_url(webhook_file)
    except Exception as e:
        return False, "archivo de webhook ilegible (%s)" % type(e).__name__, False
    extra = {}
    if headers_file:
        try:
            extra = read_headers(headers_file)
        except Exception as e:
            return False, "archivo de cabeceras ilegible (%s)" % type(e).__name__, False
    headers = dict(extra, **headers)
    if secret_file:
        try:
            headers["X-Chopshop-Signature"] = sign(read_secret(secret_file), data)
        except Exception as e:
            return False, "archivo de secreto ilegible (%s)" % type(e).__name__, False
    try:
        status = poster(url, data, timeout, headers=headers) if _accepts_headers(poster) else poster(url, data, timeout)
    except Exception as e:
        return False, exc_detail(e), True
    if isinstance(status, bool) or not isinstance(status, int):
        return bool(status), "ok" if status else "fallo", not status
    ok = 200 <= status < 300
    return ok, "HTTP %d" % status, not ok and (status >= 500 or status in (408, 425, 429))


def record(conn, seq, name, ok, detail, attempts=1, next_retry=None, clock=time.time):
    try:
        with db.tx():
            conn.execute("INSERT OR REPLACE INTO deliveries(event_seq,name,ok,detail,ts,attempts,next_retry) "
                         "VALUES(?,?,?,?,?,?,?)", (seq, name, 1 if ok else 0, detail, clock(), attempts, next_retry))
    except Exception:
        pass


class Lanes:
    def __init__(self):
        self._cv = threading.Condition()
        self._lanes = {}
        self._pending = 0

    def put(self, key, fn):
        with self._cv:
            lane = self._lanes.get(key)
            self._pending += 1
            if lane is None:
                self._lanes[key] = deque([fn])
                threading.Thread(target=self._run, args=(key,), name="chopshop-webhook", daemon=True).start()
            else:
                lane.append(fn)

    def _run(self, key):
        while True:
            with self._cv:
                lane = self._lanes[key]
                if not lane:
                    del self._lanes[key]
                    return
                fn = lane.popleft()
            try:
                fn()
            except Exception as e:
                log.error("webhook: fallo inesperado en la entrega (%s)", type(e).__name__)
            finally:
                with self._cv:
                    self._pending -= 1
                    self._cv.notify_all()

    def flush(self, timeout=10):
        end = time.monotonic() + timeout
        with self._cv:
            while self._pending:
                left = end - time.monotonic()
                if left <= 0:
                    return False
                self._cv.wait(left)
        return True


class Scheduler:
    def __init__(self, clock=time.time):
        self.clock = clock
        self._cv = threading.Condition()
        self._heap = []
        self._n = itertools.count()
        self._thread = None

    def schedule(self, due, fn):
        with self._cv:
            heapq.heappush(self._heap, (due, next(self._n), fn))
            if self._thread is None:
                self._thread = threading.Thread(target=self._run, name="chopshop-webhook-timer", daemon=True)
                self._thread.start()
            self._cv.notify_all()

    def pending(self):
        with self._cv:
            return sorted(d for d, _n, _f in self._heap)

    def pump(self):
        with self._cv:
            now = self.clock()
            while self._heap and self._heap[0][0] <= now:
                fn = heapq.heappop(self._heap)[2]
                try:
                    fn()
                except Exception as e:
                    log.error("webhook: fallo inesperado en una tarea diferida (%s)", type(e).__name__)

    def cancel(self):
        with self._cv:
            self._heap.clear()
            self._cv.notify_all()

    def _run(self):
        while True:
            with self._cv:
                if not self._heap and not self._cv.wait(30) and not self._heap:
                    self._thread = None
                    return
                if self._heap:
                    self._cv.wait(min(max(self._heap[0][0] - self.clock(), 0), 1.0))
            self.pump()


class Dispatcher:
    def __init__(self, clock=time.time, retry_delays=RETRY_DELAYS):
        self.clock = clock
        self.retry_delays = tuple(retry_delays)
        self.lanes = Lanes()
        self.scheduler = Scheduler(clock)
        self._lock = threading.Lock()
        self._last = {}
        self._held = {}

    def dispatch(self, conn, subs, fixed, env, poster, timeout):
        chosen = [s for s in subs if matches(s, env)]
        names = {s["name"] for s in chosen}
        chosen += [effective({"name": n, "webhook_file": f}) for n, f in fixed.items() if n not in names]
        out = []
        key = subject_key(env)
        for sub in chosen:
            name = sub["name"]
            if sub["only_changes"] and env.get("type") == "task.state" and key:
                b = env.get("body") or {}
                cur = (b.get("phase"), b.get("attention"))
                with self._lock:
                    prev = self._last.get((name, key))
                    self._last[(name, key)] = cur
                if prev == cur:
                    log.debug("webhook %s: seq=%s omitido (only_changes, sin cambio)", name, env.get("seq"))
                    continue
            out.append(name)
            if sub["debounce_s"] > 0 and key:
                with self._lock:
                    first = (name, key) not in self._held
                    self._held[(name, key)] = (conn, sub, env, poster, timeout)
                log.debug("webhook %s: seq=%s retenido (debounce %ss)", name, env.get("seq"), sub["debounce_s"])
                if first:
                    self.scheduler.schedule(self.clock() + sub["debounce_s"], lambda k=(name, key): self._release(k))
                continue
            self.send(conn, sub, env, poster, timeout)
        return out

    def _release(self, k):
        with self._lock:
            held = self._held.pop(k, None)
        if held:
            self.send(*held)

    def send(self, conn, sub, env, poster, timeout):
        name, state = sub["name"], {}

        def run(n):
            if "data" not in state:
                ctx = build_context(conn, env) if sub["context"] else None
                state["data"] = db.jdump(payload(env, ctx)).encode("utf-8")
            headers = {"X-Chopshop-Event": str(env.get("type")), "X-Chopshop-Id": str(env.get("id")),
                       "X-Chopshop-Delivery": str(n)}
            t0 = time.monotonic()
            ok, detail, retry = attempt(sub["webhook_file"], sub["secret_file"], state["data"], headers, poster, timeout,
                                        sub.get("headers_file"))
            ms = (time.monotonic() - t0) * 1000
            nxt = None
            if retry and n <= len(self.retry_delays):
                nxt = self.clock() + self.retry_delays[n - 1]
                self.scheduler.schedule(nxt, lambda: self.lanes.put(name, lambda: run(n + 1)))
            record(conn, env.get("seq"), name, ok, detail, n, nxt, self.clock)
            outcome = "ok" if ok else ("reintento %d en %ss" % (n + 1, self.retry_delays[n - 1]) if nxt is not None
                                       else "sin reintento" if not retry else "reintentos agotados")
            log.log(logging.INFO if ok else logging.WARNING, "webhook %s: seq=%s type=%s intento=%d/%d %s %.0fms %s",
                    name, env.get("seq"), env.get("type"), n, len(self.retry_delays) + 1, detail, ms, outcome)
        self.lanes.put(name, lambda: run(1))

    def pump(self):
        self.scheduler.pump()

    def flush(self, timeout=10):
        return self.lanes.flush(timeout)

    def cancel(self):
        self.scheduler.cancel()
        with self._lock:
            self._held.clear()
