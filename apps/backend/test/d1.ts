import { DatabaseSync, type SQLInputValue, type StatementSync } from "node:sqlite";

type Row = Record<string, unknown>;

interface Meta {
  duration: number;
  changes: number;
  last_row_id: number;
  rows_read: number;
  rows_written: number;
  changed_db: boolean;
}

export interface FakeD1Result<T = Row> {
  results: T[];
  success: true;
  meta: Meta;
}

function toInput(value: unknown): SQLInputValue {
  if (value === undefined) throw new TypeError("D1_TYPE_ERROR: undefined no es un valor válido");
  if (typeof value === "boolean") return value ? 1 : 0;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  return value as SQLInputValue;
}

function meta(changes = 0, lastRowId = 0, read = 0): Meta {
  return { duration: 0, changes, last_row_id: lastRowId, rows_read: read, rows_written: changes, changed_db: changes > 0 };
}

export class FakeD1PreparedStatement {
  constructor(
    private readonly d1: FakeD1Database,
    readonly query: string,
    readonly params: SQLInputValue[] = [],
  ) {}

  bind(...values: unknown[]): FakeD1PreparedStatement {
    return new FakeD1PreparedStatement(this.d1, this.query, values.map(toInput));
  }

  private stmt(): StatementSync {
    return this.d1.db.prepare(this.query);
  }

  private returnsRows(stmt: StatementSync): boolean {
    return stmt.columns().length > 0;
  }

  async first<T = Row>(column?: string): Promise<T | null> {
    const row = this.stmt().get(...this.params) as Row | undefined;
    if (!row) return null;
    if (column === undefined) return { ...row } as T;
    if (!(column in row)) throw new Error(`D1_COLUMN_NOTFOUND: ${column}`);
    return row[column] as T;
  }

  async all<T = Row>(): Promise<FakeD1Result<T>> {
    return this.execute<T>();
  }

  async run<T = Row>(): Promise<FakeD1Result<T>> {
    return this.execute<T>();
  }

  async raw<T = unknown[]>(options?: { columnNames?: boolean }): Promise<T[]> {
    const stmt = this.stmt();
    const names = stmt.columns().map((c) => c.name);
    const rows = (stmt.all(...this.params) as Row[]).map((r) => names.map((n) => r[n]));
    return (options?.columnNames ? [names, ...rows] : rows) as T[];
  }

  execute<T>(): FakeD1Result<T> {
    const stmt = this.stmt();
    if (this.returnsRows(stmt)) {
      const results = (stmt.all(...this.params) as Row[]).map((r) => ({ ...r })) as T[];
      return { results, success: true, meta: meta(0, 0, results.length) };
    }
    const out = stmt.run(...this.params);
    return { results: [], success: true, meta: meta(Number(out.changes), Number(out.lastInsertRowid)) };
  }
}

export class FakeD1Database {
  readonly db = new DatabaseSync(":memory:");

  constructor() {
    this.db.exec("PRAGMA foreign_keys = ON");
  }

  prepare(query: string): FakeD1PreparedStatement {
    return new FakeD1PreparedStatement(this, query);
  }

  async batch<T = Row>(statements: FakeD1PreparedStatement[]): Promise<FakeD1Result<T>[]> {
    this.db.exec("BEGIN");
    try {
      const out = statements.map((s) => s.execute<T>());
      this.db.exec("COMMIT");
      return out;
    } catch (err) {
      this.db.exec("ROLLBACK");
      throw err;
    }
  }

  async exec(query: string): Promise<{ count: number; duration: number }> {
    const count = query.split(";").filter((q) => q.trim()).length;
    this.db.exec(query);
    return { count, duration: 0 };
  }

  asD1(): D1Database {
    return this as unknown as D1Database;
  }
}
