import assert from "node:assert/strict";
import { createHash, pbkdf2Sync } from "node:crypto";
import { describe, it } from "node:test";
import {
  DUMMY_PASSWORD_HASH,
  PBKDF2_ITERATIONS,
  RECOVERY_ALPHABET,
  TOKEN_PREFIX,
  base64urlDecode,
  base64urlEncode,
  generateRecoveryCode,
  hashPassword,
  isToken,
  needsRehash,
  newToken,
  normalizeRecoveryCode,
  recoveryCodeHash,
  sha256Hex,
  timingSafeEqual,
  verifyPassword,
  type TokenKind,
} from "../src/crypto.ts";

const PASSWORD = "correct horse battery staple";
const HASH_RE = /^pbkdf2-sha256\$100000\$[A-Za-z0-9_-]{22}\$[A-Za-z0-9_-]{43}$/;

function legacyHash(password: string, iterations: number): string {
  const salt = Buffer.from("0123456789abcdef");
  const hash = pbkdf2Sync(password, salt, iterations, 32, "sha256");
  return `pbkdf2-sha256$${iterations}$${salt.toString("base64url")}$${hash.toString("base64url")}`;
}

describe("contraseñas", () => {
  it("usa PBKDF2-SHA256 con 100 000 iteraciones y el formato versionado", async () => {
    assert.equal(PBKDF2_ITERATIONS, 100_000);
    const stored = await hashPassword(PASSWORD);
    assert.match(stored, HASH_RE);
    const [, iter, salt, hash] = stored.split("$");
    assert.equal(iter, "100000");
    assert.equal(base64urlDecode(salt!)!.byteLength, 16);
    assert.equal(base64urlDecode(hash!)!.byteLength, 32);
    const expected = pbkdf2Sync(PASSWORD, Buffer.from(base64urlDecode(salt!)!), 100_000, 32, "sha256");
    assert.equal(hash, expected.toString("base64url"));
  });

  it("sal aleatoria: dos hashes de la misma contraseña difieren", async () => {
    assert.notEqual(await hashPassword(PASSWORD), await hashPassword(PASSWORD));
  });

  it("verifica la correcta y rechaza la incorrecta", async () => {
    const stored = await hashPassword(PASSWORD);
    assert.equal(await verifyPassword(PASSWORD, stored), true);
    assert.equal(await verifyPassword(PASSWORD + "x", stored), false);
    assert.equal(await verifyPassword("", stored), false);
  });

  it("normaliza a NFC antes de derivar", async () => {
    const stored = await hashPassword("contraseña-segura");
    assert.equal(await verifyPassword("contraseña-segura", stored), true);
  });

  it("rechaza hashes mal formados o de otro esquema", async () => {
    for (const bad of ["", "x", "bcrypt$10$a$b", "pbkdf2-sha256$0$AAAA$AAAA", "pbkdf2-sha256$100000$!!$AAAA", "pbkdf2-sha256$200000$MDEyMzQ1Njc4OWFiY2RlZg$AAAA"]) {
      assert.equal(await verifyPassword(PASSWORD, bad), false, bad);
    }
  });

  it("el hash ficticio es válido y no acepta contraseñas", async () => {
    assert.match(DUMMY_PASSWORD_HASH, HASH_RE);
    assert.equal(needsRehash(DUMMY_PASSWORD_HASH), false);
    assert.equal(await verifyPassword(PASSWORD, DUMMY_PASSWORD_HASH), false);
  });

  it("pide rehash si las iteraciones o el esquema no son los vigentes", async () => {
    assert.equal(needsRehash(await hashPassword(PASSWORD)), false);
    const old = legacyHash(PASSWORD, 1000);
    assert.equal(await verifyPassword(PASSWORD, old), true);
    assert.equal(needsRehash(old), true);
    assert.equal(needsRehash("bcrypt$10$a$b"), true);
  });
});

describe("tokens", () => {
  it("prefijos ss1_/cm1_/ci1_/cx1_ y 43 caracteres base64url", () => {
    assert.deepEqual(TOKEN_PREFIX, { session: "ss1_", machine: "cm1_", invitation: "ci1_", csrf: "cx1_" });
    for (const kind of Object.keys(TOKEN_PREFIX) as TokenKind[]) {
      const token = newToken(kind);
      assert.equal(token.length, 47);
      assert.match(token, new RegExp(`^${TOKEN_PREFIX[kind]}[A-Za-z0-9_-]{43}$`));
      assert.equal(base64urlDecode(token.slice(4))!.byteLength, 32);
      assert.equal(isToken(kind, token), true);
      assert.notEqual(newToken(kind), token);
    }
  });

  it("isToken rechaza otro prefijo, longitud o alfabeto", () => {
    const body = "A".repeat(43);
    assert.equal(isToken("session", `ss1_${body}`), true);
    assert.equal(isToken("session", `cm1_${body}`), false);
    assert.equal(isToken("machine", `ss1_${body}`), false);
    assert.equal(isToken("session", `ss1_${body}A`), false);
    assert.equal(isToken("session", `ss1_${"A".repeat(42)}`), false);
    assert.equal(isToken("session", `ss1_${"A".repeat(42)}=`), false);
    assert.equal(isToken("session", `ss1_${"A".repeat(42)}+`), false);
    assert.equal(isToken("session", `cr1_${body}`), false);
    assert.equal(isToken("session", undefined), false);
  });

  it("sha256Hex sobre el texto UTF-8 completo con prefijo", async () => {
    const token = newToken("session");
    const hash = await sha256Hex(token);
    assert.match(hash, /^[0-9a-f]{64}$/);
    assert.equal(hash, createHash("sha256").update(token, "utf8").digest("hex"));
    assert.equal(await sha256Hex("ñ"), createHash("sha256").update("ñ", "utf8").digest("hex"));
  });

  it("timingSafeEqual compara bytes y falla con longitudes distintas", () => {
    assert.equal(timingSafeEqual("abc", "abc"), true);
    assert.equal(timingSafeEqual("abc", "abd"), false);
    assert.equal(timingSafeEqual("abc", "abcd"), false);
    assert.equal(timingSafeEqual("", ""), true);
    assert.equal(timingSafeEqual(new Uint8Array([1, 2]), new Uint8Array([1, 2])), true);
    assert.equal(timingSafeEqual(new Uint8Array([1, 2]), new Uint8Array([1, 3])), false);
  });

  it("base64url ida y vuelta sin relleno", () => {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const text = base64urlEncode(bytes);
    assert.equal(text.length, 43);
    assert.deepEqual(base64urlDecode(text), bytes);
    assert.equal(base64urlDecode("a+b/"), null);
    assert.equal(base64urlDecode("abcde"), null);
  });
});

describe("código de recuperación", () => {
  it("20 símbolos Crockford en 4 grupos de 5", () => {
    const code = generateRecoveryCode();
    assert.match(code, /^[0-9A-HJKMNP-TV-Z]{5}(-[0-9A-HJKMNP-TV-Z]{5}){3}$/);
    assert.equal(code.replace(/-/g, "").length, 20);
    for (const c of code.replace(/-/g, "")) assert.ok(RECOVERY_ALPHABET.includes(c));
    assert.notEqual(generateRecoveryCode(), code);
  });

  it("normaliza guiones, espacios, minúsculas, O→0 e I/L→1", () => {
    assert.equal(normalizeRecoveryCode("abcde-fghjk-mnpqr-stvwx"), "ABCDEFGHJKMNPQRSTVWX");
    assert.equal(normalizeRecoveryCode(" o0iLl 11111 22222-33333 "), "00111111112222233333");
    assert.equal(normalizeRecoveryCode("OOOOO-IIIII-LLLLL-ooooo"), "00000111111111100000");
    const code = generateRecoveryCode();
    assert.equal(normalizeRecoveryCode(code), code.replace(/-/g, ""));
  });

  it("rechaza longitudes y símbolos inválidos", () => {
    assert.equal(normalizeRecoveryCode("ABCDE-FGHJK-MNPQR-STVW"), null);
    assert.equal(normalizeRecoveryCode("ABCDE-FGHJK-MNPQR-STVWXY"), null);
    assert.equal(normalizeRecoveryCode("ABCDE-FGHJK-MNPQR-STVWU"), null);
    assert.equal(normalizeRecoveryCode(""), null);
    assert.equal(normalizeRecoveryCode(42), null);
  });

  it("el hash es sha256 hex del código normalizado", async () => {
    const expected = createHash("sha256").update("00111111112222233333").digest("hex");
    assert.equal(await recoveryCodeHash("oOiIl-11111-22222-33333"), expected);
    assert.equal(await recoveryCodeHash("corto"), null);
  });
});
