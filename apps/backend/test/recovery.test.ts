import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { normalizeRecoveryCode, sha256Hex, verifyPassword } from "../src/crypto.ts";
import { addSession, addUser, call, freshEnv, row, rows, type TestEnv } from "./accounts.ts";

const CODE = "7K3MQ-0AB1C-XYZ12-34567";
const NEW_PASSWORD = "una-contraseña-nueva-y-larga";

async function owner(env: TestEnv): Promise<string> {
  return addUser(env, "duena@ejemplo.test", "owner", { password: "contraseña-del-dueño-1", recoveryCode: normalizeRecoveryCode(CODE)! });
}

function recover(env: TestEnv, body: Record<string, unknown>, ip?: string): Promise<Response> {
  return call(env, "POST", "/v1/auth/recover", { body: { email: "duena@ejemplo.test", recovery_code: CODE, new_password: NEW_PASSWORD, ...body }, ...(ip ? { ip } : {}) });
}

describe("POST /v1/auth/recover", () => {
  it("cambia la contraseña, revoca todas las sesiones y devuelve un código nuevo de un solo uso", async () => {
    const env = await freshEnv();
    const id = await owner(env);
    const s1 = await addSession(env, id);
    await addSession(env, id);
    const res = await recover(env, { email: " DUENA@ejemplo.test", recovery_code: "7k3mq oab1c xyz12 34567" });
    assert.equal(res.status, 200);
    const { recovery_code } = (await res.json()) as { recovery_code: string };
    assert.match(recovery_code, /^[0-9A-HJKMNP-TV-Z]{5}(-[0-9A-HJKMNP-TV-Z]{5}){3}$/);
    const user = await row(env, "SELECT password_hash, recovery_hash FROM users WHERE id = ?", id);
    assert.equal(await verifyPassword(NEW_PASSWORD, String(user?.password_hash)), true);
    assert.equal(user?.recovery_hash, await sha256Hex(normalizeRecoveryCode(recovery_code)!));
    const sessions = await rows(env, "SELECT revoked_at, revoked_reason FROM sessions WHERE user_id = ?", id);
    assert.equal(sessions.length, 2);
    for (const s of sessions) {
      assert.notEqual(s.revoked_at, null);
      assert.equal(s.revoked_reason, "recovered");
    }
    assert.equal((await call(env, "POST", "/v1/auth/recovery-code", { auth: `Bearer ${s1.token}`, body: { password: NEW_PASSWORD } })).status, 401);
    const audit = await rows(env, "SELECT actor_user_id, result FROM audit_log WHERE action = 'auth.recovered'");
    assert.deepEqual(audit, [{ actor_user_id: id, result: "ok" }]);

    const reused = await recover(env, { new_password: "otra-contraseña-distinta" });
    assert.equal(reused.status, 401);
    assert.equal(await verifyPassword(NEW_PASSWORD, String((await row(env, "SELECT password_hash FROM users WHERE id = ?", id))?.password_hash)), true);
    assert.equal((await recover(env, { recovery_code: recovery_code, new_password: "otra-contraseña-distinta" })).status, 200);
  });

  it("responde el mismo 401 con código malo, correo ajeno o un watcher", async () => {
    const env = await freshEnv();
    const id = await owner(env);
    await addUser(env, "vigia@ejemplo.test", "watcher", { recoveryCode: normalizeRecoveryCode(CODE)! });
    const before = await row(env, "SELECT password_hash FROM users WHERE id = ?", id);
    for (const body of [{ recovery_code: "00000-00000-00000-00000" }, { recovery_code: "corto" }, { email: "nadie@ejemplo.test" }, { email: "vigia@ejemplo.test" }]) {
      const res = await recover(env, body);
      assert.equal(res.status, 401);
      assert.equal(((await res.json()) as { message: string }).message, "correo o código de recuperación incorrectos");
    }
    assert.deepEqual(await row(env, "SELECT password_hash FROM users WHERE id = ?", id), before);
  });

  it("aplica la política de contraseña y valida el cuerpo", async () => {
    const env = await freshEnv();
    await owner(env);
    const short = await recover(env, { new_password: "corta" });
    assert.equal(short.status, 400);
    assert.equal(((await short.json()) as { field: string }).field, "password");
    assert.equal((await recover(env, { new_password: "mi-correo-es-duena-ok" })).status, 400);
    assert.equal((await recover(env, { email: "x" })).status, 400);
    assert.equal((await recover(env, { recovery_code: 5 })).status, 400);
  });

  it("límite rc: 5 fallos por IP en 1 h bloquean 60 min, incluso con el código correcto", async () => {
    const env = await freshEnv();
    await owner(env);
    for (let i = 0; i < 5; i++) assert.equal((await recover(env, { recovery_code: "00000-00000-00000-00000" })).status, 401);
    const locked = await recover(env, {});
    assert.equal(locked.status, 429);
    const retry = Number(locked.headers.get("Retry-After"));
    assert.ok(retry > 3500 && retry <= 3600, String(retry));
    const key = `rc:${await sha256Hex("203.0.113.7")}`;
    assert.equal((await row(env, "SELECT failures FROM auth_attempts WHERE key_hash = ?", key))?.failures, 5);
    assert.equal((await recover(env, {}, "198.51.100.1")).status, 200);
  });

  it("límite e: 20 fallos por correo bloquean desde todas las IPs", async () => {
    const env = await freshEnv();
    await owner(env);
    for (let i = 0; i < 20; i++) await recover(env, { recovery_code: "00000-00000-00000-00000" }, `198.51.100.${i}`);
    const locked = await recover(env, {}, "192.0.2.1");
    assert.equal(locked.status, 429);
    assert.ok(Number(locked.headers.get("Retry-After")) <= 900);
  });
});

describe("POST /v1/auth/recovery-code", () => {
  it("el dueño con su contraseña obtiene un código nuevo y el anterior deja de valer", async () => {
    const env = await freshEnv();
    const id = await owner(env);
    const s = await addSession(env, id);
    const res = await call(env, "POST", "/v1/auth/recovery-code", { auth: `Bearer ${s.token}`, body: { password: "contraseña-del-dueño-1" } });
    assert.equal(res.status, 200);
    const { recovery_code } = (await res.json()) as { recovery_code: string };
    assert.equal((await row(env, "SELECT recovery_hash FROM users WHERE id = ?", id))?.recovery_hash, await sha256Hex(normalizeRecoveryCode(recovery_code)!));
    assert.equal((await row(env, "SELECT revoked_at FROM sessions WHERE id = ?", s.id))?.revoked_at, null);
    assert.equal((await recover(env, {})).status, 401);
    assert.equal((await recover(env, { recovery_code })).status, 200);
    assert.equal((await row(env, "SELECT session_id FROM audit_log WHERE action = 'auth.recovery_code'"))?.session_id, s.id);
  });

  it("contraseña incorrecta 401, watcher 403, sin sesión 401", async () => {
    const env = await freshEnv();
    const id = await owner(env);
    const s = await addSession(env, id);
    const watcher = await addSession(env, await addUser(env, "vigia@ejemplo.test", "watcher"));
    const before = await row(env, "SELECT recovery_hash FROM users WHERE id = ?", id);
    assert.equal((await call(env, "POST", "/v1/auth/recovery-code", { auth: `Bearer ${s.token}`, body: { password: "no-es-la-buena-123" } })).status, 401);
    assert.equal((await call(env, "POST", "/v1/auth/recovery-code", { auth: `Bearer ${watcher.token}`, body: { password: "contraseña-inicial-larga" } })).status, 403);
    assert.equal((await call(env, "POST", "/v1/auth/recovery-code", { body: { password: "contraseña-del-dueño-1" } })).status, 401);
    assert.deepEqual(await row(env, "SELECT recovery_hash FROM users WHERE id = ?", id), before);
  });
});
