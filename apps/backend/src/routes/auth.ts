import { audit } from "../audit";
import {
  type AuthEnv,
  type UserRow,
  clientIp,
  db,
  parseClient,
  passwordPolicyError,
  pepper,
  publicUser,
  requireUser,
  revokeSession,
  revokeUserSessions,
  newSessionStatement,
  sessionResponse,
  validEmail,
} from "../auth";
import { DUMMY_PASSWORD_HASH, hashPassword, needsRehash, newToken, sha256Hex, verifyPassword } from "../crypto";
import { now } from "../db";
import { errorResponse, json, noContent, readJson, sessionCookie } from "../http";
import { AUTH_FAILED_MESSAGE, RATE_LIMITED_MESSAGE, type LimitKey, clearLimit, limitKey, loginKeys, normalizeEmail, recordFailure, retryAfter } from "../ratelimit";
import type { Handler } from "../router";

type Body = Record<string, unknown>;

interface CredRow extends UserRow {
  password_hash: string;
}

const USER_COLS = "id, email, display_name, role, status, created_at, password_hash";

async function readBody(request: Request): Promise<Body | Response> {
  const body = await readJson(request);
  if (body instanceof Response) return body;
  if (typeof body !== "object" || body === null || Array.isArray(body)) return errorResponse("bad_request", "se esperaba un objeto JSON");
  return body as Body;
}

function rateLimited(retryAfterS: number): Response {
  return errorResponse("rate_limited", RATE_LIMITED_MESSAGE, { retryAfterS });
}

async function failed(d: D1Database, keys: LimitKey[]): Promise<Response> {
  const wait = await recordFailure(d, keys);
  return wait > 0 ? rateLimited(wait) : errorResponse("unauthorized", AUTH_FAILED_MESSAGE);
}

const login: Handler<AuthEnv> = async (request, { env }) => {
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const email = validEmail(body.email);
  if (email === null) return errorResponse("bad_request", "correo no válido", { field: "email" });
  if (typeof body.password !== "string") return errorResponse("bad_request", "falta la contraseña", { field: "password" });
  const client = parseClient(body.client);
  if (client === null) return errorResponse("bad_request", "client debe ser mac, web o cli", { field: "client" });
  if (typeof body.device_name !== "string" || body.device_name.trim() === "") {
    return errorResponse("bad_request", "falta device_name", { field: "device_name" });
  }
  const pep = pepper(env);
  if (pep instanceof Response) return pep;
  const d = db(env);
  const keys = await loginKeys(email, clientIp(request));
  const wait = await retryAfter(d, keys);
  if (wait > 0) return rateLimited(wait);

  const user = await d.prepare(`SELECT ${USER_COLS} FROM users WHERE email_normalized = ?`).bind(email).first<CredRow>();
  const ok = await verifyPassword(body.password, user?.password_hash ?? DUMMY_PASSWORD_HASH, pep);
  if (!user || !ok || user.status !== "active") {
    await audit(d, { actorKind: "user", actorUserId: user?.id ?? null, action: "auth.login_failed", result: "denied", status: 401 });
    return failed(d, keys);
  }

  await clearLimit(d, keys[0]!);
  const t = now();
  const { session, stmt } = await newSessionStatement(d, user.id, client, body.device_name.trim(), request.headers.get("User-Agent"));
  const stmts = [stmt, d.prepare("UPDATE users SET last_login_at = ? WHERE id = ?").bind(t, user.id)];
  if (needsRehash(user.password_hash, pep)) {
    stmts.push(d.prepare("UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?").bind(await hashPassword(body.password, pep), t, user.id));
  }
  await d.batch(stmts);
  await audit(d, { actorKind: "user", actorUserId: user.id, sessionId: session.id, action: "auth.login", status: 200, detail: { client } });
  return sessionResponse(user, session);
};

const logout: Handler<AuthEnv> = async (_request, { env, principal }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  await revokeSession(env, p.sessionId, "logout");
  await audit(db(env), { actorKind: "user", actorUserId: p.userId, sessionId: p.sessionId, action: "auth.logout", status: 204 });
  return noContent(p.viaCookie ? { "Set-Cookie": sessionCookie("", 0) } : {});
};

const me: Handler<AuthEnv> = async (_request, { env, principal }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const d = db(env);
  const user = await d.prepare(`SELECT ${USER_COLS} FROM users WHERE id = ?`).bind(p.userId).first<CredRow>();
  const session = await d.prepare("SELECT id, client, expires_at FROM sessions WHERE id = ?").bind(p.sessionId).first<Body>();
  if (!user || !session) return errorResponse("unauthorized", "credencial ausente, inválida o revocada");
  const out: Body = { user: publicUser(user), session };
  if (p.client === "web") {
    const csrf = newToken("csrf");
    await d.prepare("UPDATE sessions SET csrf_hash = ? WHERE id = ?").bind(await sha256Hex(csrf), p.sessionId).run();
    out.csrf_token = csrf;
  }
  return json(out);
};

const password: Handler<AuthEnv> = async (request, { env, principal }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const body = await readBody(request);
  if (body instanceof Response) return body;
  if (typeof body.current_password !== "string") return errorResponse("bad_request", "falta la contraseña actual", { field: "current_password" });
  const pep = pepper(env);
  if (pep instanceof Response) return pep;
  const d = db(env);
  const user = await d.prepare(`SELECT ${USER_COLS} FROM users WHERE id = ?`).bind(p.userId).first<CredRow>();
  if (!user) return errorResponse("unauthorized", "credencial ausente, inválida o revocada");
  const policy = passwordPolicyError(body.new_password, user.email);
  if (policy) return policy;
  const keys = [await limitKey("ei", normalizeEmail(user.email), clientIp(request))];
  const wait = await retryAfter(d, keys);
  if (wait > 0) return rateLimited(wait);
  if (!(await verifyPassword(body.current_password, user.password_hash, pep))) {
    await audit(d, { actorKind: "user", actorUserId: p.userId, sessionId: p.sessionId, action: "auth.password_changed", result: "denied", status: 401 });
    return failed(d, keys);
  }
  await clearLimit(d, keys[0]!);
  const t = now();
  await d
    .prepare("UPDATE users SET password_hash = ?, password_changed_at = ?, updated_at = ? WHERE id = ?")
    .bind(await hashPassword(body.new_password as string, pep), t, t, p.userId)
    .run();
  const revoked = await revokeUserSessions(env, p.userId, "password_changed", p.sessionId);
  await audit(d, {
    actorKind: "user",
    actorUserId: p.userId,
    sessionId: p.sessionId,
    action: "auth.password_changed",
    status: 204,
    detail: { sessions_revoked: revoked.length },
  });
  return noContent();
};

export const authHandlers: Record<string, Handler<AuthEnv>> = {
  "auth.login": login,
  "auth.logout": logout,
  "auth.me": me,
  "auth.password": password,
};
