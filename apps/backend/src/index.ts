import { csrfHash, resolvePrincipal } from "./auth";
import { json } from "./http";
import type { LiveEnv } from "./hub";
import { authHandlers } from "./routes/auth";
import { importHandlers } from "./routes/imports";
import { invitationHandlers } from "./routes/invitations";
import { liveHandlers } from "./routes/live";
import { machineHandlers } from "./routes/machines";
import { projectHandlers } from "./routes/projects";
import { sessionHandlers } from "./routes/sessions";
import { userHandlers } from "./routes/users";
import { workspaceHandlers } from "./routes/workspaces";
import { createApi, dispatchHost } from "./router";

export const VERSION = "0.1.0";

export { Hub } from "./hub";

export interface Env extends LiveEnv {}

const api = createApi<Env>(
  {
    health: () => json({ ok: true, version: VERSION }),
    ...authHandlers,
    ...sessionHandlers,
    ...invitationHandlers,
    ...userHandlers,
    ...machineHandlers,
    ...workspaceHandlers,
    ...projectHandlers,
    ...importHandlers,
    ...liveHandlers,
  },
  { resolvePrincipal, csrfHash },
);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return dispatchHost(request, env, api);
  },
} satisfies ExportedHandler<Env>;
