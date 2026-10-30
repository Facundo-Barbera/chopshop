"""Escritorios fijos por rol con herencia (docs/plans/office-redesign.md §2): asigna escritorios a los hilos con rol y
gestiona la herencia y la espera por rol lleno. Emite `office.changed`, `desk.assigned`, `desk.released` y `desk.waiting`.
El vestíbulo (hilos sin rol) y la salida por semivida (`desk.released reason: faded`) son de otros módulos.

- `Office(conn, cfg, emit_fn, profiles_fn=None, clock=time.time)`; `emit_fn(type, project, body, **kw) -> sobre`
  (el servicio lo envuelve sobre `events.emit_envelope` y despierta al `/stream`).
- `reload()`: relee los perfiles con bloque `office:`; sincroniza la tabla `desks` (los que el perfil deja de declarar quedan
  `retired`, nunca se borran; su ocupante sale con `reason: retired`) y emite `office.changed {by: "profile"}` cuando cambia la
  estructura (o cuando el último ya no está retenido en `events`).
- `tick()`: pliega los `task.state` nuevos del bus (cursor `office_cursor` en `meta`) y asigna/encola. La primera vez (sin
  cursor) siembra en silencio con el historial retenido y solo sienta a los activos.
- `assign(desk_id, thread_id)`: asignación manual (bot o humano): `desk.assigned reason: manual`.
- `desk(desk_id)`: escritorio, ocupante, linaje completo (`GET /desks/<id>`).
- `release(desk_id, reason)`: saca al ocupante (lo usa quien decida la salida, p. ej. la semivida con `faded`).

Reglas de asignación (por rol y proyecto, piso más bajo primero): si algún ocupante del rol ya terminó (fase terminal y sin
atención), el nuevo hilo lo **hereda** (el que terminó antes; sale con `desk.released reason: inherited`, entra con
`desk.assigned reason: inherited`); si no, el primer escritorio libre (`reason: start`). La herencia es el último ocupante del
escritorio (el que sale o, si estaba libre, el último del linaje). Rol lleno (o sin escritorios) -> `desk.waiting`; sube en
cuanto un escritorio del rol queda libre o su ocupante termina. Los hilos sin rol no se sientan.
El rol de un hilo: `role` del cuerpo de `task.state` (lo pone Chopshop al lanzar, o t3watch por las reglas `match`), o el
último conocido; una asignación manual lo fija."""
import logging
import threading
import time

from .. import profile as profile_mod
from . import db, envelope, events, layout, notes

log = logging.getLogger("chopshop.agent.office")

CURSOR = "office_cursor"
STRUCT = "office_struct:"           # meta: "<seq> <estructura JSON>" del último office.changed por proyecto
LINEAGE = 20                         # ocupantes pasados guardados por escritorio
LINEAGE_STATE = 5                    # los que manda la proyección
ACTIVE = ("queued", "preparing", "running", "waiting")
TERMINAL = ("done", "failed", "settled", "skipped")
BATCH = 500
RELOAD = 60                          # s entre relecturas de perfiles
INHERIT_KEYS = ("thread_id", "title", "summary", "branch", "worktree", "pull_requests", "phase", "ended_at")
KEEP_KEYS = ("summary", "result", "role", "branch", "worktree", "title")   # no se pierden si un task.state posterior no los trae
CLOSE_AFTER = 180
CLOSE_BELOW = 0.5


def _load_profiles():
    out = []
    for name in profile_mod.list_projects():
        try:
            out.append(profile_mod.load(name))
        except profile_mod.ProfileError as e:
            log.warning("perfil %s: %s", name, e)
    return out


def _finished(body):
    """El ocupante terminó y no espera a nadie: su escritorio se puede heredar."""
    return (body or {}).get("phase") in TERMINAL and not (body or {}).get("attention")


def _iso(ts):
    return envelope.iso(ts) if ts is not None else None


class Office:
    def __init__(self, conn, cfg, emit_fn, profiles_fn=None, clock=time.time):
        self.conn, self.cfg, self.emit_fn, self.clock = conn, cfg, emit_fn, clock
        self.profiles_fn = profiles_fn or _load_profiles
        self.half_life = {}           # proyecto -> T½ (s)
        self.company = {}             # proyecto -> empresa
        self.profs = {}
        self.building = {}
        self.empty_since = {}
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

    def _waiting(self, tid):
        r = self._q("SELECT * FROM desk_waiting WHERE thread_id=?", (tid,))
        return r[0] if r else None

    def _hl(self, project):
        return self.half_life.get(project) or float(layout.DEFAULT_HALF_LIFE)

    def _role_desks(self, project, role):
        return self._q("SELECT * FROM desks WHERE project=? AND role=? AND retired=0 ORDER BY floor, slot", (project, role))

    def _declared(self, project):
        return len(layout.floors(self.profs.get(project) or {}))

    def _zone(self, d):
        return layout.zone(d["floor"], d["role"], self._declared(d["project"]))

    def _open_floors(self, project, role):
        n = self._declared(project)
        return [r["floor"] for r in self._q("SELECT DISTINCT floor FROM desks WHERE project=? AND role=? AND retired=0"
                                            " ORDER BY floor", (project, role))
                if layout.is_temporary(r["floor"], role, n)]

    # ------------------------------------------------------------ estructura

    def reload(self):
        """Sincroniza `desks` con los perfiles. Devuelve los proyectos cuyo `office.changed` se emitió."""
        with self._lock:
            changed = []
            known = {r["project"] for r in self._q("SELECT DISTINCT project FROM desks")}
            profs = self.profiles_fn()
            for prof in profs:
                self.building[prof.get("project")] = layout.building_floors(profs, prof)
            for prof in profs:
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

    def sync_project(self, project, by="profile"):
        """Resincroniza un proyecto tras reescribir su perfil (`PUT /office`): `office.changed {by}` si cambió. -> sobre o None."""
        with self._lock:
            profs = self.profiles_fn()
            prof = next((p for p in profs if p.get("project") == project), None)
            if prof:
                self.building[project] = layout.building_floors(profs, prof)
            return self._sync(prof, by=by) if prof else None

    def _sync(self, prof, by="profile"):
        """Sincroniza la tabla `desks` de un perfil. Devuelve el sobre `office.changed` emitido o None."""
        project, now = prof["project"], self.clock()
        self.half_life[project] = layout.half_life_s(prof)
        self.company[project] = layout.company(prof)
        self.profs[project] = prof
        n = len(layout.floors(prof))
        declared = {d["id"]: d for d in layout.desks(prof)}
        have = {r["id"]: r for r in self._q("SELECT * FROM desks WHERE project=?", (project,))
                if r["id"] in declared or not layout.is_temporary(r["floor"], r["role"], n)}
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
        emitted = self._publish(project, by, {"added": added, "retired": retired, "reactivated": reactivated})
        for did in retired:
            occ = self._occupant(did)
            if occ:
                self._release(did, occ, "retired")
                snap = self._snap(occ["thread_id"]) or {}
                if snap.get("phase") in ACTIVE:
                    self._decide(occ["thread_id"], project, snap)
        for role in sorted({declared[d]["role"] for d in added + reactivated}):
            self._promote_any(project, role)
        return emitted

    def _publish(self, project, by, diff, force=False):
        prof = self.profs[project]
        gone = [r["id"] for r in self._q("SELECT id FROM desks WHERE project=? AND retired=1", (project,))]
        struct = layout.structure(prof, gone, len(self._open_floors(project, layout.FLEX_ROLE)),
                                  len(self._open_floors(project, layout.OUT_ROLE)), self.building.get(project))
        last = self._meta(STRUCT + project)
        last_seq, last_struct = (last.split(" ", 1) + [""])[:2] if last else ("0", "")
        stale = int(last_seq or 0) < self._min_seq()
        if db.jdump(struct) == last_struct and not stale and not force:
            return None
        env = self._emit("office.changed", project, dict(struct, project=project, by=by, diff=diff))
        self._set_meta(STRUCT + project, "%s %s" % (env.get("seq") if env else 0, db.jdump(struct)))
        return env or {"seq": None}

    def _promote_any(self, project, role):
        if layout.is_elastic(role):
            self._promote_elastic(project)
        else:
            self._promote(project, role)

    def _min_seq(self):
        r = self._q("SELECT COALESCE(MIN(seq),0) AS s FROM events")
        return r[0]["s"] if r else 0

    # ------------------------------------------------------------ bus

    def tick(self):
        """Pliega los sobres nuevos. Devuelve el número de `task.state` procesados."""
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
            for project in sorted(self.profs):
                self._shrink(project)
            return n

    def _shrink(self, project):
        now = self.clock()
        out, ext = self._open_floors(project, layout.OUT_ROLE), self._open_floors(project, layout.FLEX_ROLE)
        if not out and not ext:
            return None
        role, floor = (layout.OUT_ROLE, out[-1]) if out else (layout.FLEX_ROLE, ext[-1])
        key = (project, role, floor)
        rows = self._q("SELECT d.id, d.floor, d.role, o.thread_id FROM desks d LEFT JOIN desk_occupancy o"
                       " ON o.desk_id=d.id AND o.until IS NULL WHERE d.project=? AND d.role IN (?,?) AND d.retired=0",
                       (project, layout.FLEX_ROLE, layout.OUT_ROLE))
        mine = [r for r in rows if r["role"] == role and r["floor"] == floor]
        if any(r["thread_id"] for r in mine):
            self.empty_since.pop(key, None)
            return None
        since = self.empty_since.setdefault(key, now)
        rest = [r for r in rows if not (r["role"] == role and r["floor"] == floor)]
        if now - since < CLOSE_AFTER or (rest and sum(1 for r in rest if r["thread_id"]) >= CLOSE_BELOW * len(rest)):
            return None
        ids = [r["id"] for r in mine]
        marks = ",".join("?" * len(ids))
        self._x("DELETE FROM desk_occupancy WHERE desk_id IN (%s)" % marks, ids)
        self._x("DELETE FROM desks WHERE id IN (%s)" % marks, ids)
        self.empty_since.pop(key, None)
        return self._publish(project, "capacity", {"added": [], "retired": [], "reactivated": [], "closed": ids})

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
        if body.get("phase") in TERMINAL:
            if body.get("ended_at") is None:
                body["ended_at"] = old.get("ended_at") if old.get("phase") in TERMINAL and old.get("ended_at") \
                    else env.get("ts")
        else:
            body["ended_at"] = None
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
            elastic = layout.is_elastic(seat["role"])
            if active and role and elastic:
                w = self._waiting(tid)
                if not w or w["role"] != role:
                    self._x("INSERT OR REPLACE INTO desk_waiting(thread_id, project, role, since) VALUES(?,?,?,?)",
                            (tid, project, role, w["since"] if w else self.clock()))
                    self._place(tid, project, role, body)
            elif active and role and role != seat["role"]:  # cambió de rol: se traslada si hay sitio
                self._place(tid, project, role, body)
            elif _finished(body):
                if elastic:
                    self._x("DELETE FROM desk_waiting WHERE thread_id=?", (tid,))
                self._promote_any(project, seat["role"])  # terminó: lo hereda quien espere ese rol
            return
        if active and role:
            w = self._waiting(tid)
            if not self._place(tid, project, role, body, elastic=True) and not (w and w["role"] == role):
                self._x("INSERT OR REPLACE INTO desk_waiting(thread_id, project, role, since) VALUES(?,?,?,?)",
                        (tid, project, role, w["since"] if w else self.clock()))
                self._emit("desk.waiting", project, {"thread_id": tid, "role": role, "title": body.get("title"),
                                                     "phase": body.get("phase")})

    # ------------------------------------------------------------ asignación

    def _candidates(self, project, role):
        """(escritorio, ocupante|None) del rol: primero el ocupante que terminó antes, luego el primer libre."""
        finished, free = [], []
        for d in self._role_desks(project, role):
            occ = self._occupant(d["id"])
            if occ is None:
                free.append((d, None))
                continue
            s = self._snap(occ["thread_id"]) or {}
            if _finished(s):
                finished.append((envelope.epoch(s.get("ended_at")) or 0.0, d["floor"], d["slot"], d, occ))
        finished.sort(key=lambda x: x[:3])
        return [(x[3], x[4]) for x in finished] + free

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

    def _elastic_order(self, project, role):
        n = self._declared(project)
        home = min([d["floor"] for d in self._role_desks(project, role)] or [0])
        rows = self._q("SELECT * FROM desks WHERE project=? AND role IN (?,?) AND retired=0",
                       (project, layout.FLEX_ROLE, layout.OUT_ROLE))
        tier = {"flex": 0, "extra": 1, "outsourced": 2}
        return sorted(rows, key=lambda d: (tier[layout.zone(d["floor"], d["role"], n)],
                                           abs(d["floor"] - home) if d["floor"] < n and d["role"] == layout.FLEX_ROLE else 0,
                                           d["floor"], d["slot"]))

    def _elastic_slot(self, project, role):
        reclaim = []
        for d in self._elastic_order(project, role):
            occ = self._occupant(d["id"])
            if occ is None:
                return d, None
            if _finished(self._snap(occ["thread_id"]) or {}):
                reclaim.append((d, occ))
        if reclaim:
            return reclaim[0]
        prof = self.profs.get(project)
        if prof is None:
            return None, None
        cap = layout.capacity(prof, self.building.get(project))
        ext, out = self._open_floors(project, layout.FLEX_ROLE), self._open_floors(project, layout.OUT_ROLE)
        if len(ext) < cap["max_extra_floors"]:
            return self._open(project, layout.FLEX_ROLE, max(ext + [self._declared(project) - 1]) + 1), None
        if cap["outsourcing"] and len(out) < layout.MAX_OUTSOURCED_FLOORS:
            return self._open(project, layout.OUT_ROLE, max(out + [-1]) + 1), None
        return None, None

    def _open(self, project, role, floor):
        now, ids = self.clock(), []
        for slot in range(layout.elastic_floor_desks(self.profs[project])):
            did = layout.desk_id(project, floor, role, slot)
            self._x("INSERT OR REPLACE INTO desks(id, project, floor, role, slot, permanent, retired, created)"
                    " VALUES(?,?,?,?,?,0,0,?)", (did, project, floor, role, slot, now))
            ids.append(did)
        self._publish(project, "capacity", {"added": ids, "retired": [], "reactivated": []})
        return self._q("SELECT * FROM desks WHERE id=?", (ids[0],))[0]

    def _place(self, tid, project, role, body, desk=None, reason=None, elastic=False):
        """Sienta al hilo en un escritorio del rol (o en `desk`). Devuelve el id del escritorio o None si está lleno."""
        cands = [(desk, self._occupant(desk["id"]))] if desk else self._candidates(project, role)
        if not cands and elastic:
            d, occ = self._elastic_slot(project, role)
            cands = [(d, occ)] if d else []
        if not cands:
            return None
        d, occ = cands[0]
        if occ and occ["thread_id"] == tid:
            return d["id"]
        zone = self._zone(d)
        flex = zone != "room"
        inh = None if flex else self._inheritance(d["id"], occ)
        if occ:
            self._release(d["id"], occ, "reclaimed" if flex else "inherited", promote=False)
        now = self.clock()
        old = self._seat(tid)
        if old:                                           # traslado: el escritorio anterior queda libre, sin linaje
            self._x("DELETE FROM desk_occupancy WHERE id=?", (old["id"],))
        back = bool(old) and layout.is_elastic(old["role"]) and not flex
        why = reason or ("overflow" if flex else "return" if back else "inherited" if occ else "start")
        self._x("INSERT INTO desk_occupancy(desk_id, thread_id, since, until, reason, inheritance) VALUES(?,?,?,NULL,?,?)",
                (d["id"], tid, now, why, db.jdump(inh) if inh else None))
        if flex:
            w = self._waiting(tid)
            self._x("INSERT OR REPLACE INTO desk_waiting(thread_id, project, role, since) VALUES(?,?,?,?)",
                    (tid, project, role, w["since"] if w else now))
        else:
            self._x("DELETE FROM desk_waiting WHERE thread_id=?", (tid,))
        self._emit("desk.assigned", project, {
            "desk": d["id"], "thread_id": tid, "role": role if flex else d["role"], "reason": why,
            "title": body.get("title"), "since": _iso(now), "inheritance": inh,
            "notes_pending": notes.count(self.conn, d["id"], now), "zone": zone})
        if old:
            self._promote_any(old["project"], old["role"])
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
            self._promote_any(project, d[0]["role"])

    def _promote(self, project, role):
        """Sube a los que esperan ese rol (los más antiguos primero) mientras haya escritorio."""
        for w in self._q("SELECT * FROM desk_waiting WHERE project=? AND role=? ORDER BY since, rowid", (project, role)):
            s = self._snap(w["thread_id"]) or {}
            if s.get("phase") not in ACTIVE:
                continue
            if not self._place(w["thread_id"], project, role, s, elastic=not self._seat(w["thread_id"])):
                break

    def _promote_elastic(self, project):
        for w in self._q("SELECT * FROM desk_waiting WHERE project=? ORDER BY since, rowid", (project,)):
            s = self._snap(w["thread_id"]) or {}
            if s.get("phase") not in ACTIVE or self._seat(w["thread_id"]):
                continue
            if not self._place(w["thread_id"], project, w["role"], s, elastic=True):
                break

    # ------------------------------------------------------------ acciones (API)

    def release(self, desk_id, reason):
        """Saca al ocupante actual (`desk.released {reason}`) y sube a quien espere el rol. -> thread_id o None."""
        with self._lock:
            occ = self._occupant(desk_id)
            if occ is None:
                return None
            self._release(desk_id, occ, reason)
            return occ["thread_id"]

    def assign(self, desk_id, thread_id, reason="manual"):
        """Asignación manual (`reason: manual`) o de un rol permanente despertado (`wake`). Lanza OfficeError(404/409/400)."""
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
                if not _finished(s):
                    raise OfficeError(409, "el escritorio está ocupado por un hilo activo (%s)" % occ["thread_id"])
            if layout.is_elastic(d["role"]):
                if not snap.get("role"):
                    raise OfficeError(400, "un escritorio elástico necesita un hilo con rol")
            else:
                snap["role"] = d["role"]
                self._x("UPDATE office_threads SET body=? WHERE thread_id=?", (db.jdump(snap), thread_id))
                self._x("UPDATE t3_threads SET role=? WHERE thread_id=?", (d["role"], thread_id))
            self._place(thread_id, d["project"], snap["role"], snap, desk=d, reason=reason)
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
                occupant = {"thread_id": occ["thread_id"], "title": s.get("title"),
                            "role": s.get("role") if layout.is_elastic(d["role"]) else d["role"], "zone": self._zone(d),
                            "phase": s.get("phase"), "attention": s.get("attention"), "since": _iso(occ["since"]),
                            "ended_at": s.get("ended_at"), "touched_at": s.get("touched_at"),
                            "half_life_s": self._hl(d["project"]),
                            "inheritance": db.jload(occ["inheritance"], None)}
            lineage = [{"thread_id": r["thread_id"], "since": _iso(r["since"]), "until": _iso(r["until"]),
                        "reason": r["reason"]}
                       for r in self._q("SELECT * FROM desk_occupancy WHERE desk_id=? AND until IS NOT NULL"
                                        " ORDER BY until DESC, id DESC LIMIT ?", (desk_id, LINEAGE))]
            return {"desk": {"id": d["id"], "project": d["project"], "floor": d["floor"], "role": d["role"], "slot": d["slot"],
                             "permanent": bool(d["permanent"]), "retired": bool(d["retired"]), "zone": self._zone(d)},
                    "occupant": occupant, "lineage": lineage}


class OfficeError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def thread_role(prof, title=None, branch=None):
    """Rol por las reglas `match` del perfil (None sin perfil/oficina o si ninguna coincide)."""
    return layout.role_for(prof, title, branch) if prof else None
