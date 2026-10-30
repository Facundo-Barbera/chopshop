import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { describe, it } from "node:test";
import {
  type HttpEnv,
  type Principal,
  MAX_BODY_BYTES,
  SESSION_COOKIE,
  errorResponse,
  readCookie,
  readJson,
  sessionCookie,
} from "../src/http.ts";
import { type Handler, ROUTES, createApi, dispatchHost, matchPath } from "../src/router.ts";

const API = "https://api.chopshop.novarix.online";
const WEB = "https://chopshop.novarix.online";
const WS = "0b7f1c2e-3d4a-4b5c-8d6e-7f8091a2b3c4";
const USER = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
const CSRF = `cx1_${"a".repeat(43)}`;
const CSRF_HASH = createHash("sha256").update(CSRF).digest("hex");

const PRINCIPALS: Record<string, Principal> = {
  [`Bearer ss1_${"o".repeat(43)}`]: { kind: "user", userId: "owner", role: "owner", sessionId: "s-owner", client: "mac", viaCookie: false },
  [`Bearer ss1_${"w".repeat(43)}`]: { kind: "user", userId: "watcher", role: "watcher", sessionId: "s-watcher", client: "mac", viaCookie: false },
  [`Bearer cm1_${"m".repeat(43)}`]: { kind: "machine", machineId: "m1", localMachineId: null, paused: false },
  "Bearer operator-secret": { kind: "operator" },
};
const OWNER = `Bearer ss1_${"o".repeat(43)}`;
const WATCHER = `Bearer ss1_${"w".repeat(43)}`;
const MACHINE = `Bearer cm1_${"m".repeat(43)}`;
const OPERATOR = "Bearer operator-secret";
const WEB_COOKIE = `ss1_${"c".repeat(43)}`;

async function resolvePrincipal(request: Request): Promise<Principal | Response> {
  const auth = request.headers.get("Authorization");
  const cookie = readCookie(request, SESSION_COOKIE);
  if (cookie === WEB_COOKIE) return { kind: "user", userId: "owner", role: "owner", sessionId: "s-web", client: "web", viaCookie: true };
  if (auth === null && cookie === null) return { kind: "anonymous" };
  return (auth !== null && PRINCIPALS[auth]) || errorResponse("unauthorized", "credencial ausente, inválida o revocada");
}

const echo: Handler = (_req, ctx) => Response.json({ route: ctx.route.name, params: ctx.params, principal: ctx.principal.kind });

const handlers: Record<string, Handler> = Object.fromEntries(ROUTES.map((r) => [r.name, echo]));
handlers["projects.create"] = async (req) => {
  const body = await readJson(req);
  return body instanceof Response ? body : Response.json({ got: body });
};
handlers["audit"] = () => {
  throw new Error("ss1_secreto");
};
delete handlers["commands"];

const api = createApi(handlers, { resolvePrincipal, csrfHash: async (_env, sessionId) => (sessionId === "s-web" ? CSRF_HASH : null) });

function env(extra: Partial<HttpEnv> = {}): HttpEnv {
  return { ...extra };
}

function call(path: string, init: RequestInit & { headers?: Record<string, string> } = {}, host = API): Promise<Response> {
  return dispatchHost(new Request(`${host}${path}`, init), env(), api);
}

async function body(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

describe("errores §5.1", () => {
  it("forma del error y campos opcionales", async () => {
    const res = errorResponse("rate_limited", "espera", { retryAfterS: 30, field: "email" });
    assert.equal(res.status, 429);
    assert.equal(res.headers.get("Retry-After"), "30");
    assert.equal(res.headers.get("Cache-Control"), "no-store");
    const b = await body(res);
    assert.equal(b.v, 2);
    assert.equal(b.type, "error");
    assert.equal(b.re, null);
    assert.equal(b.code, "rate_limited");
    assert.equal(b.retry_after_s, 30);
    assert.equal(b.field, "email");
    assert.match(String(b.id), /^[0-9A-HJKMNP-TV-Z]{26}$/);
    assert.match(String(b.ts), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    assert.equal("current" in b, false);
  });

  it("current en 409, 503 con internal y 504 timeout", async () => {
    const conflict = errorResponse("conflict", "rev", { current: { rev: 3 } });
    assert.equal(conflict.status, 409);
    assert.deepEqual((await body(conflict)).current, { rev: 3 });
    assert.equal(errorResponse("internal", "x", { status: 503 }).status, 503);
    assert.equal(errorResponse("timeout", "x").status, 504);
    assert.equal(errorResponse("unauthorized", "x").headers.get("WWW-Authenticate"), "Bearer");
  });
});

describe("tabla de rutas", () => {
  it("parámetros solo con UUID", () => {
    assert.deepEqual(matchPath("/v1/workspaces/:id/watchers/:user_id", `/v1/workspaces/${WS}/watchers/${USER}`), { id: WS, user_id: USER });
    assert.equal(matchPath("/v1/invitations/:id", "/v1/invitations/inspect"), null);
    assert.equal(matchPath("/v1/workspaces/:id", `/v1/workspaces/${WS}/`), null);
    assert.equal(matchPath("/v1/workspaces/:id", `/v1/workspaces/${WS.toUpperCase()}`), null);
  });

  it("despacha con parámetros y principal", async () => {
    const res = await call(`/v1/workspaces/${WS}/watchers/${USER}`, { method: "PUT", headers: { Authorization: OWNER } });
    assert.equal(res.status, 200);
    assert.deepEqual(await body(res), { route: "watchers.add", params: { id: WS, user_id: USER }, principal: "user" });
    assert.equal((await body(await call("/v1/invitations/inspect", { method: "POST" }))).route, "invitations.inspect");
  });

  it("404 para rutas desconocidas o sin handler", async () => {
    const res = await call("/v1/nada");
    assert.equal(res.status, 404);
    assert.equal((await body(res)).code, "not_found");
    assert.equal((await call("/v1/commands", { method: "POST", headers: { Authorization: OWNER } })).status, 404);
    assert.equal((await call(`/v1/projects/${WS}/tasks`, { headers: { Authorization: OWNER } })).status, 404);
  });

  it("405 con Allow", async () => {
    const res = await call(`/v1/workspaces/${WS}`, { method: "POST", headers: { Authorization: OWNER } });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("Allow"), "GET, PATCH, DELETE, HEAD");
    assert.equal((await body(res)).type, "error");
    const login = await call("/v1/auth/login");
    assert.equal(login.status, 405);
    assert.equal(login.headers.get("Allow"), "POST");
  });

  it("HEAD responde como GET sin cuerpo", async () => {
    const res = await call("/v1/auth/me", { method: "HEAD" });
    assert.equal(res.status, 401);
    assert.equal(await res.text(), "");
    assert.equal(res.headers.get("X-Frame-Options"), "DENY");
    assert.equal((await call("/health", { method: "HEAD" })).status, 200);
  });

  it("principales por columna quién", async () => {
    assert.equal((await call("/v1/workspaces")).status, 401);
    assert.equal((await call("/v1/workspaces", { headers: { Authorization: WATCHER } })).status, 200);
    assert.equal((await call("/v1/workspaces", { method: "POST", headers: { Authorization: WATCHER } })).status, 403);
    assert.equal((await call("/v1/auth/logout", { method: "POST", headers: { Authorization: WATCHER } })).status, 200);
    assert.equal((await call(`/v1/sessions/${USER}`, { method: "DELETE", headers: { Authorization: WATCHER } })).status, 200);
    assert.equal((await call("/v1/users", { headers: { Authorization: WATCHER } })).status, 403);
    assert.equal((await call("/v1/workspaces", { headers: { Authorization: MACHINE } })).status, 403);
    assert.equal((await call("/v1/connect", { headers: { Authorization: MACHINE } })).status, 200);
    assert.equal((await call("/v1/connect", { headers: { Authorization: OWNER } })).status, 403);
    assert.equal((await call("/v1/connect")).status, 401);
    assert.equal((await call("/v1/operator/recover", { method: "POST", headers: { Authorization: OPERATOR } })).status, 200);
    assert.equal((await call("/v1/operator/recover", { method: "POST", headers: { Authorization: OWNER } })).status, 401);
    assert.equal((await call("/v1/workspaces", { headers: { Authorization: OPERATOR } })).status, 401);
    assert.equal((await call("/health", { headers: { Authorization: OPERATOR } })).status, 401);
    assert.equal((await call("/v1/workspaces", { headers: { Authorization: "Bearer basura" } })).status, 401);
  });

  it("un error del handler da 500 sin filtrar el mensaje", async (t) => {
    const logs: string[] = [];
    t.mock.method(console, "error", (line: string) => logs.push(line));
    const res = await call("/v1/audit", { headers: { Authorization: OWNER } });
    assert.equal(res.status, 500);
    const text = await res.text();
    assert.equal(text.includes("ss1_"), false);
    assert.equal(logs.join("\n").includes("ss1_"), false);
    assert.equal(res.headers.get("Strict-Transport-Security"), "max-age=31536000; includeSubDomains");
  });
});

describe("cabeceras §6", () => {
  it("presentes en respuestas OK y de error de la API", async () => {
    for (const res of [await call("/health"), await call("/v1/nada"), await call("/v1/workspaces")]) {
      assert.equal(res.headers.get("Strict-Transport-Security"), "max-age=31536000; includeSubDomains");
      assert.equal(res.headers.get("X-Content-Type-Options"), "nosniff");
      assert.equal(res.headers.get("Referrer-Policy"), "no-referrer");
      assert.equal(res.headers.get("X-Frame-Options"), "DENY");
      assert.equal(res.headers.get("Cache-Control"), "no-store");
      assert.equal(res.headers.get("Content-Security-Policy"), null);
    }
  });
});

describe("CORS", () => {
  it("solo para el origen web", async () => {
    const web = await call("/health", { headers: { Origin: WEB } });
    assert.equal(web.headers.get("Access-Control-Allow-Origin"), WEB);
    assert.equal(web.headers.get("Access-Control-Allow-Credentials"), "true");
    assert.equal(web.headers.get("Vary"), "Origin");
    assert.equal(web.headers.get("Access-Control-Allow-Methods"), "GET, POST, PUT, PATCH, DELETE");
    assert.equal(web.headers.get("Access-Control-Allow-Headers"), "Content-Type, X-CSRF-Token");
    assert.equal(web.headers.get("Access-Control-Max-Age"), "600");
    for (const origin of ["https://evil.test", "http://chopshop.novarix.online", "https://chopshop.novarix.online.evil.test", "null"]) {
      const res = await call("/health", { headers: { Origin: origin } });
      assert.equal(res.headers.get("Access-Control-Allow-Origin"), null);
      assert.equal(res.headers.get("Access-Control-Allow-Credentials"), null);
    }
    assert.equal((await call("/health")).headers.get("Access-Control-Allow-Origin"), null);
  });

  it("preflight del origen web 204; de otro origen sin CORS", async () => {
    const pre = await call("/v1/workspaces", { method: "OPTIONS", headers: { Origin: WEB, "Access-Control-Request-Method": "POST" } });
    assert.equal(pre.status, 204);
    assert.equal(pre.headers.get("Access-Control-Allow-Origin"), WEB);
    const evil = await call("/v1/workspaces", { method: "OPTIONS", headers: { Origin: "https://evil.test" } });
    assert.notEqual(evil.status, 204);
    assert.equal(evil.headers.get("Access-Control-Allow-Origin"), null);
    assert.equal((await call("/v1/nada", { method: "OPTIONS", headers: { Origin: WEB } })).status, 404);
  });

  it("errores al origen web llevan CORS", async () => {
    const res = await call("/v1/workspaces", { headers: { Origin: WEB } });
    assert.equal(res.status, 401);
    assert.equal(res.headers.get("Access-Control-Allow-Origin"), WEB);
  });
});

describe("cookie y CSRF", () => {
  const cookie = `otra=1; ${SESSION_COOKIE}=${WEB_COOKIE}`;

  it("lee la cookie de sesión y fija sus atributos", () => {
    const req = new Request(`${API}/`, { headers: { Cookie: cookie } });
    assert.equal(readCookie(req, SESSION_COOKIE), WEB_COOKIE);
    assert.equal(readCookie(req, "nada"), null);
    assert.equal(sessionCookie("ss1_x", 604800), `${SESSION_COOKIE}=ss1_x; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=604800`);
  });

  it("GET por cookie no exige CSRF", async () => {
    assert.equal((await call("/v1/workspaces", { headers: { Cookie: cookie } })).status, 200);
  });

  it("escritura por cookie exige Origin y token", async () => {
    const post = (headers: Record<string, string>) => call("/v1/workspaces", { method: "POST", headers: { Cookie: cookie, ...headers } });
    assert.equal((await post({ Origin: WEB, "X-CSRF-Token": CSRF })).status, 200);
    const noOrigin = await post({ "X-CSRF-Token": CSRF });
    assert.equal(noOrigin.status, 403);
    assert.equal((await body(noOrigin)).code, "forbidden");
    assert.equal((await post({ Origin: "https://evil.test", "X-CSRF-Token": CSRF })).status, 403);
    assert.equal((await post({ Origin: WEB })).status, 403);
    assert.equal((await post({ Origin: WEB, "X-CSRF-Token": `cx1_${"b".repeat(43)}` })).status, 403);
    assert.equal((await post({ Origin: WEB, "X-CSRF-Token": "cx1_corto" })).status, 403);
    assert.equal((await call(`/v1/sessions/${USER}`, { method: "DELETE", headers: { Cookie: cookie, Origin: WEB } })).status, 403);
  });

  it("Bearer no necesita CSRF", async () => {
    assert.equal((await call("/v1/workspaces", { method: "POST", headers: { Authorization: OWNER } })).status, 200);
  });

  it("cookie y Bearer a la vez dan 400", async () => {
    const res = await call("/v1/workspaces", { headers: { Cookie: cookie, Authorization: OWNER } });
    assert.equal(res.status, 400);
    assert.equal((await body(res)).code, "bad_request");
  });
});

describe("límite de cuerpo", () => {
  const path = `/v1/workspaces/${WS}/projects`;

  it("acepta JSON dentro del límite", async () => {
    const res = await call(path, { method: "POST", headers: { Authorization: OWNER, "Content-Type": "application/json" }, body: '{"name":"p"}' });
    assert.equal(res.status, 200);
    assert.deepEqual(await body(res), { got: { name: "p" } });
  });

  it("413 por Content-Length", async () => {
    const big = "x".repeat(MAX_BODY_BYTES + 1);
    const res = await call(path, { method: "POST", headers: { Authorization: OWNER }, body: big });
    assert.equal(res.status, 413);
    assert.equal((await body(res)).code, "too_large");
  });

  it("413 al leer un cuerpo sin Content-Length", async () => {
    const chunk = new Uint8Array(256 * 1024).fill(32);
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent++ < 5) controller.enqueue(chunk);
        else controller.close();
      },
    });
    const req = new Request(`${API}${path}`, { method: "POST", body: stream, duplex: "half" } as RequestInit);
    const res = await readJson(req);
    assert.ok(res instanceof Response);
    assert.equal(res.status, 413);
  });

  it("JSON inválido o vacío da 400", async () => {
    const res = await call(path, { method: "POST", headers: { Authorization: OWNER }, body: "{no" });
    assert.equal(res.status, 400);
    assert.equal((await call(path, { method: "POST", headers: { Authorization: OWNER } })).status, 400);
  });
});

describe("despacho por Host", () => {
  const assets = {
    calls: [] as string[],
    async fetch(input: Request | string | URL): Promise<Response> {
      const url = input instanceof Request ? input.url : String(input);
      this.calls.push(url);
      return new Response("<html></html>", { headers: { "Content-Type": "text/html" } });
    },
  };

  it("la web va a ASSETS con CSP y cabeceras", async () => {
    const res = await dispatchHost(new Request(`${WEB}/invite`), env({ ASSETS: assets as unknown as Fetcher }), api);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), "<html></html>");
    assert.deepEqual(assets.calls, [`${WEB}/invite`]);
    assert.equal(
      res.headers.get("Content-Security-Policy"),
      "default-src 'self'; connect-src 'self' https://api.chopshop.novarix.online; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    );
    assert.equal(res.headers.get("X-Frame-Options"), "DENY");
    assert.equal(res.headers.get("Strict-Transport-Security"), "max-age=31536000; includeSubDomains");
  });

  it("la web nunca llega a la API", async () => {
    const res = await dispatchHost(new Request(`${WEB}/health`), env({ ASSETS: assets as unknown as Fetcher }), api);
    assert.equal(await res.text(), "<html></html>");
  });

  it("otro host da 404", async () => {
    const res = await call("/health", {}, "https://otro.test");
    assert.equal(res.status, 404);
    assert.equal((await body(res)).code, "not_found");
    assert.equal(res.headers.get("X-Content-Type-Options"), "nosniff");
  });

  it("orígenes configurables por env", async () => {
    const res = await dispatchHost(new Request("https://api.chopshop.test/health"), env({ API_ORIGIN: "https://api.chopshop.test" }), api);
    assert.equal(res.status, 200);
  });
});
