import { csrfHash, resolvePrincipal } from "./auth";
import { json } from "./http";
import type { MachinesEnv } from "./machines";
import { authHandlers } from "./routes/auth";
import { machineHandlers } from "./routes/machines";
import { projectHandlers } from "./routes/projects";
import { sessionHandlers } from "./routes/sessions";
import { workspaceHandlers } from "./routes/workspaces";
import { createApi, dispatchHost } from "./router";

export const VERSION = "0.1.0";

export interface Env extends MachinesEnv {}

const api = createApi<Env>(
  {
    health: () => json({ ok: true, version: VERSION }),
    ...authHandlers,
    ...sessionHandlers,
    ...machineHandlers,
    ...workspaceHandlers,
    ...projectHandlers,
  },
  { resolvePrincipal, csrfHash },
);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return dispatchHost(request, env, api);
  },
} satisfies ExportedHandler<Env>;
