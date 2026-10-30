import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";
import { now, run, uuid } from "../src/db.ts";
import worker, { type Env } from "../src/index.ts";
import { addSession, addUser, freshEnv, row } from "./accounts.ts";

const API = "https://api.chopshop.novarix.online";

type Json = Record<string, unknown>;

let env: Env & { DB: D1Database };
let hubCalls: string[];
let ownerId: string;
let ownerToken: string;

async function call(path: string, init: { method?: string; token?: string; body?: unknown } = {}): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": "203.0.113.7" };
  if (init.token !== undefined) headers.Authorization = `Bearer ${init.token}`;
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  const req = new Request(`${API}${path}`, {
    method: init.method ?? "GET",
    headers,
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  });
  return worker.fetch(req, env);
}

async function addMember(userId: string, name: string): Promise<string> {
  const id = uuid();
  const t = now();
  await run(env.DB, "INSERT INTO workspaces (id, owner_id, name, slug, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)", id, ownerId, name, name.toLowerCase(), t, t);
  await run(env.DB, "INSERT INTO workspace_members (workspace_id, user_id, added_by, created_at) VALUES (?, ?, ?, ?)", id, userId, ownerId, t);
  return id;
}

beforeEach(async () => {
  hubCalls = [];
  env = {
    ...(await freshEnv()),
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
});

describe("GET /v1/users", () => {
  it("lista usuarios con workspaces, último login y sesiones activas", async () => {
    const ana = await addUser(env, "ana@ejemplo.test", "watcher");
    const ws = await addMember(ana, "Acme");
    await addSession(env, ana);
    const revoked = await addSession(env, ana);
    await run(env.DB, "UPDATE sessions SET revoked_at = ? WHERE id = ?", now(), revoked.id);
    const res = await call("/v1/users", { token: ownerToken });
    assert.equal(res.status, 200);
    const users = ((await res.json()) as { users: Json[] }).users;
    assert.deepEqual(users.map((u) => u.email), ["duena@ejemplo.test", "ana@ejemplo.test"]);
    assert.deepEqual(Object.keys(users[1]!).sort(), ["created_at", "display_name", "email", "id", "last_login_at", "role", "sessions_active", "status", "workspace_ids"]);
    assert.deepEqual(users[1]!.workspace_ids, [ws]);
    assert.equal(users[1]!.sessions_active, 1);
    assert.equal(users[0]!.sessions_active, 1);
    assert.deepEqual(users[0]!.workspace_ids, []);
  });

  it("un watcher recibe 403 y GET de un id desconocido da 404", async () => {
    const ana = await addUser(env, "ana@ejemplo.test", "watcher");
    const { token } = await addSession(env, ana);
    assert.equal((await call("/v1/users", { token })).status, 403);
    assert.equal((await call(`/v1/users/${ana}`, { token })).status, 403);
    assert.equal((await call(`/v1/users/${uuid()}`, { token: ownerToken })).status, 404);
    const one = (await (await call(`/v1/users/${ana}`, { token: ownerToken })).json()) as { user: Json };
    assert.equal(one.user.email, "ana@ejemplo.test");
  });
});

describe("PATCH /v1/users/{id}", () => {
  it("desactivar revoca todas las sesiones y llama a viewerChanged", async () => {
    const ana = await addUser(env, "ana@ejemplo.test", "watcher");
    const ws = await addMember(ana, "Acme");
    const a = await addSession(env, ana);
    const b = await addSession(env, ana);
    const res = await call(`/v1/users/${ana}`, { method: "PATCH", token: ownerToken, body: { status: "disabled" } });
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as { user: Json }).user.status, "disabled");
    const sessions = await row(env, "SELECT count(*) AS c FROM sessions WHERE user_id = ? AND revoked_reason = 'user_disabled'", ana);
    assert.equal(sessions?.c, 2);
    assert.deepEqual([...hubCalls].sort(), [`session:${a.id}`, `session:${b.id}`, `viewer:${ana}`].sort());
    assert.equal(hubCalls.at(-1), `viewer:${ana}`);
    assert.equal((await call("/v1/auth/me", { token: a.token })).status, 401);
    assert.equal((await row(env, "SELECT count(*) AS c FROM workspace_members WHERE user_id = ? AND workspace_id = ?", ana, ws))?.c, 1);
    assert.equal((await row(env, "SELECT count(*) AS c FROM audit_log WHERE action = 'user.disabled' AND target_id = ?", ana))?.c, 1);

    const back = await call(`/v1/users/${ana}`, { method: "PATCH", token: ownerToken, body: { status: "active" } });
    assert.equal(back.status, 200);
    assert.equal((await call("/v1/auth/me", { token: a.token })).status, 401);
  });

  it("cambia display_name, rechaza el estado del dueño y cuerpos inválidos", async () => {
    const ana = await addUser(env, "ana@ejemplo.test", "watcher");
    const named = await call(`/v1/users/${ana}`, { method: "PATCH", token: ownerToken, body: { display_name: " Ana " } });
    assert.equal(((await named.json()) as { user: Json }).user.display_name, "Ana");
    assert.deepEqual(hubCalls, []);
    assert.equal((await call(`/v1/users/${ownerId}`, { method: "PATCH", token: ownerToken, body: { status: "disabled" } })).status, 409);
    assert.equal((await call(`/v1/users/${ownerId}`, { method: "PATCH", token: ownerToken, body: { display_name: "Dueña" } })).status, 200);
    assert.equal((await call(`/v1/users/${ana}`, { method: "PATCH", token: ownerToken, body: { status: "borrado" } })).status, 400);
    assert.equal((await call(`/v1/users/${ana}`, { method: "PATCH", token: ownerToken, body: {} })).status, 400);
    assert.equal((await call(`/v1/users/${uuid()}`, { method: "PATCH", token: ownerToken, body: { status: "disabled" } })).status, 404);
    assert.equal((await call("/v1/auth/me", { token: ownerToken })).status, 200);
  });
});
