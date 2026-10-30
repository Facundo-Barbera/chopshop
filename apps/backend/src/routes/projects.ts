import { assertVisible, canSee } from "../access";
import { type AuthEnv, type UserPrincipal, db, requireOwner, requireUser } from "../auth";
import { type SqlValue, casUpdate, isConstraintError, now, uuid } from "../db";
import { errorResponse, json, noContent } from "../http";
import type { Handler } from "../router";
import {
  type Body,
  bad,
  bumpStructure,
  casStructure,
  count,
  jsonArray,
  jsonObject,
  layoutObject,
  machineSet,
  name,
  optText,
  parseArray,
  parseObject,
  readBody,
  revOf,
  structureChanged,
  unknownField,
} from "../structure";

interface ProjectRow {
  id: string;
  workspace_id: string;
  name: string;
  title: string | null;
  t3_project: string | null;
  repo: string | null;
  machine_id: string | null;
  runtime_mode: string;
  model: string | null;
  settings: string;
  position: number;
  rev: number;
  created_at: string;
  updated_at: string;
  disabled_at: string | null;
}

interface RoleRow {
  id: string;
  project_id: string;
  name: string;
  prompt: string;
  model: string | null;
  match_rules: string;
  wake: string;
  settings: string;
  position: number;
  rev: number;
  created_at: string;
  updated_at: string;
}

const P_COLS = "p.id, p.workspace_id, p.name, p.title, p.t3_project, p.repo, p.machine_id, p.runtime_mode, p.model, p.settings, p.position, p.rev, p.created_at, p.updated_at, p.disabled_at";
const R_COLS = "r.id, r.project_id, r.name, r.prompt, r.model, r.match_rules, r.wake, r.settings, r.position, r.rev, r.created_at, r.updated_at";
const ACTIVE = "p.archived_at IS NULL AND w.archived_at IS NULL";
const RUNTIME_MODES = ["approval-required", "auto-accept-edits", "auto", "full-access"];
const PROJECT_FIELDS = ["name", "title", "t3_project", "repo", "machine_id", "runtime_mode", "model", "settings"];
const ROLE_FIELDS = ["name", "prompt", "model", "match_rules", "wake", "settings", "position"];
const PROJECT_NOT_FOUND = "proyecto no encontrado";
const ROLE_NOT_FOUND = "rol no encontrado";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function presentProject(r: ProjectRow): Record<string, unknown> {
  return {
    id: r.id,
    workspace_id: r.workspace_id,
    name: r.name,
    title: r.title,
    t3_project: r.t3_project,
    repo: r.repo,
    machine_id: r.machine_id,
    runtime_mode: r.runtime_mode,
    model: r.model,
    settings: parseObject(r.settings),
    position: r.position,
    disabled: r.disabled_at !== null,
    rev: r.rev,
    created_at: r.created_at,
    updated_at: r.updated_at,
  };
}

function presentRole(r: RoleRow, owner: boolean): Record<string, unknown> {
  if (!owner) {
    return { id: r.id, project_id: r.project_id, name: r.name, model: r.model, position: r.position, rev: r.rev, created_at: r.created_at, updated_at: r.updated_at };
  }
  return {
    id: r.id,
    project_id: r.project_id,
    name: r.name,
    prompt: r.prompt,
    model: r.model,
    match_rules: parseObject(r.match_rules),
    wake: parseArray(r.wake),
    settings: parseObject(r.settings),
    position: r.position,
    rev: r.rev,
    created_at: r.created_at,
    updated_at: r.updated_at,
  };
}

async function activeProject(d: D1Database, id: string): Promise<ProjectRow | null> {
  return d
    .prepare(`SELECT ${P_COLS} FROM projects p JOIN workspaces w ON w.id = p.workspace_id WHERE p.id = ? AND ${ACTIVE}`)
    .bind(id)
    .first<ProjectRow>();
}

async function visibleProject(d: D1Database, p: UserPrincipal, id: string): Promise<ProjectRow | Response> {
  const row = await activeProject(d, id);
  if (!row || !(await canSee(d, p, row.workspace_id))) return errorResponse("not_found", PROJECT_NOT_FOUND);
  return row;
}

async function activeRole(d: D1Database, id: string): Promise<(RoleRow & { machine_id: string | null; workspace_id: string }) | null> {
  return d
    .prepare(
      `SELECT ${R_COLS}, p.machine_id, p.workspace_id FROM roles r JOIN projects p ON p.id = r.project_id JOIN workspaces w ON w.id = p.workspace_id
       WHERE r.id = ? AND ${ACTIVE}`,
    )
    .bind(id)
    .first<RoleRow & { machine_id: string | null; workspace_id: string }>();
}

async function activeWorkspaceExists(d: D1Database, id: string): Promise<boolean> {
  return (await d.prepare("SELECT id FROM workspaces WHERE id = ? AND archived_at IS NULL").bind(id).first()) !== null;
}

async function machineInWorkspace(d: D1Database, workspaceId: string, machineId: string): Promise<boolean> {
  const row = await d
    .prepare(
      `SELECT 1 AS x FROM workspace_machines wm JOIN machines m ON m.id = wm.machine_id AND m.revoked_at IS NULL
       WHERE wm.workspace_id = ? AND wm.machine_id = ?`,
    )
    .bind(workspaceId, machineId)
    .first();
  return row !== null;
}

function nameTaken(err: unknown, what: string): Response {
  if (isConstraintError(err, "UNIQUE")) return errorResponse("conflict", `ya existe un ${what} con ese nombre`, { field: "name" });
  throw err;
}

type Checks = [string, () => SqlValue | Response][];

function collect(body: Body, checks: Checks): Record<string, SqlValue> | Response {
  const fields: Record<string, SqlValue> = {};
  for (const [field, check] of checks) {
    if (body[field] === undefined) continue;
    const v = check();
    if (v instanceof Response) return v;
    fields[field] = v;
  }
  return fields;
}

function projectFields(body: Body): Record<string, SqlValue> | Response {
  return collect(body, [
    ["name", () => name(body.name)],
    ["title", () => optText(body.title, "title", 0, 120)],
    ["t3_project", () => optText(body.t3_project, "t3_project", 1, 200)],
    ["repo", () => optText(body.repo, "repo", 1, 300)],
    ["machine_id", () => (body.machine_id === null || (typeof body.machine_id === "string" && UUID.test(body.machine_id)) ? body.machine_id : bad("machine_id", "machine_id no válido"))],
    ["runtime_mode", () => (typeof body.runtime_mode === "string" && RUNTIME_MODES.includes(body.runtime_mode) ? body.runtime_mode : bad("runtime_mode", "runtime_mode no válido"))],
    ["model", () => optText(body.model, "model", 1, 120)],
    ["settings", () => jsonObject(body.settings, "settings")],
  ]);
}

function roleFields(body: Body): Record<string, SqlValue> | Response {
  return collect(body, [
    ["name", () => name(body.name)],
    ["prompt", () => (typeof body.prompt === "string" && body.prompt.length <= 262144 ? body.prompt : bad("prompt", "prompt debe ser texto de hasta 256 KiB"))],
    ["model", () => optText(body.model, "model", 1, 120)],
    ["match_rules", () => jsonObject(body.match_rules, "match_rules")],
    ["wake", () => jsonArray(body.wake, "wake")],
    ["settings", () => jsonObject(body.settings, "settings")],
    ["position", () => count(body.position, "position")],
  ]);
}

const list: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const d = db(env);
  const hidden = await assertVisible(d, p, params.id!);
  if (hidden) return hidden;
  const rows = await d
    .prepare(`SELECT ${P_COLS} FROM projects p JOIN workspaces w ON w.id = p.workspace_id WHERE p.workspace_id = ? AND ${ACTIVE} ORDER BY p.position, p.name`)
    .bind(params.id!)
    .all<ProjectRow>();
  return json({ projects: rows.results.map(presentProject) });
};

const create: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const workspaceId = params.id!;
  if (!(await activeWorkspaceExists(d, workspaceId))) return errorResponse("not_found", "workspace no encontrado");
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const extra = unknownField(body, PROJECT_FIELDS);
  if (extra) return extra;
  if (body.name === undefined) return bad("name", "falta name");
  const fields = projectFields(body);
  if (fields instanceof Response) return fields;
  const machineId = (fields.machine_id as string | null | undefined) ?? null;
  if (machineId !== null && !(await machineInWorkspace(d, workspaceId, machineId))) return bad("machine_id", "la máquina no está en el workspace");
  const id = uuid();
  const t = now();
  let rev: number;
  try {
    rev = await bumpStructure(d, [
      d
        .prepare(
          `INSERT INTO projects (id, workspace_id, name, title, t3_project, repo, machine_id, runtime_mode, model, settings, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(
          id,
          workspaceId,
          fields.name!,
          fields.title ?? null,
          fields.t3_project ?? null,
          fields.repo ?? null,
          machineId,
          fields.runtime_mode ?? "approval-required",
          fields.model ?? null,
          fields.settings ?? "{}",
          t,
          t,
        ),
      d.prepare("INSERT INTO project_layouts (project_id, layout, rev, updated_at) VALUES (?, '{}', 1, ?)").bind(id, t),
    ]);
  } catch (err) {
    return nameTaken(err, "proyecto");
  }
  await structureChanged(env, rev, machineSet(machineId));
  return json({ project: presentProject((await activeProject(d, id))!) }, 201);
};

const get: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const row = await visibleProject(db(env), p, params.id!);
  return row instanceof Response ? row : json({ project: presentProject(row) });
};

const update: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const id = params.id!;
  const before = await activeProject(d, id);
  if (!before) return errorResponse("not_found", PROJECT_NOT_FOUND);
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const extra = unknownField(body, ["rev", "workspace_id", "disabled", ...PROJECT_FIELDS]);
  if (extra) return extra;
  const rev = revOf(body);
  if (rev instanceof Response) return rev;
  const fields = projectFields(body);
  if (fields instanceof Response) return fields;
  if (body.workspace_id !== undefined) {
    if (typeof body.workspace_id !== "string" || !UUID.test(body.workspace_id)) return bad("workspace_id", "workspace_id no válido");
    if (!(await activeWorkspaceExists(d, body.workspace_id))) return errorResponse("not_found", "workspace no encontrado");
    fields.workspace_id = body.workspace_id;
  }
  if (body.disabled !== undefined) {
    if (typeof body.disabled !== "boolean") return bad("disabled", "disabled debe ser booleano");
    fields.disabled_at = body.disabled ? (before.disabled_at ?? now()) : null;
  }
  const workspaceId = (fields.workspace_id as string | undefined) ?? before.workspace_id;
  const machineId = fields.machine_id === undefined ? before.machine_id : (fields.machine_id as string | null);
  if (machineId !== null && (fields.machine_id !== undefined || fields.workspace_id !== undefined) && !(await machineInWorkspace(d, workspaceId, machineId))) {
    return bad("machine_id", "la máquina no está en el workspace");
  }
  const current = async () => {
    const row = await activeProject(d, id);
    return row === null ? null : presentProject(row);
  };
  let result: number | Response;
  try {
    result = await casStructure(d, { table: "projects", id, rev }, [casUpdate(d, "projects", id, rev, { ...fields, updated_at: now() })], current);
  } catch (err) {
    return nameTaken(err, "proyecto");
  }
  if (result instanceof Response) return result;
  await structureChanged(env, result, machineSet(before.machine_id, machineId));
  return json({ project: await current() });
};

const archive: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const before = await activeProject(d, params.id!);
  if (!before) return errorResponse("not_found", PROJECT_NOT_FOUND);
  const t = now();
  const rev = await bumpStructure(d, [
    d.prepare("UPDATE projects SET archived_at = ?, updated_at = ?, rev = rev + 1 WHERE id = ? AND archived_at IS NULL").bind(t, t, before.id),
  ]);
  await structureChanged(env, rev, machineSet(before.machine_id));
  return noContent();
};

async function layoutDoc(d: D1Database, projectId: string): Promise<{ layout: Record<string, unknown>; rev: number }> {
  const row = await d.prepare("SELECT layout, rev FROM project_layouts WHERE project_id = ?").bind(projectId).first<{ layout: string; rev: number }>();
  return row === null ? { layout: {}, rev: 1 } : { layout: parseObject(row.layout), rev: row.rev };
}

const layoutGet: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const d = db(env);
  const row = await visibleProject(d, p, params.id!);
  return row instanceof Response ? row : json(await layoutDoc(d, row.id));
};

const layoutPut: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const project = await activeProject(d, params.id!);
  if (!project) return errorResponse("not_found", PROJECT_NOT_FOUND);
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const extra = unknownField(body, ["layout", "rev"]);
  if (extra) return extra;
  const rev = revOf(body);
  if (rev instanceof Response) return rev;
  const layout = layoutObject(body.layout);
  if (layout instanceof Response) return layout;
  const t = now();
  await d.prepare("INSERT INTO project_layouts (project_id, layout, rev, updated_at) VALUES (?, '{}', 1, ?) ON CONFLICT (project_id) DO NOTHING").bind(project.id, t).run();
  const result = await casStructure(
    d,
    { table: "project_layouts", id: project.id, rev, idColumn: "project_id" },
    [casUpdate(d, "project_layouts", project.id, rev, { layout, updated_at: t }, "project_id")],
    () => layoutDoc(d, project.id),
  );
  if (result instanceof Response) return result;
  await structureChanged(env, result, machineSet(project.machine_id));
  return json(await layoutDoc(d, project.id));
};

const rolesList: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const d = db(env);
  const project = await visibleProject(d, p, params.id!);
  if (project instanceof Response) return project;
  const rows = await d.prepare(`SELECT ${R_COLS} FROM roles r WHERE r.project_id = ? ORDER BY r.position, r.name`).bind(project.id).all<RoleRow>();
  return json({ roles: rows.results.map((r) => presentRole(r, p.role === "owner")) });
};

async function roleById(d: D1Database, id: string): Promise<RoleRow | null> {
  return d.prepare(`SELECT ${R_COLS} FROM roles r WHERE r.id = ?`).bind(id).first<RoleRow>();
}

const rolesCreate: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const project = await activeProject(d, params.id!);
  if (!project) return errorResponse("not_found", PROJECT_NOT_FOUND);
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const extra = unknownField(body, ROLE_FIELDS);
  if (extra) return extra;
  if (body.name === undefined) return bad("name", "falta name");
  const fields = roleFields(body);
  if (fields instanceof Response) return fields;
  const id = uuid();
  const t = now();
  let rev: number;
  try {
    rev = await bumpStructure(d, [
      d
        .prepare(
          `INSERT INTO roles (id, project_id, name, prompt, model, match_rules, wake, settings, position, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(
          id,
          project.id,
          fields.name!,
          fields.prompt ?? "",
          fields.model ?? null,
          fields.match_rules ?? "{}",
          fields.wake ?? "[]",
          fields.settings ?? "{}",
          fields.position ?? 0,
          t,
          t,
        ),
    ]);
  } catch (err) {
    return nameTaken(err, "rol");
  }
  await structureChanged(env, rev, machineSet(project.machine_id));
  return json({ role: presentRole((await roleById(d, id))!, true) }, 201);
};

const rolesUpdate: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const role = await activeRole(d, params.id!);
  if (!role) return errorResponse("not_found", ROLE_NOT_FOUND);
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const extra = unknownField(body, ["rev", ...ROLE_FIELDS]);
  if (extra) return extra;
  const rev = revOf(body);
  if (rev instanceof Response) return rev;
  const fields = roleFields(body);
  if (fields instanceof Response) return fields;
  const current = async () => {
    const row = await roleById(d, role.id);
    return row === null ? null : presentRole(row, true);
  };
  let result: number | Response;
  try {
    result = await casStructure(d, { table: "roles", id: role.id, rev }, [casUpdate(d, "roles", role.id, rev, { ...fields, updated_at: now() })], current);
  } catch (err) {
    return nameTaken(err, "rol");
  }
  if (result instanceof Response) return result;
  await structureChanged(env, result, machineSet(role.machine_id));
  return json({ role: await current() });
};

function layoutUsesRole(layout: Record<string, unknown>, roleName: string): boolean {
  const floors = Array.isArray(layout.floors) ? layout.floors : [];
  return floors.some((floor) => {
    const rooms = typeof floor === "object" && floor !== null && Array.isArray((floor as Body).rooms) ? ((floor as Body).rooms as unknown[]) : [];
    return rooms.some((room) => typeof room === "object" && room !== null && (room as Body).role === roleName);
  });
}

const rolesDelete: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const role = await activeRole(d, params.id!);
  if (!role) return errorResponse("not_found", ROLE_NOT_FOUND);
  if (layoutUsesRole((await layoutDoc(d, role.project_id)).layout, role.name)) {
    return errorResponse("conflict", "el layout aún tiene salas de ese rol");
  }
  const rev = await bumpStructure(d, [d.prepare("DELETE FROM roles WHERE id = ?").bind(role.id)]);
  await structureChanged(env, rev, machineSet(role.machine_id));
  return noContent();
};

export const projectHandlers: Record<string, Handler<AuthEnv>> = {
  "projects.list": list,
  "projects.create": create,
  "projects.get": get,
  "projects.update": update,
  "projects.archive": archive,
  "layout.get": layoutGet,
  "layout.put": layoutPut,
  "roles.list": rolesList,
  "roles.create": rolesCreate,
  "roles.update": rolesUpdate,
  "roles.delete": rolesDelete,
};
