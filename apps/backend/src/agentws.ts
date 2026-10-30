import { isConstraintError, now as isoNow } from "./db";
import { ulid } from "./http";
import { LOCAL_MACHINE_ID_RE, type MachineCtx } from "./machines";
import { MAX_OFFER_BYTES, storeImportOffer, validOffer } from "./routes/imports";
import { structureRev, syncDocFor } from "./structure";

export const MAX_FRAME_BYTES = 1_048_576;
export const PING_INTERVAL_S = 30;
export const PROTOCOL = 2;
export const SNAPSHOT_TTL_MIN_S = 30;
export const SNAPSHOT_TTL_MAX_S = 900;
export const SNAPSHOT_TTL_DEFAULT_S = 120;
const HELLO_TIMEOUT_MS = 10_000;
const IDLE_TIMEOUT_MS = PING_INTERVAL_S * 3 * 1000;
const SNAPSHOT_MIN_INTERVAL_MS = 5_000;
const EVENT_WINDOW_MS = 1_000;
const EVENT_MAX_PER_WINDOW = 50;
const TOUCH_INTERVAL_MS = 60_000;
export const AGENT_TAG = "agent";
const MSG_ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]{1,32})?$/;
const SNAPSHOT_KEYS: ReadonlySet<string> = new Set([
  "v", "type", "id", "ts", "machine_id", "workspace_id", "seq", "ttl_s", "agent_version", "health", "counts", "projects", "parts",
]);
const OFFER_KEYS: ReadonlySet<string> = new Set(["v", "type", "id", "ts", "projects"]);
const SYNC_ACK_KEYS: ReadonlySet<string> = new Set(["v", "type", "id", "ts", "re", "rev", "applied", "errors"]);
const MAX_SYNC_ERRORS = 256;
const MAX_SYNC_MESSAGE = 512;
const EVENT_KEYS: ReadonlySet<string> = new Set([
  "v", "type", "id", "ts", "machine_id", "workspace_id", "event_id", "seq", "event_ts", "project", "event_type", "severity", "needs", "subject", "body",
]);

export type WsErrorCode =
  | "bad_request"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "too_large"
  | "rate_limited"
  | "unsupported_version"
  | "internal";

const STATUS: Record<WsErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  too_large: 413,
  rate_limited: 429,
  unsupported_version: 426,
  internal: 500,
};

export interface StoredSnapshot {
  machineId: string;
  workspaceId: string | null;
  seq: number;
  ttlS: number;
  frame: string;
  receivedAt: number;
  expiresAt: number;
}

export interface CachedMachine {
  machineId: string;
  name: string;
  workspaceIds: string[];
  paused: boolean;
  revoked: boolean;
}

export interface SyncError {
  project: string;
  message: string;
}

export interface SyncStatus {
  machineId: string;
  rev: number;
  errors: SyncError[];
  ackedAt: number;
}

type SyncStatusRow = {
  machine_id: string;
  rev: number;
  errors: string;
  acked_at: number;
};

type SnapshotRow = {
  machine_id: string;
  workspace_key: string;
  seq: number;
  ttl_s: number;
  frame: string;
  received_at: number;
  expires_at: number;
};

type CacheRow = {
  machine_id: string;
  name: string;
  workspace_ids: string;
  paused: number;
  revoked: number;
};

const MIGRATIONS: readonly string[] = [
  `CREATE TABLE snapshot (
     machine_id TEXT NOT NULL,
     workspace_key TEXT NOT NULL,
     seq INTEGER NOT NULL,
     ttl_s INTEGER NOT NULL,
     frame TEXT NOT NULL,
     received_at INTEGER NOT NULL,
     expires_at INTEGER NOT NULL,
     PRIMARY KEY (machine_id, workspace_key)
   );
   CREATE INDEX snapshot_expires ON snapshot (expires_at);
   CREATE TABLE machine_cache (
     machine_id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     workspace_ids TEXT NOT NULL DEFAULT '[]',
     paused INTEGER NOT NULL DEFAULT 0,
     revoked INTEGER NOT NULL DEFAULT 0,
     updated_at INTEGER NOT NULL
   );`,
  `CREATE TABLE sync_status (
     machine_id TEXT PRIMARY KEY,
     rev INTEGER NOT NULL,
     errors TEXT NOT NULL DEFAULT '[]',
     acked_at INTEGER NOT NULL
   );`,
];

export function clampTtl(ttlS: number | null | undefined): number {
  if (ttlS === null || ttlS === undefined || !Number.isFinite(ttlS)) return SNAPSHOT_TTL_DEFAULT_S;
  return Math.min(SNAPSHOT_TTL_MAX_S, Math.max(SNAPSHOT_TTL_MIN_S, Math.floor(ttlS)));
}

function toSnapshot(r: SnapshotRow): StoredSnapshot {
  return {
    machineId: r.machine_id,
    workspaceId: r.workspace_key === "" ? null : r.workspace_key,
    seq: r.seq,
    ttlS: r.ttl_s,
    frame: r.frame,
    receivedAt: r.received_at,
    expiresAt: r.expires_at,
  };
}

function toSyncStatus(r: SyncStatusRow): SyncStatus {
  return { machineId: r.machine_id, rev: r.rev, errors: JSON.parse(r.errors) as SyncError[], ackedAt: r.acked_at };
}

function toCached(r: CacheRow): CachedMachine {
  return {
    machineId: r.machine_id,
    name: r.name,
    workspaceIds: JSON.parse(r.workspace_ids) as string[],
    paused: r.paused === 1,
    revoked: r.revoked === 1,
  };
}

export class LiveDb {
  constructor(
    private readonly sql: SqlStorage,
    private readonly storage: DurableObjectStorage,
  ) {}

  migrate(): void {
    this.sql.exec("CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)");
    const row = this.sql.exec<{ value: number }>("SELECT value FROM schema_meta WHERE key = 'version'").toArray()[0];
    const current = row?.value ?? 0;
    if (current > MIGRATIONS.length) throw new Error(`schema version ${current} is newer than ${MIGRATIONS.length}`);
    for (let v = current; v < MIGRATIONS.length; v++) {
      this.storage.transactionSync(() => {
        this.sql.exec(MIGRATIONS[v]!);
        this.sql.exec("INSERT INTO schema_meta (key, value) VALUES ('version', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", v + 1);
      });
    }
  }

  putSnapshot(machineId: string, workspaceId: string | null, seq: number, ttlS: number | null, frame: string, now: number = Date.now()): StoredSnapshot {
    const ttl = clampTtl(ttlS);
    const expiresAt = now + ttl * 1000;
    this.sql.exec(
      `INSERT INTO snapshot (machine_id, workspace_key, seq, ttl_s, frame, received_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (machine_id, workspace_key) DO UPDATE SET
         seq = excluded.seq, ttl_s = excluded.ttl_s, frame = excluded.frame,
         received_at = excluded.received_at, expires_at = excluded.expires_at`,
      machineId,
      workspaceId ?? "",
      seq,
      ttl,
      frame,
      now,
      expiresAt,
    );
    return { machineId, workspaceId, seq, ttlS: ttl, frame, receivedAt: now, expiresAt };
  }

  listSnapshots(now: number = Date.now()): StoredSnapshot[] {
    this.purgeExpiredSnapshots(now);
    return this.sql
      .exec<SnapshotRow>("SELECT machine_id, workspace_key, seq, ttl_s, frame, received_at, expires_at FROM snapshot ORDER BY machine_id, workspace_key")
      .toArray()
      .map(toSnapshot);
  }

  deleteSnapshots(machineId: string, keep: string[] | null = null): void {
    if (keep === null) {
      this.sql.exec("DELETE FROM snapshot WHERE machine_id = ?", machineId);
      return;
    }
    const marks = keep.map(() => "?").join(", ");
    this.sql.exec(`DELETE FROM snapshot WHERE machine_id = ? AND workspace_key <> '' AND workspace_key NOT IN (${marks || "''"})`, machineId, ...keep);
  }

  purgeExpiredSnapshots(now: number = Date.now()): number {
    return this.sql.exec("DELETE FROM snapshot WHERE expires_at <= ?", now).rowsWritten;
  }

  nextSnapshotExpiry(): number | null {
    const row = this.sql.exec<{ at: number | null }>("SELECT MIN(expires_at) AS at FROM snapshot").toArray()[0];
    return row?.at ?? null;
  }

  putSyncStatus(machineId: string, rev: number, errors: SyncError[], now: number = Date.now()): boolean {
    return (
      this.sql.exec(
        `INSERT INTO sync_status (machine_id, rev, errors, acked_at) VALUES (?, ?, ?, ?)
         ON CONFLICT (machine_id) DO UPDATE SET rev = excluded.rev, errors = excluded.errors, acked_at = excluded.acked_at
         WHERE excluded.rev >= sync_status.rev`,
        machineId,
        rev,
        JSON.stringify(errors),
        now,
      ).rowsWritten > 0
    );
  }

  listSyncStatus(): SyncStatus[] {
    return this.sql
      .exec<SyncStatusRow>("SELECT machine_id, rev, errors, acked_at FROM sync_status ORDER BY machine_id")
      .toArray()
      .map(toSyncStatus);
  }

  deleteSyncStatus(machineId: string): void {
    this.sql.exec("DELETE FROM sync_status WHERE machine_id = ?", machineId);
  }

  cached(machineId: string): CachedMachine | null {
    const row = this.sql
      .exec<CacheRow>("SELECT machine_id, name, workspace_ids, paused, revoked FROM machine_cache WHERE machine_id = ?", machineId)
      .toArray()[0];
    return row ? toCached(row) : null;
  }

  cachedAll(): CachedMachine[] {
    return this.sql
      .exec<CacheRow>("SELECT machine_id, name, workspace_ids, paused, revoked FROM machine_cache ORDER BY machine_id")
      .toArray()
      .map(toCached);
  }

  putCache(m: CachedMachine, now: number = Date.now()): void {
    this.sql.exec(
      `INSERT INTO machine_cache (machine_id, name, workspace_ids, paused, revoked, updated_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (machine_id) DO UPDATE SET name = excluded.name, workspace_ids = excluded.workspace_ids,
         paused = excluded.paused, revoked = excluded.revoked, updated_at = excluded.updated_at`,
      m.machineId,
      m.name,
      JSON.stringify(m.workspaceIds),
      m.paused ? 1 : 0,
      m.revoked ? 1 : 0,
      now,
    );
  }
}

export async function loadMachine(db: D1Database, machineId: string): Promise<CachedMachine | null> {
  const [m, ws] = await Promise.all([
    db
      .prepare("SELECT id, name, paused_at, revoked_at FROM machines WHERE id = ?")
      .bind(machineId)
      .first<{ id: string; name: string; paused_at: string | null; revoked_at: string | null }>(),
    db.prepare("SELECT workspace_id FROM workspace_machines WHERE machine_id = ? ORDER BY workspace_id").bind(machineId).all<{ workspace_id: string }>(),
  ]);
  if (!m) return null;
  return {
    machineId: m.id,
    name: m.name,
    workspaceIds: ws.results.map((r) => r.workspace_id),
    paused: m.paused_at !== null,
    revoked: m.revoked_at !== null,
  };
}

interface AgentAttachment {
  machineId: string;
  localMachineId: string | null;
  name: string;
  connectedAt: number;
  lastMessageAt: number;
  sessionId: string | null;
  snapshotTtlS: number;
  lastSnapshotAt: Record<string, number>;
  eventWindowStart: number;
  eventCount: number;
  touchedAt: number;
  syncRev: number | null;
}

type Frame = Record<string, unknown> & { type: string; id: string };

export interface AgentSink {
  frame(type: "snapshot" | "event", raw: string, machineId: string, workspaceId: string | null): void;
  presence(machineId: string): void;
}

function machineTag(machineId: string): string {
  return `m:${machineId}`;
}

function header(type: string, re?: string | null): Record<string, unknown> {
  const frame: Record<string, unknown> = { v: PROTOCOL, type, id: ulid(), ts: new Date().toISOString() };
  if (re !== undefined) frame.re = re;
  return frame;
}

export function errorFrame(
  code: WsErrorCode,
  message: string,
  opts: { re?: string | null; retryAfterS?: number; close?: boolean } = {},
): Record<string, unknown> {
  const frame = { ...header("error", opts.re ?? null), code, message };
  if (opts.retryAfterS !== undefined) Object.assign(frame, { retry_after_s: opts.retryAfterS });
  if (opts.close) Object.assign(frame, { close: true });
  return frame;
}

function errorResponse(code: WsErrorCode, message: string): Response {
  return Response.json(errorFrame(code, message), { status: STATUS[code], headers: { "Cache-Control": "no-store" } });
}

function send(ws: WebSocket, frame: Record<string, unknown>): void {
  try {
    ws.send(JSON.stringify(frame));
  } catch {}
}

export function closeWith(ws: WebSocket, code: WsErrorCode, message: string, re: string | null = null): void {
  send(ws, errorFrame(code, message, { re, close: true }));
  try {
    ws.close(4000 + STATUS[code], code);
  } catch {}
}

function frameBytes(message: string | ArrayBuffer): number {
  if (typeof message !== "string") return message.byteLength;
  if (message.length * 3 <= MAX_FRAME_BYTES) return message.length;
  return new TextEncoder().encode(message).byteLength;
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function validProjects(value: unknown): boolean {
  if (!Array.isArray(value) || value.length > 256) return false;
  return value.every((item) => {
    if (typeof item !== "object" || item === null) return false;
    const { name, roles } = item as { name?: unknown; roles?: unknown };
    if (typeof name !== "string" || !NAME_RE.test(name)) return false;
    return Array.isArray(roles) && roles.length <= 64 && roles.every((r) => typeof r === "string" && NAME_RE.test(r));
  });
}

export class AgentSockets {
  constructor(
    private readonly ctx: DurableObjectState,
    private readonly live: LiveDb,
    private readonly db: D1Database | null,
    private readonly sink: AgentSink,
  ) {
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  owns(ws: WebSocket): boolean {
    return this.ctx.getTags(ws).includes(AGENT_TAG);
  }

  async refresh(machineId: string): Promise<CachedMachine | null> {
    if (this.db === null) return this.live.cached(machineId);
    const m = await loadMachine(this.db, machineId);
    if (m) this.live.putCache(m);
    return m;
  }

  async upgrade(request: Request, machine: MachineCtx): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return errorResponse("bad_request", "se esperaba un upgrade a WebSocket");
    }
    const cached = await this.refresh(machine.machineId);
    if (!cached || cached.revoked) return errorResponse("unauthorized", "credencial ausente, inválida o revocada");
    if (cached.paused) return errorResponse("forbidden", "máquina desconectada por el dueño");
    for (const old of this.ctx.getWebSockets(machineTag(machine.machineId))) {
      closeWith(old, "conflict", "reemplazada por una conexión más reciente");
    }
    const pair = new WebSocketPair();
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [AGENT_TAG, machineTag(machine.machineId)]);
    const now = Date.now();
    const attachment: AgentAttachment = {
      machineId: machine.machineId,
      localMachineId: machine.localMachineId,
      name: cached.name,
      connectedAt: now,
      lastMessageAt: now,
      sessionId: null,
      snapshotTtlS: SNAPSHOT_TTL_DEFAULT_S,
      lastSnapshotAt: {},
      eventWindowStart: 0,
      eventCount: 0,
      touchedAt: 0,
      syncRev: null,
    };
    server.serializeAttachment(attachment);
    await this.scheduleAlarm(now + HELLO_TIMEOUT_MS);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async message(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const att = ws.deserializeAttachment() as AgentAttachment | null;
    if (!att) return closeWith(ws, "internal", "se perdió el estado de la conexión");
    const now = Date.now();
    att.lastMessageAt = now;
    if (frameBytes(message) > MAX_FRAME_BYTES) {
      ws.serializeAttachment(att);
      return send(ws, errorFrame("too_large", `el frame supera ${MAX_FRAME_BYTES} bytes`));
    }
    if (typeof message !== "string") {
      ws.serializeAttachment(att);
      return send(ws, errorFrame("bad_request", "los frames deben ser texto"));
    }
    let frame: Frame;
    try {
      const parsed: unknown = JSON.parse(message);
      if (
        typeof parsed !== "object" ||
        parsed === null ||
        Array.isArray(parsed) ||
        (parsed as Frame).v !== PROTOCOL ||
        typeof (parsed as Frame).type !== "string" ||
        typeof (parsed as Frame).id !== "string" ||
        !MSG_ID_RE.test((parsed as Frame).id)
      ) {
        throw new Error("bad header");
      }
      frame = parsed as Frame;
    } catch {
      ws.serializeAttachment(att);
      return send(ws, errorFrame("bad_request", "el frame no es un mensaje v2 válido"));
    }
    switch (frame.type) {
      case "ping":
        send(ws, header("pong", frame.id));
        break;
      case "pong":
        break;
      case "hello":
        if (!(await this.hello(ws, att, frame))) return;
        break;
      case "snapshot":
        await this.snapshot(ws, att, frame, message, now);
        break;
      case "event":
        this.event(ws, att, frame, message, now);
        break;
      case "import.offer":
        await this.importOffer(ws, att, frame, message);
        break;
      case "sync.ack":
        this.syncAck(ws, att, frame, now);
        break;
      default:
        send(ws, errorFrame("bad_request", "tipo de mensaje desconocido", { re: frame.id }));
    }
    ws.serializeAttachment(att);
  }

  online(): Set<string> {
    const out = new Set<string>();
    for (const ws of this.ctx.getWebSockets(AGENT_TAG)) {
      const att = ws.deserializeAttachment() as AgentAttachment | null;
      if (att?.sessionId != null) out.add(att.machineId);
    }
    return out;
  }

  async structureChanged(machineIds: string[] | "all"): Promise<number> {
    let sent = 0;
    for (const ws of this.ctx.getWebSockets(AGENT_TAG)) {
      const att = ws.deserializeAttachment() as AgentAttachment | null;
      if (!att || att.sessionId === null) continue;
      if (machineIds !== "all" && !machineIds.includes(att.machineId)) continue;
      if (await this.pushSync(ws, att, false)) sent++;
      ws.serializeAttachment(att);
    }
    return sent;
  }

  disconnect(machineId: string, code: WsErrorCode, message: string): number {
    const sockets = this.ctx.getWebSockets(machineTag(machineId));
    for (const ws of sockets) closeWith(ws, code, message);
    return sockets.length;
  }

  machineOf(ws: WebSocket): string | null {
    const att = ws.deserializeAttachment() as AgentAttachment | null;
    return att?.machineId ?? null;
  }

  close(ws: WebSocket, code: number, reason: string): void {
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {}
  }

  error(ws: WebSocket): void {
    try {
      ws.close(1011, "error");
    } catch {}
  }

  sweep(now: number = Date.now()): number | null {
    let next: number | null = null;
    for (const ws of this.ctx.getWebSockets(AGENT_TAG)) {
      const att = ws.deserializeAttachment() as AgentAttachment | null;
      if (!att) continue;
      if (att.sessionId === null) {
        const deadline = att.connectedAt + HELLO_TIMEOUT_MS;
        if (deadline <= now) {
          closeWith(ws, "bad_request", "no llegó el hello a tiempo");
          continue;
        }
        next = next === null ? deadline : Math.min(next, deadline);
        continue;
      }
      const auto = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
      const deadline = Math.max(att.lastMessageAt, auto) + IDLE_TIMEOUT_MS;
      if (deadline <= now) {
        try {
          ws.close(4408, "idle");
        } catch {}
        continue;
      }
      next = next === null ? deadline : Math.min(next, deadline);
    }
    return next;
  }

  async scheduleAlarm(at: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    if (current === null || at < current) await this.ctx.storage.setAlarm(at);
  }

  private async claimLocalId(att: AgentAttachment, localMachineId: string): Promise<"ok" | "conflict" | "forbidden"> {
    if (this.db === null) return "ok";
    try {
      await this.db
        .prepare("UPDATE machines SET local_machine_id = ? WHERE id = ? AND local_machine_id IS NULL AND revoked_at IS NULL")
        .bind(localMachineId, att.machineId)
        .run();
    } catch (err) {
      if (isConstraintError(err, "UNIQUE")) return "conflict";
      throw err;
    }
    const stored = await this.db.prepare("SELECT local_machine_id FROM machines WHERE id = ?").bind(att.machineId).first<string | null>("local_machine_id");
    return stored === localMachineId ? "ok" : "forbidden";
  }

  private async touch(att: AgentAttachment, now: number, agentVersion: string | null = null): Promise<void> {
    if (this.db === null) return;
    if (agentVersion === null && now - att.touchedAt < TOUCH_INTERVAL_MS) return;
    att.touchedAt = now;
    await this.db
      .prepare("UPDATE machines SET last_seen_at = ?, agent_version = COALESCE(?, agent_version) WHERE id = ?")
      .bind(isoNow(), agentVersion, att.machineId)
      .run();
  }

  private async hello(ws: WebSocket, att: AgentAttachment, frame: Frame): Promise<boolean> {
    const local = frame.machine_id;
    if (att.localMachineId !== null && local !== att.localMachineId) {
      closeWith(ws, "forbidden", "machine_id no coincide con la credencial", frame.id);
      return false;
    }
    const protocol = frame.protocol;
    if (!Array.isArray(protocol) || !protocol.includes(PROTOCOL)) {
      closeWith(ws, "unsupported_version", "no hay versión de protocolo común", frame.id);
      return false;
    }
    if (
      typeof local !== "string" ||
      !LOCAL_MACHINE_ID_RE.test(local) ||
      typeof frame.agent_version !== "string" ||
      !VERSION_RE.test(frame.agent_version) ||
      !validProjects(frame.projects)
    ) {
      send(ws, errorFrame("bad_request", "hello no válido", { re: frame.id }));
      return true;
    }
    if (att.localMachineId === null) {
      const claimed = await this.claimLocalId(att, local);
      if (claimed === "conflict") {
        closeWith(ws, "conflict", "ya hay otra máquina activa con ese machine_id", frame.id);
        return false;
      }
      if (claimed === "forbidden") {
        closeWith(ws, "forbidden", "machine_id no coincide con la credencial", frame.id);
        return false;
      }
      att.localMachineId = local;
    }
    await this.touch(att, Date.now(), frame.agent_version);
    const first = att.sessionId === null;
    att.sessionId ??= `ss-${Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, "0")).join("")}`;
    send(ws, {
      ...header("welcome", frame.id),
      session_id: att.sessionId,
      protocol: PROTOCOL,
      snapshot_ttl_s: att.snapshotTtlS,
      max_frame_bytes: MAX_FRAME_BYTES,
      ping_interval_s: PING_INTERVAL_S,
      machine: { id: att.machineId, name: att.name },
      rev: this.db === null ? 0 : await structureRev(this.db),
    });
    await this.pushSync(ws, att, true);
    if (first) {
      ws.serializeAttachment(att);
      this.sink.presence(att.machineId);
    }
    return true;
  }

  private async pushSync(ws: WebSocket, att: AgentAttachment, force: boolean): Promise<boolean> {
    if (this.db === null) return false;
    let doc;
    try {
      doc = await syncDocFor(this.db, att.machineId);
    } catch (err) {
      console.error(JSON.stringify({ code: "hub_sync", error: err instanceof Error ? err.name : "unknown" }));
      return false;
    }
    if (att.syncRev !== null && (doc.rev < att.syncRev || (!force && doc.rev === att.syncRev))) return false;
    att.syncRev = doc.rev;
    send(ws, { ...header("sync"), ...doc });
    return true;
  }

  private syncAck(ws: WebSocket, att: AgentAttachment, frame: Frame, now: number): void {
    const reject = (message: string) => send(ws, errorFrame("bad_request", message, { re: frame.id }));
    if (att.sessionId === null) return reject("primero hace falta el hello");
    if (!Object.keys(frame).every((k) => SYNC_ACK_KEYS.has(k))) return reject("campo fuera de la lista blanca");
    if (typeof frame.re !== "string" || !MSG_ID_RE.test(frame.re)) return reject("re debe ser un id de mensaje");
    if (!isCount(frame.rev)) return reject("rev debe ser un entero no negativo");
    const applied = frame.applied;
    if (!Array.isArray(applied) || applied.length > MAX_SYNC_ERRORS || !applied.every((n) => typeof n === "string" && NAME_RE.test(n))) {
      return reject("applied no válido");
    }
    const errors = frame.errors;
    if (
      !Array.isArray(errors) ||
      errors.length > MAX_SYNC_ERRORS ||
      !errors.every((e) => {
        if (typeof e !== "object" || e === null || Array.isArray(e)) return false;
        const { project, message, ...rest } = e as Record<string, unknown>;
        return (
          Object.keys(rest).length === 0 &&
          typeof project === "string" &&
          NAME_RE.test(project) &&
          typeof message === "string" &&
          message.length >= 1 &&
          message.length <= MAX_SYNC_MESSAGE
        );
      })
    ) {
      return reject("errors no válido");
    }
    const clean = (errors as SyncError[]).map((e) => ({ project: e.project, message: e.message }));
    this.live.putSyncStatus(att.machineId, frame.rev, clean, now);
  }

  private ready(ws: WebSocket, att: AgentAttachment, frame: Frame, keys: ReadonlySet<string>): string | null | false {
    const reject = (code: WsErrorCode, message: string) => {
      send(ws, errorFrame(code, message, { re: frame.id }));
      return false as const;
    };
    if (att.sessionId === null) return reject("bad_request", "primero hace falta el hello");
    if (!Object.keys(frame).every((k) => keys.has(k))) return reject("bad_request", "campo fuera de la lista blanca");
    if (frame.machine_id !== att.localMachineId) return reject("forbidden", "machine_id no coincide con la credencial");
    if (!isCount(frame.seq)) return reject("bad_request", "seq debe ser un entero no negativo");
    const workspaceId = frame.workspace_id;
    if (workspaceId === null) return null;
    if (typeof workspaceId !== "string" || !UUID_RE.test(workspaceId)) return reject("bad_request", "workspace_id debe ser un uuid o null");
    if (!(this.live.cached(att.machineId)?.workspaceIds ?? []).includes(workspaceId)) {
      return reject("forbidden", "la máquina no pertenece a ese workspace");
    }
    return workspaceId;
  }

  private async snapshot(ws: WebSocket, att: AgentAttachment, frame: Frame, raw: string, now: number): Promise<void> {
    const workspaceId = this.ready(ws, att, frame, SNAPSHOT_KEYS);
    if (workspaceId === false) return;
    const key = workspaceId ?? "";
    const wait = (att.lastSnapshotAt[key] ?? 0) + SNAPSHOT_MIN_INTERVAL_MS - now;
    if (wait > 0) {
      send(ws, errorFrame("rate_limited", "demasiados snapshots", { re: frame.id, retryAfterS: Math.ceil(wait / 1000) }));
      return;
    }
    att.lastSnapshotAt[key] = now;
    const ttl = typeof frame.ttl_s === "number" ? frame.ttl_s : null;
    att.snapshotTtlS = clampTtl(ttl);
    const stored = this.live.putSnapshot(att.machineId, workspaceId, frame.seq as number, ttl, raw, now);
    await this.touch(att, now);
    await this.scheduleAlarm(stored.expiresAt);
    this.sink.frame("snapshot", raw, att.machineId, workspaceId);
  }

  private async importOffer(ws: WebSocket, att: AgentAttachment, frame: Frame, raw: string): Promise<void> {
    const reject = (code: WsErrorCode, message: string) => send(ws, errorFrame(code, message, { re: frame.id }));
    if (att.sessionId === null) return reject("bad_request", "primero hace falta el hello");
    if (new TextEncoder().encode(raw).byteLength > MAX_OFFER_BYTES) return reject("too_large", `la oferta supera ${MAX_OFFER_BYTES} bytes`);
    if (!Object.keys(frame).every((k) => OFFER_KEYS.has(k)) || !validOffer(frame.projects)) return reject("bad_request", "import.offer no válido");
    if (this.db === null) return reject("internal", "importación no disponible");
    const stored = await storeImportOffer(this.db, att.machineId, frame.projects);
    send(ws, { ...header("import.result", frame.id), import_id: stored.id, status: stored.status });
  }

  private event(ws: WebSocket, att: AgentAttachment, frame: Frame, raw: string, now: number): void {
    const workspaceId = this.ready(ws, att, frame, EVENT_KEYS);
    if (workspaceId === false) return;
    if (now - att.eventWindowStart >= EVENT_WINDOW_MS) {
      att.eventWindowStart = now;
      att.eventCount = 0;
    }
    if (att.eventCount >= EVENT_MAX_PER_WINDOW) {
      send(ws, errorFrame("rate_limited", "demasiados eventos", { re: frame.id, retryAfterS: 1 }));
      return;
    }
    att.eventCount++;
    this.sink.frame("event", raw, att.machineId, workspaceId);
  }
}
