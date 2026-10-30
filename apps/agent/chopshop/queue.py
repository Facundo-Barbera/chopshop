import threading
import time

from .agent import db, envelope

MAX_LEN = 20
PREFIX = "q:"
STATES = ("queued", "dequeued", "cancelled", "done", "failed")
CANCEL_REASONS = ("manual", "superseded", "retired", "expired")

SCHEMA = """
CREATE TABLE IF NOT EXISTS employee_queue (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, task TEXT NOT NULL UNIQUE, employee TEXT NOT NULL, project TEXT,
  title TEXT NOT NULL, by_ TEXT NOT NULL, trigger TEXT, priority INTEGER NOT NULL DEFAULT 0, idem TEXT,
  state TEXT NOT NULL, enqueued REAL NOT NULL, ended REAL, cancel_by TEXT, cancel_reason TEXT, note TEXT,
  extra TEXT NOT NULL DEFAULT '{}');
CREATE INDEX IF NOT EXISTS employee_queue_live ON employee_queue(employee, state, priority, seq);
CREATE UNIQUE INDEX IF NOT EXISTS employee_queue_idem ON employee_queue(employee, idem) WHERE idem IS NOT NULL;
"""


class QueueError(Exception):
    pass


class QueueFull(QueueError):
    pass


def ensure_schema(conn):
    with db.tx():
        for sql in SCHEMA.split(";"):
            if sql.strip():
                conn.execute(sql)


def project_of(employee):
    return str(employee).split("/", 1)[0] or None


def item(row):
    return {"task": row["task"], "title": row["title"], "enqueued_at": envelope.iso(row["enqueued"]),
            "by": row["by_"], "trigger": row["trigger"]}


class Queue:
    def __init__(self, conn, emit_fn=None, clock=time.time, max_len=MAX_LEN, machine=None):
        self.conn, self.emit_fn, self.clock, self.max_len, self.machine = conn, emit_fn, clock, max_len, machine
        self._lock = threading.RLock()
        ensure_schema(conn)

    def _rows(self, employee):
        return db.rows(self.conn.execute(
            "SELECT * FROM employee_queue WHERE employee=? AND state='queued' ORDER BY priority DESC, seq",
            (employee,)))

    def get(self, task):
        with db.tx():
            r = self.conn.execute("SELECT * FROM employee_queue WHERE task=?", (task,)).fetchone()
        return dict(r) if r else None

    def show(self, employee):
        with db.tx():
            return [item(r) for r in self._rows(employee)]

    def updated(self, employee):
        with db.tx():
            r = self.conn.execute("SELECT value FROM meta WHERE key=?", ("queue_updated:" + employee,)).fetchone()
        return envelope.iso(float(r[0])) if r else None

    def snapshot(self, employees):
        return {e: {"items": self.show(e), "updated": self.updated(e)} for e in employees}

    def __len__(self):
        with db.tx():
            return self.conn.execute("SELECT COUNT(*) FROM employee_queue WHERE state='queued'").fetchone()[0]

    def length(self, employee):
        with db.tx():
            return self.conn.execute("SELECT COUNT(*) FROM employee_queue WHERE employee=? AND state='queued'",
                                     (employee,)).fetchone()[0]

    def enqueue(self, employee, title, by, trigger=None, priority=0, key=None, cause=None, extra=None):
        if not employee or not title or not by:
            raise QueueError("employee, title y by son obligatorios")
        with self._lock:
            return self._enqueue(employee, title, by, trigger, priority, key, cause, extra)

    def _enqueue(self, employee, title, by, trigger, priority, key, cause, extra):
        now = self.clock()
        with db.tx():
            if key is not None:
                r = self.conn.execute("SELECT * FROM employee_queue WHERE employee=? AND idem=?",
                                      (employee, str(key))).fetchone()
                if r:
                    return dict(r), False
            n = self.conn.execute("SELECT COUNT(*) FROM employee_queue WHERE employee=? AND state='queued'",
                                  (employee,)).fetchone()[0]
            if self.max_len and n >= self.max_len:
                raise QueueFull("la cola de %s está llena (%d)" % (employee, self.max_len))
            eid = envelope.new_id(now)
            task = PREFIX + eid
            self.conn.execute(
                "INSERT INTO employee_queue(task, employee, project, title, by_, trigger, priority, idem, state, enqueued,"
                " extra) VALUES (?,?,?,?,?,?,?,?,'queued',?,?)",
                (task, employee, project_of(employee), str(title), str(by), trigger, int(priority),
                 None if key is None else str(key), now, db.jdump(extra or {})))
            self._touch(employee, now)
            rows = self._rows(employee)
            row = next(r for r in rows if r["task"] == task)
        pos = rows.index(row)
        ev = self._emit("task.enqueued", employee, {
            "task": task, "employee": employee, "title": row["title"], "position": pos, "by": row["by_"],
            "trigger": trigger, "enqueued_at": envelope.iso(now)}, now, cause=cause, id=eid,
            subj=envelope.subject("task", task, row["title"]))
        self._changed(employee, rows, "enqueued", task, now, cause=ev or cause)
        return row, True

    def cancel(self, task, by, reason="manual", note=None, cause=None):
        if reason not in CANCEL_REASONS:
            raise QueueError("reason inválido: %r (%s)" % (reason, ", ".join(CANCEL_REASONS)))
        with self._lock:
            return self._cancel(task, by, reason, note, cause)

    def _cancel(self, task, by, reason, note, cause):
        now = self.clock()
        with db.tx():
            r = self.conn.execute("SELECT * FROM employee_queue WHERE task=?", (task,)).fetchone()
            if not r or r["state"] != "queued":
                return None
            self.conn.execute(
                "UPDATE employee_queue SET state='cancelled', ended=?, cancel_by=?, cancel_reason=?, note=? WHERE task=?",
                (now, str(by), reason, note, task))
            employee = r["employee"]
            self._touch(employee, now)
            rows = self._rows(employee)
        body = {"task": task, "employee": employee, "phase": "queued", "by": str(by), "reason": reason,
                "thread_id": None}
        if note:
            body["note"] = note
        ev = self._emit("task.cancelled", employee, body, now, cause=cause,
                        subj=envelope.subject("task", task, r["title"]))
        self._changed(employee, rows, "cancelled", task, now, cause=ev or cause)
        return dict(r, state="cancelled", ended=now, cancel_by=str(by), cancel_reason=reason, note=note)

    def announce(self, since):
        if not self.emit_fn:
            return []
        out = []
        with self._lock:
            with db.tx():
                rows = [r for r in db.rows(self.conn.execute(
                    "SELECT * FROM employee_queue WHERE state='queued' OR (state='cancelled' AND ended>=?) ORDER BY seq",
                    (since,))) if not self._announced(r)]
            for r in rows:
                employee, task, now = r["employee"], r["task"], self.clock()
                with db.tx():
                    live = self._rows(employee)
                subj = envelope.subject("task", task, r["title"])
                if r["state"] == "queued":
                    pos = next((i for i, x in enumerate(live) if x["task"] == task), None)
                    if pos is None:
                        continue
                    ev = self._emit("task.enqueued", employee, {
                        "task": task, "employee": employee, "title": r["title"], "position": pos, "by": r["by_"],
                        "trigger": r["trigger"], "enqueued_at": envelope.iso(r["enqueued"])}, now,
                        id=task[len(PREFIX):], subj=subj)
                    self._changed(employee, live, "enqueued", task, now, cause=ev)
                    out.append(("task.enqueued", task))
                    continue
                body = {"task": task, "employee": employee, "phase": "queued", "by": r["cancel_by"] or "human",
                        "reason": r["cancel_reason"] if r["cancel_reason"] in CANCEL_REASONS else "manual",
                        "thread_id": None}
                if r["note"]:
                    body["note"] = r["note"]
                ev = self._emit("task.cancelled", employee, body, now, subj=subj)
                self._changed(employee, live, "cancelled", task, now, cause=ev)
                out.append(("task.cancelled", task))
        return out

    def _announced(self, r):
        if r["state"] == "queued":
            q, args = "SELECT 1 FROM events WHERE id=?", (r["task"][len(PREFIX):],)
        else:
            q, args = ("SELECT 1 FROM events WHERE subject_kind='task' AND subject_id=? AND type='task.cancelled'",
                       (r["task"],))
        return self.conn.execute(q, args).fetchone() is not None

    def pop(self, employee, cause=None):
        now = self.clock()
        with db.tx():
            rows = self._rows(employee)
            if not rows:
                return None
            head = rows[0]
            self.conn.execute("UPDATE employee_queue SET state='dequeued', ended=? WHERE task=?", (now, head["task"]))
            self._touch(employee, now)
            rows = rows[1:]
        self._changed(employee, rows, "dequeued", head["task"], now, cause=cause)
        head.update(state="dequeued", ended=now)
        return head

    def finish(self, task, state, note=None):
        if state not in ("done", "failed"):
            raise QueueError("estado final inválido: %r" % state)
        now = self.clock()
        with db.tx():
            r = self.conn.execute("SELECT * FROM employee_queue WHERE task=?", (task,)).fetchone()
            if not r or r["state"] != "dequeued":
                return None
            self.conn.execute("UPDATE employee_queue SET state=?, ended=?, note=? WHERE task=?", (state, now, note, task))
        return dict(r, state=state, ended=now, note=note)

    def clear(self, employee, by, reason="retired", cause=None):
        out = []
        for r in self.show(employee):
            c = self.cancel(r["task"], by, reason=reason, cause=cause)
            if c:
                out.append(c)
        return out

    def _touch(self, employee, now):
        self.conn.execute("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                          ("queue_updated:" + employee, repr(float(now))))

    def _changed(self, employee, rows, reason, task, now, cause=None):
        return self._emit("queue.changed", employee, {
            "employee": employee, "items": [item(r) for r in rows], "reason": reason, "task": task}, now, cause=cause,
            subj=envelope.subject("desk", employee))

    def _emit(self, type, employee, body, now, cause=None, subj=None, id=None):
        if not self.emit_fn:
            return None
        ev = envelope.build(type, project=project_of(employee), body=body, needs=None, subj=subj, cause=cause,
                            machine=self.machine, ts=now, id=id)
        return self.emit_fn(ev) or ev
