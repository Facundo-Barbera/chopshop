import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeState, FakeWebSocket } from "./do.ts";
import { PEPPER_SECRET, addUser, freshEnv } from "./accounts.ts";
import { Hub } from "../src/hub.ts";
import worker, { type Env } from "../src/index.ts";
import { ROUTES, type RouteDef } from "../src/router.ts";

const API = "https://api.chopshop.novarix.online";
const FIXTURES = new URL("../../../packages/api/backend/hub/fixtures/", import.meta.url);
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const PASSWORD = "caballo bateria grapa";
const LINK = /#t=(ci1_[A-Za-z0-9_-]{43})$/;
const UNKNOWN_ROUTE = "ruta desconocida";
const PENDING = new Set([
  "operator.bootstrap",
  "operator.recover",
  "auth.recover",
  "auth.recovery_code",
  "imports.list",
  "imports.get",
  "imports.apply",
  "imports.dismiss",
  "commands",
  "audit",
]);

type Json = Record<string, unknown>;

interface Viewer {
  id: string;
  token: string;
  sessionId: string;
}

interface Campus {
  workspace: string;
  project: string;
  role: string;
  machine: { id: string; credential: string; local: string };
}

let env: Env & { DB: D1Database };
let state: FakeState;
let hub: Hub;
let owner: Viewer;
let ana: Viewer;
let beto: Viewer;
let w1: Campus;
let w2: Campus;
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

async function ok(res: Response, status = 200): Promise<Json> {
  const text = await res.text();
  assert.equal(res.status, status, text);
  return text === "" ? {} : (JSON.parse(text) as Json);
}

function asOwner(method: string, path: string, body?: unknown, status = 200): Promise<Json> {
  return call(path, { method, token: owner.token, body }).then((res) => ok(res, status));
}

async function login(email: string): Promise<Viewer> {
  const body = await ok(await call("/v1/auth/login", { method: "POST", body: { email, password: PASSWORD, client: "mac", device_name: "Mac mini" } }));
  return { id: (body.user as Json).id as string, token: body.token as string, sessionId: (body.session as Json).id as string };
}

async function invite(email: string, workspaceId: string): Promise<Viewer> {
  const inv = await asOwner("POST", "/v1/invitations", { email, workspace_ids: [workspaceId] }, 201);
  const token = LINK.exec(String(inv.link))![1]!;
  const body = await ok(
    await call("/v1/invitations/accept", { method: "POST", body: { token, password: PASSWORD, device_name: "MacBook Air", client: "mac" } }),
    201,
  );
  return { id: (body.user as Json).id as string, token: body.token as string, sessionId: (body.session as Json).id as string };
}

async function campus(name: string, local: string): Promise<Campus> {
  const workspace = ((await asOwner("POST", "/v1/workspaces", { name }, 201)).workspace as Json).id as string;
  const linked = await asOwner("POST", "/v1/machines/link", { local_machine_id: local, name: local, platform: "macos", workspace_ids: [workspace] }, 201);
  const machine = { id: (linked.machine as Json).id as string, credential: linked.credential as string, local };
  const project = ((await asOwner("POST", `/v1/workspaces/${workspace}/projects`, { name: `${name}-app`, machine_id: machine.id }, 201)).project as Json).id as string;
  const role = ((await asOwner("POST", `/v1/projects/${project}/roles`, { name: "triage" }, 201)).role as Json).id as string;
  return { workspace, project, role, machine };
}

function fill(def: RouteDef, c: Campus, user: Viewer): string {
  const top = def.path.split("/")[2];
  const ids: Record<string, string> = {
    workspaces: c.workspace,
    projects: c.project,
    roles: c.role,
    machines: c.machine.id,
    users: user.id,
    sessions: user.sessionId,
    invitations: crypto.randomUUID(),
    imports: crypto.randomUUID(),
  };
  return def.path
    .replace(":user_id", user.id)
    .replace(":machine_id", c.machine.id)
    .replace(":id", ids[top!] ?? crypto.randomUUID());
}

function bodyFor(def: RouteDef): unknown {
  return def.method === "GET" || def.method === "DELETE" ? undefined : { rev: 1, name: "intruso", layout: {}, status: "disabled" };
}

async function expectStatus(def: RouteDef, res: Response, status: number, label: string): Promise<void> {
  const body = (await res.json().catch(() => ({}))) as Json;
  if (res.status === 404 && body.message === UNKNOWN_ROUTE) {
    assert.ok(PENDING.has(def.name), `${label}: ruta sin handler fuera de PENDING`);
    return;
  }
  assert.equal(res.status, status, `${label}: ${JSON.stringify(body)}`);
}

async function connect(c: Campus): Promise<FakeWebSocket> {
  const before = new Set(state.getWebSockets("agent"));
  const res = await call("/v1/connect", { token: c.machine.credential, headers: { Upgrade: "websocket" } });
  assert.equal(res.status, 101);
  const ws = state.getWebSockets("agent").find((w) => !before.has(w))!;
  await hub.webSocketMessage(ws as never, JSON.stringify({ ...fixture("ws-hello"), id: msgId(), machine_id: c.machine.local, protocol: [2] }));
  assert.equal(ws.frames().at(-1)?.type, "welcome");
  return ws;
}

async function send(ws: FakeWebSocket, frame: Json): Promise<Json | undefined> {
  const count = ws.sent.length;
  await hub.webSocketMessage(ws as never, JSON.stringify(frame));
  return ws.frames().slice(count).at(-1);
}

function snapshot(c: Campus, workspaceId: string | null): Json {
  return { ...fixture("ws-snapshot"), id: msgId(), machine_id: c.machine.local, workspace_id: workspaceId, seq: ++counter };
}

function event(c: Campus, workspaceId: string | null, subject: string): Json {
  return { ...fixture("ws-event"), id: msgId(), machine_id: c.machine.local, workspace_id: workspaceId, event_id: msgId(), subject: { kind: "task", id: subject } };
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

async function openStream(v: Viewer): Promise<Response> {
  const res = await call("/v1/stream", { token: v.token });
  assert.equal(res.status, 200);
  await readSse(res, (s) => s.includes("event: hello"));
  return res;
}

async function cityOf(v: Viewer): Promise<Json> {
  return ok(await call("/v1/state", { token: v.token }));
}

async function dbCounts(): Promise<Json> {
  const out: Json = {};
  for (const t of ["workspaces", "workspace_members", "workspace_machines", "projects", "roles", "machines", "invitations", "users"]) {
    out[t] = await env.DB.prepare(`SELECT count(*) AS n FROM ${t} WHERE 1`).first<number>("n");
  }
  out.rev = await env.DB.prepare("SELECT value FROM meta WHERE key = 'structure_rev'").first("value");
  out.disabled = await env.DB.prepare("SELECT count(*) AS n FROM users WHERE status <> 'active'").first<number>("n");
  out.paused = await env.DB.prepare("SELECT count(*) AS n FROM machines WHERE paused_at IS NOT NULL OR revoked_at IS NOT NULL").first<number>("n");
  return out;
}

beforeEach(async () => {
  aborts = [];
  const base = await freshEnv();
  state = new FakeState();
  hub = new Hub(state as never, { DB: base.DB });
  env = { ...base, PASSWORD_PEPPER: PEPPER_SECRET, HUB: { idFromName: (name: string) => ({ name }) as unknown as DurableObjectId, get: () => hub } };
  await addUser(env, "duenia@ejemplo.test", "owner", { password: PASSWORD });
  owner = await login("duenia@ejemplo.test");
  w1 = await campus("Norte", "mac-mini.local");
  w2 = await campus("Sur", "air.local");
  ana = await invite("ana@ejemplo.test", w1.workspace);
  beto = await invite("beto@ejemplo.test", w2.workspace);
});

afterEach(() => {
  for (const a of aborts) a.abort();
});

describe("aislamiento de extremo a extremo (§5.7)", () => {
  it("1: cada watcher solo ve su workspace en rutas, /v1/state y /v1/stream", async () => {
    const reads = ROUTES.filter((r) => r.who === "any" && r.method === "GET" && /^\/v1\/(workspaces|projects)\/:id/.test(r.path));
    assert.deepEqual(reads.map((r) => r.name).sort(), ["campus.get", "layout.get", "projects.get", "projects.list", "roles.list", "workspaces.get"]);
    for (const [v, own, foreign] of [
      [ana, w1, w2],
      [beto, w2, w1],
    ] as const) {
      for (const def of reads) {
        assert.equal((await call(fill(def, own, v), { token: v.token })).status, 200, `propio ${def.name}`);
        const res = await call(fill(def, foreign, v), { token: v.token });
        assert.equal(res.status, 404, `ajeno ${def.name}`);
        assert.equal(((await res.json()) as Json).code, "not_found");
      }
      assert.equal((await call(`/v1/state?workspace=${foreign.workspace}`, { token: v.token })).status, 404);
      assert.equal((await call(`/v1/stream?workspace=${foreign.workspace}`, { token: v.token })).status, 404);
      assert.equal((await call(`/v1/state?workspace=${own.workspace}`, { token: v.token })).status, 200);
      const list = await ok(await call("/v1/workspaces", { token: v.token }));
      assert.deepEqual((list.workspaces as Json[]).map((w) => w.id), [own.workspace]);
    }

    const a1 = await connect(w1);
    const a2 = await connect(w2);
    assert.equal(await send(a1, snapshot(w1, w1.workspace)), undefined);
    assert.equal(await send(a1, snapshot(w1, null)), undefined);
    assert.equal(await send(a2, snapshot(w2, w2.workspace)), undefined);
    assert.equal((await send(a1, snapshot(w1, w2.workspace)))?.code, "forbidden");
    assert.equal((await send(a2, snapshot(w2, w1.workspace)))?.code, "forbidden");

    for (const [v, own, foreign] of [
      [ana, w1, w2],
      [beto, w2, w1],
    ] as const) {
      const s = await cityOf(v);
      assert.deepEqual((s.city as { workspaces: Json[] }).workspaces.map((w) => w.id), [own.workspace]);
      assert.deepEqual((s.machines as Json[]).map((m) => m.id), [own.machine.id]);
      assert.deepEqual((s.snapshots as Json[]).map((x) => x.workspace_id), [own.workspace]);
      assert.equal(JSON.stringify(s).includes(foreign.workspace), false);
      assert.equal(JSON.stringify(s).includes(foreign.machine.id), false);
      assert.equal(JSON.stringify(s).includes(foreign.project), false);
    }
    const os = await cityOf(owner);
    assert.deepEqual((os.city as { workspaces: Json[] }).workspaces.map((w) => w.id).sort(), [w1.workspace, w2.workspace].sort());
    assert.deepEqual((os.snapshots as Json[]).map((x) => x.workspace_id).sort(), [null, w1.workspace, w2.workspace].sort());

    const sa = await call("/v1/stream", { token: ana.token });
    const sb = await call("/v1/stream", { token: beto.token });
    const so = await call("/v1/stream", { token: owner.token });
    const firstA = await readSse(sa, (s) => s.includes("event: hello") && s.includes("event: snapshot"));
    const firstB = await readSse(sb, (s) => s.includes("event: hello") && s.includes("event: snapshot"));
    await readSse(so, (s) => s.includes("event: hello"));
    assert.equal(firstA.text.includes(w2.workspace), false);
    assert.equal(firstA.text.includes('"workspace_id":null'), false);
    assert.equal(firstB.text.includes(w1.workspace), false);
    assert.equal(firstB.text.includes('"workspace_id":null'), false);
    await send(a1, event(w1, null, "suelto-1"));
    await send(a2, event(w2, w2.workspace, "sur-1"));
    await send(a1, event(w1, w1.workspace, "norte-1"));
    await send(a2, event(w2, w2.workspace, "sur-2"));
    const moreA = await readSse(sa, (s) => s.includes("norte-1"));
    const moreB = await readSse(sb, (s) => s.includes("sur-2"));
    const moreO = await readSse(so, (s) => s.includes("suelto-1") && s.includes("sur-2") && s.includes("norte-1"));
    assert.equal(moreA.text.includes("sur-1"), false);
    assert.equal(moreA.text.includes("suelto-1"), false);
    assert.equal(moreB.text.includes("norte-1"), false);
    assert.equal(moreB.text.includes("suelto-1"), false);
    assert.equal(moreO.done, false);
  });

  it("2: un watcher recibe 403 en toda escritura y ruta de dueño, incluso en su workspace compartido", async () => {
    const owned = ROUTES.filter((r) => r.who === "owner");
    assert.ok(owned.some((r) => r.name === "commands"));
    const before = await dbCounts();
    for (const v of [ana, beto]) {
      for (const c of [w1, w2]) {
        for (const def of owned) {
          const res = await call(fill(def, c, v), { method: def.method, token: v.token, body: bodyFor(def) });
          await expectStatus(def, res, 403, `${v === ana ? "ana" : "beto"} ${def.method} ${def.name}`);
        }
      }
    }
    const commands = await call("/v1/commands", { method: "POST", token: ana.token, body: { machine_id: w1.machine.id, name: "status", args: {} } });
    await expectStatus(ROUTES.find((r) => r.name === "commands")!, commands, 403, "commands");
    assert.deepEqual(await dbCounts(), before);
    assert.equal((await call("/v1/auth/me", { token: ana.token })).status, 200);
    assert.equal((await call("/v1/auth/me", { token: beto.token })).status, 200);
  });

  it("3: ninguna ruta usa un user_id del cliente para decidir permisos", async () => {
    const extra = await login("ana@ejemplo.test");
    const own = await ok(await call(`/v1/sessions?user_id=${beto.id}`, { token: ana.token }));
    assert.deepEqual((own.sessions as Json[]).map((s) => s.id).sort(), [ana.sessionId, extra.sessionId].sort());
    assert.equal((await call(`/v1/sessions/${beto.sessionId}`, { method: "DELETE", token: ana.token })).status, 404);
    assert.equal((await call("/v1/auth/me", { token: beto.token })).status, 200);

    const asBeto = await ok(await call(`/v1/state?user_id=${beto.id}`, { token: ana.token }));
    assert.deepEqual(asBeto.user, { id: ana.id, role: "watcher" });
    assert.deepEqual((asBeto.city as { workspaces: Json[] }).workspaces.map((w) => w.id), [w1.workspace]);
    const list = await ok(await call(`/v1/workspaces?user_id=${owner.id}`, { token: ana.token }));
    assert.deepEqual((list.workspaces as Json[]).map((w) => w.id), [w1.workspace]);
    assert.equal((await call(`/v1/workspaces/${w2.workspace}?user_id=${beto.id}`, { token: ana.token })).status, 404);
    const me = await ok(await call(`/v1/auth/me?user_id=${owner.id}`, { token: ana.token }));
    assert.equal((me.user as Json).id, ana.id);
    assert.equal((await call(`/v1/workspaces?user_id=${owner.id}`, { method: "POST", token: ana.token, body: { name: "x", user_id: owner.id } })).status, 403);

    const filtered = await ok(await call(`/v1/sessions?user_id=${ana.id}`, { token: owner.token }));
    assert.deepEqual((filtered.sessions as Json[]).map((s) => s.id).sort(), [ana.sessionId, extra.sessionId].sort());
    const all = await ok(await call("/v1/sessions", { token: owner.token }));
    assert.equal((all.sessions as Json[]).length, 4);
  });

  it("4: cm1_ solo sirve en /v1/connect y ss1_ no sirve en /v1/connect", async () => {
    for (const c of [w1, w2]) {
      for (const def of ROUTES.filter((r) => r.who !== "anon" && r.name !== "connect")) {
        const res = await call(fill(def, c, owner), { method: def.method, token: c.machine.credential, body: bodyFor(def) });
        await expectStatus(def, res, def.who === "operator" ? 401 : 403, `cm1_ ${def.method} ${def.name}`);
      }
    }
    for (const v of [owner, ana, beto]) {
      assert.equal((await call("/v1/connect", { token: v.token, headers: { Upgrade: "websocket" } })).status, 403);
    }
    assert.equal((await call("/v1/connect", { headers: { Upgrade: "websocket" } })).status, 401);
    assert.equal((await call("/v1/connect", { token: w1.machine.credential, headers: { Upgrade: "websocket" } })).status, 101);
    assert.equal((await call("/v1/connect", { token: w2.machine.credential, headers: { Upgrade: "websocket" } })).status, 101);
  });

  it("5: quitar a un watcher de su workspace cierra sus streams en menos de 1 s sin tocar a los demás", async () => {
    const sa = await openStream(ana);
    const sb = await openStream(beto);
    await openStream(owner);
    assert.equal(hub.viewers.active, 3);
    const t0 = Date.now();
    await asOwner("DELETE", `/v1/workspaces/${w1.workspace}/watchers/${ana.id}`, undefined, 204);
    const rest = await readSse(sa, () => false);
    assert.ok(Date.now() - t0 < 1000);
    assert.equal(rest.done, true);
    assert.match(rest.text, /event: error\ndata: .*"code":"forbidden".*"close":true/);
    assert.equal(hub.viewers.active, 2);
    assert.deepEqual((await cityOf(ana)).city, { workspaces: [] });
    assert.equal((await call(`/v1/workspaces/${w1.workspace}`, { token: ana.token })).status, 404);
    const a2 = await connect(w2);
    await send(a2, event(w2, w2.workspace, "sur-vivo"));
    assert.equal((await readSse(sb, (s) => s.includes("sur-vivo"))).done, false);
  });

  it("5: desactivar a un watcher revoca sus sesiones y cierra sus streams en menos de 1 s", async () => {
    const sb = await openStream(beto);
    const sa = await openStream(ana);
    const t0 = Date.now();
    const res = await asOwner("PATCH", `/v1/users/${beto.id}`, { status: "disabled" });
    assert.equal((res.user as Json).status, "disabled");
    const rest = await readSse(sb, () => false);
    assert.ok(Date.now() - t0 < 1000);
    assert.equal(rest.done, true);
    assert.match(rest.text, /event: error\ndata: .*"code":"unauthorized".*"close":true/);
    assert.equal(hub.viewers.active, 1);
    assert.equal((await call("/v1/stream", { token: beto.token })).status, 401);
    assert.equal((await call("/v1/state", { token: beto.token })).status, 401);
    const a1 = await connect(w1);
    await send(a1, event(w1, w1.workspace, "norte-vivo"));
    assert.equal((await readSse(sa, (s) => s.includes("norte-vivo"))).done, false);
  });
});
