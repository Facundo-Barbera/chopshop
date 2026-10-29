import test from "node:test";
import assert from "node:assert/strict";
import { buildView, createHistory, createStore, normQuestion, parseTs, statusMessage } from "../src/index.js";

// Snapshots de ejemplo (datos ficticios: host-a / host-b / proyecto-demo).
const NOW = 1761660000;
const machine = (o = {}) => ({ cpus: 8, load: [1.5, 1, 0.8], cpu_pct: 20, ram_total_mb: 32768, ram_avail_mb: 20000, ram_pct: 39, swap_used_mb: 0,
  disk_used_gb: 100, disk_total_gb: 400, disk_pct: 25, os: "Linux", uptime: 1000, ...o });
const snap = (id, o = {}) => ({
  api_version: 1, machine_id: id, ts: NOW, generated: "2026-10-28T09:40:00-0600", machine: machine(), apps: [], projects: [], threads: [],
  pending_questions: [], events: [], subscriptions: {}, orchestrator: null,
  agent: { version: "0.6.0", uptime: 5, t3_ok: true, last_sample_age: 1, last_poll_age: 1 }, ...o,
});
const thread = (id, o = {}) => ({ thread_id: id, project: "proyecto-demo", title: "Hilo " + id, status: "running", settled: false, pending: [], worktree: "/wt/" + id, updated: NOW - 60, ...o });
const orch = () => ({
  hosts: { "host-a": { cap: 2, purpose: "dev", transport: "local" } }, profiles: ["proyecto-demo"], subscriptions: { bot: { project: "*", events: [] } },
  inbox: { pending: [{ task: "t-1", choice: "si" }], results: [], watcher: null }, graphs: [{ id: "g-1", nodes: [] }],
  events: [{ ts: "2025-10-28T06:30:00-0600", event: "task_done", project: "proyecto-demo", batch: "b-1", task: "t-1", summary: "ok", delivery: {} }],
  batches: [{ id: "b-1", project: "proyecto-demo", host: "host-a", created: "2026-10-28T09:00:00-0600", notes: [],
    tasks: [{ id: "t-1", title: "Tarea 1", status: "launched", t3status: "running", done: false, threadId: "th-1", pending: null }] }],
});

test("parseTs acepta epoch, ISO con offset sin dos puntos y vacío", () => {
  assert.equal(parseTs(NOW).getTime(), NOW * 1000);
  assert.equal(parseTs("2026-10-28T09:40:00-0600").toISOString(), "2026-10-28T15:40:00.000Z");
  assert.equal(parseTs(""), null);
  assert.equal(parseTs("no es fecha"), null);
});

test("statusMessage: un texto por estado, sin filtrar nada más que el error recibido", () => {
  assert.equal(statusMessage("ok"), "");
  assert.match(statusMessage("unreachable", "tiempo agotado"), /no alcanzable.*tiempo agotado/);
  assert.match(statusMessage("forbidden"), /403/);
  assert.match(statusMessage("unauthorized"), /401/);
  assert.equal(statusMessage("error", "boom"), "boom");
});

test("normQuestion: forma del orquestador y forma cruda de T3", () => {
  assert.deepEqual(normQuestion({ request: "r1", summary: "¿Sí?", options: ["a", "b"] }), { request: "r1", summary: "¿Sí?", options: ["a", "b"] });
  assert.deepEqual(normQuestion({ question: "¿Cuál?", options: [{ label: "x" }, { value: "y" }, {}] }, "r2"), { request: "r2", summary: "¿Cuál?", options: ["x", "y"] });
  assert.deepEqual(normQuestion("solo texto", "r3"), { request: "r3", summary: "solo texto", options: [] });
});

test("una sola máquina: lotes del orquestador + lote sintético con los hilos que solo ve el agente", () => {
  const s = snap("host-a", {
    orchestrator: orch(),
    projects: [{ name: "proyecto-demo", cpu_pct: 10, rss_mb: 100, procs: 3, threads_running: 2, threads_pending: 1 }],
    threads: [thread("th-1"), thread("th-2", { status: "waiting", pending: [{}] }), thread("th-3", { status: "completed", settled: true, updated: NOW - 100 }),
      thread("th-viejo", { status: "completed", updated: NOW - 3 * 86400 })],
    pending_questions: [{ thread_id: "th-2", project: "proyecto-demo", request_id: "rq-1", questions: [{ question: "¿Continuar?", options: [{ label: "Sí" }, { label: "No" }] }] }],
  });
  const v = createStore().update([{ name: "host-a", status: "ok", snapshot: s }]);
  const ids = v.state.batches.map((b) => b.id);
  assert.deepEqual(ids, ["b-1", "host-a/proyecto-demo"]);
  const syn = v.state.batches[1];
  assert.equal(syn.synthetic, true);
  assert.deepEqual(syn.tasks.map((t) => t.id), ["th-2", "th-3"], "th-1 ya está en el lote b-1; th-viejo cae fuera de la ventana");
  assert.deepEqual(syn.tasks[0].pending, { questions: [{ request: "rq-1", summary: "¿Continuar?", options: ["Sí", "No"] }], approvals: 0 });
  assert.equal(syn.tasks[1].done, true);
  assert.equal(v.state.batches[0].agent, "host-a");
  assert.deepEqual(v.state.profiles, ["proyecto-demo"]);
  assert.equal(v.state.inbox.pending.length, 1);
  assert.equal(v.state.inbox.watcher.alive, true);
  assert.equal(v.state.multi, false);
  assert.equal(v.state.graphs[0].agent, "host-a");
});

test("permisos pendientes (sin pregunta) se cuentan como approvals", () => {
  const s = snap("host-a", { threads: [thread("th-9", { status: "waiting", pending: [{}, {}] })] });
  const v = buildView([{ name: "a", label: "host-a", status: "ok", snapshot: s }]);
  assert.deepEqual(v.state.batches[0].tasks[0].pending, { questions: [], approvals: 2 });
});

test("dos máquinas se combinan: etiquetas por machine_id, eventos ordenados y mezclados", () => {
  const a = snap("host-a", { orchestrator: orch(), events: [{ seq: 1, ts: NOW - 10, machine_id: "host-a", event: "thread_started", project: "proyecto-demo", body: { thread_id: "th-1", title: "x" } }] });
  const b = snap("host-b", { threads: [thread("th-b1")], events: [{ seq: 7, ts: NOW, machine_id: "host-b", event: "thread_done", project: "proyecto-demo", body: { thread_id: "th-b1", status: "completed" } }] });
  const v = createStore().update([{ name: "mac-host-a", status: "ok", snapshot: a }, { name: "host-b", status: "ok", snapshot: b }]);
  assert.equal(v.state.multi, true);
  assert.deepEqual(v.machines.map((m) => [m.name, m.agent, m.ok]), [["host-a", "mac-host-a", true], ["host-b", "host-b", true]]);
  assert.equal(v.state.events[0].event, "thread_done", "el más nuevo primero");
  assert.equal(v.state.events[0].batch, "host-b/proyecto-demo", "el evento de hilo apunta al lote sintético");
  assert.equal(v.state.events[0].machine, "host-b");
  assert.ok(v.state.events.some((e) => e.event === "task_done" && e.machine === "host-a"));
  assert.equal(v.state.hosts["host-b"].cap, null, "el host del agente sin orquestador no tiene tope propio");
  assert.equal("leases" in v, false);
  assert.equal("leases" in v.machines[1], false);
  assert.equal(v.state.hosts["host-a"].cap, 2);
});

test("un hilo del orquestador de host-a visto también por host-b no se duplica", () => {
  const a = snap("host-a", { orchestrator: orch() });
  const b = snap("host-b", { threads: [thread("th-1")] });
  const v = buildView([{ name: "a", label: "host-a", status: "ok", snapshot: a }, { name: "b", label: "host-b", status: "ok", snapshot: b }]);
  assert.deepEqual(v.state.batches.map((x) => x.id), ["b-1"]);
});

test("agente caído: conserva los datos viejos marcados, estado visible y máquina no ok", () => {
  let t = 1_000_000;
  const store = createStore({ now: () => t });
  store.update([{ name: "host-a", status: "ok", snapshot: snap("host-a", { threads: [thread("th-1")] }) }]);
  t += 30_000;
  const v = store.update([{ name: "host-a", status: "unreachable", error: "tiempo de espera agotado" }]);
  assert.equal(v.agents[0].status, "unreachable");
  assert.equal(v.agents[0].stale, true);
  assert.equal(v.agents[0].age, 30);
  assert.match(v.agents[0].message, /no alcanzable/);
  assert.equal(v.machines[0].ok, false);
  assert.equal(v.machines[0].name, "host-a", "la etiqueta se mantiene (machine_id recordado)");
  assert.match(v.machines[0].reason, /no alcanzable/);
  assert.equal(v.state.batches.length, 1, "sigue mostrando lo último que se vio");
  assert.equal(v.machines[0].cpu.length, 1, "no se añaden muestras mientras está caído");
});

test("agente que nunca respondió: sin datos pero con estado (403)", () => {
  const v = createStore().update([{ name: "host-b", status: "forbidden", error: "" }]);
  assert.equal(v.state.batches.length, 0);
  assert.equal(v.hasData, false);
  assert.equal(v.machines[0].ok, false);
  assert.equal(v.machines[0].name, "host-b");
  assert.match(v.agents[0].message, /403/);
});

test("historial: una muestra por sondeo, acotado, y precarga con seed", () => {
  const store = createStore({ historyLen: 3 });
  let v;
  for (let i = 0; i < 5; i++) v = store.update([{ name: "a", status: "ok", snapshot: snap("host-a", { machine: machine({ cpu_pct: i * 10 }), projects: [{ name: "p", threads_running: i }] }) }]);
  assert.deepEqual(v.machines[0].cpu, [20, 30, 40]);
  assert.deepEqual(v.machines[0].run, [2, 3, 4]);
  const h = createHistory(60);
  h.seed({ "host-z": { cpu: [1, 2], ram: [3, 4], load1: [0.5], run: [0, 1] } });
  assert.deepEqual(h.get("host-z").ram, [3, 4]);
  assert.deepEqual(h.get("otro").cpu, []);
});

test("máquina: campos de la vista Máquinas desde snapshot.machine, apps y proyectos", () => {
  const s = snap("host-a", { apps: [{ name: "node", cpu_pct: 12, rss_mb: 800, procs: 14, cgroups: [] }], projects: [{ name: "proyecto-demo", cpu_pct: 3, rss_mb: 9, procs: 1, threads_running: 1, threads_pending: 0 }] });
  const m = createStore().update([{ name: "a", status: "ok", snapshot: s }]).machines[0];
  assert.equal(m.cpus, 8);
  assert.equal(m.ramTotalMB, 32768);
  assert.equal(m.ramAvailMB, 20000);
  assert.equal(m.disk, "100/400 GB");
  assert.equal(m.diskPct, 25);
  assert.equal(m.apps[0].name, "node");
  assert.equal(m.projects[0].name, "proyecto-demo");
  assert.equal(m.info.api_version, 1);
});

test("API más nueva que la soportada: aviso, sin romper", () => {
  const v = createStore().update([{ name: "a", status: "ok", snapshot: snap("host-a", { api_version: 2 }) }]);
  assert.match(v.agents[0].warning, /actualiza la app/);
});

test("T3 caído en el agente: el watcher de la bandeja figura como no vivo", () => {
  const s = snap("host-a", { agent: { version: "0.6.0", uptime: 1, t3_ok: false, last_sample_age: 1, last_poll_age: 60 } });
  assert.equal(createStore().update([{ name: "a", status: "ok", snapshot: s }]).state.inbox.watcher.alive, false);
});

test("snapshot vacío o parcial no revienta", () => {
  const v = createStore().update([{ name: "a", status: "ok", snapshot: { api_version: 1, machine_id: "host-a" } }]);
  assert.equal(v.state.batches.length, 0);
  assert.equal(v.machines[0].cpus, 0);
  assert.deepEqual(createStore().update([]).machines, []);
});
