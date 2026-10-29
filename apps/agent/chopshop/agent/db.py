"""SQLite (WAL) del agente. Un solo archivo; `user_version` lleva el esquema y migra hacia adelante.
Todos los módulos reciben una conexión de `connect()`; filas = sqlite3.Row. Timestamps = epoch float (UTC)."""
import json
import os
import sqlite3
import threading

SCHEMA_VERSION = 2

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
    conn = sqlite3.connect(path, timeout=15, check_same_thread=False, isolation_level=None)  # autocommit
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
        # v2: Chopshop deja de gestionar servers de prueba y puertos (eso es de T3); se borran las tablas de la v1
        conn.executescript("DROP TABLE IF EXISTS leases; DROP TABLE IF EXISTS ports;")
    if v < SCHEMA_VERSION:
        conn.execute("PRAGMA user_version=%d" % SCHEMA_VERSION)


def tx():
    """Candado de proceso para secuencias lectura-modificación-escritura entre hilos del agente."""
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
