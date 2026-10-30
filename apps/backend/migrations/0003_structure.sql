CREATE TABLE campus_layouts (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces (id) ON DELETE CASCADE,
  layout TEXT NOT NULL DEFAULT '{}',
  rev INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces (id),
  name TEXT NOT NULL,
  title TEXT,
  t3_project TEXT,
  repo TEXT,
  machine_id TEXT REFERENCES machines (id),
  runtime_mode TEXT NOT NULL DEFAULT 'approval-required'
    CHECK (runtime_mode IN ('approval-required', 'auto-accept-edits', 'auto', 'full-access')),
  model TEXT,
  settings TEXT NOT NULL DEFAULT '{}',
  position INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  disabled_at TEXT,
  archived_at TEXT
);
CREATE UNIQUE INDEX projects_name ON projects (name) WHERE archived_at IS NULL;
CREATE INDEX projects_workspace ON projects (workspace_id) WHERE archived_at IS NULL;
CREATE INDEX projects_machine ON projects (machine_id) WHERE archived_at IS NULL;

CREATE TABLE project_layouts (
  project_id TEXT PRIMARY KEY REFERENCES projects (id) ON DELETE CASCADE,
  layout TEXT NOT NULL DEFAULT '{}',
  rev INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE roles (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL DEFAULT '',
  model TEXT,
  match_rules TEXT NOT NULL DEFAULT '{}',
  wake TEXT NOT NULL DEFAULT '[]',
  settings TEXT NOT NULL DEFAULT '{}',
  position INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project_id, name)
);

CREATE TABLE import_offers (
  id TEXT PRIMARY KEY,
  machine_id TEXT NOT NULL REFERENCES machines (id) ON DELETE CASCADE,
  payload_hash TEXT NOT NULL,
  payload TEXT NOT NULL,
  summary TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  applied_at TEXT,
  applied_by TEXT REFERENCES users (id),
  dismissed_at TEXT,
  UNIQUE (machine_id, payload_hash)
);
