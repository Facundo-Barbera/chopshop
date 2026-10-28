import test from "node:test";
import assert from "node:assert/strict";
import { ChopshopClient } from "../src/index.js";

test("snapshot usa GET /snapshot con bearer", async () => {
  let seen;
  const c = new ChopshopClient({ baseUrl: "http://x:1/", token: "t", fetchImpl: async (u, o) => { seen = [u, o]; return { ok: true, json: async () => ({ api_version: 1 }) }; } });
  assert.equal((await c.snapshot()).api_version, 1);
  assert.equal(seen[0], "http://x:1/snapshot");
  assert.equal(seen[1].headers.Authorization, "Bearer t");
});
test("errores HTTP lanzan con status", async () => {
  const c = new ChopshopClient({ baseUrl: "http://x", fetchImpl: async () => ({ ok: false, status: 403, json: async () => ({ error: "no" }) }) });
  await assert.rejects(c.health(), (e) => e.status === 403 && e.message === "no");
});
