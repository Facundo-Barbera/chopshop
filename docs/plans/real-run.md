# E12: prueba real con 4 roles (2026-10-30)

Un agente de prueba, su MCP y un perfil local fuera del repo, contra el T3 real de la máquina. El LaunchAgent real
(127.0.0.1:3790), su MCP (3797), `/Applications` y `~/.config/chopshop` no se tocaron.

## Montaje

| pieza | valor |
|---|---|
| config | `/tmp/e12/xdg/chopshop/config.toml` (`CHOPSHOP_CONFIG`, `XDG_CONFIG_HOME=/tmp/e12/xdg`, `CHOPSHOP_HOME=/tmp/e12/home`) |
| agente | `chopshop agent run`, `127.0.0.1:3891`, `auth = "none-local"`, `machine_id = "e12-test"`, DB `<dir-de-prueba>/agent/agent.db` |
| despachador | `[agent.dispatcher] enabled = true, max_threads = 2, interval = 5`; roles, GitHub y forge apagados |
| MCP | `chopshop mcp serve`, `127.0.0.1:3897`, token y credenciales bajo `/tmp/e12/xdg` |
| perfil | `<dir-de-prueba>/profiles/chopshop-e12.yaml`: `t3_project` = proyecto `chopshop` de T3, `workspace: root` (sin worktrees ni ramas), `runtime_mode: approval-required`, `cannot_run: [git push, git commit, rm]`, `model: claudeAgent/claude-haiku-5-5`; dos pisos con cuatro escritorios `permanent: true`: triage y qa (Operaciones) y release y docs (Entrega) |

Por MCP: `project_register {name: chopshop-e12, company, t3_project}` (idempotente: el perfil ya existía) y 8 × `task_enqueue`,
dos por rol, todas de solo lectura sobre el repo (resumir un archivo o listar TODOs, versiones o títulos), cada una con
`key` propia. El título es el prompt (ver BUG-4).

Pasadas: 1) sin `model` en el perfil y sin arreglos: BUG-1 y BUG-3; 2) con `model`, sin arreglos: las 8 terminan; 3) con los
arreglos de BUG-1 y BUG-2: las 8 terminan sin errores en el log.

## Resultado (pasada 3, con los arreglos)

`/snapshot` y `/state?project=chopshop-e12` muestreados cada 3 s (vivos / en cola):

| hora | vivos | en cola | escritorios |
|---|---|---|---|
| 10:11:23 | 0 | 6 | se despachan las dos primeras tareas, aún sin sentar |
| 10:11:26 | **2** | **6** | triage y qa trabajando; release y docs en el área común con 2 en cola cada uno |
| 10:11:53 | 0 | 2 | — |
| 10:11:56 | 2 | 2 | release y docs trabajando |
| 10:12:23 | **0** | **0** | los cuatro en el área común |

- Las 8 tareas: `employee.assigned reason: queue` → `task.state` → `desk.released` → `employee.idle reason: done`. Las 8 terminaron
  `completed` en T3, con `settled` en T3 (comprobado con `threads_list include_settled`) y `closed` en `state.json`.
- `/snapshot` y `/state` coinciden en vivos y en cola en todas las muestras salvo transitorios de una muestra.
- Capturas con `ChopshopSnap` a partir del `/state` del agente guardado en el momento 2 vivos / 6 en cola y al final
  (`/tmp/e12/out/snap-2-6/`, `/tmp/e12/out/snap-end/`; no se versionan porque son datos de una instalación real):
  - `employees-chopshop-e12-{0,1}-{dark,light}.png`: el piso Operaciones con Carla (triage) y Emilio (qa) en sus escritorios, y el
    piso Entrega con Leo (release) y Elena (docs) en el lounge y la cocineta (área común). Al final, los cuatro en el área común.
  - `e12-empleado-cola*.png`: la ciudad con «2 corriendo» en el HUD y el panel de Leo con «Cola pendiente 2» y los botones Cancelar.
    Se generó con un parche local de `ShellSnapshots.swift` (cargar un `/state` y seleccionar un empleado) que no se versiona.

## Fallos

### BUG-1: la conexión SQLite compartida entre hilos corrompe el agente (arreglado)

En la pasada 1, justo después de encolar, todos los hilos del agente empezaron a fallar con `sqlite3.DatabaseError: file is not a
database` y `/snapshot` y `/state` devolvían 500. Al reiniciarlo, los primeros arranques murieron con segfault (exit 139) sin dejar
nada en el log; uno posterior arrancó bien. El archivo en disco estaba sano (`integrity_check` ok).

Causa: el agente usa **una** conexión `sqlite3` para todos sus hilos (`check_same_thread=False`) y `db.tx()` solo protege las
escrituras de lectura-modificación-escritura. El `python3` del sistema (3.9.6, `sqlite3.threadsafety == 1`) no admite que dos hilos
usen la misma conexión a la vez. Se reproduce sin el MCP: 3 hilos sobre una conexión, uno escribiendo y dos leyendo sin
`db.tx()`, dan exit 138/139 en 3 de 3 intentos.

Arreglo: `db.connect` devuelve la conexión envuelta (`db._Locked`): `execute`, `executemany` y `executescript` corren bajo el mismo
`RLock` que `db.tx()` y devuelven las filas ya leídas, así que ningún cursor se recorre fuera del candado. Prueba:
`TestSchema.test_shared_connection_survives_concurrent_threads` (sin el arreglo falla o hace segfault). Con el arreglo, la pasada 3
no dejó errores ni avisos en el log.

### BUG-2: T3 inaccesible no aparecía en el log (arreglado)

Con `t3_bin = "t3"` y `t3` fuera del `PATH` del shell, el agente arrancó con `t3_ok: false` y sin ninguna línea en el log (solo el
sobre `t3_unreachable` en el bus). Además el error real era engañoso: `[Errno 13] Permission denied: 't3'`. Ahora el agente registra
`WARNING T3 no responde: <error>` en el primer fallo de cada caída. En la prueba se usó `t3_bin = "~/.t3/bin/t3"`.

### BUG-3: un perfil sin `model` hace fallar todas las tareas de la cola (abierto)

El proyecto `chopshop` de T3 no tiene modelo por defecto, así que en la pasada 1, al reiniciar el agente, los 8 `t3_thread_launch` fallaron con
`Pass modelSelection: the project has no default model`. Cada tarea quedó `launch_failed` → cola `failed` →
`employee.idle reason: failed`, sin reintento (es a propósito: T3 no tiene clave de idempotencia). Ni `chopshop profile check` ni
`task_enqueue` avisan antes. Propuesta: que `profile check` (o el despachador antes de sacar de la cola) consulte
`t3_project_list`, vea `defaultModelSelection: null` y exija `model` en el perfil.

### BUG-4: `task_enqueue` no acepta `prompt` (abierto)

El despachador usa `extra.prompt` o, si falta, el título, pero la herramienta MCP solo recibe `title`. Para dar instrucciones
(«solo lectura, sin Bash, sin git») hubo que meterlas en el título, y la app lo muestra truncado en la cola. Propuesta: un parámetro
`prompt` opcional que vaya a `extra`.

### BUG-5: `ChopshopSnap employees` no dice nada con un fixture de `/snapshot` (resuelto en E17)

Con el JSON de `GET /snapshot` (que también trae `employees` y `queues`) el modo no genera ninguna imagen y no imprime nada. Solo
funciona con la forma de `/state` (como `snapshot.office.json`). Debería decir qué falta o aceptar las dos formas. E17: sin
`office` toma `employees`/`queues` del JSON (`/snapshot`, parte `employees` del relay o sus tramas `snapshot`) sobre las oficinas
de `snapshot.office.json` (o del 4.º argumento).

## Notas (no son fallos de Chopshop)

- `workspace: root` lanza en la copia principal del proyecto de T3 (`la copia principal del repositorio`, en otra rama), así que 4
  de las 8 respuestas dicen que el archivo pedido no existe (son archivos de `dev`). Para una prueba así conviene `base_ref: dev` con
  worktrees, a costa de crear ramas.
- Con `approval-required` y Haiku, algunos hilos dijeron no tener Grep o Bash y respondieron con lo que pudieron. Chopshop cuenta
  `completed` como `done` aunque la respuesta diga que no pudo hacer la tarea.
- Entre que el despachador saca una tarea y la sienta hay una pasada (hasta 5 s) en la que se ve 0 vivos y la cola ya descontada; y
  un hueco libre se rellena en la pasada siguiente, así que «2 vivos» no es continuo.
- Reencolar con una `key` ya usada devuelve la tarea vieja (`created: false`) aunque haya terminado (`failed`). Puede ser lo
  deseado; en la pasada 3 se usaron claves nuevas.
- El agente de prueba atribuye a `chopshop-e12` todos los hilos del proyecto `chopshop` de T3 (también los de otras sesiones), pero
  solo despacha, sienta y hace settle de los suyos.

## Efectos fuera de `/tmp/e12`

- 16 hilos de T3 en el proyecto `chopshop` (8 de la pasada 2 y 8 de la pasada 3), todos con settle; los 8 de la pasada 1 no llegaron
  a crearse.
- Una credencial de pairing de T3 para el agente de prueba (`<dir-de-prueba>/t3-credential-agent.json`).
- El agente de prueba y su MCP quedaron detenidos (puertos 3891 y 3897 libres).
