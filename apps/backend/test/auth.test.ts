import assert from "node:assert/strict";
import { pbkdf2Sync, randomBytes } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { requireOwner, resolvePrincipal } from "../src/auth.ts";
import { base64urlEncode, hashPassword, pepperFromEnv } from "../src/crypto.ts";
import { applyMigrations, now, uuid } from "../src/db.ts";
import worker, { type Env } from "../src/index.ts";
import { AUTH_FAILED_MESSAGE } from "../src/ratelimit.ts";
import { FakeD1Database } from "./d1.ts";

const API = "https://api.chopshop.novarix.online";
const WEB = "https://chopshop.novarix.online";
const SECRET = "pepper-de-prueba-0123456789abcdefghij";
const PEPPER = pepperFromEnv({ PASSWORD_PEPPER: SECRET });
const PASSWORD = "caballo bateria grapa";
const OWNER_EMAIL = "Duenia@Ejemplo.test";
const WATCHER_EMAIL = "mirona@ejemplo.test";
const IP = "203.0.113.7";
const T0 = Date.parse("2026-10-30T12:00:00.000Z");
const MIN = 60_000;
const DAY = 24 * 60 * MIN;
const DIR = new URL("../migrations/", import.meta.url);

type Json = Record<string, unknown>;

let env: Env;
let hubCalls: string[];

function migrations(): string[] {
  return readdirSync(DIR)
    .filter((f) => /^\d{4}_.+\.sql$/.test(f))
    .sort()
    .map((f) => readFileSync(new URL(f, DIR), "utf8"));
}

function db(): D1Database {
  return env.DB!;
}

async function addUser(email: string, role: "owner" | "watcher", passwordHash?: string, status = "active"): Promise<string> {
  const id = uuid();
  const t = now();
  await db()
    .prepare(
      "INSERT INTO users (id, email, email_normalized, password_hash, role, status, password_changed_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id, email, email.trim().toLowerCase(), passwordHash ?? (await hashPassword(PASSWORD, PEPPER)), role, status, t, t, t)
    .run();
  return id;
}

async function call(path: string, init: { method?: string; headers?: Record<string, string>; body?: unknown } = {}): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": IP, ...init.headers };
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  const req = new Request(`${API}${path}`, {
    method: init.method ?? "GET",
    headers,
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  });
  return worker.fetch(req, env);
}

function login(email: string, password = PASSWORD, client = "mac"): Promise<Response> {
  return call("/v1/auth/login", { method: "POST", body: { email, password, client, device_name: "Mac mini" } });
}

async function token(email: string, password = PASSWORD): Promise<string> {
  const res = await login(email, password);
  assert.equal(res.status, 200);
  return ((await res.json()) as Json).token as string;
}

function bearer(t: string): Record<string, string> {
  return { Authorization: `Bearer ${t}` };
}

async function row(sql: string, ...params: (string | number | null)[]): Promise<Json | null> {
  return db().prepare(sql).bind(...params).first<Json>();
}

function stable(b: Json): Json {
  const { id: _id, ts: _ts, ...rest } = b;
  return rest;
}

beforeEach(async () => {
  hubCalls = [];
  const d1 = new FakeD1Database().asD1();
  await applyMigrations(d1, migrations());
  env = {
    DB: d1,
    PASSWORD_PEPPER: SECRET,
    RELAY_OPERATOR_TOKEN: "secreto-de-operador-de-prueba",
    HUB: {
      idFromName: (name: string) => ({ name }) as unknown as DurableObjectId,
      get: () => ({ sessionRevoked: async (id: string) => void hubCalls.push(id) }),
    },
  };
});

afterEach(() => {
  mock.restoreAll();
  mock.timers.reset();
});

describe("login", () => {
  it("mac recibe un Bearer ss1_ que sirve para /v1/auth/me", async () => {
    const ownerId = await addUser(OWNER_EMAIL, "owner");
    const res = await login(" duenia@EJEMPLO.test ");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Set-Cookie"), null);
    const b = (await res.json()) as Json;
    assert.match(b.token as string, /^ss1_[A-Za-z0-9_-]{43}$/);
    assert.equal(b.csrf_token, undefined);
    assert.deepEqual(Object.keys(b.user as Json).sort(), ["created_at", "display_name", "email", "id", "role", "status"]);
    assert.equal((b.user as Json).id, ownerId);
    assert.equal((b.session as Json).client, "mac");
    const stored = await row("SELECT token_hash, device_name FROM sessions WHERE id = ?", (b.session as Json).id as string);
    assert.notEqual(stored?.token_hash, b.token);
    assert.equal(stored?.device_name, "Mac mini");
    const me = await call("/v1/auth/me", { headers: bearer(b.token as string) });
    assert.equal(me.status, 200);
    const mb = (await me.json()) as Json;
    assert.equal((mb.user as Json).role, "owner");
    assert.equal((mb.session as Json).id, (b.session as Json).id);
    assert.equal(mb.csrf_token, undefined);
    assert.equal((await row("SELECT count(*) AS c FROM audit_log WHERE action = 'auth.login' AND actor_user_id = ?", ownerId))?.c, 1);
    assert.notEqual((await row("SELECT last_login_at FROM users WHERE id = ?", ownerId))?.last_login_at, null);
  });

  it("401 idéntico con correo inexistente, contraseña mala y usuario desactivado", async () => {
    await addUser(OWNER_EMAIL, "owner");
    await addUser(WATCHER_EMAIL, "watcher", undefined, "disabled");
    const bodies: Json[] = [];
    for (const [email, pw] of [["nadie@ejemplo.test", PASSWORD], [OWNER_EMAIL, "otra contraseña larga"], [WATCHER_EMAIL, PASSWORD]] as const) {
      const res = await login(email, pw);
      assert.equal(res.status, 401);
      bodies.push(stable((await res.json()) as Json));
    }
    assert.equal(bodies[0]!.message, AUTH_FAILED_MESSAGE);
    assert.deepEqual(bodies[1], bodies[0]);
    assert.deepEqual(bodies[2], bodies[0]);
    const failedAudit = await db().prepare("SELECT detail FROM audit_log WHERE action = 'auth.login_failed'").all<Json>();
    assert.equal(failedAudit.results.length, 3);
    for (const r of failedAudit.results) assert.doesNotMatch(r.detail as string, /@/);
  });

  it("valida el cuerpo y responde 503 sin pepper", async () => {
    assert.equal((await call("/v1/auth/login", { method: "POST", body: { email: "x", password: PASSWORD, client: "mac", device_name: "d" } })).status, 400);
    const badClient = await call("/v1/auth/login", { method: "POST", body: { email: OWNER_EMAIL, password: PASSWORD, client: "tv", device_name: "d" } });
    assert.equal(((await badClient.json()) as Json).field, "client");
    delete env.PASSWORD_PEPPER;
    const res = await login(OWNER_EMAIL);
    assert.equal(res.status, 503);
    assert.equal(((await res.json()) as Json).code, "internal");
  });

  it("un hash viejo sin pepper se rehace al entrar", async () => {
    const salt = randomBytes(16);
    const old = `pbkdf2-sha256$1000$${base64urlEncode(salt)}$${base64urlEncode(pbkdf2Sync(PASSWORD.normalize("NFC"), salt, 1000, 32, "sha256"))}`;
    const id = await addUser(OWNER_EMAIL, "owner", old);
    assert.equal((await login(OWNER_EMAIL)).status, 200);
    const stored = (await row("SELECT password_hash FROM users WHERE id = ?", id))?.password_hash as string;
    assert.match(stored, /^pbkdf2-sha256-p1\$10000\$/);
    assert.equal((await login(OWNER_EMAIL)).status, 200);
  });
});

describe("límites de intentos", () => {
  it("bloqueo progresivo con Retry-After y sin PBKDF2 mientras dura", async () => {
    mock.timers.enable({ apis: ["Date"], now: T0 });
    await addUser(OWNER_EMAIL, "owner");
    for (let i = 0; i < 4; i++) assert.equal((await login(OWNER_EMAIL, "contraseña equivocada")).status, 401);
    const locked = await login(OWNER_EMAIL, "contraseña equivocada");
    assert.equal(locked.status, 429);
    const lb = (await locked.json()) as Json;
    assert.equal(lb.code, "rate_limited");
    assert.equal(lb.retry_after_s, 60);
    assert.equal(locked.headers.get("Retry-After"), "60");

    const derive = mock.method(crypto.subtle, "deriveBits");
    const blocked = await login(OWNER_EMAIL);
    assert.equal(blocked.status, 429);
    assert.equal(derive.mock.callCount(), 0);
    derive.mock.restore();

    mock.timers.tick(61_000);
    const again = await login(OWNER_EMAIL, "contraseña equivocada");
    assert.equal(again.status, 429);
    assert.equal(again.headers.get("Retry-After"), "120");
    assert.equal(((await again.json()) as Json).retry_after_s, 120);

    mock.timers.tick(121_000);
    assert.equal((await login(OWNER_EMAIL)).status, 200);
    assert.equal((await login(OWNER_EMAIL, "contraseña equivocada")).status, 401);
  });
});

describe("cookie web y CSRF", () => {
  it("login web pone la cookie con atributos y entrega csrf_token", async () => {
    await addUser(OWNER_EMAIL, "owner");
    const res = await login(OWNER_EMAIL, PASSWORD, "web");
    assert.equal(res.status, 200);
    const cookie = res.headers.get("Set-Cookie") ?? "";
    assert.match(cookie, /^__Host-chopshop_session=ss1_[A-Za-z0-9_-]{43}; Path=\/; Secure; HttpOnly; SameSite=Strict; Max-Age=604800$/);
    const b = (await res.json()) as Json;
    assert.equal(b.token, undefined);
    assert.match(b.csrf_token as string, /^cx1_[A-Za-z0-9_-]{43}$/);
    assert.doesNotMatch(JSON.stringify(b), /ss1_/);
    const session = cookie.split(";")[0]!;

    const me = await call("/v1/auth/me", { headers: { Cookie: session } });
    assert.equal(me.status, 200);
    const csrf = ((await me.json()) as Json).csrf_token as string;
    assert.match(csrf, /^cx1_/);
    assert.notEqual(csrf, b.csrf_token);

    assert.equal((await call("/v1/auth/logout", { method: "POST", headers: { Cookie: session, Origin: WEB, "X-CSRF-Token": b.csrf_token as string } })).status, 403);
    assert.equal((await call("/v1/auth/logout", { method: "POST", headers: { Cookie: session } })).status, 403);
    const out = await call("/v1/auth/logout", { method: "POST", headers: { Cookie: session, Origin: WEB, "X-CSRF-Token": csrf } });
    assert.equal(out.status, 204);
    assert.match(out.headers.get("Set-Cookie") ?? "", /^__Host-chopshop_session=; .*Max-Age=0$/);
    assert.equal((await call("/v1/auth/me", { headers: { Cookie: session } })).status, 401);
  });

  it("un token de sesión mac no vale como cookie", async () => {
    await addUser(OWNER_EMAIL, "owner");
    const t = await token(OWNER_EMAIL);
    assert.equal((await call("/v1/auth/me", { headers: { Cookie: `__Host-chopshop_session=${t}` } })).status, 401);
    assert.equal((await call("/v1/auth/me", { headers: bearer(t) })).status, 200);
  });
});

describe("expiración deslizante", () => {
  it("renueva tras 5 min de actividad y caduca por inactividad", async () => {
    mock.timers.enable({ apis: ["Date"], now: T0 });
    await addUser(OWNER_EMAIL, "owner");
    const t = await token(OWNER_EMAIL);
    const sel = "SELECT last_seen_at, expires_at, absolute_expires_at FROM sessions";
    const first = (await row(sel))!;
    assert.equal(first.expires_at, new Date(T0 + 30 * DAY).toISOString());
    assert.equal(first.absolute_expires_at, new Date(T0 + 90 * DAY).toISOString());

    mock.timers.tick(4 * MIN);
    assert.equal((await call("/v1/auth/me", { headers: bearer(t) })).status, 200);
    assert.deepEqual(await row(sel), first);

    mock.timers.tick(2 * MIN);
    assert.equal((await call("/v1/auth/me", { headers: bearer(t) })).status, 200);
    const slid = (await row(sel))!;
    assert.equal(slid.last_seen_at, new Date(T0 + 6 * MIN).toISOString());
    assert.equal(slid.expires_at, new Date(T0 + 6 * MIN + 30 * DAY).toISOString());

    mock.timers.tick(30 * DAY);
    assert.equal((await call("/v1/auth/me", { headers: bearer(t) })).status, 401);
  });

  it("la caducidad absoluta corta aunque haya actividad", async () => {
    mock.timers.enable({ apis: ["Date"], now: T0 });
    await addUser(OWNER_EMAIL, "owner");
    const res = await login(OWNER_EMAIL, PASSWORD, "web");
    const session = (res.headers.get("Set-Cookie") ?? "").split(";")[0]!;
    const absolute = new Date(T0 + 7 * DAY).toISOString();
    for (let h = 11; h < 7 * 24; h += 11) {
      mock.timers.tick(11 * 60 * MIN);
      assert.equal((await call("/v1/auth/me", { headers: { Cookie: session } })).status, 200, `hora ${h}`);
    }
    assert.equal((await row("SELECT expires_at FROM sessions"))?.expires_at, absolute);
    mock.timers.tick(7 * DAY - 165 * 60 * MIN);
    assert.equal((await call("/v1/auth/me", { headers: { Cookie: session } })).status, 401);
  });
});

describe("sesiones", () => {
  it("revocar cierra la sesión y avisa al Hub", async () => {
    await addUser(OWNER_EMAIL, "owner");
    const a = await token(OWNER_EMAIL);
    const bRes = await login(OWNER_EMAIL);
    const bBody = (await bRes.json()) as Json;
    const bId = (bBody.session as Json).id as string;
    const del = await call(`/v1/sessions/${bId}`, { method: "DELETE", headers: bearer(a) });
    assert.equal(del.status, 204);
    assert.deepEqual(hubCalls, [bId]);
    assert.equal((await call("/v1/auth/me", { headers: bearer(bBody.token as string) })).status, 401);
    assert.equal((await row("SELECT revoked_reason FROM sessions WHERE id = ?", bId))?.revoked_reason, "revoked");
    assert.equal((await call(`/v1/sessions/${bId}`, { method: "DELETE", headers: bearer(a) })).status, 404);
    assert.equal((await row("SELECT count(*) AS c FROM audit_log WHERE action = 'session.revoked' AND target_id = ?", bId))?.c, 1);

    const meRes = await call("/v1/auth/me", { headers: bearer(a) });
    const aId = (((await meRes.json()) as Json).session as Json).id as string;
    assert.equal((await call("/v1/auth/logout", { method: "POST", headers: bearer(a) })).status, 204);
    assert.deepEqual(hubCalls, [bId, aId]);
    assert.equal((await row("SELECT revoked_reason FROM sessions WHERE id = ?", aId))?.revoked_reason, "logout");
    assert.equal((await call("/v1/auth/me", { headers: bearer(a) })).status, 401);
  });

  it("el watcher solo ve y revoca sus sesiones; el dueño ve todas", async () => {
    const ownerId = await addUser(OWNER_EMAIL, "owner");
    const watcherId = await addUser(WATCHER_EMAIL, "watcher");
    const o = await token(OWNER_EMAIL);
    const w = await token(WATCHER_EMAIL);
    await token(WATCHER_EMAIL);

    const wl = (await (await call(`/v1/sessions?user_id=${ownerId}`, { headers: bearer(w) })).json()) as { sessions: Json[] };
    assert.equal(wl.sessions.length, 2);
    assert.ok(wl.sessions.every((s) => s.user_id === watcherId));
    assert.equal(wl.sessions.filter((s) => s.current).length, 1);
    assert.doesNotMatch(JSON.stringify(wl), /ss1_|token_hash|csrf/);

    const ol = (await (await call("/v1/sessions", { headers: bearer(o) })).json()) as { sessions: Json[] };
    assert.equal(ol.sessions.length, 3);
    const only = (await (await call(`/v1/sessions?user_id=${watcherId}`, { headers: bearer(o) })).json()) as { sessions: Json[] };
    assert.equal(only.sessions.length, 2);

    const ownerSession = ol.sessions.find((s) => s.user_id === ownerId)!.id as string;
    assert.equal((await call(`/v1/sessions/${ownerSession}`, { method: "DELETE", headers: bearer(w) })).status, 404);
    assert.equal((await call(`/v1/sessions/${uuid()}`, { method: "DELETE", headers: bearer(w) })).status, 404);
    assert.deepEqual(hubCalls, []);
    const own = wl.sessions.find((s) => !s.current)!.id as string;
    assert.equal((await call(`/v1/sessions/${own}`, { method: "DELETE", headers: bearer(w) })).status, 204);
    assert.equal((await call(`/v1/sessions/${wl.sessions.find((s) => s.current)!.id}`, { method: "DELETE", headers: bearer(o) })).status, 204);
    assert.equal((await call("/v1/auth/me", { headers: bearer(w) })).status, 401);
  });
});

describe("cambio de contraseña", () => {
  it("verifica la actual, aplica la política y revoca las demás sesiones", async () => {
    await addUser(OWNER_EMAIL, "owner");
    const a = await token(OWNER_EMAIL);
    const bBody = (await (await login(OWNER_EMAIL)).json()) as Json;
    const change = (current: string, next: string) =>
      call("/v1/auth/password", { method: "POST", headers: bearer(a), body: { current_password: current, new_password: next } });

    const short = await change(PASSWORD, "corta");
    assert.equal(short.status, 400);
    assert.equal(((await short.json()) as Json).field, "password");
    assert.equal((await change(PASSWORD, "mi duenia secreta 123")).status, 400);
    const wrong = await change("no es la actual", "nueva contraseña larga");
    assert.equal(wrong.status, 401);
    assert.equal(((await wrong.json()) as Json).message, AUTH_FAILED_MESSAGE);

    assert.equal((await change(PASSWORD, "nueva contraseña larga")).status, 204);
    assert.deepEqual(hubCalls, [(bBody.session as Json).id]);
    assert.equal((await call("/v1/auth/me", { headers: bearer(bBody.token as string) })).status, 401);
    assert.equal((await call("/v1/auth/me", { headers: bearer(a) })).status, 200);
    assert.equal((await login(OWNER_EMAIL)).status, 401);
    assert.equal((await login(OWNER_EMAIL, "nueva contraseña larga")).status, 200);
  });
});

describe("principal", () => {
  it("resuelve operador, rechaza bearers desconocidos y requireOwner distingue roles", async () => {
    const op = await resolvePrincipal(new Request(`${API}/v1/operator/recover`, { headers: bearer("secreto-de-operador-de-prueba") }), env);
    assert.deepEqual(op, { kind: "operator" });
    const bad = await resolvePrincipal(new Request(`${API}/v1/auth/me`, { headers: bearer(`ss1_${"x".repeat(43)}`) }), env);
    assert.ok(bad instanceof Response && bad.status === 401);
    assert.equal((await call("/v1/auth/me", { headers: bearer("secreto-de-operador-de-prueba") })).status, 401);
    assert.equal((await call("/v1/auth/me")).status, 401);

    assert.equal((requireOwner({ kind: "anonymous" }) as Response).status, 401);
    const watcher = { kind: "user", userId: "w", role: "watcher", sessionId: "s", client: "mac", viaCookie: false } as const;
    assert.equal((requireOwner(watcher) as Response).status, 403);
    assert.deepEqual(requireOwner({ ...watcher, role: "owner" }), { userId: "w", role: "owner", sessionId: "s" });
  });
});
