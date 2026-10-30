import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { ApiError, apiBase, createClient, errorText, inviteToken, takeInviteToken } from "../src/api.js";

const T = "ci1_" + "A".repeat(20) + "b-_" + "9".repeat(20);

function fakeFetch(responses = []) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: init.body === undefined ? undefined : JSON.parse(init.body) });
    const r = responses.shift() ?? { status: 200, body: {} };
    return { status: r.status, ok: r.status >= 200 && r.status < 300, json: async () => r.body };
  };
  fn.calls = calls;
  return fn;
}

test("extrae t del fragmento", () => {
  assert.equal(inviteToken(`#t=${T}`), T);
  assert.equal(inviteToken(`t=${T}`), T);
  assert.equal(inviteToken(`#x=1&t=${T}`), T);
  assert.equal(inviteToken(""), null);
  assert.equal(inviteToken(undefined), null);
  assert.equal(inviteToken("#t=ci1_corto"), null);
  assert.equal(inviteToken(`#t=ss1_${T.slice(4)}`), null);
});

test("quita el fragmento de la barra de direcciones al leerlo", () => {
  const calls = [];
  const history = { replaceState: (...a) => calls.push(a) };
  assert.equal(takeInviteToken({ hash: `#t=${T}`, pathname: "/invite", search: "" }, history), T);
  assert.deepEqual(calls, [[null, "", "/invite"]]);
  assert.equal(takeInviteToken({ hash: "#t=malo", pathname: "/invite", search: "" }, history), null);
  assert.equal(calls.length, 2);
  assert.equal(takeInviteToken({ hash: "", pathname: "/invite", search: "" }, history), null);
  assert.equal(calls.length, 2);
});

test("la API vive en el subdominio api del host web", () => {
  assert.equal(apiBase({ protocol: "https:", host: "chopshop.novarix.online" }), "https://api.chopshop.novarix.online");
});

test("inspect y accept mandan el token solo en el cuerpo, nunca en la URL", async () => {
  const f = fakeFetch([
    { status: 200, body: { email: "ana@chopshop.test", kind: "watcher", role: "watcher", expires_at: "x", workspaces: [] } },
    { status: 201, body: { user: { id: "u" }, session: { id: "s", client: "web" }, csrf_token: "cx1_x" } },
  ]);
  const c = createClient({ base: "https://api.chopshop.novarix.online", fetch: f });
  await c.inspect(T);
  await c.accept({ token: T, password: "correct horse battery", display_name: "" });
  assert.equal(f.calls[0].url, "https://api.chopshop.novarix.online/v1/invitations/inspect");
  assert.equal(f.calls[1].url, "https://api.chopshop.novarix.online/v1/invitations/accept");
  for (const call of f.calls) {
    assert.ok(!call.url.includes(T));
    assert.ok(!call.url.includes("?") && !call.url.includes("#"));
    assert.equal(call.init.method, "POST");
    assert.equal(call.init.credentials, "include");
    assert.equal(call.body.token, T);
  }
  assert.deepEqual(f.calls[1].body, { token: T, password: "correct horse battery", device_name: "Navegador", client: "web" });
});

test("login como web y logout con el token CSRF recibido", async () => {
  const f = fakeFetch([
    { status: 200, body: { user: { id: "u" }, session: { id: "s", client: "web" }, csrf_token: "cx1_abc" } },
    { status: 204 },
  ]);
  const c = createClient({ base: "https://api", fetch: f });
  await c.login({ email: "a@b.test", password: "p" });
  assert.equal(f.calls[0].body.client, "web");
  assert.equal(f.calls[0].init.headers["X-CSRF-Token"], undefined);
  await c.logout();
  assert.equal(f.calls[1].url, "https://api/v1/auth/logout");
  assert.equal(f.calls[1].init.headers["X-CSRF-Token"], "cx1_abc");
});

test("los errores de la API llegan como ApiError con texto legible", async () => {
  const f = fakeFetch([{ status: 429, body: { code: "rate_limited", message: "m", retry_after_s: 30 } }, { status: 410, body: { code: "gone", message: "g" } }]);
  const c = createClient({ base: "https://api", fetch: f });
  const e1 = await c.login({ email: "a", password: "b" }).catch((e) => e);
  assert.ok(e1 instanceof ApiError);
  assert.equal(e1.status, 429);
  assert.match(errorText(e1), /30 s/);
  const e2 = await c.inspect(T).catch((e) => e);
  assert.equal(e2.code, "gone");
  assert.match(errorText(e2), /invitación/);
  assert.match(errorText(new TypeError("x")), /conectar/);
});

test("el HTML no tiene scripts ni estilos en línea (CSP script-src/style-src 'self')", () => {
  const html = readFileSync(new URL("../src/index.html", import.meta.url), "utf8");
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/);
  assert.doesNotMatch(html, /<style|\bstyle=|\bon[a-z]+=/i);
});
