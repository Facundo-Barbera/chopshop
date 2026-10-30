# Sobre de eventos (v1)

Un solo formato para todo lo que emite `chopshop-agent`: la tabla `events` (SQLite), `GET /events`, `/snapshot.events`, el
webhook de los bots y, después, SSE (`/stream`) y las automatizaciones. Código: `apps/agent/chopshop/agent/envelope.py`.
Secuencia realista de 3 proyectos para la app: `apps/mac/Sources/ChopshopNative/Resources/ui-fixture.jsonl`.

## Sobre

```json
{
  "v": 1,
  "id": "01M646XHEM0W40J2GB1G6GW3RG",
  "seq": 1842,
  "ts": "2026-10-29T16:12:03.412Z",
  "machine": "contabo-dev",
  "project": "nuskills",
  "type": "task.state",
  "severity": "info",
  "needs": null,
  "subject": {"kind": "task", "id": "mcp:a03694e5", "title": "BUG-3 · Racha se reinicia", "url": "t3-thread://v2/..."},
  "cause": {"id": null, "depth": 0},
  "body": {}
}
```

| campo | qué es |
|---|---|
| `id` | ULID (26 caracteres, base32 de Crockford): único global y ordenable por tiempo. Clave de idempotencia para bots y scripts. |
| `seq` | contador monotónico **por máquina** (cursor de `?after=` y, en SSE, de `Last-Event-ID`). |
| `ts` | ISO-8601 UTC con milisegundos y `Z` (en SQLite sigue en epoch). |
| `severity` | `info` · `notice` · `warn` (trabado o degradado) · `error` (falló o no puede seguir). |
| `needs` | quién tiene que actuar: `null` · `human` · `bot` · `approval`. Un evento posterior del mismo sujeto con `needs: null` cierra la atención. |
| `subject` | `{kind, id, title?, url?}`; `kind` ∈ `task, batch, node, graph, thread, machine, pr, issue, automation, agent, desk, office, repo, run, listener`. |
| `cause` | `id` del evento que lo provocó y `depth` (0 = raíz). Anti-bucles: `emit_envelope` descarta todo evento con `depth > 3`. |
| `project` | nombre del proyecto o `null` (eventos de máquina/agente). |
| `body` | **estado completo del sujeto** (upsert idempotente: se puede perder, repetir o reordenar un evento y el siguiente lo arregla). |

Mientras dure la compatibilidad (un ciclo), `GET /events`, `/snapshot.events` y el webhook añaden además los campos viejos
`event` (nombre viejo o, si no lo hay, el tipo) y `machine_id`, y `body.legacy` lleva el nombre viejo traducido.

## Tipos

| tipo | sujeto | `needs` / `severity` por defecto | cuerpo (campos obligatorios en **negrita**) |
|---|---|---|---|
| `task.state` | task | según `attention` / info (`failed` → error) | **phase** (`queued, preparing, running, waiting, done, failed, skipped, settled`), **attention** (`null, ask, approval, human, bot`), **thread_id**, **settled**, title, batch, node, t3status, link, worktree, branch, pull_requests, level, retry_of, result, error, role, ended_at, touched_at, summary |
| `question.opened` | task | human (bot si la reacción es `bot`) / notice | **thread_id**, **request_id**, **summary**, **options**, **multi_select**, level, notify, reply, escalate_after_s |
| `question.answered` | task | null / info | **thread_id**, **request_id**, **choice**, **by** (`human`, nombre del bot o `auto`), latency_s |
| `approval.requested` | task | approval / notice | **thread_id**, **count**, **note** |
| `batch.created`, `batch.done` | batch | null / info | **batch**, **host**, **tasks** `{id: estado}`, max_parallel, notes |
| `graph.state` | graph | null / info | **graph**, **status**, **nodes** `[{id,label,phase,deps,task}]`, goal |
| `node.state` | node (`<grafo>/<nodo>`) | null / info (failed → error) | **graph**, **node**, **phase**, label, deps, task, reason |
| `graph.done` | graph | null / info (failed → error) | **graph**, **status**, batch, summary, result |
| `reaction.applied` | task | null / info (human → notice) | **on**, **level** (`auto, bot, human`), **action**, task, note |
| `machine.health` | machine | null / info (degraded → warn) | **state** (`ok, degraded, down`), **t3_ok**, cpu_pct, ram_pct, disk_pct, load, threads_running, agent_version, down_seconds |
| `github.issue.opened/updated/closed`, `github.pr.opened/updated/merged/review`, `github.ci.completed`, `github.push` | issue / pr | null / info | **repo**, **action**, number, title, url, actor, labels, head, base, state, ci, etag_source |
| `automation.ran` | automation | null / info (exit ≠ 0 → error) | **automation**, **trigger**, **exit**, **duration_ms**, **error**, trigger_event, emitted, stdout_tail, truncated, next_run |
| `desk.assigned` | desk | null / info | **desk**, **thread_id**, **role**, **reason** (`start, inherited, manual, wake`), inheritance `{thread_id, title, summary, branch, worktree, pull_requests, phase, ended_at}`, since, notes_pending, title |
| `desk.released` | desk (o thread si `desk: null`) | null / info | **desk** (null = sale del vestíbulo), **thread_id**, **reason** (`faded, inherited, retired, manual`) |
| `desk.waiting` | thread | null / info | **thread_id**, **role** (en el vestíbulo esperando escritorio), title, phase |
| `desk.note` | desk | null / info | **desk**, **from**, **text** (truncado a 2 KB), pending (notas sin consumir tras esta), expires |
| `office.changed` | office | null / info | **project**, **by** (`profile`, nombre del bot), **floors** (forma de `office.floors` de `GET /state` sin ocupantes), company, half_life_s, machine_rooms (salas de máquinas del perfil: `[{name, floor, repos, listeners, automations, subscriptions}]`, `[]` si ninguna), diff `{added, retired, reactivated}` |
| `forge.repo.state` | repo (`<proveedor>:<repo>`) | null / info (red → warn) | **provider**, **repo**, **light** (`green, amber, red, gray`), project, kind, label, default_branch, ci, url, error |
| `forge.run.state` | run (`<proveedor>:<repo>#<run_id>`) | null / info (failure → warn) | **provider**, **repo**, **run_id**, **workflow**, **status** (`queued, in_progress, completed`), **event**, **origin** `{kind: thread\|automation\|bot\|schedule\|human\|unknown, id, label}`, conclusion, actor, head_branch, head_sha, url, created_at, updated_at, project |
| `forge.dispatch` | run (`<proveedor>:<repo>#<nonce>`) | null / info | **provider**, **repo**, **workflow**, **ref**, nonce, inputs (lo emite una automatización: es el único tipo reservado que un script puede emitir) |
| `listener.state` | listener | null / info (degraded → warn, down → error) | **name** (`t3watch`, `forge` (eventos de GitHub), `rack`, `actions`, `webhooks`, `automations`, `collector`, `engine`, `office`, `halflife`, `roles`), **state** (`ok, degraded, down`), last_ok, last_cycle, backoff_s, error, heartbeat (true = latido sin cambio; no se entrega por webhook salvo suscripción con `heartbeats`) |
| `agent.started` | agent | null / info | **version** |

`task.state` gana (aditivo) `role` (rol de la oficina o `null` = vestíbulo), `ended_at` y `touched_at` (ISO, para la
semivida) y `summary` (resumen final). Los `github.*` se mantienen un ciclo junto a los `forge.*` genéricos.

Los tipos fuera de la tabla (p. ej. `triage.result` de una automatización) solo validan el sobre. Los campos extra del
cuerpo se permiten. `envelope.validate(sobre)` lanza `EnvelopeError` con todos los problemas; `envelope.errors(sobre)`
los devuelve como lista.

## Nombres viejos

`events.emit(conn, cfg, event, project, body)` conserva su firma: traduce con `envelope.LEGACY_MAP` y guarda el sobre.
El cuerpo nuevo es un superconjunto del viejo.

| viejo | nuevo |
|---|---|
| `thread_started`, `thread_done`, `thread_failed`, `thread_settled`, `task_done` | `task.state` (con `phase`) |
| `pending_question` | `question.opened`, precedido de un `task.state` con `phase: waiting` y `attention` |
| `pending_approval` | `approval.requested`, precedido de un `task.state` con `attention: approval` |
| `batch_done` | `batch.done` |
| `graph_exception`, `graph_done` | `node.state` (`phase: failed`/`skipped`), `graph.done` |
| `reaction` | `reaction.applied` |
| `t3_unreachable`, `t3_recovered` | `machine.health` (`degraded` / `ok`) |
| `agent_started` | `agent.started` |
| otro nombre sin punto | `legacy.<nombre>` |

## Quién emite

- **t3watch** (hilo `t3`): transiciones de hilos de T3. Una pregunta lleva `needs: bot` si la regla `reactions`
  `on: pending_question` del perfil del proyecto tiene `level: bot` (si no, `human`).
- **Motor** (`engine.tick`, `reactions`, `graph`): reciben un `emit_fn` (firma de `chopshop.events.emit`). Dentro del agente
  corre en el hilo `engine` (cada `agent.engine_interval` s, solo si hay lotes con trabajo en `<home>/state.json`) con el
  puente `service.engine_emitter`, que guarda el sobre en el bus y además escribe `events.jsonl` y avisa a las suscripciones
  de `state.json` como siempre. La CLI suelta sigue escribiendo `events.jsonl`; el agente lo importa cada
  `agent.legacy_interval` s (idempotente: desplazamiento + deduplicación por `ts`, nombre y proyecto).
- **Respuestas**: `question.answered` al responder por la CLI (`chopshop answer`, `engine.answer`/`answer_inline`) y por
  `POST /answer` (`by` opcional en el cuerpo; si falta, el login de quien responde o `human`).
- **Tipos nuevos**: `events.emit_envelope(conn, cfg, type, project, body, subject=, severity=, needs=, cause=)` valida y
  devuelve el sobre guardado (o `None` si `cause.depth > 3`).

## SQLite (esquema v3)

`events` conserva sus columnas (`seq, ts, machine_id, event, project, body`) y gana `id` (índice único), `type`, `severity`,
`needs`, `subject_kind`, `subject_id`, `subject` (JSON), `cause_id`, `cause_depth`. La migración desde v2 rellena las filas
existentes traduciendo el nombre viejo y es idempotente.
