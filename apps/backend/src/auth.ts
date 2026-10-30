import { type Pepper, isToken, newToken, pepperFromEnv, sha256Hex, timingSafeEqual } from "./crypto";
import { now, uuid } from "./db";
import { type HttpEnv, type Principal, errorResponse, json, readCredential, sessionCookie } from "./http";
import { normalizeEmail } from "./ratelimit";

export type Client = "mac" | "web" | "cli";

export interface HubRpc {
  sessionRevoked(sessionId: string): Promise<void>;
}

export interface AuthEnv extends HttpEnv {
  DB?: D1Database;
  HUB?: { idFromName(name: string): DurableObjectId; get(id: DurableObjectId): HubRpc };
  RELAY_OPERATOR_TOKEN?: string;
  PASSWORD_PEPPER?: string;
  PASSWORD_PEPPER_VERSION?: string;
}

export interface OwnerCtx {
  userId: string;
  role: "owner";
  sessionId: string;
}

export type UserPrincipal = Extract<Principal, { kind: "user" }>;

export const CLIENTS: readonly Client[] = ["mac", "web", "cli"];
export const SLIDE_AFTER_MS = 5 * 60 * 1000;
const DAY = 24 * 60 * 60 * 1000;
export const SESSION_TTL: Record<Client, { idleMs: number; absoluteMs: number }> = {
  mac: { idleMs: 30 * DAY, absoluteMs: 90 * DAY },
  cli: { idleMs: 30 * DAY, absoluteMs: 90 * DAY },
  web: { idleMs: 12 * 60 * 60 * 1000, absoluteMs: 7 * DAY },
};

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const INVALID_CREDENTIAL = "credencial ausente, inválida o revocada";

export interface UserRow {
  id: string;
  email: string;
  display_name: string | null;
  role: "owner" | "watcher";
  status: "active" | "disabled";
  created_at: string;
}

export function publicUser(u: UserRow): Record<string, unknown> {
  return { id: u.id, email: u.email, display_name: u.display_name, role: u.role, status: u.status, created_at: u.created_at };
}

export function db(env: AuthEnv): D1Database {
  if (!env.DB) throw new Error("DB no configurada");
  return env.DB;
}

export function pepper(env: AuthEnv): Pepper | Response {
  try {
    return pepperFromEnv(env as unknown as Record<string, unknown>);
  } catch {
    return errorResponse("internal", "contraseñas deshabilitadas", { status: 503 });
  }
}

export function clientIp(request: Request): string {
  return request.headers.get("CF-Connecting-IP") ?? "unknown";
}

export function validEmail(email: unknown): string | null {
  if (typeof email !== "string") return null;
  const n = normalizeEmail(email);
  return n.length <= 254 && EMAIL_RE.test(n) ? n : null;
}

export function passwordPolicyError(password: unknown, email: string): Response | null {
  const bad = (message: string) => errorResponse("bad_request", message, { field: "password" });
  if (typeof password !== "string") return bad("falta la contraseña");
  const p = password.normalize("NFC");
  const len = [...p].length;
  if (len < 12 || len > 256) return bad("la contraseña debe tener entre 12 y 256 caracteres");
  const lower = p.toLowerCase();
  const e = normalizeEmail(email);
  const local = e.split("@")[0] ?? "";
  if (lower === e || (local.length >= 4 && lower.includes(local))) return bad("la contraseña no puede contener el correo");
  return null;
}

export function requireOwner(p: Principal): OwnerCtx | Response {
  if (p.kind !== "user") return errorResponse("unauthorized", "esta ruta requiere una credencial válida");
  if (p.role !== "owner") return errorResponse("forbidden", "no tienes permiso para esta operación");
  return { userId: p.userId, role: "owner", sessionId: p.sessionId };
}

export function requireUser(p: Principal): UserPrincipal | Response {
  return p.kind === "user" ? p : errorResponse("unauthorized", "esta ruta requiere una credencial válida");
}

interface SessionLookup {
  id: string;
  user_id: string;
  client: Client;
  last_seen_at: string;
  expires_at: string;
  absolute_expires_at: string;
  revoked_at: string | null;
  role: "owner" | "watcher";
  status: "active" | "disabled";
}

async function resolveSession(env: AuthEnv, token: string, viaCookie: boolean): Promise<Principal | null> {
  const d = db(env);
  const s = await d
    .prepare(
      `SELECT s.id, s.user_id, s.client, s.last_seen_at, s.expires_at, s.absolute_expires_at, s.revoked_at, u.role, u.status
       FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?`,
    )
    .bind(await sha256Hex(token))
    .first<SessionLookup>();
  if (!s || s.revoked_at !== null || s.status !== "active") return null;
  if (viaCookie && s.client !== "web") return null;
  const t = Date.now();
  const stamp = new Date(t).toISOString();
  if (stamp >= s.expires_at || stamp >= s.absolute_expires_at) return null;
  if (t - Date.parse(s.last_seen_at) >= SLIDE_AFTER_MS) {
    const idle = new Date(t + SESSION_TTL[s.client].idleMs).toISOString();
    const expires = idle < s.absolute_expires_at ? idle : s.absolute_expires_at;
    await d.prepare("UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE id = ? AND revoked_at IS NULL").bind(stamp, expires, s.id).run();
  }
  return { kind: "user", userId: s.user_id, role: s.role, sessionId: s.id, client: s.client, viaCookie };
}

async function isOperator(env: AuthEnv, token: string): Promise<boolean> {
  const secret = env.RELAY_OPERATOR_TOKEN;
  if (typeof secret !== "string" || secret === "") return false;
  return timingSafeEqual(await sha256Hex(token), await sha256Hex(secret));
}

export async function resolvePrincipal(request: Request, env: AuthEnv): Promise<Principal | Response> {
  const credential = readCredential(request);
  if (credential instanceof Response) return credential;
  if (credential.via === "none") return { kind: "anonymous" };
  const denied = () => errorResponse("unauthorized", INVALID_CREDENTIAL);
  const { token } = credential;
  if (isToken("session", token)) return (await resolveSession(env, token, credential.via === "cookie")) ?? denied();
  if (credential.via === "cookie") return denied();
  if (isToken("machine", token)) {
    const m = await db(env)
      .prepare("SELECT id, local_machine_id, paused_at FROM machines WHERE credential_hash = ? AND revoked_at IS NULL")
      .bind(await sha256Hex(token))
      .first<{ id: string; local_machine_id: string | null; paused_at: string | null }>();
    return m ? { kind: "machine", machineId: m.id, localMachineId: m.local_machine_id, paused: m.paused_at !== null } : denied();
  }
  if (await isOperator(env, token)) return { kind: "operator" };
  return denied();
}

export async function csrfHash(env: AuthEnv, sessionId: string): Promise<string | null> {
  return db(env).prepare("SELECT csrf_hash FROM sessions WHERE id = ?").bind(sessionId).first<string | null>("csrf_hash");
}

export interface NewSession {
  id: string;
  token: string;
  csrfToken: string | null;
  client: Client;
  expiresAt: string;
  absoluteExpiresAt: string;
}

export async function newSessionStatement(
  d: D1Database,
  userId: string,
  client: Client,
  deviceName: string | null,
  userAgent: string | null,
): Promise<{ session: NewSession; stmt: D1PreparedStatement }> {
  const t = Date.now();
  const stamp = new Date(t).toISOString();
  const ttl = SESSION_TTL[client];
  const session: NewSession = {
    id: uuid(),
    token: newToken("session"),
    csrfToken: client === "web" ? newToken("csrf") : null,
    client,
    expiresAt: new Date(t + ttl.idleMs).toISOString(),
    absoluteExpiresAt: new Date(t + ttl.absoluteMs).toISOString(),
  };
  const stmt = d
    .prepare(
      `INSERT INTO sessions (id, user_id, token_hash, csrf_hash, client, device_name, user_agent, created_at, last_seen_at, expires_at, absolute_expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      session.id,
      userId,
      await sha256Hex(session.token),
      session.csrfToken === null ? null : await sha256Hex(session.csrfToken),
      client,
      deviceName === null ? null : deviceName.slice(0, 64),
      userAgent === null ? null : userAgent.slice(0, 200),
      stamp,
      stamp,
      session.expiresAt,
      session.absoluteExpiresAt,
    );
  return { session, stmt };
}

export function sessionResponse(user: UserRow, session: NewSession, status = 200, extra: Record<string, unknown> = {}): Response {
  const body: Record<string, unknown> = {
    user: publicUser(user),
    session: { id: session.id, client: session.client, expires_at: session.expiresAt },
    ...extra,
  };
  if (session.csrfToken === null) return json({ ...body, token: session.token }, status);
  const maxAge = Math.round((Date.parse(session.absoluteExpiresAt) - Date.now()) / 1000);
  return json({ ...body, csrf_token: session.csrfToken }, status, { "Set-Cookie": sessionCookie(session.token, maxAge) });
}

export type RevokedReason = "logout" | "revoked" | "password_changed" | "user_disabled" | "recovered";

async function notifyHub(env: AuthEnv, sessionIds: string[]): Promise<void> {
  if (!env.HUB || sessionIds.length === 0) return;
  const hub = env.HUB.get(env.HUB.idFromName("owner"));
  for (const id of sessionIds) {
    try {
      await hub.sessionRevoked(id);
    } catch (err) {
      console.error(JSON.stringify({ code: "hub_session_revoked", error: err instanceof Error ? err.name : "unknown" }));
    }
  }
}

export async function revokeSession(env: AuthEnv, sessionId: string, reason: RevokedReason): Promise<boolean> {
  const res = await db(env)
    .prepare("UPDATE sessions SET revoked_at = ?, revoked_reason = ? WHERE id = ? AND revoked_at IS NULL")
    .bind(now(), reason, sessionId)
    .run();
  if (res.meta.changes === 0) return false;
  await notifyHub(env, [sessionId]);
  return true;
}

export async function revokeUserSessions(env: AuthEnv, userId: string, reason: RevokedReason, exceptSessionId: string | null = null): Promise<string[]> {
  const d = db(env);
  const rows = await d
    .prepare("SELECT id FROM sessions WHERE user_id = ? AND revoked_at IS NULL AND id IS NOT ?")
    .bind(userId, exceptSessionId)
    .all<{ id: string }>();
  const ids = rows.results.map((r) => r.id);
  if (ids.length === 0) return ids;
  const t = now();
  await d.batch(ids.map((id) => d.prepare("UPDATE sessions SET revoked_at = ?, revoked_reason = ? WHERE id = ? AND revoked_at IS NULL").bind(t, reason, id)));
  await notifyHub(env, ids);
  return ids;
}

export function parseClient(value: unknown): Client | null {
  return typeof value === "string" && (CLIENTS as readonly string[]).includes(value) ? (value as Client) : null;
}
