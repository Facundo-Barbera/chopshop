import { DurableObject } from "cloudflare:workers";
import { AgentSockets } from "./agentws";
import { RelayDb, type StoredSnapshot } from "./db";
import { Pairing } from "./pair";
import { authorize, resolveCaller } from "./routes";
import { ViewerHub } from "./viewer";

export interface Env {
  HUB: DurableObjectNamespace<Hub>;
  RELAY_OPERATOR_TOKEN?: string;
}

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
    const caller = await resolveCaller(request, this.db, this.env.RELAY_OPERATOR_TOKEN);
    if (caller instanceof Response) return caller;
    const route = authorize(caller.role, request.method, url.pathname);
    if (route instanceof Response) return route;
    switch (route) {
      case "whoami":
        return Response.json(
          { role: caller.role, machine_id: caller.record?.machineId ?? null },
          { headers: { "Cache-Control": "no-store" } },
        );
      case "agent_ws":
        return this.agents.upgrade(request);
      case "state":
        return this.viewers.state(caller.record!.account);
      case "stream":
        return this.viewers.stream(request, caller.record!.account);
      default:
        return (await this.pairing.handle(request, url.pathname)) ?? new Response("Not Found", { status: 404 });
    }
  }
}

export default {
  async fetch(request, env): Promise<Response> {
    const stub = env.HUB.get(env.HUB.idFromName("global"));
    return stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;
