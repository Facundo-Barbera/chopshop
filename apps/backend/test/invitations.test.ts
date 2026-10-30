import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { sha256Hex } from "../src/crypto.ts";
import { now, run, uuid } from "../src/db.ts";
import worker, { type Env } from "../src/index.ts";
import { OPERATOR_SECRET, addSession, addUser, call as operatorCall, freshEnv, row, rows } from "./accounts.ts";

const API = "https://api.chopshop.novarix.online";
const LINK = /^https:\/\/chopshop\.novarix\.online\/invite#t=(ci1_[A-Za-z0-9_-]{43})$/;
const PASSWORD = "caballo bateria grapa";
const T0 = Date.parse("2026-10-30T12:00:00.000Z");

type Json = Record<string, unknown>;

let env: Env & { DB: D1Database };
let hubCalls: string[];
let ownerId: string;
let ownerToken: string;
let workspaceId: string;

async function call(path: string, init: { method?: string; token?: string; body?: unknown; ip?: string } = {}): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": init.ip ?? "203.0.113.7" };
  if (init.token !== undefined) headers.Authorization = `Bearer ${init.token}`;
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  const req = new Request(`${API}${path}`, {
    method: init.method ?? "GET",
    headers,
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  });
  return worker.fetch(req, env);
}

async function addWorkspace(name: string, archived = false): Promise<string> {
  const id = uuid();
  const t = now();
  await run(
    env.DB,
    "INSERT INTO workspaces (id, owner_id, name, slug, created_at, updated_at, archived_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    id,
    ownerId,
    name,
    name.toLowerCase(),
    t,
    t,
    archived ? t : null,
  );
  return id;
}

function tokenOf(link: unknown): string {
  const m = LINK.exec(String(link));
  assert.ok(m, String(link));
  return m[1]!;
}

async function invite(email: string, workspaceIds = [workspaceId], ttl_h?: number): Promise<{ id: string; token: string; body: Json }> {
  const res = await call("/v1/invitations", { method: "POST", token: ownerToken, body: { email, workspace_ids: workspaceIds, ...(ttl_h ? { ttl_h } : {}) } });
  assert.equal(res.status, 201);
  const body = (await res.json()) as Json;
  return { id: (body.invitation as Json).id as string, token: tokenOf(body.link), body };
}

function accept(token: string, extra: Json = {}): Promise<Response> {
  return call("/v1/invitations/accept", { method: "POST", body: { token, password: PASSWORD, device_name: "MacBook Air", client: "mac", ...extra } });
}

beforeEach(async () => {
  hubCalls = [];
  const base = await freshEnv();
  env = {
    ...base,
    HUB: {
      idFromName: (name: string) => ({ name }) as unknown as DurableObjectId,
      get: () => ({
        sessionRevoked: async (id: string) => void hubCalls.push(`session:${id}`),
        viewerChanged: async (id: string) => void hubCalls.push(`viewer:${id}`),
      }),
    },
  };
  ownerId = await addUser(env, "duena@ejemplo.test", "owner");
  ownerToken = (await addSession(env, ownerId)).token;
  workspaceId = await addWorkspace("Acme");
});

afterEach(() => {
  mock.restoreAll();
  mock.timers.reset();
});

describe("POST /v1/invitations", () => {
  it("crea la invitación watcher con link de fragmento y solo guarda el hash", async () => {
    const { id, token, body } = await invite(" Ana@Ejemplo.test ");
    const inv = body.invitation as Json;
    assert.deepEqual(Object.keys(inv).sort(), ["created_at", "email", "expires_at", "id", "kind", "revoked_at", "role", "status", "used_at", "workspace_ids"]);
    assert.equal(inv.email, "Ana@Ejemplo.test");
    assert.equal(inv.kind, "watcher");
    assert.equal(inv.status, "pending");
    assert.deepEqual(inv.workspace_ids, [workspaceId]);
    assert.equal(Date.parse(inv.expires_at as string) - Date.parse(inv.created_at as string), 168 * 3600_000);
    const stored = await row(env, "SELECT token_hash, email_normalized, created_by FROM invitations WHERE id = ?", id);
    assert.equal(stored?.token_hash, await sha256Hex(token));
    assert.equal(stored?.email_normalized, "ana@ejemplo.test");
    assert.equal(stored?.created_by, ownerId);
    assert.equal(JSON.stringify(await rows(env, "SELECT * FROM audit_log")).includes(token), false);
  });

  it("valida correo, workspaces, ttl y usuario existente", async () => {
    const post = (body: Json) => call("/v1/invitations", { method: "POST", token: ownerToken, body });
    assert.equal((await post({ email: "x", workspace_ids: [workspaceId] })).status, 400);
    assert.equal((await post({ email: "a@b.test", workspace_ids: [] })).status, 400);
    assert.equal((await post({ email: "a@b.test", workspace_ids: [workspaceId], ttl_h: 721 })).status, 400);
    assert.equal((await post({ email: "a@b.test", workspace_ids: [uuid()] })).status, 404);
    assert.equal((await post({ email: "a@b.test", workspace_ids: [await addWorkspace("Vieja", true)] })).status, 404);
    assert.equal((await post({ email: "DUENA@ejemplo.test", workspace_ids: [workspaceId] })).status, 409);
    assert.equal((await row(env, "SELECT count(*) AS c FROM invitations"))?.c, 0);
  });

  it("un watcher no puede invitar ni listar", async () => {
    const watcher = await addUser(env, "mira@ejemplo.test", "watcher");
    const { token } = await addSession(env, watcher);
    assert.equal((await call("/v1/invitations", { method: "POST", token, body: { email: "a@b.test", workspace_ids: [workspaceId] } })).status, 403);
    assert.equal((await call("/v1/invitations", { token })).status, 403);
  });
});

describe("listar, reemitir y revocar", () => {
  it("lista con estados pending, used, revoked y expired sin tokens", async () => {
    const a = await invite("a@ejemplo.test");
    const b = await invite("b@ejemplo.test");
    const c = await invite("c@ejemplo.test", [workspaceId], 1);
    await invite("d@ejemplo.test");
    assert.equal((await accept(a.token)).status, 201);
    assert.equal((await call(`/v1/invitations/${b.id}`, { method: "DELETE", token: ownerToken })).status, 204);
    await run(env.DB, "UPDATE invitations SET expires_at = ? WHERE id = ?", "2000-01-01T00:00:00.000Z", c.id);
    const res = await call("/v1/invitations", { token: ownerToken });
    assert.equal(res.status, 200);
    const text = await res.text();
    for (const t of [a.token, b.token, c.token]) assert.equal(text.includes(t), false);
    const list = (JSON.parse(text) as { invitations: Json[] }).invitations;
    const byEmail = Object.fromEntries(list.map((i) => [i.email, i.status]));
    assert.deepEqual(byEmail, { "a@ejemplo.test": "used", "b@ejemplo.test": "revoked", "c@ejemplo.test": "expired", "d@ejemplo.test": "pending" });
  });

  it("reissue invalida el enlace anterior y el nuevo funciona", async () => {
    const first = await invite("ana@ejemplo.test");
    const res = await call(`/v1/invitations/${first.id}/reissue`, { method: "POST", token: ownerToken, body: { ttl_h: 2 } });
    assert.equal(res.status, 200);
    const body = (await res.json()) as Json;
    const second = tokenOf(body.link);
    assert.notEqual(second, first.token);
    const inv = body.invitation as Json;
    assert.equal(inv.id, first.id);
    assert.equal(Date.parse(inv.expires_at as string) - Date.parse(inv.created_at as string) >= 2 * 3600_000, true);
    assert.equal((await call("/v1/invitations/inspect", { method: "POST", body: { token: first.token } })).status, 401);
    assert.equal((await accept(first.token)).status, 401);
    assert.equal((await call("/v1/invitations/inspect", { method: "POST", body: { token: second } })).status, 200);
    assert.equal((await accept(second)).status, 201);
  });

  it("reissue sin cuerpo, de una caducada; usada o revocada da 410; inexistente 404", async () => {
    const a = await invite("a@ejemplo.test");
    await run(env.DB, "UPDATE invitations SET expires_at = ? WHERE id = ?", "2000-01-01T00:00:00.000Z", a.id);
    const ok = await call(`/v1/invitations/${a.id}/reissue`, { method: "POST", token: ownerToken });
    assert.equal(ok.status, 200);
    assert.equal(((await ok.json()) as { invitation: Json }).invitation.status, "pending");
    assert.equal((await accept(tokenOf(((await (await call(`/v1/invitations/${a.id}/reissue`, { method: "POST", token: ownerToken })).json()) as Json).link))).status, 201);
    assert.equal((await call(`/v1/invitations/${a.id}/reissue`, { method: "POST", token: ownerToken })).status, 410);
    const b = await invite("b@ejemplo.test");
    await call(`/v1/invitations/${b.id}`, { method: "DELETE", token: ownerToken });
    assert.equal((await call(`/v1/invitations/${b.id}/reissue`, { method: "POST", token: ownerToken })).status, 410);
    assert.equal((await call(`/v1/invitations/${uuid()}/reissue`, { method: "POST", token: ownerToken })).status, 404);
    assert.equal((await call(`/v1/invitations/${uuid()}`, { method: "DELETE", token: ownerToken })).status, 404);
  });
});

describe("inspect y accept", () => {
  it("inspect muestra correo, tipo y workspaces sin consumir la invitación", async () => {
    const other = await addWorkspace("Beta");
    const { token } = await invite("ana@ejemplo.test", [workspaceId, other]);
    const res = await call("/v1/invitations/inspect", { method: "POST", body: { token } });
    assert.equal(res.status, 200);
    const body = (await res.json()) as Json;
    assert.equal(body.email, "ana@ejemplo.test");
    assert.equal(body.kind, "watcher");
    assert.equal(body.role, "watcher");
    assert.deepEqual((body.workspaces as Json[]).map((w) => w.name).sort(), ["Acme", "Beta"]);
    assert.equal((await call("/v1/invitations/inspect", { method: "POST", body: { token } })).status, 200);
  });

  it("accept watcher crea el usuario, sus membresías y una sesión", async () => {
    const other = await addWorkspace("Beta");
    const { id, token } = await invite("Ana@Ejemplo.test", [workspaceId, other]);
    const res = await accept(token, { display_name: "Ana" });
    assert.equal(res.status, 201);
    const body = (await res.json()) as Json;
    assert.match(body.token as string, /^ss1_[A-Za-z0-9_-]{43}$/);
    assert.equal(body.recovery_code, undefined);
    const user = body.user as Json;
    assert.equal(user.role, "watcher");
    assert.equal(user.display_name, "Ana");
    assert.equal(user.email, "Ana@Ejemplo.test");
    const members = await rows(env, "SELECT workspace_id, added_by FROM workspace_members WHERE user_id = ? ORDER BY workspace_id", user.id as string);
    assert.deepEqual(members.map((m) => m.workspace_id), [workspaceId, other].sort());
    assert.ok(members.every((m) => m.added_by === ownerId));
    const inv = await row(env, "SELECT used_at, used_by FROM invitations WHERE id = ?", id);
    assert.equal(inv?.used_by, user.id);
    assert.notEqual(inv?.used_at, null);
    const stored = await row(env, "SELECT password_hash, invited_by FROM users WHERE id = ?", user.id as string);
    assert.match(String(stored?.password_hash), /^pbkdf2-sha256-p1\$10000\$/);
    assert.equal(stored?.invited_by, ownerId);
    const me = await call("/v1/auth/me", { token: body.token as string });
    assert.equal(me.status, 200);
    const login = await call("/v1/auth/login", { method: "POST", body: { email: "ana@ejemplo.test", password: PASSWORD, client: "cli", device_name: "vps" } });
    assert.equal(login.status, 200);
  });

  it("accept web devuelve cookie y csrf sin token en el cuerpo", async () => {
    const { token } = await invite("ana@ejemplo.test");
    const res = await accept(token, { client: "web" });
    assert.equal(res.status, 201);
    assert.match(res.headers.get("Set-Cookie") ?? "", /^__Host-chopshop_session=ss1_/);
    const body = (await res.json()) as Json;
    assert.equal(body.token, undefined);
    assert.match(body.csrf_token as string, /^cx1_/);
  });

  it("410 con invitación usada, revocada o caducada; 401 con token desconocido", async () => {
    const used = await invite("a@ejemplo.test");
    assert.equal((await accept(used.token)).status, 201);
    const again = await accept(used.token);
    assert.equal(again.status, 410);
    assert.equal(((await again.json()) as Json).code, "gone");
    assert.equal((await call("/v1/invitations/inspect", { method: "POST", body: { token: used.token } })).status, 410);

    const revoked = await invite("b@ejemplo.test");
    await call(`/v1/invitations/${revoked.id}`, { method: "DELETE", token: ownerToken });
    assert.equal((await accept(revoked.token)).status, 410);

    mock.timers.enable({ apis: ["Date"], now: T0 });
    const expired = await invite("c@ejemplo.test", [workspaceId], 1);
    mock.timers.tick(3600_000);
    assert.equal((await accept(expired.token)).status, 410);
    assert.equal((await call("/v1/invitations/inspect", { method: "POST", body: { token: expired.token } })).status, 410);
    assert.equal((await row(env, "SELECT count(*) AS c FROM users WHERE email_normalized IN ('b@ejemplo.test', 'c@ejemplo.test')"))?.c, 0);

    const unknown = await accept(`ci1_${"A".repeat(43)}`);
    assert.equal(unknown.status, 401);
    assert.equal((await accept("no-es-token")).status, 401);
  });

  it("valida contraseña, client y device_name antes de consumir", async () => {
    const { id, token } = await invite("anabel@ejemplo.test");
    const short = await accept(token, { password: "corta" });
    assert.equal(short.status, 400);
    assert.equal(((await short.json()) as Json).field, "password");
    assert.equal((await accept(token, { password: "soy ANABEL y esta es mi clave" })).status, 400);
    assert.equal((await accept(token, { client: "tv" })).status, 400);
    assert.equal((await accept(token, { device_name: "" })).status, 400);
    assert.equal((await row(env, "SELECT used_at FROM invitations WHERE id = ?", id))?.used_at, null);
  });

  it("límite inv: por IP bloquea inspect y accept antes de derivar", async () => {
    const { token } = await invite("ana@ejemplo.test");
    for (let i = 0; i < 9; i++) {
      assert.equal((await call("/v1/invitations/inspect", { method: "POST", ip: "198.51.100.9", body: { token: `ci1_${"B".repeat(43)}` } })).status, 401);
    }
    const blocked = await call("/v1/invitations/inspect", { method: "POST", ip: "198.51.100.9", body: { token: `ci1_${"B".repeat(43)}` } });
    assert.equal(blocked.status, 429);
    assert.ok(Number(blocked.headers.get("Retry-After")) > 0);
    const derive = mock.method(crypto.subtle, "deriveBits");
    const res = await call("/v1/invitations/accept", {
      method: "POST",
      ip: "198.51.100.9",
      body: { token, password: PASSWORD, device_name: "Mac", client: "mac" },
    });
    assert.equal(res.status, 429);
    assert.equal(derive.mock.callCount(), 0);
    derive.mock.restore();
    assert.equal((await accept(token)).status, 201);
  });

  it("owner_bootstrap crea el dueño, el workspace Personal y devuelve el código de recuperación", async () => {
    const base = await freshEnv();
    env = { ...env, DB: base.DB };
    const boot = await operatorCall(env, "POST", "/v1/operator/bootstrap", { auth: `Bearer ${OPERATOR_SECRET}`, body: { email: "Jefa@Ejemplo.test" } });
    assert.equal(boot.status, 201);
    const token = tokenOf(((await boot.json()) as Json).link);
    const insp = (await (await call("/v1/invitations/inspect", { method: "POST", body: { token } })).json()) as Json;
    assert.equal(insp.kind, "owner_bootstrap");
    assert.deepEqual(insp.workspaces, []);
    const res = await accept(token);
    assert.equal(res.status, 201);
    const body = (await res.json()) as Json;
    assert.match(body.recovery_code as string, /^[0-9A-Z]{5}(-[0-9A-Z]{5}){3}$/);
    const user = body.user as Json;
    assert.equal(user.role, "owner");
    const stored = await row(env, "SELECT recovery_hash FROM users WHERE id = ?", user.id as string);
    assert.equal(stored?.recovery_hash, await sha256Hex((body.recovery_code as string).replace(/-/g, "")));
    const ws = await rows(env, "SELECT id, name, slug FROM workspaces WHERE owner_id = ?", user.id as string);
    assert.deepEqual(ws.map((w) => [w.name, w.slug]), [["Personal", "personal"]]);
    assert.equal((await row(env, "SELECT count(*) AS c FROM campus_layouts WHERE workspace_id = ?", ws[0]!.id as string))?.c, 1);
    assert.equal((await call("/v1/auth/me", { token: body.token as string })).status, 200);
  });

  it("owner_bootstrap con un dueño ya creado responde 409", async () => {
    const base = await freshEnv();
    env = { ...env, DB: base.DB };
    const boot = await operatorCall(env, "POST", "/v1/operator/bootstrap", { auth: `Bearer ${OPERATOR_SECRET}`, body: { email: "jefa@ejemplo.test" } });
    const token = tokenOf(((await boot.json()) as Json).link);
    await addUser(env, "otra@ejemplo.test", "owner");
    assert.equal((await accept(token)).status, 409);
    assert.equal((await row(env, "SELECT count(*) AS c FROM users"))?.c, 1);
  });

  it("owner_reset cambia la contraseña, revoca las sesiones y genera código nuevo", async () => {
    await run(env.DB, "UPDATE users SET recovery_hash = 'viejo' WHERE id = ?", ownerId);
    const old = await addSession(env, ownerId);
    const reset = await operatorCall(env, "POST", "/v1/operator/recover", { auth: `Bearer ${OPERATOR_SECRET}`, body: {} });
    assert.equal(reset.status, 201);
    const token = tokenOf(((await reset.json()) as Json).link);
    const res = await accept(token, { password: "nueva contraseña del dueño" });
    assert.equal(res.status, 201);
    const body = (await res.json()) as Json;
    assert.equal((body.user as Json).id, ownerId);
    assert.ok(typeof body.recovery_code === "string");
    const revoked = await rows(env, "SELECT id, revoked_reason FROM sessions WHERE user_id = ? AND revoked_at IS NOT NULL ORDER BY id", ownerId);
    assert.deepEqual(revoked.map((s) => s.revoked_reason), ["recovered", "recovered"]);
    assert.deepEqual(hubCalls.sort(), [old.id, (await row(env, "SELECT id FROM sessions WHERE token_hash = ?", await sha256Hex(ownerToken)))?.id].map((i) => `session:${i}`).sort());
    assert.equal((await call("/v1/auth/me", { token: ownerToken })).status, 401);
    assert.equal((await call("/v1/auth/me", { token: body.token as string })).status, 200);
    assert.notEqual((await row(env, "SELECT recovery_hash FROM users WHERE id = ?", ownerId))?.recovery_hash, "viejo");
    const login = await call("/v1/auth/login", { method: "POST", body: { email: "duena@ejemplo.test", password: "nueva contraseña del dueño", client: "mac", device_name: "Mac" } });
    assert.equal(login.status, 200);
    assert.equal((await accept(token, { password: "nueva contraseña del dueño" })).status, 410);
  });
});
