export interface MachineStats { cpus: number; load: number[]; cpu_pct: number; ram_total_mb: number; ram_avail_mb: number; ram_pct: number;
  swap_used_mb: number; disk_used_gb: number; disk_total_gb: number; disk_pct: number; os: string; uptime: number }
export interface Group { name: string; cpu_pct: number; rss_mb: number; procs: number }
export interface AppGroup extends Group { cgroups?: string[] }
export interface ProjectGroup extends Group { threads_running: number; threads_pending: number }
export interface Thread { thread_id: string; project: string | null; title: string; status: string; settled: boolean; pending: unknown[]; worktree?: string; updated: number }
export interface AgentEvent { seq: number; ts: number; machine_id: string; event: string; project?: string; body: Record<string, unknown> }
export interface Snapshot {
  api_version: number; machine_id: string; ts: number; generated: string;
  machine: MachineStats; apps: AppGroup[]; projects: ProjectGroup[]; threads: Thread[];
  pending_questions: { thread_id: string; project?: string; request_id: string; questions: unknown[] }[];
  events: AgentEvent[]; subscriptions: Record<string, { project: string; events: string[] }>;
  orchestrator: unknown | null;
  agent: { version: string; uptime: number; t3_ok: boolean; last_sample_age: number; last_poll_age: number };
}

export type AgentStatus = "ok" | "unreachable" | "forbidden" | "unauthorized" | "incompatible" | "error";
export interface AgentResult { name: string; status?: AgentStatus; error?: string; snapshot?: Snapshot | null }
export interface AgentRow { name: string; label: string; status: AgentStatus; error: string; message: string; stale: boolean; age: number; info: Snapshot["agent"] | null; warning: string }
export interface MachineView {
  name: string; agent: string; ok: boolean; stale: boolean; reason: string; os: string; cpus: number; load: number[];
  ramTotalMB: number; ramAvailMB: number; swapUsedMB: number; disk: string; diskPct: number; uptime: number;
  cpu: number[]; ram: number[]; load1: number[]; run: number[];
  apps: AppGroup[]; projects: ProjectGroup[];
}
export interface View { hasData: boolean; state: Record<string, unknown>; machines: MachineView[]; agents: AgentRow[] }
export interface Store { history: unknown; update(results: AgentResult[]): View }
export function parseTs(ts: unknown): Date | null;
export function createStore(opts?: { historyLen?: number; now?: () => number }): Store;
