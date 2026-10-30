export const PASSWORD_SCHEME = "pbkdf2-sha256";
export const PBKDF2_ITERATIONS = 10_000;
export const PBKDF2_MAX_ITERATIONS = 100_000;
export const PEPPER_MIN_LEN = 32;
export const SALT_BYTES = 16;
export const HASH_BYTES = 32;
export const TOKEN_BYTES = 32;
export const TOKEN_LEN = 43;
export const DUMMY_PASSWORD_HASH = "pbkdf2-sha256-p1$10000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

export const TOKEN_PREFIX = {
  session: "ss1_",
  machine: "cm1_",
  invitation: "ci1_",
  csrf: "cx1_",
} as const;

export type TokenKind = keyof typeof TOKEN_PREFIX;

export const RECOVERY_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const RECOVERY_LEN = 20;
export const RECOVERY_GROUP = 5;

const TOKEN_RE: Record<TokenKind, RegExp> = {
  session: /^ss1_[A-Za-z0-9_-]{43}$/,
  machine: /^cm1_[A-Za-z0-9_-]{43}$/,
  invitation: /^ci1_[A-Za-z0-9_-]{43}$/,
  csrf: /^cx1_[A-Za-z0-9_-]{43}$/,
};

const SCHEME_RE = /^pbkdf2-sha256(?:-p([1-9][0-9]{0,2}))?$/;
const PEPPER_VERSION_RE = /^[1-9][0-9]{0,2}$/;
const B64URL_RE = /^[A-Za-z0-9_-]+$/;
const encoder = new TextEncoder();

export function base64urlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlDecode(text: string): Uint8Array | null {
  if (!B64URL_RE.test(text) || text.length % 4 === 1) return null;
  const bin = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(value: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

export function timingSafeEqual(a: string | Uint8Array, b: string | Uint8Array): boolean {
  const x = typeof a === "string" ? encoder.encode(a) : a;
  const y = typeof b === "string" ? encoder.encode(b) : b;
  if (x.byteLength !== y.byteLength) return false;
  const subtle = crypto.subtle as SubtleCrypto & { timingSafeEqual?: (a: Uint8Array, b: Uint8Array) => boolean };
  if (typeof subtle.timingSafeEqual === "function") return subtle.timingSafeEqual(x, y);
  let diff = 0;
  for (let i = 0; i < x.byteLength; i++) diff |= x[i]! ^ y[i]!;
  return diff === 0;
}

async function pepperedMaterial(password: string, secret: string | null): Promise<Uint8Array> {
  const raw = encoder.encode(password.normalize("NFC"));
  if (secret === null) return raw;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, raw));
}

async function pbkdf2(material: Uint8Array, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", material, "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, HASH_BYTES * 8);
  return new Uint8Array(bits);
}

export interface Pepper {
  version: number;
  secrets: ReadonlyMap<number, string>;
}

export function pepperFromEnv(env: Record<string, unknown>): Pepper {
  const current = env.PASSWORD_PEPPER;
  const versionText = env.PASSWORD_PEPPER_VERSION ?? "1";
  if (typeof current !== "string" || current.length < PEPPER_MIN_LEN) throw new Error("PASSWORD_PEPPER ausente o corto");
  if (typeof versionText !== "string" || !PEPPER_VERSION_RE.test(versionText)) throw new Error("PASSWORD_PEPPER_VERSION inválido");
  const version = Number(versionText);
  const secrets = new Map<number, string>();
  for (const [name, value] of Object.entries(env)) {
    const m = /^PASSWORD_PEPPER_V([1-9][0-9]{0,2})$/.exec(name);
    if (m && typeof value === "string" && value.length >= PEPPER_MIN_LEN) secrets.set(Number(m[1]), value);
  }
  secrets.set(version, current);
  return { version, secrets };
}

function schemeFor(pepperVersion: number): string {
  return pepperVersion === 0 ? PASSWORD_SCHEME : `${PASSWORD_SCHEME}-p${pepperVersion}`;
}

export async function hashPassword(password: string, pepper: Pepper): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const hash = await pbkdf2(await pepperedMaterial(password, pepper.secrets.get(pepper.version)!), salt, PBKDF2_ITERATIONS);
  return `${schemeFor(pepper.version)}$${PBKDF2_ITERATIONS}$${base64urlEncode(salt)}$${base64urlEncode(hash)}`;
}

interface ParsedHash {
  pepperVersion: number;
  iterations: number;
  salt: Uint8Array;
  hash: Uint8Array;
}

function parsePasswordHash(stored: string | null): ParsedHash | null {
  if (typeof stored !== "string") return null;
  const parts = stored.split("$");
  if (parts.length !== 4) return null;
  const [scheme, iter, salt, hash] = parts as [string, string, string, string];
  const m = SCHEME_RE.exec(scheme);
  if (!m || !/^[1-9][0-9]{0,5}$/.test(iter)) return null;
  const iterations = Number(iter);
  if (iterations > PBKDF2_MAX_ITERATIONS) return null;
  const saltBytes = base64urlDecode(salt);
  const hashBytes = base64urlDecode(hash);
  if (!saltBytes || !hashBytes || saltBytes.byteLength === 0 || hashBytes.byteLength !== HASH_BYTES) return null;
  return { pepperVersion: m[1] ? Number(m[1]) : 0, iterations, salt: saltBytes, hash: hashBytes };
}

export async function verifyPassword(password: string, stored: string | null, pepper: Pepper): Promise<boolean> {
  const parsed = parsePasswordHash(stored);
  const secret = parsed ? (parsed.pepperVersion === 0 ? null : pepper.secrets.get(parsed.pepperVersion)) : undefined;
  if (!parsed || secret === undefined) {
    await pbkdf2(await pepperedMaterial(password, pepper.secrets.get(pepper.version)!), new Uint8Array(SALT_BYTES), PBKDF2_ITERATIONS);
    return false;
  }
  return timingSafeEqual(await pbkdf2(await pepperedMaterial(password, secret), parsed.salt, parsed.iterations), parsed.hash);
}

export function needsRehash(stored: string | null, pepper: Pepper): boolean {
  const parsed = parsePasswordHash(stored);
  return (
    !parsed ||
    parsed.pepperVersion !== pepper.version ||
    parsed.iterations !== PBKDF2_ITERATIONS ||
    parsed.salt.byteLength !== SALT_BYTES
  );
}

export function newToken(kind: TokenKind): string {
  return TOKEN_PREFIX[kind] + base64urlEncode(crypto.getRandomValues(new Uint8Array(TOKEN_BYTES)));
}

export function isToken(kind: TokenKind, value: unknown): value is string {
  return typeof value === "string" && TOKEN_RE[kind].test(value);
}

export function generateRecoveryCode(): string {
  let s = "";
  for (const b of crypto.getRandomValues(new Uint8Array(RECOVERY_LEN))) s += RECOVERY_ALPHABET[b & 31]!;
  const groups: string[] = [];
  for (let i = 0; i < RECOVERY_LEN; i += RECOVERY_GROUP) groups.push(s.slice(i, i + RECOVERY_GROUP));
  return groups.join("-");
}

export function normalizeRecoveryCode(code: unknown): string | null {
  if (typeof code !== "string") return null;
  const s = code.replace(/[\s-]/g, "").toUpperCase().replace(/O/g, "0").replace(/[IL]/g, "1");
  if (s.length !== RECOVERY_LEN) return null;
  for (const c of s) if (!RECOVERY_ALPHABET.includes(c)) return null;
  return s;
}

export async function recoveryCodeHash(code: unknown): Promise<string | null> {
  const normalized = normalizeRecoveryCode(code);
  return normalized === null ? null : sha256Hex(normalized);
}
