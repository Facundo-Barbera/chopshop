import { audit } from "../audit";
import { type OwnerCtx, db, requireOwner } from "../auth";
import { apiOrigin, errorResponse, json, noContent, readJson } from "../http";
import {
  LOCAL_MACHINE_ID_RE,
  type MachineRow,
  type MachinesEnv,
  PLATFORMS,
  type Platform,
  activeByLocalId,
  createMachine,
  getMachine,
  listMachines,
  machineChanged,
  onlineMachines,
  ownerWorkspaceIds,
  publicMachine,
  revokeMachine,
  setPaused,
  workspaceIdsByMachine,
} from "../machines";
import type { Handler, RouteCtx } from "../router";

type Body = Record<string, unknown>;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function readBody(request: Request): Promise<Body | Response> {
  const body = await readJson(request);
  if (body instanceof Response) return body;
  if (typeof body !== "object" || body === null || Array.isArray(body)) return errorResponse("bad_request", "se esperaba un objeto JSON");
  return body as Body;
}

function parseName(value: unknown): string | Response {
  const name = typeof value === "string" ? value.trim() : "";
  if (name.length === 0 || [...name].length > 64) return errorResponse("bad_request", "el nombre debe tener entre 1 y 64 caracteres", { field: "name" });
  return name;
}

function parsePlatform(value: unknown): Platform | Response {
  if (typeof value === "string" && (PLATFORMS as readonly string[]).includes(value)) return value as Platform;
  return errorResponse("bad_request", "platform debe ser macos, linux u other", { field: "platform" });
}

async function parseWorkspaces(d: D1Database, ownerId: string, value: unknown): Promise<string[] | Response> {
  const field = { field: "workspace_ids" };
  if (value === undefined || value === null) return (await ownerWorkspaceIds(d, ownerId, null))!;
  if (!Array.isArray(value) || !value.every((v) => typeof v === "string" && UUID.test(v)) || new Set(value).size !== value.length) {
    return errorResponse("bad_request", "workspace_ids debe ser una lista de ids distintos", field);
  }
  return (await ownerWorkspaceIds(d, ownerId, value as string[])) ?? errorResponse("not_found", "workspace no encontrado", field);
}

async function render(env: MachinesEnv, m: MachineRow): Promise<Record<string, unknown>> {
  const ws = await workspaceIdsByMachine(db(env), [m.id]);
  const online = m.revoked_at === null && (await onlineMachines(env)).has(m.id);
  return publicMachine(m, ws.get(m.id) ?? [], online);
}

function auditMachine(d: D1Database, o: OwnerCtx, action: string, machineId: string, status: number, detail: Record<string, unknown> = {}): Promise<string> {
  return audit(d, { actorKind: "user", actorUserId: o.userId, sessionId: o.sessionId, machineId, action, targetKind: "machine", targetId: machineId, status, detail });
}

async function issue(request: Request, env: MachinesEnv, o: OwnerCtx, linkApp: boolean): Promise<Response> {
  const body = await readBody(request);
  if (body instanceof Response) return body;
  let localMachineId: string | null = null;
  if (linkApp) {
    if (typeof body.local_machine_id !== "string" || !LOCAL_MACHINE_ID_RE.test(body.local_machine_id)) {
      return errorResponse("bad_request", "local_machine_id no válido", { field: "local_machine_id" });
    }
    localMachineId = body.local_machine_id;
  }
  const name = parseName(body.name);
  if (name instanceof Response) return name;
  const platform = parsePlatform(body.platform);
  if (platform instanceof Response) return platform;
  const d = db(env);
  const workspaceIds = await parseWorkspaces(d, o.userId, body.workspace_ids);
  if (workspaceIds instanceof Response) return workspaceIds;
  const previous = localMachineId === null ? null : await activeByLocalId(d, o.userId, localMachineId);
  const { row, credential } = await createMachine(d, { ownerId: o.userId, sessionId: o.sessionId, name, platform, localMachineId, workspaceIds }, previous);
  if (previous !== null) {
    await auditMachine(d, o, "machine.revoked", previous, 201, { reason: "relinked", replaced_by: row.id });
    await machineChanged(env, previous, { revoked: true });
  }
  await auditMachine(d, o, linkApp ? "machine.linked" : "machine.token_issued", row.id, 201, { platform, workspace_ids: workspaceIds });
  return json({ machine: publicMachine(row, workspaceIds, false), credential, api_url: apiOrigin(env) }, 201);
}

function owner(ctx: RouteCtx<MachinesEnv>): OwnerCtx | Response {
  return requireOwner(ctx.principal);
}

const list: Handler<MachinesEnv> = async (_request, ctx) => {
  const o = owner(ctx);
  if (o instanceof Response) return o;
  const d = db(ctx.env);
  const rows = await listMachines(d, o.userId);
  const ws = await workspaceIdsByMachine(d, rows.map((m) => m.id));
  const online = rows.length === 0 ? new Set<string>() : await onlineMachines(ctx.env);
  return json({ machines: rows.map((m) => publicMachine(m, ws.get(m.id) ?? [], online.has(m.id))) });
};

const link: Handler<MachinesEnv> = async (request, ctx) => {
  const o = owner(ctx);
  return o instanceof Response ? o : issue(request, ctx.env, o, true);
};

const create: Handler<MachinesEnv> = async (request, ctx) => {
  const o = owner(ctx);
  return o instanceof Response ? o : issue(request, ctx.env, o, false);
};

const notFound = () => errorResponse("not_found", "máquina no encontrada");

const get: Handler<MachinesEnv> = async (_request, ctx) => {
  const o = owner(ctx);
  if (o instanceof Response) return o;
  const m = await getMachine(db(ctx.env), o.userId, ctx.params.id!);
  return m ? json({ machine: await render(ctx.env, m) }) : notFound();
};

const rename: Handler<MachinesEnv> = async (request, ctx) => {
  const o = owner(ctx);
  if (o instanceof Response) return o;
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const name = parseName(body.name);
  if (name instanceof Response) return name;
  const d = db(ctx.env);
  const res = await d.prepare("UPDATE machines SET name = ? WHERE id = ? AND owner_id = ?").bind(name, ctx.params.id!, o.userId).run();
  if (res.meta.changes === 0) return notFound();
  const m = await getMachine(d, o.userId, ctx.params.id!);
  return m ? json({ machine: await render(ctx.env, m) }) : notFound();
};

function pauseHandler(paused: boolean): Handler<MachinesEnv> {
  return async (_request, ctx) => {
    const o = owner(ctx);
    if (o instanceof Response) return o;
    const d = db(ctx.env);
    const id = ctx.params.id!;
    const before = await getMachine(d, o.userId, id);
    if (!before) return notFound();
    if (before.revoked_at !== null) return errorResponse("gone", "máquina revocada");
    if (await setPaused(d, id, paused)) {
      await auditMachine(d, o, paused ? "machine.paused" : "machine.resumed", id, 200);
      await machineChanged(ctx.env, id, { paused });
    }
    const m = await getMachine(d, o.userId, id);
    return m ? json({ machine: await render(ctx.env, m) }) : notFound();
  };
}

const revoke: Handler<MachinesEnv> = async (_request, ctx) => {
  const o = owner(ctx);
  if (o instanceof Response) return o;
  const d = db(ctx.env);
  const id = ctx.params.id!;
  if (!(await getMachine(d, o.userId, id))) return notFound();
  if (await revokeMachine(d, id)) {
    await auditMachine(d, o, "machine.revoked", id, 204);
    await machineChanged(ctx.env, id, { revoked: true });
  }
  return noContent();
};

export const machineHandlers: Record<string, Handler<MachinesEnv>> = {
  "machines.list": list,
  "machines.link": link,
  "machines.create": create,
  "machines.get": get,
  "machines.update": rename,
  "machines.pause": pauseHandler(true),
  "machines.resume": pauseHandler(false),
  "machines.revoke": revoke,
};
