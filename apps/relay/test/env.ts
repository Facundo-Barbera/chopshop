import { DatabaseSync } from "node:sqlite";

export class FakeWebSocket {
  sent: string[] = [];
  closed: { code: number; reason: string } | null = null;
  private attachment: unknown = null;

  send(data: string): void {
    if (this.closed) throw new Error("closed");
    this.sent.push(data);
  }

  close(code: number, reason: string): void {
    this.closed ??= { code, reason };
  }

  serializeAttachment(value: unknown): void {
    this.attachment = structuredClone(value);
  }

  deserializeAttachment(): unknown {
    return structuredClone(this.attachment);
  }

  frames(): Record<string, unknown>[] {
    return this.sent.map((s) => JSON.parse(s) as Record<string, unknown>);
  }
}

class WebSocketPair {
  0: FakeWebSocket;
  1: FakeWebSocket;

  constructor() {
    this[0] = new FakeWebSocket();
    this[1] = new FakeWebSocket();
  }
}

class WebSocketRequestResponsePair {
  constructor(
    readonly request: string,
    readonly response: string,
  ) {}
}

const NodeResponse = globalThis.Response;

class WorkerResponse extends NodeResponse {
  readonly webSocket: FakeWebSocket | null;
  private readonly upgraded: boolean;

  constructor(body?: BodyInit | null, init?: ResponseInit & { webSocket?: FakeWebSocket }) {
    const upgraded = init?.status === 101;
    super(body, upgraded ? { ...init, status: 200 } : init);
    this.upgraded = upgraded;
    this.webSocket = init?.webSocket ?? null;
  }

  static [Symbol.hasInstance](value: unknown): boolean {
    return value instanceof NodeResponse;
  }

  override get status(): number {
    return this.upgraded ? 101 : super.status;
  }
}

Object.assign(globalThis, { WebSocketPair, WebSocketRequestResponsePair, Response: WorkerResponse });

export class FakeSql {
  readonly db = new DatabaseSync(":memory:");

  exec<T = Record<string, unknown>>(query: string, ...params: unknown[]): { toArray(): T[]; rowsWritten: number } {
    if (params.length === 0 && query.trim().replace(/;$/, "").includes(";")) {
      this.db.exec(query);
      return { toArray: () => [], rowsWritten: 0 };
    }
    const stmt = this.db.prepare(query);
    const args = params as (string | number | null)[];
    if (/^\s*(SELECT|WITH)\b/i.test(query)) {
      const rows = stmt.all(...args) as T[];
      return { toArray: () => rows, rowsWritten: 0 };
    }
    const result = stmt.run(...args);
    return { toArray: () => [], rowsWritten: Number(result.changes) };
  }
}

export class FakeStorage {
  readonly sql = new FakeSql();
  alarm: number | null = null;

  transactionSync<T>(fn: () => T): T {
    this.sql.db.exec("BEGIN");
    try {
      const out = fn();
      this.sql.db.exec("COMMIT");
      return out;
    } catch (err) {
      this.sql.db.exec("ROLLBACK");
      throw err;
    }
  }

  async getAlarm(): Promise<number | null> {
    return this.alarm;
  }

  async setAlarm(at: number): Promise<void> {
    this.alarm = at;
  }
}

export class FakeState {
  readonly id = { toString: () => "hub-test" };
  readonly storage = new FakeStorage();
  readonly sockets = new Map<FakeWebSocket, string[]>();

  setWebSocketAutoResponse(): void {}

  acceptWebSocket(ws: FakeWebSocket, tags: string[]): void {
    this.sockets.set(ws, tags);
  }

  getWebSockets(tag?: string): FakeWebSocket[] {
    return [...this.sockets].filter(([ws, tags]) => !ws.closed && (tag === undefined || tags.includes(tag))).map(([ws]) => ws);
  }

  getTags(ws: FakeWebSocket): string[] {
    return this.sockets.get(ws) ?? [];
  }

  getWebSocketAutoResponseTimestamp(): Date | null {
    return null;
  }
}
