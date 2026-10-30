import { type AuthEnv, csrfHash, resolvePrincipal } from "./auth";
import { json } from "./http";
import { authHandlers } from "./routes/auth";
import { invitationHandlers } from "./routes/invitations";
import { sessionHandlers } from "./routes/sessions";
import { userHandlers } from "./routes/users";
import { createApi, dispatchHost } from "./router";

export const VERSION = "0.1.0";

export interface Env extends AuthEnv {}

const api = createApi<Env>(
  { health: () => json({ ok: true, version: VERSION }), ...authHandlers, ...sessionHandlers, ...invitationHandlers, ...userHandlers },
  { resolvePrincipal, csrfHash },
);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return dispatchHost(request, env, api);
  },
} satisfies ExportedHandler<Env>;
