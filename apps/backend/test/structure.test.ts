import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { beforeEach, describe, it } from "node:test";
import { visibleWorkspaces } from "../src/access.ts";
import { newSessionStatement } from "../src/auth.ts";
import { applyMigrations, now, uuid } from "../src/db.ts";
import worker, { type Env } from "../src/index.ts";
import { bumpStructure, structureRev, syncDocFor } from "../src/structure.ts";
import { FakeD1Database } from "./d1.ts";

const API = "https://api.chopshop.novarix.online";
const DIR = new URL("../migrations/", import.meta.url);

type Json = Record<string, unknown>;
type HubCall = [string, ...unknown[]];

let env: Env;
let hubCalls: HubCall[];
let ownerId: string;
let watcherId: string;
let ownerToken: string;
let watcherToken: string;

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
      "INSERT INTO users (id, email, email_normalized, password_hash, role, status, password_changed_at, created_at, updated_at) VALUES (?, ?, ?, 'x', ?, 'active', ?, ?, ?)",
    )
    .bind(id, email, email, role, t, t, t)
    .run();
  return id;
}

async function sessionFor(userId: string): Promise<string> {
  const { session, stmt } = await newSessionStatement(db(), userId, "mac", "Mac mini", null);
  await stmt.run();
  return session.token;
}

async function addMachine(name: string): Promise<string> {
  const id = uuid();
  await db()
    .prepare("INSERT INTO machines (id, owner_id, name, platform, credential_hash, linked_via, created_at) VALUES (?, ?, ?, 'macos', ?, 'app', ?)")
    .bind(id, ownerId, name, uuid(), now())
    .run();
  return id;
}

async function call(token: string, method: string, path: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  return worker.fetch(new Request(`${API}${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }), env);
}

async function ok(res: Response, status = 200): Promise<Json> {
  const text = await res.text();
  assert.equal(res.status, status, text);
  return text === "" ? {} : (JSON.parse(text) as Json);
}

async function owner(method: string, path: string, body?: unknown, status = 200): Promise<Json> {
  return ok(await call(ownerToken, method, path, body), status);
}

async function newWorkspace(name: string): Promise<Json> {
  return (await owner("POST", "/v1/workspaces", { name }, 201)).workspace as Json;
}

async function newProject(workspaceId: string, body: Json): Promise<Json> {
  return (await owner("POST", `/v1/workspaces/${workspaceId}/projects`, body, 201)).project as Json;
}

async function share(workspaceId: string, userId = watcherId): Promise<void> {
  await owner("PUT", `/v1/workspaces/${workspaceId}/watchers/${userId}`, undefined, 204);
}

async function attach(workspaceId: string, machineId: string): Promise<void> {
  await owner("PUT", `/v1/workspaces/${workspaceId}/machines/${machineId}`, undefined, 204);
}

function structureCalls(): unknown[][] {
  return hubCalls.filter((c) => c[0] === "structureChanged").map((c) => c.slice(1));
}

function sorted(ids: unknown): unknown {
  return Array.isArray(ids) ? [...ids].sort() : ids;
}

beforeEach(async () => {
  hubCalls = [];
  const d1 = new FakeD1Database().asD1();
  await applyMigrations(d1, migrations());
  const record = (name: string) => async (...args: unknown[]) => void hubCalls.push([name, ...args]);
  env = {
    DB: d1,
    HUB: {
      idFromName: (name: string) => ({ name }) as unknown as DurableObjectId,
      get: () => ({
        sessionRevoked: record("sessionRevoked"),
        structureChanged: record("structureChanged"),
        viewerChanged: record("viewerChanged"),
        machineChanged: record("machineChanged"),
      }),
    },
  };
  ownerId = await addUser("duenia@ejemplo.test", "owner");
  watcherId = await addUser("mirona@ejemplo.test", "watcher");
  ownerToken = await sessionFor(ownerId);
  watcherToken = await sessionFor(watcherId);
});

describe("workspaces", () => {
  it("crea con slug derivado y campus vacío, y lista para el dueño con machine_ids y watcher_count", async () => {
    const ws = await newWorkspace("Awesome Ñandú GB");
    assert.equal(ws.slug, "awesome-nandu-gb");
    assert.equal(ws.rev, 1);
    assert.equal(ws.project_count, 0);
    assert.deepEqual(ws.machine_ids, []);
    assert.equal(ws.watcher_count, 0);
    assert.deepEqual(await owner("GET", `/v1/workspaces/${ws.id}/campus`), { layout: {}, rev: 1 });
    const dup = await call(ownerToken, "POST", "/v1/workspaces", { name: "Otro", slug: "awesome-nandu-gb" });
    assert.equal(dup.status, 409);
    assert.equal(((await dup.json()) as Json).field, "slug");
    assert.equal((await call(ownerToken, "POST", "/v1/workspaces", { name: "X", extra: 1 })).status, 400);
    const listed = (await owner("GET", "/v1/workspaces")).workspaces as Json[];
    assert.deepEqual(listed.map((w) => w.id), [ws.id]);
  });

  it("PATCH con rev viejo responde 409 con current y no sube structure_rev", async () => {
    const ws = await newWorkspace("Campus");
    const patched = (await owner("PATCH", `/v1/workspaces/${ws.id}`, { rev: 1, name: "Campus Norte", style: { color: "#3a7bd5" } })).workspace as Json;
    assert.equal(patched.rev, 2);
    assert.deepEqual(patched.style, { color: "#3a7bd5" });
    const before = await structureRev(db());
    const res = await call(ownerToken, "PATCH", `/v1/workspaces/${ws.id}`, { rev: 1, name: "Pisado" });
    assert.equal(res.status, 409);
    const body = (await res.json()) as Json;
    assert.equal(body.code, "conflict");
    assert.equal((body.current as Json).rev, 2);
    assert.equal((body.current as Json).name, "Campus Norte");
    assert.equal(await structureRev(db()), before);
  });

  it("campus PUT con CAS y conflicto con current", async () => {
    const ws = await newWorkspace("Campus");
    assert.deepEqual(await owner("PUT", `/v1/workspaces/${ws.id}/campus`, { rev: 1, layout: { streets: [1] } }), { layout: { streets: [1] }, rev: 2 });
    const res = await call(ownerToken, "PUT", `/v1/workspaces/${ws.id}/campus`, { rev: 1, layout: {} });
    assert.equal(res.status, 409);
    assert.deepEqual(((await res.json()) as Json).current, { layout: { streets: [1] }, rev: 2 });
  });

  it("archivar con proyectos da 409; sin proyectos 204 y desaparece", async () => {
    const ws = await newWorkspace("Campus");
    const p = await newProject(ws.id as string, { name: "alpha" });
    assert.equal((await call(ownerToken, "DELETE", `/v1/workspaces/${ws.id}`)).status, 409);
    await owner("DELETE", `/v1/projects/${p.id}`, undefined, 204);
    await owner("DELETE", `/v1/workspaces/${ws.id}`, undefined, 204);
    assert.equal((await call(ownerToken, "GET", `/v1/workspaces/${ws.id}`)).status, 404);
    assert.deepEqual((await owner("GET", "/v1/workspaces")).workspaces, []);
  });

  it("compartir y dejar de compartir: idempotente, audita y avisa al Hub", async () => {
    const ws = await newWorkspace("Campus");
    await share(ws.id as string);
    await share(ws.id as string);
    const watchers = (await owner("GET", `/v1/workspaces/${ws.id}/watchers`)).watchers as Json[];
    assert.deepEqual(watchers.map((u) => u.id), [watcherId]);
    assert.equal(((await owner("GET", `/v1/workspaces/${ws.id}`)).workspace as Json).watcher_count, 1);
    assert.equal((await call(ownerToken, "PUT", `/v1/workspaces/${ws.id}/watchers/${ownerId}`)).status, 404);
    await owner("DELETE", `/v1/workspaces/${ws.id}/watchers/${watcherId}`, undefined, 204);
    assert.equal((await call(ownerToken, "DELETE", `/v1/workspaces/${ws.id}/watchers/${watcherId}`)).status, 404);
    assert.deepEqual(hubCalls.filter((c) => c[0] === "viewerChanged"), [["viewerChanged", watcherId], ["viewerChanged", watcherId]]);
    const actions = await db().prepare("SELECT action FROM audit_log ORDER BY at, action").all<{ action: string }>();
    assert.deepEqual(actions.results.map((a) => a.action).sort(), ["workspace.shared", "workspace.unshared"]);
  });

  it("máquinas del workspace: PUT/DELETE, 409 con proyectos en esa máquina, 404 revocada", async () => {
    const ws = await newWorkspace("Campus");
    const m = await addMachine("mac-mini");
    await attach(ws.id as string, m);
    assert.deepEqual(((await owner("GET", `/v1/workspaces/${ws.id}`)).workspace as Json).machine_ids, [m]);
    assert.deepEqual(hubCalls.find((c) => c[0] === "machineChanged"), ["machineChanged", m, { workspaceIds: [ws.id] }]);
    const p = await newProject(ws.id as string, { name: "alpha", machine_id: m });
    assert.equal((await call(ownerToken, "DELETE", `/v1/workspaces/${ws.id}/machines/${m}`)).status, 409);
    await owner("DELETE", `/v1/projects/${p.id}`, undefined, 204);
    await owner("DELETE", `/v1/workspaces/${ws.id}/machines/${m}`, undefined, 204);
    assert.equal((await call(ownerToken, "DELETE", `/v1/workspaces/${ws.id}/machines/${m}`)).status, 404);
    const revoked = await addMachine("vieja");
    await db().prepare("UPDATE machines SET revoked_at = ? WHERE id = ?").bind(now(), revoked).run();
    assert.equal((await call(ownerToken, "PUT", `/v1/workspaces/${ws.id}/machines/${revoked}`)).status, 404);
  });
});

describe("proyectos, layouts y roles", () => {
  it("machine_id fuera del workspace → 400 al crear y al mover", async () => {
    const a = await newWorkspace("A");
    const b = await newWorkspace("B");
    const m = await addMachine("mac-mini");
    await attach(a.id as string, m);
    const res = await call(ownerToken, "POST", `/v1/workspaces/${b.id}/projects`, { name: "beta", machine_id: m });
    assert.equal(res.status, 400);
    assert.equal(((await res.json()) as Json).field, "machine_id");
    const p = await newProject(a.id as string, { name: "alpha", machine_id: m });
    const moved = await call(ownerToken, "PATCH", `/v1/projects/${p.id}`, { rev: 1, workspace_id: b.id });
    assert.equal(moved.status, 400);
    assert.equal(((await moved.json()) as Json).field, "machine_id");
    const ok2 = (await owner("PATCH", `/v1/projects/${p.id}`, { rev: 1, workspace_id: b.id, machine_id: null })).project as Json;
    assert.equal(ok2.workspace_id, b.id);
    assert.equal(ok2.machine_id, null);
  });

  it("nombre duplicado 409, CAS 409 con current, disabled y archivado", async () => {
    const ws = await newWorkspace("A");
    const p = await newProject(ws.id as string, { name: "alpha", runtime_mode: "auto", settings: { rack: { enabled: true } } });
    assert.equal(p.runtime_mode, "auto");
    assert.deepEqual(p.settings, { rack: { enabled: true } });
    assert.equal(p.disabled, false);
    const dup = await call(ownerToken, "POST", `/v1/workspaces/${ws.id}/projects`, { name: "alpha" });
    assert.equal(dup.status, 409);
    const v2 = (await owner("PATCH", `/v1/projects/${p.id}`, { rev: 1, disabled: true, title: "Alpha" })).project as Json;
    assert.equal(v2.disabled, true);
    assert.equal(v2.rev, 2);
    const stale = await call(ownerToken, "PATCH", `/v1/projects/${p.id}`, { rev: 1, title: "Pisado" });
    assert.equal(stale.status, 409);
    assert.deepEqual(((await stale.json()) as Json).current, v2);
    await owner("DELETE", `/v1/projects/${p.id}`, undefined, 204);
    assert.equal((await call(ownerToken, "GET", `/v1/projects/${p.id}`)).status, 404);
    await newProject(ws.id as string, { name: "alpha" });
  });

  it("layout: solo claves conocidas, CAS con current", async () => {
    const ws = await newWorkspace("A");
    const p = await newProject(ws.id as string, { name: "alpha" });
    assert.deepEqual(await owner("GET", `/v1/projects/${p.id}/layout`), { layout: {}, rev: 1 });
    assert.equal((await call(ownerToken, "PUT", `/v1/projects/${p.id}/layout`, { rev: 1, layout: { otra: 1 } })).status, 400);
    const layout = { floors: [{ name: "Producto", rooms: [{ role: "triage", desks: 1 }] }], half_life: "10m" };
    assert.deepEqual(await owner("PUT", `/v1/projects/${p.id}/layout`, { rev: 1, layout }), { layout, rev: 2 });
    const res = await call(ownerToken, "PUT", `/v1/projects/${p.id}/layout`, { rev: 1, layout: {} });
    assert.equal(res.status, 409);
    assert.deepEqual(((await res.json()) as Json).current, { layout, rev: 2 });
  });

  it("roles: CRUD, CAS, 409 al borrar un rol con salas en el layout", async () => {
    const ws = await newWorkspace("A");
    const p = await newProject(ws.id as string, { name: "alpha" });
    const role = (await owner("POST", `/v1/projects/${p.id}/roles`, { name: "triage", prompt: "Clasifica.", wake: ["issue.opened"], match_rules: { labels: ["bug"] } }, 201)).role as Json;
    assert.equal(role.prompt, "Clasifica.");
    assert.deepEqual(role.wake, ["issue.opened"]);
    assert.equal((await call(ownerToken, "POST", `/v1/projects/${p.id}/roles`, { name: "triage" })).status, 409);
    const v2 = (await owner("PATCH", `/v1/roles/${role.id}`, { rev: 1, prompt: "Nuevo." })).role as Json;
    assert.equal(v2.rev, 2);
    const stale = await call(ownerToken, "PATCH", `/v1/roles/${role.id}`, { rev: 1, prompt: "Pisado." });
    assert.equal(stale.status, 409);
    assert.equal((((await stale.json()) as Json).current as Json).prompt, "Nuevo.");
    await owner("PUT", `/v1/projects/${p.id}/layout`, { rev: 1, layout: { floors: [{ rooms: [{ role: "triage" }] }] } });
    assert.equal((await call(ownerToken, "DELETE", `/v1/roles/${role.id}`)).status, 409);
    await owner("PUT", `/v1/projects/${p.id}/layout`, { rev: 2, layout: { floors: [] } });
    await owner("DELETE", `/v1/roles/${role.id}`, undefined, 204);
    assert.deepEqual((await owner("GET", `/v1/projects/${p.id}/roles`)).roles, []);
  });
});

describe("watcher", () => {
  it("404 fuera de su alcance en workspaces, campus, proyectos, layouts y roles", async () => {
    const hidden = await newWorkspace("Oculto");
    const p = await newProject(hidden.id as string, { name: "alpha" });
    const role = (await owner("POST", `/v1/projects/${p.id}/roles`, { name: "triage" }, 201)).role as Json;
    for (const path of [
      `/v1/workspaces/${hidden.id}`,
      `/v1/workspaces/${hidden.id}/campus`,
      `/v1/workspaces/${hidden.id}/projects`,
      `/v1/projects/${p.id}`,
      `/v1/projects/${p.id}/layout`,
      `/v1/projects/${p.id}/roles`,
    ]) {
      const res = await call(watcherToken, "GET", path);
      assert.equal(res.status, 404, path);
      assert.equal(((await res.json()) as Json).code, "not_found");
    }
    assert.deepEqual((await ok(await call(watcherToken, "GET", "/v1/workspaces"))).workspaces, []);
    assert.equal(role.name, "triage");
  });

  it("403 en toda escritura aunque el workspace esté compartido", async () => {
    const ws = await newWorkspace("Compartido");
    await share(ws.id as string);
    const p = await newProject(ws.id as string, { name: "alpha" });
    const role = (await owner("POST", `/v1/projects/${p.id}/roles`, { name: "triage" }, 201)).role as Json;
    const m = await addMachine("mac-mini");
    const writes: [string, string, unknown?][] = [
      ["POST", "/v1/workspaces", { name: "Nuevo" }],
      ["PATCH", `/v1/workspaces/${ws.id}`, { rev: 1, name: "X" }],
      ["DELETE", `/v1/workspaces/${ws.id}`],
      ["PUT", `/v1/workspaces/${ws.id}/campus`, { rev: 1, layout: {} }],
      ["PUT", `/v1/workspaces/${ws.id}/watchers/${watcherId}`],
      ["DELETE", `/v1/workspaces/${ws.id}/watchers/${watcherId}`],
      ["PUT", `/v1/workspaces/${ws.id}/machines/${m}`],
      ["DELETE", `/v1/workspaces/${ws.id}/machines/${m}`],
      ["POST", `/v1/workspaces/${ws.id}/projects`, { name: "beta" }],
      ["PATCH", `/v1/projects/${p.id}`, { rev: 1, title: "X" }],
      ["DELETE", `/v1/projects/${p.id}`],
      ["PUT", `/v1/projects/${p.id}/layout`, { rev: 1, layout: {} }],
      ["POST", `/v1/projects/${p.id}/roles`, { name: "otro" }],
      ["PATCH", `/v1/roles/${role.id}`, { rev: 1, prompt: "X" }],
      ["DELETE", `/v1/roles/${role.id}`],
    ];
    const rev = await structureRev(db());
    for (const [method, path, body] of writes) {
      const res = await call(watcherToken, method, path, body);
      assert.equal(res.status, 403, `${method} ${path}`);
    }
    assert.equal(await structureRev(db()), rev);
    assert.equal((await call(watcherToken, "GET", `/v1/workspaces/${ws.id}/watchers`)).status, 403);
  });

  it("ve lo compartido sin machine_ids ni watcher_count y roles sin prompt", async () => {
    const ws = await newWorkspace("Compartido");
    await newWorkspace("Oculto");
    await share(ws.id as string);
    const p = await newProject(ws.id as string, { name: "alpha" });
    await owner("POST", `/v1/projects/${p.id}/roles`, { name: "triage", prompt: "Secreto.", match_rules: { a: 1 }, wake: ["x"], settings: { b: 2 } }, 201);
    const listed = (await ok(await call(watcherToken, "GET", "/v1/workspaces"))).workspaces as Json[];
    assert.deepEqual(listed.map((w) => w.id), [ws.id]);
    assert.equal(listed[0]!.project_count, 1);
    assert.equal("machine_ids" in listed[0]!, false);
    assert.equal("watcher_count" in listed[0]!, false);
    const roles = (await ok(await call(watcherToken, "GET", `/v1/projects/${p.id}/roles`))).roles as Json[];
    assert.deepEqual(Object.keys(roles[0]!).sort(), ["created_at", "id", "model", "name", "position", "project_id", "rev", "updated_at"]);
    assert.equal(JSON.stringify(roles).includes("Secreto"), false);
    const projects = (await ok(await call(watcherToken, "GET", `/v1/workspaces/${ws.id}/projects`))).projects as Json[];
    assert.deepEqual(projects.map((x) => x.id), [p.id]);
    assert.deepEqual(await visibleWorkspaces(db(), { kind: "user", userId: watcherId, role: "watcher", sessionId: "s", client: "mac", viaCookie: false }), [ws.id]);
  });
});

describe("structure_rev y structureChanged", () => {
  it("sube en cada escritura y avisa a las máquinas afectadas", async () => {
    const ws = await newWorkspace("A");
    assert.deepEqual(structureCalls(), [[1, "all"]]);
    const m1 = await addMachine("mac-mini");
    const m2 = await addMachine("macbook-air");
    await attach(ws.id as string, m1);
    await attach(ws.id as string, m2);
    assert.deepEqual(structureCalls().slice(1), [[2, [m1]], [3, [m2]]]);
    await attach(ws.id as string, m1);
    assert.equal(structureCalls().length, 3);

    hubCalls = [];
    const p = await newProject(ws.id as string, { name: "alpha", machine_id: m1 });
    assert.deepEqual(structureCalls(), [[4, [m1]]]);
    await owner("PATCH", `/v1/projects/${p.id}`, { rev: 1, machine_id: m2 });
    assert.deepEqual(structureCalls()[1]![0], 5);
    assert.deepEqual(sorted(structureCalls()[1]![1]), [m1, m2].sort());
    await owner("PUT", `/v1/projects/${p.id}/layout`, { rev: 1, layout: { floors: [] } });
    const role = (await owner("POST", `/v1/projects/${p.id}/roles`, { name: "triage" }, 201)).role as Json;
    await owner("PATCH", `/v1/roles/${role.id}`, { rev: 1, prompt: "x" });
    await owner("DELETE", `/v1/roles/${role.id}`, undefined, 204);
    assert.deepEqual(structureCalls().slice(2), [[6, [m2]], [7, [m2]], [8, [m2]], [9, [m2]]]);
    const free = await newProject(ws.id as string, { name: "libre" });
    assert.deepEqual(structureCalls()[6], [10, []]);
    await owner("PATCH", `/v1/workspaces/${ws.id}`, { rev: 1, position: 3 });
    await owner("PUT", `/v1/workspaces/${ws.id}/campus`, { rev: 1, layout: {} });
    assert.deepEqual(structureCalls().slice(7), [[11, "all"], [12, "all"]]);
    await owner("DELETE", `/v1/projects/${free.id}`, undefined, 204);
    await owner("DELETE", `/v1/projects/${p.id}`, undefined, 204);
    assert.deepEqual(structureCalls().slice(9), [[13, []], [14, [m2]]]);
    assert.equal(await structureRev(db()), 14);
  });

  it("bumpStructure es atómico: si falla una sentencia no sube la revisión", async () => {
    const before = await structureRev(db());
    await assert.rejects(bumpStructure(db(), [db().prepare("INSERT INTO workspaces (id) VALUES (?)").bind(uuid())]));
    assert.equal(await structureRev(db()), before);
    assert.equal(await bumpStructure(db(), []), before + 1);
  });

  it("syncDocFor arma el documento de la máquina con roles, layout y sus workspaces", async () => {
    const a = await newWorkspace("Awesome GB");
    const b = await newWorkspace("Otro");
    const m = await addMachine("mac-mini");
    const other = await addMachine("macbook-air");
    await attach(a.id as string, m);
    await attach(b.id as string, other);
    const p = await newProject(a.id as string, { name: "awesome-gb", title: "Awesome GB", machine_id: m, settings: { rack: { enabled: true } } });
    await newProject(b.id as string, { name: "ajeno", machine_id: other });
    await owner("PUT", `/v1/projects/${p.id}/layout`, { rev: 1, layout: { half_life: "10m" } });
    await owner("POST", `/v1/projects/${p.id}/roles`, { name: "triage", prompt: "Clasifica.", wake: ["issue.opened"] }, 201);
    await owner("PATCH", `/v1/projects/${p.id}`, { rev: 1, disabled: true });
    const doc = await syncDocFor(db(), m);
    assert.equal(doc.rev, await structureRev(db()));
    assert.deepEqual(doc.machine, { id: m, name: "mac-mini" });
    assert.deepEqual(doc.workspaces, [{ id: a.id, name: "Awesome GB", slug: "awesome-gb" }]);
    assert.equal(doc.projects.length, 1);
    const sp = doc.projects[0]!;
    assert.equal(sp.name, "awesome-gb");
    assert.equal(sp.disabled, true);
    assert.equal(sp.rev, 2);
    assert.deepEqual(sp.layout, { half_life: "10m" });
    assert.deepEqual(sp.settings, { rack: { enabled: true } });
    assert.deepEqual(sp.roles, [{ name: "triage", prompt: "Clasifica.", model: null, match_rules: {}, wake: ["issue.opened"], settings: {} }]);
  });
});
