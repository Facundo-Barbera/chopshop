import { clampTtl, SNAPSHOT_TTL_DEFAULT_S, type RelayDb } from "./db";

export const AGENT_WS_PATH = "/agent/ws";
export const MAX_FRAME_BYTES = 1_048_576;
export const PING_INTERVAL_S = 30;
const PROTOCOL = 1;
const HELLO_TIMEOUT_MS = 10_000;
const IDLE_TIMEOUT_MS = PING_INTERVAL_S * 3 * 1000;
const SNAPSHOT_MIN_INTERVAL_MS = 5_000;
const EVENT_WINDOW_MS = 1_000;
const EVENT_MAX_PER_WINDOW = 50;
const AGENT_TAG = "agent";
const MSG_ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]{1,32})?$/;
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export type ErrorCode =
  | "bad_request"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "gone"
  | "conflict"
  | "too_large"
  | "rate_limited"
  | "unsupported_version"
  | "internal";

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  gone: 410,
  conflict: 409,
  too_large: 413,
  rate_limited: 429,
  unsupported_version: 426,
  internal: 500,
};

interface AgentAttachment {
  account: string;
  tokenId: string;
  tokenName: string | null;
  machineId: string;
  connectedAt: number;
  lastMessageAt: number;
  sessionId: string | null;
  snapshotTtlS: number;
  lastSnapshotAt: number;
  eventWindowStart: number;
  eventCount: number;
}

type Frame = Record<string, unknown> & { type: string; id: string };

export function viewerTag(account: string): string {
  return `viewer:${account}`;
}

function machineTag(account: string, machineId: string): string {
  return `m:${account}:${machineId}`;
}

export function ulid(now: number = Date.now()): string {
  let out = "";
  let t = now;
  for (let i = 0; i < 10; i++) {
    out = CROCKFORD[t % 32]! + out;
    t = Math.floor(t / 32);
  }
  for (const b of crypto.getRandomValues(new Uint8Array(16))) out += CROCKFORD[b % 32]!;
  return out;
}

function header(type: string, re?: string | null): Record<string, unknown> {
  const frame: Record<string, unknown> = { v: 1, type, id: ulid(), ts: new Date().toISOString() };
  if (re !== undefined) frame.re = re;
  return frame;
}

export function errorFrame(
  code: ErrorCode,
  message: string,
  opts: { re?: string | null; retryAfterS?: number; close?: boolean } = {},
): Record<string, unknown> {
  const frame = { ...header("error", opts.re ?? null), code, message };
  if (opts.retryAfterS !== undefined) Object.assign(frame, { retry_after_s: opts.retryAfterS });
  if (opts.close) Object.assign(frame, { close: true });
  return frame;
}

export function errorResponse(code: ErrorCode, message: string): Response {
  return Response.json(errorFrame(code, message), { status: STATUS[code] });
}

function send(ws: WebSocket, frame: Record<string, unknown>): void {
  try {
    ws.send(JSON.stringify(frame));
  } catch {}
}

function closeWith(ws: WebSocket, code: ErrorCode, message: string, re: string | null = null): void {
  send(ws, errorFrame(code, message, { re, close: true }));
  try {
    ws.close(4000 + STATUS[code], code);
  } catch {}
}

function bearer(request: Request): string | null {
  const match = /^Bearer\s+(\S+)$/i.exec(request.headers.get("Authorization") ?? "");
  return match?.[1] ?? null;
}

function frameBytes(message: string | ArrayBuffer): number {
  if (typeof message !== "string") return message.byteLength;
  if (message.length * 3 <= MAX_FRAME_BYTES) return message.length;
  return new TextEncoder().encode(message).byteLength;
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function parseProjects(value: unknown): { name: string; roles: string[] }[] | null {
  if (!Array.isArray(value) || value.length > 256) return null;
  const projects: { name: string; roles: string[] }[] = [];
  for (const item of value) {
    if (typeof item !== "object" || item === null) return null;
    const { name, roles } = item as { name?: unknown; roles?: unknown };
    if (typeof name !== "string" || !NAME_RE.test(name)) return null;
    if (!Array.isArray(roles) || roles.length > 64) return null;
    if (!roles.every((r): r is string => typeof r === "string" && NAME_RE.test(r))) return null;
    projects.push({ name, roles });
  }
  return projects;
}

export class AgentSockets {
  constructor(
    private readonly ctx: DurableObjectState,
    private readonly db: RelayDb,
  ) {
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  owns(ws: WebSocket): boolean {
    return this.ctx.getTags(ws).includes(AGENT_TAG);
  }

  async upgrade(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return errorResponse("bad_request", "expected a websocket upgrade");
    }
    const token = bearer(request);
    const record = token ? await this.db.verifyToken(token) : null;
    if (!record) return errorResponse("unauthorized", "missing or invalid credential");
    if (record.scope !== "agent" || record.machineId === null) {
      return errorResponse("forbidden", "agent credential required");
    }
    const tag = machineTag(record.account, record.machineId);
    for (const old of this.ctx.getWebSockets(tag)) {
      closeWith(old, "conflict", "replaced by a newer connection");
    }
    const pair = new WebSocketPair();
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [AGENT_TAG, tag]);
    const now = Date.now();
    const attachment: AgentAttachment = {
      account: record.account,
      tokenId: record.tokenId,
      tokenName: record.name,
      machineId: record.machineId,
      connectedAt: now,
      lastMessageAt: now,
      sessionId: null,
      snapshotTtlS: SNAPSHOT_TTL_DEFAULT_S,
      lastSnapshotAt: 0,
      eventWindowStart: 0,
      eventCount: 0,
    };
    server.serializeAttachment(attachment);
    await this.scheduleAlarm(now + HELLO_TIMEOUT_MS);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async message(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const att = ws.deserializeAttachment() as AgentAttachment | null;
    if (!att) return closeWith(ws, "internal", "lost connection state");
    const now = Date.now();
    att.lastMessageAt = now;
    if (frameBytes(message) > MAX_FRAME_BYTES) {
      ws.serializeAttachment(att);
      return send(ws, errorFrame("too_large", `frame exceeds ${MAX_FRAME_BYTES} bytes`));
    }
    if (typeof message !== "string") {
      ws.serializeAttachment(att);
      return send(ws, errorFrame("bad_request", "frames must be text"));
    }
    let frame: Frame;
    try {
      const parsed: unknown = JSON.parse(message);
      if (
        typeof parsed !== "object" ||
        parsed === null ||
        Array.isArray(parsed) ||
        (parsed as Frame).v !== 1 ||
        typeof (parsed as Frame).type !== "string" ||
        typeof (parsed as Frame).id !== "string" ||
        !MSG_ID_RE.test((parsed as Frame).id)
      ) {
        throw new Error("bad header");
      }
      frame = parsed as Frame;
    } catch {
      ws.serializeAttachment(att);
      return send(ws, errorFrame("bad_request", "frame is not a valid v1 message"));
    }
    switch (frame.type) {
      case "ping":
        send(ws, header("pong", frame.id));
        break;
      case "pong":
        break;
      case "hello":
        if (!this.hello(ws, att, frame)) return;
        break;
      case "snapshot":
        await this.snapshot(ws, att, frame, message, now);
        break;
      case "event":
        this.event(ws, att, frame, message, now);
        break;
      case "whoami":
        this.whoami(ws, att, frame, now);
        break;
      default:
        send(ws, errorFrame("bad_request", "unknown message type", { re: frame.id }));
    }
    ws.serializeAttachment(att);
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
          closeWith(ws, "bad_request", "hello not received in time");
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

  private hello(ws: WebSocket, att: AgentAttachment, frame: Frame): boolean {
    if (frame.machine_id !== att.machineId) {
      closeWith(ws, "forbidden", "machine_id does not match the credential", frame.id);
      return false;
    }
    const protocol = frame.protocol;
    if (!Array.isArray(protocol) || !protocol.includes(PROTOCOL)) {
      closeWith(ws, "unsupported_version", "no common protocol version", frame.id);
      return false;
    }
    const projects = parseProjects(frame.projects);
    if (typeof frame.agent_version !== "string" || !VERSION_RE.test(frame.agent_version) || projects === null) {
      send(ws, errorFrame("bad_request", "invalid hello", { re: frame.id }));
      return true;
    }
    this.db.touchMachine(att.account, att.machineId, { agentVersion: frame.agent_version, projects });
    att.sessionId ??= `ss-${Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, "0")).join("")}`;
    send(ws, {
      ...header("welcome", frame.id),
      session_id: att.sessionId,
      protocol: PROTOCOL,
      snapshot_ttl_s: att.snapshotTtlS,
      max_frame_bytes: MAX_FRAME_BYTES,
      ping_interval_s: PING_INTERVAL_S,
    });
    return true;
  }

  private ready(ws: WebSocket, att: AgentAttachment, frame: Frame): boolean {
    if (att.sessionId === null) {
      send(ws, errorFrame("bad_request", "hello required first", { re: frame.id }));
      return false;
    }
    if (frame.machine_id !== att.machineId) {
      send(ws, errorFrame("forbidden", "machine_id does not match the credential", { re: frame.id }));
      return false;
    }
    if (!isCount(frame.seq)) {
      send(ws, errorFrame("bad_request", "seq must be a non-negative integer", { re: frame.id }));
      return false;
    }
    return true;
  }

  private async snapshot(ws: WebSocket, att: AgentAttachment, frame: Frame, raw: string, now: number): Promise<void> {
    if (!this.ready(ws, att, frame)) return;
    const wait = att.lastSnapshotAt + SNAPSHOT_MIN_INTERVAL_MS - now;
    if (wait > 0) {
      send(ws, errorFrame("rate_limited", "too many snapshots", { re: frame.id, retryAfterS: Math.ceil(wait / 1000) }));
      return;
    }
    att.lastSnapshotAt = now;
    const ttl = typeof frame.ttl_s === "number" ? frame.ttl_s : null;
    att.snapshotTtlS = clampTtl(ttl);
    const stored = this.db.putSnapshot(att.account, att.machineId, frame.seq as number, ttl, raw, now);
    this.db.touchMachine(att.account, att.machineId, {}, now);
    await this.scheduleAlarm(stored.expiresAt);
    this.broadcast(att.account, raw);
  }

  private event(ws: WebSocket, att: AgentAttachment, frame: Frame, raw: string, now: number): void {
    if (!this.ready(ws, att, frame)) return;
    if (now - att.eventWindowStart >= EVENT_WINDOW_MS) {
      att.eventWindowStart = now;
      att.eventCount = 0;
    }
    if (att.eventCount >= EVENT_MAX_PER_WINDOW) {
      send(ws, errorFrame("rate_limited", "too many events", { re: frame.id, retryAfterS: 1 }));
      return;
    }
    att.eventCount++;
    this.broadcast(att.account, raw);
  }

  private whoami(ws: WebSocket, att: AgentAttachment, frame: Frame, now: number): void {
    const snap = this.db.getSnapshot(att.account, att.machineId, now);
    send(ws, {
      ...header("whoami.result", frame.id),
      token_id: att.tokenId,
      scope: "agent",
      account: att.account,
      token_name: att.tokenName,
      machine_id: att.machineId,
      machines: [
        {
          machine_id: att.machineId,
          online: true,
          snapshot_age_s: snap ? Math.max(0, (now - snap.receivedAt) / 1000) : null,
          stale: snap === null,
        },
      ],
    });
  }

  private broadcast(account: string, raw: string): void {
    for (const viewer of this.ctx.getWebSockets(viewerTag(account))) {
      try {
        viewer.send(raw);
      } catch {}
    }
  }
}
