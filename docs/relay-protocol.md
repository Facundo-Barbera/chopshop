# Protocolo del relay (v1)

El relay es un Cloudflare Worker que deja ver el estado de varias máquinas desde fuera de la tailnet sin abrir el agente a
internet. Cada `chopshop-agent` abre una conexión saliente al relay y publica un **snapshot** (cabecera en lista blanca + partes
opacas) y sus **eventos**; los visores (app de Mac, web) se conectan al mismo relay y **solo leen**. El relay no ejecuta nada,
no habla con T3 y no interpreta las partes opacas.

Schemas (JSON Schema 2020-12): `packages/api/relay/<mensaje>.schema.json`, con las definiciones compartidas en
`common.schema.json` (`$id` base `https://schemas.chopshop.local/relay/v1/`). Un ejemplo válido por mensaje:
`packages/api/relay/fixtures/<mensaje>.json`. Si este documento y los schemas no coinciden, mandan los schemas.

## Transporte

| canal | ruta | auth |
|---|---|---|
| WebSocket | `GET /v1/connect` (upgrade; alias exacto de `GET /agent/ws`) | `Authorization: Bearer cr1_…` con scope `agent` |
| HTTP JSON | `GET /whoami` | `Bearer cr1_…` (`agent` o `viewer`) → `{role, machine_id}` |
| HTTP SSE / JSON | `GET /stream`, `GET /state` | `Bearer cr1_…` con scope `viewer` |
| HTTP JSON | `POST /v1/pair/codes` | token de operador (ver «Pairing») |
| HTTP JSON | `POST /v1/pair` | sin credencial (el código es la credencial) |
| HTTP JSON | `DELETE /v1/tokens/<token_id>`, `DELETE /v1/pair/codes/<id>` | token de operador |
| HTTP JSON | `GET /health` | pública (no mira la credencial) |

Todo cliente envía un `User-Agent` explícito (el agente: `chopshop-agent/<versión>`): Cloudflare responde 403 al de Python por defecto (`Python-urllib/3.x`).

### Rutas por rol

El rol sale de la cabecera `Authorization`: sin cabecera → `anónimo`; token de operador → `admin`; `cr1_` de scope `viewer` →
`viewer`; `cr1_` de scope `agent` → `machine`. Una cabecera mal formada o un token inválido/revocado → **401** antes de mirar la
ruta. Un `viewer` recibe **403** en **cualquier** método que no sea `GET` (`POST`, `PUT`, `DELETE`, `PATCH`…), exista o no la ruta.

| ruta | anónimo | viewer | machine | admin |
|---|---|---|---|---|
| `GET /health` | 200 | 200 | 200 | 200 |
| `GET /whoami` | 401 | 200 `{role: "viewer", machine_id: null}` | 200 `{role: "machine", machine_id}` | 403 |
| `GET /stream`, `GET /state` | 401 | 200 | 403 | 403 |
| `GET /agent/ws`, `GET /v1/connect` | 401 | 403 | 101 (upgrade) | 403 |
| `POST /v1/pair` | 200 | 403 | 403 | 403 |
| `POST /v1/pair/codes` | 401 | 403 | 403 | 200 |
| `DELETE /v1/tokens/<token_id>`, `DELETE /v1/pair/codes/<id>` | 401 | 403 | 403 | 204 |
| cualquier otra ruta, o `PUT`/`PATCH` en las de arriba | 404 / 405 | 403 | 404 / 405 | 404 / 405 |

Los 200/204/101 son el caso feliz: la ruta puede seguir respondiendo 400, 404, 410 o 429 por su propia validación. Un método
distinto en una ruta que el rol sí puede usar → 405 con `Allow`. Los 401/403 llevan cuerpo `error` (`unauthorized`/`forbidden`).
El relay no tiene `POST /pair` (ese es el canje `cs1_` de la API del agente, `docs/agent-api.md`): aquí cae en «cualquier otra
ruta» → 404; el canje del relay es solo `POST /v1/pair`.

- Cada frame del WebSocket es **un** objeto JSON UTF-8 (texto, nunca binario) con la cabecera común
  `{"v": 1, "type": "...", "id": "<ULID>", "ts": "<ISO-8601 UTC con Z>"}`. Las respuestas llevan `re` = `id` del mensaje al que
  responden. Un `type` desconocido → `error` `bad_request` (sin cerrar).
- Frame máximo 1 MiB (`welcome.max_frame_bytes`); cada parte opaca, máx. 768 KiB decodificada. Más → `error` `too_large`.
- Límites por conexión de agente: 1 `snapshot` cada 5 s, 50 `event` por segundo; exceso → `error` `rate_limited` con
  `retry_after_s`. Un visor no tiene cuota de escritura porque no escribe.
- Sin credencial o con una inválida/revocada, el upgrade responde **401** con un cuerpo `error` (`unauthorized`). Revocar un token
  cierra sus WebSockets abiertos (`error` con `close: true` y luego cierre 4401).
- No hay cookies, ni CORS con credenciales, ni tokens en la URL (no acaban en logs de acceso).

## Mensajes

| mensaje (`type`) | schema / fixture | sentido | quién puede enviarlo |
|---|---|---|---|
| `hello` | `hello` | agente → relay | solo scope `agent`; primer mensaje obligatorio |
| `welcome` | `welcome` | relay → agente | respuesta al `hello` |
| `snapshot` | `snapshot` | agente → relay → visores | solo scope `agent`, después de `welcome` |
| `event` | `event` | agente → relay → visores | solo scope `agent`, después de `welcome` |
| `ping` / `pong` | `ping`, `pong` | ambos sentidos | todos |
| `whoami` / `whoami.result` | `whoami`, `whoami-result` | agente → relay → agente | solo por el WebSocket (scope `agent`); un visor usa `GET /whoami` |
| `error` | `error` | relay → cliente (también cuerpo de errores HTTP) | relay |
| pairing (HTTP) | `pair-create`, `pair-code`, `pair-redeem`, `pair-token` | ver «Pairing» | ver «Pairing» |

### `hello`

Lo primero que manda el agente tras el upgrade (en ≤ 10 s; si no, `error` `bad_request` + cierre):
`machine_id` (mismo patrón que en el agente: `[A-Za-z0-9_.:-]{1,128}`), `agent_version` (semver), `protocol` (versiones que habla,
p. ej. `[1]`), `last_seq` opcional (último `seq` del bus local, para que el visor sepa si se perdió algo) y `projects`:
`[{name, roles}]` con los proyectos configurados y los **roles** de la oficina de cada uno (nombres, sin prompts ni configuración).

- Un token de agente queda atado al `machine_id` con el que se emparejó: otro `machine_id` → `error` `forbidden` + cierre.
- Sin versión común → `error` `unsupported_version` + cierre.
- Una segunda conexión del mismo `machine_id` reemplaza a la primera (la vieja recibe `error` `conflict` con `close: true`).

### `welcome`

`re`, `session_id`, `protocol` (la elegida: 1), `snapshot_ttl_s` (TTL efectivo, 30–900), `max_frame_bytes` y `ping_interval_s`.

### `snapshot`

El estado completo de la máquina, reemplaza al anterior (sin diffs). El agente lo manda al conectar, cada vez que cambia (como
mucho cada 5 s) y, aunque no cambie, al menos cada `ttl_s / 2`.

- **Cabecera visible** (el relay la lee para listar máquinas y para `whoami.result`): `machine_id`, `seq`, `ttl_s`,
  `agent_version`, `health`, `counts`, `projects`. Todos sus campos están en la lista blanca y el schema la cierra con
  `additionalProperties: false`.
- **`parts`**: sobres opacos `{name, media_type, enc, bytes, sha256, data}`. `data` es base64 de un JSON (`media_type`
  `application/json`); `bytes` y `sha256` son del contenido decodificado (el visor descarta la parte si no coinciden).
  `name` ∈ `state` (hilos y atención), `queue` (hilos T3 en fase `queued`, ver «Puntos de contacto con #1»), `events`
  (últimos eventos), `office` (pisos y escritorios), `employees` (empleados y sus colas de K2, ver abajo). `enc`: `none` en v1; `e2e-v1` queda reservado para cifrado extremo a extremo entre agente y
  visor (el relay no cambia: ya hoy no decodifica `data`).
- **Parte `employees`**: `{employees[], queues{}}` con la forma de `GET /snapshot` de la API del agente
  (`docs/employees.md`, `packages/api/fixtures/schemas/snapshot.schema.json`), filtrada por la lista blanca: `thread_id` sale
  como `key` opaca (la misma que `occupant_key` de `office` y `key` de `state`), `location` siempre presente, y `title`, `name`,
  `by` o `trigger` pueden llegar `null` si el filtro los vacía. Cada cola, máx. 100 tareas. Sin perfiles con escritorios
  permanentes la parte va con listas vacías; un agente sin K2 no la manda.
- **TTL**: el relay guarda **solo el último snapshot por máquina**, durante `ttl_s` (el agente propone; el relay lo recorta a
  30–900 s y por defecto usa 120). Pasado el TTL sin otro snapshot, la máquina sale como `stale: true` en `whoami.result` y el
  snapshot se borra; al reconectar un visor recibe el último snapshot vivo de cada máquina de su cuenta. No hay historial.

### `event`

Un sobre v1 (`docs/event-envelope.md`) reducido: la cabecera visible lleva `machine_id`, `event_id` (el `id` ULID del sobre),
`seq`, `event_ts`, `project`, `event_type`, `severity`, `needs` y `subject {kind, id}` (**sin** `title` ni `url`); el `body` del
sobre viaja como una parte opaca con `name: "body"`, ya filtrada por la lista blanca. El relay reenvía el evento a los visores
conectados de la cuenta y **no lo guarda** (solo lo retiene en memoria, máx. 512 frames o 5 min, para reanudar un `GET /stream`
con `Last-Event-ID`; el estado que sobrevive es el snapshot; el `body` es estado completo, así que perder
un evento no rompe nada: el siguiente lo arregla).

### `ping` / `pong`

Cualquier extremo manda `ping` cada `ping_interval_s` (30 s por defecto); el otro responde `pong` con `re`. Tres intervalos sin
tráfico → el relay cierra la conexión y la máquina queda `online: false` (su snapshot sigue hasta el TTL).

### `whoami` / `whoami.result`

`whoami` (sin campos) → `whoami.result`: `token_id`, `scope` (`agent` | `viewer`), `account`, `token_name`, `machine_id` (el atado
al token de agente; `null` en un visor) y `machines` (`[{machine_id, online, snapshot_age_s, stale}]` de toda la cuenta; para un
agente, solo la suya). Nunca devuelve el token ni su hash.

### `error`

`{v, type: "error", id, ts, re, code, message, retry_after_s?, close?}`. `code` ∈ `bad_request` (400), `unauthorized` (401),
`forbidden` (403), `not_found` (404), `gone` (410), `conflict` (409), `too_large` (413), `rate_limited` (429),
`unsupported_version` (426), `internal` (500). En HTTP es el cuerpo de la respuesta con ese código de estado; en el WebSocket,
`close: true` avisa que el relay cierra a continuación (código de cierre `4000 + estado HTTP`, p. ej. 4401, 4403). `message` es
legible y nunca incluye tokens, códigos, hashes ni contenido de partes opacas.

## Visor (HTTP)

Un visor (token `viewer`) no abre WebSocket: lee por HTTP. Ninguna de estas respuestas lleva tokens, hashes ni IPs.

| ruta | respuesta | schema / fixture |
|---|---|---|
| `GET /whoami` | `{role, machine_id}`: `role` ∈ `viewer` (con `machine_id: null`) \| `machine` (con el `machine_id` atado al token de agente). Es el rol de «Rutas por rol», no el `scope` de `whoami.result` | `whoami-http` |
| `GET /state` | `{v, type: "state", id, ts, head, machines[], snapshots[]}` | `state` |
| `GET /stream` | SSE (`text/event-stream`), ver abajo | `stream-hello` (primer frame) |

- **`GET /state`**: `machines[]` = `{machine_id, seq, snapshot_age_s, expires_at}` de cada máquina de la cuenta con snapshot
  vivo (dentro de su TTL), ordenadas por `machine_id`; `snapshots[]` = esos snapshots tal como los mandó el agente (schema
  `snapshot`). `head` es la posición actual del stream (`<época>-<n>`, ver abajo): un visor puede pedir `GET /state` y luego abrir
  `GET /stream` con `Last-Event-ID: <head>` para seguir sin huecos. Una máquina con el snapshot caducado no aparece. `/state` no
  dice si una máquina está conectada (`online`) ni distingue «caducada» de «nunca vista» (BUG-10 en `docs/plans/contract-audit.md`).
- **`GET /stream`**: SSE de la cuenta del token. Empieza con `retry: 3000` y un `event: hello` cuyo `data` es
  `{v, type: "hello", ts, head, resume}` (schema `stream-hello`; se llama como el `hello` del agente pero es otro mensaje y no
  lleva `id`). Después:
  - `resume: "events"` si el visor mandó `Last-Event-ID` (o `?after=`) de esta misma época y el relay aún retiene lo que siguió
    (máx. 512 frames o 5 min): se reenvían esos frames con su `id`.
  - `resume: "snapshot"` en otro caso: un `event: snapshot` por máquina con snapshot vivo, todos con `id: <head>`.
  - En vivo: `event: snapshot` o `event: event`, con `id: <época>-<n>` y `data` = el frame del agente tal cual (schemas
    `snapshot` y `event`).
  - Latido `: ping` (comentario SSE) cada 15 s. La época (8 símbolos Crockford) cambia cuando se reinicia el relay; un `id` de
    otra época cuenta como desconocido y da `resume: "snapshot"`.
  - Máx. 64 visores por relay; más → 429 `rate_limited` con `Retry-After`.

## Lista blanca: lo que sale de la máquina

Regla: **todo lo que no está en esta lista se descarta en el agente antes de serializar** (deny por defecto), tanto en la
cabecera visible como dentro de las partes opacas. Que una parte sea opaca para el relay no la exime: el relay es un tercero y
las partes pueden acabar en cualquier visor de la cuenta.

| dónde | campos permitidos |
|---|---|
| `hello` | `machine_id`, `agent_version`, `protocol`, `last_seq`, `projects[].name`, `projects[].roles[]` |
| `snapshot` (visible) | `machine_id`, `seq`, `ttl_s`, `agent_version`; `health.{state, t3_ok, cpu_pct, ram_pct, disk_pct, load1}`; `counts.{running, queued, waiting, stuck, needs_human, waiting_bot, done, failed}`; `projects[].{name, roles, threads_running, threads_pending, attention}` |
| parte `state` | `threads[].{key, project, title, phase, attention, role, desk, updated}`; `attention[].{key, project, needs, summary}` |
| parte `queue` | `items[].{key, project, role, title, phase, position}` |
| parte `events` | hasta 80 eventos con la forma de `event` (cabecera + `body` filtrado como abajo) |
| parte `office` | `floors[].{name, desks[].{id, role, zone, occupant_key}}`, `company` |
| parte `employees` | `employees[].{id, project, floor, role, slot, name, state, location, thread_id, task, title, since, queue_len}`; `queues.<id empleado>.{items[].{task, title, enqueued_at, by, trigger}, updated}` (`thread_id` = `key`) |
| `event` (visible) | `machine_id`, `event_id`, `seq`, `event_ts`, `project`, `event_type`, `severity`, `needs`, `subject.{kind, id}` |
| parte `body` de `event` | `phase`, `attention`, `settled`, `title`, `role`, `summary` (resumen final, máx. 280 caracteres), `state`, `light`, `status`, `conclusion`, `count`, `desk`, `reason`, `zone`; de K2: `employee`, `task`, `thread_id` (como `key`), `name`, `items[].{task, title, enqueued_at, by, trigger}`, `position`, `queue_len`, `since`, `by`, `trigger` |

`key` es un identificador opaco y estable por máquina (no el `thread_id` de T3 ni su URL). `title` y `summary` se truncan a
120 y 280 caracteres. Nunca salen, aunque un tipo nuevo los traiga:

- **rutas locales**: `worktree`, `cwd`, rutas de archivos, `webhook_file`, `secret_file`, `headers_file`, `db_path`, `branch`
  (puede delatar rutas o nombres internos), `inheritance.worktree`;
- **prompts y contenido de trabajo**: el prompt de la tarea o del rol, notas de escritorio (`desk.note.text`), opciones y texto de
  preguntas (`question.opened.options`), `stdout_tail`, `error` en texto libre, `result`, `inputs`;
- **secretos e identidad**: tokens, credenciales `cs1_`/`cr1_`, códigos de pairing, hashes, URLs de webhooks, cabeceras, IPs
  (`last_ip`), logins de Tailscale, enlaces `t3-thread://`;
- procesos y aplicaciones (`apps`, `cgroups`, comandos).

Un campo nuevo solo sale cuando se añade aquí y a su schema, en el mismo cambio.

## Pairing

Modelo: `apps/agent/chopshop/agent/pairing.py`, con un prefijo de token propio (`cr1_`, no `cs1_`: son credenciales distintas y
una no sirve en el otro sitio).

1. **Crear código**: `POST /v1/pair/codes` con `{scope, name?, ttl_s?}` (`pair-create`). Solo lo pide el operador con el token
   de operador (ver «Deploy»); un token `cr1_` (`agent` o `viewer`) recibe 403. Respuesta (`pair-code`): `{id, code, scope, name, expires_at}`. El código
   (`K7QM-93XD`: 8 símbolos base32 de Crockford, 40 bits) se muestra **una sola vez**; TTL por defecto 600 s, máx. 3600 s. El
   relay guarda solo `sha256(sal + ":" + código)`, la sal, el scope, la cuenta y las fechas.
2. **Canjear**: `POST /v1/pair` con `{code, client_name?, machine_id?}` (`pair-redeem`), sin credencial. El código se normaliza como
   en el agente (sin guiones ni espacios, mayúsculas, `O→0`, `I/L→1`). `machine_id` es obligatorio si el código es de scope
   `agent` (el token queda atado a esa máquina) y se ignora en `viewer`. Respuesta (`pair-token`):
   `{token_id, token: "cr1_<43 car. base64url>", scope, machine_id, protocol}`: 32 bytes aleatorios; **el relay guarda solo
   `sha256(token)`** y lo devuelve una única vez. El cliente lo guarda en su llavero (agente: archivo 0600 o Keychain; Mac: Keychain).
3. **Fallos**: código usado, caducado o invalidado → 410 `gone`; inválido → 401 `unauthorized`; 5 fallos por minuto por IP → 429
   `rate_limited`; cada fallo cuenta contra todos los códigos vivos de la cuenta y a los 20 se invalidan. Comparación en tiempo
   constante. Re-emparejar el mismo `machine_id` emite un token nuevo y revoca el anterior.
4. **Uso**: `Authorization: Bearer cr1_…` en el upgrade de `/v1/connect` (agente) o en `/stream`, `/state` y `/whoami` (visor). Sin expiración automática; `last_seen_at` se escribe
   como mucho una vez por minuto. **Revocar**: `DELETE /v1/tokens/<token_id>` con el token de operador (efecto inmediato, cierra sus WebSockets).

Nunca se registran ni se devuelven códigos, tokens ni hashes (salvo el código o el token recién emitidos, a quien los pidió).

## Puntos de contacto con #1

- **`hello` lleva proyectos y roles**: la lista `projects[].roles` es la de `office.roles` de cada perfil; el relay solo la usa
  para mostrar qué hay en cada máquina. Cambiar los roles de un proyecto = el agente reconecta o manda otro `hello` en la misma
  conexión (el relay acepta un `hello` repetido con el mismo `machine_id` y actualiza la lista).
- **Las colas viajan como partes opacas del snapshot**: `parts[name=queue]` son los hilos T3 en fase `queued`;
  `parts[name=employees]` lleva las colas de K2 por empleado (`queues{}`) y los eventos `employee.*`, `queue.changed` y `task.*`
  conservan sus campos K2 en el `body`. El relay no conoce su forma ni las ordena; las pinta el visor.
- **El MCP despacha local, no por el relay**: lanzar, responder, asentar o asignar sigue siendo del MCP/agente en la propia
  máquina (o de la API del agente en la tailnet). El protocolo no tiene ningún mensaje de escritura hacia el agente; el relay
  nunca reenvía órdenes.
- **El visor es solo lectura**: un token `viewer` no abre WebSocket; solo hace `GET /stream`, `GET /state` y `GET /whoami`, y
  cualquier otro método → 403 `forbidden` (ver «Rutas por rol»).

## Deploy

El Worker del relay **solo se despliega por GitHub Actions**, con los secrets del repositorio `CLOUDFLARE_API_TOKEN` y
`CLOUDFLARE_ACCOUNT_ID`, al empujar un tag de release o al hacer merge a `main`. **Nunca desde una máquina local**: nada de
`wrangler deploy` ni `wrangler secret put` a mano; las máquinas de desarrollo no tienen esas credenciales. El token de operador
(admin: emite códigos con `POST /v1/pair/codes` y revoca con `DELETE /v1/tokens/<token_id>` o `DELETE /v1/pair/codes/<id>`, en
cualquier cuenta) es el secret del Worker `RELAY_OPERATOR_TOKEN`, un binding de entorno que nunca está en el repo. Su valor se
crea una sola vez al hacer el primer deploy (R7) y se guarda como secret del repositorio con el mismo nombre,
`RELAY_OPERATOR_TOKEN`; el workflow `.github/workflows/relay-deploy.yml` lo carga en cada deploy con el input `secrets` de
`wrangler-action` (equivale a `wrangler secret put RELAY_OPERATOR_TOKEN` leyendo la variable de entorno, sin imprimirla). El
Worker lo compara por SHA-256 en tiempo constante; sin el secret, nadie puede crear códigos ni revocar. Un código creado
por el operador abre una cuenta nueva (`ac-…`) salvo que la petición lleve `?account=ac-…` para añadir a una existente.
