export type SqlValue = string | number | null;

const IDENT = /^[a-z_][a-z0-9_]*$/;

export function now(): string {
  return new Date(Date.now()).toISOString();
}

export function uuid(): string {
  return crypto.randomUUID();
}

export async function batch(db: D1Database, stmts: D1PreparedStatement[]): Promise<D1Result[]> {
  if (stmts.length === 0) return [];
  return db.batch(stmts);
}

export async function one<T>(db: D1Database, sql: string, ...params: SqlValue[]): Promise<T | null> {
  return db.prepare(sql).bind(...params).first<T>();
}

export async function all<T>(db: D1Database, sql: string, ...params: SqlValue[]): Promise<T[]> {
  const res = await db.prepare(sql).bind(...params).all<T>();
  return res.results;
}

export async function run(db: D1Database, sql: string, ...params: SqlValue[]): Promise<number> {
  const res = await db.prepare(sql).bind(...params).run();
  return res.meta.changes;
}

function ident(name: string): string {
  if (!IDENT.test(name)) throw new Error(`invalid identifier: ${name}`);
  return name;
}

export function casUpdate(
  db: D1Database,
  table: string,
  id: string,
  rev: number,
  fields: Record<string, SqlValue>,
  idColumn = "id",
): D1PreparedStatement {
  const cols = Object.keys(fields).map((c) => `${ident(c)} = ?`);
  const sql = `UPDATE ${ident(table)} SET ${[...cols, "rev = rev + 1"].join(", ")} WHERE ${ident(idColumn)} = ? AND rev = ?`;
  return db.prepare(sql).bind(...Object.values(fields), id, rev);
}

export async function casRun(
  db: D1Database,
  table: string,
  id: string,
  rev: number,
  fields: Record<string, SqlValue>,
  idColumn = "id",
): Promise<boolean> {
  const res = await casUpdate(db, table, id, rev, fields, idColumn).run();
  return res.meta.changes === 1;
}

export function isConstraintError(err: unknown, kind?: "UNIQUE" | "CHECK" | "FOREIGN KEY" | "NOT NULL"): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return msg.includes("constraint failed") && (kind === undefined || msg.includes(kind));
}

export function splitStatements(sql: string): string[] {
  return sql
    .split(/;[ \t]*(?:\r?\n|$)/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export async function applyMigrations(db: D1Database, migrations: string[]): Promise<void> {
  for (const sql of migrations) {
    await batch(db, splitStatements(sql).map((s) => db.prepare(s)));
  }
}
