import { now, uuid } from "./db";

export type AuditResult = "ok" | "denied" | "error" | "timeout";

export interface AuditEntry {
  actorKind: "user" | "operator" | "machine" | "system";
  action: string;
  actorUserId?: string | null;
  sessionId?: string | null;
  machineId?: string | null;
  targetKind?: string | null;
  targetId?: string | null;
  command?: string | null;
  result?: AuditResult;
  status?: number | null;
  detail?: Record<string, unknown>;
}

export async function audit(db: D1Database, entry: AuditEntry): Promise<string> {
  const id = uuid();
  await db
    .prepare(
      `INSERT INTO audit_log (id, at, actor_kind, actor_user_id, session_id, machine_id, action, target_kind, target_id, command, result, status, detail)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      id,
      now(),
      entry.actorKind,
      entry.actorUserId ?? null,
      entry.sessionId ?? null,
      entry.machineId ?? null,
      entry.action,
      entry.targetKind ?? null,
      entry.targetId ?? null,
      entry.command ?? null,
      entry.result ?? "ok",
      entry.status ?? null,
      JSON.stringify(entry.detail ?? {}),
    )
    .run();
  return id;
}

export async function finishAudit(db: D1Database, id: string, result: AuditResult, status: number | null): Promise<void> {
  await db.prepare("UPDATE audit_log SET result = ?, status = ? WHERE id = ?").bind(result, status, id).run();
}
