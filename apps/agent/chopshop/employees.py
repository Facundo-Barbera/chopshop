import time

from . import home, miniyaml, names
from .agent import db, layout

PROFILE = "profile"

SCHEMA = ("CREATE TABLE IF NOT EXISTS employees (id TEXT PRIMARY KEY, project TEXT NOT NULL, floor INTEGER NOT NULL,"
          " role TEXT NOT NULL, slot INTEGER NOT NULL, name TEXT, name_by TEXT, retired INTEGER NOT NULL DEFAULT 0,"
          " created REAL NOT NULL, updated REAL NOT NULL)",
          "CREATE INDEX IF NOT EXISTS employees_project ON employees(project, retired)")


class EmployeeError(ValueError):
    pass


def ensure_schema(conn):
    with db.tx():
        for sql in SCHEMA:
            conn.execute(sql)


def declared(prof):
    return [d for d in layout.desks(prof) if d["permanent"]]


def _key(d):
    return d["role"] if d["slot"] == 0 else "%s/%d" % (d["role"], d["slot"])


def profile_names(prof, pool=None):
    ds = declared(prof)
    by_key = names.resolve(prof.get("project"), [_key(d) for d in ds], pool)
    return {d["id"]: by_key[_key(d)] for d in ds}


def local_pool(project, home_dir=None):
    return names.project_pool(home_dir or home.home(), project, miniyaml.load)


def get(conn, emp_id):
    with db.tx():
        r = conn.execute("SELECT * FROM employees WHERE id=?", (emp_id,)).fetchone()
    return dict(r) if r else None


def sync(conn, prof, pool=None, now=None):
    now = time.time() if now is None else now
    project = prof.get("project")
    ds = declared(prof)
    wanted = profile_names(prof, pool)
    renamed = []
    with db.tx():
        old = {r["id"]: r for r in db.rows(conn.execute("SELECT * FROM employees WHERE project=?", (project,)))}
        for d in ds:
            r = old.get(d["id"])
            name = wanted[d["id"]]
            if r is None:
                conn.execute("INSERT INTO employees (id, project, floor, role, slot, name, name_by, retired, created, updated)"
                             " VALUES (?,?,?,?,?,?,?,0,?,?)",
                             (d["id"], project, d["floor"], d["role"], d["slot"], name, PROFILE, now, now))
                continue
            keep = r["name_by"] not in (None, PROFILE)
            if r["retired"] or (not keep and r["name"] != name):
                conn.execute("UPDATE employees SET retired=0, name=?, name_by=?, updated=? WHERE id=?",
                             (r["name"] if keep else name, r["name_by"] if keep else PROFILE, now, d["id"]))
            if not keep and r["name"] != name:
                renamed.append(_renamed(d["id"], d["role"], name, r["name"], PROFILE))
        gone = [i for i, r in old.items() if not r["retired"] and i not in wanted]
        for i in gone:
            conn.execute("UPDATE employees SET retired=1, updated=? WHERE id=?", (now, i))
    return renamed


def rename(conn, emp_id, name, by, now=None):
    now = time.time() if now is None else now
    if name is not None and (not isinstance(name, str) or not names.NAME_RE.fullmatch(name) or name != name.strip()):
        raise EmployeeError("nombre inválido: %r (letras, espacios, ' o -, máx. 32)" % (name,))
    if not isinstance(by, str) or not by.strip() or by == PROFILE:
        raise EmployeeError("by debe ser human o el nombre del bot")
    with db.tx():
        r = get(conn, emp_id)
        if r is None or r["retired"]:
            raise EmployeeError("no existe el empleado %s" % emp_id)
        conn.execute("UPDATE employees SET name=?, name_by=?, updated=? WHERE id=?", (name, by, now, emp_id))
    return _renamed(emp_id, r["role"], name, r["name"], by)


def reset_name(conn, prof, emp_id, pool=None, now=None):
    with db.tx():
        conn.execute("UPDATE employees SET name_by=NULL WHERE id=?", (emp_id,))
        return [b for b in sync(conn, prof, pool, now) if b["employee"] == emp_id]


def _renamed(emp_id, role, name, previous, by):
    return {"employee": emp_id, "role": role, "name": name, "previous": previous, "by": by}


def listing(conn, prof):
    order = {d["id"]: i for i, d in enumerate(declared(prof))}
    with db.tx():
        rs = db.rows(conn.execute("SELECT * FROM employees WHERE project=? AND retired=0", (prof.get("project"),)))
    return sorted((r for r in rs if r["id"] in order), key=lambda r: order[r["id"]])


def entry(r):
    return {"id": r["id"], "project": r["project"], "floor": r["floor"], "role": r["role"], "slot": r["slot"],
            "name": r["name"], "state": "idle", "location": "common", "thread_id": None, "task": None, "title": None, "since": None,
            "queue_len": 0}
