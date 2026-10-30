import { errorResponse, type Principal } from "./http";

export type Visible = string[] | "all";

const NOT_FOUND = "workspace no encontrado";

export async function visibleWorkspaces(db: D1Database, p: Principal): Promise<Visible> {
  if (p.kind !== "user") return [];
  if (p.role === "owner") return "all";
  const rows = await db
    .prepare(
      `SELECT w.id FROM workspaces w JOIN workspace_members m ON m.workspace_id = w.id AND m.user_id = ?
       WHERE w.archived_at IS NULL ORDER BY w.position, w.name`,
    )
    .bind(p.userId)
    .all<{ id: string }>();
  return rows.results.map((r) => r.id);
}

export async function canSee(db: D1Database, p: Principal, workspaceId: string): Promise<boolean> {
  if (p.kind !== "user") return false;
  if (p.role === "owner") {
    const w = await db.prepare("SELECT id FROM workspaces WHERE id = ? AND archived_at IS NULL").bind(workspaceId).first();
    return w !== null;
  }
  const m = await db
    .prepare(
      `SELECT w.id FROM workspaces w JOIN workspace_members m ON m.workspace_id = w.id AND m.user_id = ?
       WHERE w.id = ? AND w.archived_at IS NULL`,
    )
    .bind(p.userId, workspaceId)
    .first();
  return m !== null;
}

export async function assertVisible(db: D1Database, p: Principal, workspaceId: string): Promise<Response | null> {
  return (await canSee(db, p, workspaceId)) ? null : errorResponse("not_found", NOT_FOUND);
}
