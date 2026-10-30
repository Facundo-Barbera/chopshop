import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it, type TestContext } from "node:test";
import { FakeState, FakeWebSocket } from "./env.ts";
import { Hub } from "../src/index.ts";

const OPERATOR = "operator-test-token";
const BASE = "https://relay.test";
const MACHINE = "contabo-dev";

type Role = "anonymous" | "viewer" | "machine" | "admin";

function fixture(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(new URL(`../../api/relay/fixtures/${name}.json`, import.meta.url), "utf8")) as Record<string, unknown>;
}

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
let counter = 0;

function msgId(): string {
  let n = ++counter;
  let out = "";
  for (let i = 0; i < 26; i++) {
    out = CROCKFORD[n % 32] + out;
    n = Math.floor(n / 32);
  }
  return out;
}

class Harness {
  readonly state = new FakeState();
  readonly hub: Hub;
  readonly aborts: AbortController[] = [];
  now = Date.UTC(2026, 9, 30, 14, 0, 0);

  constructor(t: TestContext) {
    t.mock.method(Date, "now", () => this.now);
    this.hub = new Hub(this.state as never, { HUB: null as never, RELAY_OPERATOR_TOKEN: OPERATOR });
    t.after(() => {
      for (const a of this.aborts) a.abort();
    });
  }

  async request(method: string, path: string, opts: { token?: string | null; body?: unknown; headers?: Record<string, string> } = {}) {
    const headers: Record<string, string> = { ...opts.headers };
    if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
    const ctrl = new AbortController();
    this.aborts.push(ctrl);
    const init: RequestInit = { method, headers, signal: ctrl.signal };
    if (opts.body !== undefined) init.body = typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body);
    return this.hub.fetch(new Request(`${BASE}${path}`, init));
  }

  async createCode(scope: "agent" | "viewer", extra: Record<string, unknown> = {}, account = "ac-0000beef") {
    const res = await this.request("POST", `/v1/pair/codes?account=${account}`, { token: OPERATOR, body: { scope, ...extra } });
    assert.equal(res.status, 200);
    return (await res.json()) as { id: string; code: string; expires_at: string };
  }

  async redeem(code: string, extra: Record<string, unknown> = {}) {
    return this.request("POST", "/v1/pair", { body: { code, ...extra } });
  }

  async pair(scope: "agent" | "viewer", account = "ac-0000beef") {
    const { code } = await this.createCode(scope, {}, account);
    const res = await this.redeem(code, scope === "agent" ? { machine_id: MACHINE } : {});
    assert.equal(res.status, 200);
    return (await res.json()) as { token_id: string; token: string; scope: string; machine_id: string | null };
  }

  async connect(token: string): Promise<FakeWebSocket> {
    const before = new Set(this.state.getWebSockets("agent"));
    const res = await this.request("GET", "/v1/connect", { token, headers: { Upgrade: "websocket" } });
    assert.equal(res.status, 101);
    const ws = this.state.getWebSockets("agent").find((w) => !before.has(w));
    assert.ok(ws);
    return ws;
  }

  async send(ws: FakeWebSocket, frame: Record<string, unknown>): Promise<Record<string, unknown> | undefined> {
    const count = ws.sent.length;
    await this.hub.webSocketMessage(ws as never, JSON.stringify(frame));
    return ws.frames().slice(count).at(-1);
  }

  async agent(): Promise<{ ws: FakeWebSocket; tokenId: string; token: string }> {
    const issued = await this.pair("agent");
    const ws = await this.connect(issued.token);
    const reply = await this.send(ws, { v: 1, type: "hello", id: msgId(), machine_id: MACHINE, agent_version: "0.9.0", protocol: [1], projects: [] });
    assert.equal(reply?.type, "welcome");
    return { ws, tokenId: issued.token_id, token: issued.token };
  }
}

function snapshot(seq: number, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...fixture("snapshot"), id: msgId(), machine_id: MACHINE, seq, ...extra };
}

function event(seq: number, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...fixture("event"), id: msgId(), machine_id: MACHINE, seq, ...extra };
}

async function readSse(res: Response, until: (text: string) => boolean): Promise<{ text: string; done: boolean }> {
  const reader = res.body!.getReader();
  const decoder = new TextDecoder();
  let text = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return { text, done: true };
    text += decoder.decode(value, { stream: true });
    if (until(text)) {
      reader.releaseLock();
      return { text, done: false };
    }
  }
}

describe("rutas por rol", () => {
  const cases: [string, string, Record<Role, number>][] = [
    ["POST", "/v1/pair", { anonymous: 400, viewer: 403, machine: 403, admin: 403 }],
    ["GET", "/v1/pair", { anonymous: 405, viewer: 403, machine: 403, admin: 403 }],
    ["POST", "/pair", { anonymous: 404, viewer: 403, machine: 404, admin: 404 }],
    ["POST", "/v1/pair/codes", { anonymous: 401, viewer: 403, machine: 403, admin: 400 }],
    ["DELETE", "/v1/tokens/tk-00000000", { anonymous: 401, viewer: 403, machine: 403, admin: 404 }],
    ["DELETE", "/v1/pair/codes/rc-00000000", { anonymous: 401, viewer: 403, machine: 403, admin: 404 }],
    ["GET", "/v1/connect", { anonymous: 401, viewer: 403, machine: 400, admin: 403 }],
    ["GET", "/agent/ws", { anonymous: 401, viewer: 403, machine: 400, admin: 403 }],
    ["GET", "/whoami", { anonymous: 401, viewer: 200, machine: 200, admin: 403 }],
    ["GET", "/state", { anonymous: 401, viewer: 200, machine: 403, admin: 403 }],
    ["GET", "/stream", { anonymous: 401, viewer: 200, machine: 403, admin: 403 }],
    ["GET", "/health", { anonymous: 200, viewer: 200, machine: 200, admin: 200 }],
    ["GET", "/nope", { anonymous: 404, viewer: 404, machine: 404, admin: 404 }],
    ["PUT", "/nope", { anonymous: 404, viewer: 403, machine: 404, admin: 404 }],
    ["PATCH", "/state", { anonymous: 401, viewer: 403, machine: 403, admin: 403 }],
    ["DELETE", "/whoami", { anonymous: 401, viewer: 403, machine: 405, admin: 403 }],
  ];

  it("cada rol recibe el estado esperado en cada ruta", async (t) => {
    const h = new Harness(t);
    const tokens: Record<Role, string | null> = {
      anonymous: null,
      viewer: (await h.pair("viewer")).token,
      machine: (await h.pair("agent")).token,
      admin: OPERATOR,
    };
    for (const [method, path, expected] of cases) {
      for (const role of Object.keys(expected) as Role[]) {
        const res = await h.request(method, path, { token: tokens[role] });
        assert.equal(res.status, expected[role], `${role} ${method} ${path}`);
      }
    }
  });

  it("un viewer recibe 403 en cualquier método que no sea GET", async (t) => {
    const h = new Harness(t);
    const { token } = await h.pair("viewer");
    for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
      for (const path of ["/v1/pair", "/v1/pair/codes", "/v1/tokens/tk-00000000", "/stream", "/whoami", "/inexistente"]) {
        const res = await h.request(method, path, { token });
        assert.equal(res.status, 403, `${method} ${path}`);
        assert.equal(((await res.json()) as { code: string }).code, "forbidden");
      }
    }
  });

  it("credencial inválida o mal formada da 401 antes de mirar la ruta; /health no mira la credencial", async (t) => {
    const h = new Harness(t);
    for (const auth of ["Bearer cr1_inexistente", "Basic abc", "Bearer"]) {
      const res = await h.request("GET", "/nope", { headers: { Authorization: auth } });
      assert.equal(res.status, 401, auth);
      assert.equal(res.headers.get("WWW-Authenticate"), "Bearer");
    }
    const health = await h.request("GET", "/health", { headers: { Authorization: "Bearer basura" } });
    assert.equal(health.status, 200);
  });

  it("whoami devuelve rol y machine_id sin el token", async (t) => {
    const h = new Harness(t);
    const agent = await h.pair("agent");
    const viewer = await h.pair("viewer");
    assert.deepEqual(await (await h.request("GET", "/whoami", { token: agent.token })).json(), { role: "machine", machine_id: MACHINE });
    assert.deepEqual(await (await h.request("GET", "/whoami", { token: viewer.token })).json(), { role: "viewer", machine_id: null });
  });
});

describe("pairing", () => {
  it("canjea un código viewer y el token resultante sirve", async (t) => {
    const h = new Harness(t);
    const { code } = await h.createCode("viewer", { name: "web" });
    assert.match(code, /^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/);
    const res = await h.redeem(code.toLowerCase());
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, unknown>;
    assert.deepEqual(Object.keys(body).sort(), ["machine_id", "protocol", "scope", "token", "token_id"]);
    assert.equal(body.scope, "viewer");
    assert.equal(body.machine_id, null);
    assert.match(body.token as string, /^cr1_[A-Za-z0-9_-]{43}$/);
    assert.equal((await h.request("GET", "/state", { token: body.token as string })).status, 200);
  });

  it("un código agent exige machine_id y ata el token a la máquina", async (t) => {
    const h = new Harness(t);
    const { code } = await h.createCode("agent");
    const missing = await h.redeem(code);
    assert.equal(missing.status, 400);
    const res = await h.redeem(code, { machine_id: MACHINE });
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as { machine_id: string }).machine_id, MACHINE);
  });

  it("un código es de un solo uso", async (t) => {
    const h = new Harness(t);
    const { code } = await h.createCode("viewer");
    assert.equal((await h.redeem(code)).status, 200);
    const again = await h.redeem(code);
    assert.equal(again.status, 410);
    assert.equal(((await again.json()) as { code: string }).code, "gone");
  });

  it("un código caducado da 410 y uno desconocido 401", async (t) => {
    const h = new Harness(t);
    const { code } = await h.createCode("viewer", { ttl_s: 60 });
    h.now += 60_000;
    const expired = await h.redeem(code);
    assert.equal(expired.status, 410);
    const unknown = await h.redeem("ZZZZ-ZZZZ");
    assert.equal(unknown.status, 401);
  });

  it("un código invalidado por el operador ya no se canjea", async (t) => {
    const h = new Harness(t);
    const { id, code } = await h.createCode("viewer");
    assert.equal((await h.request("DELETE", `/v1/pair/codes/${id}`, { token: OPERATOR })).status, 204);
    assert.equal((await h.redeem(code)).status, 410);
  });

  it("cinco fallos por IP en un minuto dan 429", async (t) => {
    const h = new Harness(t);
    const { code } = await h.createCode("viewer");
    for (let i = 0; i < 5; i++) assert.equal((await h.redeem("ZZZZ-ZZZZ")).status, 401);
    const blocked = await h.redeem(code);
    assert.equal(blocked.status, 429);
    assert.ok(Number(blocked.headers.get("Retry-After")) > 0);
    h.now += 60_001;
    assert.equal((await h.redeem(code)).status, 200);
  });

  it("rechaza campos desconocidos y ttl_s fuera de rango", async (t) => {
    const h = new Harness(t);
    assert.equal((await h.request("POST", "/v1/pair/codes", { token: OPERATOR, body: { scope: "viewer", ttl_s: 3601 } })).status, 400);
    assert.equal((await h.request("POST", "/v1/pair/codes", { token: OPERATOR, body: { scope: "viewer", extra: 1 } })).status, 400);
    const { code } = await h.createCode("viewer");
    assert.equal((await h.redeem(code, { token: "x" })).status, 400);
  });

  it("volver a emparejar la misma máquina revoca el token agent anterior", async (t) => {
    const h = new Harness(t);
    const first = await h.pair("agent");
    await h.pair("agent");
    assert.equal((await h.request("GET", "/whoami", { token: first.token })).status, 401);
  });
});

describe("revocación", () => {
  it("revocar el token agent cierra su WebSocket y el token deja de valer", async (t) => {
    const h = new Harness(t);
    const { ws, tokenId, token } = await h.agent();
    const res = await h.request("DELETE", `/v1/tokens/${tokenId}`, { token: OPERATOR });
    assert.equal(res.status, 204);
    assert.deepEqual(ws.closed, { code: 4401, reason: "unauthorized" });
    const last = ws.frames().at(-1)!;
    assert.equal(last.type, "error");
    assert.equal(last.code, "unauthorized");
    assert.equal(last.close, true);
    assert.equal((await h.request("GET", "/v1/connect", { token, headers: { Upgrade: "websocket" } })).status, 401);
  });

  it("revocar el token viewer cierra su SSE y no toca otros visores", async (t) => {
    const h = new Harness(t);
    const a = await h.pair("viewer");
    const b = await h.pair("viewer");
    const streamA = await h.request("GET", "/stream", { token: a.token });
    const streamB = await h.request("GET", "/stream", { token: b.token });
    assert.equal(streamA.headers.get("Content-Type"), "text/event-stream; charset=utf-8");
    assert.equal((await readSse(streamA, (s) => s.includes("event: hello"))).done, false);
    assert.equal(h.hub.viewers.active, 2);
    assert.equal((await h.request("DELETE", `/v1/tokens/${a.token_id}`, { token: OPERATOR })).status, 204);
    const rest = await readSse(streamA, () => false);
    assert.equal(rest.done, true);
    assert.match(rest.text, /event: error\ndata: .*"code":"unauthorized".*"close":true/);
    assert.equal(h.hub.viewers.active, 1);
    assert.equal((await h.request("GET", "/stream", { token: a.token })).status, 401);
    assert.equal((await readSse(streamB, (s) => s.includes("event: hello"))).done, false);
  });

  it("revocar un token de otro id da 404 y no cierra nada", async (t) => {
    const h = new Harness(t);
    const { ws } = await h.agent();
    assert.equal((await h.request("DELETE", "/v1/tokens/tk-00000000", { token: OPERATOR })).status, 404);
    assert.equal(ws.closed, null);
  });
});

describe("cuotas", () => {
  it("snapshot: uno cada 5 s por conexión", async (t) => {
    const h = new Harness(t);
    const { ws } = await h.agent();
    const publish = t.mock.method(h.hub.viewers, "publish");
    assert.equal(await h.send(ws, snapshot(1)), undefined);
    h.now += 4_999;
    const limited = await h.send(ws, snapshot(2));
    assert.equal(limited?.code, "rate_limited");
    assert.equal(limited?.retry_after_s, 1);
    h.now += 1;
    assert.equal(await h.send(ws, snapshot(3)), undefined);
    assert.equal(publish.mock.callCount(), 2);
    const state = (await (await h.request("GET", "/state", { token: (await h.pair("viewer")).token })).json()) as {
      machines: { seq: number }[];
    };
    assert.equal(state.machines[0]?.seq, 3);
  });

  it("evento: 50 por segundo", async (t) => {
    const h = new Harness(t);
    const { ws } = await h.agent();
    const publish = t.mock.method(h.hub.viewers, "publish");
    for (let i = 0; i < 50; i++) assert.equal(await h.send(ws, event(i)), undefined);
    const limited = await h.send(ws, event(50));
    assert.equal(limited?.code, "rate_limited");
    assert.equal(limited?.retry_after_s, 1);
    assert.equal(publish.mock.callCount(), 50);
    h.now += 1_000;
    assert.equal(await h.send(ws, event(51)), undefined);
    assert.equal(publish.mock.callCount(), 51);
  });

  it("sin hello no se aceptan snapshots ni eventos", async (t) => {
    const h = new Harness(t);
    const ws = await h.connect((await h.pair("agent")).token);
    assert.equal((await h.send(ws, snapshot(1)))?.code, "bad_request");
    assert.equal((await h.send(ws, event(1)))?.code, "bad_request");
  });
});

describe("lista blanca", () => {
  it("los fixtures de snapshot y evento pasan y llegan intactos al visor", async (t) => {
    const h = new Harness(t);
    const viewer = await h.pair("viewer");
    const stream = await h.request("GET", "/stream", { token: viewer.token });
    await readSse(stream, (s) => s.includes("event: hello"));
    const { ws } = await h.agent();
    const snap = snapshot(7);
    const ev = event(8);
    assert.equal(await h.send(ws, snap), undefined);
    assert.equal(await h.send(ws, ev), undefined);
    const { text } = await readSse(stream, (s) => s.includes("event: event"));
    assert.ok(text.includes(`event: snapshot\nid: `));
    assert.ok(text.includes(`data: ${JSON.stringify(snap)}\n\n`));
    assert.ok(text.includes(`data: ${JSON.stringify(ev)}\n\n`));
    const state = (await (await h.request("GET", "/state", { token: viewer.token })).json()) as Record<string, unknown> & {
      machines: Record<string, unknown>[];
      snapshots: unknown[];
    };
    assert.deepEqual(Object.keys(state).sort(), ["head", "id", "machines", "snapshots", "ts", "type", "v"]);
    assert.deepEqual(Object.keys(state.machines[0]!).sort(), ["expires_at", "machine_id", "online", "seq", "snapshot_age_s", "stale"]);
    assert.deepEqual(
      { machine_id: state.machines[0]!.machine_id, online: state.machines[0]!.online, stale: state.machines[0]!.stale, seq: state.machines[0]!.seq },
      { machine_id: MACHINE, online: true, stale: false, seq: 7 },
    );
    assert.deepEqual(state.snapshots, [snap]);
  });

  for (const field of ["worktree", "cwd", "token", "title", "prompt"]) {
    it(`rechaza un snapshot con el campo ${field} fuera de la lista`, async (t) => {
      const h = new Harness(t);
      const { ws } = await h.agent();
      const publish = t.mock.method(h.hub.viewers, "publish");
      const reply = await h.send(ws, snapshot(1, { [field]: "x" }));
      assert.equal(reply?.code, "bad_request");
      assert.equal(publish.mock.callCount(), 0);
      const state = (await (await h.request("GET", "/state", { token: (await h.pair("viewer")).token })).json()) as { snapshots: unknown[] };
      assert.deepEqual(state.snapshots, []);
    });

    it(`rechaza un evento con el campo ${field} fuera de la lista`, async (t) => {
      const h = new Harness(t);
      const { ws } = await h.agent();
      const publish = t.mock.method(h.hub.viewers, "publish");
      assert.equal((await h.send(ws, event(1, { [field]: "x" })))?.code, "bad_request");
      assert.equal(publish.mock.callCount(), 0);
    });
  }

  it("un evento no puede traer parts ni un snapshot body", async (t) => {
    const h = new Harness(t);
    const { ws } = await h.agent();
    assert.equal((await h.send(ws, event(1, { parts: [] })))?.code, "bad_request");
    assert.equal((await h.send(ws, snapshot(2, { body: {} })))?.code, "bad_request");
  });

  it("un snapshot con machine_id ajeno se rechaza", async (t) => {
    const h = new Harness(t);
    const { ws } = await h.agent();
    assert.equal((await h.send(ws, snapshot(1, { machine_id: "otra" })))?.code, "forbidden");
  });
});
