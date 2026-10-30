import assert from "node:assert/strict";
import { createHash, createHmac, pbkdf2Sync } from "node:crypto";
import { describe, it } from "node:test";
import {
  DUMMY_PASSWORD_HASH,
  PBKDF2_ITERATIONS,
  PBKDF2_MAX_ITERATIONS,
  RECOVERY_ALPHABET,
  TOKEN_PREFIX,
  base64urlDecode,
  base64urlEncode,
  generateRecoveryCode,
  hashPassword,
  isToken,
  needsRehash,
  newToken,
  pepperFromEnv,
  normalizeRecoveryCode,
  recoveryCodeHash,
  sha256Hex,
  timingSafeEqual,
  verifyPassword,
  type TokenKind,
} from "../src/crypto.ts";

const PASSWORD = "correct horse battery staple";
const SECRET = "pepper-de-prueba-0123456789abcdefghij";
const SECRET2 = "pepper-nuevo-de-prueba-abcdefghij0123456789";
const PEPPER = pepperFromEnv({ PASSWORD_PEPPER: SECRET });
const HASH_RE = /^pbkdf2-sha256-p1\$10000\$[A-Za-z0-9_-]{22}\$[A-Za-z0-9_-]{43}$/;
const SALT = Buffer.from("0123456789abcdef");

function legacyHash(password: string, iterations: number): string {
  const hash = pbkdf2Sync(password, SALT, iterations, 32, "sha256");
  return `pbkdf2-sha256$${iterations}$${SALT.toString("base64url")}$${hash.toString("base64url")}`;
}

function pepperedHash(password: string, iterations: number, secret: string, version: number): string {
  const material = createHmac("sha256", secret).update(password.normalize("NFC"), "utf8").digest();
  const hash = pbkdf2Sync(material, SALT, iterations, 32, "sha256");
  return `pbkdf2-sha256-p${version}$${iterations}$${SALT.toString("base64url")}$${hash.toString("base64url")}`;
}

describe("contraseñas", () => {
  it("usa HMAC-SHA256 con pepper y PBKDF2-SHA256 con 10 000 iteraciones en el formato versionado", async () => {
    assert.equal(PBKDF2_ITERATIONS, 10_000);
    assert.equal(PBKDF2_MAX_ITERATIONS, 100_000);
    const stored = await hashPassword(PASSWORD, PEPPER);
    assert.match(stored, HASH_RE);
    const [, iter, salt, hash] = stored.split("$");
    assert.equal(iter, "10000");
    assert.equal(base64urlDecode(salt!)!.byteLength, 16);
    assert.equal(base64urlDecode(hash!)!.byteLength, 32);
    const material = createHmac("sha256", SECRET).update(PASSWORD).digest();
    const expected = pbkdf2Sync(material, Buffer.from(base64urlDecode(salt!)!), 10_000, 32, "sha256");
    assert.equal(hash, expected.toString("base64url"));
  });

  it("sal aleatoria: dos hashes de la misma contraseña difieren", async () => {
    assert.notEqual(await hashPassword(PASSWORD, PEPPER), await hashPassword(PASSWORD, PEPPER));
  });

  it("verifica la correcta y rechaza la incorrecta", async () => {
    const stored = await hashPassword(PASSWORD, PEPPER);
    assert.equal(await verifyPassword(PASSWORD, stored, PEPPER), true);
    assert.equal(await verifyPassword(PASSWORD + "x", stored, PEPPER), false);
    assert.equal(await verifyPassword("", stored, PEPPER), false);
  });

  it("normaliza a NFC antes de derivar", async () => {
    const stored = await hashPassword("contrase\u00f1a-segura", PEPPER);
    assert.equal(await verifyPassword("contrasen\u0303a-segura", stored, PEPPER), true);
  });

  it("rechaza hashes mal formados, de otro esquema o por encima del tope", async () => {
    for (const bad of [
      null,
      "",
      "x",
      "bcrypt$10$a$b",
      "pbkdf2-sha256$0$AAAA$AAAA",
      "pbkdf2-sha256$100000$!!$AAAA",
      "pbkdf2-sha256-p0$10000$MDEyMzQ1Njc4OWFiY2RlZg$AAAA",
      legacyHash(PASSWORD, 100_001),
    ]) {
      assert.equal(await verifyPassword(PASSWORD, bad, PEPPER), false, String(bad));
    }
  });

  it("el hash ficticio no acepta contraseñas", async () => {
    assert.match(DUMMY_PASSWORD_HASH, HASH_RE);
    assert.equal(await verifyPassword(PASSWORD, DUMMY_PASSWORD_HASH, PEPPER), false);
    assert.equal(await verifyPassword("", DUMMY_PASSWORD_HASH, PEPPER), false);
  });

  it("verifica hashes viejos sin pepper (100 000 y 1000 iteraciones) y pide rehash", async () => {
    for (const iterations of [100_000, 1000]) {
      const old = legacyHash(PASSWORD, iterations);
      assert.equal(await verifyPassword(PASSWORD, old, PEPPER), true);
      assert.equal(await verifyPassword(PASSWORD + "x", old, PEPPER), false);
      assert.equal(needsRehash(old, PEPPER), true);
    }
  });

  it("needsRehash solo es falso con el esquema, pepper e iteraciones vigentes", async () => {
    assert.equal(needsRehash(await hashPassword(PASSWORD, PEPPER), PEPPER), false);
    assert.equal(needsRehash(pepperedHash(PASSWORD, 10_000, SECRET, 1), PEPPER), false);
    assert.equal(needsRehash(pepperedHash(PASSWORD, 20_000, SECRET, 1), PEPPER), true);
    assert.equal(needsRehash(pepperedHash(PASSWORD, 5_000, SECRET, 1), PEPPER), true);
    assert.equal(needsRehash("bcrypt$10$a$b", PEPPER), true);
    assert.equal(needsRehash(null, PEPPER), true);
  });

  it("subir iteraciones más adelante no rompe los hashes guardados", async () => {
    const stronger = pepperedHash(PASSWORD, 50_000, SECRET, 1);
    assert.equal(await verifyPassword(PASSWORD, stronger, PEPPER), true);
    assert.equal(needsRehash(stronger, PEPPER), true);
  });

  it("el pepper cambia el hash: sin el secreto correcto no verifica", async () => {
    const stored = await hashPassword(PASSWORD, PEPPER);
    const other = pepperFromEnv({ PASSWORD_PEPPER: SECRET2 });
    assert.equal(await verifyPassword(PASSWORD, stored, other), false);
    const plain = pbkdf2Sync(PASSWORD, SALT, 10_000, 32, "sha256").toString("base64url");
    assert.equal(await verifyPassword(PASSWORD, `pbkdf2-sha256-p1$10000$${SALT.toString("base64url")}$${plain}`, PEPPER), false);
  });

  it("rotación de pepper: la versión anterior sigue verificando y pide rehash", async () => {
    const old = await hashPassword(PASSWORD, PEPPER);
    const rotated = pepperFromEnv({ PASSWORD_PEPPER: SECRET2, PASSWORD_PEPPER_VERSION: "2", PASSWORD_PEPPER_V1: SECRET });
    assert.deepEqual([rotated.version, [...rotated.secrets.keys()].sort()], [2, [1, 2]]);
    assert.equal(await verifyPassword(PASSWORD, old, rotated), true);
    assert.equal(needsRehash(old, rotated), true);
    const fresh = await hashPassword(PASSWORD, rotated);
    assert.match(fresh, /^pbkdf2-sha256-p2\$10000\$/);
    assert.equal(needsRehash(fresh, rotated), false);
    assert.equal(await verifyPassword(PASSWORD, fresh, PEPPER), false);
    const dropped = pepperFromEnv({ PASSWORD_PEPPER: SECRET2, PASSWORD_PEPPER_VERSION: "2" });
    assert.equal(await verifyPassword(PASSWORD, old, dropped), false);
  });

  it("pepperFromEnv exige un secreto de al menos 32 caracteres y versión válida", () => {
    assert.throws(() => pepperFromEnv({}));
    assert.throws(() => pepperFromEnv({ PASSWORD_PEPPER: "corto" }));
    assert.throws(() => pepperFromEnv({ PASSWORD_PEPPER: SECRET, PASSWORD_PEPPER_VERSION: "0" }));
    assert.throws(() => pepperFromEnv({ PASSWORD_PEPPER: SECRET, PASSWORD_PEPPER_VERSION: "v2" }));
    assert.equal(pepperFromEnv({ PASSWORD_PEPPER: SECRET }).version, 1);
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
