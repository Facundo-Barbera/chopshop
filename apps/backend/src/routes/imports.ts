import { audit } from "../audit";
import { db, requireOwner } from "../auth";
import { sha256Hex } from "../crypto";
import { type SqlValue, isConstraintError, now, uuid } from "../db";
import { errorResponse, json, noContent } from "../http";
import { type MachinesEnv, machineChanged, workspaceIdsByMachine } from "../machines";
import type { Handler } from "../router";
import {
  type Body,
  MAX_JSON_BYTES,
  NAME_RE,
  UUID_RE,
  bad,
  bumpStructure,
  parseArray,
  readBody,
  structureChanged,
  unknownField,
} from "../structure";
import { P_COLS, type ProjectRow, RUNTIME_MODES, presentProject } from "./projects";
import { slugify } from "./workspaces";

export const MAX_OFFER_BYTES = 768 * 1024;
export const MAX_OFFER_PROJECTS = 256;
export const MAX_APPLY_STATEMENTS = 40;
export const DEFAULT_WORKSPACE = "Personal";
const ROLES_PER_INSERT = 9;
const NOT_FOUND = "importación no encontrada";
const TOP_LEVEL = ["project", "title", "t3_project", "repo", "runtime_mode", "model", "host", "overflow_host", "office", "capacity", "machine_rooms", "registry"];
const OFFICE_KEYS = ["company", "floors", "half_life", "roles"];
const ROLE_KEYS = ["prompt", "prompt_file", "match", "wake", "model"];

type Payload = Record<string, unknown>;

interface OfferRow {
  id: string;
  machine_id: string;
  payload: string;
  summary: string;
  created_at: string;
  applied_at: string | null;
  dismissed_at: string | null;
}

interface WorkspaceRef {
  id: string;
  name: string;
  slug: string;
  isNew: boolean;
}

interface Plan {
  name: string;
  workspace: WorkspaceRef;
  payload: Payload;
}

function isObject(v: unknown): v is Payload {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (isObject(v)) {
    return `{${Object.keys(v)
      .filter((k) => v[k] !== undefined)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(v) ?? "null";
}

function text(v: unknown, min: number, max: number): string | null {
  return typeof v === "string" && v.length >= min && v.length <= max ? v : null;
}

function office(p: Payload): Payload {
  return isObject(p.office) ? p.office : {};
}

function company(p: Payload): string | null {
  const c = office(p).company;
  if (typeof c !== "string") return null;
  return text(c.trim(), 1, 80);
}

function rolesOf(p: Payload): [string, Payload][] {
  const roles = office(p).roles;
  if (!isObject(roles)) return [];
  return Object.entries(roles).filter(([name]) => NAME_RE.test(name)).map(([name, spec]) => [name, isObject(spec) ? spec : {}]);
}

function pick(src: Payload, keys: string[]): Payload {
  return Object.fromEntries(keys.filter((k) => src[k] !== undefined).map((k) => [k, src[k]]));
}

function omit(src: Payload, keys: string[]): Payload {
  return Object.fromEntries(Object.entries(src).filter(([k]) => !keys.includes(k)));
}

function fits(value: string): boolean {
  return new TextEncoder().encode(value).byteLength <= MAX_JSON_BYTES;
}

export function validOffer(projects: unknown): projects is Payload[] {
  if (!Array.isArray(projects) || projects.length < 1 || projects.length > MAX_OFFER_PROJECTS) return false;
  const names = new Set<string>();
  for (const p of projects) {
    if (!isObject(p) || typeof p.project !== "string" || !NAME_RE.test(p.project) || names.has(p.project)) return false;
    if (p.registry !== undefined && !isObject(p.registry)) return false;
    names.add(p.project);
  }
  return true;
}

export async function storeImportOffer(d: D1Database, machineId: string, projects: Payload[]): Promise<{ id: string; status: "stored" | "duplicate" }> {
  const payload = canonical(projects);
  const hash = await sha256Hex(payload);
  const summary = JSON.stringify(projects.map((p) => ({ name: p.project, company: company(p) })));
  const id = uuid();
  const res = await d
    .prepare(
      `INSERT INTO import_offers (id, machine_id, payload_hash, payload, summary, created_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (machine_id, payload_hash) DO NOTHING`,
    )
    .bind(id, machineId, hash, payload, summary, now())
    .run();
  if (res.meta.changes > 0) return { id, status: "stored" };
  const existing = await d.prepare("SELECT id FROM import_offers WHERE machine_id = ? AND payload_hash = ?").bind(machineId, hash).first<string>("id");
  return { id: existing!, status: "duplicate" };
}

function presentOffer(r: OfferRow): Record<string, unknown> {
  return { id: r.id, machine_id: r.machine_id, created_at: r.created_at, summary: parseArray(r.summary), applied_at: r.applied_at, dismissed_at: r.dismissed_at };
}

function payloadOf(r: OfferRow): Payload[] {
  return parseArray(r.payload).filter((p): p is Payload => isObject(p) && typeof p.project === "string" && NAME_RE.test(p.project));
}

function importProject(p: Payload, taken: Set<string>): Record<string, unknown> {
  const roles = rolesOf(p);
  const floors = office(p).floors;
  return {
    name: p.project,
    company: company(p),
    t3_project: text(p.t3_project, 1, 200),
    repo: text(p.repo, 1, 300),
    roles: roles.map(([name]) => name),
    floors: Array.isArray(floors) ? floors.length : 0,
    has_prompts: roles.some(([, spec]) => typeof spec.prompt === "string" && spec.prompt.trim() !== ""),
    conflicts: taken.has(p.project as string) ? ["name_taken"] : [],
  };
}

async function offerById(d: D1Database, id: string): Promise<OfferRow | null> {
  return d
    .prepare("SELECT id, machine_id, payload, summary, created_at, applied_at, dismissed_at FROM import_offers WHERE id = ?")
    .bind(id)
    .first<OfferRow>();
}

async function takenNames(d: D1Database): Promise<Set<string>> {
  const rows = await d.prepare("SELECT name FROM projects WHERE archived_at IS NULL").all<{ name: string }>();
  return new Set(rows.results.map((r) => r.name));
}

const list: Handler<MachinesEnv> = async (_request, { env, principal }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const rows = await db(env)
    .prepare("SELECT id, machine_id, '[]' AS payload, summary, created_at, applied_at, dismissed_at FROM import_offers ORDER BY created_at DESC, id")
    .all<OfferRow>();
  return json({ imports: rows.results.map(presentOffer) });
};

const get: Handler<MachinesEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const offer = await offerById(d, params.id!);
  if (!offer) return errorResponse("not_found", NOT_FOUND);
  const taken = await takenNames(d);
  return json({ import: presentOffer(offer), projects: payloadOf(offer).map((p) => importProject(p, taken)) });
};

interface Wanted {
  name: string;
  workspaceId: string | null;
  workspaceName: string | null;
}

function parseApply(body: Body): Wanted[] | Response {
  const extra = unknownField(body, ["projects"]);
  if (extra) return extra;
  const items = body.projects;
  if (!Array.isArray(items) || items.length < 1 || items.length > MAX_OFFER_PROJECTS) return bad("projects", "projects debe ser una lista no vacía");
  const out: Wanted[] = [];
  const seen = new Set<string>();
  for (const item of items) {
    if (!isObject(item)) return bad("projects", "cada proyecto debe ser un objeto");
    const unknown = unknownField(item, ["name", "workspace_id", "workspace_name"]);
    if (unknown) return unknown;
    if (typeof item.name !== "string" || !NAME_RE.test(item.name)) return bad("name", "name no válido");
    if (seen.has(item.name)) return bad("name", `proyecto repetido: ${item.name}`);
    seen.add(item.name);
    if (item.workspace_id !== undefined && item.workspace_name !== undefined) return bad("workspace_id", "usa workspace_id o workspace_name, no ambos");
    if (item.workspace_id !== undefined && (typeof item.workspace_id !== "string" || !UUID_RE.test(item.workspace_id))) return bad("workspace_id", "workspace_id no válido");
    let workspaceName: string | null = null;
    if (item.workspace_name !== undefined) {
      workspaceName = typeof item.workspace_name === "string" ? text(item.workspace_name.trim(), 1, 80) : null;
      if (workspaceName === null) return bad("workspace_name", "workspace_name debe tener entre 1 y 80 caracteres");
    }
    out.push({ name: item.name, workspaceId: (item.workspace_id as string | undefined) ?? null, workspaceName });
  }
  return out;
}

function projectStatements(d: D1Database, plan: Plan, machineId: string, t: string): D1PreparedStatement[] | null {
  const p = plan.payload;
  const o = office(p);
  const leftover = omit(o, OFFICE_KEYS);
  const settings = omit(p, TOP_LEVEL);
  if (Object.keys(leftover).length > 0) settings.office = leftover;
  const layout = { ...pick(o, ["floors", "half_life"]), ...pick(p, ["capacity", "machine_rooms"]) };
  const settingsText = canonical(settings);
  const layoutText = canonical(layout);
  if (!fits(settingsText) || !fits(layoutText)) return null;
  const registry = isObject(p.registry) ? p.registry : {};
  const id = uuid();
  const stmts = [
    d
      .prepare(
        `INSERT INTO projects (id, workspace_id, name, title, t3_project, repo, machine_id, runtime_mode, model, settings, created_at, updated_at, disabled_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        id,
        plan.workspace.id,
        plan.name,
        text(p.title, 0, 120),
        text(p.t3_project, 1, 200),
        text(p.repo, 1, 300),
        machineId,
        typeof p.runtime_mode === "string" && RUNTIME_MODES.includes(p.runtime_mode) ? p.runtime_mode : "approval-required",
        text(p.model, 1, 120),
        settingsText,
        t,
        t,
        registry.enabled === false ? t : null,
      ),
    d.prepare("INSERT INTO project_layouts (project_id, layout, rev, updated_at) VALUES (?, ?, 1, ?)").bind(id, layoutText, t),
  ];
  const rows: SqlValue[][] = [];
  for (const [index, [name, spec]] of rolesOf(p).entries()) {
    const prompt = typeof spec.prompt === "string" ? spec.prompt : "";
    const match = canonical(isObject(spec.match) ? spec.match : {});
    const wake = canonical(Array.isArray(spec.wake) ? spec.wake : []);
    const rest = canonical(omit(spec, ROLE_KEYS));
    if (![prompt, match, wake, rest].every(fits)) return null;
    rows.push([uuid(), id, name, prompt, text(spec.model, 1, 120), match, wake, rest, index, t, t]);
  }
  for (let i = 0; i < rows.length; i += ROLES_PER_INSERT) {
    const chunk = rows.slice(i, i + ROLES_PER_INSERT);
    stmts.push(
      d
        .prepare(
          `INSERT INTO roles (id, project_id, name, prompt, model, match_rules, wake, settings, position, created_at, updated_at) VALUES ${chunk
            .map(() => "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            .join(", ")}`,
        )
        .bind(...chunk.flat()),
    );
  }
  return stmts;
}

const apply: Handler<MachinesEnv> = async (request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const offer = await offerById(d, params.id!);
  if (!offer) return errorResponse("not_found", NOT_FOUND);
  const body = await readBody(request);
  if (body instanceof Response) return body;
  const wanted = parseApply(body);
  if (wanted instanceof Response) return wanted;
  if (offer.dismissed_at !== null) return errorResponse("conflict", "la importación fue descartada");
  const offered = new Map(payloadOf(offer).map((p) => [p.project as string, p]));
  const missing = wanted.find((w) => !offered.has(w.name));
  if (missing) return bad("name", `el proyecto no está en la importación: ${missing.name}`);
  const machine = await d.prepare("SELECT id, revoked_at FROM machines WHERE id = ?").bind(offer.machine_id).first<{ id: string; revoked_at: string | null }>();
  if (!machine || machine.revoked_at !== null) return errorResponse("conflict", "la máquina que ofreció la importación está revocada");

  const [taken, workspaces, linked] = await Promise.all([
    takenNames(d),
    d.prepare("SELECT id, name, slug, position FROM workspaces WHERE archived_at IS NULL").all<{ id: string; name: string; slug: string; position: number }>(),
    d.prepare("SELECT workspace_id FROM workspace_machines WHERE machine_id = ?").bind(machine.id).all<{ workspace_id: string }>(),
  ]);
  const byId = new Map(workspaces.results.map((w) => [w.id, { id: w.id, name: w.name, slug: w.slug, isNew: false }]));
  const bySlug = new Map([...byId.values()].map((w) => [w.slug, w]));
  let position = Math.max(-1, ...workspaces.results.map((w) => w.position)) + 1;
  const created: WorkspaceRef[] = [];
  const plans: Plan[] = [];
  const skipped: { name: string; reason: string }[] = [];
  for (const w of wanted) {
    const payload = offered.get(w.name)!;
    if (taken.has(w.name)) {
      skipped.push({ name: w.name, reason: "name_taken" });
      continue;
    }
    let workspace: WorkspaceRef | undefined;
    if (w.workspaceId !== null) {
      workspace = byId.get(w.workspaceId);
      if (!workspace) return errorResponse("not_found", "workspace no encontrado");
    } else {
      const wsName = w.workspaceName ?? company(payload) ?? DEFAULT_WORKSPACE;
      const slug = slugify(wsName);
      workspace = bySlug.get(slug);
      if (!workspace) {
        workspace = { id: uuid(), name: wsName, slug, isNew: true };
        bySlug.set(slug, workspace);
        created.push(workspace);
      }
    }
    plans.push({ name: w.name, workspace, payload });
  }

  const t = now();
  const stmts: D1PreparedStatement[] = [];
  const done: Plan[] = [];
  for (const plan of plans) {
    const project = projectStatements(d, plan, machine.id, t);
    if (project === null) {
      skipped.push({ name: plan.name, reason: "too_large" });
      continue;
    }
    stmts.push(...project);
    done.push(plan);
  }
  if (done.length === 0) return json({ created: [], skipped });
  const used = new Set(done.map((plan) => plan.workspace));
  const newWorkspaces = created.filter((w) => used.has(w));
  const linkedIds = new Set(linked.results.map((r) => r.workspace_id));
  const toLink = [...used].filter((w) => !linkedIds.has(w.id));
  const head: D1PreparedStatement[] = [];
  for (const w of newWorkspaces) {
    head.push(
      d
        .prepare("INSERT INTO workspaces (id, owner_id, name, slug, position, style, created_at, updated_at) VALUES (?, ?, ?, ?, ?, '{}', ?, ?)")
        .bind(w.id, owner.userId, w.name, w.slug, position++, t, t),
      d.prepare("INSERT INTO campus_layouts (workspace_id, layout, rev, updated_at) VALUES (?, '{}', 1, ?)").bind(w.id, t),
    );
  }
  for (const w of toLink) {
    head.push(
      d
        .prepare("INSERT INTO workspace_machines (workspace_id, machine_id, created_at) VALUES (?, ?, ?) ON CONFLICT (workspace_id, machine_id) DO NOTHING")
        .bind(w.id, machine.id, t),
    );
  }
  const all = [...head, ...stmts, d.prepare("UPDATE import_offers SET applied_at = ?, applied_by = ? WHERE id = ?").bind(t, owner.userId, offer.id)];
  if (all.length > MAX_APPLY_STATEMENTS) return bad("projects", "demasiados proyectos o roles para aplicar de una vez; aplica menos proyectos por petición");
  let rev: number;
  try {
    rev = await bumpStructure(d, all);
  } catch (err) {
    if (isConstraintError(err, "UNIQUE")) return errorResponse("conflict", "la estructura cambió mientras se aplicaba; vuelve a leer la importación");
    throw err;
  }
  if (toLink.length > 0) {
    const ids = (await workspaceIdsByMachine(d, [machine.id])).get(machine.id) ?? [];
    await machineChanged(env, machine.id, { workspaceIds: ids });
  }
  await structureChanged(env, rev, newWorkspaces.length > 0 ? "all" : [machine.id]);
  await audit(d, {
    actorKind: "user",
    actorUserId: owner.userId,
    sessionId: owner.sessionId,
    machineId: machine.id,
    action: "import.applied",
    targetKind: "import",
    targetId: offer.id,
    status: 200,
    detail: { created: done.map((p) => p.name), skipped: skipped.map((s) => s.name), workspaces_created: newWorkspaces.map((w) => w.id) },
  });
  const names = done.map((p) => p.name);
  const marks = names.map(() => "?").join(", ");
  const rows = await d.prepare(`SELECT ${P_COLS} FROM projects p WHERE p.archived_at IS NULL AND p.name IN (${marks})`).bind(...names).all<ProjectRow>();
  const order = new Map(names.map((n, i) => [n, i]));
  const projects = rows.results.sort((a, b) => order.get(a.name)! - order.get(b.name)!).map(presentProject);
  return json({ created: projects, skipped });
};

const dismiss: Handler<MachinesEnv> = async (_request, { env, principal, params }) => {
  const owner = requireOwner(principal);
  if (owner instanceof Response) return owner;
  const d = db(env);
  const offer = await offerById(d, params.id!);
  if (!offer) return errorResponse("not_found", NOT_FOUND);
  await d.prepare("UPDATE import_offers SET dismissed_at = ? WHERE id = ? AND dismissed_at IS NULL").bind(now(), offer.id).run();
  return noContent();
};

export const importHandlers: Record<string, Handler<MachinesEnv>> = {
  "imports.list": list,
  "imports.get": get,
  "imports.apply": apply,
  "imports.dismiss": dismiss,
};
