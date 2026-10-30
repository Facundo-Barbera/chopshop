import json
import os
import sqlite3
import threading

SCHEMA_VERSION = 7

SCHEMA = """
CREATE TABLE IF NOT EXISTS machine_samples (      -- crudo (retención raw_hours)
  ts REAL PRIMARY KEY, load1 REAL, load5 REAL, load15 REAL, cpus INTEGER, cpu_pct REAL,
  ram_total_mb INTEGER, ram_avail_mb INTEGER, swap_used_mb INTEGER, disk_used_gb REAL, disk_total_gb REAL, extra TEXT);
CREATE TABLE IF NOT EXISTS samples (              -- crudo por grupo
  ts REAL NOT NULL, kind TEXT NOT NULL,           -- kind: 'app' | 'project'
  name TEXT NOT NULL, cpu_pct REAL, rss_mb REAL, procs INTEGER, extra TEXT);
CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts, kind);
CREATE TABLE IF NOT EXISTS samples_agg (          -- agregado: res='1m' | '1h'
  res TEXT NOT NULL, ts REAL NOT NULL, kind TEXT NOT NULL,   -- kind: 'machine' | 'app' | 'project'
  name TEXT NOT NULL, cpu_avg REAL, cpu_max REAL, rss_avg REAL, rss_max REAL, procs_max INTEGER, n INTEGER,
  PRIMARY KEY (res, ts, kind, name));
CREATE TABLE IF NOT EXISTS events (               -- monotónico por máquina
  seq INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, machine_id TEXT NOT NULL,
  event TEXT NOT NULL, project TEXT, body TEXT NOT NULL DEFAULT '{}');
CREATE TABLE IF NOT EXISTS deliveries (           -- resultado por suscripción; nunca la URL
  event_seq INTEGER NOT NULL, name TEXT NOT NULL, ok INTEGER NOT NULL, detail TEXT, ts REAL NOT NULL,
  PRIMARY KEY (event_seq, name));
CREATE TABLE IF NOT EXISTS subscriptions (
  name TEXT PRIMARY KEY, webhook_file TEXT NOT NULL, project TEXT NOT NULL DEFAULT '*',
  events TEXT NOT NULL DEFAULT '[]', created REAL NOT NULL);
CREATE TABLE IF NOT EXISTS t3_threads (
  thread_id TEXT PRIMARY KEY, project TEXT, t3_project_id TEXT, title TEXT, status TEXT, settled INTEGER DEFAULT 0,
  worktree TEXT, branch TEXT, pending TEXT NOT NULL DEFAULT '[]', first_seen REAL, last_seen REAL, updated REAL, extra TEXT);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""

_lock = threading.RLock()


def connect(path):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    conn = sqlite3.connect(path, timeout=15, check_same_thread=False, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=10000")
    migrate(conn)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return conn


def migrate(conn):
    v = conn.execute("PRAGMA user_version").fetchone()[0]
    if v < 1:
        conn.executescript(SCHEMA)
    if v < 2:
        conn.executescript("DROP TABLE IF EXISTS leases; DROP TABLE IF EXISTS ports;")
    if v < 3:
        _migrate_v3(conn)
    if v < 4:
        _migrate_v4(conn)
    if v < 5:
        _migrate_v5_office(conn)
    if v < 6:
        _migrate_v6(conn)
    if v < 7:
        _migrate_v7(conn)
    if v < SCHEMA_VERSION:
        conn.execute("PRAGMA user_version=%d" % SCHEMA_VERSION)


EVENT_COLUMNS = (("id", "TEXT"), ("type", "TEXT"), ("severity", "TEXT"), ("needs", "TEXT"), ("subject_kind", "TEXT"),
                 ("subject_id", "TEXT"), ("subject", "TEXT"), ("cause_id", "TEXT"), ("cause_depth", "INTEGER"))


def _migrate_v3(conn):
    from . import envelope
    with _lock:
        have = {r[1] for r in conn.execute("PRAGMA table_info(events)")}
        for name, kind in EVENT_COLUMNS:
            if name not in have:
                conn.execute("ALTER TABLE events ADD COLUMN %s %s" % (name, kind))
        conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS events_id ON events(id)")
        conn.execute("CREATE INDEX IF NOT EXISTS events_subject ON events(subject_kind, subject_id)")
        conn.execute("BEGIN IMMEDIATE")
        try:
            todo = conn.execute("SELECT seq, ts, machine_id, event, body FROM events WHERE id IS NULL ORDER BY seq").fetchall()
            for r in todo:
                seq, ts, machine, event, raw = tuple(r)
                body = jload(raw, {})
                f = envelope.from_legacy(event, body if isinstance(body, dict) else {}, machine)
                s = f["subject"]
                conn.execute("UPDATE events SET id=?, type=?, severity=?, needs=?, subject_kind=?, subject_id=?, subject=?,"
                             " cause_id=NULL, cause_depth=0, body=? WHERE seq=?",
                             (envelope.new_id(ts), f["type"], f["severity"], f["needs"], s["kind"], s["id"], jdump(s),
                              jdump(f["body"]), seq))
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise


V4_COLUMNS = {
    "subscriptions": (("projects", "TEXT"), ("types", "TEXT"), ("exclude_types", "TEXT"), ("min_severity", "TEXT"),
                      ("needs", "TEXT"), ("only_changes", "INTEGER"), ("context", "INTEGER"), ("debounce_s", "REAL"),
                      ("secret_file", "TEXT")),
    "deliveries": (("attempts", "INTEGER"), ("next_retry", "REAL")),
}


def _add_columns(conn, spec):
    for table, cols in spec.items():
        have = {r[1] for r in conn.execute("PRAGMA table_info(%s)" % table)}
        for name, typ in cols:
            if name not in have:
                conn.execute("ALTER TABLE %s ADD COLUMN %s %s" % (table, name, typ))


def _migrate_v4(conn):
    _add_columns(conn, V4_COLUMNS)


OFFICE_SCHEMA = """
CREATE TABLE IF NOT EXISTS desks (
  id TEXT PRIMARY KEY, project TEXT NOT NULL, floor INTEGER NOT NULL, role TEXT NOT NULL, slot INTEGER NOT NULL,
  permanent INTEGER NOT NULL DEFAULT 0, retired INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL);
CREATE INDEX IF NOT EXISTS desks_role ON desks(project, role, floor, slot);
CREATE TABLE IF NOT EXISTS desk_occupancy (
  id INTEGER PRIMARY KEY AUTOINCREMENT, desk_id TEXT NOT NULL, thread_id TEXT NOT NULL, since REAL NOT NULL, until REAL,
  reason TEXT, inheritance TEXT);
CREATE INDEX IF NOT EXISTS desk_occupancy_desk ON desk_occupancy(desk_id, until);
CREATE INDEX IF NOT EXISTS desk_occupancy_thread ON desk_occupancy(thread_id, until);
CREATE TABLE IF NOT EXISTS office_threads (thread_id TEXT PRIMARY KEY, project TEXT, body TEXT NOT NULL, updated REAL);
CREATE TABLE IF NOT EXISTS desk_waiting (thread_id TEXT PRIMARY KEY, project TEXT, role TEXT NOT NULL, since REAL NOT NULL);
"""
V5_COLUMNS = {"t3_threads": (("role", "TEXT"), ("ended_at", "REAL"))}


def _migrate_v5_office(conn):
    conn.executescript(OFFICE_SCHEMA)
    _add_columns(conn, V5_COLUMNS)


V6_COLUMNS = {"subscriptions": (("headers_file", "TEXT"),)}


def _migrate_v6(conn):
    _add_columns(conn, V6_COLUMNS)


V7_COLUMNS = {"subscriptions": (("heartbeats", "INTEGER"),)}


def _migrate_v7(conn):
    _add_columns(conn, V7_COLUMNS)


def tx():
    return _lock


def rows(cur):
    return [dict(r) for r in cur.fetchall()]


def jdump(o):
    return json.dumps(o, ensure_ascii=False, separators=(",", ":"))


def jload(s, default=None):
    try:
        return json.loads(s) if s else default
    except ValueError:
        return default
