import type { CachedMachine, LiveDb, StoredSnapshot, SyncError } from "./agentws";
import { type ErrorCode, errorBody, errorResponse, ulid } from "./http";

export const HEARTBEAT_MS = 15_000;
export const RETRY_MS = 3000;
export const BUFFER_MAX = 512;
export const BUFFER_AGE_MS = 5 * 60_000;
export const MAX_VIEWERS = 64;
export const MAX_PENDING_WRITES = 256;

const encoder = new TextEncoder();

export interface ViewCtx {
  userId: string;
  role: "owner" | "watcher";
  sessionId: string;
  workspaceIds: string[] | "all";
}

export type StreamType = "snapshot" | "event" | "machine" | "structure";
export type Audience = "everyone" | (string | null)[];

export interface LiveMachine {
  id: string;
  online: boolean;
  paused: boolean;
  stale: boolean;
  seq: number | null;
  snapshot_age_s: number | null;
  expires_at: string | null;
}

export interface LiveSync {
  machine_id: string;
  rev: number;
  errors: SyncError[];
}

export interface LiveState {
  head: string;
  machines: LiveMachine[];
  snapshots: unknown[];
  sync: LiveSync[];
}

interface Buffered {
  seq: number;
  audience: Audience;
  type: StreamType;
  frame: string;
  at: number;
}

interface Viewer {
  view: ViewCtx;
  writer: WritableStreamDefaultWriter<Uint8Array>;
  pending: number;
}

export function sees(view: ViewCtx, audience: Audience): boolean {
  if (audience === "everyone" || view.workspaceIds === "all") return true;
  const ids = view.workspaceIds;
  return audience.some((w) => w !== null && ids.includes(w));
}

function sseFrame(event: string, data: string, id?: string): string {
  return `event: ${event}\n${id === undefined ? "" : `id: ${id}\n`}data: ${data}\n\n`;
}

export class ViewerHub {
  private readonly epoch = ulid().slice(10, 18);
  private seq = 0;
  private buffer: Buffered[] = [];
  private readonly viewers = new Set<Viewer>();
  private heartbeat: ReturnType<typeof setInterval> | null = null;

  constructor(
    private readonly live: LiveDb,
    private readonly online: () => Set<string> = () => new Set(),
  ) {}

  get active(): number {
    return this.viewers.size;
  }

  get head(): string {
    return this.eventId(this.seq);
  }

  private eventId(seq: number): string {
    return `${this.epoch}-${seq}`;
  }

  private parseEventId(raw: string | null): number | null {
    if (!raw) return null;
    const [epoch, n] = raw.trim().split("-");
    if (epoch !== this.epoch || n === undefined || !/^\d+$/.test(n)) return null;
    const seq = Number(n);
    return seq <= this.seq ? seq : null;
  }

  machineAudience(m: CachedMachine | null): Audience {
    return m?.workspaceIds ?? [];
  }

  private visibleSnapshots(view: ViewCtx, now: number): StoredSnapshot[] {
    return this.live.listSnapshots(now).filter((s) => sees(view, [s.workspaceId]));
  }

  state(view: ViewCtx, now: number = Date.now()): LiveState {
    const snaps = this.visibleSnapshots(view, now);
    const online = this.online();
    const cache = new Map(this.live.cachedAll().map((m) => [m.machineId, m]));
    const ids = [...new Set([...cache.keys(), ...online, ...snaps.map((s) => s.machineId)])].sort();
    const machines: LiveMachine[] = [];
    for (const id of ids) {
      const m = cache.get(id) ?? null;
      if (m?.revoked) continue;
      if (!sees(view, this.machineAudience(m))) continue;
      const newest = snaps.filter((s) => s.machineId === id).sort((a, b) => b.receivedAt - a.receivedAt)[0];
      const paused = m?.paused ?? false;
      machines.push({
        id,
        online: online.has(id) && !paused,
        paused,
        stale: newest === undefined,
        seq: newest?.seq ?? null,
        snapshot_age_s: newest ? Math.max(0, Math.floor((now - newest.receivedAt) / 1000)) : null,
        expires_at: newest ? new Date(newest.expiresAt).toISOString() : null,
      });
    }
    const visible = new Set(machines.map((m) => m.id));
    const sync = this.live
      .listSyncStatus()
      .filter((s) => visible.has(s.machineId))
      .map((s) => ({ machine_id: s.machineId, rev: s.rev, errors: s.errors }));
    return { head: this.head, machines, snapshots: snaps.map((s) => JSON.parse(s.frame) as unknown), sync };
  }

  stream(request: Request, view: ViewCtx, rev: number, now: number = Date.now()): Response {
    if (this.viewers.size >= MAX_VIEWERS) {
      return errorResponse("rate_limited", `demasiados visores conectados (máx. ${MAX_VIEWERS})`, { retryAfterS: 3 });
    }
    this.prune(now);
    const url = new URL(request.url);
    const after = this.parseEventId(request.headers.get("Last-Event-ID") ?? url.searchParams.get("after"));
    const oldest = this.buffer[0]?.seq ?? this.seq + 1;
    const resume = after !== null && after >= oldest - 1;
    const head = this.head;
    let out = `retry: ${RETRY_MS}\n\n`;
    const hello = { v: 2, type: "hello", ts: new Date(now).toISOString(), head, resume: resume ? "events" : "snapshot", rev };
    out += sseFrame("hello", JSON.stringify(hello));
    if (resume) {
      for (const b of this.buffer) {
        if (b.seq > after && sees(view, b.audience)) out += sseFrame(b.type, b.frame, this.eventId(b.seq));
      }
    } else {
      for (const s of this.visibleSnapshots(view, now)) out += sseFrame("snapshot", s.frame, head);
    }
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const viewer: Viewer = { view, writer: writable.getWriter(), pending: 0 };
    this.viewers.add(viewer);
    this.write(viewer, out);
    request.signal?.addEventListener("abort", () => this.drop(viewer));
    this.ensureHeartbeat();
    return new Response(readable, {
      headers: {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Accel-Buffering": "no",
        "X-Content-Type-Options": "nosniff",
      },
    });
  }

  publish(type: StreamType, frame: string, audience: Audience, now: number = Date.now()): string {
    this.seq += 1;
    const entry: Buffered = { seq: this.seq, audience, type, frame, at: now };
    this.buffer.push(entry);
    this.prune(now);
    const text = sseFrame(type, frame, this.eventId(entry.seq));
    for (const v of this.viewers) {
      if (sees(v.view, audience)) this.write(v, text);
    }
    return this.eventId(entry.seq);
  }

  closeSession(sessionId: string): number {
    return this.closeWhere((v) => v.view.sessionId === sessionId, "unauthorized", "sesión revocada");
  }

  closeUser(userId: string): number {
    return this.closeWhere((v) => v.view.userId === userId, "forbidden", "cambió tu acceso; vuelve a conectar");
  }

  private closeWhere(match: (v: Viewer) => boolean, code: ErrorCode, message: string): number {
    const text = sseFrame("error", JSON.stringify({ ...errorBody(code, message), close: true }));
    let n = 0;
    for (const v of [...this.viewers]) {
      if (match(v)) {
        this.write(v, text);
        this.drop(v);
        n++;
      }
    }
    return n;
  }

  private prune(now: number): void {
    const excess = this.buffer.length - BUFFER_MAX;
    if (excess > 0) this.buffer.splice(0, excess);
    while (this.buffer.length > 0 && now - this.buffer[0]!.at > BUFFER_AGE_MS) this.buffer.shift();
  }

  private write(viewer: Viewer, text: string): void {
    if (!this.viewers.has(viewer)) return;
    if (viewer.pending >= MAX_PENDING_WRITES) {
      this.drop(viewer);
      return;
    }
    viewer.pending++;
    viewer.writer.write(encoder.encode(text)).then(
      () => {
        viewer.pending--;
      },
      () => this.drop(viewer),
    );
  }

  private drop(viewer: Viewer): void {
    if (!this.viewers.delete(viewer)) return;
    viewer.writer.close().catch(() => undefined);
    if (this.viewers.size === 0 && this.heartbeat !== null) {
      clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
  }

  private ensureHeartbeat(): void {
    if (this.heartbeat !== null) return;
    this.heartbeat = setInterval(() => {
      for (const v of [...this.viewers]) this.write(v, ": ping\n\n");
    }, HEARTBEAT_MS);
  }
}
