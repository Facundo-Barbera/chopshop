import {
  type HttpEnv,
  type Principal,
  SECURITY_HEADERS,
  apiOrigin,
  bodyTooLarge,
  checkCsrf,
  corsHeaders,
  errorResponse,
  needsCsrf,
  readCredential,
  webCsp,
  webOrigin,
  withHeaders,
} from "./http";

export type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
export type Who = "anon" | "any" | "owner" | "machine" | "operator";

export interface RouteDef {
  name: string;
  method: Method;
  path: string;
  who: Who;
}

const r = (method: Method, path: string, who: Who, name: string): RouteDef => ({ name, method, path, who });

export const ROUTES: readonly RouteDef[] = [
  r("GET", "/health", "anon", "health"),
  r("POST", "/v1/operator/bootstrap", "operator", "operator.bootstrap"),
  r("POST", "/v1/operator/recover", "operator", "operator.recover"),
  r("POST", "/v1/auth/login", "anon", "auth.login"),
  r("POST", "/v1/auth/logout", "any", "auth.logout"),
  r("GET", "/v1/auth/me", "any", "auth.me"),
  r("POST", "/v1/auth/password", "any", "auth.password"),
  r("POST", "/v1/auth/recover", "anon", "auth.recover"),
  r("POST", "/v1/auth/recovery-code", "owner", "auth.recovery_code"),
  r("GET", "/v1/invitations", "owner", "invitations.list"),
  r("POST", "/v1/invitations", "owner", "invitations.create"),
  r("POST", "/v1/invitations/inspect", "anon", "invitations.inspect"),
  r("POST", "/v1/invitations/accept", "anon", "invitations.accept"),
  r("POST", "/v1/invitations/:id/reissue", "owner", "invitations.reissue"),
  r("DELETE", "/v1/invitations/:id", "owner", "invitations.revoke"),
  r("GET", "/v1/users", "owner", "users.list"),
  r("GET", "/v1/users/:id", "owner", "users.get"),
  r("PATCH", "/v1/users/:id", "owner", "users.update"),
  r("GET", "/v1/sessions", "any", "sessions.list"),
  r("DELETE", "/v1/sessions/:id", "any", "sessions.revoke"),
  r("GET", "/v1/machines", "owner", "machines.list"),
  r("POST", "/v1/machines/link", "owner", "machines.link"),
  r("POST", "/v1/machines", "owner", "machines.create"),
  r("GET", "/v1/machines/:id", "owner", "machines.get"),
  r("PATCH", "/v1/machines/:id", "owner", "machines.update"),
  r("POST", "/v1/machines/:id/pause", "owner", "machines.pause"),
  r("POST", "/v1/machines/:id/resume", "owner", "machines.resume"),
  r("POST", "/v1/machines/:id/revoke", "owner", "machines.revoke"),
  r("GET", "/v1/workspaces", "any", "workspaces.list"),
  r("POST", "/v1/workspaces", "owner", "workspaces.create"),
  r("GET", "/v1/workspaces/:id", "any", "workspaces.get"),
  r("PATCH", "/v1/workspaces/:id", "owner", "workspaces.update"),
  r("DELETE", "/v1/workspaces/:id", "owner", "workspaces.archive"),
  r("GET", "/v1/workspaces/:id/campus", "any", "campus.get"),
  r("PUT", "/v1/workspaces/:id/campus", "owner", "campus.put"),
  r("GET", "/v1/workspaces/:id/watchers", "owner", "watchers.list"),
  r("PUT", "/v1/workspaces/:id/watchers/:user_id", "owner", "watchers.add"),
  r("DELETE", "/v1/workspaces/:id/watchers/:user_id", "owner", "watchers.remove"),
  r("PUT", "/v1/workspaces/:id/machines/:machine_id", "owner", "workspace_machines.add"),
  r("DELETE", "/v1/workspaces/:id/machines/:machine_id", "owner", "workspace_machines.remove"),
  r("GET", "/v1/workspaces/:id/projects", "any", "projects.list"),
  r("POST", "/v1/workspaces/:id/projects", "owner", "projects.create"),
  r("GET", "/v1/projects/:id", "any", "projects.get"),
  r("PATCH", "/v1/projects/:id", "owner", "projects.update"),
  r("DELETE", "/v1/projects/:id", "owner", "projects.archive"),
  r("GET", "/v1/projects/:id/layout", "any", "layout.get"),
  r("PUT", "/v1/projects/:id/layout", "owner", "layout.put"),
  r("GET", "/v1/projects/:id/roles", "any", "roles.list"),
  r("POST", "/v1/projects/:id/roles", "owner", "roles.create"),
  r("PATCH", "/v1/roles/:id", "owner", "roles.update"),
  r("DELETE", "/v1/roles/:id", "owner", "roles.delete"),
  r("GET", "/v1/imports", "owner", "imports.list"),
  r("GET", "/v1/imports/:id", "owner", "imports.get"),
  r("POST", "/v1/imports/:id/apply", "owner", "imports.apply"),
  r("DELETE", "/v1/imports/:id", "owner", "imports.dismiss"),
  r("GET", "/v1/state", "any", "state"),
  r("GET", "/v1/stream", "any", "stream"),
  r("GET", "/v1/connect", "machine", "connect"),
  r("POST", "/v1/commands", "owner", "commands"),
  r("GET", "/v1/audit", "owner", "audit"),
];

export interface RouteCtx<E extends HttpEnv = HttpEnv> {
  env: E;
  principal: Principal;
  params: Record<string, string>;
  url: URL;
  route: RouteDef;
}

export type Handler<E extends HttpEnv = HttpEnv> = (request: Request, ctx: RouteCtx<E>) => Response | Promise<Response>;

export interface RouterDeps<E extends HttpEnv = HttpEnv> {
  resolvePrincipal: (request: Request, env: E) => Promise<Principal | Response>;
  csrfHash?: (env: E, sessionId: string) => Promise<string | null>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function matchPath(pattern: string, path: string): Record<string, string> | null {
  const want = pattern.split("/");
  const got = path.split("/");
  if (want.length !== got.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < want.length; i++) {
    const w = want[i]!;
    const g = got[i]!;
    if (w.startsWith(":")) {
      if (!UUID.test(g)) return null;
      params[w.slice(1)] = g;
    } else if (w !== g) {
      return null;
    }
  }
  return params;
}

function gate(who: Who, p: Principal): Response | null {
  const unauthorized = () => errorResponse("unauthorized", "esta ruta requiere una credencial válida");
  const forbidden = () => errorResponse("forbidden", "no tienes permiso para esta operación");
  if (p.kind === "operator") return who === "operator" ? null : unauthorized();
  switch (who) {
    case "anon":
      return null;
    case "operator":
      return unauthorized();
    case "any":
      if (p.kind === "user") return null;
      return p.kind === "anonymous" ? unauthorized() : forbidden();
    case "owner":
      if (p.kind === "user" && p.role === "owner") return null;
      return p.kind === "anonymous" ? unauthorized() : forbidden();
    case "machine":
      if (p.kind === "machine") return null;
      return p.kind === "anonymous" ? unauthorized() : forbidden();
  }
}

export function createApi<E extends HttpEnv>(
  handlers: Partial<Record<string, Handler<E>>>,
  deps: RouterDeps<E>,
): (request: Request, env: E) => Promise<Response> {
  const table = ROUTES.filter((route) => handlers[route.name] !== undefined);

  async function route(request: Request, env: E, url: URL): Promise<Response> {
    const method = request.method === "HEAD" ? "GET" : request.method;
    const hits = table.flatMap((def) => {
      const params = matchPath(def.path, url.pathname);
      return params === null ? [] : [{ def, params }];
    });

    if (method === "OPTIONS" && request.headers.has("Origin")) {
      const cors = corsHeaders(request, env);
      if (hits.length === 0) return errorResponse("not_found", "ruta desconocida");
      if (Object.keys(cors).length > 0) return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
    }

    const credential = readCredential(request);
    if (credential instanceof Response) return credential;
    const principal = await deps.resolvePrincipal(request, env);
    if (principal instanceof Response) return principal;

    if (hits.length === 0) return errorResponse("not_found", "ruta desconocida");
    const hit = hits.find((h) => h.def.method === method);
    if (hit === undefined) {
      const allow: string[] = [...new Set(hits.map((h) => h.def.method))];
      if (allow.includes("GET")) allow.push("HEAD");
      return errorResponse("bad_request", "método no permitido en esta ruta", { status: 405, headers: { Allow: allow.join(", ") } });
    }

    const denied = gate(hit.def.who, principal);
    if (denied) return denied;

    const viaCookie = credential.via === "cookie";
    if (needsCsrf(request.method, viaCookie)) {
      const hash = principal.kind === "user" && deps.csrfHash ? await deps.csrfHash(env, principal.sessionId) : null;
      const csrf = await checkCsrf(request, env, hash);
      if (csrf) return csrf;
    }

    const tooLarge = bodyTooLarge(request);
    if (tooLarge) return tooLarge;

    const handler = handlers[hit.def.name]!;
    return handler(request, { env, principal, params: hit.params, url, route: hit.def });
  }

  return async (request, env) => {
    const url = new URL(request.url);
    const started = Date.now();
    let response: Response;
    try {
      response = await route(request, env, url);
    } catch (err) {
      console.error(JSON.stringify({ method: request.method, path: url.pathname, code: "internal", error: err instanceof Error ? err.name : "unknown", ms: Date.now() - started }));
      response = errorResponse("internal", "error interno");
    }
    if (request.method === "HEAD") response = new Response(null, { status: response.status, statusText: response.statusText, headers: response.headers });
    return withHeaders(response, { "Cache-Control": "no-store", ...SECURITY_HEADERS, ...corsHeaders(request, env) });
  };
}

export async function dispatchHost<E extends HttpEnv>(
  request: Request,
  env: E,
  api: (request: Request, env: E) => Promise<Response>,
): Promise<Response> {
  const host = new URL(request.url).host;
  if (host === new URL(apiOrigin(env)).host) return api(request, env);
  if (host === new URL(webOrigin(env)).host && env.ASSETS) {
    const asset = await env.ASSETS.fetch(request);
    return withHeaders(asset, { ...SECURITY_HEADERS, "Content-Security-Policy": webCsp(apiOrigin(env)) });
  }
  return withHeaders(errorResponse("not_found", "host desconocido"), SECURITY_HEADERS);
}
