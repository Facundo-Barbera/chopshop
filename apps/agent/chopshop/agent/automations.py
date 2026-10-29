"""Automatizaciones por proyecto (perfil `automations:`): scripts locales sin versionar que reaccionan a sobres del bus.

- Declaración en `~/.chopshop/profiles/<proyecto>.yaml`; los scripts viven en `<home>/automations/<proyecto>/` (0700),
  con `state/` y `logs/`. `validate(perfil)` lo llama `profile.validate` (igual que `reactions.validate`).
- Disparadores: `type` (glob de tipo de sobre, con `where`), `schedule` (`every: 6h` o `cron` de 5 campos en hora local
  de la máquina) y `manual` (`chopshop automation run`).
- Runner: `Popen(argv)` sin shell, grupo de procesos propio, entorno limpio (PATH mínimo + lista blanca `env` +
  `CHOPSHOP_EVENT_FILE/PROJECT/AUTOMATION` + `<SECRETO>_FILE`), stdin=/dev/null, timeout que mata el grupo (SIGTERM, gracia,
  SIGKILL), RLIMIT_CPU/AS/NOFILE, tope de 256 KB en stdout/stderr, `max_runs_per_hour` y `concurrency`.
- Salida: JSONL en stdout -> sobres (solo tipos de `emits`, `cause = {id: disparador, depth+1}`). Siempre `automation.ran`.
- Anti-bucles: `cause.depth >= 3` no dispara; una automatización no se dispara con sus `emits` ni con su `automation.ran`.
No es un sandbox contra scripts hostiles: el modelo de confianza es «scripts escritos por los agentes del dueño».
El agente nunca crea ni ejecuta scripts a petición de la API HTTP (no hay ruta para eso)."""
import argparse
import calendar
import collections
import fnmatch
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

from .. import home
from . import envelope

log = logging.getLogger("chopshop.agent.automations")

DEFAULT_TIMEOUT = 60
MAX_TIMEOUT = 900
MIN_TIMEOUT = 1
DEFAULT_RUNS_PER_HOUR = 60
MAX_CONCURRENCY = 8
KILL_GRACE = 5.0                  # s entre SIGTERM y SIGKILL al vencer el timeout
OUT_CAP = 256 * 1024              # bytes guardados de stdout y de stderr (el resto se descarta)
MAX_EMITS = 100                   # sobres por ejecución
MAX_DEPTH = 3                     # cause.depth >= MAX_DEPTH no dispara
QUEUE_MAX = 20                    # ejecuciones en espera por automatización
TAIL = 2000                       # caracteres de stdout/stderr en automation.ran
MIN_EVERY = 60                    # s mínimos de `every`
MIN_PATH = "/usr/local/bin:/usr/bin:/bin"
AS_LIMIT = 1024 * 1024 * 1024     # RLIMIT_AS (1 GB)
NOFILE_LIMIT = 256
LOG_MAX = 1024 * 1024             # bytes por archivo de log antes de recortar

KEYS = ("name", "description", "on", "run", "cwd", "timeout", "max_runs_per_hour", "concurrency", "env", "secrets",
        "emits", "enabled", "on_failure")
TRIGGER_KEYS = ("type", "where", "every", "cron")
SEVERITY = ("info", "notice", "warn", "error")
NEEDS = (None, "human", "bot", "approval")
WHERE_ROOTS = ("type", "project", "severity", "needs", "subject", "body")
WHERE_OPS = ("in", "not", "regex")
# Espacios de nombres de tipos del agente (§2.2): se pueden escuchar pero no emitir desde un script.
RESERVED = ("task", "question", "approval", "batch", "graph", "node", "reaction", "machine", "github", "automation", "agent",
            "desk", "office", "forge", "listener")
RESERVED_EMITTABLE = ("forge.dispatch",)   # tipos del agente que un script sí puede emitir (anuncia un workflow_dispatch)
RESERVED_ENV = ("PATH", "CHOPSHOP_EVENT_FILE", "CHOPSHOP_PROJECT", "CHOPSHOP_AUTOMATION")
_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_ENVNAME = re.compile(r"^[A-Z_][A-Z0-9_]{0,63}$")
_TYPE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$")         # el de envelope.py
_GLOB = re.compile(r"^[a-z0-9_*?]+(\.[a-z0-9_*?]+)*$")
_EVERY = re.compile(r"^\s*(\d+)\s*([smhd])\s*$")
_UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


class AutomationError(Exception):
    pass


# ---------------------------------------------------------------- rutas

def base_dir(root=None):
    """Raíz de los scripts: `<home>/automations` (CHOPSHOP_HOME) o `root` inyectado."""
    return os.path.expanduser(root) if root else os.path.join(home.home(), "automations")


def project_dir(project, root=None, create=False):
    if not _NAME.match(project or ""):
        raise AutomationError("nombre de proyecto inválido: %r" % project)
    d = os.path.join(base_dir(root), project)
    if create:
        for sub in ("", "state", "logs"):
            os.makedirs(os.path.join(d, sub), mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
    return d


def secrets_dir(root=None):
    return os.path.expanduser(root) if root else os.path.join(home.home(), "secrets")


def secret_var(name):
    """`triage_token` -> `TRIAGE_TOKEN_FILE`."""
    return re.sub(r"[^A-Z0-9]", "_", name.upper()) + "_FILE"


# ---------------------------------------------------------------- validación

def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def parse_every(v):
    """`6h` / `30m` / `90s` / `1d` / segundos -> segundos (None si no es válido)."""
    if _num(v):
        return float(v) if v > 0 else None
    m = _EVERY.match(str(v or ""))
    return float(int(m.group(1)) * _UNITS[m.group(2)]) if m and int(m.group(1)) > 0 else None


_CRON_RANGES = ((0, 59), (0, 23), (1, 31), (1, 12), (0, 7))


def parse_cron(text):
    """`m h dom mes dow` -> 5 conjuntos (dow: 0 y 7 = domingo) + si dom/dow están restringidos. Lanza AutomationError."""
    parts = str(text or "").split()
    if len(parts) != 5:
        raise AutomationError("cron necesita 5 campos (minuto hora día mes día-semana)")
    sets = []
    for field, (lo, hi) in zip(parts, _CRON_RANGES):
        vals = set()
        for item in field.split(","):
            rng, _, step = item.partition("/")
            if step and not step.isdigit() or step == "0":
                raise AutomationError("cron: paso inválido en %r" % item)
            if rng == "*":
                a, b = lo, hi
            elif re.fullmatch(r"\d+-\d+", rng):
                a, b = (int(x) for x in rng.split("-"))
            elif rng.isdigit():
                a = b = int(rng)
                if step:
                    b = hi
            else:
                raise AutomationError("cron: campo inválido %r" % item)
            if not (lo <= a <= b <= hi):
                raise AutomationError("cron: %r fuera de rango (%d-%d)" % (item, lo, hi))
            vals.update(range(a, b + 1, int(step or 1)))
        sets.append(vals)
    if 7 in sets[4]:
        sets[4] = (sets[4] - {7}) | {0}
    return {"min": sets[0], "hour": sets[1], "dom": sets[2], "month": sets[3], "dow": sets[4],
            "dom_any": parts[2] == "*", "dow_any": parts[4] == "*"}


def cron_match(c, ts):
    """¿El minuto local de `ts` cumple el cron? (dom y dow restringidos a la vez = cualquiera de los dos, como cron)."""
    t = time.localtime(ts)
    if t.tm_min not in c["min"] or t.tm_hour not in c["hour"] or t.tm_mon not in c["month"]:
        return False
    dom, dow = t.tm_mday in c["dom"], (t.tm_wday + 1) % 7 in c["dow"]
    if c["dom_any"] or c["dow_any"]:
        return dom and dow
    return dom or dow


def _where_errs(where, at):
    if not isinstance(where, dict) or not where:
        return ["%s: se esperaba un mapa {ruta: condición}" % at]
    errs = []
    for path, cond in where.items():
        parts = str(path).split(".")
        if parts[0] not in WHERE_ROOTS or not all(parts) or (parts[0] in ("subject", "body") and len(parts) < 2) \
                or (parts[0] not in ("subject", "body") and len(parts) > 1):
            errs.append("%s: ruta %r inválida (project, severity, needs, type, subject.<campo>, body.<campo>)" % (at, path))
            continue
        errs += _cond_errs(cond, "%s.%s" % (at, path))
    return errs


def _cond_errs(cond, at, depth=0):
    if depth > 4:
        return ["%s: anidado demasiado profundo" % at]
    if isinstance(cond, list):
        return [] if all(not isinstance(x, (dict, list)) for x in cond) else ["%s: la lista solo admite escalares" % at]
    if not isinstance(cond, dict):
        return []
    if not cond:
        return ["%s: condición vacía" % at]
    errs = []
    for op, v in cond.items():
        if op not in WHERE_OPS:
            errs.append("%s: operador %r desconocido (%s)" % (at, op, ", ".join(WHERE_OPS)))
        elif op == "in" and not (isinstance(v, list) and all(not isinstance(x, (dict, list)) for x in v)):
            errs.append("%s.in: se esperaba una lista de valores" % at)
        elif op == "regex":
            try:
                re.compile(str(v))
            except re.error as e:
                errs.append("%s.regex no es regex: %s" % (at, e))
        elif op == "not":
            errs += _cond_errs(v, at + ".not", depth + 1)
    return errs


def _known_type(glob, emitted):
    if glob == "*" or "." not in glob and any(c in glob for c in "*?"):
        return True
    ns = glob.split(".")[0]
    return ns in RESERVED or any(c in ns for c in "*?") or any(fnmatch.fnmatchcase(e, glob) for e in emitted)


def triggers(a):
    """`on` normalizado: lista de dicts (`"manual"` o `"github.*"` sueltos = {type: ...})."""
    on = a.get("on")
    if isinstance(on, (str, dict)):
        on = [on]
    return [{"type": t} if isinstance(t, str) else t for t in (on or [])]


def validate(prof):
    """Problemas del bloque `automations:` (lista vacía si está bien o no existe)."""
    items = prof.get("automations")
    if items is None:
        return []
    if not isinstance(items, list):
        return ["automations: se esperaba una lista"]
    errs, names = [], set()
    emitted = _emitted(items)
    for i, a in enumerate(items):
        errs += _item_errs(a, i, names, emitted)
    return errs


def _emitted(items):
    return {e for a in items if isinstance(a, dict) and isinstance(a.get("emits"), list) for e in a["emits"] if isinstance(e, str)}


def _item_errs(a, i, names, emitted):
    at = "automations[%d]" % i
    if not isinstance(a, dict):
        return ["%s: se esperaba un mapa" % at]
    errs = []
    name = a.get("name")
    if not isinstance(name, str) or not _NAME.match(name):
        errs.append("%s.name inválido (letras, números, . _ -)" % at)
    elif name in names:
        errs.append("%s.name repetido: %s" % (at, name))
    else:
        names.add(name)
        at = "automations.%s" % name
    errs += ["%s.%s desconocido (%s)" % (at, k, ", ".join(KEYS)) for k in a if k not in KEYS]
    run = a.get("run")
    if not (isinstance(run, list) and run and all(isinstance(x, str) and x and "\0" not in x for x in run)):
        errs.append("%s.run debe ser una lista argv no vacía sin shell (p. ej. [python3, triage.py])" % at)
    cwd = a.get("cwd", ".")
    if not isinstance(cwd, str) or os.path.isabs(cwd) or ".." in cwd.replace("\\", "/").split("/"):
        errs.append("%s.cwd debe ser una ruta relativa dentro de la carpeta del proyecto" % at)
    to = a.get("timeout", DEFAULT_TIMEOUT)
    if not _num(to) or not MIN_TIMEOUT <= to <= MAX_TIMEOUT:
        errs.append("%s.timeout debe estar entre %d y %d s" % (at, MIN_TIMEOUT, MAX_TIMEOUT))
    mr = a.get("max_runs_per_hour", DEFAULT_RUNS_PER_HOUR)
    if not isinstance(mr, int) or isinstance(mr, bool) or not 1 <= mr <= 3600:
        errs.append("%s.max_runs_per_hour debe ser un entero 1-3600" % at)
    cc = a.get("concurrency", 1)
    if not isinstance(cc, int) or isinstance(cc, bool) or not 1 <= cc <= MAX_CONCURRENCY:
        errs.append("%s.concurrency debe ser un entero 1-%d" % (at, MAX_CONCURRENCY))
    env = a.get("env", [])
    if not isinstance(env, list) or not all(isinstance(x, str) and _ENVNAME.match(x) and x not in RESERVED_ENV for x in env):
        errs.append("%s.env debe ser una lista de nombres de variable (no PATH ni CHOPSHOP_EVENT_FILE/...)" % at)
    sec = a.get("secrets", [])
    if not isinstance(sec, list) or not all(isinstance(x, str) and _NAME.match(x) for x in sec):
        errs.append("%s.secrets debe ser una lista de nombres de archivo de ~/.chopshop/secrets/" % at)
    em = a.get("emits", [])
    if not isinstance(em, list):
        errs.append("%s.emits debe ser una lista de tipos" % at)
    else:
        for e in em:
            if not isinstance(e, str) or not _TYPE.match(e):
                errs.append("%s.emits: tipo inválido %r (p. ej. triage.result)" % (at, e))
            elif e.split(".")[0] in RESERVED and e not in RESERVED_EMITTABLE:
                errs.append("%s.emits: %s es un tipo del agente; usa un espacio propio (p. ej. %s.result)" % (at, e, name))
    if "enabled" in a and not isinstance(a["enabled"], bool):
        errs.append("%s.enabled debe ser true o false" % at)
    of = a.get("on_failure")
    if of is not None and not (isinstance(of, dict) and set(of) <= {"needs"} and of.get("needs") in NEEDS):
        errs.append("%s.on_failure debe ser {needs: bot|human|approval}" % at)
    trs = triggers(a)
    if not trs:
        errs.append("%s.on: falta al menos un disparador (type, schedule o manual)" % at)
    for j, t in enumerate(trs):
        errs += trigger_errs(t, "%s.on[%d]" % (at, j), emitted)
    return errs


def trigger_errs(t, tat, emitted=()):
    """Problemas de un disparador ya normalizado (mapa con `type`); lo reutiliza `wake:` de los roles permanentes."""
    if not isinstance(t, dict):
        return ["%s: se esperaba un mapa o un tipo" % tat]
    errs = []
    errs += ["%s.%s desconocido (%s)" % (tat, k, ", ".join(TRIGGER_KEYS)) for k in t if k not in TRIGGER_KEYS]
    ty = t.get("type")
    if not isinstance(ty, str) or not ty:
        errs.append("%s.type falta" % tat)
    elif ty == "schedule":
        if ("every" in t) == ("cron" in t):
            errs.append("%s: schedule necesita every o cron (uno solo)" % tat)
        elif "every" in t:
            ev = parse_every(t["every"])
            if ev is None or ev < MIN_EVERY:
                errs.append("%s.every inválido (p. ej. 6h, 30m; mínimo %ds)" % (tat, MIN_EVERY))
        else:
            try:
                parse_cron(t["cron"])
            except AutomationError as e:
                errs.append("%s.%s" % (tat, e))
        if "where" in t:
            errs.append("%s: where solo aplica a disparadores por tipo de evento" % tat)
    elif ty == "manual":
        errs += ["%s.%s no aplica a manual" % (tat, k) for k in ("where", "every", "cron") if k in t]
    else:
        if not _GLOB.match(ty):
            errs.append("%s.type inválido %r (tipo de sobre o glob, p. ej. github.issue.*)" % (tat, ty))
        elif not _known_type(ty, emitted):
            errs.append("%s.type desconocido %r (%s o un tipo de emits)" % (tat, ty, ", ".join(RESERVED)))
        errs += ["%s.%s solo aplica a schedule" % (tat, k) for k in ("every", "cron") if k in t]
        if "where" in t:
            errs += _where_errs(t["where"], tat + ".where")
    return errs


def specs(prof):
    """Automatizaciones válidas del perfil con valores por defecto (las inválidas se omiten: las reporta `validate`)."""
    out, names = [], set()
    items = prof.get("automations")
    items = items if isinstance(items, list) else []
    emitted = _emitted(items)
    for i, a in enumerate(items):
        if _item_errs(a, i, names, emitted):
            continue
        s = {"project": prof.get("project"), "name": a["name"], "run": list(a["run"]), "cwd": a.get("cwd", "."),
             "timeout": float(a.get("timeout", DEFAULT_TIMEOUT)), "max_runs_per_hour": a.get("max_runs_per_hour", DEFAULT_RUNS_PER_HOUR),
             "concurrency": a.get("concurrency", 1), "env": list(a.get("env") or []), "secrets": list(a.get("secrets") or []),
             "emits": list(a.get("emits") or []), "enabled": a.get("enabled", True), "on_failure": a.get("on_failure") or {},
             "on": []}
        for t in triggers(a):
            t = dict(t)
            if t["type"] == "schedule":
                t["_every"] = parse_every(t["every"]) if "every" in t else None
                t["_cron"] = parse_cron(t["cron"]) if "cron" in t else None
            s["on"].append(t)
        out.append(s)
    return out


# ---------------------------------------------------------------- where

_MISSING = object()


def _get(env, path):
    cur = env
    for p in path.split("."):
        if not isinstance(cur, dict) or p not in cur:
            return _MISSING
        cur = cur[p]
    return cur


def _eq(actual, want):
    if isinstance(actual, list):
        return any(_eq(x, want) for x in actual)
    if actual is _MISSING:
        return False
    if isinstance(want, bool) or isinstance(actual, bool):
        return actual is want
    return actual == want or (actual is not None and want is not None and str(actual) == str(want))


def _cond(actual, cond):
    if isinstance(cond, list):
        return any(_eq(actual, w) for w in cond)
    if not isinstance(cond, dict):
        return _eq(actual, cond)
    for op, v in cond.items():
        if op == "in" and not any(_eq(actual, w) for w in v):
            return False
        if op == "not" and _cond(actual, v):
            return False
        if op == "regex":
            vals = actual if isinstance(actual, list) else [actual]
            if not any(x is not _MISSING and x is not None and re.search(str(v), str(x)) for x in vals):
                return False
    return True


def where_match(where, env):
    """¿El sobre cumple todas las condiciones? Escalar = igualdad (en listas: contiene), lista = in, {in|not|regex}."""
    return all(_cond(_get(env, path), cond) for path, cond in (where or {}).items())


# ---------------------------------------------------------------- sobres

def new_id():
    return envelope.new_id()


def normalize(row):
    """Sobre del bus (`events.list_after`) o sobre suelto -> sobre con `cause`, `subject` y `body` bien formados.
    Un dict con el nombre viejo (`event`) y sin `type` se traduce con `envelope.from_legacy`."""
    if not isinstance(row, dict):
        return None
    env = dict(row)
    if not env.get("type") and env.get("event"):
        f = envelope.from_legacy(env["event"], env.get("body") if isinstance(env.get("body"), dict) else {})
        env.update({k: f[k] for k in ("type", "severity", "needs", "subject", "body")})
    if not env.get("id"):
        env["id"] = "seq-%s" % env.get("seq")
    cause = env.get("cause") if isinstance(env.get("cause"), dict) else {}
    try:
        depth = int(cause.get("depth") or 0)
    except (TypeError, ValueError):
        depth = MAX_DEPTH
    env["cause"] = {"id": cause.get("id"), "depth": depth}
    for k in ("body", "subject"):
        if not isinstance(env.get(k), dict):
            env[k] = {}
    return env


def _clean_subject(o, spec):
    """Sujeto que da el script, si cumple el contrato (kind conocido, id texto); si no, el de la automatización."""
    if not isinstance(o, dict) or o.get("kind") not in envelope.SUBJECT_KINDS or o.get("id") in (None, ""):
        return _subject(spec)
    out = {"kind": o["kind"], "id": str(o["id"])[:200]}
    for k in ("title", "url"):
        if isinstance(o.get(k), str) and o[k]:
            out[k] = o[k][:500]
    return out


def parse_output(text, spec, trigger_env):
    """JSONL de stdout -> (sobres parciales, descartadas). Solo tipos de `emits`; el runner completa el resto."""
    out, discarded = [], 0
    cause = {"id": (trigger_env or {}).get("id"), "depth": int(((trigger_env or {}).get("cause") or {}).get("depth") or 0) + 1}
    allowed = set(spec["emits"])
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            discarded += 1
            continue
        if not isinstance(o, dict) or o.get("type") not in allowed or len(out) >= MAX_EMITS:
            discarded += 1
            continue
        sev = o.get("severity") if o.get("severity") in SEVERITY else "info"
        needs = o.get("needs") if o.get("needs") in NEEDS else None
        subj = _clean_subject(o.get("subject"), spec)
        body = o.get("body") if isinstance(o.get("body"), dict) else {}
        out.append({"v": 1, "type": o["type"], "project": spec["project"], "severity": sev, "needs": needs, "subject": subj,
                    "cause": dict(cause), "body": body})
    return out, discarded


def _subject(spec):
    return envelope.subject("automation", spec["name"])


# ---------------------------------------------------------------- runner

def _limits(timeout):
    def apply():
        import resource  # noqa: PLC0415 - solo POSIX, dentro del hijo
        cpu = int(timeout) + 5
        for lim, val in ((resource.RLIMIT_CPU, cpu), (resource.RLIMIT_AS, AS_LIMIT), (resource.RLIMIT_NOFILE, NOFILE_LIMIT)):
            try:
                soft, hard = resource.getrlimit(lim)
                val = val if hard == resource.RLIM_INFINITY else min(val, hard)
                resource.setrlimit(lim, (val, hard))
            except (ValueError, OSError):
                pass
    return apply


def _reader(stream, buf):
    """Lee todo el flujo (para que el hijo no se bloquee) y guarda como mucho OUT_CAP bytes."""
    try:
        while True:
            chunk = stream.read(65536)
            if not chunk:
                break
            room = OUT_CAP - len(buf["data"])
            if room > 0:
                buf["data"] += chunk[:room]
            if len(chunk) > max(room, 0):
                buf["truncated"] = True
    except (OSError, ValueError):
        pass
    finally:
        try:
            stream.close()
        except OSError:
            pass


def _killpg(pgid, sig):
    try:
        os.killpg(pgid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def build_env(spec, event_file, environ=None, secrets_root=None):
    """Entorno limpio: PATH mínimo + lista blanca + CHOPSHOP_* del disparo + `<SECRETO>_FILE` (solo si el archivo existe)."""
    src = os.environ if environ is None else environ
    env = {"PATH": MIN_PATH}
    for k in spec["env"]:
        if k in src:
            env[k] = src[k]
    for name in spec["secrets"]:
        p = os.path.join(secrets_dir(secrets_root), name)
        if os.path.isfile(p):
            env[secret_var(name)] = p
    env.update(CHOPSHOP_EVENT_FILE=event_file, CHOPSHOP_PROJECT=spec["project"], CHOPSHOP_AUTOMATION=spec["name"])
    return env


def execute(spec, trigger_env=None, root=None, secrets_root=None, environ=None, grace=KILL_GRACE, clock=time.monotonic):
    """Ejecuta el script una vez. Devuelve {exit, timed_out, duration_ms, stdout, stderr, truncated, error}."""
    pdir = project_dir(spec["project"], root, create=True)
    cwd = os.path.realpath(os.path.join(pdir, spec["cwd"]))
    res = {"exit": None, "timed_out": False, "duration_ms": 0, "stdout": "", "stderr": "", "truncated": False, "error": None}
    if cwd != os.path.realpath(pdir) and not cwd.startswith(os.path.realpath(pdir) + os.sep):
        res["error"] = "cwd fuera de la carpeta del proyecto"
        return res
    fd, event_file = tempfile.mkstemp(prefix="event-", suffix=".json", dir=os.path.join(pdir, "state"))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(trigger_env or {}, f, ensure_ascii=False)
        env = build_env(spec, event_file, environ, secrets_root)
        t0 = clock()
        try:
            p = subprocess.Popen(spec["run"], shell=False, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                                 preexec_fn=_limits(spec["timeout"]), close_fds=True)
        except OSError as e:
            res["error"] = "no se pudo ejecutar: %s" % type(e).__name__
            res["duration_ms"] = int((clock() - t0) * 1000)
            return res
        bufs = [{"data": b"", "truncated": False}, {"data": b"", "truncated": False}]
        readers = [threading.Thread(target=_reader, args=(s, b), daemon=True) for s, b in ((p.stdout, bufs[0]), (p.stderr, bufs[1]))]
        for r in readers:
            r.start()
        try:
            p.wait(timeout=spec["timeout"])
        except subprocess.TimeoutExpired:
            res["timed_out"] = True
            _killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                pass
        _killpg(p.pid, signal.SIGKILL)         # el grupo entero (nietos incluidos): un script no deja procesos vivos
        if p.poll() is None:
            p.wait()
        for r in readers:
            r.join(5)
        res["duration_ms"] = int((clock() - t0) * 1000)
        res["exit"] = p.returncode
        res["stdout"] = bufs[0]["data"].decode("utf-8", "replace")
        res["stderr"] = bufs[1]["data"].decode("utf-8", "replace")
        res["truncated"] = bufs[0]["truncated"] or bufs[1]["truncated"]
        if res["timed_out"]:
            res["error"] = "timeout (%ss)" % _fmt_s(spec["timeout"])
        elif p.returncode != 0:
            res["error"] = "exit %s" % p.returncode
        return res
    finally:
        try:
            os.unlink(event_file)
        except OSError:
            pass


def _fmt_s(v):
    return ("%d" % v) if float(v).is_integer() else ("%.1f" % v)


def next_run(spec, store, now):
    """Próximo disparo por horario de la automatización (epoch) o None si no tiene `schedule`. `store` = cursores de `tick`."""
    best = None
    for i, t in enumerate(spec.get("on") or []):
        if t.get("type") != "schedule":
            continue
        cand = None
        if t.get("_every"):
            last = store.get("sched:%s:%s:%d" % (spec["project"], spec["name"], i))
            cand = max(now, (float(last) if last is not None else now) + t["_every"])
        elif t.get("_cron"):
            m = (int(now) // 60 + 1) * 60
            for _ in range(8 * 1440):              # una semana y un día cubre cualquier cron de 5 campos usado aquí
                if cron_match(t["_cron"], m):
                    cand = m
                    break
                m += 60
        if cand is not None and (best is None or cand < best):
            best = cand
    return best


def ran_envelope(spec, trigger, trigger_env, res, emitted, discarded, next_run_ts=None):
    """Sobre `automation.ran` (siempre: éxito, fallo o timeout)."""
    failed = res["timed_out"] or res["exit"] != 0
    err = res["error"]
    if discarded:
        err = ((err + "; ") if err else "") + "%d líneas descartadas" % discarded
    of = spec.get("on_failure") or {}
    cause = {"id": (trigger_env or {}).get("id"), "depth": int(((trigger_env or {}).get("cause") or {}).get("depth") or 0) + 1}
    return {"v": 1, "type": "automation.ran", "project": spec["project"],
            "severity": "error" if failed else ("warn" if discarded else "info"),
            "needs": of.get("needs") if failed else None, "subject": _subject(spec), "cause": cause,
            "body": {"automation": spec["name"], "trigger": trigger, "trigger_event": (trigger_env or {}).get("id"),
                     "exit": res["exit"], "duration_ms": res["duration_ms"], "emitted": emitted, "discarded": discarded,
                     "timed_out": res["timed_out"], "stdout_tail": res["stdout"][-TAIL:], "stderr_tail": res["stderr"][-TAIL:],
                     "truncated": res["truncated"], "error": err,
                     "next_run": envelope.iso(next_run_ts) if next_run_ts is not None else None}}


def write_log(spec, rec, root=None):
    """Una línea JSON por ejecución en `logs/<nombre>.log` (se recorta a la mitad al pasar de LOG_MAX)."""
    try:
        p = os.path.join(project_dir(spec["project"], root, create=True), "logs", spec["name"] + ".log")
        if os.path.exists(p) and os.path.getsize(p) > LOG_MAX:
            with open(p, "rb") as f:
                f.seek(-LOG_MAX // 2, os.SEEK_END)
                keep = f.read()
            with open(p, "wb") as f:
                f.write(keep[keep.find(b"\n") + 1:])
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        log.warning("no pude escribir el log de %s/%s", spec["project"], spec["name"])


def read_log(project, name=None, n=20, root=None):
    d = os.path.join(project_dir(project, root), "logs")
    files = [name + ".log"] if name else (sorted(f for f in os.listdir(d) if f.endswith(".log")) if os.path.isdir(d) else [])
    out = []
    for fn in files:
        p = os.path.join(d, fn)
        if not os.path.isfile(p):
            continue
        with open(p, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    out.sort(key=lambda r: r.get("ts") or 0)
    return out[-n:]


def _publish(emit_fn, e):
    stored = emit_fn(e)
    if isinstance(stored, dict):                     # el bus pone id/seq/ts/machine definitivos
        e.update({k: stored[k] for k in ("id", "seq", "ts", "machine") if k in stored})
    else:
        e.setdefault("id", new_id())


def run_once(spec, emit_fn, trigger="manual", trigger_env=None, root=None, secrets_root=None, environ=None,
             grace=KILL_GRACE, wall=time.time, next_run_fn=None):
    """Ejecuta, convierte la salida en sobres, los emite (más `automation.ran`) y deja una línea en el log."""
    res = execute(spec, trigger_env, root, secrets_root, environ, grace)
    envs, discarded = parse_output(res["stdout"], spec, trigger_env)
    if res["timed_out"]:
        envs = []                                    # una ejecución que no terminó no publica nada a medias
    sent = []
    for e in envs:
        try:
            _publish(emit_fn, e)
            sent.append(e)
        except envelope.EnvelopeError:               # el bus lo rechaza (esquema del tipo): se descarta y se cuenta
            discarded += 1
    envs = sent
    nxt = None
    if next_run_fn is not None:
        try:
            nxt = next_run_fn()
        except Exception:  # noqa: BLE001 - el próximo horario es informativo
            nxt = None
    ran = ran_envelope(spec, trigger, trigger_env, res, len(envs), discarded, nxt)
    _publish(emit_fn, ran)
    write_log(spec, {"ts": wall(), "trigger": trigger, "trigger_event": (trigger_env or {}).get("id"), "exit": res["exit"],
                     "duration_ms": res["duration_ms"], "emitted": len(envs), "discarded": discarded,
                     "error": ran["body"]["error"], "stderr_tail": res["stderr"][-500:]}, root)
    return dict(res, emitted=len(envs), discarded=discarded, envelopes=envs, ran=ran)


# ---------------------------------------------------------------- motor (hilo del agente)

class Automations:
    """Despacha sobres del bus y horarios a las automatizaciones de todos los perfiles.

    `emit_fn(sobre_parcial)` publica en el bus. `profiles_fn() -> [perfil]` (por defecto los de `profile.py`).
    `store` = dict persistente para los cursores de `schedule` (el servicio lo guarda en `meta`). Reloj inyectable."""

    def __init__(self, emit_fn, profiles_fn=None, root=None, secrets_root=None, clock=time.time, store=None,
                 environ=None, grace=KILL_GRACE, enabled=True):
        self.emit_fn, self.root, self.secrets_root, self.clock = emit_fn, root, secrets_root, clock
        self.profiles_fn = profiles_fn or _load_profiles
        self.store = store if store is not None else {}
        self.environ, self.grace, self.enabled = environ, grace, enabled
        self.specs = []
        self._lock = threading.Condition()
        self._running = collections.Counter()
        self._queues = collections.defaultdict(collections.deque)
        self._history = collections.defaultdict(collections.deque)
        self._subjects = collections.Counter()        # (proyecto, nombre, kind, id) en ejecución
        self._active = 0
        self.stats = collections.defaultdict(lambda: collections.Counter())
        self.threads = []

    def reload(self):
        out = []
        for prof in self.profiles_fn():
            try:
                out += specs(prof)
            except Exception as e:  # noqa: BLE001 - un perfil roto no para a los demás
                log.warning("automatizaciones de %s: %s", prof.get("project"), e)
        self.specs = out
        return out

    def find(self, project, name):
        return next((s for s in self.specs if s["project"] == project and s["name"] == name), None)

    # -- qué dispara
    def matches(self, env):
        """[(spec, trigger)] que este sobre dispara (con anti-bucles)."""
        env = normalize(env)
        if not env or not self.enabled or env["cause"]["depth"] >= MAX_DEPTH:
            return []
        out = []
        for s in self.specs:
            if not s["enabled"] or env.get("project") != s["project"] or env.get("type") in s["emits"]:
                continue
            if env.get("type") == "automation.ran" and env["body"].get("automation") == s["name"]:
                continue
            for t in s["on"]:
                if t["type"] in ("schedule", "manual"):
                    continue
                if fnmatch.fnmatchcase(env.get("type") or "", t["type"]) and where_match(t.get("where"), env):
                    out.append((s, t))
                    break
        return out

    def on_event(self, env):
        env = normalize(env)
        hits = self.matches(env)
        for s, _ in hits:
            self.submit(s, env.get("type"), env)
        return [(s["project"], s["name"]) for s, _ in hits]

    def tick(self, now=None):
        """Revisa los `schedule`. Primera vez = siembra sin disparar. Tras una caída larga dispara una sola vez."""
        now = self.clock() if now is None else now
        fired = []
        if not self.enabled:
            return fired
        for s in self.specs:
            if not s["enabled"]:
                continue
            for i, t in enumerate(s["on"]):
                if t["type"] != "schedule":
                    continue
                key = "sched:%s:%s:%d" % (s["project"], s["name"], i)
                last = self.store.get(key)
                if last is None:
                    self.store[key] = now
                    continue
                last = float(last)
                due = False
                if t.get("_every"):
                    due = now - last >= t["_every"]
                elif t.get("_cron"):
                    m = (int(last) // 60 + 1) * 60
                    m = max(m, (int(now) // 60 - 1440) * 60)
                    while m <= now and not due:
                        due = cron_match(t["_cron"], m)
                        m += 60
                if due or t.get("_cron"):
                    self.store[key] = now
                if due:
                    fired.append((s["project"], s["name"]))
                    self.submit(s, "schedule", None)
        return fired

    # -- cola, límites y ejecución
    def _rate_ok(self, s, now):
        h = self._history[(s["project"], s["name"])]
        while h and now - h[0] >= 3600:
            h.popleft()
        if len(h) >= s["max_runs_per_hour"]:
            return False
        h.append(now)
        return True

    def submit(self, s, trigger, env, wait=False):
        """Encola una ejecución. Devuelve "started" | "queued" | "duplicate" | "rate_limited" | "queue_full"."""
        key = (s["project"], s["name"])
        subj = ((env or {}).get("subject") or {})
        skey = (subj.get("kind"), subj.get("id")) if subj.get("id") else None
        with self._lock:
            q = self._queues[key]
            if skey and any(item[2] == skey for item in q):
                self.stats[key]["duplicate"] += 1
                return "duplicate"
            if s["concurrency"] == 1 and skey and self._subjects[key + skey]:
                self.stats[key]["duplicate"] += 1
                return "duplicate"
            if len(q) >= QUEUE_MAX:
                self.stats[key]["queue_full"] += 1
                return "queue_full"
            if not self._rate_ok(s, self.clock()):
                self.stats[key]["rate_limited"] += 1
                if self.stats[key]["rate_limited"] == 1:
                    log.warning("automatización %s/%s: max_runs_per_hour alcanzado", *key)
                return "rate_limited"
            q.append((trigger, env, skey))
            self._active += 1
            started = self._pump(s)
        if wait:
            self.wait_idle()
        return "started" if started else "queued"

    def _pump(self, s):
        key = (s["project"], s["name"])
        started = False
        while self._queues[key] and self._running[key] < s["concurrency"]:
            trigger, env, skey = self._queues[key].popleft()
            self._running[key] += 1
            self.stats[key]["peak"] = max(self.stats[key]["peak"], self._running[key])
            if skey:
                self._subjects[key + skey] += 1
            th = threading.Thread(target=self._worker, args=(s, trigger, env, skey), daemon=True,
                                  name="chopshop-automation-%s" % s["name"])
            self.threads.append(th)
            th.start()
            started = True
        return started

    def _worker(self, s, trigger, env, skey):
        key = (s["project"], s["name"])
        try:
            r = run_once(s, self.emit_fn, trigger, env, self.root, self.secrets_root, self.environ, self.grace,
                         next_run_fn=lambda: next_run(s, self.store, self.clock()))
            self.stats[key]["runs"] += 1
            if r["error"]:
                self.stats[key]["failed"] += 1
        except Exception:  # noqa: BLE001 - el hilo nunca se cae
            log.exception("automatización %s/%s", *key)
        finally:
            with self._lock:
                self._running[key] -= 1
                if skey:
                    self._subjects[key + skey] -= 1
                self._active -= 1
                self._pump(s)
                self._lock.notify_all()

    def wait_idle(self, timeout=None):
        end = None if timeout is None else time.monotonic() + timeout
        with self._lock:
            while self._active:
                left = None if end is None else end - time.monotonic()
                if left is not None and left <= 0:
                    return False
                self._lock.wait(left)
        return True


class MetaStore:
    """Cursores de `schedule` en la tabla `meta` del agente (clave `automation:<...>`): sobreviven a reinicios."""

    def __init__(self, conn):
        self.conn = conn

    def get(self, key, default=None):
        from . import db  # noqa: PLC0415
        with db.tx():
            row = self.conn.execute("SELECT value FROM meta WHERE key=?", ("automation:" + key,)).fetchone()
        return row["value"] if row else default

    def __setitem__(self, key, value):
        from . import db  # noqa: PLC0415
        with db.tx():
            self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ("automation:" + key, str(value)))


def _load_profiles():
    from .. import profile  # noqa: PLC0415
    out = []
    for p in profile.list_projects():
        try:
            prof = profile.load(p)
        except profile.ProfileError as e:
            log.warning("perfil %s: %s", p, e)
            continue
        if prof.get("automations"):
            out.append(prof)
    return out


# ---------------------------------------------------------------- CLI: chopshop automation ...

def _profile(project):
    from .. import profile  # noqa: PLC0415
    return profile.load(project)


def runtime_problems(spec, root=None, secrets_root=None):
    """Lo que `check` mira además del perfil: carpeta, cwd, ejecutable y secretos (errores, avisos)."""
    errs, warns = [], []
    pdir = project_dir(spec["project"], root)
    if not os.path.isdir(pdir):
        errs.append("%s: no existe la carpeta %s (créala con `chopshop automation add`)" % (spec["name"], pdir))
        return errs, warns
    if os.stat(pdir).st_mode & 0o077:
        warns.append("%s: %s es accesible por otros: chmod 700" % (spec["name"], pdir))
    cwd = os.path.join(pdir, spec["cwd"])
    if not os.path.isdir(cwd):
        errs.append("%s: cwd no existe: %s" % (spec["name"], cwd))
        return errs, warns
    exe = spec["run"][0]
    if "/" in exe:
        if not os.access(os.path.join(cwd, exe), os.X_OK):
            errs.append("%s: %s no existe o no es ejecutable" % (spec["name"], exe))
    elif not shutil.which(exe, path=MIN_PATH):
        errs.append("%s: %s no está en el PATH mínimo (%s); usa una ruta absoluta" % (spec["name"], exe, MIN_PATH))
    for arg in spec["run"][1:]:
        if not arg.startswith("-") and re.search(r"\.(py|sh|js|rb|pl)$", arg) and not os.path.isfile(os.path.join(cwd, arg)):
            errs.append("%s: falta el script %s en %s" % (spec["name"], arg, cwd))
    for name in spec["secrets"]:
        p = os.path.join(secrets_dir(secrets_root), name)
        if not os.path.isfile(p):
            warns.append("%s: falta el secreto %s (no se pasará %s)" % (spec["name"], name, secret_var(name)))
        elif os.stat(p).st_mode & 0o077:
            warns.append("%s: el secreto %s es legible por otros: chmod 600" % (spec["name"], name))
    return errs, warns


def _summary(t):
    if t["type"] == "schedule":
        return "schedule(%s)" % (t.get("every") or t.get("cron"))
    return t["type"] + (" where %s" % json.dumps(t["where"], ensure_ascii=False) if t.get("where") else "")


def _projects(a):
    from .. import profile  # noqa: PLC0415
    return [a.project] if a.project else profile.list_projects()


def cmd_list(a, out, err):
    for p in _projects(a):
        prof = _profile(p)
        for s in specs(prof):
            print("%s/%s  %s  run=%s  emits=%s%s" % (p, s["name"], ", ".join(_summary(t) for t in s["on"]), " ".join(s["run"]),
                                                     ",".join(s["emits"]) or "-", "" if s["enabled"] else "  (desactivada)"), file=out)
    return 0


def cmd_check(a, out, err):
    bad = 0
    for p in _projects(a):
        prof = _profile(p)
        if not prof.get("automations"):
            continue
        errs = validate(prof)
        warns = []
        for s in specs(prof):
            e, w = runtime_problems(s, a.root, a.secrets)
            errs += e
            warns += w
        for e in errs:
            print("error: %s: %s" % (p, e), file=out)
        for w in warns:
            print("aviso: %s: %s" % (p, w), file=out)
        if not errs:
            print("ok: %s (%d automatizaciones)" % (p, len(prof["automations"])), file=out)
        bad += bool(errs)
    return 1 if bad else 0


def _db_emitter():
    """Publica en la DB del agente (SQLite WAL admite varios procesos), con entrega de webhooks esperando al final."""
    from . import config, db  # noqa: PLC0415
    cfg = config.load()
    conn = db.connect(cfg["db_path"])
    return lambda env: bus_emit(conn, cfg, env, wait=True)


def bus_emit(conn, cfg, env, poster=None, wait=False):
    """Sobre parcial -> bus del agente (`events.emit_envelope`, que valida y asigna id/seq/ts). Devuelve el sobre guardado."""
    from . import events  # noqa: PLC0415
    return events.emit_envelope(conn, cfg, env["type"], env.get("project"), env.get("body") or {}, env.get("subject"),
                                env.get("severity"), env.get("needs"), env.get("cause"), poster=poster, wait=wait)


def cmd_run(a, out, err):
    s = next((x for x in specs(_profile(a.project)) if x["name"] == a.name), None)
    if not s:
        print("error: %s no tiene la automatización %s (o es inválida: `chopshop automation check`)" % (a.project, a.name), file=err)
        return 1
    trig = None
    if a.event_file:
        with open(os.path.expanduser(a.event_file), encoding="utf-8") as f:
            trig = normalize(json.load(f))
    printed = []
    publish = None if a.dry_run else _db_emitter()

    def emit(e):
        printed.append(e)
        if publish:
            publish(e)
    r = run_once(s, emit, "manual", trig, a.root, a.secrets)
    if a.json:
        print(json.dumps({k: r[k] for k in ("exit", "timed_out", "duration_ms", "emitted", "discarded", "error")}
                         | {"envelopes": printed}, ensure_ascii=False, indent=1), file=out)
    else:
        for e in printed:
            print(json.dumps(e, ensure_ascii=False), file=out)
        print("%s/%s: exit=%s %dms emitidos=%d descartados=%d%s" % (a.project, a.name, r["exit"], r["duration_ms"], r["emitted"],
                                                                    r["discarded"], (" error: " + r["error"]) if r["error"] else ""), file=out)
    return 0 if not r["error"] else 1


def cmd_logs(a, out, err):
    for r in read_log(a.project, a.name, a.n, a.root):
        print("%s  exit=%s %sms emitidos=%s descartados=%s trigger=%s%s" % (
            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r.get("ts") or 0)), r.get("exit"), r.get("duration_ms"),
            r.get("emitted"), r.get("discarded"), r.get("trigger"), ("  error: %s" % r["error"]) if r.get("error") else ""), file=out)
    return 0


def snippet(name, script, on, emits, timeout):
    interp = {".py": "python3", ".sh": "sh", ".js": "node"}.get(os.path.splitext(script)[1])
    run = "[%s]" % ", ".join(([interp] if interp else []) + [script if interp else "./" + script])
    lines = ["  - name: %s" % name, "    on:"]
    for t in on:
        if t.startswith("every:") or t.startswith("cron:"):
            k, _, v = t.partition(":")
            lines += ["      - type: schedule", "        %s: %s" % (k, json.dumps(v.strip()) if k == "cron" else v.strip())]
        else:
            lines.append("      - type: %s" % t)
    lines += ["    run: %s" % run, "    timeout: %d" % timeout, "    emits: [%s]" % ", ".join(emits)]
    return "\n".join(lines) + "\n"


def cmd_add(a, out, err):
    """Copia el script a la carpeta del proyecto (0700) e imprime (o añade) la declaración del perfil."""
    from .. import profile  # noqa: PLC0415
    if not _NAME.match(a.name):
        print("error: nombre inválido: %s" % a.name, file=err)
        return 2
    prof = _profile(a.project)
    pdir = project_dir(a.project, a.root, create=True)
    dest = os.path.join(pdir, os.path.basename(a.script))
    if os.path.exists(dest) and not a.force:
        print("error: ya existe %s (usa --force para reemplazarlo)" % dest, file=err)
        return 1
    shutil.copyfile(os.path.expanduser(a.script), dest)
    os.chmod(dest, 0o700)
    text = snippet(a.name, os.path.basename(a.script), a.on or ["manual"], a.emits or [], a.timeout)
    if a.append:
        if prof.get("automations") is not None:
            print("error: el perfil ya tiene `automations:`; añade a mano:\n%s" % text, file=err)
            return 1
        path = prof["_path"]
        with open(path, encoding="utf-8") as f:
            old = f.read()
        with open(path, "w", encoding="utf-8") as f:
            f.write(old + ("" if old.endswith("\n") or not old else "\n") + "automations:\n" + text)
        errs = validate(profile.load(a.project))
        if errs:
            with open(path, "w", encoding="utf-8") as f:
                f.write(old)
            for e in errs:
                print("error: %s" % e, file=err)
            return 1
        print("script copiado a %s; perfil %s actualizado" % (dest, path), file=out)
    else:
        print("script copiado a %s; añade al perfil (%s):\nautomations:\n%s" % (dest, prof["_path"], text), file=out)
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="chopshop automation", description="Automatizaciones por proyecto (perfil `automations:`)")
    p.add_argument("--root", help=argparse.SUPPRESS)        # carpeta de scripts (tests); por defecto <home>/automations
    p.add_argument("--secrets", help=argparse.SUPPRESS)     # carpeta de secretos (tests); por defecto <home>/secrets
    sp = p.add_subparsers(dest="cmd", required=True)
    x = sp.add_parser("list", help="automatizaciones declaradas")
    x.add_argument("project", nargs="?")
    x.set_defaults(f=cmd_list)
    x = sp.add_parser("check", help="valida perfil, carpeta, ejecutables y secretos")
    x.add_argument("project", nargs="?")
    x.set_defaults(f=cmd_check)
    x = sp.add_parser("run", help="ejecuta ya (disparador manual); publica en el bus del agente salvo --dry-run")
    x.add_argument("project")
    x.add_argument("name")
    x.add_argument("--event-file", help="sobre JSON que hace de disparador")
    x.add_argument("--dry-run", action="store_true", help="solo imprime los sobres, no los publica")
    x.add_argument("--json", action="store_true")
    x.set_defaults(f=cmd_run)
    x = sp.add_parser("logs", help="últimas ejecuciones")
    x.add_argument("project")
    x.add_argument("name", nargs="?")
    x.add_argument("-n", type=int, default=20)
    x.set_defaults(f=cmd_logs)
    x = sp.add_parser("add", help="copia un script a ~/.chopshop/automations/<proyecto>/ y genera su declaración")
    x.add_argument("project")
    x.add_argument("name")
    x.add_argument("--script", required=True)
    x.add_argument("--on", action="append", help="tipo de sobre (glob), manual, every:6h o 'cron:0 9 * * 1' (repetible)")
    x.add_argument("--emits", action="append")
    x.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    x.add_argument("--append", action="store_true", help="añade el bloque al perfil (solo si aún no tiene automations:)")
    x.add_argument("--force", action="store_true")
    x.set_defaults(f=cmd_add)
    return p


def main(argv, stdout=None, stderr=None):
    from .. import miniyaml, profile  # noqa: PLC0415
    out, err = stdout or sys.stdout, stderr or sys.stderr
    try:
        a = build_parser().parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 2
    try:
        return a.f(a, out, err) or 0
    except (profile.ProfileError, miniyaml.YamlError, AutomationError, OSError, ValueError) as e:
        print("error: %s" % e, file=err)
        return 1
