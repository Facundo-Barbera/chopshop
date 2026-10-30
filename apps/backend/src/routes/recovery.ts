import {
  generateRecoveryCode,
  hashPassword,
  needsRehash,
  normalizeRecoveryCode,
  sha256Hex,
  timingSafeEqual,
  verifyPassword,
} from "../crypto";
import { batch, now, one, run, uuid, type SqlValue } from "../db";
import { type HttpEnv, errorResponse, json, readJson } from "../http";
import type { Handler } from "../router";

export interface RecoveryEnv extends HttpEnv {
  DB?: D1Database;
}

export interface LimitRule {
  prefix: string;
  max: number;
  windowMs: number;
  lockMs: number;
}

const MIN = 60_000;
const HOUR = 60 * MIN;

export const LIMITS = {
  email: { prefix: "e:", max: 20, windowMs: HOUR, lockMs: 15 * MIN },
  ip: { prefix: "ip:", max: 100, windowMs: HOUR, lockMs: HOUR },
  recover: { prefix: "rc:", max: 5, windowMs: HOUR, lockMs: HOUR },
  operator: { prefix: "op:", max: 5, windowMs: 10 * MIN, lockMs: HOUR },
} as const satisfies Record<string, LimitRule>;

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const GENERIC_RECOVER = "correo o código de recuperación incorrectos";

interface AttemptRow {
  failures: number;
  window_start: string;
  locked_until: string | null;
}

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

export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = raw.trim().normalize("NFC").toLowerCase();
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

export async function checkPassword(_env: RecoveryEnv, password: string, stored: string): Promise<{ ok: boolean; rehash: string | null }> {
  const ok = await verifyPassword(password, stored);
  return { ok, rehash: ok && needsRehash(stored) ? await hashPassword(password) : null };
}

export async function newPasswordHash(_env: RecoveryEnv, password: string): Promise<string> {
  return hashPassword(password);
}

export async function limitKey(rule: LimitRule, value: string): Promise<string> {
  return rule.prefix + (await sha256Hex(value));
}

export async function lockedFor(db: D1Database, keys: string[], at = Date.now()): Promise<number> {
  let wait = 0;
  for (const key of keys) {
    const row = await one<AttemptRow>(db, "SELECT failures, window_start, locked_until FROM auth_attempts WHERE key_hash = ?", key);
    if (row?.locked_until) wait = Math.max(wait, Math.ceil((Date.parse(row.locked_until) - at) / 1000));
  }
  return wait;
}

export async function recordFailure(db: D1Database, rule: LimitRule, key: string, at = Date.now()): Promise<void> {
  const row = await one<AttemptRow>(db, "SELECT failures, window_start, locked_until FROM auth_attempts WHERE key_hash = ?", key);
  const fresh = !row || at - Date.parse(row.window_start) >= rule.windowMs;
  const failures = fresh ? 1 : row.failures + 1;
  const windowStart = fresh ? new Date(at).toISOString() : row.window_start;
  const lockedUntil = failures >= rule.max ? new Date(at + rule.lockMs).toISOString() : null;
  const t = new Date(at).toISOString();
  await run(
    db,
    "INSERT INTO auth_attempts (key_hash, failures, window_start, locked_until, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (key_hash) DO UPDATE SET failures = excluded.failures, window_start = excluded.window_start, locked_until = excluded.locked_until, updated_at = excluded.updated_at",
    key,
    failures,
    windowStart,
    lockedUntil,
    t,
  );
}

export function rateLimited(retryAfterS: number): Response {
  return errorResponse("rate_limited", "demasiados intentos; espera antes de reintentar", { retryAfterS });
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
  const email = normalizeEmail(field(body, "email"));
  if (email === null) return errorResponse("bad_request", "correo inválido", { field: "email" });
  const code = field(body, "recovery_code");
  if (typeof code !== "string") return errorResponse("bad_request", "falta el código de recuperación", { field: "recovery_code" });
  const password = field(body, "new_password");

  const ip = clientIp(request);
  const keys = {
    recover: await limitKey(LIMITS.recover, ip),
    email: await limitKey(LIMITS.email, email),
    ip: await limitKey(LIMITS.ip, ip),
  };
  const wait = await lockedFor(db, Object.values(keys));
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
    await recordFailure(db, LIMITS.recover, keys.recover);
    await recordFailure(db, LIMITS.email, keys.email);
    await recordFailure(db, LIMITS.ip, keys.ip);
    return errorResponse("unauthorized", GENERIC_RECOVER);
  };
  if (!owner || !matches) return fail();

  const fresh = generateRecoveryCode();
  const freshHash = await sha256Hex(normalizeRecoveryCode(fresh)!);
  const passwordHash = await newPasswordHash(env, password as string);
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

  const ip = clientIp(request);
  const keys = { email: await limitKey(LIMITS.email, user.email_normalized), ip: await limitKey(LIMITS.ip, ip) };
  const wait = await lockedFor(db, Object.values(keys));
  if (wait > 0) return rateLimited(wait);

  const check = await checkPassword(env, password, user.password_hash);
  if (!check.ok) {
    await recordFailure(db, LIMITS.email, keys.email);
    await recordFailure(db, LIMITS.ip, keys.ip);
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
