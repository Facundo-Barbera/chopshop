import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { applyMigrations, batch, casRun, isConstraintError, now, one, run, splitStatements, uuid, type SqlValue } from "../src/db.ts";
import { FakeD1Database } from "./d1.ts";

const DIR = new URL("../migrations/", import.meta.url);

function migrations(): string[] {
  return readdirSync(DIR)
    .filter((f) => /^\d{4}_.+\.sql$/.test(f))
    .sort()
    .map((f) => readFileSync(new URL(f, DIR), "utf8"));
}

async function fresh(): Promise<D1Database> {
  const db = new FakeD1Database().asD1();
  await applyMigrations(db, migrations());
  return db;
}

async function addUser(db: D1Database, email: string, role: "owner" | "watcher"): Promise<string> {
  const id = uuid();
  const t = now();
  await run(
    db,
    "INSERT INTO users (id, email, email_normalized, password_hash, role, password_changed_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    id,
    email,
    email.trim().toLowerCase(),
    "pbkdf2$x",
    role,
    t,
    t,
    t,
  );
  return id;
}

async function get(db: D1Database, sql: string, ...params: SqlValue[]): Promise<Record<string, unknown> | null> {
  const row = await one<Record<string, unknown>>(db, sql, ...params);
  return row && { ...row };
}

async function rejects(p: Promise<unknown>, kind: "UNIQUE" | "CHECK" | "FOREIGN KEY"): Promise<void> {
  await assert.rejects(p, (err: unknown) => isConstraintError(err, kind));
}

describe("migraciones", () => {
  it("son 0001 a 0003 y aplican en el doble de D1", async () => {
    assert.deepEqual(
      readdirSync(DIR).filter((f) => f.endsWith(".sql")).sort(),
      ["0001_identity.sql", "0002_machines.sql", "0003_structure.sql"],
    );
    const db = await fresh();
    const tables = await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all<{ name: string }>();
    assert.deepEqual(
      tables.results.map((r) => r.name).filter((n) => !n.startsWith("sqlite_") && !n.startsWith("_cf_")),
      [
        "audit_log",
        "auth_attempts",
        "campus_layouts",
        "import_offers",
        "invitation_workspaces",
        "invitations",
        "machines",
        "meta",
        "project_layouts",
        "projects",
        "roles",
        "sessions",
        "users",
        "workspace_machines",
        "workspace_members",
        "workspaces",
      ],
    );
    assert.deepEqual(await get(db, "SELECT value FROM meta WHERE key = ?", "structure_rev"), { value: "0" });
  });

  it("son portables: sin AUTOINCREMENT, fechas de SQLite ni STRICT", () => {
    for (const sql of migrations()) {
      assert.doesNotMatch(sql, /AUTOINCREMENT|datetime\(|CURRENT_TIMESTAMP|STRICT|WITHOUT ROWID|json_/i);
    }
  });

  it("separa sentencias por punto y coma al final de línea", () => {
    assert.deepEqual(splitStatements("CREATE TABLE a (x TEXT);\n\nCREATE INDEX i ON a (x);"), [
      "CREATE TABLE a (x TEXT)",
      "CREATE INDEX i ON a (x)",
    ]);
  });
});

describe("restricciones", () => {
  it("dos owner falla", async () => {
    const db = await fresh();
    await addUser(db, "dueno@example.test", "owner");
    await addUser(db, "watcher1@example.test", "watcher");
    await addUser(db, "watcher2@example.test", "watcher");
    await rejects(addUser(db, "otro@example.test", "owner"), "UNIQUE");
  });

  it("email duplicado falla", async () => {
    const db = await fresh();
    await addUser(db, "Ana@Example.test", "owner");
    await rejects(addUser(db, "ana@example.test ", "watcher"), "UNIQUE");
  });

  it("rol y estado fuera del CHECK fallan", async () => {
    const db = await fresh();
    await rejects(addUser(db, "x@example.test", "admin" as "owner"), "CHECK");
    const id = await addUser(db, "y@example.test", "watcher");
    await rejects(run(db, "UPDATE users SET status = ? WHERE id = ?", "1", id), "CHECK");
  });

  it("claves foráneas activas", async () => {
    const db = await fresh();
    const t = now();
    await rejects(
      run(db, "INSERT INTO workspaces (id, owner_id, name, slug, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)", uuid(), uuid(), "A", "a", t, t),
      "FOREIGN KEY",
    );
  });
});

describe("db.ts", () => {
  it("now() es ISO UTC con milisegundos y uuid() es v4 en minúsculas", () => {
    assert.match(now(), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    assert.match(uuid(), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  it("rev CAS: solo la revisión actual actualiza y la sube", async () => {
    const db = await fresh();
    const owner = await addUser(db, "dueno@example.test", "owner");
    const ws = uuid();
    const t = now();
    await run(db, "INSERT INTO workspaces (id, owner_id, name, slug, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)", ws, owner, "Acme", "acme", t, t);
    assert.equal(await casRun(db, "workspaces", ws, 1, { name: "Acme 2", updated_at: now() }), true);
    assert.equal(await casRun(db, "workspaces", ws, 1, { name: "Acme 3", updated_at: now() }), false);
    assert.deepEqual(await get(db, "SELECT name, rev FROM workspaces WHERE id = ?", ws), { name: "Acme 2", rev: 2 });
    assert.equal(await casRun(db, "workspaces", ws, 2, { name: "Acme 3" }), true);
    assert.deepEqual(await get(db, "SELECT name, rev FROM workspaces WHERE id = ?", ws), { name: "Acme 3", rev: 3 });
    await run(db, "INSERT INTO campus_layouts (workspace_id, updated_at) VALUES (?, ?)", ws, t);
    assert.equal(await casRun(db, "campus_layouts", ws, 1, { layout: "{\"x\":1}" }, "workspace_id"), true);
    assert.equal(await casRun(db, "campus_layouts", ws, 1, { layout: "{}" }, "workspace_id"), false);
    await assert.rejects(casRun(db, "workspaces; DROP TABLE users", ws, 1, { name: "x" }), /invalid identifier/);
  });

  it("batch es atómico", async () => {
    const db = await fresh();
    const owner = await addUser(db, "dueno@example.test", "owner");
    const t = now();
    const ins = (slug: string) =>
      db.prepare("INSERT INTO workspaces (id, owner_id, name, slug, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)").bind(uuid(), owner, slug, slug, t, t);
    await rejects(batch(db, [ins("a"), db.prepare("UPDATE meta SET value = value + 1 WHERE key = 'structure_rev'"), ins("a")]), "UNIQUE");
    assert.deepEqual(await get(db, "SELECT count(*) AS n FROM workspaces"), { n: 0 });
    assert.deepEqual(await get(db, "SELECT value FROM meta WHERE key = 'structure_rev'"), { value: "0" });
    assert.deepEqual(await batch(db, []), []);
  });
});
