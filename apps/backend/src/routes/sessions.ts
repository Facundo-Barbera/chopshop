import { audit } from "../audit";
import { type AuthEnv, db, requireUser, revokeSession } from "../auth";
import { now } from "../db";
import { errorResponse, json, noContent } from "../http";
import type { Handler } from "../router";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const COLS = "id, user_id, client, device_name, user_agent, created_at, last_seen_at, expires_at";
const ACTIVE = "revoked_at IS NULL AND expires_at > ?1 AND absolute_expires_at > ?1";

interface SessionRow {
  id: string;
  user_id: string;
  client: string;
  device_name: string | null;
  user_agent: string | null;
  created_at: string;
  last_seen_at: string;
  expires_at: string;
}

const list: Handler<AuthEnv> = async (_request, { env, principal, url }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  let userId: string | null = p.userId;
  if (p.role === "owner") {
    userId = url.searchParams.get("user_id");
    if (userId !== null && !UUID.test(userId)) return errorResponse("bad_request", "user_id no válido", { field: "user_id" });
  }
  const where = userId === null ? ACTIVE : `${ACTIVE} AND user_id = ?2`;
  const stmt = db(env).prepare(`SELECT ${COLS} FROM sessions WHERE ${where} ORDER BY last_seen_at DESC`);
  const rows = await (userId === null ? stmt.bind(now()) : stmt.bind(now(), userId)).all<SessionRow>();
  return json({ sessions: rows.results.map((s) => ({ ...s, current: s.id === p.sessionId })) });
};

const revoke: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const d = db(env);
  const id = params.id!;
  const own = p.role === "owner" ? "" : " AND user_id = ?3";
  const stmt = d.prepare(`SELECT id, user_id FROM sessions WHERE id = ?2 AND ${ACTIVE}${own}`);
  const row = await (p.role === "owner" ? stmt.bind(now(), id) : stmt.bind(now(), id, p.userId)).first<{ id: string; user_id: string }>();
  if (!row || !(await revokeSession(env, row.id, "revoked"))) return errorResponse("not_found", "sesión no encontrada");
  await audit(d, {
    actorKind: "user",
    actorUserId: p.userId,
    sessionId: p.sessionId,
    action: "session.revoked",
    targetKind: "session",
    targetId: row.id,
    status: 204,
    detail: { user_id: row.user_id },
  });
  return noContent();
};

export const sessionHandlers: Record<string, Handler<AuthEnv>> = {
  "sessions.list": list,
  "sessions.revoke": revoke,
};
