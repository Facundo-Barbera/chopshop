import { Component, createContext, useContext, useEffect, useMemo, useState } from "react";
import { createStore, parseTs } from "@chopshop/api";
import { on, request, send } from "./bridge.js";

const Ctx = createContext({ fin: {} });

// ---------- utilidades ----------
// Las horas se muestran en la zona horaria local del Mac.
const clock = (ts) => {
  const d = parseTs(ts);
  return d ? d.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit", hour12: false }) : "";
};
const ago = (ts, now) => {
  const d = parseTs(ts);
  if (!d) return "";
  const s = Math.max(0, Math.round((now - d.getTime()) / 1000));
  if (s < 10) return "ahora";
  if (s < 60) return `hace ${s} s`;
  if (s < 3600) return `hace ${Math.floor(s / 60)} min`;
  if (s < 86400) return `hace ${Math.floor(s / 3600)} h`;
  return `hace ${Math.floor(s / 86400)} d`;
};

const EVENT_META = {
  pending_question: { label: "Pregunta pendiente", tone: "amber", icon: "?" },
  pending_approval: { label: "Permiso pendiente", tone: "orange", icon: "!" },
  task_done: { label: "Tarea terminada", tone: "green", icon: "✓" },
  batch_done: { label: "Lote terminado", tone: "teal", icon: "◆" },
  reaction: { label: "Reacción", tone: "violet", icon: "⚡" },
  // eventos del agente (por hilo de T3 y por máquina)
  thread_started: { label: "Hilo iniciado", tone: "blue", icon: "▶" },
  thread_done: { label: "Hilo terminado", tone: "green", icon: "✓" },
  thread_failed: { label: "Hilo falló", tone: "red", icon: "×" },
  thread_settled: { label: "Hilo cerrado", tone: "teal", icon: "◆" },
  t3_unreachable: { label: "T3 no responde", tone: "orange", icon: "!" },
  machine_alert: { label: "Alerta de máquina", tone: "orange", icon: "!" },
  lease_granted: { label: "Servidor de pruebas activo", tone: "mint", icon: "▲" },
  lease_queued: { label: "Servidor en cola", tone: "gray", icon: "…" },
  lease_released: { label: "Servidor liberado", tone: "gray", icon: "▼" },
};

// ---------- niveles de reacción ----------
const LEVELS = {
  auto: { n: 1, label: "Auto", tone: "mint", what: "Chopshop lo resuelve solo" },
  bot: { n: 2, label: "Bot", tone: "violet", what: "despierta al bot por webhook" },
  human: { n: 3, label: "Humano", tone: "pink", what: "escala a una persona" },
};
const LevelBadge = ({ level, small }) => {
  const l = LEVELS[level];
  return l ? <span className={`lvl tone-${l.tone} ${small ? "sm" : ""}`} title={`Nivel ${l.n}: ${l.what}`}>N{l.n} · {l.label}</span> : null;
};
const RX_ON = { task_done: "Tarea terminada", task_failed: "Tarea falló", task_stalled: "Hilo sin progreso", pending_question: "Pregunta pendiente" };
const rxActionLabel = (a) => {
  a = a || "";
  if (a === "settle") return "Cerrar hilo (settle)";
  if (a.startsWith("retry_once")) return a.includes("agotado") ? "Reintento agotado" : "Reintentar una vez";
  if (a.startsWith("answer:")) return "Responder «" + a.slice(7) + "»";
  if (a.startsWith("despertar a ")) return "Despertar a " + a.slice(12);
  if (a.startsWith("escalar a ")) return "Escalar a " + a.slice(10);
  return a;
};

const needsHuman = (t) => !!(t.escalation && t.escalation.status === "open");
const waitingBot = (t) => !!(t.bot_wait && !t.bot_wait.done);
function taskState(t) {
  if (needsHuman(t)) return { label: "Necesita humano", tone: "pink", pulse: true };
  if (waitingBot(t) && t.pending && t.pending.questions && t.pending.questions.length) return { label: "Esperando al bot", tone: "violet", pulse: true };
  if (t.pending && t.pending.questions && t.pending.questions.length) return { label: "Pregunta", tone: "amber", pulse: true };
  if (t.pending && t.pending.approvals) return { label: "Permiso", tone: "orange", pulse: true };
  if (t.status === "skipped") return { label: "Omitida", tone: "gray" };
  if (t.status === "launch_failed") return { label: "Falló", tone: "red" };
  if (t.status === "queued") return { label: "En cola", tone: "gray" };
  const s = t.t3status;
  if (s === "completed") return { label: "Completada", tone: "green" };
  if (s === "failed" || s === "rolled_back") return { label: "Falló", tone: "red" };
  if (s === "cancelled" || s === "interrupted") return { label: s === "cancelled" ? "Cancelada" : "Interrumpida", tone: "gray" };
  return { label: s === "preparing" ? "Preparando" : "Corriendo", tone: "blue", pulse: true };
}

const secs = (a, b) => {
  const x = parseTs(a), y = parseTs(b);
  return x && y ? Math.max(0, Math.round((y - x) / 1000)) : null;
};
const fmtDur = (s) => (s == null ? "" : s < 60 ? `${s} s` : s < 3600 ? `${Math.floor(s / 60)} min ${s % 60 ? (s % 60) + " s" : ""}`.trim() : `${Math.floor(s / 3600)} h`);
// texto del resultado sin el bloque de diff (primera frase útil) y el diff aparte
const splitResult = (r) => {
  if (!r) return { text: "", diff: "" };
  const m = r.match(/(`{3,})diff\n([\s\S]*?)\n\1/);
  const text = (m ? r.replace(m[0], "") : r).trim();
  return { text, diff: m ? m[2] : "" };
};
const stripMd = (t) =>
  (t || "").replace(/`{3,}[\s\S]*?`{3,}/g, " ").replace(/[*_`#>]+/g, "").replace(/\[([^\]]+)\]\([^)]*\)/g, "$1");
const oneLine = (t, n = 120) => {
  const x = stripMd(t).replace(/\s+/g, " ").trim();
  return x.length > n ? x.slice(0, n - 1).trimEnd() + "…" : x;
};
const niceTitle = (x, n = 64) => {
  x = x || "";
  if (/^use your interactive question tool/i.test(x)) return "Tarea con pregunta interactiva";
  return x.length <= n ? x : oneLine(x, n);
};
const cleanTitle = (t) => niceTitle(t.title || t.prompt || t.id);

const waited = (ts, now) => (ts ? "esperando " + ago(ts, now).replace("hace ", "") : "");

const Chip = ({ tone = "gray", children, pulse }) => (
  <span className={`chip tone-${tone}`}>
    <i className={pulse ? "dot pulse" : "dot"} />
    {children}
  </span>
);

const Icon = ({ name }) => {
  const p = {
    overview: "M4 13h6V4H4v9zm0 7h6v-5H4v5zm9 0h7v-9h-7v9zm0-16v5h7V4h-7z",
    question: "M12 3a9 9 0 100 18 9 9 0 000-18zm.9 14.2h-1.8v-1.8h1.8v1.8zm1.3-5.6l-.8.8c-.5.5-.7.9-.7 1.6h-1.7v-.4c0-.8.3-1.5.9-2.1l1-1a1.5 1.5 0 10-2.5-1.1H8.6a3.2 3.2 0 116.4 0c0 .8-.3 1.6-.8 2.2z",
    layers: "M12 3l9 5-9 5-9-5 9-5zm-7.5 8.4L12 15.6l7.5-4.2L21 12.3l-9 5-9-5 1.5-.9zm0 4L12 19.6l7.5-4.2 1.5.9-9 5-9-5 1.5-.9z",
    bolt: "M13 2L5 14h6l-1 8 8-12h-6l1-8z",
  }[name];
  return (
    <svg viewBox="0 0 24 24" className="icon" aria-hidden="true">
      <path d={p} fill="currentColor" />
    </svg>
  );
};

// ---------- tarjetas ----------
function QuestionCard({ batch, task, q, onDone, since, queued, failed, watcher, bare, compact, by }) {
  const [custom, setCustom] = useState("");
  const [busy, setBusy] = useState(null);
  const [msg, setMsg] = useState(null);

  const submit = async (choice) => {
    if (!choice || busy) return;
    setBusy(choice);
    setMsg(null);
    try {
      // POST /answer al agente dueño del hilo (la app nativa lo traduce)
      const r = await request("answer", { agent: batch.agent, thread_id: task.threadId || task.id, choice, request: q.request, by: by || (needsHuman(task) ? "humano" : undefined) });
      setMsg(r.payload);
      if (r.payload.ok) onDone && onDone();
    } catch (e) {
      setMsg({ ok: false, message: String(e.message || e) });
    }
    setBusy(null);
  };

  return (
    <article className={`card question ${bare ? "bare" : "boxed"} ${compact ? "compact" : ""}`}>
      <header className="card-head">
        {needsHuman(task) ? <Chip tone="pink" pulse>Necesita humano</Chip> : waitingBot(task) ? <Chip tone="violet" pulse>Esperando al bot</Chip> : <Chip tone="amber" pulse>Pregunta pendiente</Chip>}
        {task.level && <LevelBadge level={task.level} small />}
        <span className="meta">
          {batch.project} · {batch.id} · {task.id} · {batch.host}{since ? ` · ${since}` : ""}
        </span>
      </header>
      <h3 className="q-text">{q.summary || "(sin texto)"}</h3>
      <p className="task-title">{niceTitle(task.title)}</p>
      {needsHuman(task) && <p className="note esc">Escalada a <b>{task.escalation.notify}</b> · {task.escalation.reason}</p>}
      <div className="options">
        {(q.options || []).map((o) => (
          <button key={o} className="pill" disabled={!!busy || !!queued} onClick={() => submit(o)}>
            {busy === o ? <span className="spin" /> : null}
            {o}
          </button>
        ))}
      </div>
      <form
        className="custom"
        onSubmit={(e) => {
          e.preventDefault();
          submit(custom.trim());
        }}
      >
        <input value={custom} onChange={(e) => setCustom(e.target.value)} placeholder="o escribe otra respuesta…" disabled={!!busy || !!queued} />
        <button className="pill primary" disabled={!custom.trim() || !!busy || !!queued}>Responder</button>
      </form>
      {queued && (
        <p className="note ok">
          <b>En cola:</b> «{queued.choice}» · la envía el agente en su próximo ciclo
          {!(watcher && watcher.alive) && <span className="warn"> · el agente no ve a T3 ahora mismo</span>}
        </p>
      )}
      {failed && !queued && <p className="note err">La última respuesta («{failed.choice}») falló: {failed.error}</p>}
      {msg && !msg.ok && <p className="note err">Error: {msg.message}</p>}
    </article>
  );
}

function ApprovalCard({ batch, task, bare, compact }) {
  return (
    <article className={`card approval ${bare ? "bare" : "boxed"} ${compact ? "compact" : ""}`}>
      <header className="card-head">
        <Chip tone="orange" pulse>Permiso pendiente</Chip>
        <span className="meta">
          {batch.project} · {batch.id} · {task.id} · {batch.host}
        </span>
      </header>
      <h3 className="q-text" title={task.title}>{niceTitle(task.title, 56)}</h3>
      <p className="muted">
        El hilo espera aprobar {task.pending.approvals > 1 ? `${task.pending.approvals} permisos` : "un permiso"} (comando o edición). Chopshop no puede aprobarlo
        por MCP: hay que hacerlo en la UI de T3.
      </p>
      {task.threadId && task.link && (
        <button className="pill" onClick={() => send("openLink", { url: (task.link.match(/\((.*)\)/) || [])[1] || task.link })}>
          Abrir hilo en T3
        </button>
      )}
    </article>
  );
}

const Diff = ({ text }) => (
  <pre className="diff">
    {text.split("\n").map((l, i) => (
      <span key={i} className={l.startsWith("+") && !l.startsWith("+++") ? "add" : l.startsWith("-") && !l.startsWith("---") ? "del" : l.startsWith("@@") ? "hunk" : l.startsWith("+++") || l.startsWith("---") ? "file" : ""}>
        {l + "\n"}
      </span>
    ))}
  </pre>
);

const openT3 = (t) => send("openLink", { url: (t.link.match(/\((.*)\)/) || [])[1] || t.link });

function Stat({ label, value, tone, hint, live }) {
  return (
    <div className={`glass stat tone-${tone} ${value === 0 ? "zero" : ""}`}>
      <div className="stat-top">
        <i className={`dot ${live && value > 0 ? "pulse" : ""}`} />
        <span className="stat-label">{label}</span>
      </div>
      <div className="stat-value">{value}</div>
      {hint && <div className="stat-hint">{hint}</div>}
    </div>
  );
}

function ProgressBar({ tasks }) {
  return (
    <div className="progress" title={`${tasks.length} tareas`}>
      {tasks.map((t) => (
        <span key={t.id} className={`seg tone-${taskState(t).tone} ${taskState(t).pulse ? "live" : ""}`} />
      ))}
    </div>
  );
}

/** Contenedor de panel: cabecera fija + cuerpo con scroll propio. */
function Pane({ title, count, action, children, className = "", flush }) {
  return (
    <section className={`glass pane ${className}`}>
      <header className="pane-head">
        <h2>{title}</h2>
        {count != null && <span className="count-s">{count}</span>}
        <span className="grow" />
        {action}
      </header>
      <div className={`pane-body ${flush ? "flush" : ""}`}>{children}</div>
    </section>
  );
}

const PaneEmpty = ({ mark = "✦", title, text }) => (
  <div className="pane-empty">
    <div className="empty-mark">{mark}</div>
    <b>{title}</b>
    {text && <span className="muted">{text}</span>}
  </div>
);

function ViewHead({ title, sub, children }) {
  return (
    <header className="view-head">
      <div>
        <h1>{title}</h1>
        {sub && <p className="muted">{sub}</p>}
      </div>
      <div className="view-tools">{children}</div>
    </header>
  );
}

// ---------- detalle de una tarea ----------
function TaskDetail({ t, b, c, now }) {
  const { fin } = useContext(Ctx);
  const st = taskState(t);
  const { text, diff } = splitResult(t.result);
  const dur = t.done ? fmtDur(secs(b.created, fin[t.id])) : "";
  const qs = c.questions.filter((x) => x.t.id === t.id);
  const appr = t.pending && t.pending.approvals;
  const [settling, setSettling] = useState(false);
  const [settleMsg, setSettleMsg] = useState(null);
  const canSettle = t.done && !t.settled && !!t.threadId && !!b.agent;
  // POST /settle: marca el hilo como cerrado en T3 (nunca lo archiva)
  const settle = async () => {
    setSettling(true);
    setSettleMsg(null);
    try {
      const r = await request("settle", { agent: b.agent, thread_id: t.threadId });
      setSettleMsg(r.payload);
    } catch (e) {
      setSettleMsg({ ok: false, message: String(e.message || e) });
    }
    setSettling(false);
  };
  return (
    <div className="detail">
      <header className="detail-head">
        <Chip tone={st.tone} pulse={st.pulse}>{st.label}</Chip>
        <span className="meta">{b.project} · {b.id} · {t.id} · {b.host}{dur ? ` · ${dur}` : ""}</span>
      </header>
      {!(qs.length || appr) && <h3 className="detail-title">{cleanTitle(t)}</h3>}
      {qs.map(({ b: bb, t: tt, q, ts, ...x }) => (
        <QuestionCard key={q.request} batch={bb} task={tt} q={q} since={waited(ts, now)} {...x} bare />
      ))}
      {appr ? <ApprovalCard batch={b} task={t} bare /> : null}
      {t.skip_reason && <p className="muted">Omitida: {t.skip_reason}</p>}
      {t.last_error && <p className="note err">{t.last_error}</p>}
      {(t.answered || []).length > 0 && <h5>Preguntas respondidas</h5>}
      {(t.answered || []).map((a, i) => (
        <div key={i} className="qa">
          <span className="qa-q">{a.summary}</span>
          <span className="qa-a">→ {a.choice}</span>
        </div>
      ))}
      {text && <p className="result-text">{text}</p>}
      {diff && (
        <>
          <h5>Propuesta (diff)</h5>
          <Diff text={diff} />
        </>
      )}
      {t.result && !diff && !text && (
        <>
          <h5>Resultado</h5>
          <pre>{t.result}</pre>
        </>
      )}
      {!t.result && t.prompt && (
        <>
          <h5>Prompt</h5>
          <pre>{t.prompt}</pre>
        </>
      )}
      <div className="detail-foot">
        {t.settled && <span className="tag">settled</span>}
        {canSettle && (
          <button className="pill small" disabled={settling} onClick={settle} title="Marca el hilo como cerrado en T3 (no lo archiva)">
            {settling ? <span className="spin" /> : null}
            Cerrar hilo (settle)
          </button>
        )}
        {!appr && t.threadId && t.link && <button className="pill small" onClick={() => openT3(t)}>Abrir hilo en T3</button>}
      </div>
      {settleMsg && <p className={`note ${settleMsg.ok ? "ok" : "err"}`}>{settleMsg.ok ? "Hilo cerrado." : "Error: " + settleMsg.message}</p>}
    </div>
  );
}

function BatchSummary({ b }) {
  return (
    <div className="detail">
      <header className="detail-head">
        <Chip tone={isActive(b) ? "blue" : "green"} pulse={isActive(b)}>{isActive(b) ? "Activo" : "Terminado"}</Chip>
        <span className="meta">{b.project} · {b.host}</span>
      </header>
      <h3 className="detail-title">Lote {b.id}</h3>
      <ProgressBar tasks={b.tasks} />
      <ul className="mini-tasks">
        {b.tasks.map((t) => (
          <li key={t.id}>
            <Chip tone={taskState(t).tone} pulse={taskState(t).pulse}>{taskState(t).label}</Chip>
            <span className="grow ell">{cleanTitle(t)}</span>
            <span className="meta">{t.id}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

// ---------- listas ----------
function BatchRow({ b, now, selected, onSelect, showProject }) {
  const done = b.tasks.filter((t) => t.done).length;
  const active = isActive(b);
  return (
    <li>
      <button className={`row batch-row ${selected ? "sel" : ""} ${active ? "live" : ""}`} onClick={onSelect} aria-pressed={selected}>
        <div className="row-top">
          <i className={`dot tone-${active ? "blue" : "green"} ${active ? "pulse" : ""}`} />
          <b>{b.id}</b>
          {showProject && <span className="muted ell">{b.project}</span>}
          <span className="grow" />
          <span className="count">{done}/{b.tasks.length}</span>
        </div>
        <ProgressBar tasks={b.tasks} />
        <div className="meta">{clock(b.created)} · {ago(b.created, now)} · {b.host}</div>
      </button>
    </li>
  );
}

function TaskListRow({ t, selected, onSelect }) {
  const st = taskState(t);
  const ans = (t.answered || []).slice(-1)[0];
  return (
    <li>
      <button className={`row task-row ${selected ? "sel" : ""}`} onClick={onSelect} aria-pressed={selected}>
        <div className="row-top">
          <Chip tone={st.tone} pulse={st.pulse}>{st.label}</Chip>
          {t.level && <LevelBadge level={t.level} small />}
          <span className="grow" />
          <span className="meta">{t.id}</span>
        </div>
        <div className="row-title">{cleanTitle(t)}</div>
        {ans && <div className="meta ell">respondió {ans.choice}{ans.by ? ` · ${ans.by}` : ""}</div>}
      </button>
    </li>
  );
}

function EventItem({ e, now, titles, selected, onSelect }) {
  let m = EVENT_META[e.event] || { label: e.event, tone: "gray", icon: "·" };
  if (e.event === "task_done" && e.status && e.status !== "completed") {
    m = { label: e.status === "failed" ? "Tarea fallida" : `Tarea ${e.status}`, tone: e.status === "failed" ? "red" : "gray", icon: "×" };
  }
  const who = (e.task && titles[e.task] && niceTitle(titles[e.task], 52)) || e.task || e.batch;
  const dl = Object.values(e.delivery || {});
  const dlBad = dl.some((v) => v !== "ok");
  return (
    <li>
      <button className={`row event-row ${selected ? "sel" : ""}`} onClick={onSelect} aria-pressed={selected}>
        <span className={`ev-icon tone-${m.tone}`}>{m.icon}</span>
        <span className="ev-main">
          <span className="ev-top"><b>{m.label}</b><span className="meta">{e.batch}{e.task ? ` · ${e.task}` : ""}</span></span>
          <span className="ell who">{who}</span>
          {e.summary && <span className="meta ell">“{e.summary}”</span>}
          {dl.length > 0 && <span className={`dl ${dlBad ? "bad" : "ok"}`}>webhook {dlBad ? "falló" : "entregado ✓"}</span>}
        </span>
        <time title={e.ts}>{clock(e.ts)}<small>{ago(e.ts, now)}</small></time>
      </button>
    </li>
  );
}

function HistoryItem({ h, selected, onSelect }) {
  return (
    <li>
      <button className={`row hist-row ${selected ? "sel" : ""}`} onClick={onSelect} aria-pressed={selected}>
        <div className="row-top">
          <i className="dot tone-green" />
          <span className="tag ok">{h.choice || "respondida"}</span>
          <span className="grow" />
          <span className="meta">{clock(h.ts)}</span>
        </div>
        <div className="row-title">{h.summary || "(sin texto)"}</div>
        <div className="meta ell">{h.t.id} · {niceTitle(h.t.title || h.t.id, 40)}{h.by ? ` · por ${h.by}` : ""}</div>
      </button>
    </li>
  );
}


// ---------- vistas ----------
function Empty({ title, text }) {
  return (
    <div className="empty glass">
      <div className="empty-mark">✦</div>
      <h3>{title}</h3>
      <p className="muted">{text}</p>
    </div>
  );
}

const isActive = (b) => !b.tasks.every((t) => t.done);
const byActivity = (batches) => [...batches].sort((a, b) => Number(isActive(b)) - Number(isActive(a)) || b.id.localeCompare(a.id));

function collect(snap) {
  const seenQ = new Set();
  const questions = [];
  const approvals = [];
  let running = 0;
  let queued = 0;
  const evTs = {};
  for (const e of [...snap.events].reverse()) if (e.event === "pending_question" || e.event === "pending_approval") evTs[e.task] = e.ts;
  const inb = snap.inbox || { pending: [], results: [], watcher: null };
  const queuedBy = {};
  const failedBy = {};
  inb.pending.forEach((i) => (queuedBy[i.task] = i));
  inb.results.forEach((r) => {
    if (r.ok === false) failedBy[r.task] = r;
    else delete failedBy[r.task];
  });
  for (const b of snap.batches) {
    for (const t of b.tasks) {
      const p = t.pending;
      if (p && p.questions) p.questions.forEach((q) => questions.push({ b, t, q, ts: evTs[t.id], queued: queuedBy[t.id], failed: failedBy[t.id], watcher: inb.watcher }));
      if (p && p.approvals) approvals.push({ b, t });
      if (t.status === "launched" && !t.done && !(p && ((p.questions && p.questions.length) || p.approvals))) running++;
      if (t.status === "queued") queued++;
    }
  }
  const history = [];
  const answered = new Set();
  for (const b of snap.batches)
    for (const t of b.tasks)
      (t.answered || []).forEach((a) => {
        answered.add(t.id);
        history.push({ b, t, summary: a.summary, choice: a.choice, ts: a.ts, by: a.by });
      });
  const doneIds = {};
  snap.batches.forEach((b) => b.tasks.forEach((t) => (doneIds[t.id] = { b, t })));
  for (const e of snap.events)
    if (e.event === "pending_question" && !answered.has(e.task) && doneIds[e.task] && doneIds[e.task].t.done && !seenQ.has(e.task)) {
      seenQ.add(e.task);
      history.push({ b: doneIds[e.task].b, t: doneIds[e.task].t, summary: e.summary, choice: null, ts: e.ts });
    }
  history.sort((x, y) => (y.ts || "").localeCompare(x.ts || ""));
  const completed = snap.batches.reduce((n, b) => n + b.tasks.filter((t) => t.done).length, 0);
  return { questions, approvals, running, queued, history, completed };
}

const taskPick = (b) => (b && (b.tasks.find((t) => t.pending && ((t.pending.questions && t.pending.questions.length) || t.pending.approvals)) || b.tasks.find((t) => !t.done) || b.tasks[0])) || null;

// ---------- Resumen: tres paneles ----------
function Overview({ snap, c, now, go, titles, nav }) {
  const active = snap.batches.filter(isActive);
  const attn = c.questions.length + c.approvals.length;
  const running = [];
  snap.batches.forEach((b) => b.tasks.forEach((t) => taskState(t).tone === "blue" && !t.done && running.push({ b, t })));
  return (
    <section className="view">
      <ViewHead title="Resumen" sub="Lo que está corriendo y lo que necesita una decisión" />
      <div className="stats">
        <Stat label="corriendo" value={c.running} tone="blue" live hint={c.queued ? `${c.queued} en cola` : "nada en cola"} />
        <Stat label="preguntas" value={c.questions.length} tone="amber" live hint={c.questions.length ? "esperando respuesta" : "ninguna pendiente"} />
        <Stat label="permisos" value={c.approvals.length} tone="orange" live hint={c.approvals.length ? "se aprueban en T3" : "nada bloqueado"} />
        <Stat label="completadas" value={c.completed} tone="green" hint={`en ${snap.batches.length} lotes${active.length ? ` · ${active.length} activos` : ""}`} />
      </div>
      <div className="panes overview">
        <Pane title="Necesita atención" count={attn || null} action={attn ? <button className="link" onClick={() => go("questions")}>abrir</button> : null}>
          {attn === 0 ? (
            <PaneEmpty title="Todo en calma" text="Ningún hilo espera una respuesta o un permiso." />
          ) : (
            <div className="stack">
              {c.questions.map(({ b, t, q, ts, ...x }) => (
                <QuestionCard key={q.request} batch={b} task={t} q={q} since={waited(ts, now)} {...x} compact />
              ))}
              {c.approvals.map(({ b, t }) => (
                <ApprovalCard key={t.id} batch={b} task={t} compact />
              ))}
            </div>
          )}
          {c.history.length > 0 && (
            <>
              <h3 className="subhead flat">Respondidas <span className="count-s">{c.history.length}</span></h3>
              <ul className="list">
                {c.history.slice(0, 4).map((h, i) => (
                  <li key={i}>
                    <button className="row hist-row" onClick={() => go("questions")}>
                      <div className="row-top"><i className="dot tone-green" /><span className="ell grow">{h.summary || "(sin texto)"}</span><span className="tag ok">{h.choice || "respondida"}</span></div>
                    </button>
                  </li>
                ))}
              </ul>
            </>
          )}
        </Pane>
        <div className="col">
          <Pane title="En marcha" count={running.length || null} className="short">
            {running.length === 0 ? (
              <PaneEmpty mark="◦" title="Nada corriendo" text={c.queued ? `${c.queued} tareas en cola` : "Sin hilos activos ahora mismo."} />
            ) : (
              <ul className="list">
                {running.map(({ b, t }) => (
                  <li key={t.id} className="run-row">
                    <span className="spin" />
                    <span className="grow ell">{cleanTitle(t)}</span>
                    <span className="meta">{b.host} · {ago(b.created, now).replace("hace ", "")}</span>
                  </li>
                ))}
              </ul>
            )}
          </Pane>
          <Pane title="Lotes recientes" action={<button className="link" onClick={() => go("batches")}>ver todos</button>} flush>
            {snap.batches.length === 0 ? (
              <PaneEmpty title="Sin lotes todavía" text="Lanza uno con: chopshop fanout <proyecto> --from tasks.yaml" />
            ) : (
              <ul className="list">
                {byActivity(snap.batches).slice(0, 6).map((b) => (
                  <BatchRow key={b.id} b={b} now={now} showProject selected={false} onSelect={() => nav({ view: "project", project: b.project })} />
                ))}
              </ul>
            )}
          </Pane>
        </div>
        <Pane title="Actividad" action={<button className="link" onClick={() => go("events")}>ver todo</button>} flush>
          <ul className="list">
            {snap.events.slice(0, 8).map((e, i) => (
              <EventItem key={i} e={e} now={now} titles={titles} selected={false} onSelect={() => go("events")} />
            ))}
            {snap.events.length === 0 && <li className="muted pad">Sin eventos.</li>}
          </ul>
        </Pane>
      </div>
    </section>
  );
}

// ---------- Preguntas: lista + detalle ----------
function Questions({ c, now }) {
  const items = [
    ...c.questions.map((x) => ({ key: "q:" + x.q.request, kind: "q", x })),
    ...c.approvals.map((x) => ({ key: "a:" + x.t.id, kind: "a", x })),
    ...c.history.map((h, i) => ({ key: "h:" + i, kind: "h", h })),
  ];
  const [sel, setSel] = useState(items[0] ? items[0].key : null);
  const cur = items.find((i) => i.key === sel) || items[0];
  const pend = items.filter((i) => i.kind !== "h");
  const hist = items.filter((i) => i.kind === "h");
  return (
    <section className="view">
      <ViewHead title="Preguntas" sub="Responde aquí lo que un hilo preguntó; el hilo sigue en cuanto envías la respuesta" />
      <div className="panes split-list">
        <Pane title="Pendientes" count={pend.length || null} flush>
          <ul className="list">
            {pend.length === 0 && <li className="pad"><PaneEmpty title="Todo en calma" text="Ningún hilo espera una respuesta." /></li>}
            {pend.map((i) => {
              const t = i.x.t;
              const amber = i.kind === "q";
              return (
                <li key={i.key}>
                  <button className={`row ${cur && cur.key === i.key ? "sel" : ""}`} onClick={() => setSel(i.key)} aria-pressed={cur && cur.key === i.key}>
                    <div className="row-top"><Chip tone={amber ? (needsHuman(t) ? "pink" : waitingBot(t) ? "violet" : "amber") : "orange"} pulse>{amber ? (needsHuman(t) ? "Necesita humano" : waitingBot(t) ? "Esperando al bot" : "Pregunta") : "Permiso"}</Chip>{t.level && <LevelBadge level={t.level} small />}<span className="grow" /><span className="meta">{t.id}</span></div>
                    <div className="row-title">{amber ? i.x.q.summary : cleanTitle(t)}</div>
                  </button>
                </li>
              );
            })}
          </ul>
          {hist.length > 0 && (
            <>
              <h3 className="subhead">Respondidas <span className="count-s">{hist.length}</span></h3>
              <ul className="list">
                {hist.map((i) => (
                  <HistoryItem key={i.key} h={i.h} selected={cur && cur.key === i.key} onSelect={() => setSel(i.key)} />
                ))}
              </ul>
            </>
          )}
        </Pane>
        <Pane title="Detalle" className="detail-pane">
          {!cur ? (
            <PaneEmpty title="Nada que mostrar" />
          ) : cur.kind === "q" ? (
            <div className="detail">
              <QuestionCard key={cur.x.q.request} batch={cur.x.b} task={cur.x.t} q={cur.x.q} since={waited(cur.x.ts, now)} queued={cur.x.queued} failed={cur.x.failed} watcher={cur.x.watcher} bare />
              <h5>Contexto de la tarea</h5>
              <TaskContext t={cur.x.t} b={cur.x.b} />
            </div>
          ) : cur.kind === "a" ? (
            <div className="detail">
              <ApprovalCard batch={cur.x.b} task={cur.x.t} bare />
              <h5>Contexto de la tarea</h5>
              <TaskContext t={cur.x.t} b={cur.x.b} />
            </div>
          ) : (
            <TaskDetail t={cur.h.t} b={cur.h.b} c={c} now={now} />
          )}
        </Pane>
      </div>
    </section>
  );
}

function TaskContext({ t, b }) {
  return (
    <dl className="kv">
      <dt>Lote</dt><dd>{b.id} · {b.project}</dd>
      <dt>Máquina</dt><dd>{b.host}</dd>
      <dt>Tarea</dt><dd>{cleanTitle(t)}</dd>
      {t.prompt && (<><dt>Prompt</dt><dd className="ell3">{oneLine(t.prompt, 240)}</dd></>)}
    </dl>
  );
}

// ---------- Proyecto / Lotes: tres paneles (lotes · tareas · detalle) ----------
function ProjectView({ snap, c, now, project }) {
  const all = !project;
  const batches = byActivity(all ? snap.batches : snap.batches.filter((b) => b.project === project));
  const [bid, setBid] = useState(batches[0] ? batches[0].id : null);
  const b = batches.find((x) => x.id === bid) || batches[0] || null;
  const [tid, setTid] = useState(null);
  const t = (b && b.tasks.find((x) => x.id === tid)) || taskPick(b);
  const tasks = batches.flatMap((x) => x.tasks);
  const cnt = {
    run: tasks.filter((x) => !x.done && taskState(x).tone === "blue").length,
    q: tasks.filter((x) => x.pending && ((x.pending.questions && x.pending.questions.length) || x.pending.approvals)).length,
    done: tasks.filter((x) => x.done).length,
  };
  return (
    <section className="view">
      <ViewHead title={all ? "Lotes" : project} sub={all ? `${snap.batches.length} lotes · lotes del orquestador y hilos de los agentes` :`${batches.length} lotes · ${tasks.length} tareas`}>
        <span className="chip tone-blue"><i className={`dot ${cnt.run ? "pulse" : ""}`} />{cnt.run} corriendo</span>
        <span className="chip tone-amber"><i className="dot" />{cnt.q} esperan</span>
        <span className="chip tone-green"><i className="dot" />{cnt.done} completadas</span>
      </ViewHead>
      {batches.length === 0 ? (
        <div className="panes"><Pane title="Lotes"><PaneEmpty title="Sin lotes" text="Aún no hay lotes en este proyecto." /></Pane></div>
      ) : (
        <div className="panes three">
          <Pane title="Lotes" count={batches.length} flush>
            <ul className="list">
              {batches.map((x) => (
                <BatchRow key={x.id} b={x} now={now} showProject={all} selected={b && b.id === x.id} onSelect={() => { setBid(x.id); setTid(null); }} />
              ))}
            </ul>
          </Pane>
          <Pane title={b ? `Tareas · ${b.id}` : "Tareas"} count={b ? `${b.tasks.filter((x) => x.done).length}/${b.tasks.length}` : null} flush>
            <ul className="list">
              {b && b.tasks.map((x) => <TaskListRow key={x.id} t={x} selected={t && t.id === x.id} onSelect={() => setTid(x.id)} />)}
            </ul>
            {b && b.notes && b.notes.length > 0 && <p className="muted small pad">{b.notes.join(" · ")}</p>}
          </Pane>
          <Pane title="Detalle" className="detail-pane">
            {b && t ? <TaskDetail key={t.id} t={t} b={b} c={c} now={now} /> : <PaneEmpty title="Selecciona una tarea" />}
          </Pane>
        </div>
      )}
    </section>
  );
}

// ---------- Actividad: línea de tiempo + detalle ----------
const EV_FILTERS = [
  ["all", "Todo", () => true],
  ["ask", "Preguntas", (e) => e.event === "pending_question" || e.event === "pending_approval"],
  ["done", "Tareas", (e) => e.event === "task_done"],
  ["batch", "Lotes", (e) => e.event === "batch_done"],
];

function Events({ snap, c, now, titles }) {
  const [f, setF] = useState("all");
  const fn = EV_FILTERS.find((x) => x[0] === f)[2];
  const events = snap.events.map((e, i) => ({ e, i })).filter((x) => fn(x.e));
  const [sel, setSel] = useState(events[0] ? events[0].i : null);
  const cur = events.find((x) => x.i === sel) || events[0];
  const e = cur && cur.e;
  let b = null, t = null;
  if (e) {
    b = snap.batches.find((x) => x.id === e.batch) || null;
    t = b && e.task ? b.tasks.find((x) => x.id === e.task) : null;
  }
  const dl = e ? Object.entries(e.delivery || {}) : [];
  return (
    <section className="view">
      <ViewHead title="Actividad" sub="Lo que Chopshop emitió y si el webhook llegó. Las URLs nunca se muestran">
        <div className="seg-ctl" role="tablist">
          {EV_FILTERS.map(([k, l]) => (
            <button key={k} role="tab" aria-selected={f === k} className={f === k ? "on" : ""} onClick={() => { setF(k); setSel(null); }}>{l}</button>
          ))}
        </div>
      </ViewHead>
      <div className="panes split-list wide">
        <Pane title="Línea de tiempo" count={events.length} flush>
          <ul className="list">
            {events.map((x) => (
              <EventItem key={x.i} e={x.e} now={now} titles={titles} selected={cur && cur.i === x.i} onSelect={() => setSel(x.i)} />
            ))}
            {events.length === 0 && <li className="muted pad">Sin eventos.</li>}
          </ul>
        </Pane>
        <Pane title="Detalle" className="detail-pane">
          {!e ? (
            <PaneEmpty title="Nada seleccionado" />
          ) : (
            <>
              <dl className="kv top">
                <dt>Cuándo</dt><dd>{clock(e.ts)} · {ago(e.ts, now)}</dd>
                <dt>Evento</dt><dd>{(EVENT_META[e.event] || { label: e.event }).label}</dd>
                {e.machine && (<><dt>Máquina</dt><dd>{e.machine}</dd></>)}
                {dl.length > 0 && (<><dt>Webhook</dt><dd>{dl.map(([k, v]) => <span key={k} className={`tag ${v === "ok" ? "ok" : "bad"}`}>{k}: {v === "ok" ? "entregado" : v}</span>)}</dd></>)}
              </dl>
              {t && b ? <TaskDetail key={t.id} t={t} b={b} c={c} now={now} /> : b ? <BatchSummary b={b} /> : <p className="muted">El lote ya no aparece en el estado de los agentes.</p>}
            </>
          )}
        </Pane>
      </div>
    </section>
  );
}


// ---------- Reacciones: tres niveles ----------
function rxEntries(snap) {
  const out = [];
  snap.batches.forEach((b) => b.tasks.forEach((t) => (t.reactions || []).forEach((r, i) => out.push({ b, t, r, k: t.id + ":" + i }))));
  out.sort((x, y) => (y.r.ts || "").localeCompare(x.r.ts || ""));
  return out;
}

function RxRow({ x, now }) {
  const { t, r } = x;
  const res = r.level === "bot" ? t.bot_wait : r.level === "human" ? t.escalation : null;
  const resolved = res && (res.done || res.status === "resolved") ? res : null;
  return (
    <li>
      <div className="row static rx-row">
        <div className="row-top">
          <Chip tone={LEVELS[r.level].tone}>{rxActionLabel(r.action)}</Chip>
          <span className="grow" />
          <span className="meta">{t.id}</span>
        </div>
        <div className="row-title">{RX_ON[r.on] || r.on}</div>
        <div className="meta ell">{cleanTitle(t)}</div>
        <div className="meta">{clock(r.ts)} · {ago(r.ts, now)}{r.note ? ` · ${oneLine(r.note, 70)}` : ""}</div>
        {resolved && <div className="rx-res">resuelta por <b>{resolved.by}</b>{resolved.choice ? <> → «{resolved.choice}»</> : null}</div>}
        {!resolved && r.level === "bot" && waitingBot(t) && <div className="rx-res wait">esperando respuesta de {t.bot_wait.notify}…</div>}
      </div>
    </li>
  );
}

function Reactions({ snap, now }) {
  const all = rxEntries(snap);
  const open = [];
  snap.batches.forEach((b) => b.tasks.forEach((t) => needsHuman(t) && open.push({ b, t })));
  const cols = ["auto", "bot", "human"];
  const resolvedH = [];
  snap.batches.forEach((b) => b.tasks.forEach((t) => t.escalation && t.escalation.status === "resolved" && resolvedH.push({ b, t })));
  return (
    <section className="view">
      <ViewHead title="Reacciones" sub="Cada evento sigue las reglas del perfil: Chopshop actúa solo, despierta al bot o escala a una persona" />
      <div className="rx">
        {(open.length > 0 || resolvedH.length > 0) && (
          <Pane title="Necesita humano" count={open.length || null} className="rx-esc">
            {open.length === 0 && <p className="muted">Nada pendiente. Resueltas: {resolvedH.length}.</p>}
            <div className="rx-cards">
              {open.map(({ b, t }) => {
                const e = t.escalation;
                const q = ((t.pending && t.pending.questions) || []).find((qq) => qq.request === e.request);
                return q ? (
                  <QuestionCard key={t.id} batch={b} task={t} q={q} since={waited(e.since, now)} by="humano" compact />
                ) : (
                  <article key={t.id} className="card question boxed compact">
                    <header className="card-head"><Chip tone="pink" pulse>Necesita humano</Chip><LevelBadge level="human" small /><span className="meta">{b.project} · {t.id}</span></header>
                    <h3 className="q-text">{e.summary}</h3>
                    <p className="note esc">{e.reason} · escalada a {e.notify}</p>
                  </article>
                );
              })}
            </div>
          </Pane>
        )}
        <div className="panes rx3">
          {cols.map((lv) => {
            const rows = all.filter((x) => x.r.level === lv);
            return (
              <Pane key={lv} title={`Nivel ${LEVELS[lv].n} · ${LEVELS[lv].label}`} count={rows.length || null} flush className={`lvl-pane lv-${lv}`}
                action={<span className="meta">{LEVELS[lv].what}</span>}>
                {rows.length === 0 ? <PaneEmpty mark="◦" title="Sin reacciones" text="Todavía no se disparó ninguna regla de este nivel." /> : <ul className="list">{rows.map((x) => <RxRow key={x.k} x={x} now={now} />)}</ul>}
              </Pane>
            );
          })}
        </div>
      </div>
    </section>
  );
}

// ---------- Máquinas: lista · métricas · hilos y alertas ----------
const HIST = 60; // muestras que guarda la app (una cada 3 s ≈ 3 min)
const fmt1 = (n) => (Math.round(n * 100) / 100).toFixed(2);
const gb = (mb) => (mb / 1024).toFixed(mb >= 10240 ? 0 : 1);
const lvl = (v, warn = 85, bad = 100) => (v >= bad ? "red" : v >= warn ? "orange" : "blue");

function Gauge({ value, label, sub, tone }) {
  const r = 34, C = 2 * Math.PI * r, v = Math.max(0, Math.min(100, value));
  return (
    <div className={`gauge tone-${tone}`}>
      <svg viewBox="0 0 88 88" aria-hidden="true">
        <circle cx="44" cy="44" r={r} className="g-track" />
        <circle cx="44" cy="44" r={r} className="g-val" strokeDasharray={`${(C * v) / 100} ${C}`} transform="rotate(-90 44 44)" />
      </svg>
      <div className="g-txt"><b>{Math.round(value)}%</b><span>{label}</span></div>
      {sub && <div className="g-sub">{sub}</div>}
    </div>
  );
}

/** Gráfica de línea con área; el eje X es tiempo (derecha = ahora). */
function Chart({ series, max = 100, unit = "%", h = 150, step, empty }) {
  const W = 300;
  const hi = Math.max(max, ...series.flatMap((s) => s.values));
  const top = hi <= max ? max : Math.ceil(hi / 50) * 50;
  const pts = (vals) => vals.map((v, i) => [W - (vals.length - 1 - i) * (W / (HIST - 1)), h - 3 - (Math.min(v, top) / top) * (h - 6)]);
  const path = (p) => (step ? p.map((q, i) => (i ? `H${q[0].toFixed(1)}V${q[1].toFixed(1)}` : `M${q[0].toFixed(1)} ${q[1].toFixed(1)}`)).join("") : p.map((q, i) => `${i ? "L" : "M"}${q[0].toFixed(1)} ${q[1].toFixed(1)}`).join(""));
  const n = Math.max(...series.map((s) => s.values.length));
  return (
    <div className="chart">
      <div className="ch-y"><span>{top}{unit}</span><span>{top / 2}{unit}</span><span>0</span></div>
      <div className="ch-plot" style={{ height: h }}>
        {n < 2 ? (
          <div className="ch-empty">{empty || "reuniendo muestras…"}</div>
        ) : (
          <>
            <svg viewBox={`0 0 ${W} ${h}`} preserveAspectRatio="none" aria-hidden="true">
              {[0, 0.5, 1].map((f) => <line key={f} x1="0" x2={W} y1={3 + f * (h - 6)} y2={3 + f * (h - 6)} className="ch-grid" />)}
              {series.map((s, k) => {
                if (s.values.length < 2) return null;
                const p = pts(s.values);
                return (
                  <g key={k} className={`tone-${s.tone}`}>
                    {s.fill !== false && <path d={`${path(p)}L${p[p.length - 1][0]} ${h}L${p[0][0]} ${h}Z`} className="ch-area" />}
                    <path d={path(p)} className="ch-line" />
                  </g>
                );
              })}
            </svg>
            {series.map((s, k) => s.values.length > 0 && (
              <i key={k} className={`ch-dot tone-${s.tone}`} style={{ top: `${((h - 3 - (Math.min(s.values[s.values.length - 1], top) / top) * (h - 6)) / h) * 100}%` }} />
            ))}
          </>
        )}
      </div>
      <div className="ch-x"><span>antes</span><span>ahora</span></div>
    </div>
  );
}

function MachineListRow({ m, selected, onSelect }) {
  const cpu = m.cpu[m.cpu.length - 1] || 0, ram = m.ram[m.ram.length - 1] || 0;
  return (
    <li>
      <button className={`row mach-row ${selected ? "sel" : ""}`} onClick={onSelect} aria-pressed={selected}>
        <div className="row-top">
          <i className={`dot tone-${m.ok ? (m.stale ? "orange" : "green") : "gray"} ${m.ok && !m.stale ? "pulse" : ""}`} />
          <b className="ell">{m.name}</b>
          <span className="grow" />
          <span className="meta">{m.ok ? `${m.cpus} núcleos` : "sin datos"}</span>
        </div>
        {m.ok && (
          <div className="bars">
            <div className="bar-line"><span>CPU</span><div className="bar"><i className={`tone-${lvl(cpu)}`} style={{ width: Math.min(100, cpu) + "%" }} /></div><b>{Math.round(cpu)}%</b></div>
            <div className="bar-line"><span>RAM</span><div className="bar"><i className={`tone-${lvl(ram)}`} style={{ width: Math.min(100, ram) + "%" }} /></div><b>{Math.round(ram)}%</b></div>
          </div>
        )}
        {!m.ok && <span className="meta ell">{m.reason || ""}</span>}
      </button>
    </li>
  );
}

function alertsFor(m) {
  const out = [];
  if (!m.ok) return [{ tone: "gray", text: "Sin datos de esta máquina", sub: m.reason }];
  const cpu = m.cpu[m.cpu.length - 1] || 0, ram = m.ram[m.ram.length - 1] || 0;
  if (cpu >= 100) out.push({ tone: "red", text: "CPU saturada", sub: `carga ${fmt1(m.load[0])} sobre ${m.cpus} núcleos (${Math.round(cpu)}%)` });
  else if (cpu >= 85) out.push({ tone: "orange", text: "CPU alta", sub: `${Math.round(cpu)}% de la capacidad` });
  if (ram >= 90) out.push({ tone: "red", text: "RAM casi llena", sub: `${gb(m.ramAvailMB)} GB libres de ${gb(m.ramTotalMB)} GB` });
  else if (ram >= 80) out.push({ tone: "orange", text: "RAM alta", sub: `${gb(m.ramAvailMB)} GB libres de ${gb(m.ramTotalMB)} GB` });
  if (m.diskPct >= 90) out.push({ tone: "red", text: "Disco casi lleno", sub: `${m.disk} (${m.diskPct}%)` });
  else if (m.diskPct >= 80) out.push({ tone: "orange", text: "Disco alto", sub: `${m.disk} (${m.diskPct}%)` });
  const i = m.info || {};
  if (i.t3_ok === false) out.push({ tone: "orange", text: "T3 no responde", sub: "el agente no logra hablar con el servidor de T3 de esta máquina" });
  if (i.last_sample_age > 60) out.push({ tone: "orange", text: "Muestreo atrasado", sub: `última muestra hace ${Math.round(i.last_sample_age)} s` });
  const cap = m.leases && m.leases.capacity;
  if (m.leases && m.leases.queued.length) out.push({ tone: "orange", text: "Servidores de prueba en cola", sub: `${m.leases.queued.length} esperando capacidad${cap && cap.max_servers != null ? ` (máx. ${cap.max_servers})` : ""}` });
  return out;
}

const mb = (v) => (v >= 1024 ? (v / 1024).toFixed(1) + " GB" : Math.round(v) + " MB");

/** Tabla de consumo por app o por proyecto (CPU 100 % = un núcleo). */
function UsageTable({ rows, cols }) {
  const top = [...rows].sort((a, b) => b.cpu_pct - a.cpu_pct || b.rss_mb - a.rss_mb).slice(0, 8);
  if (!top.length) return <p className="muted small">Sin datos todavía.</p>;
  return (
    <table className="tbl">
      <thead><tr><th>Nombre</th><th>CPU</th><th>RAM</th>{cols.map((c) => <th key={c[0]}>{c[0]}</th>)}</tr></thead>
      <tbody>
        {top.map((r) => (
          <tr key={r.name}>
            <td className="ell">{r.name}</td>
            <td>{Math.round(r.cpu_pct)}%</td>
            <td>{mb(r.rss_mb)}</td>
            {cols.map((c) => <td key={c[0]}>{c[1](r)}</td>)}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

const APP_COLS = [["Proc.", (r) => r.procs]];
const PROJECT_COLS = [["Hilos", (r) => `${r.threads_running || 0}${r.threads_pending ? ` · ${r.threads_pending}?` : ""}`], ["Serv.", (r) => `${r.leases_active || 0}${r.leases_queued ? ` +${r.leases_queued}` : ""}`]];

/** Servidores de prueba (leases) de una máquina; "Liberar" hace POST /leases/release. */
function Leases({ m }) {
  const [busy, setBusy] = useState(null);
  const [msg, setMsg] = useState(null);
  const rows = [...m.leases.active, ...m.leases.queued];
  const cap = m.leases.capacity || {};
  const release = async (l) => {
    setBusy(l.id);
    setMsg(null);
    try {
      const r = await request("leaseRelease", { agent: m.agent, lease_id: l.id });
      setMsg(r.payload);
    } catch (e) {
      setMsg({ ok: false, message: String(e.message || e) });
    }
    setBusy(null);
  };
  return (
    <>
      {cap.max_servers != null && <p className="meta pad-b">{cap.used || 0} de {cap.max_servers} servidores en uso{cap.ram_avail_mb != null ? ` · ${mb(cap.ram_avail_mb)} de RAM libres` : ""}</p>}
      {rows.length === 0 ? (
        <PaneEmpty mark="◦" title="Sin servidores de prueba" text="Los hilos los piden por MCP (chopshop_request_test_server)." />
      ) : (
        <ul className="list">
          {rows.map((l) => (
            <li key={l.id}>
              <div className="row static">
                <div className="row-top">
                  <Chip tone={l.state === "active" ? "green" : "gray"} pulse={l.state === "active"}>{l.state === "active" ? "Activo" : "En cola"}</Chip>
                  <span className="grow" />
                  <span className="meta">{l.kind === "port" ? "puerto" : "servidor"}{l.port ? ` · :${l.port}` : ""}</span>
                </div>
                <div className="row-title">{l.project}</div>
                {l.worktree && <div className="meta ell" title={l.worktree}>{l.worktree}</div>}
                <div className="detail-foot">
                  <button className="pill small" disabled={busy === l.id} onClick={() => release(l)}>{busy === l.id ? <span className="spin" /> : null}Liberar</button>
                </div>
              </div>
            </li>
          ))}
        </ul>
      )}
      {msg && <p className={`note ${msg.ok ? "ok" : "err"}`}>{msg.ok ? "Liberado." : "Error: " + msg.message}</p>}
    </>
  );
}

function Machines({ metrics, snap, sel, pick }) {
  const ms = metrics || [];
  const m = ms.find((x) => x.name === sel) || ms[0];
  const threads = [];
  if (m) snap.batches.filter((b) => b.host === m.name).forEach((b) => b.tasks.filter((t) => !t.done).forEach((t) => threads.push({ b, t })));
  const doneN = m ? snap.batches.filter((b) => b.host === m.name).reduce((n, b) => n + b.tasks.filter((t) => t.done).length, 0) : 0;
  const al = m ? alertsFor(m) : [];
  const cpu = m && m.cpu.length ? m.cpu[m.cpu.length - 1] : 0, ram = m && m.ram.length ? m.ram[m.ram.length - 1] : 0;
  return (
    <section className="view">
      <ViewHead title="Máquinas" sub="CPU, RAM y disco que reporta el agente de cada máquina · el historial de las gráficas es el de esta sesión">
        <span className="chip"><i className="dot tone-blue" />CPU</span>
        <span className="chip"><i className="dot tone-green" />RAM</span>
      </ViewHead>
      {!m ? (
        <div className="panes"><Pane title="Máquinas"><PaneEmpty title="Sin máquinas" text="La app aún no recibió métricas." /></Pane></div>
      ) : (
        <div className="panes machines">
          <Pane title="Flota" count={ms.length} flush>
            <ul className="list">{ms.map((x) => <MachineListRow key={x.name} m={x} selected={x.name === m.name} onSelect={() => pick(x.name)} />)}</ul>
          </Pane>
          <Pane title={m.name} className="metrics-pane" action={<span className="meta">{m.os || ""}{m.role ? ` · ${m.role}` : ""}</span>}>
            {!m.ok ? (
              <PaneEmpty mark="∅" title="Sin datos" text={m.reason || "esta máquina no reporta métricas"} />
            ) : (
              <div className="metrics">
                <div className="gauges">
                  <Gauge value={cpu} label="CPU" tone={lvl(cpu)} sub={`${m.cpus} núcleos`} />
                  <Gauge value={ram} label="RAM" tone={lvl(ram, 80, 90)} sub={`${gb(m.ramAvailMB)} de ${gb(m.ramTotalMB)} GB libres`} />
                  <Gauge value={m.diskPct} label="Disco" tone={lvl(m.diskPct, 80, 90)} sub={m.disk} />
                  <div className="loadbox">
                    <h5>Carga</h5>
                    <div className="load3">
                      {["1 min", "5 min", "15 min"].map((l, i) => (<div key={l}><b>{fmt1(m.load[i] || 0)}</b><span>{l}</span></div>))}
                    </div>
                  </div>
                </div>
                <h5>CPU y RAM</h5>
                <Chart series={[{ values: m.ram, tone: "green", fill: false }, { values: m.cpu, tone: "blue" }]} />
                <h5>Carga (1 min)</h5>
                <Chart series={[{ values: m.load1, tone: "blue" }]} max={Math.max(1, m.cpus)} unit="" h={96} />
                <h5>Hilos corriendo aquí</h5>
                <Chart series={[{ values: m.run, tone: "orange" }]} max={4} unit="" h={80} step empty="sin hilos en las últimas muestras" />
                <h5>Por app</h5>
                <UsageTable rows={m.apps} cols={APP_COLS} />
                <h5>Por proyecto</h5>
                <UsageTable rows={m.projects} cols={PROJECT_COLS} />
              </div>
            )}
          </Pane>
          <div className="col">
            <Pane title="Alertas" count={al.length || null} className="short">
              {al.length === 0 ? (
                <PaneEmpty title="Sin alertas" text="CPU, RAM y disco dentro de lo normal." />
              ) : (
                <ul className="alerts">
                  {al.map((a, i) => (
                    <li key={i} className={`tone-${a.tone}`}><i className="dot" /><div><b>{a.text}</b>{a.sub && <span className="meta">{a.sub}</span>}</div></li>
                  ))}
                </ul>
              )}
            </Pane>
            <Pane title="Servidores de prueba" count={m.leases.active.length + m.leases.queued.length || null} className="short"><Leases key={m.name} m={m} /></Pane>
            <Pane title="Hilos en esta máquina" count={threads.length || null} flush>
              {threads.length === 0 ? (
                <PaneEmpty mark="◦" title="Ningún hilo activo" text={`${doneN} tareas completadas aquí en total`} />
              ) : (
                <ul className="list">
                  {threads.map(({ b, t }) => (
                    <li key={t.id}>
                      <div className="row static">
                        <div className="row-top"><Chip tone={taskState(t).tone} pulse={taskState(t).pulse}>{taskState(t).label}</Chip><span className="grow" /><span className="meta">{t.id}</span></div>
                        <div className="row-title">{cleanTitle(t)}</div>
                        <div className="meta">{b.project} · {b.id}</div>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </Pane>
          </div>
        </div>
      )}
    </section>
  );
}

// ---------- Grafo de tareas ----------
const GN = { pending: ["gray", "En espera"], running: ["blue", "En curso"], expanding: ["violet", "Dividido"], done: ["green", "Listo"], failed: ["red", "Falló"], skipped: ["gray", "Omitido"] };
const GW = 218, GH = 58, GGX = 70, GGY = 14;

function graphLayout(nodes) {
  const by = {};
  nodes.forEach((n) => (by[n.id] = { ...n, kids: [] }));
  nodes.forEach((n) => n.parent && by[n.parent] && by[n.parent].kids.push(by[n.id]));
  let row = 0;
  const place = (n) => {
    if (!n.kids.length) n.row = row++;
    else { n.kids.forEach(place); n.row = (n.kids[0].row + n.kids[n.kids.length - 1].row) / 2; }
  };
  nodes.filter((n) => !n.parent).forEach((r) => place(by[r.id]));
  const list = Object.values(by);
  list.forEach((n) => { n.x = 12 + n.depth * (GW + GGX); n.y = 12 + n.row * (GH + GGY); });
  const maxD = Math.max(0, ...list.map((n) => n.depth));
  return { by, list, w: 24 + (maxD + 1) * GW + maxD * GGX, h: 24 + Math.max(1, row) * (GH + GGY) - GGY };
}

const nodeAttn = (n) => {
  const s = n.task_state;
  if (!s) return null;
  if (s.escalation === "open") return "human";
  if (s.bot_wait) return "bot";
  if (s.pending && !s.done) return "ask";
  return null;
};

function GraphNode({ n, sel, onSelect }) {
  const [tone, label] = GN[n.status] || GN.pending;
  const attn = nodeAttn(n);
  const s = n.task_state;
  return (
    <button className={`gnode tone-${tone} ${sel ? "sel" : ""} ${n.status} ${attn ? "attn-" + attn : ""} k-${n.kind}`}
      style={{ left: n.x, top: n.y, width: GW, height: GH }} onClick={() => onSelect(n.id)} aria-pressed={sel}>
      <div className="gn-top">
        <i className={`dot ${n.status === "running" ? "pulse" : ""}`} />
        <b className="gn-label">{n.label}</b>
        <span className="grow" />
        {attn === "human" ? <span className="lvl tone-pink sm">Necesita humano</span>
          : attn === "bot" ? <span className="lvl tone-violet sm">Esperando bot</span>
          : attn === "ask" ? <span className="lvl tone-amber sm">Pregunta</span>
          : s && s.level ? <LevelBadge level={s.level} small /> : null}
      </div>
      <div className="gn-title ell">{n.kind === "root" ? "Meta" : n.title}</div>
      <div className="gn-sub ell">{label}{s && s.retries ? " · reintento" : ""}{n.reason ? " · " + oneLine(n.reason, 30) : ""}</div>
    </button>
  );
}

function GraphCanvas({ g, sel, onSelect }) {
  const L = graphLayout(g.nodes);
  const edges = [];
  L.list.forEach((n) => {
    if (n.parent && L.by[n.parent]) {
      const p = L.by[n.parent];
      const x1 = p.x + GW, y1 = p.y + GH / 2, x2 = n.x, y2 = n.y + GH / 2, mx = (x1 + x2) / 2;
      edges.push(<path key={"p" + n.id} className="g-edge" d={`M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`} />);
    }
    (n.deps || []).forEach((d) => {
      const a = L.by[d];
      if (!a) return;
      const ya = a.y + GH / 2, yb = n.y + GH / 2, out = Math.min(GGX - 14, 22 + Math.abs(yb - ya) * 0.12);
      edges.push(<path key={"d" + d + n.id} className="g-dep" markerEnd="url(#garrow)" d={`M${a.x},${ya} C${a.x - out},${ya} ${n.x - out},${yb} ${n.x - 2},${yb}`} />);
    });
  });
  return (
    <div className="g-canvas" style={{ width: L.w, height: L.h }}>
      <svg width={L.w} height={L.h} className="g-svg">
        <defs>
          <marker id="garrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="var(--amber)" /></marker>
        </defs>
        {edges}
      </svg>
      {L.list.map((n) => <GraphNode key={n.id} n={n} sel={sel === n.id} onSelect={onSelect} />)}
    </div>
  );
}

const Meter = ({ label, v, warn, bad }) => (
  <div className="gm">
    <span className="gm-l">{label}</span>
    <span className="gm-bar"><i className={v >= bad ? "bad" : v >= warn ? "warn" : ""} style={{ width: Math.min(100, v || 0) + "%" }} /></span>
    <span className="gm-v">{v == null ? "—" : v + "%"}</span>
  </div>
);

const THROTTLE = { pleno: ["green", "Paralelismo pleno"], mitad: ["amber", "CPU alta: la mitad de hilos"], pausa: ["red", "Saturado: sin lanzar nuevos"], "sin-datos": ["gray", "Sin métricas: tope del host"] };

function GraphDetail({ g, n }) {
  if (!n) return <PaneEmpty mark="◦" title="Elige un nodo" text="Verás su resultado, dependencias y el hilo." />;
  const [tone, label] = GN[n.status] || GN.pending;
  const by = {};
  g.nodes.forEach((x) => (by[x.id] = x));
  const kids = g.nodes.filter((x) => x.parent === n.id && x.kind !== "triage");
  const attn = nodeAttn(n);
  const s = n.task_state;
  return (
    <div className="gd">
      <div className="gd-top">
        <Chip tone={tone} pulse={n.status === "running"}>{label}</Chip>
        {attn === "human" && <Chip tone="pink" pulse>Necesita humano</Chip>}
        {attn === "bot" && <Chip tone="violet" pulse>Esperando bot</Chip>}
        {s && s.level && <LevelBadge level={s.level} small />}
        <span className="grow" />
        <span className="meta">{n.label} · {n.id} · prof. {n.depth}</span>
      </div>
      <h3 className="gd-title">{n.title}</h3>
      {n.reason && <p className="note">{n.reason}</p>}
      {n.deps && n.deps.length > 0 && <p className="meta">Depende de: {n.deps.map((d) => (by[d] ? by[d].label : d)).join(", ")}</p>}
      {n.ask && <p className="meta">Pregunta: «{n.ask}»</p>}
      {kids.length > 0 && (
        <>
          <h5>Hijos</h5>
          <ul className="gd-kids">
            {kids.map((k) => <li key={k.id}><i className={`dot tone-${(GN[k.status] || GN.pending)[0]}`} /><b>{k.label}</b><span className="ell">{k.title}</span></li>)}
          </ul>
        </>
      )}
      {n.result && <><h5>{n.kind === "root" || kids.length ? "Resultado subido de los hijos" : "Resultado"}</h5><pre>{n.result}</pre></>}
      {n.prompt && <><h5>Prompt</h5><pre className="short">{n.prompt}</pre></>}
      <div className="detail-foot">
        {s && <span className="tag">{s.id}</span>}
        {s && s.link && <button className="pill small" onClick={() => openT3(s)}>Abrir hilo en T3</button>}
      </div>
    </div>
  );
}

function Graph({ snap, now }) {
  const graphs = snap.graphs || [];
  const [gid, setGid] = useState(null);
  const [sel, setSel] = useState(null);
  if (graphs.length === 0) {
    return (
      <section className="view">
        <ViewHead title="Grafo" sub="Tareas que crecen: una meta → un nodo por bug → hijos y dependencias" />
        <div className="panes"><Pane title="Grafos"><PaneEmpty mark="◦" title="Sin grafos" text="Crea uno con `chopshop graph new <proyecto> --bugs archivo.yaml`." /></Pane></div>
      </section>
    );
  }
  const g = graphs.find((x) => x.id === gid) || graphs[0];
  const n = g.nodes.find((x) => x.id === sel) || g.nodes.find((x) => nodeAttn(x) === "human") || g.nodes[0] || null;
  const cnt = (st) => g.nodes.filter((x) => x.status === st && x.kind !== "root").length;
  const th = g.throttle || {};
  const [tt, tl] = THROTTLE[th.mode] || THROTTLE["sin-datos"];
  const human = g.nodes.filter((x) => nodeAttn(x) === "human").length;
  const bot = g.nodes.filter((x) => nodeAttn(x) === "bot").length;
  return (
    <section className="view">
      <ViewHead title="Grafo" sub={g.goal}>
        {graphs.length > 1 && (
          <div className="seg-row">
            {graphs.map((x) => <button key={x.id} className={`pill small ${x.id === g.id ? "on" : ""}`} onClick={() => { setGid(x.id); setSel(null); }}>{x.id}</button>)}
          </div>
        )}
        <Chip tone={g.status === "running" ? "blue" : g.status === "done" ? "green" : "red"} pulse={g.status === "running"}>{g.status === "running" ? "En curso" : g.status === "done" ? "Completo" : "Falló"}</Chip>
        {g.finished && <span className="meta">{clock(g.finished)}</span>}
      </ViewHead>
      <div className="panes graph">
        <Pane title="Grafo en vivo" count={g.nodes.length} flush className="g-pane"
          action={<span className="g-legend"><i className="dot tone-blue" />en curso <i className="dot tone-green" />listo <i className="dot tone-gray" />espera <i className="dot tone-red" />falló <span className="ldep" />dependencia</span>}>
          <div className="g-scroll"><GraphCanvas g={g} sel={n ? n.id : null} onSelect={setSel} /></div>
        </Pane>
        <div className="col">
          <Pane title="Planificador" className="short g-plan">
            <div className="g-stats">
              <div><b>{cnt("running")}</b><span>en curso</span></div>
              <div><b>{cnt("pending")}</b><span>en espera</span></div>
              <div><b>{cnt("done")}</b><span>listos</span></div>
              <div><b>{cnt("failed") + cnt("skipped")}</b><span>fallidos/omitidos</span></div>
            </div>
            <div className="g-lim">
              <span>Hilos <b>{g.threads}/{g.limits.thread_budget}</b></span>
              <span>Prof. máx. <b>{g.limits.max_depth}</b></span>
              <span>Cierre <b>{g.limits.done === "ratio" ? `≥ ${Math.round(g.limits.min_ratio * 100)}%` : "todos"}</b></span>
            </div>
            <div className="g-thr"><Chip tone={tt}>{tl}</Chip>{th.allowed != null && <span className="meta">hasta {th.allowed} de {th.cap} hilos</span>}</div>
            <Meter label="CPU" v={th.cpu} warn={g.limits.throttle_cpu} bad={g.limits.stop_cpu} />
            <Meter label="RAM" v={th.ram} warn={80} bad={g.limits.stop_ram} />
            {(human > 0 || bot > 0) && <p className="note esc">{human > 0 ? `${human} nodo(s) necesitan a un humano` : ""}{human > 0 && bot > 0 ? " · " : ""}{bot > 0 ? `${bot} esperan al bot` : ""}</p>}
          </Pane>
          <Pane title={n ? `Nodo ${n.label}` : "Nodo"}><GraphDetail g={g} n={n} /></Pane>
          <Pane title="Bitácora" className="short g-log" flush>
            <ul className="g-loglist">
              {g.log.slice().reverse().map((l, i) => (
                <li key={i} className={`k-${l.kind}`}><span className="meta">{clock(l.ts)}</span><span>{l.msg}</span></li>
              ))}
            </ul>
          </Pane>
        </div>
      </div>
    </section>
  );
}

class Guard extends Component {
  constructor(p) { super(p); this.state = { e: null }; }
  static getDerivedStateFromError(e) { return { e }; }
  render() {
    if (this.state.e) return <section className="view"><p className="note err">Error al dibujar esta vista: {String(this.state.e && this.state.e.message || this.state.e)}</p></section>;
    return this.props.children;
  }
}

// ---------- estado de los agentes ----------
/** Una línea por agente con problemas (no alcanzable, 403…); si hay datos viejos, lo dice. */
function AgentBanner({ agents }) {
  const bad = (agents || []).filter((a) => a.status !== "ok" || a.warning);
  if (!bad.length) return null;
  return (
    <div className="banner-stack">
      {bad.map((a) => (
        <p key={a.name} className={`note ${a.status === "ok" ? "" : "err"} banner`}>
          <b>{a.label}</b>: {a.status === "ok" ? a.warning : a.message}
          {a.stale ? ` · mostrando datos de hace ${fmtDur(a.age)}` : ""}
        </p>
      ))}
    </div>
  );
}

function Connecting({ agents, configPath }) {
  if (agents && agents.length === 0) {
    return (
      <>
        <h3>Ningún agente configurado</h3>
        <p className="muted">Crea <code>{configPath || "~/.config/chopshop/config.toml"}</code> a partir de <code>config.example.toml</code> y define en <code>[app]</code> el <code>agent_url</code> y el <code>token_file</code> de tu agente (o varios en <code>[app.agents.&lt;nombre&gt;]</code>). Después reabre la app.</p>
      </>
    );
  }
  const bad = (agents || []).filter((a) => a.status !== "ok");
  if (bad.length) {
    return (
      <>
        <h3>No pude conectar con el agente</h3>
        {bad.map((a) => <p key={a.name} className="note err"><b>{a.label}</b>: {a.message}</p>)}
        <p className="muted">Reintento automático en cada ciclo. Comprueba que el agente corre, que Tailscale está conectado y que <code>agent_url</code> y <code>token_file</code> son correctos.</p>
      </>
    );
  }
  return <p className="muted">Conectando con los agentes…</p>;
}

// ---------- app ----------
export default function App() {
  const [snap, setSnap] = useState(null);
  const [agents, setAgents] = useState(null);
  const [configPath, setConfigPath] = useState("");
  const [view, setView] = useState("overview");
  const [project, setProject] = useState("");
  const [machine, setMachine] = useState("");
  const [metrics, setMetrics] = useState([]);
  const [now, setNow] = useState(Date.now());
  const [err, setErr] = useState(null);
  const store = useMemo(() => createStore(), []);

  useEffect(() => {
    const off = on((m) => {
      if (m.type === "agents") {
        // resultados crudos por agente (ver AgentClient.swift): se combinan aquí
        const v = store.update(m.payload.agents || []);
        setConfigPath(m.payload.configPath || "");
        setAgents(v.agents);
        setMetrics(v.machines);
        setSnap(v.hasData ? v.state : null);
        setErr(null);
      } else if (m.type === "history") {
        store.history.seed(m.payload.machines);
      } else if (m.type === "select") {
        setView(m.payload.view);
        setProject(m.payload.project || "");
        setMachine(m.payload.machine || "");
      } else if (m.type === "error") setErr(m.payload.message);
    });
    send("ready");
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => {
      off();
      clearInterval(t);
    };
  }, [store]);

  const c = useMemo(() => (snap ? collect(snap) : null), [snap]);
  const fin = useMemo(() => {
    const m = {};
    if (snap) snap.events.forEach((e) => e.event === "task_done" && e.task && !m[e.task] && (m[e.task] = e.ts));
    return m;
  }, [snap]);
  const titles = useMemo(() => {
    const m = {};
    if (snap) snap.batches.forEach((b) => b.tasks.forEach((t) => (m[t.id] = t.title)));
    return m;
  }, [snap]);
  const nav = ({ view: v, project: p = "" }) => {
    setView(v);
    setProject(p);
    send("navigate", { view: v, project: p });
  };
  const go = (v) => nav({ view: v });

  if (!snap) {
    return (
      <main className="page center">
        <div className="spin big" />
        {err && <p className="note err">{err}</p>}
        <Connecting agents={agents} configPath={configPath} />
      </main>
    );
  }
  return (
    <Ctx.Provider value={{ fin }}>
      <main className="page" key={view + ":" + project}>
        <Guard key={view + ":" + project}>
        <AgentBanner agents={agents} />
        {err && <p className="note err banner">{err}</p>}
        {view === "overview" && <Overview snap={snap} c={c} now={now} go={go} nav={nav} titles={titles} />}
        {view === "questions" && <Questions c={c} now={now} />}
        {view === "batches" && <ProjectView snap={snap} c={c} now={now} project="" />}
        {view === "project" && <ProjectView snap={snap} c={c} now={now} project={project} />}
        {view === "machines" && <Machines metrics={metrics} snap={snap} sel={machine} pick={(n) => { setMachine(n); send("navigate", { view: "machines", machine: n }); }} />}
        {view === "reactions" && <Reactions snap={snap} now={now} />}
        {view === "graph" && <Graph snap={snap} now={now} />}
        {view === "events" && <Events snap={snap} c={c} now={now} titles={titles} />}
        </Guard>
      </main>
    </Ctx.Provider>
  );
}

// Para las pruebas de renderizado (apps/ui/test): las vistas se dibujan en Node sin DOM.
export { collect, Overview, Questions, ProjectView, Machines, Reactions, Graph, Events, AgentBanner, Connecting };
