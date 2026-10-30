import { sha256Hex } from "./crypto";

export const AUTH_FAILED_MESSAGE = "correo o contraseña incorrectos";
export const RATE_LIMITED_MESSAGE = "demasiados intentos; vuelve a intentarlo más tarde";

export interface LimitRule {
  limit: number;
  windowS: number;
  lockS: (failures: number) => number;
}

export const LIMIT_RULES = {
  ei: { limit: 5, windowS: 15 * 60, lockS: (f: number) => Math.min(60 * 2 ** (f - 5), 60 * 60) },
  e: { limit: 20, windowS: 60 * 60, lockS: () => 15 * 60 },
  ip: { limit: 100, windowS: 60 * 60, lockS: () => 60 * 60 },
  rc: { limit: 5, windowS: 60 * 60, lockS: () => 60 * 60 },
  inv: { limit: 10, windowS: 60, lockS: () => 5 * 60 },
  op: { limit: 5, windowS: 10 * 60, lockS: () => 60 * 60 },
} as const satisfies Record<string, LimitRule>;

export type LimitKind = keyof typeof LIMIT_RULES;

export interface LimitKey {
  kind: LimitKind;
  hash: string;
}

export function normalizeEmail(email: string): string {
  return email.trim().normalize("NFC").toLowerCase();
}

export async function limitKey(kind: LimitKind, ...parts: string[]): Promise<LimitKey> {
  return { kind, hash: `${kind}:${await sha256Hex(parts.join("|"))}` };
}

export async function loginKeys(email: string, ip: string): Promise<LimitKey[]> {
  const e = normalizeEmail(email);
  return Promise.all([limitKey("ei", e, ip), limitKey("e", e), limitKey("ip", ip)]);
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

export async function retryAfter(db: D1Database, keys: LimitKey[], nowMs = Date.now()): Promise<number> {
  if (keys.length === 0) return 0;
  const marks = keys.map(() => "?").join(", ");
  const row = await db
    .prepare(`SELECT MAX(locked_until) AS until FROM auth_attempts WHERE key_hash IN (${marks}) AND locked_until > ?`)
    .bind(...keys.map((k) => k.hash), iso(nowMs))
    .first<{ until: string | null }>();
  if (!row?.until) return 0;
  return Math.max(1, Math.ceil((Date.parse(row.until) - nowMs) / 1000));
}

export async function recordFailure(db: D1Database, keys: LimitKey[], nowMs = Date.now()): Promise<number> {
  const now = iso(nowMs);
  for (const key of keys) {
    const rule: LimitRule = LIMIT_RULES[key.kind];
    const cutoff = iso(nowMs - rule.windowS * 1000);
    const row = await db
      .prepare(
        `INSERT INTO auth_attempts (key_hash, failures, window_start, locked_until, updated_at) VALUES (?1, 1, ?2, NULL, ?2)
         ON CONFLICT (key_hash) DO UPDATE SET
           failures = CASE WHEN MAX(updated_at, COALESCE(locked_until, '')) <= ?3 THEN 1 ELSE failures + 1 END,
           window_start = CASE WHEN MAX(updated_at, COALESCE(locked_until, '')) <= ?3 THEN ?2 ELSE window_start END,
           locked_until = CASE WHEN MAX(updated_at, COALESCE(locked_until, '')) <= ?3 THEN NULL ELSE locked_until END,
           updated_at = ?2
         RETURNING failures`,
      )
      .bind(key.hash, now, cutoff)
      .first<{ failures: number }>();
    const failures = row?.failures ?? 1;
    if (failures >= rule.limit) {
      await db
        .prepare("UPDATE auth_attempts SET locked_until = ? WHERE key_hash = ?")
        .bind(iso(nowMs + rule.lockS(failures) * 1000), key.hash)
        .run();
    }
  }
  return retryAfter(db, keys, nowMs);
}

export async function clearLimit(db: D1Database, key: LimitKey): Promise<void> {
  await db.prepare("DELETE FROM auth_attempts WHERE key_hash = ?").bind(key.hash).run();
}

export async function purgeAttempts(db: D1Database, nowMs = Date.now()): Promise<number> {
  const cutoff = iso(nowMs - 24 * 60 * 60 * 1000);
  const res = await db
    .prepare("DELETE FROM auth_attempts WHERE updated_at < ?1 AND (locked_until IS NULL OR locked_until < ?1)")
    .bind(cutoff)
    .run();
  return res.meta.changes;
}

export function rateLimitedBody(retryAfterS: number): { code: "rate_limited"; message: string; retry_after_s: number } {
  return { code: "rate_limited", message: RATE_LIMITED_MESSAGE, retry_after_s: retryAfterS };
}

export function authFailedBody(): { code: "unauthorized"; message: string } {
  return { code: "unauthorized", message: AUTH_FAILED_MESSAGE };
}
