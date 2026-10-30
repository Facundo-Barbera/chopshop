import { type AuthEnv, type UserRow, db, notifyViewerChanged, publicUser, requireOwner, revokeUserSessions } from "../auth";
import { all, now, one } from "../db";
import { errorResponse, json, readJson } from "../http";
import type { Handler } from "../router";
import { auditStmt } from "./recovery";

type Body = Record<string, unknown>;

const COLS = "id, email, display_name, role, status, created_at";

interface SummaryRow extends UserRow {
  last_login_at: string | null;
  sessions_active: number;
}

const list: Handler<AuthEnv> = async (_request, { env, principal }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const users = await all<SummaryRow>(
    d,
    `SELECT u.id, u.email, u.display_name, u.role, u.status, u.created_at, u.last_login_at,
       (SELECT count(*) FROM sessions s WHERE s.user_id = u.id AND s.revoked_at IS NULL AND s.expires_at > ?1 AND s.absolute_expires_at > ?1) AS sessions_active
     FROM users u ORDER BY u.role = 'watcher', u.created_at`,
    now(),
  );
  const members = await all<{ user_id: string; workspace_id: string }>(
    d,
    "SELECT m.user_id, m.workspace_id FROM workspace_members m JOIN workspaces w ON w.id = m.workspace_id WHERE w.archived_at IS NULL ORDER BY m.workspace_id",
  );
  const byUser = new Map<string, string[]>();
  for (const m of members) byUser.set(m.user_id, [...(byUser.get(m.user_id) ?? []), m.workspace_id]);
  return json({
    users: users.map((u) => ({
      ...publicUser(u),
      workspace_ids: byUser.get(u.id) ?? [],
      last_login_at: u.last_login_at,
      sessions_active: Number(u.sessions_active),
    })),
  });
};

const get: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const user = await one<UserRow>(db(env), `SELECT ${COLS} FROM users WHERE id = ?`, params.id!);
  if (!user) return errorResponse("not_found", "usuario no encontrado");
  return json({ user: publicUser(user) });
};

const update: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const body = await readJson(request);
  if (body instanceof Response) return body;
  if (typeof body !== "object" || body === null || Array.isArray(body)) return errorResponse("bad_request", "se esperaba un objeto JSON");
  const b = body as Body;
  if (b.status === undefined && b.display_name === undefined) return errorResponse("bad_request", "nada que cambiar");
  if (b.status !== undefined && b.status !== "active" && b.status !== "disabled") {
    return errorResponse("bad_request", "status debe ser active o disabled", { field: "status" });
  }
  let displayName: string | undefined;
  if (b.display_name !== undefined) {
    displayName = typeof b.display_name === "string" ? b.display_name.trim().normalize("NFC") : "";
    if (displayName.length < 1 || [...displayName].length > 80) {
      return errorResponse("bad_request", "display_name debe tener entre 1 y 80 caracteres", { field: "display_name" });
    }
  }
  const d = db(env);
  const user = await one<UserRow>(d, `SELECT ${COLS} FROM users WHERE id = ?`, params.id!);
  if (!user) return errorResponse("not_found", "usuario no encontrado");
  if (b.status !== undefined && user.role === "owner") return errorResponse("conflict", "no se puede cambiar el estado del dueño");

  const nextStatus = (b.status as UserRow["status"] | undefined) ?? user.status;
  const next: UserRow = { ...user, status: nextStatus, display_name: displayName ?? user.display_name };
  const t = now();
  const action = nextStatus === user.status ? "user.updated" : nextStatus === "disabled" ? "user.disabled" : "user.enabled";
  await d.batch([
    d.prepare("UPDATE users SET status = ?, display_name = ?, updated_at = ? WHERE id = ?").bind(next.status, next.display_name, t, user.id),
    auditStmt(d, {
      actorKind: "user",
      actorUserId: owner.userId,
      sessionId: owner.sessionId,
      action,
      targetKind: "user",
      targetId: user.id,
      result: "ok",
      status: 200,
    }),
  ]);
  if (action === "user.disabled") {
    await revokeUserSessions(env, user.id, "user_disabled");
    await notifyViewerChanged(env, user.id);
  }
  return json({ user: publicUser(next) });
};

export const userHandlers: Record<string, Handler<AuthEnv>> = {
  "users.list": list,
  "users.get": get,
  "users.update": update,
};
