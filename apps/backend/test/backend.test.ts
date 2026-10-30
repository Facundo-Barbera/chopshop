import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { FakeD1Database } from "./d1.ts";
import worker, { VERSION, type Env } from "../src/index.ts";

function env(): Env {
  return { DB: new FakeD1Database().asD1(), API_ORIGIN: "https://api.chopshop.test" };
}

async function call(path: string, method = "GET"): Promise<Response> {
  return worker.fetch(new Request(`https://api.chopshop.test${path}`, { method }), env());
}

describe("health", () => {
  it("responde ok y la versión", async () => {
    const res = await call("/health");
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /^application\/json/);
    assert.deepEqual(await res.json(), { ok: true, version: VERSION });
  });

  it("otras rutas dan 404 y otros métodos 405", async () => {
    assert.equal((await call("/nada")).status, 404);
    assert.equal((await call("/health", "POST")).status, 405);
  });
});

describe("doble de D1", () => {
  async function seeded(): Promise<FakeD1Database> {
    const d1 = new FakeD1Database();
    await d1.exec("CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, n INTEGER NOT NULL DEFAULT 0);");
    return d1;
  }

  it("prepare/bind/run/first/all", async () => {
    const d1 = await seeded();
    const ins = await d1.prepare("INSERT INTO users (id, email) VALUES (?1, ?2)").bind("u1", "a@x.test").run();
    assert.equal(ins.success, true);
    assert.equal(ins.meta.changes, 1);
    await d1.prepare("INSERT INTO users (id, email, n) VALUES (?, ?, ?)").bind("u2", "b@x.test", true).run();
    assert.deepEqual(await d1.prepare("SELECT id, n FROM users WHERE id = ?").bind("u2").first(), { id: "u2", n: 1 });
    assert.equal(await d1.prepare("SELECT email FROM users WHERE id = ?").bind("u1").first("email"), "a@x.test");
    assert.equal(await d1.prepare("SELECT id FROM users WHERE id = ?").bind("zz").first(), null);
    const all = await d1.prepare("SELECT id FROM users ORDER BY id").all<{ id: string }>();
    assert.deepEqual(all.results.map((r) => r.id), ["u1", "u2"]);
    assert.deepEqual(await d1.prepare("SELECT id FROM users ORDER BY id").raw(), [["u1"], ["u2"]]);
    assert.throws(() => d1.prepare("SELECT id FROM users WHERE id = ?").bind(undefined), /D1_TYPE_ERROR/);
  });

  it("bind no muta la sentencia original", async () => {
    const d1 = await seeded();
    const base = d1.prepare("INSERT INTO users (id, email) VALUES (?, ?)");
    await base.bind("u1", "a@x.test").run();
    await base.bind("u2", "b@x.test").run();
    assert.equal(await d1.prepare("SELECT count(*) AS c FROM users").first("c"), 2);
  });

  it("batch es atómico", async () => {
    const d1 = await seeded();
    const ins = d1.prepare("INSERT INTO users (id, email) VALUES (?, ?)");
    const ok = await d1.batch([ins.bind("u1", "a@x.test"), ins.bind("u2", "b@x.test"), d1.prepare("SELECT id FROM users")]);
    assert.equal(ok.length, 3);
    assert.equal(ok[2]?.results.length, 2);
    await assert.rejects(d1.batch([ins.bind("u3", "c@x.test"), ins.bind("u4", "a@x.test")]), /UNIQUE/);
    assert.equal(await d1.prepare("SELECT count(*) AS c FROM users").first("c"), 2);
  });
});
