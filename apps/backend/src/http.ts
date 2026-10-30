export const API_ORIGIN = "https://api.chopshop.novarix.online";
export const WEB_ORIGIN = "https://chopshop.novarix.online";
export const SESSION_COOKIE = "__Host-chopshop_session";
export const CSRF_HEADER = "X-CSRF-Token";
export const MAX_BODY_BYTES = 1024 * 1024;

export interface HttpEnv {
  API_ORIGIN?: string;
  WEB_ORIGIN?: string;
  ASSETS?: Fetcher;
}

export type Principal =
  | { kind: "anonymous" }
  | { kind: "user"; userId: string; role: "owner" | "watcher"; sessionId: string; client: "mac" | "web" | "cli"; viaCookie: boolean }
  | { kind: "machine"; machineId: string; localMachineId: string | null; paused: boolean }
  | { kind: "operator" };

const ERROR_STATUS = {
  bad_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  gone: 410,
  too_large: 413,
  unsupported_version: 426,
  rate_limited: 429,
  internal: 500,
  timeout: 504,
} as const;

export type ErrorCode = keyof typeof ERROR_STATUS;

export interface ErrorExtra {
  field?: string;
  retryAfterS?: number;
  current?: unknown;
  status?: number;
  headers?: Record<string, string>;
}

export const SECURITY_HEADERS: Readonly<Record<string, string>> = {
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "X-Frame-Options": "DENY",
};

export function webCsp(apiOrigin: string): string {
  return [
    "default-src 'self'",
    `connect-src 'self' ${apiOrigin}`,
    "img-src 'self' data:",
    "style-src 'self'",
    "script-src 'self'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "form-action 'none'",
  ].join("; ");
}

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const encoder = new TextEncoder();

export function ulid(now: number = Date.now()): string {
  let out = "";
  let t = now;
  for (let i = 0; i < 10; i++) {
    out = CROCKFORD[t % 32]! + out;
    t = Math.floor(t / 32);
  }
  for (const b of crypto.getRandomValues(new Uint8Array(16))) out += CROCKFORD[b % 32]!;
  return out;
}

export function apiOrigin(env: HttpEnv): string {
  return env.API_ORIGIN ?? API_ORIGIN;
}

export function webOrigin(env: HttpEnv): string {
  return env.WEB_ORIGIN ?? WEB_ORIGIN;
}

export function errorBody(code: ErrorCode, message: string, extra: ErrorExtra = {}): Record<string, unknown> {
  const body: Record<string, unknown> = { v: 2, type: "error", id: ulid(), ts: new Date().toISOString(), re: null, code, message };
  if (extra.field !== undefined) body.field = extra.field;
  if (extra.retryAfterS !== undefined) body.retry_after_s = extra.retryAfterS;
  if (extra.current !== undefined) body.current = extra.current;
  return body;
}

export function errorResponse(code: ErrorCode, message: string, extra: ErrorExtra = {}): Response {
  const headers: Record<string, string> = { "Cache-Control": "no-store", ...extra.headers };
  if (extra.retryAfterS !== undefined) headers["Retry-After"] = String(extra.retryAfterS);
  if (code === "unauthorized") headers["WWW-Authenticate"] ??= "Bearer";
  return Response.json(errorBody(code, message, extra), { status: extra.status ?? ERROR_STATUS[code], headers });
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store", ...headers } });
}

export function noContent(headers: Record<string, string> = {}): Response {
  return new Response(null, { status: 204, headers: { "Cache-Control": "no-store", ...headers } });
}

export function corsHeaders(request: Request, env: HttpEnv): Record<string, string> {
  const origin = request.headers.get("Origin");
  if (origin === null || origin !== webOrigin(env)) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Credentials": "true",
    "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE",
    "Access-Control-Allow-Headers": `Content-Type, ${CSRF_HEADER}`,
    "Access-Control-Max-Age": "600",
    Vary: "Origin",
  };
}

export function withHeaders(response: Response, extra: Record<string, string>): Response {
  if (response.status === 101) return response;
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(extra)) {
    if (k === "Vary" && headers.has("Vary")) headers.append("Vary", v);
    else headers.set(k, v);
  }
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

export function readCookie(request: Request, name: string): string | null {
  const raw = request.headers.get("Cookie");
  if (raw === null) return null;
  for (const part of raw.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return null;
}

export function sessionCookie(token: string, maxAgeS: number): string {
  return `${SESSION_COOKIE}=${token}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=${Math.max(0, Math.floor(maxAgeS))}`;
}

export type Credential = { via: "bearer"; token: string } | { via: "cookie"; token: string } | { via: "none" };

export function readCredential(request: Request): Credential | Response {
  const auth = request.headers.get("Authorization");
  const cookie = readCookie(request, SESSION_COOKIE);
  if (auth !== null && cookie !== null) return errorResponse("bad_request", "no se admiten cookie y Bearer a la vez");
  if (auth !== null) {
    const token = /^Bearer\s+(\S+)$/i.exec(auth)?.[1];
    if (token === undefined) return errorResponse("unauthorized", "credencial ausente, inválida o revocada");
    return { via: "bearer", token };
  }
  if (cookie !== null && cookie !== "") return { via: "cookie", token: cookie };
  return { via: "none" };
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function needsCsrf(method: string, viaCookie: boolean): boolean {
  return viaCookie && method !== "GET" && method !== "HEAD";
}

export async function checkCsrf(request: Request, env: HttpEnv, csrfHash: string | null): Promise<Response | null> {
  const denied = () => errorResponse("forbidden", "falta o no es válida la protección CSRF");
  if (request.headers.get("Origin") !== webOrigin(env)) return denied();
  const token = request.headers.get(CSRF_HEADER);
  if (token === null || !/^cx1_[A-Za-z0-9_-]{43}$/.test(token) || csrfHash === null) return denied();
  if (!sameText(await sha256Hex(token), csrfHash)) return denied();
  return null;
}

export function bodyTooLarge(request: Request): Response | null {
  const length = request.headers.get("Content-Length");
  if (length === null) return null;
  const n = Number(length);
  if (Number.isFinite(n) && n <= MAX_BODY_BYTES) return null;
  return errorResponse("too_large", "el cuerpo supera 1 MiB");
}

export async function readJson(request: Request): Promise<unknown | Response> {
  const tooLarge = bodyTooLarge(request);
  if (tooLarge) return tooLarge;
  if (request.body === null) return errorResponse("bad_request", "se esperaba un cuerpo JSON");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      return errorResponse("too_large", "el cuerpo supera 1 MiB");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    bytes.set(c, offset);
    offset += c.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)) as unknown;
  } catch {
    return errorResponse("bad_request", "el cuerpo no es JSON válido");
  }
}
