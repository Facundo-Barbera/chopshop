import { visibleWorkspaces } from "./access";
import type { UserPrincipal } from "./auth";
import type { LiveEnv } from "./hub";
import { errorResponse, ulid } from "./http";
import { parseObject, structureRev, UUID_RE } from "./structure";
import type { LiveMachine, LiveState, LiveSync, ViewCtx } from "./viewer";

interface WorkspaceRow {
  id: string;
  name: string;
  slug: string;
  position: number;
  style: string;
  campus_layout: string | null;
  campus_rev: number | null;
}

interface ProjectRow {
  id: string;
  workspace_id: string;
  name: string;
  title: string | null;
  machine_id: string | null;
  disabled_at: string | null;
  layout: string | null;
}

interface MachineRow {
  id: string;
  name: string;
  platform: string;
  paused_at: string | null;
}

function marks(ids: string[]): string {
  return ids.map(() => "?").join(", ");
}

export async function viewFor(db: D1Database, p: UserPrincipal, only: string | null): Promise<ViewCtx | Response> {
  const notFound = () => errorResponse("not_found", "workspace no encontrado");
  const visible = await visibleWorkspaces(db, p);
  const base = { userId: p.userId, role: p.role, sessionId: p.sessionId };
  if (only === null) return { ...base, workspaceIds: visible };
  if (!UUID_RE.test(only)) return notFound();
  if (visible === "all") {
    const w = await db.prepare("SELECT id FROM workspaces WHERE id = ? AND archived_at IS NULL").bind(only).first();
    return w === null ? notFound() : { ...base, workspaceIds: [only] };
  }
  return visible.includes(only) ? { ...base, workspaceIds: [only] } : notFound();
}

export function workspaceParam(url: URL): string | null {
  return url.searchParams.get("workspace");
}

async function workspaceRows(db: D1Database, view: ViewCtx): Promise<WorkspaceRow[]> {
  const sql = `SELECT w.id, w.name, w.slug, w.position, w.style, c.layout AS campus_layout, c.rev AS campus_rev
    FROM workspaces w LEFT JOIN campus_layouts c ON c.workspace_id = w.id WHERE w.archived_at IS NULL`;
  const order = " ORDER BY w.position, w.name";
  if (view.workspaceIds === "all") return (await db.prepare(sql + order).all<WorkspaceRow>()).results;
  if (view.workspaceIds.length === 0) return [];
  const ids = view.workspaceIds;
  return (await db.prepare(`${sql} AND w.id IN (${marks(ids)})${order}`).bind(...ids).all<WorkspaceRow>()).results;
}

type SyncErrors = Map<string, { message: string; rev: number }[]>;

function syncErrors(sync: LiveSync[]): SyncErrors {
  const out: SyncErrors = new Map();
  for (const s of sync) {
    for (const e of s.errors) {
      const key = `${s.machine_id}/${e.project}`;
      out.set(key, [...(out.get(key) ?? []), { message: e.message, rev: s.rev }]);
    }
  }
  return out;
}

async function city(db: D1Database, workspaces: WorkspaceRow[], errors: SyncErrors) {
  const ids = workspaces.map((w) => w.id);
  if (ids.length === 0) return { workspaces: [], machineIds: [] as string[] };
  const [projects, roles, wm] = await Promise.all([
    db
      .prepare(
        `SELECT p.id, p.workspace_id, p.name, p.title, p.machine_id, p.disabled_at, l.layout FROM projects p
         LEFT JOIN project_layouts l ON l.project_id = p.id
         WHERE p.archived_at IS NULL AND p.workspace_id IN (${marks(ids)}) ORDER BY p.position, p.name`,
      )
      .bind(...ids)
      .all<ProjectRow>(),
    db
      .prepare(
        `SELECT r.project_id, r.name FROM roles r JOIN projects p ON p.id = r.project_id
         WHERE p.archived_at IS NULL AND p.workspace_id IN (${marks(ids)}) ORDER BY r.position, r.name`,
      )
      .bind(...ids)
      .all<{ project_id: string; name: string }>(),
    db
      .prepare(
        `SELECT wm.workspace_id, wm.machine_id FROM workspace_machines wm JOIN machines m ON m.id = wm.machine_id
         WHERE m.revoked_at IS NULL AND wm.workspace_id IN (${marks(ids)}) ORDER BY wm.machine_id`,
      )
      .bind(...ids)
      .all<{ workspace_id: string; machine_id: string }>(),
  ]);
  const rolesBy = new Map<string, string[]>();
  for (const r of roles.results) rolesBy.set(r.project_id, [...(rolesBy.get(r.project_id) ?? []), r.name]);
  const machinesBy = new Map<string, string[]>();
  for (const r of wm.results) machinesBy.set(r.workspace_id, [...(machinesBy.get(r.workspace_id) ?? []), r.machine_id]);
  return {
    workspaces: workspaces.map((w) => ({
      id: w.id,
      name: w.name,
      slug: w.slug,
      position: w.position,
      style: parseObject(w.style),
      campus: { layout: parseObject(w.campus_layout), rev: w.campus_rev ?? 1 },
      projects: projects.results
        .filter((p) => p.workspace_id === w.id)
        .map((p) => ({
          id: p.id,
          name: p.name,
          title: p.title,
          machine_id: p.machine_id,
          disabled: p.disabled_at !== null,
          layout: parseObject(p.layout),
          roles: rolesBy.get(p.id) ?? [],
          sync_errors: p.machine_id === null ? [] : (errors.get(`${p.machine_id}/${p.name}`) ?? []),
        })),
      machine_ids: machinesBy.get(w.id) ?? [],
    })),
    machineIds: [...new Set(wm.results.map((r) => r.machine_id))],
  };
}

async function machineRows(db: D1Database, p: UserPrincipal, view: ViewCtx, inCity: string[]): Promise<MachineRow[]> {
  if (p.role === "owner" && view.workspaceIds === "all") {
    return (
      await db
        .prepare("SELECT id, name, platform, paused_at FROM machines WHERE owner_id = ? AND revoked_at IS NULL ORDER BY created_at, id")
        .bind(p.userId)
        .all<MachineRow>()
    ).results;
  }
  if (inCity.length === 0) return [];
  return (
    await db
      .prepare(`SELECT id, name, platform, paused_at FROM machines WHERE revoked_at IS NULL AND id IN (${marks(inCity)}) ORDER BY created_at, id`)
      .bind(...inCity)
      .all<MachineRow>()
  ).results;
}

async function liveState(env: LiveEnv, view: ViewCtx): Promise<LiveState | null> {
  if (!env.HUB) return null;
  try {
    return await env.HUB.get(env.HUB.idFromName("owner")).state(view);
  } catch (err) {
    console.error(JSON.stringify({ code: "hub_state", error: err instanceof Error ? err.name : "unknown" }));
    return null;
  }
}

export async function cityState(env: LiveEnv, db: D1Database, p: UserPrincipal, view: ViewCtx): Promise<Record<string, unknown>> {
  const workspaces = await workspaceRows(db, view);
  const [rev, live] = await Promise.all([structureRev(db), liveState(env, view)]);
  const built = await city(db, workspaces, syncErrors(live?.sync ?? []));
  const machines = await machineRows(db, p, view, built.machineIds);
  const liveBy = new Map<string, LiveMachine>((live?.machines ?? []).map((m) => [m.id, m]));
  return {
    v: 2,
    type: "state",
    id: ulid(),
    ts: new Date().toISOString(),
    rev,
    head: live?.head ?? `${ulid().slice(10, 18)}-0`,
    user: { id: p.userId, role: p.role },
    city: { workspaces: built.workspaces },
    machines: machines.map((m) => {
      const l = liveBy.get(m.id);
      const paused = m.paused_at !== null;
      const online = (l?.online ?? false) && !paused;
      const stale = l?.stale ?? true;
      if (p.role !== "owner") return { id: m.id, name: m.name, online, stale };
      return {
        id: m.id,
        name: m.name,
        platform: m.platform,
        online,
        paused,
        stale,
        seq: l?.seq ?? null,
        snapshot_age_s: l?.snapshot_age_s ?? null,
        expires_at: l?.expires_at ?? null,
      };
    }),
    snapshots: live?.snapshots ?? [],
  };
}
