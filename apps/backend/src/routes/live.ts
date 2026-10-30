import { db, requireUser } from "../auth";
import type { LiveEnv } from "../hub";
import { errorResponse, json } from "../http";
import { verifyMachine } from "../machines";
import type { Handler } from "../router";
import { cityState, viewFor, workspaceParam } from "../state";

function hub(env: LiveEnv) {
  if (!env.HUB) return null;
  return env.HUB.get(env.HUB.idFromName("owner"));
}

const unavailable = () => errorResponse("internal", "relay en vivo no disponible", { status: 503 });

const connect: Handler<LiveEnv> = async (request, ctx) => {
  const p = ctx.principal;
  if (p.kind !== "machine") return errorResponse("forbidden", "esta ruta es solo para máquinas");
  if (p.paused) return errorResponse("forbidden", "máquina desconectada por el dueño");
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return errorResponse("bad_request", "se esperaba un upgrade a WebSocket");
  const m = await verifyMachine(db(ctx.env), request.headers.get("Authorization") ?? "");
  if (!m || m.machineId !== p.machineId) return errorResponse("unauthorized", "credencial ausente, inválida o revocada");
  if (m.paused) return errorResponse("forbidden", "máquina desconectada por el dueño");
  const h = hub(ctx.env);
  if (!h) return unavailable();
  return h.connectAgent(request, { machineId: m.machineId, localMachineId: m.localMachineId, name: m.name });
};

const state: Handler<LiveEnv> = async (_request, ctx) => {
  const p = requireUser(ctx.principal);
  if (p instanceof Response) return p;
  const d = db(ctx.env);
  const view = await viewFor(d, p, workspaceParam(ctx.url));
  if (view instanceof Response) return view;
  return json(await cityState(ctx.env, d, p, view));
};

const stream: Handler<LiveEnv> = async (request, ctx) => {
  const p = requireUser(ctx.principal);
  if (p instanceof Response) return p;
  const view = await viewFor(db(ctx.env), p, workspaceParam(ctx.url));
  if (view instanceof Response) return view;
  const h = hub(ctx.env);
  if (!h) return unavailable();
  return h.stream(request, view);
};

export const liveHandlers: Record<string, Handler<LiveEnv>> = {
  connect,
  state,
  stream,
};
