import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { resolvePrincipal } from "../src/auth.ts";
import { hashPassword, pepperFromEnv, sha256Hex } from "../src/crypto.ts";
import { applyMigrations, now, uuid } from "../src/db.ts";
import worker, { type Env } from "../src/index.ts";
import { verifyMachine } from "../src/machines.ts";
import { FakeD1Database } from "./d1.ts";

const API = "https://api.chopshop.novarix.online";
const SECRET = "pepper-de-prueba-0123456789abcdefghij";
const PEPPER = pepperFromEnv({ PASSWORD_PEPPER: SECRET });
const PASSWORD = "caballo bateria grapa";
const OWNER_EMAIL = "duenia@ejemplo.test";
const WATCHER_EMAIL = "mirona@ejemplo.test";
const DAY = 24 * 60 * 60 * 1000;
const DIR = new URL("../migrations/", import.meta.url);

type Json = Record<string, unknown>;

let env: Env;
let changes: [string, Json][];
let online: string[];
let ownerId: string;
let ownerToken: string;

function migrations(): string[] {
  return readdirSync(DIR)
    .filter((f) => /^\d{4}_.+\.sql$/.test(f))
    .sort()
    .map((f) => readFileSync(new URL(f, DIR), "utf8"));
}

function db(): D1Database {
  return env.DB!;
}

async function addUser(email: string, role: "owner" | "watcher"): Promise<string> {
  const id = uuid();
  const t = now();
  await db()
    .prepare(
      "INSERT INTO users (id, email, email_normalized, password_hash, role, status, password_changed_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?)",
    )
    .bind(id, email, email, await hashPassword(PASSWORD, PEPPER), role, t, t, t)
    .run();
  return id;
}

async function addWorkspace(slug: string, position: number, archived = false): Promise<string> {
  const id = uuid();
  const t = now();
  await db()
    .prepare("INSERT INTO workspaces (id, owner_id, name, slug, position, created_at, updated_at, archived_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    .bind(id, ownerId, slug, slug, position, t, t, archived ? t : null)
    .run();
  return id;
}

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

async function login(email: string): Promise<string> {
  const res = await call("/v1/auth/login", { method: "POST", body: { email, password: PASSWORD, client: "mac", device_name: "Mac mini" } });
  assert.equal(res.status, 200);
  return ((await res.json()) as Json).token as string;
}

async function link(body: Json, token = ownerToken): Promise<Response> {
  return call("/v1/machines/link", { method: "POST", token, body });
}

async function issued(res: Response, status = 201): Promise<{ machine: Json; credential: string; api_url: string }> {
  assert.equal(res.status, status);
  return (await res.json()) as { machine: Json; credential: string; api_url: string };
}

async function auditActions(machineId: string): Promise<string[]> {
  const rows = await db().prepare("SELECT action FROM audit_log WHERE machine_id = ? ORDER BY at, rowid").bind(machineId).all<{ action: string }>();
  return rows.results.map((r) => r.action);
}

function connectReq(credential: string): Request {
  return new Request(`${API}/v1/connect`, { headers: { Authorization: `Bearer ${credential}` } });
}

beforeEach(async () => {
  changes = [];
  online = [];
  const d1 = new FakeD1Database().asD1();
  await applyMigrations(d1, migrations());
  env = {
    DB: d1,
    PASSWORD_PEPPER: SECRET,
    HUB: {
      idFromName: (name: string) => ({ name }) as unknown as DurableObjectId,
      get: () => ({
        sessionRevoked: async () => {},
        machineChanged: async (id: string, change: Json) => void changes.push([id, change]),
        online: async () => online,
      }),
    },
  };
  ownerId = await addUser(OWNER_EMAIL, "owner");
  ownerToken = await login(OWNER_EMAIL);
});

afterEach(() => {
  mock.restoreAll();
  mock.timers.reset();
});

describe("crear máquinas", () => {
  it("link devuelve la credencial solo en la respuesta de creación", async () => {
    const w1 = await addWorkspace("uno", 1);
    const w0 = await addWorkspace("cero", 0);
    await addWorkspace("viejo", 2, true);
    const b = await issued(await link({ local_machine_id: "mac-mini.local", name: " mac-mini ", platform: "macos" }));
    assert.match(b.credential, /^cm1_[A-Za-z0-9_-]{43}$/);
    assert.equal(b.api_url, API);
    assert.equal(b.machine.name, "mac-mini");
    assert.equal(b.machine.linked_via, "app");
    assert.equal(b.machine.local_machine_id, "mac-mini.local");
    assert.equal(b.machine.online, false);
    assert.deepEqual(b.machine.workspace_ids, [w0, w1]);
    assert.deepEqual(Object.keys(b.machine).sort(), [
      "agent_version", "created_at", "id", "last_seen_at", "linked_via", "local_machine_id", "name", "online", "paused_at", "platform", "revoked_at", "workspace_ids",
    ]);

    const stored = await db().prepare("SELECT credential_hash, created_by_session FROM machines WHERE id = ?").bind(b.machine.id as string).first<Json>();
    assert.equal(stored?.credential_hash, await sha256Hex(b.credential));
    assert.notEqual(stored?.created_by_session, null);

    const listed = await call("/v1/machines", { token: ownerToken });
    const one = await call(`/v1/machines/${b.machine.id}`, { token: ownerToken });
    const audits = await db().prepare("SELECT detail FROM audit_log").all<{ detail: string }>();
    for (const text of [await listed.text(), await one.text(), ...audits.results.map((r) => r.detail)]) {
      assert.ok(!text.includes(b.credential));
      assert.ok(!text.includes("cm1_"));
    }
  });

  it("token para VPS: linked_via token, sin local_machine_id y con los workspaces pedidos", async () => {
    const w = await addWorkspace("uno", 0);
    await addWorkspace("dos", 1);
    const b = await issued(await call("/v1/machines", { method: "POST", token: ownerToken, body: { name: "contabo", platform: "linux", workspace_ids: [w] } }));
    assert.equal(b.machine.linked_via, "token");
    assert.equal(b.machine.local_machine_id, null);
    assert.deepEqual(b.machine.workspace_ids, [w]);
    assert.deepEqual(await auditActions(b.machine.id as string), ["machine.token_issued"]);
    assert.deepEqual(await verifyMachine(db(), b.credential), { machineId: b.machine.id, localMachineId: null, name: "contabo", paused: false });
  });

  it("valida el cuerpo y los workspaces", async () => {
    const archived = await addWorkspace("viejo", 0, true);
    const cases: [Json, number, string][] = [
      [{ local_machine_id: "con espacio", name: "a", platform: "macos" }, 400, "local_machine_id"],
      [{ local_machine_id: "a", name: "", platform: "macos" }, 400, "name"],
      [{ local_machine_id: "a", name: "x".repeat(65), platform: "macos" }, 400, "name"],
      [{ local_machine_id: "a", name: "a", platform: "windows" }, 400, "platform"],
      [{ local_machine_id: "a", name: "a", platform: "macos", workspace_ids: "x" }, 400, "workspace_ids"],
      [{ local_machine_id: "a", name: "a", platform: "macos", workspace_ids: [archived] }, 404, "workspace_ids"],
      [{ local_machine_id: "a", name: "a", platform: "macos", workspace_ids: [uuid()] }, 404, "workspace_ids"],
    ];
    for (const [body, status, field] of cases) {
      const res = await link(body);
      assert.equal(res.status, status, JSON.stringify(body));
      assert.equal(((await res.json()) as Json).field, field);
    }
    assert.equal((await db().prepare("SELECT COUNT(*) AS n FROM machines").first<{ n: number }>())?.n, 0);
  });

  it("link revoca la máquina anterior con el mismo local_machine_id", async () => {
    const first = await issued(await link({ local_machine_id: "mbp", name: "MacBook Air", platform: "macos" }));
    const other = await issued(await link({ local_machine_id: "otra", name: "Otra", platform: "macos" }));
    const second = await issued(await link({ local_machine_id: "mbp", name: "MacBook Air", platform: "macos" }));
    assert.notEqual(second.machine.id, first.machine.id);
    assert.equal(await verifyMachine(db(), first.credential), null);
    assert.notEqual(await verifyMachine(db(), second.credential), null);
    assert.notEqual(await verifyMachine(db(), other.credential), null);
    assert.deepEqual(changes, [[first.machine.id, { revoked: true }]]);
    assert.deepEqual(await auditActions(first.machine.id as string), ["machine.linked", "machine.revoked"]);
    const old = (await (await call(`/v1/machines/${first.machine.id}`, { token: ownerToken })).json()) as { machine: Json };
    assert.notEqual(old.machine.revoked_at, null);
  });
});

describe("listar y renombrar", () => {
  it("lista con online del Hub y oculta las revocadas hace más de 30 días", async () => {
    const a = await issued(await link({ local_machine_id: "a", name: "a", platform: "macos" }));
    const b = await issued(await link({ local_machine_id: "b", name: "b", platform: "linux" }));
    const c = await issued(await link({ local_machine_id: "c", name: "c", platform: "other" }));
    await db().prepare("UPDATE machines SET revoked_at = ? WHERE id = ?").bind(new Date(Date.now() - 31 * DAY).toISOString(), c.machine.id as string).run();
    await call(`/v1/machines/${b.machine.id}/revoke`, { method: "POST", token: ownerToken });
    online = [a.machine.id as string, b.machine.id as string];
    const res = await call("/v1/machines", { token: ownerToken });
    assert.equal(res.status, 200);
    const machines = ((await res.json()) as { machines: Json[] }).machines;
    assert.deepEqual(machines.map((m) => [m.id, m.online]), [[a.machine.id, true], [b.machine.id, false]]);
  });

  it("renombra; id desconocido da 404", async () => {
    const a = await issued(await link({ local_machine_id: "a", name: "a", platform: "macos" }));
    const res = await call(`/v1/machines/${a.machine.id}`, { method: "PATCH", token: ownerToken, body: { name: "estudio" } });
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as { machine: Json }).machine.name, "estudio");
    assert.equal((await verifyMachine(db(), a.credential))?.name, "estudio");
    assert.equal((await call(`/v1/machines/${a.machine.id}`, { method: "PATCH", token: ownerToken, body: { name: " " } })).status, 400);
    assert.equal((await call(`/v1/machines/${uuid()}`, { method: "PATCH", token: ownerToken, body: { name: "x" } })).status, 404);
    assert.equal((await call(`/v1/machines/${uuid()}`, { token: ownerToken })).status, 404);
  });
});

describe("pausar, reanudar y revocar", () => {
  it("pausada → verifyMachine paused: true; reanudar lo quita", async () => {
    const a = await issued(await link({ local_machine_id: "a", name: "a", platform: "macos" }));
    const id = a.machine.id as string;
    const paused = await call(`/v1/machines/${id}/pause`, { method: "POST", token: ownerToken });
    assert.equal(paused.status, 200);
    assert.notEqual(((await paused.json()) as { machine: Json }).machine.paused_at, null);
    assert.equal((await verifyMachine(db(), a.credential))?.paused, true);
    assert.deepEqual(await resolvePrincipal(connectReq(a.credential), env), { kind: "machine", machineId: id, localMachineId: "a", paused: true });
    assert.equal((await call(`/v1/machines/${id}/pause`, { method: "POST", token: ownerToken })).status, 200);

    const resumed = await call(`/v1/machines/${id}/resume`, { method: "POST", token: ownerToken });
    assert.equal(resumed.status, 200);
    assert.equal(((await resumed.json()) as { machine: Json }).machine.paused_at, null);
    assert.equal((await verifyMachine(db(), a.credential))?.paused, false);
    assert.deepEqual(changes, [[id, { paused: true }], [id, { paused: false }]]);
    assert.deepEqual(await auditActions(id), ["machine.linked", "machine.paused", "machine.resumed"]);
  });

  it("revocada → verifyMachine null, 401 con la credencial, 410 al pausar y revocar es idempotente", async () => {
    const a = await issued(await link({ local_machine_id: "a", name: "a", platform: "macos" }));
    const id = a.machine.id as string;
    assert.equal((await call(`/v1/machines/${id}/revoke`, { method: "POST", token: ownerToken })).status, 204);
    assert.equal(await verifyMachine(db(), a.credential), null);
    assert.equal(await verifyMachine(db(), `Bearer ${a.credential}`), null);
    const denied = await resolvePrincipal(connectReq(a.credential), env);
    assert.ok(denied instanceof Response);
    assert.equal(denied.status, 401);
    assert.equal((await call(`/v1/machines/${id}/pause`, { method: "POST", token: ownerToken })).status, 410);
    assert.equal((await call(`/v1/machines/${id}/resume`, { method: "POST", token: ownerToken })).status, 410);
    assert.equal((await call(`/v1/machines/${id}/revoke`, { method: "POST", token: ownerToken })).status, 204);
    assert.equal((await call(`/v1/machines/${uuid()}/revoke`, { method: "POST", token: ownerToken })).status, 404);
    assert.deepEqual(changes, [[id, { revoked: true }]]);
    const audits = await db()
      .prepare("SELECT action, actor_kind, actor_user_id, target_kind, target_id, status FROM audit_log WHERE machine_id = ? ORDER BY at, rowid")
      .bind(id)
      .all<Json>();
    assert.deepEqual(audits.results.at(-1), { action: "machine.revoked", actor_kind: "user", actor_user_id: ownerId, target_kind: "machine", target_id: id, status: 204 });
    assert.equal(audits.results.length, 2);
  });

  it("verifyMachine acepta Bearer y rechaza formatos ajenos", async () => {
    const a = await issued(await link({ local_machine_id: "a", name: "a", platform: "macos" }));
    assert.equal((await verifyMachine(db(), `Bearer ${a.credential}`))?.machineId, a.machine.id);
    assert.equal(await verifyMachine(db(), ownerToken), null);
    assert.equal(await verifyMachine(db(), "cm1_corto"), null);
  });
});

describe("permisos", () => {
  it("watcher recibe 403 y la credencial de máquina no sirve en /v1/machines", async () => {
    await addUser(WATCHER_EMAIL, "watcher");
    const watcher = await login(WATCHER_EMAIL);
    const a = await issued(await link({ local_machine_id: "a", name: "a", platform: "macos" }));
    const id = a.machine.id as string;
    for (const [method, path, body] of [
      ["GET", "/v1/machines", undefined],
      ["POST", "/v1/machines/link", { local_machine_id: "b", name: "b", platform: "macos" }],
      ["POST", "/v1/machines", { name: "b", platform: "linux" }],
      ["GET", `/v1/machines/${id}`, undefined],
      ["PATCH", `/v1/machines/${id}`, { name: "b" }],
      ["POST", `/v1/machines/${id}/pause`, undefined],
      ["POST", `/v1/machines/${id}/resume`, undefined],
      ["POST", `/v1/machines/${id}/revoke`, undefined],
    ] as const) {
      assert.equal((await call(path, { method, token: watcher, body })).status, 403, `${method} ${path}`);
      assert.equal((await call(path, { method, token: a.credential, body })).status, 403, `${method} ${path}`);
      assert.equal((await call(path, { method, body })).status, 401, `${method} ${path}`);
    }
    assert.equal((await verifyMachine(db(), a.credential))?.paused, false);
    assert.equal((await db().prepare("SELECT COUNT(*) AS n FROM machines").first<{ n: number }>())?.n, 1);
  });
});
