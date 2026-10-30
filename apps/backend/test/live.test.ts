import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeState, FakeWebSocket } from "./do.ts";
import { revokeUserSessions } from "../src/auth.ts";
import { sha256Hex } from "../src/crypto.ts";
import { applyMigrations, now, uuid } from "../src/db.ts";
import { Hub } from "../src/hub.ts";
import worker, { type Env } from "../src/index.ts";
import { viewerChanged } from "../src/structure.ts";
import { FakeD1Database } from "./d1.ts";

const API = "https://api.chopshop.novarix.online";
const DIR = new URL("../migrations/", import.meta.url);
const FIXTURES = new URL("../../../packages/api/backend/hub/fixtures/", import.meta.url);
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

type Json = Record<string, unknown>;

let env: Env;
let state: FakeState;
let hub: Hub;
let ownerId: string;
let watcherId: string;
let ownerToken: string;
let watcherToken: string;
let w1: string;
let w2: string;
let aborts: AbortController[];
let counter = 0;

function fixture(name: string): Json {
  return JSON.parse(readFileSync(new URL(`${name}.json`, FIXTURES), "utf8")) as Json;
}

function msgId(): string {
  let n = ++counter;
  let out = "";
  for (let i = 0; i < 26; i++) {
    out = CROCKFORD[n % 32] + out;
    n = Math.floor(n / 32);
  }
  return out;
}

function db(): D1Database {
  return env.DB!;
}

async function addUser(email: string, role: "owner" | "watcher"): Promise<string> {
  const id = uuid();
  const t = now();
  await db()
    .prepare(
      "INSERT INTO users (id, email, email_normalized, password_hash, role, password_changed_at, created_at, updated_at) VALUES (?, ?, ?, 'x', ?, ?, ?, ?)",
    )
    .bind(id, email, email, role, t, t, t)
    .run();
  return id;
}

async function addSession(userId: string): Promise<string> {
  const token = `ss1_${crypto.randomUUID().replace(/-/g, "").padEnd(43, "a")}`;
  const t = now();
  const later = new Date(Date.now() + 86_400_000).toISOString();
  await db()
    .prepare(
      "INSERT INTO sessions (id, user_id, token_hash, client, created_at, last_seen_at, expires_at, absolute_expires_at) VALUES (?, ?, ?, 'mac', ?, ?, ?, ?)",
    )
    .bind(uuid(), userId, await sha256Hex(token), t, t, later, later)
    .run();
  return token;
}

async function addWorkspace(slug: string, position: number): Promise<string> {
  const id = uuid();
  const t = now();
  await db().batch([
    db().prepare("INSERT INTO workspaces (id, owner_id, name, slug, position, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)").bind(id, ownerId, slug, slug, position, t, t),
    db().prepare("INSERT INTO campus_layouts (workspace_id, updated_at) VALUES (?, ?)").bind(id, t),
  ]);
  return id;
}

async function call(path: string, init: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {}): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": "203.0.113.7", ...init.headers };
  if (init.token !== undefined) headers.Authorization = `Bearer ${init.token}`;
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  const ctrl = new AbortController();
  aborts.push(ctrl);
  const req = new Request(`${API}${path}`, {
    method: init.method ?? "GET",
    headers,
    signal: ctrl.signal,
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  });
  return worker.fetch(req, env);
}

async function machine(body: Json, path = "/v1/machines/link"): Promise<{ id: string; credential: string }> {
  const res = await call(path, { method: "POST", token: ownerToken, body });
  assert.equal(res.status, 201);
  const b = (await res.json()) as { machine: Json; credential: string };
  return { id: b.machine.id as string, credential: b.credential };
}

async function upgrade(credential: string): Promise<Response> {
  return call("/v1/connect", { token: credential, headers: { Upgrade: "websocket" } });
}

async function connect(credential: string): Promise<FakeWebSocket> {
  const before = new Set(state.getWebSockets("agent"));
  const res = await upgrade(credential);
  assert.equal(res.status, 101);
  const ws = state.getWebSockets("agent").find((w) => !before.has(w));
  assert.ok(ws);
  return ws;
}

async function send(ws: FakeWebSocket, frame: Json): Promise<Json | undefined> {
  const count = ws.sent.length;
  await hub.webSocketMessage(ws as never, JSON.stringify(frame));
  return ws.frames().slice(count).at(-1);
}

function hello(local: string): Json {
  return { ...fixture("ws-hello"), id: msgId(), machine_id: local, protocol: [2] };
}

async function agent(credential: string, local: string): Promise<FakeWebSocket> {
  const ws = await connect(credential);
  const reply = await send(ws, hello(local));
  assert.equal(reply?.type, "welcome");
  return ws;
}

function snapshot(local: string, workspaceId: string | null, seq = 1): Json {
  return { ...fixture("ws-snapshot"), id: msgId(), machine_id: local, workspace_id: workspaceId, seq };
}

function event(local: string, workspaceId: string | null, subject: string): Json {
  return { ...fixture("ws-event"), id: msgId(), machine_id: local, workspace_id: workspaceId, event_id: msgId(), subject: { kind: "task", id: subject } };
}

async function readSse(res: Response, until: (text: string) => boolean): Promise<{ text: string; done: boolean }> {
  const reader = res.body!.getReader();
  const decoder = new TextDecoder();
  let text = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return { text, done: true };
    text += decoder.decode(value, { stream: true });
    if (until(text)) {
      reader.releaseLock();
      return { text, done: false };
    }
  }
}

async function json(res: Response): Promise<Json> {
  return (await res.json()) as Json;
}

beforeEach(async () => {
  aborts = [];
  const d1 = new FakeD1Database().asD1();
  const files = readdirSync(DIR).filter((f) => /^\d{4}_.+\.sql$/.test(f)).sort();
  await applyMigrations(d1, files.map((f) => readFileSync(new URL(f, DIR), "utf8")));
  state = new FakeState();
  hub = new Hub(state as never, { DB: d1 });
  env = { DB: d1, HUB: { idFromName: (name: string) => ({ name }) as unknown as DurableObjectId, get: () => hub } };
  ownerId = await addUser("duenia@ejemplo.test", "owner");
  watcherId = await addUser("mirona@ejemplo.test", "watcher");
  ownerToken = await addSession(ownerId);
  watcherToken = await addSession(watcherId);
  w1 = await addWorkspace("compartido", 0);
  w2 = await addWorkspace("privado", 1);
  await db().prepare("INSERT INTO workspace_members (workspace_id, user_id, added_by, created_at) VALUES (?, ?, ?, ?)").bind(w1, watcherId, ownerId, now()).run();
});

afterEach(() => {
  for (const a of aborts) a.abort();
});

describe("aislamiento por vista (§5.7)", () => {
  it("1: un watcher no ve W ajeno en /v1/state ni en /v1/stream y recibe 404 al pedirlo", async () => {
    const m1 = await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos", workspace_ids: [w1] });
    const m2 = await machine({ local_machine_id: "air.local", name: "air", platform: "macos", workspace_ids: [w2] });
    const a1 = await agent(m1.credential, "mac-mini.local");
    const a2 = await agent(m2.credential, "air.local");
    assert.equal(await send(a1, snapshot("mac-mini.local", w1)), undefined);
    assert.equal(await send(a1, snapshot("mac-mini.local", null)), undefined);
    assert.equal(await send(a2, snapshot("air.local", w2)), undefined);
    const foreign = await send(a1, snapshot("mac-mini.local", w2));
    assert.equal(foreign?.code, "forbidden");

    assert.equal((await call(`/v1/state?workspace=${w2}`, { token: watcherToken })).status, 404);
    assert.equal((await call(`/v1/stream?workspace=${w2}`, { token: watcherToken })).status, 404);
    assert.equal((await call("/v1/state?workspace=nada", { token: watcherToken })).status, 404);

    const ws = await json(await call("/v1/state", { token: watcherToken }));
    assert.deepEqual(ws.user, { id: watcherId, role: "watcher" });
    const city = ws.city as { workspaces: Json[] };
    assert.deepEqual(city.workspaces.map((w) => w.id), [w1]);
    assert.deepEqual(city.workspaces[0]!.machine_ids, [m1.id]);
    assert.deepEqual(ws.machines, [{ id: m1.id, name: "mac-mini", online: true, stale: false }]);
    assert.deepEqual((ws.snapshots as Json[]).map((s) => s.workspace_id), [w1]);

    const os = await json(await call("/v1/state", { token: ownerToken }));
    assert.deepEqual((os.city as { workspaces: Json[] }).workspaces.map((w) => w.id), [w1, w2]);
    assert.deepEqual((os.machines as Json[]).map((m) => [m.id, m.online, m.paused]), [[m1.id, true, false], [m2.id, true, false]]);
    assert.deepEqual((os.snapshots as Json[]).map((s) => s.workspace_id).sort(), [null, w1, w2].sort());

    const stream = await call("/v1/stream", { token: watcherToken });
    assert.equal(stream.status, 200);
    const first = await readSse(stream, (s) => s.includes("event: hello") && s.includes("event: snapshot"));
    assert.equal(first.text.includes(`"workspace_id":"${w2}"`), false);
    assert.equal(first.text.includes('"workspace_id":null'), false);
    await send(a2, event("air.local", w2, "privado-1"));
    await send(a1, event("mac-mini.local", null, "sin-workspace-1"));
    await send(a1, event("mac-mini.local", w1, "compartido-1"));
    const more = await readSse(stream, (s) => s.includes("compartido-1"));
    assert.equal(more.text.includes("privado-1"), false);
    assert.equal(more.text.includes("sin-workspace-1"), false);
  });

  it("4: cm1_ solo sirve en /v1/connect y ss1_ no sirve en /v1/connect", async () => {
    const m = await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos" });
    for (const path of ["/v1/state", "/v1/stream", "/v1/workspaces", "/v1/auth/me", "/v1/machines", "/v1/sessions"]) {
      assert.equal((await call(path, { token: m.credential })).status, 403, path);
    }
    assert.equal((await upgrade(ownerToken)).status, 403);
    assert.equal((await upgrade(watcherToken)).status, 403);
    assert.equal((await upgrade(`cm1_${"A".repeat(43)}`)).status, 401);
    assert.equal((await upgrade(m.credential)).status, 101);
  });

  it("5: quitar al watcher de W cierra sus streams en la misma petición", async () => {
    const stream = await call("/v1/stream", { token: watcherToken });
    const other = await call("/v1/stream", { token: ownerToken });
    await readSse(stream, (s) => s.includes("event: hello"));
    await readSse(other, (s) => s.includes("event: hello"));
    assert.equal(hub.viewers.active, 2);
    assert.equal((await call(`/v1/workspaces/${w1}/watchers/${watcherId}`, { method: "DELETE", token: ownerToken })).status, 204);
    const rest = await readSse(stream, () => false);
    assert.equal(rest.done, true);
    assert.match(rest.text, /event: error\ndata: .*"code":"forbidden".*"close":true/);
    assert.equal(hub.viewers.active, 1);
    const after = await json(await call("/v1/state", { token: watcherToken }));
    assert.deepEqual((after.city as { workspaces: Json[] }).workspaces, []);
  });

  it("5: desactivar al watcher revoca sus sesiones y cierra sus streams", async () => {
    const stream = await call("/v1/stream", { token: watcherToken });
    await readSse(stream, (s) => s.includes("event: hello"));
    await revokeUserSessions(env, watcherId, "user_disabled");
    await viewerChanged(env, watcherId);
    const rest = await readSse(stream, () => false);
    assert.equal(rest.done, true);
    assert.match(rest.text, /event: error\ndata: .*"code":"unauthorized".*"close":true/);
    assert.equal(hub.viewers.active, 0);
    assert.equal((await call("/v1/stream", { token: watcherToken })).status, 401);
  });

  it("sessionRevoked cierra solo el stream de esa sesión", async () => {
    const second = await addSession(watcherId);
    const a = await call("/v1/stream", { token: watcherToken });
    const b = await call("/v1/stream", { token: second });
    await readSse(a, (s) => s.includes("event: hello"));
    await readSse(b, (s) => s.includes("event: hello"));
    const sid = await db().prepare("SELECT id FROM sessions WHERE token_hash = ?").bind(await sha256Hex(watcherToken)).first<string>("id");
    assert.equal((await call(`/v1/sessions/${sid}`, { method: "DELETE", token: ownerToken })).status, 204);
    assert.equal((await readSse(a, () => false)).done, true);
    assert.equal(hub.viewers.active, 1);
  });
});

describe("conexión del agente v2", () => {
  it("welcome trae machine y rev; online refleja el hello", async () => {
    const m = await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos" });
    const ws = await connect(m.credential);
    assert.deepEqual(await hub.online(), []);
    const welcome = await send(ws, hello("mac-mini.local"));
    assert.equal(welcome?.type, "welcome");
    assert.equal(welcome?.v, 2);
    assert.equal(welcome?.protocol, 2);
    assert.deepEqual(welcome?.machine, { id: m.id, name: "mac-mini" });
    assert.equal(typeof welcome?.rev, "number");
    assert.equal(welcome?.whoami, undefined);
    assert.deepEqual(await hub.online(), [m.id]);
    const row = await db().prepare("SELECT agent_version, last_seen_at FROM machines WHERE id = ?").bind(m.id).first<Json>();
    assert.equal(row?.agent_version, "0.9.0");
    assert.notEqual(row?.last_seen_at, null);
    const machines = await json(await call("/v1/machines", { token: ownerToken }));
    assert.equal((machines.machines as Json[])[0]!.online, true);
  });

  it("pausar cierra con 4403 y rechaza reconexiones hasta reanudar", async () => {
    const m = await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos", workspace_ids: [w1] });
    const ws = await agent(m.credential, "mac-mini.local");
    const stream = await call("/v1/stream", { token: watcherToken });
    await readSse(stream, (s) => s.includes("event: hello"));
    assert.equal((await call(`/v1/machines/${m.id}/pause`, { method: "POST", token: ownerToken })).status, 200);
    assert.deepEqual(ws.closed, { code: 4403, reason: "forbidden" });
    assert.equal(ws.frames().at(-1)?.close, true);
    const seen = await readSse(stream, (s) => s.includes("event: machine"));
    assert.match(seen.text, new RegExp(`event: machine\nid: [^\n]+\ndata: \\{"id":"${m.id}","online":false,"paused":true\\}`));
    assert.equal((await upgrade(m.credential)).status, 403);
    assert.deepEqual(await hub.online(), []);
    assert.equal((await call(`/v1/machines/${m.id}/resume`, { method: "POST", token: ownerToken })).status, 200);
    await agent(m.credential, "mac-mini.local");
  });

  it("revocar cierra con 4401, borra sus snapshots y la credencial deja de valer", async () => {
    const m = await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos", workspace_ids: [w1] });
    const ws = await agent(m.credential, "mac-mini.local");
    await send(ws, snapshot("mac-mini.local", w1));
    assert.equal(((await json(await call("/v1/state", { token: ownerToken }))).snapshots as Json[]).length, 1);
    assert.equal((await call(`/v1/machines/${m.id}/revoke`, { method: "POST", token: ownerToken })).status, 204);
    assert.deepEqual(ws.closed, { code: 4401, reason: "unauthorized" });
    assert.equal(ws.frames().at(-1)?.code, "unauthorized");
    assert.equal((await upgrade(m.credential)).status, 401);
    const s = await json(await call("/v1/state", { token: ownerToken }));
    assert.deepEqual(s.snapshots, []);
    assert.deepEqual(s.machines, []);
  });

  it("un hello con otro machine_id cierra la conexión", async () => {
    const m = await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos" });
    const ws = await connect(m.credential);
    const reply = await send(ws, hello("otra-maquina"));
    assert.equal(reply?.code, "forbidden");
    assert.deepEqual(ws.closed, { code: 4403, reason: "forbidden" });
    assert.deepEqual(await hub.online(), []);
  });

  it("un hello sin protocolo 2 se rechaza con 4426", async () => {
    const m = await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos" });
    const ws = await connect(m.credential);
    await send(ws, { ...hello("mac-mini.local"), protocol: [1] });
    assert.deepEqual(ws.closed, { code: 4426, reason: "unsupported_version" });
  });

  it("el primer hello fija local_machine_id de una máquina creada con token (VPS)", async () => {
    const m = await machine({ name: "contabo", platform: "linux", workspace_ids: [w2] }, "/v1/machines");
    const before = await db().prepare("SELECT local_machine_id FROM machines WHERE id = ?").bind(m.id).first<string | null>("local_machine_id");
    assert.equal(before, null);
    const ws = await agent(m.credential, "contabo-dev");
    const after = await db().prepare("SELECT local_machine_id FROM machines WHERE id = ?").bind(m.id).first<string | null>("local_machine_id");
    assert.equal(after, "contabo-dev");
    assert.equal(await send(ws, snapshot("contabo-dev", w2)), undefined);
    ws.close(1000, "bye");
    const again = await connect(m.credential);
    assert.equal((await send(again, hello("otro-nombre")))?.code, "forbidden");
    assert.deepEqual(again.closed, { code: 4403, reason: "forbidden" });
  });

  it("un hello VPS con el machine_id de otra máquina activa cierra con 4409", async () => {
    await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos" });
    const vps = await machine({ name: "contabo", platform: "linux" }, "/v1/machines");
    const ws = await connect(vps.credential);
    const reply = await send(ws, hello("mac-mini.local"));
    assert.equal(reply?.code, "conflict");
    assert.deepEqual(ws.closed, { code: 4409, reason: "conflict" });
    const stored = await db().prepare("SELECT local_machine_id FROM machines WHERE id = ?").bind(vps.id).first<string | null>("local_machine_id");
    assert.equal(stored, null);
  });

  it("quitar la máquina de un workspace borra sus snapshots de ese workspace", async () => {
    const m = await machine({ local_machine_id: "mac-mini.local", name: "mac-mini", platform: "macos", workspace_ids: [w1, w2] });
    const ws = await agent(m.credential, "mac-mini.local");
    await send(ws, snapshot("mac-mini.local", w1));
    await send(ws, snapshot("mac-mini.local", w2));
    assert.equal((await call(`/v1/workspaces/${w2}/machines/${m.id}`, { method: "DELETE", token: ownerToken })).status, 204);
    const s = await json(await call("/v1/state", { token: ownerToken }));
    assert.deepEqual((s.snapshots as Json[]).map((x) => x.workspace_id), [w1]);
    const reply = await send(ws, snapshot("mac-mini.local", w2, 2));
    assert.equal(reply?.code, "forbidden");
  });
});
