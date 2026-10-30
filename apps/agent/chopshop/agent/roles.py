"""Roles permanentes por oficina (docs/plans/office-redesign.md §5, fase 6): modelo, escritorio y despertar.

- Un departamento `permanent: true` cuyo rol declara `office.roles.<rol>.wake` se **despierta** con los disparadores de
  `automations.py`: `schedule` (`cron`/`every`, hora local de la box), `type: <evento>` con `where` sobre los sobres del bus
  (p. ej. `github.issue.opened` del polling de GitHub), `manual` y `desk.note` (una nota de bot en ese escritorio: lo despierta
  si está libre; si está ocupado la nota se queda en la bandeja de `notes.py`). Las notas vivas del escritorio entran en el
  prompt del despertar y se consumen al lanzarlo.
- Al despertar se elige el primer escritorio permanente libre del rol (piso más bajo primero) y se crea un **lote de una
  tarea** en el motor (`engine.create_batch`, con `role`/`desk`/`wake` en la tarea) con el prompt del rol (`prompt_file`,
  relativo a `~/.chopshop/automations/<proyecto>/`) + el disparador + la herencia del ocupante anterior. El hilo de
  `engine.tick` lo lanza en T3; cuando aparece su `threadId`, `assign_fn` lo sienta en el escritorio (por defecto emite
  `desk.assigned reason: wake`); cuando la tarea termina, el despertar se cierra.
- **Una sola instancia viva por escritorio**: si todos los escritorios del rol tienen un despertar vivo, el disparo queda como
  **despertar pendiente** del escritorio (varios se fusionan en uno, en `meta` `role:pending:<escritorio>`) y se lanza al
  terminar el hilo vivo.
- Tope `max_wakes_per_hour` por escritorio; anti-bucles: `cause.depth >= 3` no despierta.
- Tabla propia `desk_wakes`, creada con `ensure_schema` (idempotente, sin tocar `user_version`).
Todo lo externo es inyectable (perfiles, lanzamiento, lectura de la tarea, asiento, reloj)."""
import fnmatch
import json
import logging
import os
import time

from .. import cloudsync
from . import automations, db, envelope, layout, notes as notes_mod

log = logging.getLogger("chopshop.agent.roles")

PROMPT_MAX = 32 * 1024            # bytes leídos del prompt_file
SUMMARY_MAX = 1500
MAX_WAKES_PER_HOUR = 6
PENDING_SEEN = 10                 # disparos pendientes que se citan en el prompt (el resto solo cuenta)
CURSOR = "roles_cursor"
BATCH = 500
RELOAD = 60.0
LIVE = ("launching", "live")

SCHEMA = """
CREATE TABLE IF NOT EXISTS desk_wakes (
  id TEXT PRIMARY KEY, desk_id TEXT NOT NULL, project TEXT NOT NULL, role TEXT NOT NULL, trigger TEXT NOT NULL,
  cause_id TEXT, batch_id TEXT, task_id TEXT, thread_id TEXT,
  state TEXT NOT NULL,                            -- launching | live | ended | failed
  created REAL NOT NULL, ended REAL, error TEXT);
CREATE INDEX IF NOT EXISTS desk_wakes_desk ON desk_wakes(desk_id, state);
"""


class RolesError(Exception):
    pass


def ensure_schema(conn):
    with db.tx():
        for sql in SCHEMA.split(";"):
            if sql.strip():
                conn.execute(sql)


# ---------------------------------------------------------------- despertares (tabla)

def wakes(conn, desk=None, states=None, limit=50):
    sql, args = "SELECT * FROM desk_wakes", []
    cond = []
    if desk:
        cond.append("desk_id=?")
        args.append(desk)
    if states:
        cond.append("state IN (%s)" % ",".join("?" * len(states)))
        args += list(states)
    if cond:
        sql += " WHERE " + " AND ".join(cond)
    sql += " ORDER BY created DESC, id DESC LIMIT ?"
    args.append(limit)
    with db.tx():
        return db.rows(conn.execute(sql, args))


def _set_wake(conn, wid, **cols):
    with db.tx():
        conn.execute("UPDATE desk_wakes SET %s WHERE id=?" % ", ".join("%s=?" % k for k in cols), list(cols.values()) + [wid])


# ---------------------------------------------------------------- perfil -> escritorios que despiertan

def permanent_roles(prof):
    """[{project, role, desks:[id], triggers, prompt_file, prof}] de los roles con `wake` y departamento permanente."""
    out = []
    for role, spec in layout.roles(prof).items():
        trs = layout.wake_triggers(prof, role)
        ds = [d["id"] for d in layout.desks(prof) if d["role"] == role and d["permanent"]]
        if not trs or not ds:
            continue
        out.append({"project": prof.get("project"), "role": role, "desks": ds, "triggers": trs,
                    "prompt_file": spec.get("prompt_file") if isinstance(spec, dict) else None, "prof": prof})
    return out


def read_prompt(project, rel, root=None):
    """Texto del `prompt_file` (dentro de la carpeta del proyecto; nunca fuera) o None si no hay o no se puede leer."""
    if not rel:
        return None
    base = os.path.realpath(cloudsync.prompts_dir(project) if cloudsync.is_cloud(project) else automations.project_dir(project, root))
    path = os.path.realpath(os.path.join(base, rel))
    if not path.startswith(base + os.sep):
        log.warning("prompt_file de %s fuera de %s: se ignora", project, base)
        return None
    try:
        with open(path, "rb") as f:
            return f.read(PROMPT_MAX).decode("utf-8", "replace")
    except OSError:
        log.warning("no pude leer el prompt_file %s de %s", rel, project)
        return None


def describe(env):
    """Una línea legible del sobre que despierta (tipo, sujeto, título, url)."""
    if not env:
        return None
    s = env.get("subject") or {}
    b = env.get("body") or {}
    parts = [env.get("type") or "?", s.get("id") or ""]
    title = s.get("title") or b.get("title")
    if title:
        parts.append("· %s" % title)
    url = s.get("url") or b.get("url")
    if url:
        parts.append("(%s)" % url)
    return " ".join(p for p in parts if p)[:500]


def compose(role, desk, trigger, prompt_text, inheritance, trigger_env=None, pending=None, notes_text=None):
    """Prompt del despertar: rol + disparador + herencia + restricciones (el motor antepone las reglas del perfil)."""
    out = ["[Chopshop] Rol permanente `%s` en el escritorio %s. Te despertó: %s." % (role, desk, describe(trigger_env) or trigger)]
    out.append("")
    out.append(prompt_text.strip() if prompt_text and prompt_text.strip()
               else "Revisa los pendientes de tu rol en este proyecto y deja un resumen claro de lo que encontraste y propones.")
    if inheritance:
        out += ["", "## Herencia (ocupante anterior del escritorio)"]
        out.append("- hilo: %s (%s)" % (inheritance.get("thread_id"), inheritance.get("phase") or "?"))
        for k, label in (("branch", "rama"), ("worktree", "worktree")):
            if inheritance.get(k):
                out.append("- %s: %s" % (label, inheritance[k]))
        if inheritance.get("pull_requests"):
            out.append("- PRs: %s" % ", ".join(map(str, inheritance["pull_requests"])))
        if inheritance.get("summary"):
            out += ["- resumen final:", inheritance["summary"].strip()]
    if pending:
        out += ["", "## Disparos mientras el ocupante anterior trabajaba (%d)" % pending["count"]]
        out += ["- %s" % d for d in pending["seen"]]
    if notes_text:
        out += ["", "## Notas", notes_text]
    out += ["", "## Restricciones",
            "- Propón; no comentes, etiquetes, cierres ni envíes mensajes fuera (GitHub, chats, correos) sin aprobación humana:"
            " pide permiso con la herramienta de preguntas.",
            "- Deja tu resultado en el último mensaje: lo hereda el próximo despertar de este escritorio."]
    return "\n".join(out)


def default_launch(prof, item):
    """Lote de una tarea en el motor (state.json); `engine.tick` (hilo `engine` del agente) lo lanza en T3."""
    from .. import engine  # noqa: PLC0415
    host, _cap, route_notes = engine.route(prof, 1)
    bid = engine.create_batch(prof, [item], host, 1, route_notes)
    return bid, "t-%s-1" % bid[2:]


def default_task(batch_id, task_id):
    from .. import state  # noqa: PLC0415
    b = state.read().get("batches", {}).get(batch_id)
    return next((t for t in (b or {}).get("tasks", []) if t.get("id") == task_id), None) if b else None


class MetaStore:
    """Cursores de `schedule` y despertares pendientes de los roles en `meta` (clave `role:<...>`)."""

    def __init__(self, conn):
        self.conn = conn

    def get(self, key, default=None):
        with db.tx():
            row = self.conn.execute("SELECT value FROM meta WHERE key=?", ("role:" + key,)).fetchone()
        return row["value"] if row else default

    def __setitem__(self, key, value):
        with db.tx():
            self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ("role:" + key, str(value)))


def _load_profiles():
    from .. import profile  # noqa: PLC0415
    from . import registry
    out = []
    for p in registry.profiles():
        try:
            prof = profile.load(p)
        except profile.ProfileError as e:
            log.warning("perfil %s: %s", p, e)
            continue
        if layout.roles(prof):
            out.append(prof)
    return out


# ---------------------------------------------------------------- motor

class Roles:
    """Despierta roles permanentes. `emit_fn(sobre_parcial) -> sobre guardado` publica en el bus (como las automatizaciones).

    `launch_fn(perfil, tarea) -> (batch_id, task_id)`; `task_fn(batch_id, task_id) -> tarea de state.json | None`;
    `assign_fn(**kw)` sienta el hilo en el escritorio (por defecto, sobre `desk.assigned reason: wake`; la oficina de escritorios puede sustituirlo)."""

    def __init__(self, conn, emit_fn, profiles_fn=None, launch_fn=None, task_fn=None, assign_fn=None,
                 clock=time.time, store=None, root=None, enabled=True, max_wakes_per_hour=MAX_WAKES_PER_HOUR):
        self.conn, self.emit_fn, self.clock, self.root = conn, emit_fn, clock, root
        self.profiles_fn = profiles_fn or _load_profiles
        self.launch_fn = launch_fn or default_launch
        self.task_fn = task_fn or default_task
        self.assign_fn = assign_fn or self._emit_assigned
        self.store = store if store is not None else MetaStore(conn)
        self.enabled, self.max_wakes_per_hour = enabled, max_wakes_per_hour
        self.roles = []
        self._loaded = None
        self._cursor = None
        ensure_schema(conn)

    # -- perfiles
    def reload(self):
        out = []
        for prof in self.profiles_fn():
            try:
                out += permanent_roles(prof)
            except Exception as e:  # noqa: BLE001 - un perfil roto no para a los demás
                log.warning("roles de %s: %s", prof.get("project"), e)
        self.roles = out
        self._loaded = self.clock()
        return out

    def find(self, project, role):
        return next((r for r in self.roles if r["project"] == project and r["role"] == role), None)

    # -- emisión
    def _emit(self, type, project, body, cause=None):
        try:
            return self.emit_fn({"type": type, "project": project, "body": body, "cause": cause})
        except Exception:  # noqa: BLE001 - el bus no debe frenar el despertar
            log.exception("no pude emitir %s", type)
            return None

    def _emit_assigned(self, project, desk, thread_id, role, inheritance=None, title=None, cause=None):
        body = {"desk": desk, "thread_id": thread_id, "role": role, "reason": "wake", "inheritance": inheritance,
                "since": envelope.iso(self.clock())}
        if title:
            body["title"] = title
        return self._emit("desk.assigned", project, body, cause)

    # -- disparadores
    def matches(self, env):
        """[(rol, disparador)] que este sobre despierta (con anti-bucles; `desk.*`/`office.*` nunca despiertan)."""
        env = automations.normalize(env)
        if not env or env["cause"]["depth"] >= automations.MAX_DEPTH:
            return []
        ty = env.get("type") or ""
        if ty == layout.WAKE_EVENT:                       # nota de bot: despierta ese escritorio si su rol la declara
            desk = (env.get("body") or {}).get("desk")
            return [(r, t, desk) for r in self.roles if env.get("project") == r["project"] and desk in r["desks"]
                    for t in r["triggers"] if t.get("type") == layout.WAKE_EVENT][:1]
        if ty.startswith(("desk.", "office.")):
            return []
        out = []
        for r in self.roles:
            if env.get("project") != r["project"]:
                continue
            for t in r["triggers"]:
                if t.get("type") in ("schedule", "manual", layout.WAKE_EVENT):
                    continue
                if fnmatch.fnmatchcase(ty, t["type"]) and automations.where_match(t.get("where"), env):
                    out.append((r, t, None))
                    break
        return out

    def on_event(self, env):
        """Un sobre del bus -> despertares. Devuelve [(proyecto, rol, resultado)]."""
        if not self.enabled:
            return []
        env = automations.normalize(env)
        if not env:
            return []
        return [(r["project"], r["role"], self.wake(r, env.get("type"), env, desk=d)) for r, _, d in self.matches(env)]

    def tick(self, now=None):
        """Horarios (`schedule`) de los roles. Primera vez = siembra sin disparar; tras una caída larga dispara una sola vez."""
        now = self.clock() if now is None else now
        fired = []
        if not self.enabled:
            return fired
        for r in self.roles:
            for i, t in enumerate(r["triggers"]):
                if t.get("type") != "schedule":
                    continue
                key = "sched:%s:%s:%d" % (r["project"], r["role"], i)
                last = self.store.get(key)
                if last is None:
                    self.store[key] = now
                    continue
                last, due = float(last), False
                if t.get("_every"):
                    due = now - last >= t["_every"]
                elif t.get("_cron"):
                    m = max((int(last) // 60 + 1) * 60, (int(now) // 60 - 1440) * 60)
                    while m <= now and not due:
                        due = automations.cron_match(t["_cron"], m)
                        m += 60
                if due or t.get("_cron"):
                    self.store[key] = now
                if due:
                    fired.append((r["project"], r["role"], self.wake(r, "schedule", None)))
        return fired

    def manual(self, project, role, by="manual"):
        r = self.find(project, role)
        if not r:
            raise RolesError("%s no tiene un rol permanente %s con wake" % (project, role))
        return self.wake(r, "manual", None, by=by)

    # -- despertar
    def _rate_ok(self, desk, now):
        with db.tx():
            n = self.conn.execute("SELECT COUNT(*) FROM desk_wakes WHERE desk_id=? AND created > ? AND state != 'failed'",
                                  (desk, now - 3600)).fetchone()[0]
        return n < self.max_wakes_per_hour

    def wake(self, r, trigger, env=None, desk=None, by=None):
        """Despierta el rol: "launched" | "pending" | "rate_limited" | "failed" | "disabled"."""
        if not self.enabled:
            return "disabled"
        now = self.clock()
        live = {w["desk_id"] for w in wakes(self.conn, None, LIVE, 500)}
        free = [d for d in r["desks"] if d not in live] if desk is None else ([desk] if desk not in live else [])
        if not free:
            if trigger == layout.WAKE_EVENT:              # la nota ya espera en la bandeja; la lee el próximo despertar
                return "noted"
            self._add_pending(desk or r["desks"][0], "%s: %s" % (trigger, describe(env) or by or trigger))
            return "pending"
        target = free[0]
        if not self._rate_ok(target, now):
            log.warning("rol %s/%s: max_wakes_per_hour alcanzado en %s", r["project"], r["role"], target)
            return "rate_limited"
        wid = envelope.new_id(now)
        pending = self._take_pending(target)
        inh = self.inheritance(target)
        inbox = notes_mod.pending(self.conn, target, now)
        prompt = compose(r["role"], target, trigger, read_prompt(r["project"], r["prompt_file"], self.root), inh, env, pending,
                         notes_mod.prompt_block(inbox))
        item = {"title": "[%s] despertar · %s" % (r["role"], trigger), "prompt": prompt, "role": r["role"], "desk": target,
                "wake": wid}
        try:
            bid, tid = self.launch_fn(r["prof"], item)
        except Exception as e:  # noqa: BLE001 - perfil sin host, state.json bloqueado...
            if pending:
                self.store["pending:" + target] = json.dumps(pending)
            log.warning("no pude despertar %s/%s en %s: %s", r["project"], r["role"], target, e)
            with db.tx():
                self.conn.execute("INSERT INTO desk_wakes(id, desk_id, project, role, trigger, cause_id, state, created, ended, error)"
                                  " VALUES(?,?,?,?,?,?,?,?,?,?)", (wid, target, r["project"], r["role"], trigger,
                                                                    (env or {}).get("id"), "failed", now, now, str(e)[:300]))
            return "failed"
        if inbox:
            notes_mod.consume(self.conn, target, now, by=wid)
        with db.tx():
            self.conn.execute("INSERT INTO desk_wakes(id, desk_id, project, role, trigger, cause_id, batch_id, task_id, state, created)"
                              " VALUES(?,?,?,?,?,?,?,?,?,?)", (wid, target, r["project"], r["role"], trigger, (env or {}).get("id"),
                                                               bid, tid, "launching", now))
        log.info("rol %s/%s despertado en %s (%s) -> lote %s", r["project"], r["role"], target, trigger, bid)
        return "launched"

    # -- despertares pendientes (disparos mientras el escritorio está ocupado; se fusionan en uno)
    def _add_pending(self, desk, desc):
        p = self._pending(desk) or {"count": 0, "seen": []}
        p["count"] += 1
        p["seen"] = (p["seen"] + [desc[:300]])[-PENDING_SEEN:]
        self.store["pending:" + desk] = json.dumps(p, ensure_ascii=False)

    def _pending(self, desk):
        try:
            p = json.loads(self.store.get("pending:" + desk) or "null")
        except ValueError:
            return None
        return p if isinstance(p, dict) and p.get("count") else None

    def _take_pending(self, desk):
        p = self._pending(desk)
        if p:
            self.store["pending:" + desk] = ""
        return p

    def inheritance(self, desk):
        """Lo que hereda el próximo ocupante: el último despertar terminado del escritorio (hilo, resumen, rama, PRs)."""
        prev = next((w for w in wakes(self.conn, desk, ("ended",), 5) if w["thread_id"]), None)
        if not prev:
            return None
        task = None
        try:
            task = self.task_fn(prev["batch_id"], prev["task_id"]) if prev["batch_id"] else None
        except Exception:  # noqa: BLE001
            task = None
        with db.tx():
            th = self.conn.execute("SELECT title, status, worktree, branch, extra FROM t3_threads WHERE thread_id=?",
                                   (prev["thread_id"],)).fetchone()
        th = dict(th) if th else {}
        extra = db.jload(th.get("extra"), {}) or {}
        return {"thread_id": prev["thread_id"], "title": th.get("title") or (task or {}).get("title"),
                "summary": ((task or {}).get("result") or "")[:SUMMARY_MAX] or None, "branch": th.get("branch"),
                "worktree": th.get("worktree"),
                "pull_requests": (task or {}).get("pullRequests") or extra.get("pull_requests") or [],
                "phase": "failed" if (task or {}).get("t3status") in ("failed", "cancelled", "interrupted") else "done",
                "ended_at": envelope.iso(prev["ended"]) if prev["ended"] else None}

    # -- seguimiento de los despertares vivos
    def sync(self, now=None):
        """Avanza los despertares vivos: hilo lanzado -> `assign_fn`; tarea terminada -> fin (y el despertar pendiente del
        escritorio, si lo hay). Devuelve [(desk, evento)]."""
        now = self.clock() if now is None else now
        out = []
        for w in reversed(wakes(self.conn, None, LIVE, 500)):
            try:
                task = self.task_fn(w["batch_id"], w["task_id"])
            except Exception as e:  # noqa: BLE001 - state.json ilegible: se reintenta
                log.warning("no pude leer la tarea %s/%s: %s", w["batch_id"], w["task_id"], e)
                continue
            if task is None:
                _set_wake(self.conn, w["id"], state="failed", ended=now, error="la tarea desapareció de state.json")
                out.append((w["desk_id"], "lost"))
                continue
            thread = task.get("threadId")
            if w["state"] == "launching" and thread:
                _set_wake(self.conn, w["id"], state="live", thread_id=thread)
                w = dict(w, state="live", thread_id=thread)
                self.assign_fn(project=w["project"], desk=w["desk_id"], thread_id=thread, role=w["role"],
                               inheritance=self.inheritance(w["desk_id"]), title=task.get("title"))
                out.append((w["desk_id"], "assigned"))
            if task.get("done"):
                if w["state"] == "launching":
                    why = task.get("last_error") or task.get("status") or "sin hilo"
                    _set_wake(self.conn, w["id"], state="failed", ended=now, error=str(why)[:300])
                    out.append((w["desk_id"], "failed"))
                    self._rewake(w, out)
                    continue
                _set_wake(self.conn, w["id"], state="ended", ended=now)
                out.append((w["desk_id"], "ended"))
                self._rewake(w, out)
        return out

    def _rewake(self, w, out):
        r = self.find(w["project"], w["role"])
        if r and self.enabled and self._pending(w["desk_id"]):
            out.append((w["desk_id"], "rewake:" + self.wake(r, "pending", None, desk=w["desk_id"])))

    # -- pasada del servicio
    def once(self, list_after, last_seq, now=None):
        """Relee perfiles (cada RELOAD s), despacha los sobres nuevos del bus (cursor en `meta`), revisa horarios y sigue
        los despertares vivos. `list_after(conn, seq, n)` / `last_seq(conn)` = las de `events`."""
        now = self.clock() if now is None else now
        if self._loaded is None or now - self._loaded >= RELOAD:
            self.reload()
        row_missing = False
        if self._cursor is None:
            with db.tx():
                row = self.conn.execute("SELECT value FROM meta WHERE key=?", (CURSOR,)).fetchone()
            self._cursor = int(row["value"]) if row and str(row["value"]).isdigit() else last_seq(self.conn)
            row_missing = not row
        fired = []
        rows = list_after(self.conn, self._cursor, BATCH)
        for r in rows:
            fired += self.on_event(r)
            self._cursor = r["seq"]
        if rows or row_missing:
            with db.tx():
                self.conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (CURSOR, str(self._cursor)))
        fired += self.tick(now)
        self.sync(now)
        return fired

