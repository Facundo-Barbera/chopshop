# chopshop-agent: contrato de módulos y API (v0.6, api_version 1)

Contexto: el agente corre en cada máquina como servicio de usuario (`systemd --user` en Linux, launchd en macOS). Escucha en
`agent.bind`:`agent.port` (`~/.config/chopshop/config.toml`, ver `config.example.toml`): por defecto `127.0.0.1`; para otras máquinas,
`"auto"` (IP de Tailscale) o la IP concreta (p. ej. `100.64.0.10`). **Nunca** `0.0.0.0` ni `::` (se niega a arrancar). Si `bind` no es
loopback abre además `127.0.0.1:<port>` (`agent.local_listener`) para el CLI local. Instalación y operación: `docs/agent-service.md`.
La app es un cliente puro. Stdlib de Python solamente (>=3.9 compatible).
El agente es una capa delgada sobre T3: observa (métricas, hilos, eventos) y solo escribe en T3 por `answer`/`settle`. **No** lanza ni
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
| `server.py`, `service.py` | integrador | `server.py`: `ThreadingHTTPServer`, `Authenticator` y las rutas (`AgentApp`). `service.py`: `AgentService` (ensambla módulos, hilos de fondo, parada limpia) y el CLI `chopshop agent run\|status\|token\|check-config\|print-unit`. |
| `ui/` | hilo UI | cliente puro de la API (ver abajo). |

Convención: funciones que fallan lanzan excepciones propias del módulo; nada imprime secretos; todo es testeable sin red ni systemd
(inyecta runners: `T3(..., runner=callable)`, el `runner` de tailscale del `Authenticator` y el `poster` de webhooks).

## API HTTP (JSON, UTF-8). Auth

Orden de decisión por petición (`agent.auth`, por defecto `tailscale+token`):

1. **Origen local** (loopback o la propia IP de escucha del agente: CLI de la misma máquina) → aceptado, lectura y escritura
   (`agent.trust_local = true`; con `false` también el origen local pasa por lo que sigue).
2. `auth = "none-local"` → cualquier otro origen: 403.
3. `auth = "token"` → hace falta `Authorization: Bearer <token>` (archivo `token_file`, 0600) en **toda** petición, lectura incluida.
4. `auth = "tailscale+token"` → `tailscale whois --json <ip origen>` (cache 60 s; fallos 5 s) → `UserProfile.LoginName` (login completo,
   sin distinguir mayúsculas) debe ser `owner_login` (lectura y escritura) o estar en `allowed_logins` (**solo lectura**). Las
   **escrituras** (`POST`/`DELETE`) del propietario exigen además el bearer.

Sin identidad válida, o sin permiso para escribir → **403** (también en rutas inexistentes: no se puede sondear sin identidad). El
bearer se compara con `hmac.compare_digest`. No se confía en cabeceras `X-Forwarded-*`.
- Cuerpo máximo 64 KiB (413), `Content-Length` obligatorio (sin chunked: 411), JSON UTF-8 objeto (400), timeout de conexión 15 s.
- Errores: `{"error": "mensaje"}` + código HTTP (400 petición inválida/`AnswerError`, 403, 404, 405, 413, 500 `error interno`, 502 T3 falló,
  503 T3 desactivado). Respuestas y logs **nunca** incluyen URLs de webhooks ni tokens (las suscripciones solo guardan RUTAS de archivo).
- El agente no ejecuta comandos de clientes: no hay rutas para lanzar servidores, pedir puertos ni matar procesos (eso es de T3).

| Método y ruta | Descripción |
|---|---|
| `GET /health` | `{ok, api_version, version, machine_id, ts, uptime, whoami}` |
| `GET /snapshot` | ver forma abajo (lo que pinta la UI) |
| `GET /metrics?from=&to=&group=machine\|app\|project&step=` | series (ver `collector.query`) |
| `GET /events?after=<seq>&limit=` | `{events:[{seq,ts,machine_id,event,project,body}], last_seq, head_seq}`: `last_seq` = cursor para la siguiente consulta (seq del último devuelto, o `after` si no hay), `head_seq` = último de la máquina |
| `GET /threads?project=&limit=` | `{threads:[...]}` desde `t3_threads` (más recientes primero) |
| `GET /subscriptions` | `{subscriptions:{nombre:{project,events,created,projects,types,exclude_types,min_severity,needs,only_changes,context,debounce_s,signed}}}` (filtros; sin URL ni rutas; `signed` = tiene `secret_file`). Ver «Suscripciones (webhooks v2)» |
| `POST /answer` | `{thread_id, choice, request?}` → responde en T3 (`{ok, request_id, answers, question}`). `AnswerError` (sin pendientes, ambigua, opción no válida) → 400; T3 caído → 502 |
| `POST /settle` | `{thread_id}` → `t3_thread_organize settle` (nunca archivar) → `{ok, thread_id}` |
| `POST /subscriptions` / `DELETE /subscriptions/<name>` | `{name, webhook_file, project?, events?, projects?, types?, exclude_types?, min_severity?, needs?, only_changes?, context?, debounce_s?, secret_file?}` (`webhook_file`/`secret_file` = rutas de archivos existentes en la máquina del agente, nunca una URL; `secret_file` con permisos 0600). Reemplaza la suscripción entera. Valores inválidos → 400 |

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
  "agent": {"version": "0.6.0", "uptime": 12, "t3_ok": true, "last_sample_age": 3.2, "last_poll_age": 2.0}
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
- `types`: globs sobre el `type` (`question.*`, `github.*`); también casan con el nombre viejo (`body.legacy`). Lista vacía = todos.
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
el `body.legacy` del sobre (así `events: ["thread_done"]` no recibe todo `task.state`) y, si el sobre no trae nombre viejo, con su tipo
nuevo vía `LEGACY_MAP` (`pending_question` → `question.opened`). `events` vacío = todos. `cfg["webhook_files"]` = destinos sin filtro.

**Entrega**: cabeceras `X-Chopshop-Event: <type>`, `X-Chopshop-Id: <id>` (clave de idempotencia; igual en todos los intentos),
`X-Chopshop-Delivery: <n.º de intento, 1–4>` y, con `secret_file`, `X-Chopshop-Signature: sha256=<hex(HMAC-SHA256(secreto, cuerpo))>`
(el secreto = contenido del archivo sin espacios; si el archivo falta o es legible por grupo/otros no se envía nada). Verificación en el
receptor: `hmac.compare_digest(cabecera, "sha256=" + hmac.new(secreto, cuerpo_crudo, sha256).hexdigest())`.
Timeout 3 s por intento; **3 reintentos** tras 2, 10 y 60 s ante error de red, `5xx`, `408`, `425` o `429` (otros `4xx` y archivos
ilegibles son definitivos). Cada destino tiene su propio carril (hilo) y los reintentos se programan sin ocupar hilo: un destino lento o
caído no retrasa a otro. `deliveries(event_seq, name, ok, detail, ts, attempts, next_retry)` guarda el último intento (`detail` =
`HTTP <código>` o el tipo de excepción; nunca la URL, el secreto ni mensajes de excepción) y `next_retry` (epoch) si queda reintento.

**CLI**: `chopshop subscribe <nombre> --webhook-file F [--project p1,p2] [--types 'question.*,task.state'] [--exclude-types ...]
[--min-severity notice] [--needs bot,human] [--only-changes] [--context] [--debounce 5] [--secret-file K]` registra en el agente
(`POST /subscriptions`); `chopshop subscribe --list --agent` lista los filtros. Sin opciones v2 ni `--agent` el comando sigue escribiendo
la suscripción del motor viejo (`state.json`), como antes.

**Esquema**: `user_version` 4 añade a `subscriptions` las columnas nulables `projects`, `types`, `exclude_types`, `needs` (JSON),
`min_severity`, `only_changes`, `context`, `debounce_s`, `secret_file`, y a `deliveries` `attempts`, `next_retry`. La migración es
idempotente (solo añade columnas que falten) y conserva las suscripciones existentes.

## Decisiones de los módulos (resumen)

- **Eventos**: los de T3 (`thread_*`, `pending_question`, `pending_approval`, `t3_unreachable`, `t3_recovered`) y `agent_started` al
  arrancar. El agente mismo corre en `chopshop.slice`.
- **`emit_fn(event, project, body)`**: `T3` (poll) lo recibe; el servicio lo implementa sobre `events.emit`.
- **Hilos**: muestreo + compactación (`Collector.run_forever`), sondeo de T3 (`t3_poll_interval`, con backoff propio) y mantenimiento horario (retención de eventos `retention.events_days`, checkpoint WAL). Parada limpia con SIGTERM/SIGINT.
- **Migración**: al arrancar, `events.import_legacy(<general.home>/events.jsonl)` si existe y `agent.import_legacy = true`.
