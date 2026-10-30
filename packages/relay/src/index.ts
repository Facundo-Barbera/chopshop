import { DurableObject } from "cloudflare:workers";
import { AGENT_WS_PATH, AgentSockets } from "./agentws";
import { RelayDb } from "./db";

export interface Env {
  HUB: DurableObjectNamespace<Hub>;
}

export class Hub extends DurableObject<Env> {
  readonly db: RelayDb;
  readonly agents: AgentSockets;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.db = new RelayDb(ctx.storage.sql, ctx.storage);
    this.db.migrate();
    this.agents = new AgentSockets(ctx, this.db);
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
    if (url.pathname === AGENT_WS_PATH) return this.agents.upgrade(request);
    return new Response("Not Found", { status: 404 });
  }
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" || url.pathname === AGENT_WS_PATH) {
      const stub = env.HUB.get(env.HUB.idFromName("global"));
      return stub.fetch(request);
    }
    return new Response("Not Found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
