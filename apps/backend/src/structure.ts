import type { AuthEnv } from "./auth";
import { errorResponse, readJson } from "./http";

export type Body = Record<string, unknown>;
export type MachineIds = string[] | "all";

export interface SyncRole {
  name: string;
  prompt: string;
  model: string | null;
  match_rules: unknown;
  wake: unknown;
  settings: unknown;
}

export interface SyncProject {
  id: string;
  name: string;
  workspace_id: string;
  title: string | null;
  t3_project: string | null;
  repo: string | null;
  runtime_mode: string;
  model: string | null;
  disabled: boolean;
  settings: unknown;
  layout: unknown;
  roles: SyncRole[];
  rev: number;
}

export interface SyncDoc {
  rev: number;
  machine: { id: string; name: string };
  workspaces: { id: string; name: string; slug: string }[];
  projects: SyncProject[];
}

export interface StructureHub {
  structureChanged?(rev: number, machineIds: MachineIds): Promise<void>;
  viewerChanged?(userId: string): Promise<void>;
}

export const MAX_JSON_BYTES = 256 * 1024;
export const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const LAYOUT_KEYS = ["floors", "half_life", "capacity", "machine_rooms"];

const BUMP = "UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'structure_rev'";

export interface CasGuard {
  table: "workspaces" | "campus_layouts" | "projects" | "project_layouts" | "roles";
  id: string;
  rev: number;
  idColumn?: "id" | "workspace_id" | "project_id";
}

export async function structureBatch(
  db: D1Database,
  stmts: D1PreparedStatement[],
  guard?: CasGuard,
): Promise<{ rev: number | null; results: D1Result[] }> {
  const bump = guard
    ? db
        .prepare(`${BUMP} AND EXISTS (SELECT 1 FROM ${guard.table} WHERE ${guard.idColumn ?? "id"} = ? AND rev = ?) RETURNING value`)
        .bind(guard.id, guard.rev)
    : db.prepare(`${BUMP} RETURNING value`);
  const results = await db.batch([bump, ...stmts]);
  const row = results[0]!.results[0] as { value: string | number } | undefined;
  if (row === undefined && !guard) throw new Error("meta.structure_rev ausente");
  return { rev: row === undefined ? null : Number(row.value), results: results.slice(1) };
}

export async function bumpStructure(db: D1Database, stmts: D1PreparedStatement[]): Promise<number> {
  return (await structureBatch(db, stmts)).rev!;
}

export async function casStructure(
  db: D1Database,
  guard: CasGuard,
  stmts: D1PreparedStatement[],
  current: () => Promise<unknown>,
): Promise<number | Response> {
  const { rev } = await structureBatch(db, stmts, guard);
  if (rev !== null) return rev;
  return errorResponse("conflict", "el recurso cambió; vuelve a leerlo", { current: await current() });
}

export async function structureRev(db: D1Database): Promise<number> {
  const v = await db.prepare("SELECT value FROM meta WHERE key = 'structure_rev'").first<string | number>("value");
  return Number(v ?? 0);
}

function hub(env: AuthEnv): StructureHub | null {
  if (!env.HUB) return null;
  return env.HUB.get(env.HUB.idFromName("owner")) as unknown as StructureHub;
}

async function callHub(env: AuthEnv, code: string, fn: (h: StructureHub) => Promise<void> | undefined): Promise<void> {
  const h = hub(env);
  if (h === null) return;
  try {
    await fn(h);
  } catch (err) {
    console.error(JSON.stringify({ code, error: err instanceof Error ? err.name : "unknown" }));
  }
}

export function machineSet(...ids: (string | null | undefined)[]): string[] {
  return [...new Set(ids.filter((id): id is string => typeof id === "string"))];
}

export function structureChanged(env: AuthEnv, rev: number, machineIds: MachineIds): Promise<void> {
  return callHub(env, "hub_structure_changed", (h) => h.structureChanged?.(rev, machineIds));
}

export function viewerChanged(env: AuthEnv, userId: string): Promise<void> {
  return callHub(env, "hub_viewer_changed", (h) => h.viewerChanged?.(userId));
}

function parse(text: string | null | undefined, fallback: unknown): unknown {
  if (text === null || text === undefined) return fallback;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return fallback;
  }
}

export function parseObject(text: string | null | undefined): Record<string, unknown> {
  const v = parse(text, {});
  return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

export function parseArray(text: string | null | undefined): unknown[] {
  const v = parse(text, []);
  return Array.isArray(v) ? v : [];
}

export async function readBody(request: Request): Promise<Body | Response> {
  const body = await readJson(request);
  if (body instanceof Response) return body;
  if (typeof body !== "object" || body === null || Array.isArray(body)) return errorResponse("bad_request", "se esperaba un objeto JSON");
  return body as Body;
}

export function bad(field: string, message: string): Response {
  return errorResponse("bad_request", message, { field });
}

export function unknownField(body: Body, allowed: readonly string[]): Response | null {
  const extra = Object.keys(body).find((k) => !allowed.includes(k));
  return extra === undefined ? null : bad(extra, `campo desconocido: ${extra}`);
}

function tooBig(text: string): boolean {
  return new TextEncoder().encode(text).byteLength > MAX_JSON_BYTES;
}

export function jsonObject(value: unknown, field: string): string | Response {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return bad(field, `${field} debe ser un objeto JSON`);
  const text = JSON.stringify(value);
  return tooBig(text) ? bad(field, `${field} supera 256 KiB`) : text;
}

export function jsonArray(value: unknown, field: string): string | Response {
  if (!Array.isArray(value)) return bad(field, `${field} debe ser una lista JSON`);
  const text = JSON.stringify(value);
  return tooBig(text) ? bad(field, `${field} supera 256 KiB`) : text;
}

export function layoutObject(value: unknown): string | Response {
  const text = jsonObject(value, "layout");
  if (text instanceof Response) return text;
  const extra = Object.keys(value as object).find((k) => !LAYOUT_KEYS.includes(k));
  return extra === undefined ? text : bad("layout", `clave de layout desconocida: ${extra}`);
}

export function optText(value: unknown, field: string, min: number, max: number): string | null | Response {
  if (value === null) return null;
  if (typeof value !== "string" || value.length < min || value.length > max) return bad(field, `${field} debe ser texto de ${min} a ${max} caracteres o null`);
  return value;
}

export function count(value: unknown, field: string): number | Response {
  return Number.isSafeInteger(value) && (value as number) >= 0 ? (value as number) : bad(field, `${field} debe ser un entero ≥ 0`);
}

export function revOf(body: Body): number | Response {
  const rev = body.rev;
  return Number.isSafeInteger(rev) && (rev as number) >= 1 ? (rev as number) : bad("rev", "falta rev o no es válido");
}

export function name(value: unknown, field = "name"): string | Response {
  return typeof value === "string" && NAME_RE.test(value) ? value : bad(field, `${field} no válido`);
}

interface SyncProjectRow {
  id: string;
  name: string;
  workspace_id: string;
  title: string | null;
  t3_project: string | null;
  repo: string | null;
  runtime_mode: string;
  model: string | null;
  disabled_at: string | null;
  settings: string;
  layout: string | null;
  rev: number;
}

interface SyncRoleRow {
  project_id: string;
  name: string;
  prompt: string;
  model: string | null;
  match_rules: string;
  wake: string;
  settings: string;
}

export async function syncDocFor(db: D1Database, machineId: string): Promise<SyncDoc> {
  const machine = await db.prepare("SELECT id, name FROM machines WHERE id = ?").bind(machineId).first<{ id: string; name: string }>();
  if (!machine) throw new Error("máquina desconocida");
  const [rev, projects, roles, workspaces] = await Promise.all([
    structureRev(db),
    db
      .prepare(
        `SELECT p.id, p.name, p.workspace_id, p.title, p.t3_project, p.repo, p.runtime_mode, p.model, p.disabled_at, p.settings, p.rev, l.layout
         FROM projects p JOIN workspaces w ON w.id = p.workspace_id LEFT JOIN project_layouts l ON l.project_id = p.id
         WHERE p.machine_id = ? AND p.archived_at IS NULL AND w.archived_at IS NULL ORDER BY p.position, p.name`,
      )
      .bind(machineId)
      .all<SyncProjectRow>(),
    db
      .prepare(
        `SELECT r.project_id, r.name, r.prompt, r.model, r.match_rules, r.wake, r.settings
         FROM roles r JOIN projects p ON p.id = r.project_id
         WHERE p.machine_id = ? AND p.archived_at IS NULL ORDER BY r.position, r.name`,
      )
      .bind(machineId)
      .all<SyncRoleRow>(),
    db
      .prepare(
        `SELECT id, name, slug FROM workspaces WHERE archived_at IS NULL AND (
           id IN (SELECT workspace_id FROM workspace_machines WHERE machine_id = ?1)
           OR id IN (SELECT workspace_id FROM projects WHERE machine_id = ?1 AND archived_at IS NULL))
         ORDER BY position, name`,
      )
      .bind(machineId)
      .all<{ id: string; name: string; slug: string }>(),
  ]);
  const byProject = new Map<string, SyncRole[]>();
  for (const r of roles.results) {
    const list = byProject.get(r.project_id) ?? [];
    list.push({
      name: r.name,
      prompt: r.prompt,
      model: r.model,
      match_rules: parseObject(r.match_rules),
      wake: parseArray(r.wake),
      settings: parseObject(r.settings),
    });
    byProject.set(r.project_id, list);
  }
  return {
    rev,
    machine: { id: machine.id, name: machine.name },
    workspaces: workspaces.results.map((w) => ({ id: w.id, name: w.name, slug: w.slug })),
    projects: projects.results.map((p) => ({
      id: p.id,
      name: p.name,
      workspace_id: p.workspace_id,
      title: p.title,
      t3_project: p.t3_project,
      repo: p.repo,
      runtime_mode: p.runtime_mode,
      model: p.model,
      disabled: p.disabled_at !== null,
      settings: parseObject(p.settings),
      layout: parseObject(p.layout),
      roles: byProject.get(p.id) ?? [],
      rev: p.rev,
    })),
  };
}
