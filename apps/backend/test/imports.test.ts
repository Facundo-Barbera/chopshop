import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeState, FakeWebSocket } from "./do.ts";
import { sha256Hex } from "../src/crypto.ts";
import { applyMigrations, now, uuid } from "../src/db.ts";
import { Hub } from "../src/hub.ts";
import worker, { type Env } from "../src/index.ts";
import { structureRev } from "../src/structure.ts";
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
let ownerToken: string;
let watcherToken: string;
let structureCalls: unknown[][];
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

async function call(path: string, init: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {}): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": "203.0.113.7", ...init.headers };
  if (init.token !== undefined) headers.Authorization = `Bearer ${init.token}`;
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  return worker.fetch(
    new Request(`${API}${path}`, { method: init.method ?? "GET", headers, ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }) }),
    env,
  );
}

async function owner(method: string, path: string, body?: unknown, status = 200): Promise<Json> {
  const res = await call(path, { method, token: ownerToken, body });
  const text = await res.text();
  assert.equal(res.status, status, text);
  return text === "" ? {} : (JSON.parse(text) as Json);
}

async function link(local: string, workspaceIds: string[] = []): Promise<{ id: string; credential: string }> {
  const b = await owner("POST", "/v1/machines/link", { local_machine_id: local, name: local, platform: "macos", workspace_ids: workspaceIds }, 201);
  return { id: (b.machine as Json).id as string, credential: b.credential as string };
}

async function agent(credential: string, local: string): Promise<FakeWebSocket> {
  const before = new Set(state.getWebSockets("agent"));
  const res = await call("/v1/connect", { token: credential, headers: { Upgrade: "websocket" } });
  assert.equal(res.status, 101);
  const ws = state.getWebSockets("agent").find((w) => !before.has(w))!;
  const count = ws.sent.length;
  await hub.webSocketMessage(ws as never, JSON.stringify({ ...fixture("ws-hello"), id: msgId(), machine_id: local, protocol: [2] }));
  assert.ok(ws.frames().slice(count).some((f) => f.type === "welcome"));
  return ws;
}

async function send(ws: FakeWebSocket, frame: Json): Promise<Json | undefined> {
  const count = ws.sent.length;
  await hub.webSocketMessage(ws as never, JSON.stringify(frame));
  return ws.frames().slice(count).at(-1);
}

function profile(name: string, company: string | null, extra: Json = {}): Json {
  const office: Json = {
    half_life: "10m",
    floors: [{ name: "Producto", rooms: [{ role: "triage", desks: 1, permanent: true }, { role: "backend", desks: 2 }] }],
    roles: {
      triage: { prompt: "Clasifica los issues nuevos.", match: { labels: ["bug"] }, wake: ["issue.opened"], model: "sonnet", tone: "breve" },
      backend: { prompt: "" },
    },
  };
  if (company !== null) office.company = company;
  return {
    project: name,
    t3_project: name,
    repo: `https://github.com/example/${name}`,
    runtime_mode: "auto",
    host: "mac-mini",
    office,
    capacity: { flex_per_floor: 0, max_extra_floors: 0, outsourcing: false },
    rack: { enabled: true },
    registry: { path: name, enabled: true },
    ...extra,
  };
}

function offer(projects: Json[]): Json {
  return { v: 2, type: "import.offer", id: msgId(), ts: new Date().toISOString(), projects };
}

async function offerFrom(ws: FakeWebSocket, projects: Json[]): Promise<Json> {
  const reply = await send(ws, offer(projects));
  assert.equal(reply?.type, "import.result", JSON.stringify(reply));
  return reply!;
}

beforeEach(async () => {
  const d1 = new FakeD1Database().asD1();
  const files = readdirSync(DIR).filter((f) => /^\d{4}_.+\.sql$/.test(f)).sort();
  await applyMigrations(d1, files.map((f) => readFileSync(new URL(f, DIR), "utf8")));
  state = new FakeState();
  hub = new Hub(state as never, { DB: d1 });
  structureCalls = [];
  const rpc = new Proxy(hub, {
    get(target, prop, receiver) {
      if (prop === "structureChanged") return async (...args: unknown[]) => void structureCalls.push(args);
      const v = Reflect.get(target, prop, receiver) as unknown;
      return typeof v === "function" ? (v as (...a: unknown[]) => unknown).bind(target) : v;
    },
  });
  env = { DB: d1, HUB: { idFromName: (name: string) => ({ name }) as unknown as DurableObjectId, get: () => rpc } };
  ownerId = await addUser("duenia@ejemplo.test", "owner");
  ownerToken = await addSession(ownerId);
  watcherToken = await addSession(await addUser("mirona@ejemplo.test", "watcher"));
});

afterEach(() => {
  counter = 0;
});

describe("import.offer", () => {
  it("guarda la oferta y una idéntica responde duplicate con el mismo import_id", async () => {
    const m = await link("mac-mini.local");
    const ws = await agent(m.credential, "mac-mini.local");
    const first = await offerFrom(ws, [profile("awesome-gb", "Awesome GB")]);
    assert.equal(first.status, "stored");
    assert.equal(first.re !== undefined, true);
    const again = await offerFrom(ws, [profile("awesome-gb", "Awesome GB")]);
    assert.equal(again.status, "duplicate");
    assert.equal(again.import_id, first.import_id);
    const changed = await offerFrom(ws, [profile("awesome-gb", "Awesome GB", { model: "opus" })]);
    assert.equal(changed.status, "stored");
    assert.notEqual(changed.import_id, first.import_id);
    const stored = await db().prepare("SELECT count(*) AS n FROM import_offers WHERE machine_id = ?").bind(m.id).first<number>("n");
    assert.equal(stored, 2);

    const other = await link("air.local");
    const ws2 = await agent(other.credential, "air.local");
    assert.equal((await offerFrom(ws2, [profile("awesome-gb", "Awesome GB")])).status, "stored");
  });

  it("rechaza ofertas sin hello, mal formadas o con nombres repetidos y no guarda nada", async () => {
    const m = await link("mac-mini.local");
    const before = new Set(state.getWebSockets("agent"));
    await call("/v1/connect", { token: m.credential, headers: { Upgrade: "websocket" } });
    const raw = state.getWebSockets("agent").find((w) => !before.has(w))!;
    assert.equal((await send(raw, offer([profile("a", null)])))?.code, "bad_request");
    const ws = await agent(m.credential, "mac-mini.local");
    assert.equal((await send(ws, offer([])))?.code, "bad_request");
    assert.equal((await send(ws, offer([{ project: "mal nombre" }])))?.code, "bad_request");
    assert.equal((await send(ws, offer([profile("a", null), profile("a", null)])))?.code, "bad_request");
    assert.equal((await send(ws, { ...offer([profile("a", null)]), extra: 1 }))?.code, "bad_request");
    const big = { project: "grande", notes: "x".repeat(800 * 1024) };
    assert.equal((await send(ws, offer([big])))?.code, "too_large");
    assert.equal(await db().prepare("SELECT count(*) AS n FROM import_offers").first<number>("n"), 0);
  });
});

describe("/v1/imports", () => {
  async function offered(projects: Json[]): Promise<{ machineId: string; importId: string }> {
    const m = await link("mac-mini.local");
    const ws = await agent(m.credential, "mac-mini.local");
    const reply = await offerFrom(ws, projects);
    return { machineId: m.id, importId: reply.import_id as string };
  }

  it("lista y detalla la oferta con roles, pisos, prompts y conflictos; solo el dueño", async () => {
    const { machineId, importId } = await offered([profile("awesome-gb", "Awesome GB"), profile("orchestrator", null, { office: {} })]);
    const ws = (await owner("POST", "/v1/workspaces", { name: "Otro" }, 201)).workspace as Json;
    await owner("POST", `/v1/workspaces/${ws.id}/projects`, { name: "orchestrator" }, 201);
    const list = (await owner("GET", "/v1/imports")).imports as Json[];
    assert.deepEqual(list.map((i) => [i.id, i.machine_id, i.applied_at, i.dismissed_at]), [[importId, machineId, null, null]]);
    assert.deepEqual(list[0]!.summary, [
      { name: "awesome-gb", company: "Awesome GB" },
      { name: "orchestrator", company: null },
    ]);
    const detail = await owner("GET", `/v1/imports/${importId}`);
    assert.deepEqual(detail.projects, [
      {
        name: "awesome-gb",
        company: "Awesome GB",
        t3_project: "awesome-gb",
        repo: "https://github.com/example/awesome-gb",
        roles: ["backend", "triage"],
        floors: 1,
        has_prompts: true,
        conflicts: [],
      },
      { name: "orchestrator", company: null, t3_project: "orchestrator", repo: "https://github.com/example/orchestrator", roles: [], floors: 0, has_prompts: false, conflicts: ["name_taken"] },
    ]);
    assert.equal((await call("/v1/imports", { token: watcherToken })).status, 403);
    assert.equal((await call(`/v1/imports/${importId}`, { token: watcherToken })).status, 403);
    assert.equal((await call(`/v1/imports/${uuid()}`, { token: ownerToken })).status, 404);
  });

  it("apply crea un workspace por company, proyectos con máquina, roles con prompt y layout, y sube structure_rev", async () => {
    const { machineId, importId } = await offered([
      profile("awesome-gb", "Awesome GB"),
      profile("awesome-api", "Awesome GB", { registry: { path: "awesome-api", enabled: false } }),
      profile("nuskills", "NuSkills"),
    ]);
    const rev0 = await structureRev(db());
    const res = await owner("POST", `/v1/imports/${importId}/apply`, { projects: [{ name: "awesome-gb" }, { name: "awesome-api" }, { name: "nuskills" }] });
    assert.deepEqual(res.skipped, []);
    const created = res.created as Json[];
    assert.deepEqual(created.map((p) => p.name), ["awesome-gb", "awesome-api", "nuskills"]);
    const rev1 = await structureRev(db());
    assert.equal(rev1, rev0 + 1);
    assert.deepEqual(structureCalls, [[rev1, "all"]]);

    const workspaces = (await owner("GET", "/v1/workspaces")).workspaces as Json[];
    assert.deepEqual(workspaces.map((w) => [w.name, w.slug, w.project_count, w.machine_ids]), [
      ["Awesome GB", "awesome-gb", 2, [machineId]],
      ["NuSkills", "nuskills", 1, [machineId]],
    ]);
    const awesome = workspaces[0]!;
    assert.deepEqual(await owner("GET", `/v1/workspaces/${awesome.id}/campus`), { layout: {}, rev: 1 });

    const gb = created[0]!;
    assert.equal(gb.workspace_id, awesome.id);
    assert.equal(gb.machine_id, machineId);
    assert.equal(gb.t3_project, "awesome-gb");
    assert.equal(gb.repo, "https://github.com/example/awesome-gb");
    assert.equal(gb.runtime_mode, "auto");
    assert.equal(gb.disabled, false);
    assert.deepEqual(gb.settings, { rack: { enabled: true } });
    assert.equal(created[1]!.disabled, true);
    assert.equal(created[1]!.workspace_id, awesome.id);

    const layout = await owner("GET", `/v1/projects/${gb.id}/layout`);
    assert.deepEqual(layout, {
      layout: {
        floors: [{ name: "Producto", rooms: [{ desks: 1, permanent: true, role: "triage" }, { desks: 2, role: "backend" }] }],
        half_life: "10m",
        capacity: { flex_per_floor: 0, max_extra_floors: 0, outsourcing: false },
      },
      rev: 1,
    });
    const roles = (await owner("GET", `/v1/projects/${gb.id}/roles`)).roles as Json[];
    assert.deepEqual(
      roles.map((r) => [r.name, r.prompt, r.model, r.match_rules, r.wake, r.settings, r.position]),
      [
        ["backend", "", null, {}, [], {}, 0],
        ["triage", "Clasifica los issues nuevos.", "sonnet", { labels: ["bug"] }, ["issue.opened"], { tone: "breve" }, 1],
      ],
    );
    const sync = await hub.agents.refresh(machineId);
    assert.deepEqual(sync?.workspaceIds.sort(), workspaces.map((w) => w.id).sort());

    const detail = await owner("GET", `/v1/imports/${importId}`);
    assert.equal(typeof (detail.import as Json).applied_at, "string");
    assert.deepEqual((detail.projects as Json[]).map((p) => p.conflicts), [["name_taken"], ["name_taken"], ["name_taken"]]);
    const entry = await db().prepare("SELECT action, target_id, machine_id, detail FROM audit_log WHERE action = 'import.applied'").first<Json>();
    assert.equal(entry?.target_id, importId);
    assert.equal(String(entry?.detail).includes("Clasifica"), false);
  });

  it("apply salta name_taken, usa workspace_id o workspace_name y no crea nada si todo se salta", async () => {
    const ws = (await owner("POST", "/v1/workspaces", { name: "Existente" }, 201)).workspace as Json;
    const { machineId, importId } = await offered([profile("awesome-gb", "Awesome GB"), profile("orchestrator", null), profile("libre", null), profile("tomado", "X")]);
    await owner("POST", `/v1/workspaces/${ws.id}/projects`, { name: "tomado" }, 201);
    const rev0 = await structureRev(db());
    structureCalls = [];
    const res = await owner("POST", `/v1/imports/${importId}/apply`, {
      projects: [{ name: "awesome-gb", workspace_id: ws.id }, { name: "orchestrator", workspace_name: "existente" }, { name: "tomado" }],
    });
    assert.deepEqual(res.skipped, [{ name: "tomado", reason: "name_taken" }]);
    const created = res.created as Json[];
    assert.deepEqual(created.map((p) => [p.name, p.workspace_id]), [["awesome-gb", ws.id], ["orchestrator", ws.id]]);
    assert.equal(await structureRev(db()), rev0 + 1);
    assert.deepEqual(structureCalls, [[rev0 + 1, [machineId]]]);
    assert.equal(await db().prepare("SELECT count(*) AS n FROM workspaces").first<number>("n"), 1);

    const personal = await owner("POST", `/v1/imports/${importId}/apply`, { projects: [{ name: "libre" }] });
    const libre = (personal.created as Json[])[0]!;
    const ws2 = (await owner("GET", `/v1/workspaces/${libre.workspace_id}`)).workspace as Json;
    assert.equal(ws2.name, "Personal");

    const rev2 = await structureRev(db());
    const none = await owner("POST", `/v1/imports/${importId}/apply`, { projects: [{ name: "tomado" }, { name: "awesome-gb" }] });
    assert.deepEqual(none, { created: [], skipped: [{ name: "tomado", reason: "name_taken" }, { name: "awesome-gb", reason: "name_taken" }] });
    assert.equal(await structureRev(db()), rev2);
  });

  it("apply valida el cuerpo, 404 con workspace desconocido, 409 si está descartada; DELETE descarta", async () => {
    const { importId } = await offered([profile("awesome-gb", "Awesome GB")]);
    const path = `/v1/imports/${importId}/apply`;
    const status = async (body: unknown, token = ownerToken) => (await call(path, { method: "POST", token, body })).status;
    assert.equal(await status({ projects: [] }), 400);
    assert.equal(await status({ projects: [{ name: "no-ofrecido" }] }), 400);
    assert.equal(await status({ projects: [{ name: "awesome-gb" }, { name: "awesome-gb" }] }), 400);
    assert.equal(await status({ projects: [{ name: "awesome-gb", workspace_id: uuid(), workspace_name: "X" }] }), 400);
    assert.equal(await status({ projects: [{ name: "awesome-gb" }], extra: true }), 400);
    assert.equal(await status({ projects: [{ name: "awesome-gb", workspace_id: uuid() }] }), 404);
    assert.equal(await status({ projects: [{ name: "awesome-gb" }] }, watcherToken), 403);
    assert.equal((await call(`/v1/imports/${uuid()}/apply`, { method: "POST", token: ownerToken, body: { projects: [{ name: "x" }] } })).status, 404);
    assert.equal(await db().prepare("SELECT count(*) AS n FROM projects").first<number>("n"), 0);

    assert.equal((await call(`/v1/imports/${importId}`, { method: "DELETE", token: watcherToken })).status, 403);
    await owner("DELETE", `/v1/imports/${importId}`, undefined, 204);
    await owner("DELETE", `/v1/imports/${importId}`, undefined, 204);
    assert.equal(typeof ((await owner("GET", `/v1/imports/${importId}`)).import as Json).dismissed_at, "string");
    assert.equal(await status({ projects: [{ name: "awesome-gb" }] }), 409);
    assert.equal((await call(`/v1/imports/${uuid()}`, { method: "DELETE", token: ownerToken })).status, 404);
  });

  it("apply con la máquina revocada responde 409 y no escribe", async () => {
    const { machineId, importId } = await offered([profile("awesome-gb", "Awesome GB")]);
    await owner("POST", `/v1/machines/${machineId}/revoke`, undefined, 204);
    assert.equal((await call(`/v1/imports/${importId}/apply`, { method: "POST", token: ownerToken, body: { projects: [{ name: "awesome-gb" }] } })).status, 409);
    assert.equal(await db().prepare("SELECT count(*) AS n FROM workspaces").first<number>("n"), 0);
  });
});
