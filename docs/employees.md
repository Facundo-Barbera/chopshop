# Empleados y colas (contrato v1)

Un **empleado** es un escritorio permanente de la oficina: un departamento `permanent: true` del perfil
(`apps/agent/chopshop/agent/roles.py`). No tiene id propio: su id es el del escritorio que calcula `layout.desk_id`,
`<proyecto>/<piso>/<rol>/<n>` (piso y `n` desde 0), el mismo que usan `desk.*` y `office.changed`. Los escritorios flexibles
(`_flex`), extra, del vestíbulo o de contratistas (`_out`) no son empleados.

Cada empleado tiene **una cola** FIFO de tareas pendientes. Un disparador de `wake` (o un encargo manual) que encuentra el
escritorio ocupado ya no se fusiona en el despertar pendiente: entra en la cola como tarea. Al quedar libre el escritorio, la
primera tarea sale de la cola y el empleado la toma (`employee.assigned reason: queue`).

Este documento fija la forma de los datos; los schemas y ejemplos están en `packages/api/fixtures/` y los consumen el agente
(Python) y la app Mac (Swift); `@chopshop/api` aún no decodifica `employees`/`queues` (ver `docs/plans/contract-audit.md`).

## Ids

| id | forma | ejemplo |
|---|---|---|
| empleado | id de escritorio de `layout.desk_id` | `awesome-gb/0/triage/0` |
| tarea de cola | `q:` + `id` (ULID) del sobre `task.enqueued` que la creó | `q:01MCC5Y3S0F8YH6PV8TEN7BD00` |

Cuando la tarea arranca, su hilo de T3 sigue con su propio id (`thread_id`) y el ciclo de vida del hilo lo cuenta
`task.state` como siempre; la tarea de cola solo vive hasta que se asigna o se cancela.

## Snapshot

`GET /snapshot` gana dos campos aditivos (los clientes viejos los ignoran):

```json
{
  "employees": [
    {"id": "awesome-gb/0/triage/0", "project": "awesome-gb", "floor": 0, "role": "triage", "slot": 0,
     "name": "Tría", "state": "working", "thread_id": "mcp:c41f", "task": "q:01MCC5Y3S0F8YH6PV8TEN7BD00",
     "title": "Triage #212 · login falla en Safari", "since": "2027-01-15T09:12:00.000Z", "queue_len": 1}
  ],
  "queues": {
    "awesome-gb/0/triage/0": {"items": [{"task": "q:…", "title": "…", "enqueued_at": "…", "by": "triage-bot",
                                         "trigger": "desk.note"}], "updated": "2027-01-15T09:12:00.000Z"}
  }
}
```

| campo | qué es |
|---|---|
| `employees[]` | un elemento por escritorio permanente no retirado, en el orden de `layout.desks` (piso, departamento, `n`). |
| `employees[].name` | nombre visible; `null` = sin nombre (la UI muestra el rol). Lo cambia `employee.renamed`. |
| `employees[].state` | `idle` (escritorio libre) · `working` (hay un hilo sentado). |
| `employees[].location` | dónde se dibuja: `desk` si está `working`, `common` (área común) si está `idle`. Derivado de `state`; opcional para los clientes (si falta, se deriva igual). |
| `employees[].thread_id`, `task`, `title`, `since` | hilo actual (o el último si está `idle`), tarea de cola que lo originó (`null` si vino de un despertar directo o manual), su título y desde cuándo está en el estado actual. |
| `employees[].queue_len` | largo de su cola (`= len(queues[id].items)`). |
| `queues` | `{id de empleado: {items, updated}}`; todo empleado tiene clave (cola vacía = `items: []`, `updated: null` si nunca cambió). `items` va en orden de ejecución, con la forma de `queue.changed`. |

## Eventos

Todos van en el sobre v1 (`docs/event-envelope.md`), con `needs: null`. Los `employee.*` y `queue.changed` tienen
`subject {kind: "desk", id: <empleado>, title: <nombre o rol>}`; los `task.*`, `subject {kind: "task", id: <tarea de cola>}`.
Como todos los sobres, el cuerpo es el estado completo del sujeto: perder o repetir un evento se arregla con el siguiente o
con el snapshot.

| tipo | cuándo | severidad |
|---|---|---|
| `employee.assigned` | un hilo se sienta en el escritorio permanente. Se emite junto a `desk.assigned` (que sigue siendo la fuente del mapa de la oficina), con `cause` = ese `desk.assigned`. | info |
| `employee.idle` | el escritorio queda libre y no hay tarea de cola que tomar (o el tope `max_wakes_per_hour` la retiene). | info (`failed` → warn) |
| `employee.renamed` | cambia `name` (perfil, UI o bot). | info |
| `queue.changed` | cualquier cambio de la cola: entra, sale para asignarse, se cancela, se reordena o se vacía. Lleva la cola entera. | info |
| `task.enqueued` | una tarea entra en la cola de un empleado. Le sigue un `queue.changed reason: enqueued` con `cause` = este sobre. | info |
| `task.cancelled` | una tarea de cola se cancela antes de arrancar (`phase: queued`) o se corta en marcha (`phase: running`). Si estaba en cola, le sigue un `queue.changed reason: cancelled`. | info |

Campos del cuerpo (obligatorios en **negrita**; los extra se permiten):

| tipo | cuerpo |
|---|---|
| `employee.assigned` | **employee**, **role**, **thread_id**, **task** (`null` si no viene de la cola), **reason** (`wake, queue, manual, inherited`), name, title, since, queue_len |
| `employee.idle` | **employee**, **role**, **reason** (`done, failed, cancelled, released, retired`), **thread_id** (el último o `null`), **since**, name, summary, queue_len |
| `employee.renamed` | **employee**, **role**, **name** (`null` = quitar nombre), **previous**, **by** (`profile`, `human` o nombre del bot) |
| `queue.changed` | **employee**, **items** `[{task, title, enqueued_at, by, trigger}]`, **reason** (`enqueued, dequeued, cancelled, reordered, cleared`), task (la tarea que provocó el cambio) |
| `task.enqueued` | **task**, **employee**, **title**, **position** (0 = la próxima), **by** (quién la encargó: tipo del evento disparador, `human` o nombre del bot), trigger, enqueued_at |
| `task.cancelled` | **task**, **employee**, **phase** (`queued, running`), **by**, **reason** (`manual, superseded, retired, expired`), thread_id (si estaba en marcha), note |

Orden típico: `task.enqueued` → `queue.changed (enqueued)` → … → `queue.changed (dequeued)` → `desk.assigned` →
`employee.assigned (queue)` → `task.state` del hilo → `desk.released` → `employee.idle` (o el siguiente `employee.assigned`).

Quién emite cada uno fuera del despachador (herramientas del MCP de Chopshop, mismo bus que el agente):

- `task_cancel {task, reason?, note?, by?}`: si la tarea sigue en cola, `task.cancelled phase: queued` + `queue.changed
  reason: cancelled`. Si ya salió de la cola y su hilo está vivo, interrumpe el hilo (`t3_thread_interrupt`, nunca archiva),
  marca la tarea del motor terminada (el empleado queda libre para el despachador) y emite `task.cancelled phase: running` con
  `thread_id`, sin `queue.changed` (la cola no cambió). En su próxima pasada el despachador hace settle del hilo y libera el
  escritorio con `employee.idle reason: cancelled`. Si la tarea aún no tiene hilo o ya terminó, error.
- `employee_rename {employee, name, by?}`: `employees.rename` (`name: null` quita el nombre; el nombre queda fijado y el
  perfil ya no lo pisa) y `employee.renamed` con `by` del llamador (`human` por defecto o el nombre del bot).

## Fixtures

```
packages/api/fixtures/
  schemas/<tipo>.schema.json     JSON Schema 2020-12 del sobre completo de cada tipo (autocontenido)
  schemas/snapshot.schema.json   employees[] y queues{} del snapshot (el resto del snapshot no se valida)
  events/<tipo>.json             un sobre de ejemplo por tipo (oficina de office-fixture: empleado awesome-gb/0/triage/0)
  snapshot.employees.json        employees[] y queues{} de ejemplo
```

Los ejemplos además pasan `envelope.errors` del agente, que valida el sobre y, con la entrada de cada tipo en
`envelope.SCHEMAS`, los campos obligatorios del cuerpo.
