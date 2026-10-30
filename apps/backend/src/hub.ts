import { DurableObject } from "cloudflare:workers";
import { AgentSockets, LiveDb, loadMachine } from "./agentws";
import type { HubRpc } from "./auth";
import type { MachineChange, MachineCtx, MachineHubRpc, MachinesEnv } from "./machines";
import { structureRev } from "./structure";
import { type LiveState, type ViewCtx, ViewerHub } from "./viewer";

export interface HubEnv {
  DB?: D1Database;
}

export interface LiveHubRpc {
  connectAgent(request: Request, machine: MachineCtx): Promise<Response>;
  state(view: ViewCtx): Promise<LiveState>;
  stream(request: Request, view: ViewCtx): Promise<Response>;
  viewerChanged(userId: string): Promise<void>;
}

export interface LiveEnv extends MachinesEnv {
  HUB?: { idFromName(name: string): DurableObjectId; get(id: DurableObjectId): HubRpc & MachineHubRpc & LiveHubRpc };
}

export class Hub extends DurableObject<HubEnv> implements HubRpc, MachineHubRpc, LiveHubRpc {
  readonly live: LiveDb;
  readonly agents: AgentSockets;
  readonly viewers: ViewerHub;

  constructor(ctx: DurableObjectState, env: HubEnv) {
    super(ctx, env);
    this.live = new LiveDb(ctx.storage.sql, ctx.storage);
    this.live.migrate();
    this.agents = new AgentSockets(ctx, this.live, env.DB ?? null, {
      frame: (type, raw, _machineId, workspaceId) => {
        this.viewers.publish(type, raw, [workspaceId]);
      },
      presence: (machineId) => this.presence(machineId),
    });
    this.viewers = new ViewerHub(this.live, () => this.agents.online());
  }

  private presence(machineId: string): void {
    const m = this.live.cached(machineId);
    const paused = m?.paused ?? false;
    const online = !paused && !(m?.revoked ?? false) && this.agents.online().has(machineId);
    this.viewers.publish("machine", JSON.stringify({ id: machineId, online, paused }), this.viewers.machineAudience(m));
  }

  async connectAgent(request: Request, machine: MachineCtx): Promise<Response> {
    return this.agents.upgrade(request, machine);
  }

  async state(view: ViewCtx): Promise<LiveState> {
    return this.viewers.state(view);
  }

  async stream(request: Request, view: ViewCtx): Promise<Response> {
    const rev = this.env.DB ? await structureRev(this.env.DB) : 0;
    return this.viewers.stream(request, view, rev);
  }

  async machineChanged(machineId: string, change: MachineChange): Promise<void> {
    const fresh = this.env.DB ? await loadMachine(this.env.DB, machineId) : this.live.cached(machineId);
    if (fresh === null) return;
    const m = {
      ...fresh,
      paused: change.paused ?? fresh.paused,
      revoked: change.revoked ?? fresh.revoked,
      workspaceIds: change.workspaceIds ?? fresh.workspaceIds,
    };
    this.live.putCache(m);
    if (m.revoked) {
      this.agents.disconnect(machineId, "unauthorized", "credencial revocada");
      this.live.deleteSnapshots(machineId);
    } else if (m.paused) {
      this.agents.disconnect(machineId, "forbidden", "máquina desconectada por el dueño");
    } else {
      this.live.deleteSnapshots(machineId, m.workspaceIds);
    }
    this.presence(machineId);
  }

  async viewerChanged(userId: string): Promise<void> {
    this.viewers.closeUser(userId);
  }

  async sessionRevoked(sessionId: string): Promise<void> {
    this.viewers.closeSession(sessionId);
  }

  async online(): Promise<string[]> {
    return [...this.agents.online()].sort();
  }

  override async alarm(): Promise<void> {
    this.live.purgeExpiredSnapshots();
    const next = [this.live.nextSnapshotExpiry(), this.agents.sweep()].filter((t): t is number => t !== null);
    if (next.length > 0) await this.ctx.storage.setAlarm(Math.min(...next));
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (this.agents.owns(ws)) await this.agents.message(ws, message);
  }

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    if (!this.agents.owns(ws)) return;
    this.agents.close(ws, code, reason);
    const machineId = this.agents.machineOf(ws);
    if (machineId !== null) this.presence(machineId);
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    if (this.agents.owns(ws)) this.agents.error(ws);
  }
}
