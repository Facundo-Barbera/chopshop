"""Oficina por escritorios (docs/plans/office-redesign.md §2, §3 y §7): asigna escritorios a los hilos con rol, gestiona la
herencia, el vestíbulo y la salida por semivida. Emite `office.changed`, `desk.assigned`, `desk.released` y `desk.waiting`.

- `Office(conn, cfg, emit_fn, profiles_fn=None, clock=time.time)`; `emit_fn(type, project, body, **kw) -> sobre`
  (el servicio lo envuelve sobre `events.emit_envelope` y despierta al `/stream`).
- `reload()`: relee los perfiles con bloque `office:`; sincroniza la tabla `desks` (los que el perfil deja de declarar quedan
  `retired`, nunca se borran; su ocupante sale con `reason: retired`) y emite `office.changed {by: "profile"}` cuando cambia la
  estructura (o cuando el último ya no está retenido en `events`).
- `tick(now=None)`: pliega los `task.state` nuevos del bus (cursor `office_cursor` en `meta`), asigna/encola y saca a los que
  se desvanecieron. La primera vez (sin cursor) siembra en silencio con el historial retenido y solo sienta a los activos.
- `touch(thread_id)`: reinicia el reloj de semivida y reemite su `task.state` con `touched_at`.
- `assign(desk_id, thread_id)`: asignación manual (bot o humano): `desk.assigned reason: manual`.
- `desk(desk_id)`: escritorio, ocupante, linaje completo (`GET /desks/<id>`).

Reglas de asignación (por rol y proyecto, piso más bajo primero): si algún ocupante del rol está en semivida, el nuevo hilo
**hereda** el más desvanecido (sale con `desk.released reason: inherited`, entra con `desk.assigned reason: inherited`); si no,
el primer escritorio libre (`reason: start`). La herencia es el último ocupante del escritorio (en semivida o ya del linaje).
Rol lleno (o sin escritorios) -> vestíbulo con `desk.waiting`; sube en cuanto un escritorio del rol queda libre o en
semivida. Sin rol -> vestíbulo.
El rol de un hilo: `role` del cuerpo de `task.state` (lo pone Chopshop al lanzar, o t3watch por las reglas `match`), o el
último conocido; una asignación manual lo fija."""
import logging
import threading
import time

from .. import profile as profile_mod
from . import db, envelope, events, halflife, layout

log = logging.getLogger("chopshop.agent.office")

CURSOR = "office_cursor"
STRUCT = "office_struct:"           # meta: "<seq> <estructura JSON>" del último office.changed por proyecto
LINEAGE = 20                         # ocupantes pasados guardados por escritorio
LINEAGE_STATE = 5                    # los que manda la proyección
ACTIVE = ("queued", "preparing", "running", "waiting")
BATCH = 500
RELOAD = 60                          # s entre relecturas de perfiles
INHERIT_KEYS = ("thread_id", "title", "summary", "branch", "worktree", "pull_requests", "phase", "ended_at")
KEEP_KEYS = ("summary", "result", "role", "branch", "worktree", "title")   # no se pierden si un task.state posterior no los trae


def _load_profiles():
    out = []
    for name in profile_mod.list_projects():
        try:
            out.append(profile_mod.load(name))
        except profile_mod.ProfileError as e:
            log.warning("perfil %s: %s", name, e)
    return out


def _iso(ts):
    return envelope.iso(ts) if ts is not None else None


class Office:
    def __init__(self, conn, cfg, emit_fn, profiles_fn=None, clock=time.time):
        self.conn, self.cfg, self.emit_fn, self.clock = conn, cfg, emit_fn, clock
        self.profiles_fn = profiles_fn or _load_profiles
        self.half_life = {}           # proyecto -> T½ (s)
        self.company = {}             # proyecto -> empresa
        self._lock = threading.RLock()
        self._loaded = None           # instante de la última relectura de perfiles

    # ------------------------------------------------------------ utilidades de DB

    def _q(self, sql, args=()):
        with db.tx():
            return db.rows(self.conn.execute(sql, args))

    def _x(self, sql, args=()):
        with db.tx():
            return self.conn.execute(sql, args)

    def _meta(self, key):
        r = self._q("SELECT value FROM meta WHERE key=?", (key,))
        return r[0]["value"] if r else None

    def _set_meta(self, key, value):
        self._x("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", (key, str(value)))

    def _emit(self, type, project, body, **kw):
        return self.emit_fn(type, project, body, **kw)

    def _snap(self, tid):
        r = self._q("SELECT body FROM office_threads WHERE thread_id=?", (tid,))
        return (db.jload(r[0]["body"], {}) or {}) if r else None

    def _occupant(self, desk_id):
        r = self._q("SELECT * FROM desk_occupancy WHERE desk_id=? AND until IS NULL ORDER BY id DESC LIMIT 1", (desk_id,))
        return r[0] if r else None

    def _seat(self, tid):
        r = self._q("SELECT o.*, d.project, d.role FROM desk_occupancy o JOIN desks d ON d.id=o.desk_id"
                    " WHERE o.thread_id=? AND o.until IS NULL ORDER BY o.id DESC LIMIT 1", (tid,))
        return r[0] if r else None

    def _lobby(self, tid):
        r = self._q("SELECT * FROM office_lobby WHERE thread_id=?", (tid,))
        return r[0] if r else None

    def _hl(self, project):
        return self.half_life.get(project) or float(layout.DEFAULT_HALF_LIFE)

    def _role_desks(self, project, role):
        return self._q("SELECT * FROM desks WHERE project=? AND role=? AND retired=0 ORDER BY floor, slot", (project, role))

    # ------------------------------------------------------------ estructura

    def reload(self):
        """Sincroniza `desks` con los perfiles. Devuelve los proyectos cuyo `office.changed` se emitió."""
        with self._lock:
            changed = []
            known = {r["project"] for r in self._q("SELECT DISTINCT project FROM desks")}
            for prof in self.profiles_fn():
                project = prof.get("project")
                if not project or ("office" not in prof and project not in known):
                    continue
                try:
                    if self._sync(prof):
                        changed.append(project)
                except Exception:  # noqa: BLE001 - un perfil roto no para a los demás
                    log.exception("oficina de %s", project)
            self._loaded = self.clock()
            return changed

    def _sync(self, prof):
        project, now = prof["project"], self.clock()
        self.half_life[project] = layout.half_life_s(prof)
        self.company[project] = layout.company(prof)
        declared = {d["id"]: d for d in layout.desks(prof)}
        have = {r["id"]: r for r in self._q("SELECT * FROM desks WHERE project=?", (project,))}
        added, retired, reactivated = [], [], []
        for did, d in declared.items():
            old = have.get(did)
            if old is None:
                self._x("INSERT INTO desks(id, project, floor, role, slot, permanent, retired, created) VALUES(?,?,?,?,?,?,0,?)",
                        (did, project, d["floor"], d["role"], d["slot"], int(d["permanent"]), now))
                added.append(did)
            else:
                if old["retired"]:
                    reactivated.append(did)
                if old["retired"] or bool(old["permanent"]) != d["permanent"]:
                    self._x("UPDATE desks SET retired=0, permanent=? WHERE id=?", (int(d["permanent"]), did))
        for did, old in have.items():
            if did not in declared and not old["retired"]:
                self._x("UPDATE desks SET retired=1 WHERE id=?", (did,))
                retired.append(did)
        gone = [did for did, old in have.items() if did not in declared]
        struct = layout.structure(prof, gone)
        last = self._meta(STRUCT + project)
        last_seq, last_struct = (last.split(" ", 1) + [""])[:2] if last else ("0", "")
        stale = int(last_seq or 0) < self._min_seq()
        emitted = False
        if db.jdump(struct) != last_struct or stale:
            body = dict(struct, project=project, by="profile",
                        diff={"added": added, "retired": retired, "reactivated": reactivated})
            env = self._emit("office.changed", project, body)
            self._set_meta(STRUCT + project, "%s %s" % (env.get("seq") if env else 0, db.jdump(struct)))
            emitted = True
        for did in retired:
            occ = self._occupant(did)
            if occ:
                self._release(did, occ, "retired")
                snap = self._snap(occ["thread_id"]) or {}
                if snap.get("phase") in ACTIVE:
                    self._decide(occ["thread_id"], project, snap)
        for role in {declared[d]["role"] for d in added + reactivated}:
            self._promote(project, role)
        return emitted

    def _min_seq(self):
        r = self._q("SELECT COALESCE(MIN(seq),0) AS s FROM events")
        return r[0]["s"] if r else 0

    # ------------------------------------------------------------ bus

    def tick(self, now=None):
        """Pliega los sobres nuevos y saca a los desvanecidos. Devuelve el número de `task.state` procesados."""
        with self._lock:
            if self._loaded is None or self.clock() - self._loaded >= RELOAD:
                self.reload()
            cur = self._meta(CURSOR)
            n = 0
            if cur is None or not str(cur).isdigit():
                n = self._bootstrap()
            else:
                cur = int(cur)
                while True:
                    page = events.list_after(self.conn, cur, BATCH)
                    for env in page:
                        if env.get("type") == "task.state":
                            self.on_task_state(env)
                            n += 1
                        cur = env["seq"]
                    if page:
                        self._set_meta(CURSOR, cur)
                    if len(page) < BATCH:
                        break
            self.fade(self.clock() if now is None else now)
            return n

    def _bootstrap(self):
        """Primera pasada: guarda la última `task.state` de cada hilo sin decidir nada y luego sienta a los activos."""
        cur, n = 0, 0
        while True:
            page = events.list_after(self.conn, cur, BATCH)
            for env in page:
                if env.get("type") == "task.state":
                    self._remember(env)
                    n += 1
                cur = env["seq"]
            if len(page) < BATCH:
                break
        self._set_meta(CURSOR, cur)
        for r in self._q("SELECT thread_id, project, body FROM office_threads ORDER BY updated"):
            body = db.jload(r["body"], {}) or {}
            if body.get("phase") in ACTIVE and r["project"]:
                self._decide(r["thread_id"], r["project"], body)
        return n

    def _remember(self, env):
        """Guarda la última `task.state` del hilo (conservando `KEEP_KEYS` si la nueva no los trae). -> (tid, proyecto, cuerpo)."""
        body = {k: v for k, v in (env.get("body") or {}).items() if k not in ("legacy", "context")}
        tid = body.get("thread_id") or (env.get("subject") or {}).get("id")
        if not tid:
            return None, None, None
        old = self._snap(tid) or {}
        for k in KEEP_KEYS:
            if body.get(k) is None and old.get(k) is not None:
                body[k] = old[k]
        if body.get("phase") in halflife.TERMINAL:
            if body.get("ended_at") is None:
                body["ended_at"] = old.get("ended_at") if old.get("phase") in halflife.TERMINAL and old.get("ended_at") \
                    else env.get("ts")
        else:
            body["ended_at"] = None
        if body.get("touched_at") is None:
            t = self._q("SELECT touched_at FROM thread_touch WHERE thread_id=?", (tid,))
            body["touched_at"] = _iso(t[0]["touched_at"]) if t else old.get("touched_at")
        ts = envelope.epoch(env.get("ts")) or self.clock()
        self._x("INSERT OR REPLACE INTO office_threads(thread_id, project, body, updated) VALUES(?,?,?,?)",
                (tid, env.get("project"), db.jdump(body), ts))
        return tid, env.get("project"), body

    def on_task_state(self, env):
        with self._lock:
            tid, project, body = self._remember(env)
            if tid and project:
                self._decide(tid, project, body)

    def _decide(self, tid, project, body):
        role = body.get("role")                           # un rol sin escritorios espera en el vestíbulo con su etiqueta
        seat, active = self._seat(tid), body.get("phase") in ACTIVE
        if seat:
            if active and role and role != seat["role"]:  # cambió de rol: se traslada si hay sitio
                self._place(tid, project, role, body)
            elif halflife.fading(body.get("phase"), body.get("attention")):
                self._promote(project, seat["role"])      # entró en semivida: lo hereda quien espere ese rol
            return
        lob = self._lobby(tid)
        if active and role:
            if not self._place(tid, project, role, body) and not (lob and lob["role"] == role):
                self._x("INSERT OR REPLACE INTO office_lobby(thread_id, project, role, since) VALUES(?,?,?,?)",
                        (tid, project, role, lob["since"] if lob else self.clock()))
                self._emit("desk.waiting", project, {"thread_id": tid, "role": role, "title": body.get("title"),
                                                     "phase": body.get("phase")})
        elif active and lob is None:
            self._x("INSERT INTO office_lobby(thread_id, project, role, since) VALUES(?,?,NULL,?)",
                    (tid, project, self.clock()))
        elif active and lob["role"] and not role:
            self._x("UPDATE office_lobby SET role=NULL WHERE thread_id=?", (tid,))

    # ------------------------------------------------------------ asignación

    def _candidates(self, project, role):
        """(escritorio, ocupante|None) del rol: primero el ocupante en semivida más desvanecido, luego el primer libre."""
        now, fading, free = self.clock(), [], []
        for d in self._role_desks(project, role):
            occ = self._occupant(d["id"])
            if occ is None:
                free.append((d, None))
                continue
            s = self._snap(occ["thread_id"]) or {}
            if halflife.fading(s.get("phase"), s.get("attention")):
                op = halflife.opacity(s.get("phase"), s.get("attention"), s.get("ended_at"), s.get("touched_at"),
                                      self._hl(project), now)
                fading.append((op, d["floor"], d["slot"], d, occ))
        fading.sort(key=lambda x: x[:3])
        return [(x[3], x[4]) for x in fading] + free

    def _inheritance(self, desk_id, occ):
        prev = occ or next(iter(self._q("SELECT * FROM desk_occupancy WHERE desk_id=? AND until IS NOT NULL"
                                        " ORDER BY until DESC, id DESC LIMIT 1", (desk_id,))), None)
        if not prev:
            return None
        s = dict(self._snap(prev["thread_id"]) or {}, thread_id=prev["thread_id"])
        s.setdefault("summary", None)
        if s.get("summary") is None:
            s["summary"] = s.get("result")
        return {k: s.get(k) for k in INHERIT_KEYS}

    def _place(self, tid, project, role, body, desk=None, reason=None):
        """Sienta al hilo en un escritorio del rol (o en `desk`). Devuelve el id del escritorio o None si está lleno."""
        cands = [(desk, self._occupant(desk["id"]))] if desk else self._candidates(project, role)
        if not cands:
            return None
        d, occ = cands[0]
        if occ and occ["thread_id"] == tid:
            return d["id"]
        inh = self._inheritance(d["id"], occ)
        if occ:
            self._release(d["id"], occ, "inherited", promote=False)
        now = self.clock()
        old = self._seat(tid)
        if old:                                           # traslado: el escritorio anterior queda libre, sin linaje
            self._x("DELETE FROM desk_occupancy WHERE id=?", (old["id"],))
        self._x("INSERT INTO desk_occupancy(desk_id, thread_id, since, until, reason, inheritance) VALUES(?,?,?,NULL,?,?)",
                (d["id"], tid, now, reason or ("inherited" if occ else "start"), db.jdump(inh) if inh else None))
        self._x("DELETE FROM office_lobby WHERE thread_id=?", (tid,))
        self._emit("desk.assigned", project, {
            "desk": d["id"], "thread_id": tid, "role": d["role"], "reason": reason or ("inherited" if occ else "start"),
            "title": body.get("title"), "since": _iso(now), "inheritance": inh})
        if old:
            self._promote(old["project"], old["role"])
        return d["id"]

    def _release(self, desk_id, occ, reason, promote=True):
        now = self.clock()
        self._x("UPDATE desk_occupancy SET until=?, reason=? WHERE id=?", (now, reason, occ["id"]))
        self._x("DELETE FROM desk_occupancy WHERE desk_id=? AND until IS NOT NULL AND id NOT IN"
                " (SELECT id FROM desk_occupancy WHERE desk_id=? AND until IS NOT NULL ORDER BY until DESC, id DESC LIMIT ?)",
                (desk_id, desk_id, LINEAGE))
        d = self._q("SELECT project, role FROM desks WHERE id=?", (desk_id,))
        project = d[0]["project"] if d else None
        self._emit("desk.released", project, {"desk": desk_id, "thread_id": occ["thread_id"], "reason": reason})
        if promote and d:
            self._promote(project, d[0]["role"])

    def _promote(self, project, role):
        """Sube a los que esperan ese rol (los más antiguos primero) mientras haya escritorio."""
        for w in self._q("SELECT * FROM office_lobby WHERE project=? AND role=? ORDER BY since", (project, role)):
            s = self._snap(w["thread_id"]) or {}
            if s.get("phase") not in ACTIVE:
                continue
            if not self._place(w["thread_id"], project, role, s):
                break

    # ------------------------------------------------------------ semivida

    def fade(self, now):
        """Saca de escritorios y vestíbulo a los terminados cuya opacidad bajó de 0.1 (`desk.released reason: faded`)."""
        out = []
        for occ in self._q("SELECT o.*, d.project FROM desk_occupancy o JOIN desks d ON d.id=o.desk_id WHERE o.until IS NULL"):
            s = self._snap(occ["thread_id"])
            if s and halflife.gone(s.get("phase"), s.get("attention"), s.get("ended_at"), s.get("touched_at"),
                                   self._hl(occ["project"]), now):
                self._release(occ["desk_id"], occ, "faded")
                out.append(occ["thread_id"])
        for w in self._q("SELECT * FROM office_lobby"):
            s = self._snap(w["thread_id"])
            if s and halflife.gone(s.get("phase"), s.get("attention"), s.get("ended_at"), s.get("touched_at"),
                                   self._hl(w["project"]), now):
                self._x("DELETE FROM office_lobby WHERE thread_id=?", (w["thread_id"],))
                self._emit("desk.released", w["project"], {"desk": None, "thread_id": w["thread_id"], "reason": "faded",
                                                           "title": s.get("title")})
                out.append(w["thread_id"])
        return out

    # ------------------------------------------------------------ acciones (API)

    def touch(self, thread_id):
        """Reinicia el reloj de semivida (`touched_at = ahora`) y reemite la `task.state` del hilo. -> touched_at ISO."""
        with self._lock:
            now = self.clock()
            self._x("INSERT OR REPLACE INTO thread_touch(thread_id, touched_at) VALUES(?,?)", (thread_id, now))
            r = self._q("SELECT project, body FROM office_threads WHERE thread_id=?", (thread_id,))
            if r:
                body = dict(db.jload(r[0]["body"], {}) or {}, touched_at=_iso(now))
                self._x("UPDATE office_threads SET body=? WHERE thread_id=?", (db.jdump(body), thread_id))
                self._emit("task.state", r[0]["project"], body, needs=envelope.needs_for_attention(body.get("attention")),
                           severity="error" if body.get("phase") == "failed" else "info")
            return _iso(now)

    def assign(self, desk_id, thread_id):
        """Asignación manual. Lanza OfficeError(404/409/400) si no se puede."""
        with self._lock:
            d = self._q("SELECT * FROM desks WHERE id=?", (desk_id,))
            if not d:
                raise OfficeError(404, "escritorio desconocido")
            d = d[0]
            if d["retired"]:
                raise OfficeError(409, "el escritorio está retirado")
            snap = self._snap(thread_id)
            if snap is None:
                raise OfficeError(404, "hilo desconocido (aún sin task.state)")
            r = self._q("SELECT project FROM office_threads WHERE thread_id=?", (thread_id,))
            if r and r[0]["project"] != d["project"]:
                raise OfficeError(400, "el hilo es de otro proyecto (%s)" % r[0]["project"])
            occ = self._occupant(desk_id)
            if occ and occ["thread_id"] == thread_id:
                return desk_id
            if occ:
                s = self._snap(occ["thread_id"]) or {}
                if not halflife.fading(s.get("phase"), s.get("attention")):
                    raise OfficeError(409, "el escritorio está ocupado por un hilo activo (%s)" % occ["thread_id"])
            snap["role"] = d["role"]
            self._x("UPDATE office_threads SET body=? WHERE thread_id=?", (db.jdump(snap), thread_id))
            self._x("UPDATE t3_threads SET role=? WHERE thread_id=?", (d["role"], thread_id))
            self._x("INSERT OR REPLACE INTO thread_touch(thread_id, touched_at) VALUES(?,?)", (thread_id, self.clock()))
            self._place(thread_id, d["project"], d["role"], snap, desk=d, reason="manual")
            return desk_id

    def desk(self, desk_id):
        """`GET /desks/<id>`: {desk, occupant, lineage:[…20]} o None."""
        with self._lock:
            d = self._q("SELECT * FROM desks WHERE id=?", (desk_id,))
            if not d:
                return None
            d = d[0]
            occ = self._occupant(desk_id)
            occupant = None
            if occ:
                s = self._snap(occ["thread_id"]) or {}
                occupant = {"thread_id": occ["thread_id"], "title": s.get("title"), "role": d["role"],
                            "phase": s.get("phase"), "attention": s.get("attention"), "since": _iso(occ["since"]),
                            "ended_at": s.get("ended_at"), "touched_at": s.get("touched_at"),
                            "half_life_s": self._hl(d["project"]),
                            "inheritance": db.jload(occ["inheritance"], None)}
            lineage = [{"thread_id": r["thread_id"], "since": _iso(r["since"]), "until": _iso(r["until"]),
                        "reason": r["reason"]}
                       for r in self._q("SELECT * FROM desk_occupancy WHERE desk_id=? AND until IS NOT NULL"
                                        " ORDER BY until DESC, id DESC LIMIT ?", (desk_id, LINEAGE))]
            return {"desk": {"id": d["id"], "project": d["project"], "floor": d["floor"], "role": d["role"], "slot": d["slot"],
                             "permanent": bool(d["permanent"]), "retired": bool(d["retired"])},
                    "occupant": occupant, "lineage": lineage}


class OfficeError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def thread_role(prof, title=None, branch=None):
    """Rol por las reglas `match` del perfil (None sin perfil/oficina o si ninguna coincide)."""
    return layout.role_for(prof, title, branch) if prof else None
