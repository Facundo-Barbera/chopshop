import type { AuthEnv, HubRpc } from "./auth";
import { isToken, newToken, sha256Hex } from "./crypto";
import { now, uuid } from "./db";

export type Platform = "macos" | "linux" | "other";
export type LinkedVia = "app" | "token";

export const PLATFORMS: readonly Platform[] = ["macos", "linux", "other"];
export const LOCAL_MACHINE_ID_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
export const REVOKED_LISTED_MS = 30 * 24 * 60 * 60 * 1000;

export interface MachineCtx {
  machineId: string;
  localMachineId: string | null;
  name: string;
}

export interface MachineChange {
  paused?: boolean;
  revoked?: boolean;
  workspaceIds?: string[];
}

export interface MachineHubRpc {
  machineChanged(machineId: string, change: MachineChange): Promise<void>;
  online(): Promise<string[]>;
}

export interface MachinesEnv extends AuthEnv {
  HUB?: { idFromName(name: string): DurableObjectId; get(id: DurableObjectId): HubRpc & MachineHubRpc };
}

export interface MachineRow {
  id: string;
  owner_id: string;
  name: string;
  platform: Platform;
  local_machine_id: string | null;
  linked_via: LinkedVia;
  agent_version: string | null;
  created_at: string;
  last_seen_at: string | null;
  paused_at: string | null;
  revoked_at: string | null;
}

export interface NewMachine {
  ownerId: string;
  sessionId: string;
  name: string;
  platform: Platform;
  localMachineId: string | null;
  workspaceIds: string[];
}

const COLS = "id, owner_id, name, platform, local_machine_id, linked_via, agent_version, created_at, last_seen_at, paused_at, revoked_at";

export async function verifyMachine(db: D1Database, bearer: string): Promise<(MachineCtx & { paused: boolean }) | null> {
  const token = bearer.startsWith("Bearer ") ? bearer.slice(7).trim() : bearer;
  if (!isToken("machine", token)) return null;
  const m = await db
    .prepare("SELECT id, local_machine_id, name, paused_at FROM machines WHERE credential_hash = ? AND revoked_at IS NULL")
    .bind(await sha256Hex(token))
    .first<{ id: string; local_machine_id: string | null; name: string; paused_at: string | null }>();
  return m ? { machineId: m.id, localMachineId: m.local_machine_id, name: m.name, paused: m.paused_at !== null } : null;
}

export function publicMachine(m: MachineRow, workspaceIds: string[], online: boolean): Record<string, unknown> {
  return {
    id: m.id,
    name: m.name,
    platform: m.platform,
    local_machine_id: m.local_machine_id,
    linked_via: m.linked_via,
    agent_version: m.agent_version,
    workspace_ids: workspaceIds,
    created_at: m.created_at,
    last_seen_at: m.last_seen_at,
    paused_at: m.paused_at,
    revoked_at: m.revoked_at,
    online: online && m.revoked_at === null && m.paused_at === null,
  };
}

export async function getMachine(db: D1Database, ownerId: string, id: string): Promise<MachineRow | null> {
  return db.prepare(`SELECT ${COLS} FROM machines WHERE id = ? AND owner_id = ?`).bind(id, ownerId).first<MachineRow>();
}

export async function listMachines(db: D1Database, ownerId: string): Promise<MachineRow[]> {
  const cutoff = new Date(Date.now() - REVOKED_LISTED_MS).toISOString();
  const rows = await db
    .prepare(`SELECT ${COLS} FROM machines WHERE owner_id = ? AND (revoked_at IS NULL OR revoked_at > ?) ORDER BY created_at, id`)
    .bind(ownerId, cutoff)
    .all<MachineRow>();
  return rows.results;
}

export async function workspaceIdsByMachine(db: D1Database, machineIds: string[]): Promise<Map<string, string[]>> {
  const out = new Map<string, string[]>(machineIds.map((id) => [id, []]));
  if (machineIds.length === 0) return out;
  const marks = machineIds.map(() => "?").join(", ");
  const rows = await db
    .prepare(`SELECT machine_id, workspace_id FROM workspace_machines WHERE machine_id IN (${marks}) ORDER BY workspace_id`)
    .bind(...machineIds)
    .all<{ machine_id: string; workspace_id: string }>();
  for (const r of rows.results) out.get(r.machine_id)?.push(r.workspace_id);
  return out;
}

export async function ownerWorkspaceIds(db: D1Database, ownerId: string, wanted: string[] | null): Promise<string[] | null> {
  const rows = await db
    .prepare("SELECT id FROM workspaces WHERE owner_id = ? AND archived_at IS NULL ORDER BY position, id")
    .bind(ownerId)
    .all<{ id: string }>();
  const ids = rows.results.map((r) => r.id);
  if (wanted === null) return ids;
  const known = new Set(ids);
  return wanted.every((id) => known.has(id)) ? wanted : null;
}

export async function activeByLocalId(db: D1Database, ownerId: string, localMachineId: string): Promise<string | null> {
  return db
    .prepare("SELECT id FROM machines WHERE owner_id = ? AND local_machine_id = ? AND revoked_at IS NULL")
    .bind(ownerId, localMachineId)
    .first<string>("id");
}

export async function createMachine(
  db: D1Database,
  m: NewMachine,
  replaceId: string | null = null,
): Promise<{ row: MachineRow; credential: string }> {
  const credential = newToken("machine");
  const t = now();
  const row: MachineRow = {
    id: uuid(),
    owner_id: m.ownerId,
    name: m.name,
    platform: m.platform,
    local_machine_id: m.localMachineId,
    linked_via: m.localMachineId === null ? "token" : "app",
    agent_version: null,
    created_at: t,
    last_seen_at: null,
    paused_at: null,
    revoked_at: null,
  };
  const stmts: D1PreparedStatement[] = [];
  if (replaceId !== null) stmts.push(db.prepare("UPDATE machines SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL").bind(t, replaceId));
  stmts.push(
    db
      .prepare(
        `INSERT INTO machines (id, owner_id, name, platform, local_machine_id, credential_hash, linked_via, created_by_session, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(row.id, row.owner_id, row.name, row.platform, row.local_machine_id, await sha256Hex(credential), row.linked_via, m.sessionId, t),
  );
  for (const w of m.workspaceIds) {
    stmts.push(db.prepare("INSERT INTO workspace_machines (workspace_id, machine_id, created_at) VALUES (?, ?, ?)").bind(w, row.id, t));
  }
  await db.batch(stmts);
  return { row, credential };
}

export async function setPaused(db: D1Database, id: string, paused: boolean): Promise<boolean> {
  const stmt = paused
    ? db.prepare("UPDATE machines SET paused_at = ? WHERE id = ? AND revoked_at IS NULL AND paused_at IS NULL").bind(now(), id)
    : db.prepare("UPDATE machines SET paused_at = NULL WHERE id = ? AND revoked_at IS NULL AND paused_at IS NOT NULL").bind(id);
  const res = await stmt.run();
  return res.meta.changes === 1;
}

export async function revokeMachine(db: D1Database, id: string): Promise<boolean> {
  const res = await db.prepare("UPDATE machines SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL").bind(now(), id).run();
  return res.meta.changes === 1;
}

function hub(env: MachinesEnv): (HubRpc & MachineHubRpc) | null {
  return env.HUB ? env.HUB.get(env.HUB.idFromName("owner")) : null;
}

export async function machineChanged(env: MachinesEnv, machineId: string, change: MachineChange): Promise<void> {
  const h = hub(env);
  if (!h) return;
  try {
    await h.machineChanged(machineId, change);
  } catch (err) {
    console.error(JSON.stringify({ code: "hub_machine_changed", error: err instanceof Error ? err.name : "unknown" }));
  }
}

export async function onlineMachines(env: MachinesEnv): Promise<Set<string>> {
  const h = hub(env);
  if (!h) return new Set();
  try {
    return new Set(await h.online());
  } catch (err) {
    console.error(JSON.stringify({ code: "hub_online", error: err instanceof Error ? err.name : "unknown" }));
    return new Set();
  }
}
