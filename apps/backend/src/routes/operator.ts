import { newToken, sha256Hex, timingSafeEqual } from "../crypto";
import { batch, now, one, uuid } from "../db";
import { type Principal, errorResponse, json, readJson, webOrigin } from "../http";
import type { Handler } from "../router";
import {
  LIMITS,
  type RecoveryEnv,
  auditStmt,
  clientIp,
  database,
  limitKey,
  lockedFor,
  normalizeEmail,
  rateLimited,
  recordFailure,
} from "./recovery";

export interface OperatorEnv extends RecoveryEnv {
  RELAY_OPERATOR_TOKEN?: string;
}

const BOOTSTRAP_TTL_MS = 24 * 3600_000;
const RESET_TTL_MS = 3600_000;

type OwnerKind = "owner_bootstrap" | "owner_reset";

export function isOperatorPath(pathname: string): boolean {
  return pathname.startsWith("/v1/operator/");
}

export async function operatorPrincipal(request: Request, env: OperatorEnv): Promise<Principal | Response> {
  const secret = env.RELAY_OPERATOR_TOKEN;
  if (!secret) return errorResponse("internal", "operador deshabilitado", { status: 503 });
  const db = database(env);
  const key = await limitKey(LIMITS.operator, clientIp(request));
  const wait = await lockedFor(db, [key]);
  if (wait > 0) return rateLimited(wait);
  const bearer = /^Bearer\s+(\S+)$/i.exec(request.headers.get("Authorization") ?? "")?.[1] ?? "";
  if (timingSafeEqual(await sha256Hex(bearer), await sha256Hex(secret))) return { kind: "operator" };
  await recordFailure(db, LIMITS.operator, key);
  return errorResponse("unauthorized", "credencial ausente, inválida o revocada");
}

async function issueOwnerInvitation(env: OperatorEnv, kind: OwnerKind, email: string, emailNormalized: string, ttlMs: number, action: string): Promise<Response> {
  const db = database(env);
  const id = uuid();
  const token = newToken("invitation");
  const t = now();
  const expiresAt = new Date(Date.parse(t) + ttlMs).toISOString();
  await batch(db, [
    db
      .prepare("UPDATE invitations SET revoked_at = ? WHERE kind = ? AND used_at IS NULL AND revoked_at IS NULL")
      .bind(t, kind),
    db
      .prepare(
        "INSERT INTO invitations (id, token_hash, kind, email, email_normalized, role, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, 'owner', NULL, ?, ?)",
      )
      .bind(id, await sha256Hex(token), kind, email, emailNormalized, t, expiresAt),
    auditStmt(db, { actorKind: "operator", action, targetKind: "invitation", targetId: id, result: "ok", status: 201 }),
  ]);
  return json({ invitation: { id, email, kind, expires_at: expiresAt }, link: `${webOrigin(env)}/invite#t=${token}` }, 201);
}

async function ownerConflict(db: D1Database, action: string, message: string): Promise<Response> {
  await auditStmt(db, { actorKind: "operator", action, result: "denied", status: 409 }).run();
  return errorResponse("conflict", message);
}

export const bootstrap: Handler<OperatorEnv> = async (request, { env }) => {
  const db = database(env);
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const raw = body !== null && typeof body === "object" ? (body as Record<string, unknown>).email : undefined;
  const emailNormalized = normalizeEmail(raw);
  if (emailNormalized === null) return errorResponse("bad_request", "correo inválido", { field: "email" });
  const owner = await one<{ id: string }>(db, "SELECT id FROM users WHERE role = 'owner'");
  if (owner) return ownerConflict(db, "operator.bootstrap", "ya existe un dueño");
  return issueOwnerInvitation(env, "owner_bootstrap", (raw as string).trim().normalize("NFC"), emailNormalized, BOOTSTRAP_TTL_MS, "operator.bootstrap");
};

export const recover: Handler<OperatorEnv> = async (_request, { env }) => {
  const db = database(env);
  const owner = await one<{ email: string; email_normalized: string }>(db, "SELECT email, email_normalized FROM users WHERE role = 'owner'");
  if (!owner) return ownerConflict(db, "operator.recover", "no hay dueño");
  return issueOwnerInvitation(env, "owner_reset", owner.email, owner.email_normalized, RESET_TTL_MS, "operator.recover");
};

export const operatorHandlers = {
  "operator.bootstrap": bootstrap,
  "operator.recover": recover,
};
