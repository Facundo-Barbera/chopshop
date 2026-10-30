import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { sha256Hex } from "../src/crypto.ts";
import { OPERATOR_SECRET, addUser, call, freshEnv, row, rows } from "./accounts.ts";

const OP = `Bearer ${OPERATOR_SECRET}`;

function tokenFrom(link: string): string {
  const m = /^https:\/\/chopshop\.novarix\.online\/invite#t=(ci1_[A-Za-z0-9_-]{43})$/.exec(link);
  assert.ok(m, link);
  return m[1]!;
}

describe("POST /v1/operator/bootstrap", () => {
  it("crea la invitación del dueño con 201 y luego responde 409", async () => {
    const env = await freshEnv();
    const res = await call(env, "POST", "/v1/operator/bootstrap", { auth: OP, body: { email: " Duena@Ejemplo.test " } });
    assert.equal(res.status, 201);
    const body = (await res.json()) as { invitation: Record<string, string>; link: string };
    assert.deepEqual(Object.keys(body.invitation).sort(), ["email", "expires_at", "id", "kind"]);
    assert.equal(body.invitation.kind, "owner_bootstrap");
    assert.equal(body.invitation.email, "Duena@Ejemplo.test");
    const token = tokenFrom(body.link);
    const inv = await row(env, "SELECT * FROM invitations WHERE id = ?", body.invitation.id!);
    assert.equal(inv?.token_hash, await sha256Hex(token));
    assert.equal(inv?.role, "owner");
    assert.equal(inv?.email_normalized, "duena@ejemplo.test");
    assert.equal(inv?.created_by, null);
    const ttl = Date.parse(String(inv?.expires_at)) - Date.parse(String(inv?.created_at));
    assert.equal(ttl, 24 * 3600_000);
    assert.equal(JSON.stringify(await rows(env, "SELECT * FROM audit_log")).includes(token), false);
    assert.equal((await row(env, "SELECT count(*) AS c FROM audit_log WHERE action = 'operator.bootstrap' AND result = 'ok'"))?.c, 1);

    const again = await call(env, "POST", "/v1/operator/bootstrap", { auth: OP, body: { email: "duena@ejemplo.test" } });
    assert.equal(again.status, 201);
    const pending = await rows(env, "SELECT id FROM invitations WHERE kind = 'owner_bootstrap' AND revoked_at IS NULL");
    assert.equal(pending.length, 1);
    assert.notEqual(pending[0]!.id, body.invitation.id);

    await addUser(env, "duena@ejemplo.test", "owner");
    const conflict = await call(env, "POST", "/v1/operator/bootstrap", { auth: OP, body: { email: "otra@ejemplo.test" } });
    assert.equal(conflict.status, 409);
    assert.equal(((await conflict.json()) as { code: string }).code, "conflict");
  });

  it("rechaza correo inválido, secret ausente o incorrecto y operador sin configurar", async () => {
    const env = await freshEnv();
    const bad = await call(env, "POST", "/v1/operator/bootstrap", { auth: OP, body: { email: "no-es-correo" } });
    assert.equal(bad.status, 400);
    assert.equal(((await bad.json()) as { field: string }).field, "email");
    assert.equal((await call(env, "POST", "/v1/operator/bootstrap", { body: { email: "a@b.test" } })).status, 401);
    assert.equal((await call(env, "POST", "/v1/operator/bootstrap", { auth: "Bearer otro", body: { email: "a@b.test" } })).status, 401);
    const { RELAY_OPERATOR_TOKEN: _, ...disabled } = env;
    const off = await call(disabled, "POST", "/v1/operator/bootstrap", { auth: OP, body: { email: "a@b.test" } });
    assert.equal(off.status, 503);
    assert.equal(((await off.json()) as { code: string }).code, "internal");
    assert.equal((await rows(env, "SELECT id FROM invitations")).length, 0);
  });

  it("el secret de operador no vale fuera de /v1/operator/*", async () => {
    const env = await freshEnv();
    assert.equal((await call(env, "POST", "/v1/auth/recovery-code", { auth: OP, body: { password: "x" } })).status, 401);
  });
});

describe("POST /v1/operator/recover", () => {
  it("sin dueño responde 409", async () => {
    const env = await freshEnv();
    const res = await call(env, "POST", "/v1/operator/recover", { auth: OP, body: {} });
    assert.equal(res.status, 409);
    assert.equal((await row(env, "SELECT count(*) AS c FROM invitations"))?.c, 0);
  });

  it("crea una owner_reset de 1 h para el correo del dueño y revoca la anterior", async () => {
    const env = await freshEnv();
    await addUser(env, "Duena@Ejemplo.test", "owner");
    const first = (await (await call(env, "POST", "/v1/operator/recover", { auth: OP, body: {} })).json()) as { invitation: { id: string } };
    const res = await call(env, "POST", "/v1/operator/recover", { auth: OP, body: {} });
    assert.equal(res.status, 201);
    const body = (await res.json()) as { invitation: Record<string, string>; link: string };
    assert.equal(body.invitation.kind, "owner_reset");
    assert.equal(body.invitation.email, "Duena@Ejemplo.test");
    const inv = await row(env, "SELECT * FROM invitations WHERE id = ?", body.invitation.id!);
    assert.equal(inv?.token_hash, await sha256Hex(tokenFrom(body.link)));
    assert.equal(Date.parse(String(inv?.expires_at)) - Date.parse(String(inv?.created_at)), 3600_000);
    assert.notEqual((await row(env, "SELECT revoked_at FROM invitations WHERE id = ?", first.invitation.id))?.revoked_at, null);
    assert.equal((await row(env, "SELECT count(*) AS c FROM audit_log WHERE action = 'operator.recover' AND result = 'ok'"))?.c, 2);
  });
});

describe("límite op:", () => {
  it("5 fallos en 10 min bloquean la IP 60 min, incluso con el secret correcto", async () => {
    const env = await freshEnv();
    for (let i = 0; i < 5; i++) {
      assert.equal((await call(env, "POST", "/v1/operator/recover", { auth: "Bearer malo", body: {} })).status, 401);
    }
    const locked = await call(env, "POST", "/v1/operator/recover", { auth: OP, body: {} });
    assert.equal(locked.status, 429);
    const retry = Number(locked.headers.get("Retry-After"));
    assert.ok(retry > 3500 && retry <= 3600, String(retry));
    assert.equal(((await locked.json()) as { retry_after_s: number }).retry_after_s, retry);
    const key = `op:${await sha256Hex("203.0.113.7")}`;
    assert.equal((await row(env, "SELECT failures FROM auth_attempts WHERE key_hash = ?", key))?.failures, 5);
    assert.equal((await call(env, "POST", "/v1/operator/recover", { auth: OP, body: {}, ip: "198.51.100.1" })).status, 409);
  });

  it("los fallos fuera de la ventana de 10 min reinician la cuenta", async () => {
    const env = await freshEnv();
    for (let i = 0; i < 4; i++) await call(env, "POST", "/v1/operator/recover", { auth: "Bearer malo", body: {} });
    const old = new Date(Date.now() - 11 * 60_000).toISOString();
    await env.DB.prepare("UPDATE auth_attempts SET window_start = ?1, updated_at = ?1").bind(old).run();
    await call(env, "POST", "/v1/operator/recover", { auth: "Bearer malo", body: {} });
    assert.equal((await call(env, "POST", "/v1/operator/recover", { auth: OP, body: {} })).status, 409);
  });
});
