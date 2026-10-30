import { readdirSync, readFileSync } from "node:fs";
import { hashPassword, pepperFromEnv, sha256Hex } from "../src/crypto.ts";
import { applyMigrations, now, one, run, uuid } from "../src/db.ts";
import { type HttpEnv, type Principal, errorResponse, readCredential } from "../src/http.ts";
import { createApi } from "../src/router.ts";
import { isOperatorPath, operatorHandlers, operatorPrincipal } from "../src/routes/operator.ts";
import { recoveryHandlers } from "../src/routes/recovery.ts";
import { FakeD1Database } from "./d1.ts";

export const API = "https://api.chopshop.novarix.online";
export const OPERATOR_SECRET = "operador-secreto-de-prueba-0123456789";
export const PEPPER_SECRET = "pepper-de-prueba-0123456789abcdefghij";
export const PEPPER = pepperFromEnv({ PASSWORD_PEPPER: PEPPER_SECRET });

export interface TestEnv extends HttpEnv {
  DB: D1Database;
  RELAY_OPERATOR_TOKEN?: string;
  PASSWORD_PEPPER?: string;
}

const DIR = new URL("../migrations/", import.meta.url);

export async function freshEnv(): Promise<TestEnv> {
  const db = new FakeD1Database().asD1();
  const files = readdirSync(DIR).filter((f) => /^\d{4}_.+\.sql$/.test(f)).sort();
  await applyMigrations(db, files.map((f) => readFileSync(new URL(f, DIR), "utf8")));
  return { DB: db, RELAY_OPERATOR_TOKEN: OPERATOR_SECRET, PASSWORD_PEPPER: PEPPER_SECRET };
}

async function resolvePrincipal(request: Request, env: TestEnv): Promise<Principal | Response> {
  if (isOperatorPath(new URL(request.url).pathname)) return operatorPrincipal(request, env);
  const credential = readCredential(request);
  if (credential instanceof Response) return credential;
  if (credential.via === "none") return { kind: "anonymous" };
  const row = await one<{ id: string; user_id: string; role: "owner" | "watcher" }>(
    env.DB,
    "SELECT s.id, s.user_id, u.role FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ? AND s.revoked_at IS NULL AND u.status = 'active'",
    await sha256Hex(credential.token),
  );
  if (!row) return errorResponse("unauthorized", "credencial ausente, inválida o revocada");
  return { kind: "user", userId: row.user_id, role: row.role, sessionId: row.id, client: "mac", viaCookie: false };
}

const api = createApi<TestEnv>({ ...operatorHandlers, ...recoveryHandlers }, { resolvePrincipal });

export async function call(
  env: TestEnv,
  method: string,
  path: string,
  opts: { body?: unknown; auth?: string; ip?: string } = {},
): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": opts.ip ?? "203.0.113.7" };
  if (opts.auth !== undefined) headers.Authorization = opts.auth;
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  const body = opts.body === undefined ? null : JSON.stringify(opts.body);
  return api(new Request(`${API}${path}`, { method, headers, body }), env);
}

export async function addUser(
  env: TestEnv,
  email: string,
  role: "owner" | "watcher",
  opts: { password?: string; recoveryCode?: string } = {},
): Promise<string> {
  const id = uuid();
  const t = now();
  const recovery = opts.recoveryCode === undefined ? null : await sha256Hex(opts.recoveryCode);
  await run(
    env.DB,
    "INSERT INTO users (id, email, email_normalized, password_hash, role, recovery_hash, password_changed_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    id,
    email,
    email.toLowerCase(),
    await hashPassword(opts.password ?? "contraseña-inicial-larga", PEPPER),
    role,
    recovery,
    t,
    t,
    t,
  );
  return id;
}

export async function addSession(env: TestEnv, userId: string): Promise<{ id: string; token: string }> {
  const id = uuid();
  const token = `ss1_${crypto.randomUUID().replace(/-/g, "").padEnd(43, "a")}`;
  const t = now();
  const later = new Date(Date.now() + 86_400_000).toISOString();
  await run(
    env.DB,
    "INSERT INTO sessions (id, user_id, token_hash, client, created_at, last_seen_at, expires_at, absolute_expires_at) VALUES (?, ?, ?, 'mac', ?, ?, ?, ?)",
    id,
    userId,
    await sha256Hex(token),
    t,
    t,
    later,
    later,
  );
  return { id, token };
}

export async function row(env: TestEnv, sql: string, ...params: (string | number | null)[]): Promise<Record<string, unknown> | null> {
  const r = await one<Record<string, unknown>>(env.DB, sql, ...params);
  return r && { ...r };
}

export async function rows(env: TestEnv, sql: string, ...params: (string | number | null)[]): Promise<Record<string, unknown>[]> {
  const res = await env.DB.prepare(sql).bind(...params).all<Record<string, unknown>>();
  return res.results.map((r) => ({ ...r }));
}
