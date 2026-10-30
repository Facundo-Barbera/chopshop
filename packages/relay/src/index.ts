import { DurableObject } from "cloudflare:workers";
import { AGENT_WS_PATH, AgentSockets } from "./agentws";
import { RelayDb, type StoredSnapshot } from "./db";
import { Pairing } from "./pair";
import { ViewerHub, errorResponse } from "./viewer";

export interface Env {
  HUB: DurableObjectNamespace<Hub>;
  RELAY_OPERATOR_TOKEN?: string;
}

const VIEWER_PATHS = new Set(["/stream", "/state"]);

export class Hub extends DurableObject<Env> {
  readonly db: RelayDb;
  readonly pairing: Pairing;
  readonly agents: AgentSockets;
  readonly viewers: ViewerHub;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.db = new RelayDb(ctx.storage.sql, ctx.storage);
    this.db.migrate();
    this.pairing = new Pairing(ctx.storage.sql, ctx.storage, this.db, env.RELAY_OPERATOR_TOKEN);
    this.agents = new AgentSockets(ctx, this.db, (account, type, raw) => {
      this.viewers.publish(account, type, raw);
    });
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
    const next = [this.db.nextSnapshotExpiry(), this.agents.sweep()].filter((t): t is number => t !== null);
    if (next.length > 0) await this.ctx.storage.setAlarm(Math.min(...next));
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (this.agents.owns(ws)) await this.agents.message(ws, message);
  }

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    if (this.agents.owns(ws)) this.agents.close(ws, code, reason);
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    if (this.agents.owns(ws)) this.agents.error(ws);
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({ ok: true, hub: this.ctx.id.toString() });
    }
    const paired = await this.pairing.handle(request, url.pathname);
    if (paired) return paired;
    if (url.pathname === AGENT_WS_PATH) return this.agents.upgrade(request);
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
    if (
      url.pathname === "/health" ||
      url.pathname === AGENT_WS_PATH ||
      VIEWER_PATHS.has(url.pathname) ||
      url.pathname === "/pair" ||
      url.pathname.startsWith("/v1/pair") ||
      url.pathname.startsWith("/v1/tokens/")
    ) {
      const stub = env.HUB.get(env.HUB.idFromName("global"));
      return stub.fetch(request);
    }
    return new Response("Not Found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
