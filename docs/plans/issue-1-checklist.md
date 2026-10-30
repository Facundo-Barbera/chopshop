# Borrador: checklist del issue #1 (empleados, colas, hilos cortos)

Estado al 2026-10-30, sobre `dev` (merge de E12). Borrador para actualizar el issue a mano: aquí no se tocó GitHub. Cada punto
cita la rama o el archivo que lo respalda. `[x]` = hecho y con tests; `[~]` = hecho en parte o sin probar en la instalación
real; `[ ]` = pendiente.

## Tareas

- [~] **Emparejar la máquina Linux remota (hoy 401) con la app y el MCP de la Mac mini.** Ya existe el camino por el relay
  (`chopshop relay pair`, `docs/relay.md` «Pairing»), que no necesita Tailscale. Falta hacerlo en la máquina real y confirmar
  que la app la ve. El `pair`/`mcp pair` por Tailscale sigue igual (sin cambios en esta ola).
- [x] **Registro de proyectos, roles y colas de punta a punta.** Registro `projects.toml` (`agent/registry.py`, E3), herramientas
  MCP `registry_list`, `project_register`, `role_list` (E3, E15), empleados (E4), colas (E5, E7), despachador (E8, E14),
  `task_cancel` en marcha y `employee_rename` (E15). Verificado en E12.
- [x] **Prueba real con 3-4 roles** (triage, QA, release, docs): `docs/plans/real-run.md` (E12), 8 tareas por MCP, 2 hilos vivos
  como máximo, todas con settle. Se hizo con un agente y un MCP de prueba, no con el LaunchAgent instalado.
- [x] **Distribución estable de oficinas.** Índices de piso estables para temporales (4-7) y contratista (8-11) (E6, E6b);
  mundo estable en la app (M4).

## Criterio de hecho

- [ ] **Chopshop usable en la Mac mini con la versión Release en `/Applications`, sin modo dev.** No verificado: E12 corrió
  fuera de la instalación real. Falta: publicar una release con estos cambios (`docs/release.md`), instalarla, activar
  `[agent.dispatcher] enabled = true` en el agente real y repetir la prueba de E12 con el MCP real.

## Depende del relay (#2)

- [x] **Roles por el relay:** `hello.projects[].roles` (A2, A4).
- [x] **Colas y estado de empleados en el snapshot del relay:** parte `employees` y campos K2 en el `body` de los eventos (A6,
  BUG-4 de K4 resuelto). La app los pinta desde `GET /state` del relay (M10).
- [~] **Emparejar la máquina Linux por token del relay.** Mecanismo listo: código con `POST /v1/pair/codes` (operador), canje con
  `POST /v1/pair` y `chopshop relay pair --stdin`. No hay `chopshop relay join <código>`: el canje se hace con `curl`.
  Pendiente hacerlo en la máquina real.
- [ ] **MCP servido desde Cloudflare para despachar tareas.** No se hizo: el relay es de solo lectura por diseño
  (`relay-protocol.md` «Puntos de contacto con #1»). El MCP sigue en `chopshop mcp serve` de la mini.
- [ ] **Quién emite los webhooks a los bots.** Sin cambios: los emiten los agentes y `mcp/hooks.py` de la mini; el relay no
  emite webhooks. Falta cerrar la decisión en el issue.
- [~] **Dirigir y ver la oficina desde el portátil vía relay.** Ver: sí (visor con token `viewer`, M5, M6, M10). Dirigir: no
  (depende del punto del MCP).

## Avanza en paralelo

- [x] **Modelo local de roles, pool de nombres, colas y slots** (`chopshop/employees.py`, `chopshop/names.py`,
  `chopshop/queue.py`; pool local en `~/.chopshop/names/<proyecto>.yaml`).
- [x] **Registro local de proyectos** (`projects.toml` junto al `config.toml`).
- [x] **Hilos cortos con settle:** el despachador hace settle al terminar cada tarea (E11, E14).
- [x] **Distribución estable de oficinas** (ver arriba).
- [x] **Prueba real con 3-4 roles** (E12, ver arriba).
- [ ] **Criterio de hecho** (ver arriba).

## Fallos abiertos que tocan a #1

- E12 BUG-3: un perfil sin `model` en un proyecto de T3 sin modelo por defecto hace fallar todas las tareas de la cola; ni
  `profile check` ni `task_enqueue` avisan.
- E12 BUG-4: `task_enqueue` no acepta `prompt`; el título hace de prompt y la app lo trunca.
- E12 BUG-5 (menor): `ChopshopSnap employees` no dice nada con un JSON de `/snapshot`.
- K4 BUG-10: un visor del relay no ve `online`/`stale` por máquina en `GET /state`.
- Notas de E12: la `key` de `task_enqueue` devuelve la tarea vieja aunque haya terminado; hay hasta 5 s con «0 vivos» entre que
  se saca una tarea y se sienta.
