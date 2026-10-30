import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { beforeEach, describe, it } from "node:test";
import {
  AUTH_FAILED_MESSAGE,
  authFailedBody,
  clearLimit,
  limitKey,
  loginKeys,
  purgeAttempts,
  rateLimitedBody,
  recordFailure,
  retryAfter,
} from "../src/ratelimit.ts";
import { FakeD1Database } from "./d1.ts";

const DDL = `CREATE TABLE auth_attempts (
  key_hash TEXT PRIMARY KEY,
  failures INTEGER NOT NULL DEFAULT 0,
  window_start TEXT NOT NULL,
  locked_until TEXT,
  updated_at TEXT NOT NULL
);`;

const T0 = Date.parse("2026-10-30T12:00:00.000Z");
const MIN = 60_000;
let fake: FakeD1Database;
let db: D1Database;

async function fail(keys: Awaited<ReturnType<typeof loginKeys>>, times: number, at: number): Promise<number> {
  let retry = 0;
  for (let i = 0; i < times; i++) retry = await recordFailure(db, keys, at);
  return retry;
}

describe("límites de login", () => {
  beforeEach(async () => {
    fake = new FakeD1Database();
    await fake.exec(DDL);
    db = fake.asD1();
  });

  it("claves con prefijo y sha256, sin correo ni IP en claro", async () => {
    const keys = await loginKeys("  Ana@Example.COM ", "203.0.113.7");
    assert.deepEqual(
      keys.map((k) => k.hash),
      [
        "ei:" + createHash("sha256").update("ana@example.com|203.0.113.7").digest("hex"),
        "e:" + createHash("sha256").update("ana@example.com").digest("hex"),
        "ip:" + createHash("sha256").update("203.0.113.7").digest("hex"),
      ],
    );
    await recordFailure(db, keys, T0);
    const rows = fake.db.prepare("SELECT * FROM auth_attempts").all() as Record<string, unknown>[];
    assert.equal(rows.length, 3);
    for (const row of rows) assert.ok(!JSON.stringify(row).includes("ana") && !JSON.stringify(row).includes("203.0"));
  });

  it("bloquea correo+IP al quinto fallo y el bloqueo crece de forma progresiva hasta 60 min", async () => {
    const keys = await loginKeys("ana@example.com", "203.0.113.7");
    assert.equal(await fail(keys, 4, T0), 0);
    assert.equal(await retryAfter(db, keys, T0), 0);
    assert.equal(await recordFailure(db, keys, T0), 60);
    assert.equal(await retryAfter(db, keys, T0 + 30_000), 30);
    let at = T0 + MIN;
    assert.equal(await retryAfter(db, keys, at), 0);
    const expected = [120, 240, 480, 960, 1920, 3600, 3600];
    for (const lock of expected) {
      assert.equal(await recordFailure(db, keys, at), lock);
      at += lock * 1000;
    }
  });

  it("la ventana caduca 15 min después del último fallo o del fin del bloqueo", async () => {
    const keys = await loginKeys("ana@example.com", "203.0.113.7");
    await fail(keys, 4, T0);
    assert.equal(await recordFailure(db, keys, T0 + 15 * MIN), 0);
    await fail(keys, 3, T0 + 15 * MIN);
    assert.equal(await recordFailure(db, keys, T0 + 16 * MIN), 60);
    assert.equal(await recordFailure(db, keys, T0 + 17 * MIN + 15 * MIN), 0);
  });

  it("el bloqueo por correo alcanza a todas las IPs y no depende de que el correo exista", async () => {
    let retry = 0;
    for (let i = 0; i < 20; i++) retry = await recordFailure(db, await loginKeys("nadie@example.com", `198.51.100.${i}`), T0);
    assert.equal(retry, 15 * 60);
    assert.equal(await retryAfter(db, await loginKeys("NADIE@example.com", "192.0.2.1"), T0), 15 * 60);
    assert.equal(await retryAfter(db, await loginKeys("otra@example.com", "192.0.2.1"), T0), 0);
  });

  it("el bloqueo por IP llega a los 100 fallos en 1 h con correos distintos", async () => {
    let retry = 0;
    for (let i = 0; i < 100; i++) retry = await recordFailure(db, await loginKeys(`u${i}@example.com`, "192.0.2.9"), T0);
    assert.equal(retry, 60 * 60);
    assert.equal(await retryAfter(db, await loginKeys("nueva@example.com", "192.0.2.9"), T0), 60 * 60);
  });

  it("un login correcto borra solo la clave correo+IP", async () => {
    const keys = await loginKeys("ana@example.com", "203.0.113.7");
    await fail(keys, 5, T0);
    await clearLimit(db, keys[0]!);
    const rows = fake.db.prepare("SELECT key_hash, failures FROM auth_attempts ORDER BY key_hash").all() as { key_hash: string; failures: number }[];
    assert.deepEqual(
      rows.map((r) => [r.key_hash.split(":")[0], r.failures]),
      [
        ["e", 5],
        ["ip", 5],
      ],
    );
    assert.equal(await retryAfter(db, keys, T0), 0);
  });

  it("reglas de recuperación, invitaciones y operador", async () => {
    const rc = [await limitKey("rc", "192.0.2.1")];
    assert.equal(await fail(rc, 5, T0), 3600);
    const inv = [await limitKey("inv", "192.0.2.1")];
    assert.equal(await fail(inv, 9, T0), 0);
    assert.equal(await recordFailure(db, inv, T0 + 30_000), 300);
    const op = [await limitKey("op", "192.0.2.1")];
    assert.equal(await fail(op, 5, T0), 3600);
  });

  it("purga intentos viejos sin bloqueo vigente", async () => {
    await recordFailure(db, [await limitKey("rc", "a")], T0);
    await fail([await limitKey("op", "b")], 5, T0);
    assert.equal(await purgeAttempts(db, T0 + 26 * 60 * MIN), 2);
    await fail([await limitKey("ei", "c")], 15, T0);
    assert.equal(await purgeAttempts(db, T0 + 24 * 60 * MIN + 30 * MIN), 0);
  });

  it("mensajes uniformes: mismo 401 y mismo 429 sin importar la causa", () => {
    assert.deepEqual(authFailedBody(), { code: "unauthorized", message: AUTH_FAILED_MESSAGE });
    assert.deepEqual(rateLimitedBody(60), {
      code: "rate_limited",
      message: "demasiados intentos; vuelve a intentarlo más tarde",
      retry_after_s: 60,
    });
  });
});
