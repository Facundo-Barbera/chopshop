import { DurableObject } from "cloudflare:workers";
import { RelayDb, type StoredSnapshot } from "./db";
import { ViewerHub, errorResponse } from "./viewer";

export interface Env {
  HUB: DurableObjectNamespace<Hub>;
}

const VIEWER_PATHS = new Set(["/stream", "/state"]);

export class Hub extends DurableObject<Env> {
  readonly db: RelayDb;
  readonly viewers: ViewerHub;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.db = new RelayDb(ctx.storage.sql, ctx.storage);
    this.db.migrate();
    this.viewers = new ViewerHub(this.db);
  }

  async publishSnapshot(account: string, machineId: string, seq: number, ttlS: number | null, frame: string): Promise<StoredSnapshot> {
    const stored = this.db.putSnapshot(account, machineId, seq, ttlS, frame);
    const alarm = await this.ctx.storage.getAlarm();
    if (alarm === null || alarm > stored.expiresAt) await this.ctx.storage.setAlarm(stored.expiresAt);
    this.viewers.publish(account, "snapshot", frame);
    return stored;
  }

  publishEvent(account: string, frame: string): string {
    return this.viewers.publish(account, "event", frame);
  }

  override async alarm(): Promise<void> {
    this.db.purgeExpiredSnapshots();
    const next = this.db.nextSnapshotExpiry();
    if (next !== null) await this.ctx.storage.setAlarm(next);
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({ ok: true, hub: this.ctx.id.toString() });
    }
    if (VIEWER_PATHS.has(url.pathname)) {
      if (request.method !== "GET") return errorResponse("bad_request", "solo GET", { Allow: "GET" });
      const who = await this.viewers.authorize(request);
      if (who instanceof Response) return who;
      return url.pathname === "/state" ? this.viewers.state(who.account) : this.viewers.stream(request, who.account);
    }
    return new Response("Not Found", { status: 404 });
  }
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" || VIEWER_PATHS.has(url.pathname)) {
      const stub = env.HUB.get(env.HUB.idFromName("global"));
      return stub.fetch(request);
    }
    return new Response("Not Found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
