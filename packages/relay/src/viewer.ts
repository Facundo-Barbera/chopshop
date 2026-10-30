import type { RelayDb, StoredSnapshot, TokenRecord } from "./db";

export const HEARTBEAT_MS = 15_000;
export const RETRY_MS = 3000;
export const BUFFER_MAX = 512;
export const BUFFER_AGE_MS = 5 * 60_000;
export const MAX_VIEWERS = 64;
export const MAX_PENDING_WRITES = 256;

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const encoder = new TextEncoder();

export type StreamType = "snapshot" | "event";

interface Buffered {
  seq: number;
  account: string;
  type: StreamType;
  frame: string;
  at: number;
}

interface Viewer {
  account: string;
  writer: WritableStreamDefaultWriter<Uint8Array>;
  pending: number;
}

export function ulid(now: number = Date.now()): string {
  let time = "";
  let t = now;
  for (let i = 0; i < 10; i++) {
    time = CROCKFORD[t % 32] + time;
    t = Math.floor(t / 32);
  }
  const rand = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => CROCKFORD[b % 32]).join("");
  return time + rand;
}

const ERROR_STATUS = {
  bad_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  gone: 410,
  too_large: 413,
  unsupported_version: 426,
  rate_limited: 429,
  internal: 500,
} as const;

export type ErrorCode = keyof typeof ERROR_STATUS;

export function errorResponse(code: ErrorCode, message: string, headers: Record<string, string> = {}): Response {
  const body = { v: 1, type: "error", id: ulid(), ts: new Date().toISOString(), code, message };
  return Response.json(body, { status: ERROR_STATUS[code], headers: { "Cache-Control": "no-store", ...headers } });
}

function sseFrame(event: string, data: string, id?: string): string {
  return `event: ${event}\n${id === undefined ? "" : `id: ${id}\n`}data: ${data}\n\n`;
}

function machineInfo(s: StoredSnapshot, now: number) {
  return {
    machine_id: s.machineId,
    seq: s.seq,
    snapshot_age_s: Math.max(0, Math.floor((now - s.receivedAt) / 1000)),
    expires_at: new Date(s.expiresAt).toISOString(),
  };
}

export class ViewerHub {
  private readonly epoch = ulid().slice(10, 18);
  private seq = 0;
  private buffer: Buffered[] = [];
  private readonly viewers = new Set<Viewer>();
  private heartbeat: ReturnType<typeof setInterval> | null = null;

  constructor(private readonly db: RelayDb) {}

  get active(): number {
    return this.viewers.size;
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

  async authorize(request: Request): Promise<TokenRecord | Response> {
    const auth = request.headers.get("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
    const record = token ? await this.db.verifyToken(token) : null;
    if (!record) return errorResponse("unauthorized", "credencial ausente, inválida o revocada", { "WWW-Authenticate": "Bearer" });
    if (record.scope !== "viewer") return errorResponse("forbidden", "esta ruta es solo para tokens viewer");
    return record;
  }

  state(account: string, now: number = Date.now()): Response {
    return Response.json(this.snapshotBody(account, now), { headers: { "Cache-Control": "no-store" } });
  }

  private snapshotBody(account: string, now: number) {
    const live = this.db.listSnapshots(account, now);
    return {
      v: 1,
      type: "state",
      id: ulid(now),
      ts: new Date(now).toISOString(),
      head: this.eventId(this.seq),
      machines: live.map((s) => machineInfo(s, now)),
      snapshots: live.map((s) => JSON.parse(s.frame) as unknown),
    };
  }

  stream(request: Request, account: string, now: number = Date.now()): Response {
    if (this.viewers.size >= MAX_VIEWERS) {
      return errorResponse("rate_limited", `demasiados visores conectados (máx. ${MAX_VIEWERS})`, { "Retry-After": "3" });
    }
    this.prune(now);
    const url = new URL(request.url);
    const after = this.parseEventId(request.headers.get("Last-Event-ID") ?? url.searchParams.get("after"));
    const oldest = this.buffer[0]?.seq ?? this.seq + 1;
    const resume = after !== null && after >= oldest - 1;
    const head = this.eventId(this.seq);
    let out = `retry: ${RETRY_MS}\n\n`;
    const hello = { v: 1, type: "hello", ts: new Date(now).toISOString(), head, resume: resume ? "events" : "snapshot" };
    out += sseFrame("hello", JSON.stringify(hello));
    if (resume) {
      for (const b of this.buffer) {
        if (b.seq > after && b.account === account) out += sseFrame(b.type, b.frame, this.eventId(b.seq));
      }
    } else {
      for (const s of this.db.listSnapshots(account, now)) out += sseFrame("snapshot", s.frame, head);
    }
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const viewer: Viewer = { account, writer: writable.getWriter(), pending: 0 };
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

  publish(account: string, type: StreamType, frame: string, now: number = Date.now()): string {
    this.seq += 1;
    const entry: Buffered = { seq: this.seq, account, type, frame, at: now };
    this.buffer.push(entry);
    this.prune(now);
    const text = sseFrame(type, frame, this.eventId(entry.seq));
    for (const v of this.viewers) {
      if (v.account === account) this.write(v, text);
    }
    return this.eventId(entry.seq);
  }

  closeAccount(account: string): number {
    let n = 0;
    for (const v of [...this.viewers]) {
      if (v.account === account) {
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
