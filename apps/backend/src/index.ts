import { type HttpEnv, type Principal, errorResponse, json, readCredential } from "./http";
import { createApi, dispatchHost } from "./router";

export const VERSION = "0.1.0";

export interface Env extends HttpEnv {
  DB?: D1Database;
}

async function resolvePrincipal(request: Request): Promise<Principal | Response> {
  const credential = readCredential(request);
  if (credential instanceof Response) return credential;
  if (credential.via === "none") return { kind: "anonymous" };
  return errorResponse("unauthorized", "credencial ausente, inválida o revocada");
}

const api = createApi<Env>({ health: () => json({ ok: true, version: VERSION }) }, { resolvePrincipal });

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return dispatchHost(request, env, api);
  },
} satisfies ExportedHandler<Env>;
