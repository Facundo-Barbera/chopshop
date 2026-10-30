CREATE TABLE machines (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES users (id),
  name TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('macos', 'linux', 'other')),
  local_machine_id TEXT,
  credential_hash TEXT NOT NULL UNIQUE,
  linked_via TEXT NOT NULL CHECK (linked_via IN ('app', 'token')),
  agent_version TEXT,
  created_by_session TEXT REFERENCES sessions (id),
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  paused_at TEXT,
  revoked_at TEXT
);
CREATE UNIQUE INDEX machines_local ON machines (owner_id, local_machine_id)
  WHERE revoked_at IS NULL AND local_machine_id IS NOT NULL;

CREATE TABLE workspace_machines (
  workspace_id TEXT NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
  machine_id TEXT NOT NULL REFERENCES machines (id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, machine_id)
);
CREATE INDEX workspace_machines_machine ON workspace_machines (machine_id);

CREATE TABLE audit_log (
  id TEXT PRIMARY KEY,
  at TEXT NOT NULL,
  actor_kind TEXT NOT NULL CHECK (actor_kind IN ('user', 'operator', 'machine', 'system')),
  actor_user_id TEXT REFERENCES users (id),
  session_id TEXT,
  machine_id TEXT REFERENCES machines (id),
  action TEXT NOT NULL,
  target_kind TEXT,
  target_id TEXT,
  command TEXT,
  result TEXT NOT NULL CHECK (result IN ('ok', 'denied', 'error', 'timeout')),
  status INTEGER,
  detail TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX audit_at ON audit_log (at);
CREATE INDEX audit_machine ON audit_log (machine_id, at);
