# chopshop-agent: contrato de módulos y API (v0.7, api_version 1 + 2 + 3)

`api_version 2` es **aditiva**: añade `GET /stream` (SSE), `GET /state` y el emparejamiento por dispositivo (`POST /pair`).
`GET /snapshot`, `GET /events` y `GET /health` conservan su forma v1 (`api_version: 1`); la v2 se anuncia en el `hello` del stream,
en `GET /state` y en la respuesta de `POST /pair`. `api_version 3` (también aditiva) añade la oficina por escritorios, el
vestíbulo y la sala de máquinas (ver «`api_version 3`»).

Contexto: el agente corre en cada máquina como servicio de usuario (`systemd --user` en Linux, launchd en macOS). Escucha en
`agent.bind`:`agent.port` (`~/.config/chopshop/config.toml`, ver `config.example.toml`): por defecto `127.0.0.1`; para otras máquinas,
`"auto"` (IP de Tailscale) o la IP concreta (p. ej. `100.64.0.10`). **Nunca** `0.0.0.0` ni `::` (se niega a arrancar). Si `bind` no es
loopback abre además `127.0.0.1:<port>` (`agent.local_listener`) para el CLI local. Instalación y operación: `docs/agent-service.md`.
La app es un cliente puro. Stdlib de Python solamente (>=3.9 compatible).
El agente es una capa delgada sobre T3: observa (métricas, hilos, eventos) y solo escribe en T3 por `answer`/`settle` (y, desde la
v3, el despertar de un rol permanente lanza su hilo como un lote de una tarea por el motor, igual que `fanout`). **No** lanza ni
mata procesos, no reparte puertos ni crea worktrees: los servers de prueba, puertos y comandos de cada hilo son cosa de T3. Las URLs de webhook nunca se imprimen ni se guardan en DB/logs (solo rutas de archivo).

## Módulos (cada uno en `apps/agent/chopshop/agent/`, con su test en `apps/agent/tests/`)

Todos reciben `cfg` (dict de `config.load()`) y `conn` (de `db.connect(cfg["db_path"])`). El esquema está en `db.py` (no lo cambies sin avisar;
si necesitas columnas, usa los campos `extra` JSON). `user_version` 2: la migración desde la 1 borra las tablas de la v1 que ya no se usan; la 4 añade los filtros de suscripciones v2
(ver «Suscripciones»).

| Módulo | Dueño | Interfaz pública |
|---|---|---|
| `events.py` | hilo events | `emit(conn, cfg, event, project, body=None) -> seq` (inserta en `events`, entrega a `subscriptions` + `cfg["webhook_files"]`, escribe `deliveries`); `list_after(conn, after=0, limit=200) -> [dict]`; `subscribe(conn, name, webhook_file, project="*", events=None, **filtros_v2)`; `unsubscribe`; `list_subscriptions(conn)` (sin URL ni rutas). Filtros, firma, reintentos y debounce en `webhooks.py` (`Dispatcher` con reloj inyectable). Webhook POST con timeout, la URL solo se lee del archivo. Migración opcional `import_legacy(conn, ~/.chopshop/events.jsonl)`. |
| `collector.py` | hilo metrics | `Collector(cfg, conn)`: `.sample_once() -> dict` (escribe `machine_samples`, `samples`, y devuelve el snapshot); `.latest() -> {"machine":{...},"apps":[...],"projects":[...]}`; `.compact()` (agrega a `samples_agg` 1m/1h y aplica retención); `query(conn, frm, to, group="machine"|"app"|"project", step=None) -> {"group","step","res","series":[{"name","points":[[ts,cpu,rss],...]}]}` (`res` = resolución usada: `raw`, `1m` o `1h`). Lee `/proc` (sin `ps`). Agrupa por **app** (nombre del ejecutable normalizado: node, python, claude, codex, git, tsc, vitest, chrome…) y por **proyecto** (cwd bajo `projects_root/<p>` o `worktrees_root/<p>/…`, o `T3CODE_THREAD_ID`→t3_threads.project, o cgroup/scope). También reporta el cgroup/slice (`app-t3code-agents.slice`, `t3code.service`, `chopshop-*`). Backoff del intervalo si load1 > 0.5*cpus. Debe costar < 1 % CPU. |
| `t3watch.py` | hilo t3 | `T3(cfg, client=None, clock=None)`: adaptador fino sobre el cliente MCP nativo `t3mcp.Client` (el inyectado o uno construido desde `cfg.t3`: `origin`, `access`, `credential_file`, `t3_bin`); `.call(tool, args) -> obj` delega en él (errores → `T3Error` = `t3mcp.T3Error`); `.projects()`, `.threads()`, `.read()`; `poll(conn, cfg, t3, emit_fn) -> {"threads":n,"changes":[...]}` (lee `t3_thread_list` por proyecto + `t3_thread_read`/pending solo de los activos; upsert en `t3_threads` con project, worktree, status, settled, pending; emite `thread_started`, `thread_done`, `thread_failed`, `thread_settled`, `pending_question` por transición); `settle(t3, thread_id)` = `t3_thread_organize {action:"settle"}` (nunca archivar); `answer(t3, thread_id, choice, request=None)` (resuelve la opción con `chopshop/answers.py`, el mismo módulo que usa el motor). Debe tolerar T3 caído (error → evento `t3_unreachable` una vez, backoff). Detalles: `emit_fn(event, project, body)` (el integrador lo envuelve sobre `events.emit`); `T3` expone `.reachable`, `.failures`, `.backoff` (s) y `.retry_at` (`poll` no llama a T3 hasta entonces y devuelve `skipped:"backoff"`); `poll` devuelve también `errors`, `reachable`, `backoff`. Eventos extra: `t3_recovered` y `pending_approval` (permisos, solo aviso). La primera pasada siembra `t3_threads` en silencio (solo avisa preguntas pendientes). `project` = título del proyecto en T3. Archivar lo rechaza `t3mcp.Client` (solo `settle`/`unsettle`); el agente solo envía `settle`. `answer` devuelve `{request_id, answers, question}` y lanza `AnswerError` (subclase de `T3Error`, error del llamante → 400) si no hay pendientes, es ambigua o la opción no vale; con varias preguntas, `choice` es `{id_pregunta: elección}`. |
| `../answers.py` | motor y agente | `resolve(q, choice)` (nº de opción, etiqueta, valor o texto libre; lista si `multiSelect`) y `resolve_all(questions, choice)` (`{id: valor}`; con varias preguntas `choice` es `{id: elección}`). Puro, sin I/O; lanza `InvalidChoice` (`ValueError`). |
| `../t3.py`, `../t3mcp.py` | motor y agente | `t3mcp.Client(origin, access, credential_file, t3_bin, timeout)`: cliente MCP HTTP nativo (OAuth+PKCE con pairing local, credencial 0600 en `<CHOPSHOP_HOME>/t3-credential.json`). `t3.call(host_cfg, host_name, tool, args)` es la fachada del motor: un cliente cacheado por host (`origin`, `access`, `credential_file`), `t3.is_local(host_cfg)` (= sin `origin`), `t3.T3Error` (= `t3mcp.T3Error`), `t3.set_client_factory(fn)`/`t3.reset()` para tests. Sin `fleet` ni helper node. |
| `forge/` | hilo forge | Rack de repos (v3, `docs/plans/office-redesign.md` §4). `base.ForgeProvider` (`norm_repo`, `repo_url`, `poll_events(repo, project)`, `poll_runs(repo, branch=None) -> [run]`, `repo_status(repo) -> {default_branch, url, ci, active, pr_failing, error}`, `next_delay()`; errores → `ProviderError(kind, degraded)`) y `base.light(status)` pura: gris (sin datos o `error`) > rojo (CI de la rama por defecto fallido o PR con CI rojo) > ámbar (runs en curso/en cola) > verde (CI en `success`). `github.GitHubProvider`: `gh api` de `github.py` + `actions/runs` (todas las ramas y la por defecto) con ETag; cursores `forge_etag:*`/`forge_body:*` en `meta`. `rack.Rack(conn, cfg, emit)`: repos de `rack.repos` de los perfiles + `[agent.github] repos`; emite `forge.repo.state` solo al cambiar (`forge_repo:<proveedor>:<repo>` en `meta`, red → `warn`); proveedor degradado → gris + backoff. `[agent.forge] enabled = "auto"` sigue a `[agent.github] enabled`. Proveedores nuevos: `forge.PROVIDERS`. |
| `actions.py` | hilo actions | `ActionsPoller(conn, cfg, emit, runner, clock, profiles_fn, head_fn)` (subclase de `GitHubPoller`: mismo `gh`, ETag y backoff; el `machine.health` de GitHub lo publica solo el hilo `github`). Sondea `/actions/runs` de `[agent.github] repos` + `rack.repos` (github) y emite `forge.run.state` (en curso + 5 completados por repo; `warn` si terminó mal) con `origin` por prioridad: `thread` (rama del hilo fuera de la rama por defecto, o sha = HEAD de su worktree en `push`/`pull_request*`; etiqueta `rol · escritorio`), `automation` (`forge.dispatch` reciente: `nonce` en el título del run o mismo workflow+ref en 10 min), `bot` (`rack.actors` kind bot o cuenta `…[bot]`; no en `schedule`), `schedule`, `human`/`unknown`. Un origen `thread`/`automation` no se degrada. Tabla propia `forge_runs` (`CREATE TABLE IF NOT EXISTS`, sin tocar `user_version`). `[agent.github] actions = false` lo apaga. |
| `stream.py` | integrador | `Bus` (`publish(seq)`, `wait(seq, timeout)`, `close()`; `AgentService.emit` publica) y `StreamHub` (`serve(handler, ident, query)`, `revoke(device_id)`, `close()`, `active`): ver «`GET /stream`». |
| `projection.py` | integrador | `apply(state, envelope) -> state` (pura, idempotente por `seq`), `fold(envs)`, `state(conn, cfg)`, `Projector(conn, cfg).current()` (incremental), `envelopes_after(conn, after)` (sobres del bus sin `event`/`machine_id`), `filter_project`. |
| `office.py` | hilo office | `Office(conn, cfg, emit_fn, profiles_fn=None, clock)`: `.reload()` (perfiles con `office:` → tabla `desks`; retira, nunca borra; emite `office.changed {by: "profile"}` al cambiar la estructura o si el último ya no está retenido), `.tick()` (pliega los `task.state` nuevos del bus con cursor `office_cursor` en `meta`: asigna, hereda, encola por rol lleno), `.assign(desk_id, thread_id)` (`OfficeError` 404/409/400), `.release(desk_id, reason)` (para quien decida la salida, p. ej. la semivida), `.desk(desk_id)`. Tablas `desks`, `desk_occupancy` (ocupante = `until` nulo; linaje ≤ 20), `office_threads` (última `task.state` por hilo), `desk_waiting`; `t3_threads` gana `role` y `ended_at` (esquema 5). Herencia: si un ocupante del rol ya terminó (fase terminal, sin atención), el hilo nuevo hereda el que terminó antes (`reason: inherited`); si no, el primer libre (`start`); la herencia es el último ocupante del escritorio (también ya salido). Rol lleno o sin escritorios → `desk.waiting`; sube en cuanto uno queda libre o su ocupante termina. Los hilos sin rol no se sientan (vestíbulo: aparte). Rol lleno → escritorios elásticos (`capacity:`; ver «Escritorios elásticos»): flex, pisos temporales y contratista, con vuelta a la sala y cierre con histéresis en `.tick()`. `[agent.office] enabled, interval`. |
| `halflife.py` | hilo semivida | `opacity/exit_at/gone(phase, attention, ended_at, touched_at, half_life_s[, now])` (pura, tabla `fixtures/office/halflife.json`); `touch(conn, thread_id, now)` / `touched_at` / `touches` (tabla propia `thread_touch`, `CREATE TABLE IF NOT EXISTS`, sin tocar `user_version`); `stamp(conn, event, body)` (añade `touched_at` a los `task.state` que emite `AgentService.emit`); `schedule(state, touches)` / `due(state, now, touches)` sobre la proyección v3 (ocupantes y `lobby`; con `attention` en el ocupante o abierta en `projects[].attention` no sale); `Fader(conn, state_fn, emit_fn, clock)`: `.sweep()` emite `desk.released reason: faded` (`desk: null` en el vestíbulo), `.next_delay()` (1–30 s). Hilo `halflife` del servicio (`agent.halflife_enabled`, por defecto `true`). `POST /touch` y `POST /answer` tocan. |
| `listeners.py` | integrador | `Listeners(emit, clock).report(hilo, estado, error, backoff_s)` → `listener.state` por transición + latido horario. |
| `machine_room.py` | integrador | Reductor de `machine_room` (listeners y automatizaciones: `apply`, `filter_project`; el rack es de otro módulo) que llama `projection._apply`; `subscriptions(conn)` / `live(state, conn)` rellenan `machine_room.subscriptions` (`{name, projects, last_ok, last_error, last_error_at, signed}`) en `Projector.current()`; `rooms(state)` / `scope(mr, project, cfg)` resuelven `projects[].machine_rooms` (0..N salas, las de `office.machine_rooms`). |
| `pairing.py` | integrador | `Pairing(conn, clock)`: `create_code(name, ttl)`, `redeem(code, device_name, device_id, ip)`, `check(cred, ip)`, `active(id)`, `list()`, `revoke(id)`, `prune()`; CLI `chopshop pair create\|list\|revoke\|prune`. Tablas propias `pair_codes` y `devices` (`CREATE TABLE IF NOT EXISTS`, sin tocar `user_version`). |
| `roles.py` | hilo roles | Roles permanentes (fase 6): `Roles(conn, emit_fn, profiles_fn, launch_fn, task_fn, assign_fn, clock)`: `.on_event(sobre)`, `.tick(now)` (schedule), `.sync(now)` (lote lanzado → `assign_fn`, terminado → fin + despertar pendiente), `.manual(project, role)`, `.once(list_after, last_seq)`. Tabla propia `desk_wakes` (`ensure_schema`, `CREATE TABLE IF NOT EXISTS`, sin tocar `user_version`). Ver «Roles permanentes». |
| `server.py`, `service.py` | integrador | `server.py`: `ThreadingHTTPServer`, `Authenticator` y las rutas (`AgentApp`). `service.py`: `AgentService` (ensambla módulos, hilos de fondo, parada limpia) y el CLI `chopshop agent run\|status\|token\|check-config\|print-unit`. |
| `ui/` | hilo UI | cliente puro de la API (ver abajo). |

Convención: funciones que fallan lanzan excepciones propias del módulo; nada imprime secretos; todo es testeable sin red ni systemd
(inyecta runners: `T3(..., runner=callable)`, el `runner` de tailscale del `Authenticator` y el `poster` de webhooks).

## API HTTP (JSON, UTF-8). Auth

Orden de decisión por petición (`agent.auth`, por defecto `tailscale+token`):

1. **Origen local** (loopback o la propia IP de escucha del agente: CLI de la misma máquina) → aceptado, lectura y escritura
   (`agent.trust_local = true`; con `false` también el origen local pasa por lo que sigue).
2. `auth = "none-local"` → cualquier otro origen: 403.
3. `auth = "token"` → hace falta `Authorization: Bearer <token>` (el de `token_file`, 0600, o una credencial de dispositivo) en
   **toda** petición, lectura incluida.
4. `auth = "tailscale+token"` → `tailscale whois --json <ip origen>` (cache 60 s; fallos 5 s) → `UserProfile.LoginName` (login completo,
   sin distinguir mayúsculas) debe ser `owner_login` (lectura y escritura) o estar en `allowed_logins` (**solo lectura**). Además
   **toda** petición (lecturas incluidas, también `/stream`), salvo `GET /health` y `POST /pair`, exige
   `Authorization: Bearer <credencial>`: la de un **dispositivo emparejado** (`cs1_…`, ver «Emparejamiento») o el bearer legado de
   `token_file` (credencial de servicio para la CLI remota y bots). No hay modo sin credencial.

Sin identidad válida, o sin permiso para escribir → **403** (también en rutas inexistentes: no se puede sondear sin identidad). Sin
credencial, o con una inválida/revocada → **401** (`WWW-Authenticate: Bearer`). Las credenciales se comparan en tiempo constante
(`hmac.compare_digest` el bearer legado; por SHA-256 las de dispositivo). No se confía en cabeceras `X-Forwarded-*`.

**Defensas web** (en todos los modos, también el origen local; no son el control principal): se rechaza toda petición con cabecera
`Origin` (navegadores) y toda petición cuyo `Host` no sea del agente (IPs de escucha, loopback, `localhost`, `machine_id`, hostname o
`agent.allowed_hosts`; anti DNS-rebinding); las escrituras (`POST`, y `DELETE` con cuerpo) exigen `Content-Type: application/json`.
Todo eso → **403**.

### Emparejamiento por dispositivo

- **Crear código** (solo en la máquina del agente, CLI local; no hay ruta HTTP): `chopshop pair create [--name "MacBook"] [--ttl 10m]`
  imprime un código de un solo uso (`K7QM-93XD`: 8 símbolos base32 de Crockford, 40 bits; se muestra una vez) y su caducidad
  (por defecto 10 min, máx. 1 h). En SQLite (`pair_codes`) solo queda `sha256(sal + código)`.
- **Canjear**: `POST /pair {"code", "device_name"?, "device_id"?}` (sin credencial; con identidad Tailscale en `tailscale+token`) →
  `{"device_id", "credential": "cs1_<43 car. base64url>", "api_version": 2}`. El código se consume en el primer canje: reusarlo,
  caducado o invalidado → **410**; inválido → **401**; 5 fallos por minuto por IP → **429**; cada fallo cuenta contra todos los
  códigos vivos y a los 20 se invalidan. `device_id` (opcional; si falta se genera un UUID) re-emparejado = credencial nueva, la
  anterior deja de valer. En `devices` solo queda `sha256(credencial)`; el cliente la guarda (la app de Mac, en el Keychain).
- **Uso**: `Authorization: Bearer cs1_…`; sin expiración automática; `last_seen_at`/`last_ip` se actualizan (máx. una vez por minuto).
  El dispositivo hereda los permisos de la identidad Tailscale desde la que llega (propietario = escribe; `allowed_logins` = lee).
- **Gestión** (CLI local, directo sobre la DB): `chopshop pair list [--json]` (dispositivos y códigos vivos: id, nombre, fechas,
  último uso, IP; nunca hashes ni credenciales), `chopshop pair revoke <device_id|code_id>` (efecto inmediato: la siguiente petición
  da 401 y el `/stream` abierto de ese dispositivo se cierra en ≤ 1 s), `chopshop pair prune` (borra códigos usados/caducados de más
  de 7 días y dispositivos revocados).
- Cuerpo máximo 64 KiB (413), `Content-Length` obligatorio (sin chunked: 411), JSON UTF-8 objeto (400), timeout de conexión 15 s.
- Errores: `{"error": "mensaje"}` + código HTTP (400 petición inválida/`AnswerError`, 403, 404, 405, 413, 500 `error interno`, 502 T3 falló,
  503 T3 desactivado). Respuestas y logs **nunca** incluyen URLs de webhooks ni tokens (las suscripciones solo guardan RUTAS de archivo).
- El agente no ejecuta comandos de clientes: no hay rutas para lanzar servidores, pedir puertos ni matar procesos (eso es de T3).

| Método y ruta | Descripción |
|---|---|
| `GET /health` | `{ok, api_version, version, machine_id, ts, uptime, whoami}` (`whoami.device` si se usó una credencial de dispositivo). Sin credencial |
| `POST /pair` | `{code, device_name?, device_id?}` → `{device_id, credential, api_version: 2}` (ver «Emparejamiento»). Sin credencial |
| `GET /stream?after=&project=&types=` | Server-Sent Events (v2), ver abajo |
| `GET /state?project=` | proyección completa (v2), lo mismo que el evento `state` del stream |
| `GET /snapshot` | ver forma abajo (lo que pinta la UI) |
| `GET /metrics?from=&to=&group=machine\|app\|project&step=` | series (ver `collector.query`) |
| `GET /events?after=<seq>&limit=` | `{events:[sobre], last_seq, head_seq}` (sobre v1 de `docs/event-envelope.md`, + `event` y `machine_id` viejos): `last_seq` = cursor para la siguiente consulta (seq del último devuelto, o `after` si no hay), `head_seq` = último de la máquina |
| `GET /threads?project=&limit=` | `{threads:[...]}` desde `t3_threads` (más recientes primero) |
| `GET /subscriptions` | `{subscriptions:{nombre:{project,events,created,projects,types,exclude_types,min_severity,needs,only_changes,context,debounce_s,signed,headers}}}` (filtros; sin URL ni rutas; `signed` = tiene `secret_file`; `headers` = tiene `headers_file`). Ver «Suscripciones (webhooks v2)» |
| `POST /answer` | `{thread_id, choice, request?}` → responde en T3 (`{ok, request_id, answers, question}`). `AnswerError` (sin pendientes, ambigua, opción no válida) → 400; T3 caído → 502 |
| `POST /settle` | `{thread_id}` → `t3_thread_organize settle` (nunca archivar) → `{ok, thread_id}` |
| `POST /subscriptions` / `DELETE /subscriptions/<name>` | `{name, webhook_file, project?, events?, projects?, types?, exclude_types?, min_severity?, needs?, only_changes?, context?, debounce_s?, secret_file?, headers_file?}` (`webhook_file`/`secret_file`/`headers_file` = rutas de archivos existentes en la máquina del agente, nunca una URL; `secret_file` y `headers_file` con permisos 0600). Reemplaza la suscripción entera. Valores inválidos → 400 |

### Forma de `GET /snapshot`

```json
{
  "api_version": 1, "machine_id": "host-b", "ts": 1761660000.0, "generated": "2026-10-28T09:40:00-0600",
  "machine": {"cpus": 12, "load": [0.1,0.1,0.1], "cpu_pct": 3, "ram_total_mb": 48169, "ram_avail_mb": 45000, "ram_pct": 7,
              "swap_used_mb": 0, "disk_used_gb": 18, "disk_total_gb": 387, "disk_pct": 5, "os": "Linux", "uptime": 12345},
  "apps":     [{"name": "node", "cpu_pct": 12.0, "rss_mb": 800.0, "procs": 14, "cgroups": ["app-t3code-agents.slice"]}],
  "projects": [{"name": "orchestrator", "cpu_pct": 30.0, "rss_mb": 1500.0, "procs": 20, "threads_running": 2, "threads_pending": 1}],
  "threads":  [{"thread_id": "...", "project": "...", "title": "...", "status": "running", "settled": false, "pending": [], "worktree": "...", "updated": 0.0}],
  "pending_questions": [{"thread_id": "...", "project": "...", "request_id": "...", "questions": [...]}],
  "events":   [ ...últimos 80, más nuevos primero... ],
  "subscriptions": {"nombre": {"project": "*", "events": []}},
  "orchestrator": { ...salida de chopshop.engine.snapshot() (lotes, grafos, reacciones) o null... },
  "agent": {"version": "0.6.0", "uptime": 12, "t3_ok": true, "last_sample_age": 3.2, "last_poll_age": 2.0},
  "employees": [ ...empleados (docs/employees.md)... ], "queues": {"<empleado>": {"items": [], "updated": null}}
}
```

Notas de `snapshot`:
- `machine.cpu_pct` es **0–100 de toda la máquina**; `apps[].cpu_pct` y `projects[].cpu_pct` usan **100 = un núcleo** (pueden superar 100):
  con 4 CPUs, un proceso que ocupa un núcleo entero da `machine.cpu_pct` = 25 y `cpu_pct` = 100 en su app/proyecto. Hay test que lo
  verifica de extremo a extremo.
- `projects` incluye también los proyectos con hilos o configurados aunque no tengan procesos (CPU 0).
- `threads` = hasta 200 (activos y con preguntas primero, luego los más recientes); `pending_questions` los lista todos.
- `agent.t3_ok` es `null` si aún no hubo sondeo o `agent.t3_enabled = false`; `last_sample_age`/`last_poll_age` son `null` hasta la
  primera muestra/sondeo. Si algún hilo de fondo falla aparece `agent.errors: {hilo: "Tipo: mensaje"}`.
- `orchestrator` es `chopshop.engine.snapshot()` (cache de 5 s) o `null` si no está disponible.

## `GET /stream` (api_version 2)

`text/event-stream` (`Cache-Control: no-store`, `X-Accel-Buffering: no`). Cursor: cabecera `Last-Event-ID` (manda) o `?after=<seq>`.
Filtros: `project=<nombre exacto>` y `types=<glob,glob>` (p. ej. `task.*,question.*`); solo afectan a los `envelope`.
```
retry: 3000

event: hello
data: {"api_version":2,"machine":"host-b","head_seq":1842,"resume":"snapshot"}

event: state
id: 1842
data: { ...lo mismo que GET /state... }

event: envelope
id: 1843
data: { ...sobre (docs/event-envelope.md)... }

: ping
```
- **Sin cursor**, cursor más viejo que el primer evento retenido, más de 2000 eventos atrás o mayor que `head_seq` → `hello` con
  `resume: "snapshot"` + `state` (`id = head_seq`) + deltas con `seq > head_seq`. **Cursor válido** → `hello` con `resume: "events"` y
  los sobres desde SQLite sin `state`: reconectar con el último `id` recibido no pierde ni duplica eventos.
- Los deltas salen de SQLite (no hay buffer en memoria) y un `threading.Condition` despierta a los clientes en cada `emit`; además se
  revisa la DB cada segundo (eventos escritos por otro proceso).
- `: ping` cada 15 s. Máximo **8** conexiones SSE simultáneas (la 9.ª → **503** + `Retry-After: 3`; `/health` y el resto no cuentan).
  Sin timeout de inactividad; una escritura bloqueada más de 10 s (cliente lento) cierra esa conexión sin afectar a las demás: el
  cliente reconecta con `Last-Event-ID`. Revocar el dispositivo o parar el agente cierra el stream.
- Cada sobre trae el estado completo de su sujeto: el cliente aplica `apply(state, sobre)` (la misma función que `projection.py`) y
  obtiene exactamente `GET /state` (hay test de equivalencia).

### Forma de `GET /state` (y del evento `state`)

```json
{"api_version": 2, "machine": "host-b", "head_seq": 1842, "ts": "2026-10-29T16:12:03.412Z",
 "machine_health": {"state": "ok", "cpu_pct": 12, "ram_pct": 31, "disk_pct": 5, "t3_ok": true},
 "projects": [{"name": "nuskills",
   "counts": {"running": 2, "queued": 3, "waiting": 0, "stuck": 1, "needs_human": 1, "waiting_bot": 1, "done": 9, "failed": 0},
   "batches": [{"id": "b-0007", "host": "host-b", "max_parallel": 3, "status": "running", "tasks": {"t-1": "done"}}],
   "tasks": [{"id": "mcp:b7", "phase": "running", "attention": null, "...": "cuerpo de task.state", "severity": "info", "seq": 1840, "updated": "..."}],
   "graphs": [{"id": "g-2", "goal": "...", "status": "running", "nodes": [{"id": "n-4", "phase": "running", "deps": ["n-2"]}]}],
   "attention": [{"key": "task:mcp:b7", "id": "01JC9Z...", "seq": 1841, "type": "question.opened", "needs": "bot", "severity": "notice",
                  "subject": {"kind": "task", "id": "mcp:b7"}, "since": "...", "summary": "¿Qué canal manda la fuente de verdad?"}]}],
 "recent": [ ...últimos 50 sobres, el más nuevo primero... ]}
```
- `attention` = cola de lo que necesita acción: un elemento por sujeto (`key = kind:id`) cuyo último sobre trae `needs != null`; el
  siguiente sobre del mismo sujeto con `needs: null` lo cierra (`reaction.applied` y `automation.ran` no cuentan). `since` = cuándo se abrió.
- `counts`: `running` (running/preparing), `queued`, `waiting` (sin atención), `done` (done/settled), `failed`, `stuck` (último sobre
  `warn`/`error` y sin terminar), `needs_human` (atención human/approval), `waiting_bot` (atención bot).
- `machine_health` = último `machine.health`; los eventos sin proyecto solo cuentan para `machine_health` y `recent`.
- Los sobres son los del bus (`events.list_after`, docs/event-envelope.md) sin los campos viejos `event`/`machine_id`.

## `api_version 3` (aditiva): oficina, vestíbulo y sala de máquinas

Plan: `docs/plans/office-redesign.md`. Todo lo de la v2 sigue igual; `GET /state`, el `hello` y el evento `state` del stream
pasan a decir `api_version: 3` y el estado gana campos. Un cliente v2 ignora lo nuevo. La regla sigue siendo
`GET /state == fold(apply, sobres)`; la única excepción es `machine_room.subscriptions` (y sus copias recortadas en
`projects[].machine_rooms[].subscriptions`), que no viene de sobres (ver abajo).

### Forma nueva de `GET /state`

```json
{"api_version": 3, "...": "lo de la v2",
 "projects": [{"name": "awesome-gb", "...": "lo de la v2",
   "office": {"company": "Awesome GB", "half_life_s": 1800, "floors": [
     {"index": 0, "name": "Producto", "rooms": [
       {"role": "triage", "permanent": true, "desks": [
         {"id": "awesome-gb/0/triage/0", "slot": 0, "retired": false, "occupant": null, "lineage": [], "notes_pending": 2}]},
       {"role": "backend", "permanent": false, "desks": [
         {"id": "awesome-gb/0/backend/0", "slot": 0, "retired": false, "notes_pending": 0,
          "occupant": {"thread_id": "mcp:b7", "title": "[be] login", "role": "backend", "phase": "done", "attention": null,
                       "since": "2026-10-29T16:00:00.000Z", "ended_at": "2026-10-29T16:20:00.000Z", "touched_at": null,
                       "half_life_s": 1800, "inheritance": {"thread_id": "mcp:a1", "summary": "...", "branch": "be/x"}},
          "lineage": [{"thread_id": "mcp:a1", "since": "...", "until": "...", "reason": "inherited"}]}]}]}]}}],
 "lobby": [{"thread_id": "mcp:c3", "project": "awesome-gb", "company": "Awesome GB", "title": "...", "phase": "running",
            "attention": null, "waiting_role": null, "since": "...", "ended_at": null, "touched_at": null, "half_life_s": 1800}],
 "machine_room": {
   "listeners": [{"name": "t3watch", "state": "ok", "last_ok": "...", "last_cycle": "...", "backoff_s": 0, "error": null, "ts": "..."}],
   "automations": [{"project": "awesome-gb", "name": "triage", "trigger": "schedule", "exit": 0, "duration_ms": 2310,
                    "error": null, "ts": "...", "next_run": "...", "severity": "info"}],
   "subscriptions": [{"name": "bots", "last_ok": "...", "last_error": null, "signed": true}],
   "rack": [{"provider": "github", "repo": "<org>/<repo-principal>", "project": "awesome-gb", "kind": "main",
             "label": "repo-principal", "light": "amber", "default_branch": "main", "ci": "success", "url": "...", "ts": "...",
             "runs": [{"run_id": "9", "workflow": "ci", "status": "in_progress", "conclusion": null, "event": "push",
                       "actor": "...", "head_branch": "be/x", "head_sha": "abc", "url": "...", "updated_at": "...",
                       "origin": {"kind": "thread", "id": "mcp:b7", "label": "backend · awesome-gb/0/backend/0"}}]}]}}
```

Además, cada proyecto lleva sus **salas de máquinas** (aditivo; la app pinta cada una como una sala de su piso, no hay vista
aparte). Son **opcionales**: un proyecto tiene 0, 1 o varias, las que declara su perfil local en `machine_rooms:` (ver
`examples/profiles/awesome-gb.example.yaml`; `chopshop profile check` las valida: `name` único, `floor` = un piso de
`office.floors`, departamentos + salas ≤ 6 por piso). La configuración llega con `office.changed` a `office.machine_rooms` y la
proyección la resuelve en `projects[].machine_rooms`:

```json
{"projects": [{"name": "awesome-gb", "...": "...",
  "office": {"...": "...", "machine_rooms": [
    {"name": "Sala de máquinas", "floor": 0, "repos": ["<org>/<repo-principal>"], "listeners": ["*"], "automations": ["*"],
     "subscriptions": ["*"]},
    {"name": "Sala de docs", "floor": 1, "repos": ["<org>/<engine-cx>"], "listeners": ["forge"], "automations": ["docs-*"],
     "subscriptions": []}]},
  "machine_rooms": [
    {"name": "Sala de máquinas", "floor": 0, "listeners": ["…"], "automations": ["…"], "subscriptions": ["…"], "rack": ["…"]},
    {"name": "Sala de docs", "floor": 1, "listeners": ["…"], "automations": ["…"], "subscriptions": ["…"], "rack": ["…"]}],
  "machine_room": {"name": "Sala de máquinas", "floor": 0, "...": "la primera de machine_rooms"}}]}
```

Qué aloja cada sala (patrones con `*`/`?`/`[…]` estilo `fnmatch`; una lista vacía o ausente = nada de ese tipo): `rack` = los
módulos del rack con `project` igual al proyecto cuyo `repo` (`<dueño>/<repo>`) casa con `repos`; `automations` = las del
proyecto cuyo nombre casa; `listeners` y `subscriptions` = los que casan por `name`. El mismo módulo puede estar en dos salas.
Sin `machine_rooms` en el perfil (o sin `office`): `machine_rooms: []` y el proyecto no pinta ninguna sala.
`projects[].machine_room` se conserva para clientes anteriores: la primera sala o `null`. Se recalcula tras cada sobre
(`machine_room.rooms`, parte de `fold`) y tras rellenar `subscriptions`.

### Escritorios elásticos (flex, pisos temporales y contratista)

Para que un hilo con rol no espere en el vestíbulo, la oficina (`office.py`) tiene capacidad elástica, configurable en el
bloque opcional `capacity:` del perfil (`chopshop profile check` lo valida y muestra la capacidad efectiva):

```yaml
capacity:
  flex_per_floor: 4       # 0-8 (4): escritorios sin asignación por piso declarado (sin pasar de 24 por piso)
  max_extra_floors: 2     # 0-4 (2): pisos temporales "en obra"; recortado a lo que quede de los 16 pisos del edificio
  outsourcing: true       # (true): pasado el tope, pisos del edificio contratista del campus (máximo 4)
```

- Ids: flex `<proyecto>/<piso>/_flex/<n>` (también en los pisos temporales), contratista `<proyecto>/<piso>/_out/<n>`. Los
  índices de piso son estables y no dependen de cuántos pisos declare el perfil (`layout.py`): los declarados van de 0 a 3
  (`MAX_FLOORS_PER_PROJECT` = 4), los temporales desde 4 (`EXTRA_FLOOR_BASE`, hasta 7) y los del contratista desde 8
  (`OUT_FLOOR_BASE` = 4 + `MAX_EXTRA_FLOORS`, hasta 11). Cada tipo abre el siguiente índice libre tras el más alto abierto
  (`layout.next_elastic_floor`); la app los rotula por orden: «En obra · 1», «Contratista · 1». Los roles nunca empiezan por `_`.
- `office` gana `capacity` (efectiva) y `outsourced: null | {label: "Contratista", floors: [...]}`, con los pisos del
  contratista abiertos (`index` 8 en adelante, `temporary: false`); cada piso gana `temporary` (`true` en los pisos en obra,
  índices 4 a 7) y cada sala `flex` (`true` en `_flex`/`_out`). Los pisos declarados
  llevan al final una sala `_flex`; un piso temporal o del contratista lleva solo una sala elástica de N escritorios
  (N = máx(4, escritorios del piso declarado más grande con su flex), tope 24).
- Orden (determinista): sala del rol (herencia o libre) → flex del piso de la sala, luego de los otros pisos declarados por
  distancia → pisos temporales abiertos → abrir uno nuevo → contratista (abiertos, luego abrir otro) → `desk.waiting`. Un
  elástico cuyo ocupante terminó se reutiliza (`desk.released reason: reclaimed`). Entra con `desk.assigned reason: overflow`.
- Estable: un hilo en un elástico solo se mueve para volver a su sala cuando un escritorio de su rol queda libre o su ocupante
  termina (`reason: return`, por orden de llegada; comparte cola con los que esperan en el vestíbulo).
- Abrir o cerrar pisos re-emite `office.changed {by: "capacity"}` (`diff.added` con los escritorios abiertos, `diff.closed`
  con los cerrados). Se cierra el piso más alto (contratista primero) cuando lleva ≥ 180 s vacío y el resto de elásticos
  abiertos está por debajo del 50 %; se borra (no queda `retired`).

### Regla `apply` de los sobres nuevos (la misma en `projection.py` y en `LiveState.swift`)

- `office.changed` → `projects[project].office = {company, half_life_s, floors, machine_rooms, capacity, outsourced}`
  (`machine_rooms` = la configuración de las salas del perfil, `[]` si no declara ninguna); cada escritorio (también los de
  `outsourced.floors`) conserva `occupant`,
  `lineage` y `notes_pending` que ya tuviera (por `id`); los nuevos empiezan con `occupant: null, lineage: [], notes_pending: 0`.
  Un `office.changed` es la estructura **completa** (los retirados vienen con `retired: true`).
- `desk.assigned` → el escritorio `desk` (si no existe en `office`, se ignora) pasa a `occupant = {thread_id, title, role,
  phase, attention, since: body.since || ts, ended_at, touched_at, half_life_s: office.half_life_s, inheritance, zone}`
  (`role` = rol del hilo también en un elástico; `zone` = `body.zone` o `room`: `room | flex | extra | outsourced`), donde
  `title/phase/attention/ended_at/touched_at` salen de la última `task.state` de ese hilo en el mismo proyecto (o `title` del
  cuerpo y `phase: "running"` si aún no hay). `notes_pending` = `body.notes_pending` si viene. El hilo sale del `lobby`. Si el hilo
  ocupaba otro escritorio, ese queda libre (sin linaje: es un traslado).
- `desk.released` con `desk` → si el ocupante es ese hilo: `lineage = [{thread_id, since, until: ts, reason}] + lineage`
  (máximo 5) y `occupant = null`. Con `desk: null` → el hilo sale del `lobby`.
- `desk.waiting` → upsert en `lobby` por `thread_id` con `waiting_role = role` (resto de campos desde la última `task.state`).
- `desk.note` → `notes_pending = body.pending` (si viene; si no, `+1`).
- `task.state` (además de lo de la v2): si el hilo ocupa un escritorio de su proyecto, se refrescan `title, phase, attention,
  ended_at, touched_at` del ocupante (solo las claves que trae el cuerpo; un `task.state` del motor sin `touched_at` no lo borra). Si no ocupa escritorio: con `role` nulo y fase activa (`queued, preparing, running,
  waiting`) entra/se refresca en `lobby` (`waiting_role: null`); si ya está en el `lobby` se refresca (también en fase
  terminal: ahí se desvanece); con fase terminal y sin estar en el `lobby` no entra. `company` y `half_life_s` del elemento
  del lobby salen del `office` del proyecto (o `null` y 1800).
- `listener.state` → upsert en `machine_room.listeners` por `name` (cuerpo + `ts`), ordenados por nombre.
- `automation.ran` → upsert en `machine_room.automations` por `(project, automation)` con `name, trigger, exit,
  duration_ms, error, next_run, severity, ts`.
- `forge.repo.state` → upsert en `machine_room.rack` por `(provider, repo)` (cuerpo sin `ci` crudo extra + `ts`), conservando
  `runs`. `forge.run.state` → upsert del run por `run_id` dentro de su módulo (si el módulo no existe se crea con `light:
  "gray"`); se conservan todos los `status != completed` y los 5 completados más recientes (por `updated_at`, si no por
  orden de llegada). `rack` se ordena por `(project, kind == main ? 0 : 1, repo)`.
- `lobby` se ordena por `(company, project, since)`.
- Los sobres `desk.*`, `office.changed`, `forge.*` y `listener.state` llevan `needs: null`: cierran atención solo de su propio
  sujeto (nunca de la tarea).

`machine_room.subscriptions` lo rellena `GET /state` (y el evento `state` del stream) desde la tabla de suscripciones y la
última entrega (`deliveries`): nombre, `projects` (su filtro), `last_ok`, `last_error` (texto corto, nunca la URL), `signed`. No cambia con los deltas;
la app lo refresca con cada `state`. El test de equivalencia lo excluye.

### Semivida (función pura compartida)

`opacity(phase, attention, ended_at, touched_at, half_life_s, now)`: `1.0` si la fase no es terminal (`done, failed, settled,
skipped`), si hay `attention` o si no hay fechas; si no, `0.5 ^ (t / T)` con `t = max(0, now − max(ended_at, touched_at))` y
`T = half_life_s` (× 2 si `failed`). Sale (se deja de pintar y el agente emite `desk.released reason: faded`) cuando
`opacity < 0.1`, es decir en `base + T·log2(10)`. Tabla compartida: `apps/agent/tests/fixtures/office/halflife.json` (la usan el
test de Python y `HalfLifeTests.swift`).

### Rutas nuevas

| Método y ruta | Descripción |
|---|---|
| `GET /desks/<id>` | `{desk:{id, project, floor, role, slot, permanent, retired}, occupant, lineage:[…20], notes:[pendientes]}` |
| `POST /touch` | `{thread_id}` → reinicia el reloj de semivida (`touched_at = ahora`) y reemite su `task.state` → `{ok, touched_at}` |
| `POST /desks/<id>/notes` | `{from, text, ttl_s?}` (texto ≤ 2 KB; `ttl_s` por defecto 86400) → `desk.note` → `{ok, note_id, pending}` |
| `POST /desks/<id>/assign` | `{thread_id}` → asigna un hilo del vestíbulo (o lo traslada) al escritorio: `desk.assigned reason: manual`. Fija el rol del hilo. 409 si el escritorio está retirado u ocupado por un hilo que no terminó (o con atención); 404 si el escritorio o el hilo no se conocen |
| `PUT /office/<proyecto>` | `{office: {...bloque office...}, rack?: {...}, by}` → valida como `profile check` (400 con la lista de problemas), reescribe esos bloques del perfil local, retira (nunca borra) los escritorios que ya no declara y emite `office.changed {by}` |
| `GET /office/<proyecto>` | (lectura) `{project, rev, office, rack, structure, limits}`: bloques crudos del perfil, estructura con retirados y topes; base para un `PUT` |

Detalle de `PUT /office/<proyecto>` (`agent/structure.py`, guía para los bots en `docs/office-bots.md`):
- Cuerpo: `office` (obligatorio, el bloque completo), `rack` (opcional; si falta no se toca), `by` (obligatorio, ≤ 64),
  `base_rev` (opcional: el `rev` de un `GET`; si el perfil cambió → 409) y `reactivate` (lista de ids retirados que vuelve a
  declarar; sin ella → 409: reactivar lo pide un humano).
- Respuesta: `{ok, project, rev, changed, seq, office: <estructura con retirados>, diff: {added, retired, reactivated}}`.
  Sin cambios de contenido → `changed: false`, no se escribe ni se emite. Errores: `{error, problems?: [...]}`; 404 si no hay
  perfil local (la ruta no crea perfiles).
- Solo se reescriben los bloques `office:`/`rack:` (escritura atómica, mismo modo de archivo); el resto del perfil y sus
  comentarios quedan igual. Si el texto no se puede releer idéntico (p. ej. comillas dobles seguidas de ` #`) → 400.
- Los escritorios conocidos y retirados se recuerdan en `meta` (`office_desks:<proyecto>`; si falta, desde el último
  `office.changed`).

Todas exigen permiso de escritura (dueño, origen local o credencial de servicio/dispositivo). No hay `DELETE` de escritorios ni de
pisos; ninguna ruta crea ni ejecuta scripts.

### Roles permanentes (`[agent.roles]`, opt-in)

Un departamento `permanent: true` cuyo rol declara `office.roles.<rol>.wake` despierta con los disparadores de las
automatizaciones: `schedule` (`cron`/`every`, hora local de la box) y `type` + `where` sobre los sobres del bus (p. ej.
`github.issue.opened` del polling de GitHub) y `desk.note` (una nota en ese escritorio lo despierta si está libre; si está
ocupado la nota espera en la bandeja). Las notas vivas del escritorio entran en el prompt del despertar y se consumen al lanzarlo. El hilo `roles` del agente (solo si `[agent.roles] enabled = true`; apagado por defecto porque
**lanza hilos de T3**) lee el bus con cursor propio (`meta` `roles_cursor`) y, al despertar:

1. elige el primer escritorio permanente del rol sin despertar vivo (**una sola instancia viva por escritorio**); si todos están
   ocupados, el disparo queda como **despertar pendiente** del escritorio (`meta` `role:pending:<escritorio>`, se fusionan
   varios en uno) y se lanza al terminar el hilo vivo;
2. crea un lote de una tarea en el motor (`engine.create_batch`, tarea con `role`, `desk`, `wake`) con el prompt del rol
   (`prompt_file` dentro de `~/.chopshop/automations/<proyecto>/`), el disparador y la herencia del despertar anterior (hilo,
   resumen final, rama, worktree, PRs); el hilo `engine` lo lanza en T3;
3. cuando la tarea tiene `threadId` la oficina (`office.assign(..., reason="wake")`) sienta el hilo en el escritorio:
   `desk.assigned {reason: wake, inheritance, notes_pending}` (se reintenta hasta 15 min si la oficina aún no vio su `task.state`); cuando la tarea termina, cierra el despertar (`desk_wakes`).

Topes: `max_wakes_per_hour` por escritorio (6); `cause.depth >= 3` no despierta; los sobres `desk.*`/`office.*` no cuentan como
disparador por tipo.
Notas (`agent/notes.py`, tabla `desk_notes`): el escritorio debe estar declarado en el perfil local de su proyecto (si no, 404);
`from` es obligatorio salvo que la identidad lo aporte (login, dispositivo u origen); el texto admite saltos de línea y tabuladores
(400 si supera 2 KB). Como mucho 50 notas vivas por escritorio (al pasarse caducan las más viejas). `pending` cuenta las notas sin
consumir y sin caducar. Las consume el hilo que despierta en el escritorio (`notes.consume` + `notes.prompt_block` para su
prompt); el mantenimiento borra las consumidas o caducadas con más de 7 días.

### Colas de empleados y despachador (`[agent.dispatcher]`, opt-in)

Las colas de los empleados (`docs/employees.md`) las llena también el proceso MCP (`task_enqueue`/`task_cancel`), que escribe
en la misma SQLite y emite sus sobres en el mismo bus (`task_cancel` también corta una tarea ya despachada: interrumpe su hilo
y emite `task.cancelled phase: running`; `employee_rename` emite `employee.renamed`). El hilo `dispatcher` del agente (solo si `[agent.dispatcher] enabled = true`, apagado por
defecto porque **lanza hilos de T3**, y solo si algún perfil declara escritorios permanentes), cada `interval` s (5):

1. **anuncia** lo que otro proceso cambió: `task.enqueued` (mismo id que la tarea, `q:<id>`) de cada tarea en cola que aún no
   tiene su sobre y `task.cancelled phase: queued` de cada cancelación de la última hora sin el suyo, cada uno seguido de su
   `queue.changed` (con `cause`; las cortadas en marcha salen `phase: running` con `thread_id` y sin `queue.changed`). Es idempotente (mira el bus), así que también recupera lo encolado con el agente parado;
2. **cierra** los hilos de escritorio terminados (`dispatcher.Dispatcher.close`: settle en T3, la tarea de cola pasa a
   `done`/`failed`, o se queda `cancelled` si la cortó `task_cancel`) y libera su escritorio (`desk.released reason: manual` →
   `employee.idle reason: done|failed|cancelled`; si el hilo
   nunca llegó a sentarse, `employee.idle` sale directo);
3. **despacha**: mientras haya menos de `max_threads` (2) hilos de escritorio vivos en total, saca la primera tarea de la cola de
   cada empleado libre (`queue.changed reason: dequeued`) y la lanza como lote de una tarea del motor (`role`, `desk`, `qtask`);
4. cuando la tarea tiene `threadId`, la oficina sienta el hilo en el escritorio (`desk.assigned reason: wake`, mismo reintento
   que los roles) y sale `employee.assigned {reason: queue, task: <tarea de cola>}`.

Sin el despachador habilitado o sin empleados declarados el agente no hace nada de esto (la cola se ve igual en `/state` y
`/snapshot`).

| Método y ruta | Descripción |
|---|---|
| `POST /queue/cancel` | `{employee, task, by?, note?}` (`by` por defecto `human`) → cancela una tarea **en cola** (`task.cancelled {phase: queued, reason: manual}` + `queue.changed reason: cancelled`) → `{ok, task, employee, state: "cancelled", queue_len}`. 404 si la tarea no existe, es de otro empleado o ya salió de la cola; 400 si el cuerpo es inválido. Exige permiso de escritura. Funciona aunque el despachador esté apagado |

Detalle de `POST /queue/cancel` (`server.r_queue_cancel`): `employee` (≤ 128) y `task` (`q:…`) son obligatorios; `by` ≤ 64
caracteres y `note` ≤ 500, sin caracteres de control. La razón siempre es `manual`. Solo saca tareas en estado `queued`: para cortar
una tarea ya despachada (con hilo en marcha) usa la herramienta MCP `task_cancel`. 503 si el agente no tiene cola (solo pasa fuera
del servicio, p. ej. en tests). Ejemplo desde la propia máquina:

```sh
curl -s -X POST http://127.0.0.1:3790/queue/cancel -H 'Content-Type: application/json' \
  -d '{"employee": "awesome-gb/0/triage/0", "task": "q:01MCC5Y3S0F8YH6PV8TEN7BD00", "note": "duplicada"}'
```

### Empleados y colas: resumen

- **Empleado** = escritorio permanente (`permanent: true`) del perfil; id `<proyecto>/<piso>/<rol>/<n>`. Los elásticos (`_flex`,
  `_out`) no son empleados. Su nombre se elige de forma determinista del pool de nombres (`chopshop/names.py`; un archivo local
  `~/.chopshop/names/<proyecto>.yaml` con `names: [...]` y `mode: extend|replace` lo amplía o lo reemplaza); un
  `employee_rename` lo fija y la sincronización con el perfil ya no lo pisa. Tabla `employees` (`chopshop/employees.py`).
- **Cola** = FIFO por empleado (tabla `employee_queue`, `chopshop/queue.py`): máx. 20 tareas en cola por empleado (más → error
  «cola llena»), orden `priority` descendente y luego orden de llegada. `key` hace idempotente el encargo: repetir la misma `key`
  para el mismo empleado devuelve la tarea existente (`created: false`), aunque ya haya terminado. Estados: `queued`, `dequeued`
  (despachada), `cancelled`, `done`, `failed`. Razones de cancelación: `manual`, `superseded`, `retired`, `expired`.
- Se ven en `GET /snapshot` y `GET /state` (`employees[]`, `queues{}`), en los sobres `employee.*`, `queue.changed`, `task.*` y,
  por el relay, en la parte `employees` del snapshot. Forma exacta y eventos: `docs/employees.md`.

### Herramientas MCP de proyectos, empleados y colas

Las sirve `chopshop mcp serve` (README, «Servidor MCP multi-máquina»). A diferencia de `thread_*` y `fanout`, que llaman a la API
de cada agente, estas trabajan sobre la máquina donde corre el MCP: leen los perfiles locales (`profile.load`) y escriben en la
SQLite del agente local (`[agent] db_path`), en el mismo bus. El despachador de ese agente las anuncia y las ejecuta.

| herramienta | argumentos (obligatorios en **negrita**) | qué hace y devuelve |
|---|---|---|
| `registry_list` | `include_disabled` | Proyectos de `projects.toml` (junto al `config.toml`): empresa, proyecto de T3, host, roles. |
| `project_register` | **`name`**, `company` (obligatoria si es nuevo), `t3_project`, `repo`, `host` | Registra o reactiva un proyecto (idempotente); crea un perfil mínimo si falta. |
| `role_list` | **`project`** | Roles del perfil: `{role, desks, permanent, zones, wake, prompt_file}` por rol, más `registered`. |
| `task_enqueue` | **`project`**, **`role`**, **`title`**, `slot`, `floor`, `priority`, `by` (`human`), `key` | Encola en el empleado del rol con la cola más corta (o el de `slot`/`floor`): `task.enqueued` + `queue.changed reason: enqueued` → `{task, employee, created, state, position, queue_len}`. El título es también el prompt de la tarea. |
| `queue_show` | **`project`**, `role` | `{project, queues: [{employee, role, items, updated}]}` en orden de ejecución. |
| `task_cancel` | **`task`**, `reason` (`manual`), `note`, `by` (`human`) | En cola: la saca (`task.cancelled phase: queued` + `queue.changed reason: cancelled`). Despachada con hilo: interrumpe el hilo en T3 (`t3_thread_interrupt`, nunca archiva), marca la tarea del motor como terminada y emite `task.cancelled phase: running` con `thread_id`; el despachador luego hace settle y emite `employee.idle reason: cancelled`. → `{task, employee, state, reason, phase, thread_id, queue_len}`. Error si no existe, ya terminó o aún no tiene hilo (reintentar en unos segundos). |
| `employee_rename` | **`employee`**, **`name`** (`null` quita el nombre), `by` (`human`) | Nombre de 1 a 32 caracteres (letras, espacios, `'` o `-`); `by` no puede ser `profile`. Emite `employee.renamed` → `{employee, role, name, previous, by}`. |

## Suscripciones (webhooks v2)

Cada suscripción es **un webhook** (la URL vive en `webhook_file`, primera línea, 0600) que recibe el **sobre completo** (§2.1 del
diseño de eventos: `v, id, seq, ts, machine, project, type, severity, needs, subject, cause, body`) como `POST` JSON. Durante un
ciclo de versión el cuerpo trae además `event` (nombre viejo, p. ej. `pending_question`; o el `type` si no hay nombre viejo) y
`machine_id`.

```json
{"name":"bot-nuskills","webhook_file":"~/.config/chopshop/webhooks/bot-nuskills.url","projects":["nuskills"],
 "types":["question.*","approval.requested","task.state"],"exclude_types":["machine.health"],
 "min_severity":"notice","needs":["bot","human"],"only_changes":true,"context":true,"debounce_s":5,
 "secret_file":"~/.config/chopshop/webhooks/bot-nuskills.key"}
```

Filtros (todos opcionales; `null` = sin filtro):
- `projects`: lista con globs (`fnmatch`, `*` incluye eventos sin proyecto). Si falta se usa `project` (exacto o `*`, como antes).
- `types`: globs sobre el `type` (`question.*`, `github.*`); también casan con el nombre viejo (`event`). Lista vacía = todos.
- `exclude_types`: globs; gana sobre `types`.
- `min_severity`: `info < notice < warn < error`.
- `needs`: `human | bot | approval | none` (`none` = eventos con `needs: null`, p. ej. los que cierran una atención). Vacío = cualquiera.
- `only_changes`: omite `task.state` cuyo `phase`/`attention` no cambió respecto del último `task.state` del mismo sujeto visto por
  esta suscripción (en memoria: tras reiniciar el agente se entrega el primero).
- `debounce_s` (0–3600): colapsa ráfagas por sujeto; ventana fija desde el primer evento, se entrega solo el último (los colapsados no
  dejan fila en `deliveries`).
- `context: true`: añade `body.context = {recent: [≤5 sobres previos del mismo sujeto, del más viejo al más nuevo],
  project_summary: {project, counts: {tasks, <phase>: n, needs_human, waiting_bot, stuck}}}` (contadores del último `task.state` de
  cada sujeto entre los 500 eventos más recientes del proyecto).
- `batch_window_s`: reservado (solo `0` en v1).

**Compatibilidad**: las suscripciones viejas (`project` + `events: [nombres]`, sin columnas v4) siguen igual: un nombre viejo casa con
el nombre viejo del evento (`event`; así `events: ["thread_done"]` no recibe todo `task.state`, y el `task.state` acompañante de una
pregunta no cuenta como `pending_question`) y, si el evento no tiene nombre viejo, con su tipo nuevo vía `LEGACY_MAP`
(`pending_question` → `question.opened`). `events` vacío = todos. `cfg["webhook_files"]` = destinos sin filtro.

**Entrega**: cabeceras `X-Chopshop-Event: <type>`, `X-Chopshop-Id: <id>` (clave de idempotencia; igual en todos los intentos),
`X-Chopshop-Delivery: <n.º de intento, 1–4>` y, con `secret_file`, `X-Chopshop-Signature: sha256=<hex(HMAC-SHA256(secreto, cuerpo))>`
(el secreto = contenido del archivo sin espacios; si el archivo falta o es legible por grupo/otros no se envía nada). Verificación en el
receptor: `hmac.compare_digest(cabecera, "sha256=" + hmac.new(secreto, cuerpo_crudo, sha256).hexdigest())`.
Con `headers_file` (0600; una cabecera por línea `Nombre: valor`, vacías y `#...` se ignoran) se añaden esas cabeceras, p. ej.
`Authorization: Bearer …` para receptores que la exigen (los webhooks de Grok responden `401` sin ella). No se pueden pisar
`Content-Type`, `Content-Length`, `Host`, `User-Agent`, `Transfer-Encoding`, `Connection` ni `X-Chopshop-*`; un archivo que falta, es
legible por otros o está mal formado hace que no se envíe nada (definitivo). Se relee en cada intento; los valores nunca se guardan ni
se registran.
Timeout 3 s por intento; **3 reintentos** tras 2, 10 y 60 s ante error de red, `5xx`, `408`, `425` o `429` (otros `4xx` y archivos
ilegibles son definitivos). Cada destino tiene su propio carril (hilo) y los reintentos se programan sin ocupar hilo: un destino lento o
caído no retrasa a otro. `deliveries(event_seq, name, ok, detail, ts, attempts, next_retry)` guarda el último intento (`detail` =
`HTTP <código>` o el tipo de excepción; nunca la URL, el secreto ni mensajes de excepción) y `next_retry` (epoch) si queda reintento.
Cada intento se registra además en el log (journal) como `chopshop.agent.webhooks`: `webhook <nombre>: seq=<n> type=<type>
intento=<n>/4 <detail> <ms>ms <ok | reintento N en Ss | sin reintento | reintentos agotados>` (INFO si ok, WARNING si no). Con nivel
DEBUG también los omitidos por `only_changes` y los retenidos por `debounce_s`.

**CLI**: `chopshop subscribe <nombre> --webhook-file F [--project p1,p2] [--types 'question.*,task.state'] [--exclude-types ...]
[--min-severity notice] [--needs bot,human] [--only-changes] [--context] [--debounce 5] [--secret-file K] [--headers-file H]` registra en el agente
(`POST /subscriptions`); `chopshop subscribe --list --agent` lista los filtros. Sin opciones v2 ni `--agent` el comando sigue escribiendo
la suscripción del motor viejo (`state.json`), como antes.

**Esquema**: `user_version` 4 añade a `subscriptions` las columnas nulables `projects`, `types`, `exclude_types`, `needs` (JSON),
`min_severity`, `only_changes`, `context`, `debounce_s`, `secret_file`, y a `deliveries` `attempts`, `next_retry`. La migración es
idempotente (solo añade columnas que falten) y conserva las suscripciones existentes. `user_version` 5 son las tablas de la oficina; la 6 añade
`subscriptions.headers_file` (nulable).

## Decisiones de los módulos (resumen)

- **Eventos**: los de T3 (`thread_*`, `pending_question`, `pending_approval`, `t3_unreachable`, `t3_recovered`) y `agent_started` al
  arrancar. El agente mismo corre en `chopshop.slice`.
- **`emit_fn(event, project, body)`**: `T3` (poll) lo recibe; el servicio lo implementa sobre `events.emit`.
- **Hilos**: muestreo + compactación (`Collector.run_forever`), sondeo de T3 (`t3_poll_interval`, con backoff propio), motor (`engine.tick` con el bus inyectado cada `engine_interval` s si hay lotes en `state.json`), importación de `events.jsonl` (`legacy_interval`) y mantenimiento horario (retención de eventos `retention.events_days`, checkpoint WAL). Parada limpia con SIGTERM/SIGINT.
- **Migración**: al arrancar y cada `legacy_interval` s, `events.import_legacy(<general.home>/events.jsonl)` si existe y `agent.import_legacy = true` (idempotente).
