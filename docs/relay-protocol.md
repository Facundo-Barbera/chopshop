# Protocolo del agente con el backend (v2)

Cada `chopshop-agent` ligado a la cuenta del dueño abre **una** conexión WebSocket saliente al backend (`chopshop-api`,
`apps/backend`) y por ella publica su estado (snapshots por workspace y eventos, con la lista blanca de abajo) y recibe la
estructura de sus proyectos (`sync`), que vive en la nube. Los visores (app Mac, web) no hablan este protocolo: leen la ciudad
por HTTP y SSE (`GET /v1/state`, `GET /v1/stream`, ver [`backend-api.md`](backend-api.md)). Contrato de diseño:
`docs/plans/auth-backend.md` §5.8; operación y despliegue: [`relay.md`](relay.md).

Sustituye al protocolo v1 de tokens `cr1_` ([`relay-protocol-v1.md`](relay-protocol-v1.md), obsoleto, vivo solo en las fases
0–2 en el Worker viejo `chopshop-relay`). Transporte, cabecera de los frames, tamaños, cuotas, `ping`/`pong`, errores y lista
blanca son los del v1; cambian la credencial, el `hello`/`welcome`, el `workspace_id` en snapshots y eventos, los frames nuevos
y desaparece `whoami`.

Schemas (JSON Schema 2020-12, subconjunto): `packages/api/backend/hub/ws-<type>.schema.json` (`sync.ack` → `ws-sync-ack`), con
las definiciones compartidas en `packages/api/backend/common.schema.json` y el error en `packages/api/backend/error.schema.json`.
Un ejemplo válido por mensaje en `packages/api/backend/hub/fixtures/`. Los valida `python3 tools/contract_audit.py --backend`. Si
este documento y los schemas no coinciden, mandan los schemas.

## Transporte

| canal | ruta | auth |
|---|---|---|
| WebSocket | `GET /v1/connect` en `https://api.chopshop.novarix.online` (upgrade; `wss://`) | `Authorization: Bearer cm1_…` (credencial de máquina) |

- La credencial `cm1_` (`cm1_` + 43 caracteres base64url) sale de `POST /v1/machines/link` (app Mac) o `POST /v1/machines`
  (token para VPS); el agente la guarda en `~/.config/chopshop/relay/machine.json` (0600). El backend guarda solo su `sha256`.
- Una `cm1_` solo sirve en `/v1/connect`; una sesión `ss1_` no sirve en `/v1/connect` (403). Nada de cookies ni tokens en la URL.
- Respuestas del upgrade: `101`; `401 unauthorized` si la credencial falta, está mal formada, es desconocida o está revocada;
  `403 forbidden` si la máquina está pausada (desconectada por el dueño); `400 bad_request` sin cabecera `Upgrade: websocket`;
  `503 internal` si el Hub no está disponible. Todos con el cuerpo `error` de [`backend-api.md`](backend-api.md#errores).
- El agente deriva la URL del WebSocket de la base de la API (`https→wss`, ruta `/v1/connect`); una `[relay] url` que ya empiece
  por `wss://` o acabe en `/v1/connect` se usa tal cual.
- Todo cliente manda un `User-Agent` explícito (`chopshop-agent/<versión>`).
- Cada frame es **un** objeto JSON UTF-8 (texto, nunca binario) con la cabecera común
  `{"v": 2, "type": "...", "id": "<ULID>", "ts": "<ISO-8601 UTC con Z>"}`. Las respuestas llevan `re` = `id` del mensaje al que
  responden. Un frame con `v` distinto de 2, sin `id` ULID o que no sea JSON → `error` `bad_request` (sin cerrar); un `type`
  desconocido → `error` `bad_request` con `re` (sin cerrar).
- Frame máximo 1 MiB (`welcome.max_frame_bytes` = 1 048 576); cada parte opaca, máx. 768 KiB decodificada. Más → `error`
  `too_large`.
- Cuotas por conexión: 1 `snapshot` cada 5 s **por workspace**, 50 `event` por segundo; exceso → `error` `rate_limited` con
  `retry_after_s` (el frame se descarta).
- Una sola conexión por máquina: una nueva cierra la anterior (`error` `conflict` con `close: true`, cierre 4409).

### Cierres

`error` con `close: true` y a continuación cierre del WebSocket con `4000 + estado HTTP`:

| cierre | causa | qué hace el agente |
|---|---|---|
| 4400 | no llegó el `hello` en 10 s | backoff normal |
| 4401 | credencial revocada (`POST /v1/machines/{id}/revoke`) | marca «revocada», no borra `machine.json` y deja de reintentar hasta que `machine.json` cambie |
| 4403 | máquina pausada (`POST /v1/machines/{id}/pause`) o `hello` con un `machine_id` distinto del ligado | reintenta cada 600 s |
| 4408 | 90 s (tres `ping_interval_s`) sin tráfico (sin cuerpo `error`) | backoff normal |
| 4409 | otra conexión de la misma máquina la reemplazó, o el primer `hello` de un token VPS usa un `machine_id` que ya tiene otra máquina activa | reintenta cada 600 s |
| 4426 | `hello.protocol` no incluye 2 | backoff normal (actualizar el agente) |
| 4500 | el Hub perdió el estado de la conexión | backoff normal |

## Mensajes

| `type` | schema | sentido | cuándo |
|---|---|---|---|
| `hello` | `ws-hello` | agente → relay | primer mensaje, en ≤ 10 s tras el upgrade |
| `welcome` | `ws-welcome` | relay → agente | respuesta al `hello` |
| `sync` | `ws-sync` | relay → agente | justo después de `welcome` y cada vez que cambia la estructura de la máquina |
| `sync.ack` | `ws-sync-ack` | agente → relay | tras aplicar un `sync` |
| `snapshot` | `ws-snapshot` | agente → relay → visores | tras `welcome`; uno por workspace |
| `event` | `ws-event` | agente → relay → visores | tras `welcome` |
| `ping` / `pong` | `ws-ping`, `ws-pong` | ambos sentidos | cada `ping_interval_s` |
| `error` | `error` | relay → agente | ver «Cierres» y `error` |
| `import.offer` | `ws-import-offer` | agente → relay | reservado (tarea H3): oferta de importar la configuración local |
| `import.result` | `ws-import-result` | relay → agente | reservado (H3): `stored` \| `duplicate` |
| `cmd` | `ws-cmd` | relay → agente | reservado (fase de comandos, C1): orden del dueño |
| `cmd.result` | `ws-cmd-result` | agente → relay | reservado (C1): resultado de `cmd` |

Los frames reservados ya tienen schema y fixture; hasta que se implementen, el Hub responde a `import.offer` y `cmd.result` con
`error` `bad_request` («tipo de mensaje desconocido») y nunca manda `cmd` ni `import.result`.

### `hello`

`machine_id` (el `local_machine_id`: `[agent] machine_id` o el hostname; `[A-Za-z0-9_.:-]{1,128}`), `agent_version` (semver),
`protocol` (versiones que habla; debe incluir `2`), `last_seq` opcional y `projects`: `[{name, roles}]` (≤ 256 proyectos, ≤ 64
roles cada uno; nombres sin prompts ni configuración).

- Máquina ligada desde la app: `machine_id` debe coincidir con `machines.local_machine_id`; si no → `error` `forbidden` + cierre
  4403.
- Máquina creada con token para VPS (`local_machine_id = null`): el primer `hello` lo fija. Si ya hay otra máquina activa con ese
  `local_machine_id` → `error` `conflict` + cierre 4409.
- Sin `2` en `protocol` → `error` `unsupported_version` + cierre 4426.
- Un `hello` con campos mal formados → `error` `bad_request` sin cerrar (el agente puede reintentar el `hello`). Un `hello`
  repetido en la misma conexión vuelve a recibir `welcome` y el `sync` vigente.

### `welcome`

`re`, `session_id` (`ss-` + 16 hex; id de la conexión, no es una credencial), `protocol` (2), `snapshot_ttl_s` (30–900, 120 por
defecto), `max_frame_bytes`, `ping_interval_s` (30), `machine: {id, name}` (el `id` UUID de la máquina en la nube y su nombre) y
`rev` (el `structure_rev` actual). No hay `whoami`/`whoami.result` en v2.

### `sync`

La estructura que la máquina debe ejecutar, completa (sin diffs): `rev`, `machine: {id, name}`, `workspaces: [{id, name, slug}]`
(los de `workspace_machines` de la máquina) y `projects: [SyncProject]` (los de `projects.machine_id` = esta máquina, no
archivados).

`SyncProject` = `{id, name, workspace_id, title, t3_project, repo, runtime_mode, model, disabled, settings, layout, roles: [{name,
prompt, model, match_rules, wake, settings}], rev}`. `layout` lleva `floors`, `half_life`, `capacity` y `machine_rooms`;
`settings`, el resto del perfil (`rack`, reacciones, `graph`, `integration`, `automations`, `scratch`…). La equivalencia con el
perfil YAML local está en `docs/plans/auth-backend.md` §2.

- El Hub lo manda justo después de cada `welcome` y cuando una escritura de estructura (`POST/PATCH/PUT/DELETE` de workspaces,
  campus, proyectos, layouts, roles, `workspace_machines` e importaciones) afecta a la máquina: las de `projects.machine_id`
  antes y después del cambio, o todas si cambia un workspace.
- `rev` es monótono por conexión: el Hub nunca manda un `sync` con `rev` menor que el último enviado, ni repite el mismo `rev`
  salvo tras un `welcome`.
- La estructura (prompts incluidos) **baja** de la nube porque es su fuente de verdad; el agente no la edita en local: escribe
  `~/.chopshop/cloud/state.json`, materializa perfiles y prompts en `~/.chopshop/cloud/` y pasa esos proyectos a modo nube.

### `sync.ack`

`re` (el `id` del `sync`), `rev`, `applied: [nombre]` y `errors: [{project, message}]` (≤ 256 de cada; `message` de 1 a 512
caracteres, sin rutas locales ni secretos). Los errores son los de `profile.validate` del agente y se ven en `GET /v1/state`
como `city.workspaces[].projects[].sync_errors` (los del último `sync.ack` de la máquina del proyecto). Un `sync.ack` con un
campo fuera de esa lista → `error` `bad_request`.

### `snapshot`

El estado completo de la máquina **para un workspace**: el agente manda uno por workspace con los proyectos de ese workspace y,
si quedan proyectos sin migrar a la nube, uno más con `workspace_id: null`. Cada uno reemplaza al anterior del mismo
`(máquina, workspace)`. Se manda al conectar, cada vez que cambia (como mucho cada 5 s por workspace) y, aunque no cambie, al
menos cada `ttl_s / 2`.

- **Cabecera visible** (`additionalProperties: false`): `machine_id`, `workspace_id` (UUID de un workspace al que pertenece la
  máquina, o `null`; otro → `error` `forbidden`), `seq`, `ttl_s`, `agent_version`, `health`, `counts`, `projects` y `parts`.
- **`parts`** (máx. 8): sobres opacos `{name, media_type, enc, bytes, sha256, data}`, igual que en v1 (`state`, `queue`,
  `events`, `office`, `employees`; `enc` `none`, `e2e-v1` reservado). `health` es de la máquina y va igual en todos los
  snapshots de la conexión.
- **TTL**: el Hub guarda el último por `(machine_id, workspace_id)` durante `ttl_s` (recortado a 30–900, 120 por defecto) en su
  SQLite, que sobrevive a la hibernación. Pasado el TTL sin otro, la máquina sale `stale: true` en el estado y el snapshot se
  borra. El plan fija como objetivo persistir como mucho uno por minuto y par (límite de filas escritas del plan gratis); hoy se
  escribe cada snapshot aceptado (hasta uno cada 5 s por par).
- Un visor solo recibe los snapshots de los workspaces que puede ver; los de `workspace_id: null` solo el dueño.

### `event`

Como en v1 (un sobre `docs/event-envelope.md` reducido): cabecera visible `machine_id`, `workspace_id`, `event_id`, `seq`,
`event_ts`, `project`, `event_type`, `severity`, `needs`, `subject {kind, id}` y `body` (parte opaca con `name: "body"`,
filtrada por la lista blanca). `workspace_id` es el del proyecto del evento según el último `sync`, o `null` si el proyecto no
está en la nube o el evento no tiene proyecto. El Hub lo reenvía a los visores que pueden ver ese workspace y no lo guarda (solo
lo retiene en memoria, máx. 512 frames o 5 min, para reanudar un `GET /v1/stream`).

### `ping` / `pong`

Cualquier extremo manda `ping` cada `ping_interval_s`; el otro responde `pong` con `re`. El Hub también contesta `pong` al texto
literal `ping` sin despertar al Durable Object. Tres intervalos sin tráfico → cierre 4408 y la máquina queda `online: false` (sus
snapshots siguen hasta el TTL).

### `error`

`{v: 2, type: "error", id, ts, re, code, message, retry_after_s?, close?}` (schema `error`). `code` ∈ `bad_request` (400),
`unauthorized` (401), `forbidden` (403), `not_found` (404), `conflict` (409), `too_large` (413), `rate_limited` (429),
`unsupported_version` (426), `internal` (500). `close: true` avisa de que el Hub cierra a continuación con `4000 + estado`.
`message` nunca incluye credenciales, hashes ni contenido de partes opacas.

### `import.offer` / `import.result` (reservados, H3)

`import.offer {projects: [ImportPayload]}` (≤ 768 KiB): el perfil local entero como JSON, con `prompt_file` sustituido por
`prompt` (texto) y la entrada de `projects.toml` en `registry`; solo los proyectos que no vinieron en el `sync`, y solo si el
`sha256` de la oferta cambió. El Hub la guarda en `import_offers` (sin duplicar por hash) y responde `import.result {re,
import_id, status: "stored" | "duplicate"}`. Es la única subida de estructura y solo la aplica el dueño
(`POST /v1/imports/{id}/apply`).

### `cmd` / `cmd.result` (reservados, C1)

`cmd {command_id, name, args}` → `cmd.result {re, command_id, ok, status, body}` (`body` ≤ 512 KiB, sin secretos ni rutas
locales). Solo el dueño origina comandos (`POST /v1/commands`); el catálogo de `name` está en
[`backend-api.md`](backend-api.md#comandos).

## Lista blanca: lo que sale de la máquina

Regla: **todo lo que no está en esta lista se descarta en el agente antes de serializar** (deny por defecto), tanto en la
cabecera visible como dentro de las partes opacas. Que una parte sea opaca para el backend no la exime: puede acabar en
cualquier visor con acceso al workspace, watchers incluidos. La lista es la del v1 sin cambios de campos, más `workspace_id`.

| dónde | campos permitidos |
|---|---|
| `hello` | `machine_id`, `agent_version`, `protocol`, `last_seq`, `projects[].name`, `projects[].roles[]` |
| `snapshot` (visible) | `machine_id`, `workspace_id`, `seq`, `ttl_s`, `agent_version`; `health.{state, t3_ok, cpu_pct, ram_pct, disk_pct, load1}`; `counts.{running, queued, waiting, stuck, needs_human, waiting_bot, done, failed}`; `projects[].{name, roles, threads_running, threads_pending, attention}` |
| parte `state` | `threads[].{key, project, title, phase, attention, role, desk, updated}`; `attention[].{key, project, needs, summary}` |
| parte `queue` | `items[].{key, project, role, title, phase, position}` |
| parte `events` | hasta 80 eventos con la forma de `event` (cabecera + `body` filtrado como abajo) |
| parte `office` | `floors[].{name, desks[].{id, role, zone, occupant_key}}`, `company` |
| parte `employees` | `employees[].{id, project, floor, role, slot, name, state, location, thread_id, task, title, since, queue_len}`; `queues.<id empleado>.{items[].{task, title, enqueued_at, by, trigger}, updated}` (`thread_id` = `key`) |
| `event` (visible) | `machine_id`, `workspace_id`, `event_id`, `seq`, `event_ts`, `project`, `event_type`, `severity`, `needs`, `subject.{kind, id}` |
| parte `body` de `event` | `phase`, `attention`, `settled`, `title`, `role`, `summary` (máx. 280 caracteres), `state`, `light`, `status`, `conclusion`, `count`, `desk`, `reason`, `zone`; de K2: `employee`, `task`, `thread_id` (como `key`), `name`, `items[].{task, title, enqueued_at, by, trigger}`, `position`, `queue_len`, `since`, `by`, `trigger` |
| `sync.ack` | `re`, `rev`, `applied[]`, `errors[].{project, message}` |

`key` es un identificador opaco y estable por máquina (no el `thread_id` de T3 ni su URL). `title` y `summary` se truncan a
120 y 280 caracteres. Nunca salen, aunque un tipo nuevo los traiga:

- **rutas locales**: `worktree`, `cwd`, rutas de archivos, `webhook_file`, `secret_file`, `headers_file`, `db_path`, `branch`,
  `inheritance.worktree`;
- **prompts y contenido de trabajo**: el prompt de la tarea o del rol, notas de escritorio (`desk.note.text`), opciones y texto de
  preguntas (`question.opened.options`), `stdout_tail`, `error` en texto libre, `result`, `inputs`;
- **secretos e identidad**: credenciales (`cm1_`, `cs1_`, `cr1_`), códigos, hashes, URLs de webhooks, cabeceras, IPs
  (`last_ip`), logins de Tailscale, enlaces `t3-thread://`;
- procesos y aplicaciones (`apps`, `cgroups`, comandos).

Los prompts de los roles **sí** bajan en `sync` (la nube es su fuente de verdad) y solo suben en `import.offer`, que únicamente
lee el dueño. Un campo nuevo solo sale cuando se añade aquí y a su schema, en el mismo cambio.

## Diferencias con v1

| v1 (`relay-protocol-v1.md`) | v2 |
|---|---|
| `Bearer cr1_` de scope `agent`, por pairing con código de operador | `Bearer cm1_`, por login del dueño (app) o token para VPS; sin pairing |
| `GET /agent/ws` y `GET /v1/connect` en `chopshop-relay.<…>.workers.dev` | solo `GET /v1/connect` en `api.chopshop.novarix.online` |
| `v: 1`, `protocol: [1]` | `v: 2`, `protocol` incluye `2` |
| `welcome` sin máquina | `welcome` con `machine {id, name}` y `rev` |
| un snapshot por máquina | uno por `(máquina, workspace)`; `workspace_id` en snapshot y evento |
| `whoami` / `whoami.result` | no existen |
| sin canal hacia el agente | `sync` (hoy); `cmd` e `import.result` (reservados) |
| visores con `cr1_` de scope `viewer` en `GET /state` y `GET /stream` | sesiones de usuario en `GET /v1/state` y `GET /v1/stream`, filtradas por workspace |
