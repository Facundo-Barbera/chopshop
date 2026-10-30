# K4: auditoría cruzada de contratos (K1 relay, K2 empleados)

Base: `origin/dev` @ 38b391d (olas 1 y 2, E11, R6, M8) · 2026-10-30.

Contratos auditados: **K1** = `docs/relay-protocol.md` + `packages/api/relay/` (schemas y ejemplos); **K2** = `docs/employees.md`
+ `packages/api/fixtures/` (schemas y ejemplos). Si el documento y los schemas no coinciden, mandan los schemas.

## Método

- Lectura del código de cada tarea contra cada mensaje y ruta (mapa tarea → archivos abajo).
- Salidas **reales** del agente: `python3 tools/contract_audit.py` levanta un `AgentService` en un directorio temporal (sin T3 ni
  red), recorre un escenario de empleado y cola (sentar un hilo en un escritorio permanente, encolar dos tareas, cancelar una,
  renombrar, terminar el hilo, liberar el escritorio, sacar de la cola) y valida con JSON Schema 2020-12:
  - K2: `employees`/`queues` de `GET /snapshot` (con el empleado `working` y luego `idle`) y cada sobre `employee.*`,
    `queue.changed`, `task.*` del bus (E9);
  - K1: `hello`, `snapshot` y los 15 `event` que arma `relaysync` (A2) para el relay;
  - los ejemplos de `packages/api/relay/fixtures/`, `packages/api/fixtures/events/` y `packages/api/fixtures/snapshot.*.json`.
- Resultado con los arreglos de esta tarea: **todo valida** (`ok`). Antes de los arreglos fallaban
  `snapshot.office.json` (ULID con la letra `O`) y `location` de un empleado `working` (ver F1 y F4).
- No se ejecutó: el Worker contra Cloudflare real (sin credenciales) ni la app de Mac (Linux). Para el Worker hay revisión de
  código y `tsc --noEmit`; para la app, revisión de código.

| tarea | archivos |
|---|---|
| A2 | `apps/agent/chopshop/relaysync.py` (mapeo a `hello`/`snapshot`/`event` y lista blanca) |
| A3 | `apps/agent/chopshop/relaycfg.py` (`chopshop relay pair/status/unpair`, `[relay] url`) |
| A4 | `apps/agent/chopshop/agent/relay.py` (`RelayLink`: WebSocket, `hello`→`welcome`, envío, ping) |
| E9 | `agent/service.py` (`_employee_event`, `employees_sync`, `_emit_queue`), `agent/projection.py`, `employees.py`, `queue.py` |
| E11 | `apps/agent/chopshop/dispatcher.py` (`close`: asentar y cerrar), `queue.finish` |
| R3 | `packages/relay/src/pair.ts` (pairing, revocación) |
| R4 | `packages/relay/src/agentws.ts` (WebSocket del agente) |
| R5 | `packages/relay/src/viewer.ts` (`GET /stream` SSE, `GET /state`) |
| R6 | `packages/relay/src/routes.ts` + `index.ts` (rutas por rol, `GET /whoami`) |
| M2 | `apps/mac/Sources/ChopshopUI/AgentClient.swift` (`fetchRelaySnapshot`, `RelayView`) |
| M3 | `apps/mac/Sources/ChopshopNative/Live/LiveStateEmployees.swift` |
| M5 | `apps/mac/Sources/ChopshopUI/RelayLogin.swift` |
| M6 | `AgentClient.swift` (`AgentRole`, `ActGate.canAct`) |
| M7 | `ChopshopNative/Office/FloorPlan.swift` (`employee` por escritorio), `FloorRender.swift` |
| M8 | `ChopshopNative/Shell/ShellPanels.swift` (`ShellEmployeePanel`, cola) |

Veredictos: **OK** = emisor, receptor y decodificador coinciden con el contrato · **OK\*** = coincide, con nota · **BUG-n** =
diferencia sin arreglar (abajo, con tarea sugerida) · **F-n** = diferencia arreglada en esta tarea · **conocido** = ya cubierto
por otra tarea, no se toca aquí.

## K1: mensajes del WebSocket

| mensaje | emite | acepta | decodifica | validación real | veredicto |
|---|---|---|---|---|---|
| `hello` | A2 `relaysync.hello`, enviado por A4 al conectar | R4 `AgentSockets.hello`: `machine_id` = el del token, `protocol` ∋ 1, `agent_version`, `projects` | R4 (guarda proyectos y roles con `touchMachine`) | A2 ✓ | **OK\***: A4 no reenvía `hello` si cambian los roles; solo al reconectar (el contrato admite las dos cosas). |
| `welcome` | R4 | A4 `_welcome` | A4: `snapshot_ttl_s`, `ping_interval_s`, `session_id` | forma del código = schema | **OK** |
| `snapshot` | A2 `relaysync.snapshot` vía A4 (al conectar, si cambia, y cada `ttl/2`) | R4 (`machine_id`, `seq`, cuota 5 s; no valida el resto) → R5 lo guarda y lo reparte por `/stream` y `/state` | M2 `RelayView.machineSnapshot` (decodifica `parts` y verifica `bytes`/`sha256`) | A2 ✓ | **conocido** (BUG-1: M2 no llega a recibirlo) + **BUG-4** (K2 no viaja) + **F6**. Nadie en la app lee `parts` después de decodificarlas. |
| `event` | A2 `relaysync.event` vía A4 (hasta 40 por tick) | R4 (cuota 50/s) → R5 `/stream` | nadie (M2 ignora `event`) | A2 ✓ (15 tipos) | **OK\*** en el relay; **BUG-4** (los cuerpos K2 salen vacíos) + **F6**. |
| `ping` / `pong` | A4 manda `ping` JSON cada `ping_interval_s` y contesta `pong` con `re`; R4 contesta `pong` con `re` | R4, A4 | A4 (cualquier frame cuenta como tráfico) | forma del código = schema | **OK**. R4 nunca inicia `ping` JSON (solo autorrespuesta al texto `"ping"`); A4 lo cubre. |
| `whoami` | M2 y M5 (frame por el WebSocket con token `viewer`) | R4 solo a scope `agent`; un `viewer` recibe 403 en el upgrade | — | — | **conocido** (BUG-1). Doc corregida (F7): por WebSocket es solo del agente; el visor usa `GET /whoami`. |
| `whoami.result` | R4 (`scope: "agent"`, `machines` = la propia) | — | M2 (`machines`, `role ?? scope`), M5 (`scope`, `account`) | forma del código = schema | **conocido** (BUG-1, BUG-2). A4 no lo usa. |
| `error` | R3, R4, R5, R6 (cuerpo HTTP y frame) | — | A4 (`retry_after_s` → espera, `close` → reconecta), M2/M5 (`code` → estado) | forma del código = schema | **OK\***: los 404/405 de rutas son texto plano, no `error` (el contrato solo exige `error` en 401/403). |

## K1: pairing (HTTP)

| mensaje | emite | acepta | decodifica | veredicto |
|---|---|---|---|---|
| `pair-create` (`POST /v1/pair/codes`) | operador (`curl` con `RELAY_OPERATOR_TOKEN`); ningún cliente del repo | R3 `createCode` (`onlyKeys`, `scope`, `name`, `ttl_s` 1–3600), solo `admin` por R6 | — | **OK** |
| `pair-code` | R3 | — | operador | **OK** (`rc-` + 8 hex, código Crockford `XXXX-XXXX`) |
| `pair-redeem` (`POST /v1/pair`) | **ninguno en el repo**: A3 recibe el token ya emitido (`--stdin`/`--token-file`), M5 pide pegar el `cr1_` | R3 `redeem` (normaliza el código, `machine_id` obligatorio en `agent`) | — | **OK\*** (sin cliente; alias `/pair` retirado, BUG-9) |
| `pair-token` | R3 (`token_id`, `token`, `scope`, `machine_id`, `protocol: 1`) | — | nadie | **OK\*** (sin cliente) |
| revocación (`DELETE /v1/tokens/<id>`, `/v1/pair/codes/<id>`) | operador | R3 + R6 (`admin`) | — | **F5** (el WebSocket del agente revocado no se cerraba) + **BUG-8** (el SSE del visor revocado sigue abierto) |

## K1: rutas del relay

Convención de URL distinta en cada lado: el agente usa `[relay] url` **tal cual** como endpoint del WebSocket (el ejemplo de
`config.example.toml` termina en `/v1/connect`); la app de Mac guarda la **base** y le añade `/v1/connect`
(`AgentClient.swift:204`). Pegar en la Mac la misma URL que en el agente da `/v1/connect/v1/connect` → 404.

| ruta | Worker (R3–R6) | agente (A3/A4) | app de Mac (M2/M5/M6) | doc K1 | veredicto |
|---|---|---|---|---|---|
| `GET /v1/connect` | alias exacto de `/agent/ws`, rol `machine` → 101 | A4 conecta a `[relay] url` (ejemplo: `/v1/connect`) con `Bearer cr1_` de scope `agent` | M2 `fetchRelaySnapshot` y M5 `RelayLogin.whoami` lo abren con token `viewer` → **403** | ✓ | agente **OK**; Mac **conocido** (BUG-1) |
| `GET /agent/ws` | `AGENT_WS_PATH`, igual que arriba | nadie | nadie | ✓ (alias) | **OK** (sin uso) |
| `GET /whoami` | R6: `viewer`/`machine` → `{role, machine_id}`; `admin` → 403 | nadie | nadie (usa el frame `whoami` por WebSocket) | ✓; **sin schema** | **conocido** (BUG-1) + BUG-3 |
| `GET /stream` | R5: SSE, solo `viewer` | nadie | nadie (el `/stream` de la Mac es el de la API del agente) | ✓ ruta; **formato sin contrato** | BUG-3 |
| `GET /state` | R5: `{v, type: "state", id, ts, head, machines[], snapshots[]}`, solo `viewer` | nadie | nadie | ✓ ruta; **cuerpo sin contrato** | BUG-3 |
| `POST /v1/pair` | R3, solo `anónimo` | nadie | nadie | ✓ | **OK\*** (sin cliente) |
| `POST /pair` | retirado en R9 → 404 | nadie | nadie | ✓ (sin alias) | **OK** (BUG-9 resuelto) |
| `POST /v1/pair/codes`, `DELETE /v1/tokens/<id>`, `DELETE /v1/pair/codes/<id>` | R3 + R6, solo `admin` | A3 `unpair` solo lo menciona | nadie | ✓ | **OK** |
| `GET /health` | antes de mirar la credencial | nadie | nadie | ✓ | **OK** |

**Nombres de rol.** Scope del token: `agent` | `viewer`. Rol de R6 y de `GET /whoami`: `anonymous` | `viewer` | `machine` | `admin`.
`whoami.result` (WebSocket): `scope: agent | viewer`. M6 `AgentRole` espera `agent` | `viewer` y lee `role ?? scope`
(`AgentClient.swift:45`): un `role: "machine"` de `GET /whoami` no se reconoce (`nil`) y `canAct` queda en `true`. → **conocido** (BUG-2).

**Nombres compartidos con la API del agente** (`docs/agent-api.md`): `/stream` y `/state` existen en las dos con
semántica distinta (sobres v1 vs. frames K1). Las rutas del relay solo se distinguen por el host. `POST /pair` ya es solo del
agente (código `cs1_` con `device_id`); el relay canjea en `POST /v1/pair` (código `cr1_` con `machine_id`) y responde 404 a
`POST /pair` desde R9 (BUG-9).

## K2: snapshot

| campo | emite | acepta / reparte | decodifica | validación real | veredicto |
|---|---|---|---|---|---|
| `employees[]` | E9: `employees.roster` (perfil + proyección + escritorios ocupados) en `GET /snapshot`, `GET /state` y el `hello` de `/stream` del agente | API del agente (local/Tailscale) | M3 `readEmployees`, M7 `FloorPlan` (empleado por escritorio), M8 `ShellEmployeePanel` | ✓ (`working` e `idle`) | **OK**; no viaja por el relay (**BUG-4**) |
| `employees[].location` | E9 (`employees.entry`/`roster`, desde E10) | — | nadie (M3/M7 deciden por `state`) | antes: `common` también con `working` | **F1**: solo estaba en el código y era constante; ahora `desk`/`common` derivado de `state`, documentado y en el schema como opcional |
| `queues{}` | E9: `Queue.snapshot` (todo empleado tiene clave) | API del agente | M3, M8 (lista de la cola) | ✓ | **OK**; no viaja por el relay (**BUG-4**) |
| `@chopshop/api` | — | — | **no decodifica** `employees`/`queues` (la doc decía que sí) | — | **F7** (doc corregida) |

## K2: eventos

Todos se validaron contra su schema y contra `envelope.errors` (que ya tiene los tipos K2 en `envelope.SCHEMAS`; la doc decía
que no: F7). Por el relay (A2) todos salen con `subject.id` = empleado o tarea, pero el cuerpo pierde los campos K2 (**BUG-4**).

| tipo | emite | acepta | decodifica | validación real | veredicto |
|---|---|---|---|---|---|
| `employee.assigned` | E9 `_employee_event` tras cada `desk.assigned` de un escritorio permanente | bus + `/stream` | E9 `projection._apply_employee`, M3 `applyEmployees` | ✓ | **BUG-5**: `task` siempre `null` y `reason` nunca `queue`. Nota: los `desk.assigned` con `reason` `start`/`return`/`overflow` se publican como `manual`. |
| `employee.idle` | E9 tras `desk.released` (salvo `inherited`) | bus + `/stream` | E9, M3 | ✓ | **OK** (E11 cierra la tarea con `queue.finish`, sin sobre propio; el `employee.idle` llega por el `desk.released`) |
| `employee.renamed` | E9 `employees_sync` (`by: profile`) | bus + `/stream` | E9, M3 | ✓ | **BUG-7**: no hay ruta ni herramienta MCP que llame a `employees.rename`, así que nunca sale con `by: human` o un bot |
| `queue.changed` | `queue.py` vía E9 `_emit_queue`; MCP (E7) | bus + `/stream` | E9, M3, M8 | ✓ | **F2** (`subject.title` faltaba) + **F3** (el MCP no emitía). Nunca sale con `reason` `reordered`/`cleared` (`clear` cancela una a una). |
| `task.enqueued` | `queue.enqueue` vía E9; MCP `task_enqueue` | bus + `/stream` | E9, M3 | ✓ | **F3** (el MCP no emitía) |
| `task.cancelled` | `queue.cancel` vía E9; MCP `task_cancel` | bus + `/stream` | E9, M3 | ✓ | **F3**; **BUG-6**: nunca sale `phase: running` |

## Arreglos hechos aquí

- **F1** `employees.py`: `location` era `"common"` para todos, también con `working` (E9 reemplazó la proyección de E10 y se
  perdió el cambio a `desk`). Ahora se deriva de `state` en `roster`; `docs/employees.md` y `snapshot.schema.json` lo documentan
  como opcional (`desk` | `common`).
- **F2** `queue.py`: `queue.changed` salía con `subject` sin `title`; K2 pide «nombre o rol». Ahora lleva el rol (la cola no
  conoce el nombre).
- **F3** `mcp/tools.py`: `task_enqueue` y `task_cancel` del MCP creaban `Queue` sin `emit_fn`: la cola cambiaba en la DB, pero
  no salía `task.enqueued`, `queue.changed` ni `task.cancelled`, y la Mac (M3/M8) no se enteraba hasta recargar el estado. Ahora
  escriben en el bus con el mismo `machine_id` (el `/stream` del agente revisa la DB por si otro proceso escribió).
- **F4** `packages/api/fixtures/snapshot.office.json`: dos `q:` con la letra `O` (no es Crockford) no validaban el schema.
- **F5** `packages/relay/src/index.ts` + `agentws.ts`: `DELETE /v1/tokens/<id>` no cerraba el WebSocket del agente, aunque K1
  lo promete. Ahora manda `error unauthorized` con `close: true` y cierra con 4401.
- **F6** `agent/relay.py`: margen frente a las cuotas del relay. A4 revisaba el snapshot cada 5,0 s y mandaba 50 eventos por
  tick, justo en el límite (1 snapshot cada 5 s, 50 eventos/s medidos al llegar): con jitter de red salía `rate_limited` y el
  evento rechazado se perdía (el cursor ya avanzó). Ahora son 6 s y 40.
- **F7** documentación: en `relay-protocol.md`, `whoami` por WebSocket es solo del agente y el relay retiene eventos en memoria
  (512 frames o 5 min) para reanudar `/stream`. En `employees.md`, `@chopshop/api` aún no consume K2 y `envelope.SCHEMAS` ya
  cubre los tipos nuevos.
- `tools/contract_audit.py`: el validador de arriba, para repetir la auditoría.

## Pendientes

- **BUG-1** (conocido, lo cubre otra tarea) M2/M5 usan el WebSocket `/v1/connect` con token `viewer` → 403. Además M2 espera
  que el relay le empuje `snapshot` por ese socket, cosa que el Worker nunca hace. El reparto a sockets `viewer:<cuenta>` de
  `AgentSockets.broadcast` (`agentws.ts`) es código muerto, porque ningún visor puede abrir WebSocket. Para arreglarlo:
  `GET /whoami` para M5 y `GET /state` (o `GET /stream`) para M2, y unificar la convención de URL con el agente (base o
  endpoint).
- **BUG-2** (conocido, lo cubre otra tarea) M6 `AgentRole` = `agent | viewer`; `GET /whoami` devuelve `role: machine | viewer`.
- **BUG-3** Las respuestas del visor no tienen contrato: `GET /whoami` (`{role, machine_id}`), `GET /state`
  (`{v, type: "state", id, ts, head, machines[{machine_id, seq, snapshot_age_s, expires_at}], snapshots[]}`) y el SSE de
  `/stream` (`retry`, `event: hello` con `{v, type: "hello", ts, head, resume}`, que se llama como el `hello` del agente pero
  tiene otra forma y no lleva `id`; luego `event: snapshot|event` con `id: <época>-<n>`; latido `: ping`). Tampoco hay forma de
  ver `online`/`stale` de cada máquina desde un visor (solo `whoami.result`, que es del agente). *Tarea chica (K1b)*:
  `whoami-http`, `state` y `stream-hello` `.schema.json` con sus ejemplos, una sección «Visor (HTTP)» en K1 y `online`/`stale`
  en `state.machines[]`. Conviene hacerla antes que M2/M5, que van a decodificar esto.
- **BUG-4** K2 no cruza el relay: el `snapshot` de A2 no tiene parte de empleados ni colas (su parte `queue` son los hilos
  T3 en fase `queued`, no la cola de K2), y la lista blanca del cuerpo (`relaysync.BODY_KEYS`) descarta `employee`, `task`,
  `thread_id`, `name`, `items`, `position`, `queue_len`, `since`, `by` y `trigger`. Un visor por relay no puede pintar empleados
  ni colas. *Tarea chica (A5)*: parte opaca `employees` (`employees[]` sin `thread_id`, o con `key(thread_id)`, más `queues{}`)
  y los campos K2 del cuerpo, añadidos a la tabla «Lista blanca» de K1, al enum de `part.name` en `common.schema.json` y a
  `BODY_KEYS`, en el mismo cambio. El relay no cambia.
- **BUG-5** `employee.assigned` nunca sale con `reason: queue` ni con `task: q:…` (`service.py:368` pone `task=None`, y
  `EMPLOYEE_ASSIGN` no tiene `queue`). El `Dispatcher` (E8/E11) no está instanciado en el servicio, y cuando lo esté, el
  `desk.assigned` del hilo lanzado no sabe de qué tarea vino. *Tarea chica (dentro de E14, cableado del despachador)*: pasar
  `qtask` de la tarea del lote a `office.assign` / al cuerpo de `desk.assigned` y mapearlo a `reason: queue`, `task`.
- **BUG-6** `task.cancelled` con `phase: running` no tiene camino: `queue.cancel` solo acepta tareas en cola. *Tarea chica*: que
  `task_cancel` del MCP acepte una tarea `dequeued` con hilo vivo, interrumpa el hilo y emita `phase: running` con `thread_id`.
- **BUG-7** `employee.renamed` con `by: human`/bot: `employees.rename` no tiene llamador. *Tarea chica*: herramienta MCP
  `employee_rename` (o ruta de la API) que llame a `rename` y emita el sobre como `employees_sync`.
- **BUG-8** Revocar un token `viewer` no cierra su `GET /stream` abierto (R5 no guarda el `token_id` de cada visor). *Tarea
  chica*: guardar `tokenId` en `Viewer` y cerrarlo desde el caso `revoke` de `index.ts`, igual que F5.
- **BUG-9** (decisión; **resuelto en R9**: se retiró el alias, el relay responde 404 a `POST /pair`) El alias `POST /pair`
  del relay comparte nombre con `POST /pair` de la API del agente (`cs1_`, `device_id`). Un cliente que apunte al host equivocado recibe `400 campos desconocidos` en vez de un error claro. *Sugerencia*:
  retirar el alias (no lo usa nadie) o documentar la diferencia en los dos contratos.
