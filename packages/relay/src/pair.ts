import { type RelayDb, type Scope, randomId, sha256Hex } from "./db";

export const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const CODE_LEN = 8;
export const DEFAULT_TTL_S = 600;
export const MAX_TTL_S = 3600;
export const IP_FAILS = 5;
export const IP_WINDOW_MS = 60_000;
export const CODE_FAILS = 20;
const KEEP_CODES_MS = 7 * 86_400_000;
const MAX_BODY = 4096;
const MACHINE_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
const ACCOUNT_RE = /^ac-[0-9a-f]{8}$/;
const TOKEN_ID_RE = /^tk-[0-9a-f]{8}$/;
const CODE_ID_RE = /^rc-[0-9a-f]{8}$/;

type ErrorCode =
  | "bad_request"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "gone"
  | "too_large"
  | "rate_limited";

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  gone: 410,
  too_large: 413,
  rate_limited: 429,
};

class PairError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly retryAfterS?: number,
  ) {
    super(message);
  }
}

function ulid(now: number): string {
  let time = "";
  let t = now;
  for (let i = 0; i < 10; i++) {
    time = ALPHABET[t % 32]! + time;
    t = Math.floor(t / 32);
  }
  let rand = "";
  for (const b of crypto.getRandomValues(new Uint8Array(16))) rand += ALPHABET[b & 31]!;
  return time + rand;
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function errorResponse(err: PairError, now: number): Response {
  const body: Record<string, unknown> = {
    v: 1,
    type: "error",
    id: ulid(now),
    ts: iso(now),
    re: null,
    code: err.code,
    message: err.message,
  };
  const headers: Record<string, string> = {};
  if (err.retryAfterS !== undefined) {
    body.retry_after_s = err.retryAfterS;
    headers["Retry-After"] = String(err.retryAfterS);
  }
  return Response.json(body, { status: STATUS[err.code], headers });
}

export function normalizeCode(code: unknown): string | null {
  if (typeof code !== "string") return null;
  const s = code.replace(/[\s-]/g, "").toUpperCase().replace(/O/g, "0").replace(/[IL]/g, "1");
  if (s.length !== CODE_LEN) return null;
  for (const c of s) if (!ALPHABET.includes(c)) return null;
  return s;
}

function generateCode(): string {
  let s = "";
  for (const b of crypto.getRandomValues(new Uint8Array(CODE_LEN))) s += ALPHABET[b & 31]!;
  return s;
}

export function timingSafeEqual(a: string, b: string): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return diff === 0;
}

function validName(v: unknown): v is string | null | undefined {
  return v === undefined || v === null || (typeof v === "string" && v.length <= 128 && !/[\u0000-\u001f]/.test(v));
}

function onlyKeys(body: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(body).every((k) => keys.includes(k));
}

async function readJson(request: Request): Promise<Record<string, unknown>> {
  const text = await request.text();
  if (text.length > MAX_BODY) throw new PairError("too_large", "cuerpo demasiado grande");
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new PairError("bad_request", "el cuerpo debe ser JSON");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new PairError("bad_request", "el cuerpo debe ser un objeto JSON");
  }
  return body as Record<string, unknown>;
}

type CodeRow = {
  id: string;
  account: string;
  scope: string;
  name: string | null;
  salt: string;
  hash: string;
  expires_at: number;
  used_at: number | null;
  invalidated_at: number | null;
};

type Caller = { operator: true } | { operator: false; account: string };

export class Pairing {
  constructor(
    private readonly sql: SqlStorage,
    private readonly storage: DurableObjectStorage,
    private readonly db: RelayDb,
    private readonly operatorToken: string | undefined,
  ) {}

  async handle(request: Request, path: string): Promise<Response | null> {
    const now = Date.now();
    try {
      if (path === "/v1/pair") {
        if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return Response.json(await this.redeem(request, now));
      }
      if (path === "/v1/pair/codes") {
        if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return Response.json(await this.createCode(request, now));
      }
      if (path.startsWith("/v1/tokens/") || path.startsWith("/v1/pair/codes/")) {
        if (request.method !== "DELETE") return new Response("Method Not Allowed", { status: 405 });
        await this.revoke(request, path, now);
        return new Response(null, { status: 204 });
      }
    } catch (err) {
      if (err instanceof PairError) return errorResponse(err, now);
      throw err;
    }
    return null;
  }

  private async caller(request: Request, now: number): Promise<Caller> {
    const auth = request.headers.get("Authorization") ?? "";
    const m = /^Bearer\s+(\S+)$/.exec(auth);
    if (!m) throw new PairError("unauthorized", "falta Authorization: Bearer");
    const bearer = m[1]!;
    if (this.operatorToken && timingSafeEqual(await sha256Hex(bearer), await sha256Hex(this.operatorToken))) {
      return { operator: true };
    }
    const rec = await this.db.verifyToken(bearer, now);
    if (!rec) throw new PairError("unauthorized", "token inválido o revocado");
    if (rec.scope !== "agent") throw new PairError("forbidden", "solo un token agent o el operador puede hacer esto");
    return { operator: false, account: rec.account };
  }

  private async createCode(request: Request, now: number): Promise<unknown> {
    const caller = await this.caller(request, now);
    const body = await readJson(request);
    if (!onlyKeys(body, ["scope", "name", "ttl_s"])) throw new PairError("bad_request", "campos desconocidos");
    const scope = body.scope;
    if (scope !== "agent" && scope !== "viewer") throw new PairError("bad_request", "scope debe ser agent o viewer");
    if (!validName(body.name)) throw new PairError("bad_request", "name inválido (máx. 128 caracteres, sin controles)");
    const ttl = body.ttl_s ?? DEFAULT_TTL_S;
    if (typeof ttl !== "number" || !Number.isInteger(ttl) || ttl < 1 || ttl > MAX_TTL_S) {
      throw new PairError("bad_request", "ttl_s fuera de rango (1 a 3600)");
    }
    let account: string;
    if (caller.operator) {
      const requested = new URL(request.url).searchParams.get("account");
      if (requested !== null && !ACCOUNT_RE.test(requested)) throw new PairError("bad_request", "account inválida");
      account = requested ?? randomId("ac");
    } else {
      account = caller.account;
    }
    const code = generateCode();
    const salt = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
    const hash = await sha256Hex(`${salt}:${code}`);
    const id = randomId("rc");
    const name = body.name ?? null;
    const expiresAt = now + ttl * 1000;
    this.sql.exec(
      "INSERT INTO pair_codes (id, account, scope, name, salt, hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      id,
      account,
      scope,
      name,
      salt,
      hash,
      now,
      expiresAt,
    );
    return { id, code: `${code.slice(0, 4)}-${code.slice(4)}`, scope, name, expires_at: iso(expiresAt) };
  }

  private ipKey(request: Request): string {
    return `ip:${request.headers.get("CF-Connecting-IP") ?? ""}`;
  }

  private checkIp(key: string, now: number): void {
    this.sql.exec("DELETE FROM attempts WHERE at <= ?", now - IP_WINDOW_MS);
    const rows = this.sql
      .exec<{ n: number; first: number | null }>("SELECT COUNT(*) AS n, MIN(at) AS first FROM attempts WHERE key = ?", key)
      .toArray();
    const row = rows[0];
    if (row && row.n >= IP_FAILS) {
      const wait = Math.max(1, Math.ceil(((row.first ?? now) + IP_WINDOW_MS - now) / 1000));
      throw new PairError("rate_limited", "demasiados intentos: espera un minuto", wait);
    }
  }

  private fail(key: string, now: number): void {
    this.storage.transactionSync(() => {
      this.sql.exec("INSERT INTO attempts (key, at) VALUES (?, ?)", key, now);
      this.sql.exec(
        "UPDATE pair_codes SET failures = failures + 1 WHERE used_at IS NULL AND invalidated_at IS NULL AND expires_at > ?",
        now,
      );
      this.sql.exec(
        "UPDATE pair_codes SET invalidated_at = ? WHERE used_at IS NULL AND invalidated_at IS NULL AND failures >= ?",
        now,
        CODE_FAILS,
      );
    });
  }

  private async redeem(request: Request, now: number): Promise<unknown> {
    const key = this.ipKey(request);
    this.checkIp(key, now);
    const body = await readJson(request);
    if (!onlyKeys(body, ["code", "client_name", "machine_id"])) throw new PairError("bad_request", "campos desconocidos");
    if (!validName(body.client_name)) throw new PairError("bad_request", "client_name inválido (máx. 128 caracteres, sin controles)");
    const machineId = body.machine_id;
    if (machineId !== undefined && (typeof machineId !== "string" || !MACHINE_RE.test(machineId))) {
      throw new PairError("bad_request", "machine_id tiene caracteres no permitidos");
    }
    const canon = normalizeCode(body.code);
    this.sql.exec(
      "DELETE FROM pair_codes WHERE MAX(COALESCE(used_at, 0), COALESCE(invalidated_at, 0), expires_at) < ?",
      now - KEEP_CODES_MS,
    );
    const rows = this.sql
      .exec<CodeRow>("SELECT id, account, scope, name, salt, hash, expires_at, used_at, invalidated_at FROM pair_codes")
      .toArray();
    let hit: CodeRow | null = null;
    for (const r of rows) {
      const ok = timingSafeEqual(await sha256Hex(`${r.salt}:${canon ?? "-"}`), r.hash);
      if (ok && canon !== null) hit = r;
    }
    if (hit !== null && hit.used_at === null && hit.invalidated_at === null && hit.expires_at > now) {
      const scope = hit.scope as Scope;
      if (scope === "agent" && machineId === undefined) {
        throw new PairError("bad_request", "machine_id es obligatorio para un código agent");
      }
      const claimed =
        this.sql.exec(
          "UPDATE pair_codes SET used_at = ? WHERE id = ? AND used_at IS NULL AND invalidated_at IS NULL",
          now,
          hit.id,
        ).rowsWritten > 0;
      if (claimed) {
        const issued = await this.db.issueToken({
          scope,
          account: hit.account,
          name: (body.client_name as string | null | undefined) ?? hit.name,
          machineId: scope === "agent" ? (machineId as string) : null,
          now,
        });
        return {
          token_id: issued.tokenId,
          token: issued.token,
          scope: issued.scope,
          machine_id: issued.machineId,
          protocol: 1,
        };
      }
    }
    this.fail(key, now);
    if (hit !== null) throw new PairError("gone", "el código ya se usó, caducó o fue invalidado: crea otro");
    throw new PairError("unauthorized", "código de pairing inválido");
  }

  private async revoke(request: Request, path: string, now: number): Promise<void> {
    const caller = await this.caller(request, now);
    const ident = decodeURIComponent(path.slice(path.lastIndexOf("/") + 1));
    if (path.startsWith("/v1/tokens/")) {
      if (!TOKEN_ID_RE.test(ident)) throw new PairError("bad_request", "token_id inválido");
      const rec = this.db.getToken(ident);
      if (!rec || (!caller.operator && rec.account !== caller.account)) {
        throw new PairError("not_found", "no hay token activo con ese id");
      }
      this.db.revokeToken(ident, rec.account, now);
      return;
    }
    if (!CODE_ID_RE.test(ident)) throw new PairError("bad_request", "id de código inválido");
    const changed = caller.operator
      ? this.sql.exec(
          "UPDATE pair_codes SET invalidated_at = ? WHERE id = ? AND used_at IS NULL AND invalidated_at IS NULL",
          now,
          ident,
        ).rowsWritten
      : this.sql.exec(
          "UPDATE pair_codes SET invalidated_at = ? WHERE id = ? AND account = ? AND used_at IS NULL AND invalidated_at IS NULL",
          now,
          ident,
          caller.account,
        ).rowsWritten;
    if (changed === 0) throw new PairError("not_found", "no hay código vivo con ese id");
  }
}
