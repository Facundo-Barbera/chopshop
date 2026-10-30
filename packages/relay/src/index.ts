import { DurableObject } from "cloudflare:workers";
import { RelayDb } from "./db";
import { Pairing } from "./pair";

export interface Env {
  HUB: DurableObjectNamespace<Hub>;
  RELAY_OPERATOR_TOKEN?: string;
}

export class Hub extends DurableObject<Env> {
  readonly db: RelayDb;
  readonly pairing: Pairing;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.db = new RelayDb(ctx.storage.sql, ctx.storage);
    this.db.migrate();
    this.pairing = new Pairing(ctx.storage.sql, ctx.storage, this.db, env.RELAY_OPERATOR_TOKEN);
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
    const paired = await this.pairing.handle(request, url.pathname);
    if (paired) return paired;
    return new Response("Not Found", { status: 404 });
  }
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (
      url.pathname === "/health" ||
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
