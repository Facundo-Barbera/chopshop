export type Scope = "agent" | "viewer";

export interface TokenRecord {
  tokenId: string;
  scope: Scope;
  account: string;
  name: string | null;
  machineId: string | null;
  createdAt: number;
  lastSeenAt: number | null;
}

export interface IssuedToken extends TokenRecord {
  token: string;
}

export interface StoredSnapshot {
  machineId: string;
  seq: number;
  ttlS: number;
  frame: string;
  receivedAt: number;
  expiresAt: number;
}

export const SNAPSHOT_TTL_MIN_S = 30;
export const SNAPSHOT_TTL_MAX_S = 900;
export const SNAPSHOT_TTL_DEFAULT_S = 120;
const LAST_SEEN_INTERVAL_MS = 60_000;
const TOKEN_RE = /^cr1_[A-Za-z0-9_-]{43}$/;

const MIGRATIONS: readonly string[] = [
  `CREATE TABLE tokens (
     id TEXT PRIMARY KEY,
     hash TEXT NOT NULL UNIQUE,
     scope TEXT NOT NULL CHECK (scope IN ('agent', 'viewer')),
     account TEXT NOT NULL,
     name TEXT,
     machine_id TEXT,
     created_at INTEGER NOT NULL,
     last_seen_at INTEGER,
     revoked_at INTEGER
   );
   CREATE INDEX tokens_account ON tokens (account, revoked_at);
   CREATE INDEX tokens_machine ON tokens (account, machine_id, revoked_at);
   CREATE TABLE machines (
     account TEXT NOT NULL,
     machine_id TEXT NOT NULL,
     agent_version TEXT,
     projects TEXT NOT NULL DEFAULT '[]',
     first_seen_at INTEGER NOT NULL,
     last_seen_at INTEGER NOT NULL,
     PRIMARY KEY (account, machine_id)
   );
   CREATE TABLE snapshot (
     account TEXT NOT NULL,
     machine_id TEXT NOT NULL,
     seq INTEGER NOT NULL,
     ttl_s INTEGER NOT NULL,
     frame TEXT NOT NULL,
     received_at INTEGER NOT NULL,
     expires_at INTEGER NOT NULL,
     PRIMARY KEY (account, machine_id)
   );
   CREATE INDEX snapshot_expires ON snapshot (expires_at);
   CREATE TABLE pair_codes (
     id TEXT PRIMARY KEY,
     account TEXT NOT NULL,
     scope TEXT NOT NULL CHECK (scope IN ('agent', 'viewer')),
     name TEXT,
     salt TEXT NOT NULL,
     hash TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     expires_at INTEGER NOT NULL,
     used_at INTEGER,
     invalidated_at INTEGER,
     failures INTEGER NOT NULL DEFAULT 0
   );
   CREATE INDEX pair_codes_account ON pair_codes (account, expires_at);
   CREATE TABLE attempts (
     key TEXT NOT NULL,
     at INTEGER NOT NULL
   );
   CREATE INDEX attempts_key ON attempts (key, at);`,
];

export const SCHEMA_VERSION = MIGRATIONS.length;

function hex(bytes: ArrayBuffer | Uint8Array): string {
  return Array.from(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
}

function base64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function sha256Hex(value: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

export function randomId(prefix: string): string {
  return `${prefix}-${hex(crypto.getRandomValues(new Uint8Array(4)))}`;
}

export function clampTtl(ttlS: number | null | undefined): number {
  if (ttlS === null || ttlS === undefined || !Number.isFinite(ttlS)) return SNAPSHOT_TTL_DEFAULT_S;
  return Math.min(SNAPSHOT_TTL_MAX_S, Math.max(SNAPSHOT_TTL_MIN_S, Math.floor(ttlS)));
}

type TokenRow = {
  id: string;
  scope: string;
  account: string;
  name: string | null;
  machine_id: string | null;
  created_at: number;
  last_seen_at: number | null;
};

function toRecord(row: TokenRow): TokenRecord {
  return {
    tokenId: row.id,
    scope: row.scope as Scope,
    account: row.account,
    name: row.name,
    machineId: row.machine_id,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
  };
}

type SnapshotRow = {
  machine_id: string;
  seq: number;
  ttl_s: number;
  frame: string;
  received_at: number;
  expires_at: number;
};

function toSnapshot(row: SnapshotRow): StoredSnapshot {
  return {
    machineId: row.machine_id,
    seq: row.seq,
    ttlS: row.ttl_s,
    frame: row.frame,
    receivedAt: row.received_at,
    expiresAt: row.expires_at,
  };
}

export class RelayDb {
  constructor(
    private readonly sql: SqlStorage,
    private readonly storage: DurableObjectStorage,
  ) {}

  migrate(): number {
    this.sql.exec("CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)");
    const row = this.sql.exec<{ value: number }>("SELECT value FROM schema_meta WHERE key = 'version'").toArray()[0];
    const current = row?.value ?? 0;
    if (current > SCHEMA_VERSION) {
      throw new Error(`schema version ${current} is newer than ${SCHEMA_VERSION}`);
    }
    for (let v = current; v < SCHEMA_VERSION; v++) {
      this.storage.transactionSync(() => {
        this.sql.exec(MIGRATIONS[v]!);
        this.sql.exec(
          "INSERT INTO schema_meta (key, value) VALUES ('version', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
          v + 1,
        );
      });
    }
    return SCHEMA_VERSION;
  }

  async issueToken(opts: {
    scope: Scope;
    account: string;
    name?: string | null;
    machineId?: string | null;
    now?: number;
  }): Promise<IssuedToken> {
    const now = opts.now ?? Date.now();
    const machineId = opts.scope === "agent" ? (opts.machineId ?? null) : null;
    if (opts.scope === "agent" && machineId === null) {
      throw new Error("agent tokens require a machine_id");
    }
    const token = `cr1_${base64url(crypto.getRandomValues(new Uint8Array(32)))}`;
    const hash = await sha256Hex(token);
    const tokenId = randomId("tk");
    const name = opts.name ?? null;
    this.storage.transactionSync(() => {
      if (machineId !== null) {
        this.sql.exec(
          "UPDATE tokens SET revoked_at = ? WHERE account = ? AND machine_id = ? AND scope = 'agent' AND revoked_at IS NULL",
          now,
          opts.account,
          machineId,
        );
      }
      this.sql.exec(
        "INSERT INTO tokens (id, hash, scope, account, name, machine_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        tokenId,
        hash,
        opts.scope,
        opts.account,
        name,
        machineId,
        now,
      );
    });
    return {
      token,
      tokenId,
      scope: opts.scope,
      account: opts.account,
      name,
      machineId,
      createdAt: now,
      lastSeenAt: null,
    };
  }

  async verifyToken(token: string, now: number = Date.now()): Promise<TokenRecord | null> {
    if (!TOKEN_RE.test(token)) return null;
    const hash = await sha256Hex(token);
    const row = this.sql
      .exec<TokenRow>(
        "SELECT id, scope, account, name, machine_id, created_at, last_seen_at FROM tokens WHERE hash = ? AND revoked_at IS NULL",
        hash,
      )
      .toArray()[0];
    if (!row) return null;
    if (row.last_seen_at === null || now - row.last_seen_at >= LAST_SEEN_INTERVAL_MS) {
      this.sql.exec("UPDATE tokens SET last_seen_at = ? WHERE id = ?", now, row.id);
      row.last_seen_at = now;
    }
    return toRecord(row);
  }

  revokeToken(tokenId: string, account: string, now: number = Date.now()): boolean {
    return (
      this.sql.exec(
        "UPDATE tokens SET revoked_at = ? WHERE id = ? AND account = ? AND revoked_at IS NULL",
        now,
        tokenId,
        account,
      ).rowsWritten > 0
    );
  }

  getToken(tokenId: string): TokenRecord | null {
    const row = this.sql
      .exec<TokenRow>(
        "SELECT id, scope, account, name, machine_id, created_at, last_seen_at FROM tokens WHERE id = ? AND revoked_at IS NULL",
        tokenId,
      )
      .toArray()[0];
    return row ? toRecord(row) : null;
  }

  touchMachine(
    account: string,
    machineId: string,
    info: { agentVersion?: string | null; projects?: unknown } = {},
    now: number = Date.now(),
  ): void {
    this.sql.exec(
      `INSERT INTO machines (account, machine_id, agent_version, projects, first_seen_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (account, machine_id) DO UPDATE SET
         agent_version = COALESCE(excluded.agent_version, machines.agent_version),
         projects = CASE WHEN ? THEN excluded.projects ELSE machines.projects END,
         last_seen_at = excluded.last_seen_at`,
      account,
      machineId,
      info.agentVersion ?? null,
      JSON.stringify(info.projects ?? []),
      now,
      now,
      info.projects === undefined ? 0 : 1,
    );
  }

  listMachines(account: string): { machineId: string; agentVersion: string | null; lastSeenAt: number }[] {
    return this.sql
      .exec<{ machine_id: string; agent_version: string | null; last_seen_at: number }>(
        "SELECT machine_id, agent_version, last_seen_at FROM machines WHERE account = ? ORDER BY machine_id",
        account,
      )
      .toArray()
      .map((r) => ({ machineId: r.machine_id, agentVersion: r.agent_version, lastSeenAt: r.last_seen_at }));
  }

  listAgentMachines(account: string): string[] {
    return this.sql
      .exec<{ machine_id: string }>(
        "SELECT DISTINCT machine_id FROM tokens WHERE account = ? AND scope = 'agent' AND revoked_at IS NULL AND machine_id IS NOT NULL ORDER BY machine_id",
        account,
      )
      .toArray()
      .map((r) => r.machine_id);
  }

  putSnapshot(
    account: string,
    machineId: string,
    seq: number,
    ttlS: number | null | undefined,
    frame: string,
    now: number = Date.now(),
  ): StoredSnapshot {
    const ttl = clampTtl(ttlS);
    const expiresAt = now + ttl * 1000;
    this.sql.exec(
      `INSERT INTO snapshot (account, machine_id, seq, ttl_s, frame, received_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (account, machine_id) DO UPDATE SET
         seq = excluded.seq, ttl_s = excluded.ttl_s, frame = excluded.frame,
         received_at = excluded.received_at, expires_at = excluded.expires_at`,
      account,
      machineId,
      seq,
      ttl,
      frame,
      now,
      expiresAt,
    );
    return { machineId, seq, ttlS: ttl, frame, receivedAt: now, expiresAt };
  }

  getSnapshot(account: string, machineId: string, now: number = Date.now()): StoredSnapshot | null {
    const row = this.sql
      .exec<SnapshotRow>(
        "SELECT machine_id, seq, ttl_s, frame, received_at, expires_at FROM snapshot WHERE account = ? AND machine_id = ?",
        account,
        machineId,
      )
      .toArray()[0];
    if (!row) return null;
    if (row.expires_at <= now) {
      this.sql.exec("DELETE FROM snapshot WHERE account = ? AND machine_id = ?", account, machineId);
      return null;
    }
    return toSnapshot(row);
  }

  listSnapshots(account: string, now: number = Date.now()): StoredSnapshot[] {
    this.purgeExpiredSnapshots(now);
    return this.sql
      .exec<SnapshotRow>(
        "SELECT machine_id, seq, ttl_s, frame, received_at, expires_at FROM snapshot WHERE account = ? ORDER BY machine_id",
        account,
      )
      .toArray()
      .map(toSnapshot);
  }

  purgeExpiredSnapshots(now: number = Date.now()): number {
    return this.sql.exec("DELETE FROM snapshot WHERE expires_at <= ?", now).rowsWritten;
  }

  nextSnapshotExpiry(): number | null {
    const row = this.sql.exec<{ at: number | null }>("SELECT MIN(expires_at) AS at FROM snapshot").toArray()[0];
    return row?.at ?? null;
  }
}
