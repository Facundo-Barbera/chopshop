export const TERMINAL = new Set(["completed", "failed", "rolled_back", "cancelled", "interrupted"]);
export const SUPPORTED_API = 1;
export const HISTORY_LEN = 60;
export const RECENT_DONE_SECONDS = 24 * 3600;
export const MAX_DONE_PER_PROJECT = 30;

const num = (v, d = 0) => (typeof v === "number" && Number.isFinite(v) ? v : d);
const arr = (v) => (Array.isArray(v) ? v : []);

export function parseTs(ts) {
  if (ts == null || ts === "") return null;
  const d = typeof ts === "number" ? new Date(ts * 1000) : new Date(String(ts).replace(/([+-]\d\d)(\d\d)$/, "$1:$2"));
  return Number.isNaN(d.getTime()) ? null : d;
}
const tsMs = (ts) => {
  const d = parseTs(ts);
  return d ? d.getTime() : 0;
};
const isoTs = (ts) => {
  if (typeof ts === "number") return new Date(ts * 1000).toISOString();
  return ts || "";
};

export function statusMessage(status, error) {
  switch (status) {
    case "ok": return "";
    case "unreachable": return "agente no alcanzable" + (error ? ` (${error})` : "");
    case "forbidden": return "acceso denegado (403): tu identidad no está autorizada en el agente";
    case "unauthorized": return "token rechazado (401): revisa el token_file del agente";
    case "incompatible": return error || "versión de la API no compatible";
    default: return error || "error del agente";
  }
}

export function createHistory(len = HISTORY_LEN) {
  const by = new Map();
  const get = (label) => {
    if (!by.has(label)) by.set(label, { cpu: [], ram: [], load1: [], run: [] });
    return by.get(label);
  };
  const clip = (a) => (a.length > len ? a.slice(a.length - len) : a);
  return {
    push(label, s) {
      const h = get(label);
      h.cpu = clip([...h.cpu, num(s.cpu)]);
      h.ram = clip([...h.ram, num(s.ram)]);
      h.load1 = clip([...h.load1, num(s.load1)]);
      h.run = clip([...h.run, num(s.run)]);
    },
    get(label) {
      return by.get(label) || { cpu: [], ram: [], load1: [], run: [] };
    },
    seed(map) {
      for (const [label, h] of Object.entries(map || {})) {
        const cur = get(label);
        for (const k of ["cpu", "ram", "load1", "run"]) if (Array.isArray(h[k])) cur[k] = clip(h[k].map((v) => num(v)));
      }
    },
  };
}

function sampleOf(snap) {
  const m = snap.machine || {};
  const running = arr(snap.projects).reduce((n, p) => n + num(p.threads_running), 0);
  const fallback = arr(snap.threads).filter((t) => t.status === "running").length;
  return { cpu: num(m.cpu_pct), ram: num(m.ram_pct), load1: num(arr(m.load)[0]), run: arr(snap.projects).length ? running : fallback };
}

export function normQuestion(q, requestId = "") {
  if (typeof q === "string") return { request: requestId, summary: q, options: [] };
  q = q || {};
  const opts = arr(q.options).map((o) => (typeof o === "string" ? o : (o && (o.label || o.value)) || "")).filter(Boolean);
  return {
    request: q.request || q.request_id || q.requestId || requestId,
    summary: q.summary || q.question || q.text || q.prompt || q.header || "",
    options: opts,
  };
}

function pendingOf(snap, threadId, thread) {
  const entries = arr(snap.pending_questions).filter((p) => p.thread_id === threadId);
  const questions = entries.flatMap((p) => arr(p.questions).map((q) => normQuestion(q, p.request_id)));
  const total = Math.max(arr(thread && thread.pending).length, questions.length);
  const approvals = Math.max(total - questions.length, 0);
  return questions.length || approvals ? { questions, approvals } : null;
}

function threadTask(snap, th) {
  const done = TERMINAL.has(th.status);
  return {
    id: th.thread_id, title: th.title || th.thread_id, status: "launched", t3status: th.status, done,
    settled: !!th.settled, link: null, threadId: th.thread_id, worktree: th.worktree || null, updated: th.updated,
    pending: done ? null : pendingOf(snap, th.thread_id, th), answered: [], prompt: "", result: null,
  };
}

function syntheticBatches(snap, label, name, known) {
  const now = num(snap.ts, Date.now() / 1000);
  const byProject = new Map();
  for (const th of arr(snap.threads)) {
    if (!th.thread_id || known.has(th.thread_id)) continue;
    const key = th.project || "sin-proyecto";
    if (!byProject.has(key)) byProject.set(key, []);
    byProject.get(key).push(th);
  }
  const out = [];
  for (const [project, list] of byProject) {
    list.sort((a, b) => num(b.updated) - num(a.updated));
    const live = list.filter((t) => !TERMINAL.has(t.status));
    const recent = list.filter((t) => TERMINAL.has(t.status) && now - num(t.updated) <= RECENT_DONE_SECONDS).slice(0, MAX_DONE_PER_PROJECT);
    const picked = [...live, ...recent];
    if (!picked.length) continue;
    out.push({
      id: `${label}/${project}`, project, host: label, machine: label, agent: name, synthetic: true, max_parallel: null, notes: [],
      created: isoTs(Math.min(...picked.map((t) => num(t.updated, now)))), tasks: picked.map((t) => threadTask(snap, t)),
    });
  }
  return out;
}

function agentEvent(e, label, name, batchOfThread) {
  const body = e.body || {};
  const task = body.task || body.thread_id || body.thread || "";
  return {
    ts: isoTs(e.ts), event: e.event, batch: body.batch || batchOfThread.get(task) || e.project || "", task,
    summary: body.summary || body.title || body.message || "", status: body.status, delivery: body.delivery || {},
    project: e.project || "", machine: e.machine_id || label, agent: name, seq: e.seq,
  };
}

export function buildView(rows, history = createHistory()) {
  const state = { generated: "", hosts: {}, profiles: [], subscriptions: {}, inbox: { pending: [], results: [], watcher: null }, batches: [], events: [], graphs: [] };
  const machines = [], agents = [];
  const profiles = new Set();
  const withSnap = rows.filter((r) => r.snapshot);
  const known = new Set();
  for (const r of withSnap) {
    const o = r.snapshot.orchestrator;
    if (o) for (const b of arr(o.batches)) for (const t of arr(b.tasks)) if (t.threadId) known.add(t.threadId);
  }
  const batchOfThread = new Map();
  let t3ok = true;
  for (const r of withSnap) {
    const snap = r.snapshot, label = r.label, o = snap.orchestrator;
    if (snap.agent && snap.agent.t3_ok === false) t3ok = false;
    if (snap.generated && snap.generated > state.generated) state.generated = snap.generated;
    const mine = [];
    if (o) {
      for (const b of arr(o.batches)) mine.push({ ...b, agent: r.name, machine: label });
      for (const g of arr(o.graphs)) state.graphs.push({ ...g, agent: r.name, machine: label });
      Object.assign(state.hosts, o.hosts || {});
      arr(o.profiles).forEach((p) => profiles.add(p));
      Object.assign(state.subscriptions, o.subscriptions || {});
      if (o.inbox) {
        state.inbox.pending.push(...arr(o.inbox.pending).map((i) => ({ ...i, agent: r.name })));
        state.inbox.results.push(...arr(o.inbox.results).map((i) => ({ ...i, agent: r.name })));
      }
    }
    mine.push(...syntheticBatches(snap, label, r.name, known));
    for (const b of mine) for (const t of b.tasks) if (t.threadId) batchOfThread.set(t.threadId, b.id);
    state.batches.push(...mine);
    arr(snap.projects).forEach((p) => profiles.add(p.name));
    Object.assign(state.subscriptions, snap.subscriptions || {});
    if (!state.hosts[label]) state.hosts[label] = { cap: null, purpose: "", transport: "agent" };
  }
  const evs = [];
  for (const r of withSnap) {
    const o = r.snapshot.orchestrator;
    if (o) evs.push(...arr(o.events).map((e) => ({ ...e, machine: r.label, agent: r.name })));
    evs.push(...arr(r.snapshot.events).map((e) => agentEvent(e, r.label, r.name, batchOfThread)));
  }
  state.events = evs.sort((a, b) => tsMs(b.ts) - tsMs(a.ts)).slice(0, 200);
  state.profiles = [...profiles].sort();
  state.inbox.watcher = { alive: withSnap.length > 0 && t3ok };
  state.multi = rows.length > 1;

  for (const r of rows) {
    const snap = r.snapshot, ok = r.status === "ok" && !r.stale;
    const info = snap && snap.agent ? { ...snap.agent, api_version: snap.api_version } : null;
    const warning = snap && num(snap.api_version, SUPPORTED_API) > SUPPORTED_API ? "el agente usa una API más nueva: actualiza la app" : "";
    agents.push({ name: r.name, label: r.label, status: r.status, error: r.error || "", message: statusMessage(r.status, r.error), stale: !!r.stale, age: r.age || 0, info, warning });
    const h = history.get(r.label);
    const m = (snap && snap.machine) || {};
    machines.push({
      name: r.label, agent: r.name, ok, stale: !!r.stale, reason: ok ? "" : statusMessage(r.status, r.error), os: m.os || "", role: "",
      cpus: num(m.cpus), load: arr(m.load), ramTotalMB: num(m.ram_total_mb), ramAvailMB: num(m.ram_avail_mb), swapUsedMB: num(m.swap_used_mb),
      disk: m.disk_total_gb ? `${num(m.disk_used_gb)}/${num(m.disk_total_gb)} GB` : "", diskPct: num(m.disk_pct), uptime: num(m.uptime),
      cpu: h.cpu, ram: h.ram, load1: h.load1, run: h.run,
      apps: arr(snap && snap.apps), projects: arr(snap && snap.projects), info,
    });
  }
  return { state, machines, agents, hasData: withSnap.length > 0 };
}

export function createStore({ historyLen = HISTORY_LEN, now = Date.now } = {}) {
  const history = createHistory(historyLen);
  const lastOk = new Map();
  const labels = new Map();
  return {
    history,
    update(results) {
      const t = now();
      const seen = new Set();
      const rows = arr(results).map((r) => {
        seen.add(r.name);
        const status = r.status || (r.snapshot ? "ok" : "error");
        const row = { name: r.name, status, error: r.error || "", snapshot: null, stale: false, age: 0, label: labels.get(r.name) || r.name };
        if (status === "ok" && r.snapshot) {
          row.snapshot = r.snapshot;
          row.label = r.snapshot.machine_id || r.name;
          labels.set(r.name, row.label);
          lastOk.set(r.name, { snapshot: r.snapshot, at: t });
          history.push(row.label, sampleOf(r.snapshot));
        } else if (lastOk.has(r.name)) {
          const l = lastOk.get(r.name);
          row.snapshot = l.snapshot;
          row.stale = true;
          row.age = Math.max(0, Math.round((t - l.at) / 1000));
        }
        return row;
      });
      for (const k of [...lastOk.keys()]) if (!seen.has(k)) lastOk.delete(k);
      return buildView(rows, history);
    },
  };
}
