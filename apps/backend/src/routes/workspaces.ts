import { assertVisible, visibleWorkspaces } from "../access";
import { audit } from "../audit";
import { type AuthEnv, type UserRow, db, publicUser, requireOwner, requireUser } from "../auth";
import { casUpdate, isConstraintError, now, uuid } from "../db";
import { errorResponse, json, noContent } from "../http";
import type { Handler } from "../router";
import {
  type Body,
  bad,
  bumpStructure,
  casStructure,
  count,
  jsonObject,
  machineWorkspacesChanged,
  parseObject,
  readBody,
  revOf,
  structureChanged,
  unknownField,
  viewerChanged,
} from "../structure";

interface WorkspaceRow {
  id: string;
  name: string;
  slug: string;
  position: number;
  style: string;
  rev: number;
  created_at: string;
  updated_at: string;
}

const COLS = "id, name, slug, position, style, rev, created_at, updated_at";
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const NOT_FOUND = "workspace no encontrado";

export function slugify(name: string): string {
  const s = name
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+/, "")
    .slice(0, 64)
    .replace(/-+$/, "");
  return s === "" ? "workspace" : s;
}

async function activeWorkspace(d: D1Database, id: string): Promise<WorkspaceRow | null> {
  return d.prepare(`SELECT ${COLS} FROM workspaces WHERE id = ? AND archived_at IS NULL`).bind(id).first<WorkspaceRow>();
}

async function present(d: D1Database, rows: WorkspaceRow[], owner: boolean): Promise<Record<string, unknown>[]> {
  if (rows.length === 0) return [];
  const ids = rows.map((r) => r.id);
  const marks = ids.map(() => "?").join(", ");
  const grouped = (sql: string) => d.prepare(sql).bind(...ids).all<{ workspace_id: string; n: number }>();
  const projects = await grouped(`SELECT workspace_id, count(*) AS n FROM projects WHERE archived_at IS NULL AND workspace_id IN (${marks}) GROUP BY workspace_id`);
  const projectCount = new Map(projects.results.map((r) => [r.workspace_id, r.n]));
  const machineIds = new Map<string, string[]>();
  const watcherCount = new Map<string, number>();
  if (owner) {
    const machines = await d
      .prepare(
        `SELECT wm.workspace_id, wm.machine_id FROM workspace_machines wm JOIN machines m ON m.id = wm.machine_id AND m.revoked_at IS NULL
         WHERE wm.workspace_id IN (${marks}) ORDER BY wm.created_at, wm.machine_id`,
      )
      .bind(...ids)
      .all<{ workspace_id: string; machine_id: string }>();
    for (const m of machines.results) machineIds.set(m.workspace_id, [...(machineIds.get(m.workspace_id) ?? []), m.machine_id]);
    const watchers = await grouped(`SELECT workspace_id, count(*) AS n FROM workspace_members WHERE workspace_id IN (${marks}) GROUP BY workspace_id`);
    for (const w of watchers.results) watcherCount.set(w.workspace_id, w.n);
  }
  return rows.map((r) => {
    const out: Record<string, unknown> = {
      id: r.id,
      name: r.name,
      slug: r.slug,
      position: r.position,
      style: parseObject(r.style),
      rev: r.rev,
      project_count: projectCount.get(r.id) ?? 0,
    };
    if (owner) {
      out.machine_ids = machineIds.get(r.id) ?? [];
      out.watcher_count = watcherCount.get(r.id) ?? 0;
    }
    out.created_at = r.created_at;
    out.updated_at = r.updated_at;
    return out;
  });
}

async function presentOne(d: D1Database, row: WorkspaceRow, owner: boolean): Promise<Record<string, unknown>> {
  return (await present(d, [row], owner))[0]!;
}

function workspaceName(value: unknown): string | Response {
  if (typeof value !== "string") return bad("name", "falta name");
  const n = value.trim();
  return n.length >= 1 && n.length <= 80 ? n : bad("name", "name debe tener entre 1 y 80 caracteres");
}

function slugValue(value: unknown): string | Response {
  return typeof value === "string" && SLUG_RE.test(value) ? value : bad("slug", "slug no válido");
}

function slugTaken(err: unknown): Response {
  if (isConstraintError(err, "UNIQUE")) return errorResponse("conflict", "ya existe un workspace con ese slug", { field: "slug" });
  throw err;
}

const list: Handler<AuthEnv> = async (_request, { env, principal }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const d = db(env);
  const visible = await visibleWorkspaces(d, p);
  let rows: WorkspaceRow[];
  if (visible === "all") {
    rows = (await d.prepare(`SELECT ${COLS} FROM workspaces WHERE archived_at IS NULL ORDER BY position, name`).all<WorkspaceRow>()).results;
  } else if (visible.length === 0) {
    rows = [];
  } else {
    const marks = visible.map(() => "?").join(", ");
    rows = (
      await d
        .prepare(`SELECT ${COLS} FROM workspaces WHERE archived_at IS NULL AND id IN (${marks}) ORDER BY position, name`)
        .bind(...visible)
        .all<WorkspaceRow>()
    ).results;
  }
  return json({ workspaces: await present(d, rows, visible === "all") });
};

const create: Handler<AuthEnv> = async (request, { env, principal }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const extra = unknownField(body, ["name", "slug", "position", "style"]);
  if (extra) return extra;
  const name = workspaceName(body.name);
  if (name instanceof Response) return name;
  const slug = body.slug === undefined ? slugify(name) : slugValue(body.slug);
  if (slug instanceof Response) return slug;
  const position = body.position === undefined ? 0 : count(body.position, "position");
  if (position instanceof Response) return position;
  const style = body.style === undefined ? "{}" : jsonObject(body.style, "style");
  if (style instanceof Response) return style;
  const d = db(env);
  const id = uuid();
  const t = now();
  let rev: number;
  try {
    rev = await bumpStructure(d, [
      d
        .prepare(`INSERT INTO workspaces (id, owner_id, name, slug, position, style, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
        .bind(id, owner.userId, name, slug, position, style, t, t),
      d.prepare("INSERT INTO campus_layouts (workspace_id, layout, rev, updated_at) VALUES (?, '{}', 1, ?)").bind(id, t),
    ]);
  } catch (err) {
    return slugTaken(err);
  }
  await structureChanged(env, rev, "all");
  return json({ workspace: await presentOne(d, (await activeWorkspace(d, id))!, true) }, 201);
};

const get: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const d = db(env);
  const hidden = await assertVisible(d, p, params.id!);
  if (hidden) return hidden;
  const row = await activeWorkspace(d, params.id!);
  if (!row) return errorResponse("not_found", NOT_FOUND);
  return json({ workspace: await presentOne(d, row, p.role === "owner") });
};

const update: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const id = params.id!;
  if (!(await activeWorkspace(d, id))) return errorResponse("not_found", NOT_FOUND);
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const extra = unknownField(body, ["rev", "name", "slug", "position", "style"]);
  if (extra) return extra;
  const rev = revOf(body);
  if (rev instanceof Response) return rev;
  const fields = workspaceFields(body);
  if (fields instanceof Response) return fields;
  const current = async () => {
    const row = await activeWorkspace(d, id);
    return row === null ? null : presentOne(d, row, true);
  };
  let result: number | Response;
  try {
    result = await casStructure(d, { table: "workspaces", id, rev }, [casUpdate(d, "workspaces", id, rev, { ...fields, updated_at: now() })], current);
  } catch (err) {
    return slugTaken(err);
  }
  if (result instanceof Response) return result;
  await structureChanged(env, result, "all");
  return json({ workspace: await current() });
};

function workspaceFields(body: Body): Record<string, string | number> | Response {
  const fields: Record<string, string | number> = {};
  if (body.name !== undefined) {
    const v = workspaceName(body.name);
    if (v instanceof Response) return v;
    fields.name = v;
  }
  if (body.slug !== undefined) {
    const v = slugValue(body.slug);
    if (v instanceof Response) return v;
    fields.slug = v;
  }
  if (body.position !== undefined) {
    const v = count(body.position, "position");
    if (v instanceof Response) return v;
    fields.position = v;
  }
  if (body.style !== undefined) {
    const v = jsonObject(body.style, "style");
    if (v instanceof Response) return v;
    fields.style = v;
  }
  return fields;
}

const archive: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const id = params.id!;
  if (!(await activeWorkspace(d, id))) return errorResponse("not_found", NOT_FOUND);
  const busy = await d.prepare("SELECT count(*) AS n FROM projects WHERE workspace_id = ? AND archived_at IS NULL").bind(id).first<number>("n");
  if ((busy ?? 0) > 0) return errorResponse("conflict", "el workspace tiene proyectos sin archivar");
  const t = now();
  const rev = await bumpStructure(d, [
    d.prepare("UPDATE workspaces SET archived_at = ?, updated_at = ?, rev = rev + 1 WHERE id = ? AND archived_at IS NULL").bind(t, t, id),
  ]);
  await structureChanged(env, rev, "all");
  return noContent();
};

async function campusDoc(d: D1Database, workspaceId: string): Promise<{ layout: Record<string, unknown>; rev: number }> {
  const row = await d.prepare("SELECT layout, rev FROM campus_layouts WHERE workspace_id = ?").bind(workspaceId).first<{ layout: string; rev: number }>();
  return row === null ? { layout: {}, rev: 1 } : { layout: parseObject(row.layout), rev: row.rev };
}

const campusGet: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const p = requireUser(principal);
  if (p instanceof Response) return p;
  const d = db(env);
  const hidden = await assertVisible(d, p, params.id!);
  if (hidden) return hidden;
  return json(await campusDoc(d, params.id!));
};

const campusPut: Handler<AuthEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const id = params.id!;
  if (!(await activeWorkspace(d, id))) return errorResponse("not_found", NOT_FOUND);
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const extra = unknownField(body, ["layout", "rev"]);
  if (extra) return extra;
  const rev = revOf(body);
  if (rev instanceof Response) return rev;
  const layout = jsonObject(body.layout, "layout");
  if (layout instanceof Response) return layout;
  const t = now();
  await d.prepare("INSERT INTO campus_layouts (workspace_id, layout, rev, updated_at) VALUES (?, '{}', 1, ?) ON CONFLICT (workspace_id) DO NOTHING").bind(id, t).run();
  const result = await casStructure(
    d,
    { table: "campus_layouts", id, rev, idColumn: "workspace_id" },
    [casUpdate(d, "campus_layouts", id, rev, { layout, updated_at: t }, "workspace_id")],
    () => campusDoc(d, id),
  );
  if (result instanceof Response) return result;
  await structureChanged(env, result, "all");
  return json(await campusDoc(d, id));
};

const watchersList: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  if (!(await activeWorkspace(d, params.id!))) return errorResponse("not_found", NOT_FOUND);
  const rows = await d
    .prepare(
      `SELECT u.id, u.email, u.display_name, u.role, u.status, u.created_at FROM users u
       JOIN workspace_members m ON m.user_id = u.id AND m.workspace_id = ? ORDER BY u.email_normalized`,
    )
    .bind(params.id!)
    .all<UserRow>();
  return json({ watchers: rows.results.map(publicUser) });
};

const watchersAdd: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const id = params.id!;
  const userId = params.user_id!;
  if (!(await activeWorkspace(d, id))) return errorResponse("not_found", NOT_FOUND);
  const user = await d.prepare("SELECT id FROM users WHERE id = ? AND role = 'watcher'").bind(userId).first();
  if (!user) return errorResponse("not_found", "watcher no encontrado");
  const res = await d
    .prepare("INSERT INTO workspace_members (workspace_id, user_id, role, added_by, created_at) VALUES (?, ?, 'watcher', ?, ?) ON CONFLICT (workspace_id, user_id) DO NOTHING")
    .bind(id, userId, owner.userId, now())
    .run();
  if (res.meta.changes > 0) {
    await audit(d, {
      actorKind: "user",
      actorUserId: owner.userId,
      sessionId: owner.sessionId,
      action: "workspace.shared",
      targetKind: "workspace",
      targetId: id,
      status: 204,
      detail: { user_id: userId },
    });
    await viewerChanged(env, userId);
  }
  return noContent();
};

const watchersRemove: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const id = params.id!;
  const userId = params.user_id!;
  const res = await d.prepare("DELETE FROM workspace_members WHERE workspace_id = ? AND user_id = ?").bind(id, userId).run();
  if (res.meta.changes === 0) return errorResponse("not_found", "watcher no encontrado en el workspace");
  await audit(d, {
    actorKind: "user",
    actorUserId: owner.userId,
    sessionId: owner.sessionId,
    action: "workspace.unshared",
    targetKind: "workspace",
    targetId: id,
    status: 204,
    detail: { user_id: userId },
  });
  await viewerChanged(env, userId);
  return noContent();
};

async function machineWorkspaceIds(d: D1Database, machineId: string): Promise<string[]> {
  const rows = await d
    .prepare(
      `SELECT wm.workspace_id FROM workspace_machines wm JOIN workspaces w ON w.id = wm.workspace_id AND w.archived_at IS NULL
       WHERE wm.machine_id = ? ORDER BY wm.workspace_id`,
    )
    .bind(machineId)
    .all<{ workspace_id: string }>();
  return rows.results.map((r) => r.workspace_id);
}

const machinesAdd: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const id = params.id!;
  const machineId = params.machine_id!;
  if (!(await activeWorkspace(d, id))) return errorResponse("not_found", NOT_FOUND);
  const machine = await d.prepare("SELECT id FROM machines WHERE id = ? AND revoked_at IS NULL").bind(machineId).first();
  if (!machine) return errorResponse("not_found", "máquina no encontrada");
  const linked = await d.prepare("SELECT 1 AS x FROM workspace_machines WHERE workspace_id = ? AND machine_id = ?").bind(id, machineId).first();
  if (linked) return noContent();
  const rev = await bumpStructure(d, [
    d
      .prepare("INSERT INTO workspace_machines (workspace_id, machine_id, created_at) VALUES (?, ?, ?) ON CONFLICT (workspace_id, machine_id) DO NOTHING")
      .bind(id, machineId, now()),
  ]);
  await machineWorkspacesChanged(env, machineId, await machineWorkspaceIds(d, machineId));
  await structureChanged(env, rev, [machineId]);
  return noContent();
};

const machinesRemove: Handler<AuthEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const id = params.id!;
  const machineId = params.machine_id!;
  const linked = await d.prepare("SELECT 1 AS x FROM workspace_machines WHERE workspace_id = ? AND machine_id = ?").bind(id, machineId).first();
  if (!linked) return errorResponse("not_found", "la máquina no está en el workspace");
  const busy = await d
    .prepare("SELECT count(*) AS n FROM projects WHERE workspace_id = ? AND machine_id = ? AND archived_at IS NULL")
    .bind(id, machineId)
    .first<number>("n");
  if ((busy ?? 0) > 0) return errorResponse("conflict", "hay proyectos del workspace en esa máquina", { field: "machine_id" });
  const rev = await bumpStructure(d, [d.prepare("DELETE FROM workspace_machines WHERE workspace_id = ? AND machine_id = ?").bind(id, machineId)]);
  await machineWorkspacesChanged(env, machineId, await machineWorkspaceIds(d, machineId));
  await structureChanged(env, rev, [machineId]);
  return noContent();
};

export const workspaceHandlers: Record<string, Handler<AuthEnv>> = {
  "workspaces.list": list,
  "workspaces.create": create,
  "workspaces.get": get,
  "workspaces.update": update,
  "workspaces.archive": archive,
  "campus.get": campusGet,
  "campus.put": campusPut,
  "watchers.list": watchersList,
  "watchers.add": watchersAdd,
  "watchers.remove": watchersRemove,
  "workspace_machines.add": machinesAdd,
  "workspace_machines.remove": machinesRemove,
};
