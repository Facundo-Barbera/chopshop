import { AGENT_WS_PATH } from "./agentws";
import { type RelayDb, type TokenRecord, sha256Hex } from "./db";
import { timingSafeEqual } from "./pair";
import { errorResponse } from "./viewer";

export const CONNECT_PATH = "/v1/connect";

export type Role = "anonymous" | "viewer" | "machine" | "admin";

export type RouteName = "redeem" | "create_code" | "revoke" | "agent_ws" | "whoami" | "stream" | "state";

interface Route {
  name: RouteName;
  method: "GET" | "POST" | "DELETE";
  match: (path: string) => boolean;
  roles: readonly Role[];
}

const exact = (...paths: string[]) => (path: string) => paths.includes(path);
const prefix = (...prefixes: string[]) => (path: string) => prefixes.some((p) => path.startsWith(p) && path.length > p.length);

export const ROUTES: readonly Route[] = [
  { name: "redeem", method: "POST", match: exact("/v1/pair"), roles: ["anonymous"] },
  { name: "create_code", method: "POST", match: exact("/v1/pair/codes"), roles: ["admin"] },
  { name: "revoke", method: "DELETE", match: prefix("/v1/tokens/", "/v1/pair/codes/"), roles: ["admin"] },
  { name: "agent_ws", method: "GET", match: exact(AGENT_WS_PATH, CONNECT_PATH), roles: ["machine"] },
  { name: "whoami", method: "GET", match: exact("/whoami"), roles: ["viewer", "machine"] },
  { name: "stream", method: "GET", match: exact("/stream"), roles: ["viewer"] },
  { name: "state", method: "GET", match: exact("/state"), roles: ["viewer"] },
];

export interface Caller {
  role: Role;
  record: TokenRecord | null;
}

export async function resolveCaller(request: Request, db: RelayDb, operatorToken: string | undefined): Promise<Caller | Response> {
  const auth = request.headers.get("Authorization");
  if (auth === null) return { role: "anonymous", record: null };
  const bearer = /^Bearer\s+(\S+)$/i.exec(auth)?.[1];
  const unauthorized = () => errorResponse("unauthorized", "credencial ausente, inválida o revocada", { "WWW-Authenticate": "Bearer" });
  if (bearer === undefined) return unauthorized();
  if (operatorToken && timingSafeEqual(await sha256Hex(bearer), await sha256Hex(operatorToken))) {
    return { role: "admin", record: null };
  }
  const record = await db.verifyToken(bearer);
  if (!record) return unauthorized();
  return { role: record.scope === "viewer" ? "viewer" : "machine", record };
}

export function authorize(role: Role, method: string, path: string): RouteName | Response {
  if (role === "viewer" && method !== "GET") return errorResponse("forbidden", "un token viewer solo puede hacer GET");
  const candidates = ROUTES.filter((r) => r.match(path));
  if (candidates.length === 0) return new Response("Not Found", { status: 404 });
  const allowed = candidates.filter((r) => r.roles.includes(role));
  if (allowed.length === 0) {
    if (role === "anonymous") return errorResponse("unauthorized", "esta ruta requiere credencial", { "WWW-Authenticate": "Bearer" });
    return errorResponse("forbidden", `el rol ${role} no puede usar esta ruta`);
  }
  const hit = allowed.find((r) => r.method === method);
  if (!hit) return new Response("Method Not Allowed", { status: 405, headers: { Allow: allowed.map((r) => r.method).join(", ") } });
  return hit.name;
}
