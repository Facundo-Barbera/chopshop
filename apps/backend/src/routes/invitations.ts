import {
  type AuthEnv,
  type UserRow,
  clientIp,
  db,
  newSessionStatement,
  notifyHub,
  parseClient,
  passwordPolicyError,
  pepper,
  requireOwner,
  sessionResponse,
  validEmail,
} from "../auth";
import { generateRecoveryCode, hashPassword, isToken, newToken, recoveryCodeHash, sha256Hex } from "../crypto";
import { type SqlValue, all, batch, isConstraintError, now, one, uuid } from "../db";
import { errorResponse, json, noContent, readJson, webOrigin } from "../http";
import { RATE_LIMITED_MESSAGE, type LimitKey, limitKey, recordFailure, retryAfter } from "../ratelimit";
import type { Handler } from "../router";
import { auditStmt } from "./recovery";

type Body = Record<string, unknown>;
type Kind = "owner_bootstrap" | "owner_reset" | "watcher";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DEFAULT_TTL_H = 168;
const MAX_TTL_H = 720;
const RECENT_LIMIT = 50;
const INVALID_TOKEN = "invitación no válida";
const COLS = "id, email, email_normalized, kind, role, created_by, created_at, expires_at, used_at, revoked_at";

interface InvitationRow {
  id: string;
  email: string;
  email_normalized: string;
  kind: Kind;
  role: "owner" | "watcher";
  created_by: string | null;
  created_at: string;
  expires_at: string;
  used_at: string | null;
  revoked_at: string | null;
}

function status(inv: InvitationRow, t: string): "pending" | "used" | "revoked" | "expired" {
  if (inv.used_at !== null) return "used";
  if (inv.revoked_at !== null) return "revoked";
  return inv.expires_at <= t ? "expired" : "pending";
}

function publicInvitation(inv: InvitationRow, workspaceIds: string[], t: string): Body {
  return {
    id: inv.id,
    email: inv.email,
    kind: inv.kind,
    role: inv.role,
    workspace_ids: workspaceIds,
    created_at: inv.created_at,
    expires_at: inv.expires_at,
    used_at: inv.used_at,
    revoked_at: inv.revoked_at,
    status: status(inv, t),
  };
}

function link(env: AuthEnv, token: string): string {
  return `${webOrigin(env)}/invite#t=${token}`;
}

function marks(n: number): string {
  return Array.from({ length: n }, () => "?").join(", ");
}

async function workspaceIdsOf(d: D1Database, ids: string[]): Promise<Map<string, string[]>> {
  const out = new Map<string, string[]>(ids.map((id) => [id, []]));
  if (ids.length === 0) return out;
  const rows = await all<{ invitation_id: string; workspace_id: string }>(
    d,
    `SELECT invitation_id, workspace_id FROM invitation_workspaces WHERE invitation_id IN (${marks(ids.length)}) ORDER BY workspace_id`,
    ...ids,
  );
  for (const r of rows) out.get(r.invitation_id)?.push(r.workspace_id);
  return out;
}

async function readBody(request: Request, optional = false): Promise<Body | Response> {
  if (optional && request.body === null) return {};
  const body = await readJson(request);
  if (body instanceof Response) return body;
  if (typeof body !== "object" || body === null || Array.isArray(body)) return errorResponse("bad_request", "se esperaba un objeto JSON");
  return body as Body;
}

function parseTtl(value: unknown): number | Response {
  if (value === undefined) return DEFAULT_TTL_H;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > MAX_TTL_H) {
    return errorResponse("bad_request", "ttl_h debe ser un entero entre 1 y 720", { field: "ttl_h" });
  }
  return value;
}

function expiry(t: string, ttlH: number): string {
  return new Date(Date.parse(t) + ttlH * 3600_000).toISOString();
}

function rateLimited(retryAfterS: number): Response {
  return errorResponse("rate_limited", RATE_LIMITED_MESSAGE, { retryAfterS });
}

async function tokenKeys(request: Request): Promise<LimitKey[]> {
  const ip = clientIp(request);
  return Promise.all([limitKey("inv", ip), limitKey("ip", ip)]);
}

async function findByToken(request: Request, d: D1Database, token: unknown): Promise<InvitationRow | Response> {
  const keys = await tokenKeys(request);
  const wait = await retryAfter(d, keys);
  if (wait > 0) return rateLimited(wait);
  const inv = isToken("invitation", token)
    ? await one<InvitationRow>(d, `SELECT ${COLS} FROM invitations WHERE token_hash = ?`, await sha256Hex(token))
    : null;
  if (!inv) {
    const locked = await recordFailure(d, keys);
    return locked > 0 ? rateLimited(locked) : errorResponse("unauthorized", INVALID_TOKEN);
  }
  if (status(inv, now()) !== "pending") return errorResponse("gone", "la invitación ya se usó, se revocó o caducó");
  return inv;
}

const list: Handler<AuthEnv> = async (_request, { env, principal }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const pending = await all<InvitationRow>(
    d,
    `SELECT ${COLS} FROM invitations WHERE kind = 'watcher' AND used_at IS NULL AND revoked_at IS NULL ORDER BY created_at DESC`,
  );
  const done = await all<InvitationRow>(
    d,
    `SELECT ${COLS} FROM invitations WHERE kind = 'watcher' AND (used_at IS NOT NULL OR revoked_at IS NOT NULL)
     ORDER BY COALESCE(used_at, revoked_at) DESC LIMIT ${RECENT_LIMIT}`,
  );
  const rows = [...pending, ...done];
  const ws = await workspaceIdsOf(d, rows.map((r) => r.id));
  const t = now();
  return json({ invitations: rows.map((r) => publicInvitation(r, ws.get(r.id) ?? [], t)) });
};

const create: Handler<AuthEnv> = async (request, { env, principal }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const email = validEmail(body.email);
  if (email === null) return errorResponse("bad_request", "correo no válido", { field: "email" });
  const raw = body.workspace_ids;
  if (!Array.isArray(raw) || raw.length === 0 || !raw.every((w) => typeof w === "string" && UUID.test(w))) {
    return errorResponse("bad_request", "workspace_ids debe ser una lista no vacía de ids", { field: "workspace_ids" });
  }
  const workspaceIds = [...new Set(raw as string[])].sort();
  const ttl = parseTtl(body.ttl_h);
  if (ttl instanceof Response) return ttl;
  const d = db(env);
  if (await one(d, "SELECT id FROM users WHERE email_normalized = ?", email)) {
    return errorResponse("conflict", "ya existe un usuario con ese correo");
  }
  const found = await all<{ id: string }>(
    d,
    `SELECT id FROM workspaces WHERE archived_at IS NULL AND id IN (${marks(workspaceIds.length)})`,
    ...workspaceIds,
  );
  if (found.length !== workspaceIds.length) return errorResponse("not_found", "workspace no encontrado", { field: "workspace_ids" });

  const t = now();
  const inv: InvitationRow = {
    id: uuid(),
    email: (body.email as string).trim().normalize("NFC"),
    email_normalized: email,
    kind: "watcher",
    role: "watcher",
    created_by: owner.userId,
    created_at: t,
    expires_at: expiry(t, ttl),
    used_at: null,
    revoked_at: null,
  };
  const token = newToken("invitation");
  await batch(d, [
    d
      .prepare(
        "INSERT INTO invitations (id, token_hash, kind, email, email_normalized, role, created_by, created_at, expires_at) VALUES (?, ?, 'watcher', ?, ?, 'watcher', ?, ?, ?)",
      )
      .bind(inv.id, await sha256Hex(token), inv.email, email, owner.userId, t, inv.expires_at),
    ...workspaceIds.map((w) => d.prepare("INSERT INTO invitation_workspaces (invitation_id, workspace_id) VALUES (?, ?)").bind(inv.id, w)),
    auditStmt(d, {
      actorKind: "user",
      actorUserId: owner.userId,
      sessionId: owner.sessionId,
      action: "invitation.created",
      targetKind: "invitation",
      targetId: inv.id,
      result: "ok",
      status: 201,
    }),
  ]);
  return json({ invitation: publicInvitation(inv, workspaceIds, t), link: link(env, token) }, 201);
};

const reissue: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const body = await readBody(request, true);
  if (body instanceof Response) return body;
  const ttl = parseTtl(body.ttl_h);
  if (ttl instanceof Response) return ttl;
  const d = db(env);
  const inv = await one<InvitationRow>(d, `SELECT ${COLS} FROM invitations WHERE id = ? AND kind = 'watcher'`, params.id!);
  if (!inv) return errorResponse("not_found", "invitación no encontrada");
  if (inv.used_at !== null || inv.revoked_at !== null) return errorResponse("gone", "la invitación ya se usó o se revocó");
  const t = now();
  const token = newToken("invitation");
  const expiresAt = expiry(t, ttl);
  const [res] = await batch(d, [
    d
      .prepare("UPDATE invitations SET token_hash = ?, expires_at = ? WHERE id = ? AND used_at IS NULL AND revoked_at IS NULL")
      .bind(await sha256Hex(token), expiresAt, inv.id),
    auditStmt(
      d,
      {
        actorKind: "user",
        actorUserId: owner.userId,
        sessionId: owner.sessionId,
        action: "invitation.reissued",
        targetKind: "invitation",
        targetId: inv.id,
        result: "ok",
        status: 200,
      },
      { sql: "EXISTS (SELECT 1 FROM invitations WHERE id = ? AND expires_at = ? AND used_at IS NULL)", params: [inv.id, expiresAt] },
    ),
  ]);
  if (res?.meta.changes !== 1) return errorResponse("gone", "la invitación ya se usó o se revocó");
  const ws = await workspaceIdsOf(d, [inv.id]);
  return json({ invitation: publicInvitation({ ...inv, expires_at: expiresAt }, ws.get(inv.id) ?? [], t), link: link(env, token) });
};

const revoke: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const inv = await one<{ id: string }>(d, "SELECT id FROM invitations WHERE id = ? AND kind = 'watcher'", params.id!);
  if (!inv) return errorResponse("not_found", "invitación no encontrada");
  const t = now();
  await batch(d, [
    d.prepare("UPDATE invitations SET revoked_at = ? WHERE id = ? AND used_at IS NULL AND revoked_at IS NULL").bind(t, inv.id),
    auditStmt(
      d,
      {
        actorKind: "user",
        actorUserId: owner.userId,
        sessionId: owner.sessionId,
        action: "invitation.revoked",
        targetKind: "invitation",
        targetId: inv.id,
        result: "ok",
        status: 204,
      },
      { sql: "EXISTS (SELECT 1 FROM invitations WHERE id = ? AND revoked_at = ?)", params: [inv.id, t] },
    ),
  ]);
  return noContent();
};

const inspect: Handler<AuthEnv> = async (request, { env }) => {
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const d = db(env);
  const inv = await findByToken(request, d, body.token);
  if (inv instanceof Response) return inv;
  const workspaces = await all<{ id: string; name: string }>(
    d,
    `SELECT w.id, w.name FROM invitation_workspaces iw JOIN workspaces w ON w.id = iw.workspace_id
     WHERE iw.invitation_id = ? AND w.archived_at IS NULL ORDER BY w.position, w.name`,
    inv.id,
  );
  return json({ email: inv.email, kind: inv.kind, role: inv.role, expires_at: inv.expires_at, workspaces: workspaces.map((w) => ({ id: w.id, name: w.name })) });
};

function parseDisplayName(value: unknown): string | null | Response {
  if (value === undefined || value === null) return null;
  const name = typeof value === "string" ? value.trim().normalize("NFC") : "";
  if (name.length < 1 || [...name].length > 80) return errorResponse("bad_request", "display_name debe tener entre 1 y 80 caracteres", { field: "display_name" });
  return name;
}

const accept: Handler<AuthEnv> = async (request, { env }) => {
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const client = parseClient(body.client);
  if (client === null) return errorResponse("bad_request", "client debe ser mac, web o cli", { field: "client" });
  if (typeof body.device_name !== "string" || body.device_name.trim() === "") {
    return errorResponse("bad_request", "falta device_name", { field: "device_name" });
  }
  const displayName = parseDisplayName(body.display_name);
  if (displayName instanceof Response) return displayName;
  const pep = pepper(env);
  if (pep instanceof Response) return pep;
  const d = db(env);
  const inv = await findByToken(request, d, body.token);
  if (inv instanceof Response) return inv;

  const owner = await one<UserRow & { email_normalized: string }>(
    d,
    "SELECT id, email, email_normalized, display_name, role, status, created_at FROM users WHERE role = 'owner'",
  );
  if (inv.kind === "owner_bootstrap" && owner) return errorResponse("conflict", "ya existe un dueño");
  if (inv.kind === "owner_reset" && (!owner || owner.email_normalized !== inv.email_normalized)) {
    return errorResponse("gone", "la invitación ya no corresponde al dueño");
  }
  if (inv.kind === "watcher" && (await one(d, "SELECT id FROM users WHERE email_normalized = ?", inv.email_normalized))) {
    return errorResponse("conflict", "ya existe un usuario con ese correo");
  }
  const policy = passwordPolicyError(body.password, inv.email);
  if (policy) return policy;

  const t = now();
  const passwordHash = await hashPassword(body.password as string, pep);
  const recoveryCode = inv.kind === "watcher" ? null : generateRecoveryCode();
  const recoveryHash = recoveryCode === null ? null : await recoveryCodeHash(recoveryCode);
  const user: UserRow =
    inv.kind === "owner_reset"
      ? owner!
      : { id: uuid(), email: inv.email, display_name: displayName, role: inv.role, status: "active", created_at: t };
  const claimable = "EXISTS (SELECT 1 FROM invitations WHERE id = ? AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?)";
  const claimed = { sql: "EXISTS (SELECT 1 FROM invitations WHERE id = ? AND used_by = ? AND used_at = ?)", params: [inv.id, user.id, t] as SqlValue[] };
  const stmts: D1PreparedStatement[] = [];

  if (inv.kind === "owner_reset") {
    stmts.push(
      d
        .prepare(`UPDATE invitations SET used_at = ?, used_by = ? WHERE id = ? AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?`)
        .bind(t, user.id, inv.id, t),
      d
        .prepare(`UPDATE users SET password_hash = ?, password_changed_at = ?, recovery_hash = ?, updated_at = ? WHERE id = ? AND ${claimed.sql}`)
        .bind(passwordHash, t, recoveryHash, t, user.id, ...claimed.params),
      d
        .prepare(`UPDATE sessions SET revoked_at = ?, revoked_reason = 'recovered' WHERE user_id = ? AND revoked_at IS NULL AND ${claimed.sql}`)
        .bind(t, user.id, ...claimed.params),
    );
  } else {
    stmts.push(
      d
        .prepare(
          `INSERT INTO users (id, email, email_normalized, display_name, password_hash, role, recovery_hash, invited_by, password_changed_at, created_at, updated_at)
           SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE ${claimable}`,
        )
        .bind(user.id, inv.email, inv.email_normalized, displayName, passwordHash, inv.role, recoveryHash, inv.created_by, t, t, t, inv.id, t),
      d
        .prepare("UPDATE invitations SET used_at = ?, used_by = ? WHERE id = ? AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?")
        .bind(t, user.id, inv.id, t),
    );
    if (inv.kind === "owner_bootstrap") {
      const workspaceId = uuid();
      stmts.push(
        d
          .prepare(`INSERT INTO workspaces (id, owner_id, name, slug, created_at, updated_at) SELECT ?, ?, 'Personal', 'personal', ?, ? WHERE ${claimed.sql}`)
          .bind(workspaceId, user.id, t, t, ...claimed.params),
        d
          .prepare(`INSERT INTO campus_layouts (workspace_id, updated_at) SELECT ?, ? WHERE ${claimed.sql}`)
          .bind(workspaceId, t, ...claimed.params),
      );
    } else {
      stmts.push(
        d
          .prepare(
            `INSERT INTO workspace_members (workspace_id, user_id, role, added_by, created_at)
             SELECT iw.workspace_id, ?, 'watcher', ?, ? FROM invitation_workspaces iw JOIN workspaces w ON w.id = iw.workspace_id
             WHERE iw.invitation_id = ? AND w.archived_at IS NULL AND ${claimed.sql}`,
          )
          .bind(user.id, inv.created_by, t, inv.id, ...claimed.params),
      );
    }
  }
  const { session, stmt } = await newSessionStatement(d, user.id, client, body.device_name.trim(), request.headers.get("User-Agent"), claimed);
  stmts.push(
    stmt,
    d.prepare(`UPDATE users SET last_login_at = ? WHERE id = ? AND ${claimed.sql}`).bind(t, user.id, ...claimed.params),
    auditStmt(d, { actorKind: "user", actorUserId: user.id, sessionId: session.id, action: "invitation.accepted", targetKind: "invitation", targetId: inv.id, result: "ok", status: 201 }, claimed),
  );

  let results: D1Result[];
  try {
    results = await batch(d, stmts);
  } catch (err) {
    if (isConstraintError(err, "UNIQUE")) return errorResponse("conflict", "ya existe un usuario con ese correo o un dueño");
    throw err;
  }
  const claim = results[inv.kind === "owner_reset" ? 0 : 1];
  if (claim?.meta.changes !== 1) return errorResponse("gone", "la invitación ya se usó, se revocó o caducó");

  if (inv.kind === "owner_reset") {
    const revoked = await all<{ id: string }>(
      d,
      "SELECT id FROM sessions WHERE user_id = ? AND revoked_reason = 'recovered' AND revoked_at = ?",
      user.id,
      t,
    );
    await notifyHub(env, revoked.map((r) => r.id));
  }
  return sessionResponse(user, session, 201, recoveryCode === null ? {} : { recovery_code: recoveryCode });
};

export const invitationHandlers: Record<string, Handler<AuthEnv>> = {
  "invitations.list": list,
  "invitations.create": create,
  "invitations.reissue": reissue,
  "invitations.revoke": revoke,
  "invitations.inspect": inspect,
  "invitations.accept": accept,
};
