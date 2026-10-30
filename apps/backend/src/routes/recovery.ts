import {
  type Pepper,
  generateRecoveryCode,
  hashPassword,
  needsRehash,
  normalizeRecoveryCode,
  pepperFromEnv,
  sha256Hex,
  timingSafeEqual,
  verifyPassword,
} from "../crypto";
import { batch, now, one, uuid, type SqlValue } from "../db";
import { type HttpEnv, errorResponse, json, readJson } from "../http";
import { RATE_LIMITED_MESSAGE, limitKey, loginKeys, normalizeEmail, recordFailure, retryAfter } from "../ratelimit";
import type { Handler } from "../router";

export interface RecoveryEnv extends HttpEnv {
  DB?: D1Database;
  PASSWORD_PEPPER?: string;
  PASSWORD_PEPPER_VERSION?: string;
}

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const GENERIC_RECOVER = "correo o código de recuperación incorrectos";

interface OwnerRow {
  id: string;
  email_normalized: string;
  password_hash: string;
  recovery_hash: string | null;
}

export function database(env: RecoveryEnv): D1Database {
  if (!env.DB) throw new Error("DB no configurada");
  return env.DB;
}

export function clientIp(request: Request): string {
  return request.headers.get("CF-Connecting-IP") ?? "";
}

export function parseEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = normalizeEmail(raw);
  return email.length <= 254 && EMAIL_RE.test(email) ? email : null;
}

export function passwordPolicyError(password: unknown, emailNormalized: string): Response | null {
  const bad = (message: string) => errorResponse("bad_request", message, { field: "password" });
  if (typeof password !== "string") return bad("falta la contraseña");
  const p = password.normalize("NFC");
  const length = [...p].length;
  if (length < 12 || length > 256) return bad("la contraseña debe tener entre 12 y 256 caracteres");
  const lower = p.toLowerCase();
  const local = emailNormalized.split("@")[0] ?? "";
  if (lower === emailNormalized || (local.length >= 4 && lower.includes(local))) {
    return bad("la contraseña no puede ser ni contener tu correo");
  }
  return null;
}

export function pepperOf(env: RecoveryEnv): Pepper | Response {
  try {
    return pepperFromEnv(env as Record<string, unknown>);
  } catch {
    return errorResponse("internal", "contraseñas deshabilitadas", { status: 503 });
  }
}

export async function checkPassword(pepper: Pepper, password: string, stored: string): Promise<{ ok: boolean; rehash: string | null }> {
  const ok = await verifyPassword(password, stored, pepper);
  return { ok, rehash: ok && needsRehash(stored, pepper) ? await hashPassword(password, pepper) : null };
}

export function rateLimited(retryAfterS: number): Response {
  return errorResponse("rate_limited", RATE_LIMITED_MESSAGE, { retryAfterS });
}

export interface AuditInput {
  actorKind: "user" | "operator" | "system";
  actorUserId?: string | null;
  sessionId?: string | null;
  action: string;
  targetKind?: string | null;
  targetId?: string | null;
  result: "ok" | "denied" | "error";
  status: number;
}

export function auditStmt(db: D1Database, e: AuditInput, when: { sql: string; params: SqlValue[] } = { sql: "1", params: [] }): D1PreparedStatement {
  const values: SqlValue[] = [
    uuid(),
    now(),
    e.actorKind,
    e.actorUserId ?? null,
    e.sessionId ?? null,
    e.action,
    e.targetKind ?? null,
    e.targetId ?? null,
    e.result,
    e.status,
    ...when.params,
  ];
  return db
    .prepare(
      `INSERT INTO audit_log (id, at, actor_kind, actor_user_id, session_id, action, target_kind, target_id, result, status, detail) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}' WHERE ${when.sql}`,
    )
    .bind(...values);
}

function field(body: unknown, name: string): unknown {
  return body !== null && typeof body === "object" ? (body as Record<string, unknown>)[name] : undefined;
}

export const recover: Handler<RecoveryEnv> = async (request, { env }) => {
  const db = database(env);
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const email = parseEmail(field(body, "email"));
  if (email === null) return errorResponse("bad_request", "correo inválido", { field: "email" });
  const code = field(body, "recovery_code");
  if (typeof code !== "string") return errorResponse("bad_request", "falta el código de recuperación", { field: "recovery_code" });
  const password = field(body, "new_password");
  const pepper = pepperOf(env);
  if (pepper instanceof Response) return pepper;

  const ip = clientIp(request);
  const keys = await Promise.all([limitKey("rc", ip), limitKey("e", email), limitKey("ip", ip)]);
  const wait = await retryAfter(db, keys);
  if (wait > 0) return rateLimited(wait);

  const policy = passwordPolicyError(password, email);
  if (policy) return policy;

  const owner = await one<OwnerRow>(
    db,
    "SELECT id, email_normalized, password_hash, recovery_hash FROM users WHERE email_normalized = ? AND role = 'owner' AND status = 'active'",
    email,
  );
  const normalized = normalizeRecoveryCode(code);
  const given = normalized === null ? null : await sha256Hex(normalized);
  const matches = owner?.recovery_hash != null && given !== null && timingSafeEqual(given, owner.recovery_hash);

  const fail = async () => {
    await recordFailure(db, keys);
    return errorResponse("unauthorized", GENERIC_RECOVER);
  };
  if (!owner || !matches) return fail();

  const fresh = generateRecoveryCode();
  const freshHash = await sha256Hex(normalizeRecoveryCode(fresh)!);
  const passwordHash = await hashPassword(password as string, pepper);
  const t = now();
  const consumed = "EXISTS (SELECT 1 FROM users WHERE id = ? AND recovery_hash = ?)";
  const results = await batch(db, [
    db
      .prepare("UPDATE users SET password_hash = ?, password_changed_at = ?, recovery_hash = ?, updated_at = ? WHERE id = ? AND recovery_hash = ?")
      .bind(passwordHash, t, freshHash, t, owner.id, owner.recovery_hash),
    db
      .prepare(`UPDATE sessions SET revoked_at = ?, revoked_reason = 'recovered' WHERE user_id = ? AND revoked_at IS NULL AND ${consumed}`)
      .bind(t, owner.id, owner.id, freshHash),
    auditStmt(
      db,
      { actorKind: "user", actorUserId: owner.id, action: "auth.recovered", targetKind: "user", targetId: owner.id, result: "ok", status: 200 },
      { sql: consumed, params: [owner.id, freshHash] },
    ),
  ]);
  if (results[0]?.meta.changes !== 1) return fail();
  return json({ recovery_code: fresh });
};

export const recoveryCode: Handler<RecoveryEnv> = async (request, { env, principal }) => {
  if (principal.kind !== "user" || principal.role !== "owner") return errorResponse("forbidden", "solo el dueño puede regenerar el código");
  const db = database(env);
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const password = field(body, "password");
  if (typeof password !== "string") return errorResponse("bad_request", "falta la contraseña", { field: "password" });

  const user = await one<OwnerRow>(
    db,
    "SELECT id, email_normalized, password_hash, recovery_hash FROM users WHERE id = ? AND role = 'owner' AND status = 'active'",
    principal.userId,
  );
  if (!user) return errorResponse("unauthorized", "credencial ausente, inválida o revocada");

  const pepper = pepperOf(env);
  if (pepper instanceof Response) return pepper;

  const keys = await loginKeys(user.email_normalized, clientIp(request));
  const wait = await retryAfter(db, keys);
  if (wait > 0) return rateLimited(wait);

  const check = await checkPassword(pepper, password, user.password_hash);
  if (!check.ok) {
    await recordFailure(db, keys);
    return errorResponse("unauthorized", "contraseña incorrecta");
  }

  const fresh = generateRecoveryCode();
  const t = now();
  await batch(db, [
    db
      .prepare("UPDATE users SET recovery_hash = ?, password_hash = ?, updated_at = ? WHERE id = ?")
      .bind(await sha256Hex(normalizeRecoveryCode(fresh)!), check.rehash ?? user.password_hash, t, user.id),
    auditStmt(db, {
      actorKind: "user",
      actorUserId: user.id,
      sessionId: principal.sessionId,
      action: "auth.recovery_code",
      targetKind: "user",
      targetId: user.id,
      result: "ok",
      status: 200,
    }),
  ]);
  return json({ recovery_code: fresh });
};

export const recoveryHandlers = {
  "auth.recover": recover,
  "auth.recovery_code": recoveryCode,
};
