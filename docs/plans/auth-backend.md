# Plan: backend con cuentas para chopshop (relay v2)

Estado: diseño aprobado para implementar (2026-10-30). Sustituye al relay de tokens `cr1_` (`docs/relay-protocol.md` v1,
`packages/relay`). Cada sección es un **contrato**: los hilos que implementan no pueden preguntar, así que si algo no está aquí
se elige lo más simple que respete estas reglas y se anota en la respuesta del hilo. Si este plan y un schema de
`packages/api/backend/` no coinciden después de implementarse, manda el schema y se corrige el plan en el mismo cambio.

Glosario fijo (mismos nombres en todo el documento, en el código y en la API):

| término | significado |
|---|---|
| **dueño** (`owner`) | la única persona propietaria: posee todas las máquinas, workspaces y su ciudad; edita todo |
| **watcher** (`watcher`) | persona invitada con login; **solo lectura** sobre los workspaces que el dueño comparta con ella |
| **workspace** = **campus** | área de trabajo a nivel empresa, con uno o más proyectos; su estructura vive en la nube |
| **ciudad** | lo que ve un usuario: la unión de los campus a los que tiene acceso (el dueño: todos) |
| **proyecto** | lo que hoy es un perfil `~/.chopshop/profiles/<p>.yaml` + su entrada en `projects.toml`; pertenece a un workspace |
| **rol** / **empleado** | rol de la oficina de un proyecto (`office.roles`); un empleado es un escritorio `permanent` de ese rol (id K2 `proyecto/piso/rol/slot`) |
| **máquina** | un `chopshop-agent` ligado a la cuenta del dueño; **solo ejecuta** |
| **Hub** | el único Durable Object del backend (`idFromName("owner")`) |
| **API** | `https://api.chopshop.novarix.online` (HTTP, SSE y WebSocket) |
| **web** | `https://chopshop.novarix.online` (web admin estática) |

Prefijos de secretos (todos de 32 bytes aleatorios en base64url sin relleno = 43 caracteres, salvo el código de recuperación):

| secreto | formato | quién lo tiene | se guarda en el backend |
|---|---|---|---|
| token de sesión | `ss1_<43>` | app Mac (Keychain), CLI; la web lo recibe solo como cookie HttpOnly | `sha256` hex |
| credencial de máquina | `cm1_<43>` | agente (`machine.json`, 0600) | `sha256` hex |
| token de invitación | `ci1_<43>` | el enlace de invitación (fragmento `#t=`) | `sha256` hex |
| token CSRF (web) | `cx1_<43>` | memoria de la web | `sha256` hex en la sesión |
| código de recuperación | `XXXXX-XXXXX-XXXXX-XXXXX` (20 símbolos Crockford = 100 bits) | el dueño, fuera de línea | `sha256` hex del código normalizado |
| secret de operador | `RELAY_OPERATOR_TOKEN` (ya existe) | secret del Worker y del repo; el operador en contabo | nunca en D1 |

`sha256` siempre sobre el texto UTF-8 completo del secreto, con prefijo incluido. Ningún secreto va en una URL que llegue a un
servidor (el enlace de invitación lo lleva en el fragmento `#`, que el navegador no envía).

---

## 1. Arquitectura

```
 app Mac / CLI ──Bearer ss1_──┐                         ┌── D1 "chopshop" (SQL global, fuente de verdad)
 web (chopshop.…) ─cookie────►│  Worker "chopshop-api"  │      usuarios, invitaciones, sesiones, máquinas,
 agente ──Bearer cm1_ (WS)───►│  api.chopshop.…         ├──►   workspaces, miembros, proyectos, roles, layouts,
 operador ─RELAY_OPERATOR_TOKEN►  (auth + autorización) │      importaciones, auditoría, intentos de login
                              │                         │
                              └── RPC ──► Durable Object Hub idFromName("owner")
                                          SQLite propio: último snapshot por (máquina, workspace), estado de conexión
                                          WebSockets de los agentes (Hibernation), visores SSE, comandos en vuelo
```

- **Un Worker** (`apps/backend`, nombre de despliegue `chopshop-api`) atiende todo: resuelve el principal (sesión, credencial de
  máquina u operador), autoriza, lee/escribe D1 y llama al Hub por **RPC** (métodos del `DurableObject`, no `fetch` con
  cabeceras). El Worker es el único que puede llamar al Hub; un cliente nunca habla con el Hub directamente.
- **Un solo Hub**, siempre `env.HUB.idFromName("owner")`. Ningún parámetro de cliente participa en elegirlo: no existe otro Hub
  al que llegar. El aislamiento entre personas no se hace por Hubs sino **por vista**: el Worker calcula en D1 qué workspaces
  puede ver el principal y se los pasa al Hub en un `ViewCtx`; el Hub filtra cada snapshot y evento por `workspace_id` y vuelve
  a comprobar que el rol permita la operación (doble verificación, §5.3).
- **D1** es la fuente de verdad de todo lo que no es «en vivo». El Hub tiene binding a D1 (solo para leer la estructura que
  sincroniza a las máquinas y escribir resultados de importación/auditoría); el resto lo escribe el Worker.
- **Web admin** estática servida por el mismo Worker con Workers Assets en el host `chopshop.novarix.online`; consume la misma
  API pública que la app Mac (no hay rutas exclusivas de la web).
- **Cron** del Worker (`17 4 * * *`): purga sesiones caducadas, invitaciones viejas, intentos de login y auditoría > 180 días.

### D1 vs SQLite del Hub, dato por dato

| dato | dónde | por qué |
|---|---|---|
| usuarios, invitaciones, sesiones, intentos de login | D1 | se consultan en cada petición desde el Worker, antes de tocar el Hub; consultas relacionales; la web admin los lista |
| máquinas (identidad, credencial, pausa, revocación) | D1 | la credencial se valida en el Worker antes del upgrade; revocar debe sobrevivir a reinicios del Hub |
| workspaces, miembros, campus, proyectos, roles, layouts | D1 | fuente de verdad editable por la API; portable a Postgres; el Hub solo la lee para armar el `sync` |
| importaciones ofrecidas por los agentes | D1 | se revisan y aplican desde la app (transacción con la creación de proyectos) |
| auditoría (comandos, auth, máquinas) | D1 | consultable por la app y la web; retención con cron |
| tareas de las colas (fase S2) | D1 | la nube es la fuente de verdad; compare-and-set por `rev` |
| último snapshot por (máquina, workspace) con TTL | SQLite del Hub | llega cada pocos segundos y se sirve desde memoria; al SQLite se persiste como mucho uno por minuto y par (límite gratis de filas escritas, §12); efímero; solo lo sirve el Hub; sobrevive a la hibernación |
| estado de cada WebSocket (máquina, `hello`, cuotas) | adjunto del WebSocket (`serializeAttachment`) | igual que hoy en `agentws.ts` |
| buffer de reanudación del stream (512 frames / 5 min) | memoria del Hub | igual que hoy en `viewer.ts`; perderlo solo fuerza `resume: "snapshot"` |
| comandos en vuelo (esperando `cmd.result`) | memoria del Hub | vida ≤ 30 s; si el Hub reinicia, el Worker responde `timeout` y la auditoría lo refleja |
| caché de máquina→workspaces y estado pausa/revocación | SQLite del Hub (`machine_cache`) | evita leer D1 en cada frame; el Worker la invalida por RPC en cada cambio |

---

## 2. Modelo de datos (D1)

Reglas de portabilidad a Postgres (obligatorias en todas las migraciones):

- Ids `TEXT` con UUID v4 en minúsculas (`crypto.randomUUID()`); nada de `AUTOINCREMENT` ni `rowid`.
- Fechas `TEXT` ISO-8601 UTC con milisegundos y `Z` (`2026-10-30T12:00:00.000Z`), generadas por la aplicación; nada de
  `datetime('now')` ni `DEFAULT CURRENT_TIMESTAMP`. Se comparan como texto (el formato fijo lo hace correcto).
- Sin booleanos: un estado se expresa con una fecha nullable (`revoked_at`, `paused_at`) o con un `TEXT` con `CHECK`.
- JSON en columnas `TEXT` (en Postgres pasarán a `jsonb`); el Worker valida forma y tamaño antes de escribir (máx. 256 KiB).
- Sin `STRICT`, sin `WITHOUT ROWID`, sin funciones JSON de SQLite en consultas. Sí: `CHECK`, `FOREIGN KEY`, índices parciales
  (`WHERE`), `ON CONFLICT … DO UPDATE` (existen en ambos).
- Migraciones numeradas en `apps/backend/migrations/NNNN_nombre.sql` (formato de `wrangler d1 migrations`); nunca se edita una
  migración ya aplicada en producción: se añade otra.
- Concurrencia optimista: toda entidad editable tiene `rev INTEGER NOT NULL DEFAULT 1`; un `PATCH`/`PUT` trae `rev` y la
  consulta es `UPDATE … SET …, rev = rev + 1 WHERE id = ? AND rev = ?`; 0 filas → 409 `conflict` con el recurso actual.

### `0001_identity.sql`

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  email_normalized TEXT NOT NULL UNIQUE,
  display_name TEXT,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner', 'watcher')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  recovery_hash TEXT,
  invited_by TEXT REFERENCES users (id),
  password_changed_at TEXT NOT NULL,
  last_login_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX users_one_owner ON users (role) WHERE role = 'owner';

CREATE TABLE workspaces (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES users (id),
  name TEXT NOT NULL,
  slug TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0,
  style TEXT NOT NULL DEFAULT '{}',
  rev INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  archived_at TEXT
);
CREATE UNIQUE INDEX workspaces_slug ON workspaces (owner_id, slug) WHERE archived_at IS NULL;

CREATE TABLE workspace_members (
  workspace_id TEXT NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'watcher' CHECK (role IN ('watcher')),
  added_by TEXT NOT NULL REFERENCES users (id),
  created_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, user_id)
);
CREATE INDEX workspace_members_user ON workspace_members (user_id);

CREATE TABLE invitations (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('owner_bootstrap', 'owner_reset', 'watcher')),
  email TEXT NOT NULL,
  email_normalized TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner', 'watcher')),
  created_by TEXT REFERENCES users (id),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  used_by TEXT REFERENCES users (id),
  revoked_at TEXT
);
CREATE INDEX invitations_pending ON invitations (email_normalized) WHERE used_at IS NULL AND revoked_at IS NULL;

CREATE TABLE invitation_workspaces (
  invitation_id TEXT NOT NULL REFERENCES invitations (id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
  PRIMARY KEY (invitation_id, workspace_id)
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  csrf_hash TEXT,
  client TEXT NOT NULL CHECK (client IN ('mac', 'web', 'cli')),
  device_name TEXT,
  user_agent TEXT,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  absolute_expires_at TEXT NOT NULL,
  revoked_at TEXT,
  revoked_reason TEXT CHECK (revoked_reason IN ('logout', 'revoked', 'password_changed', 'user_disabled', 'recovered'))
);
CREATE INDEX sessions_user ON sessions (user_id) WHERE revoked_at IS NULL;
CREATE INDEX sessions_expiry ON sessions (expires_at);

CREATE TABLE auth_attempts (
  key_hash TEXT PRIMARY KEY,
  failures INTEGER NOT NULL DEFAULT 0,
  window_start TEXT NOT NULL,
  locked_until TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT INTO meta (key, value) VALUES ('structure_rev', '0');
```

`workspace_members.role` solo admite `watcher` hoy; el dueño no tiene fila (es dueño de todo por `users.role = 'owner'`). Un
rol nuevo (p. ej. editor) es una migración que amplía el `CHECK`; no se diseña aquí.

### `0002_machines.sql`

```sql
CREATE TABLE machines (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES users (id),
  name TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('macos', 'linux', 'other')),
  local_machine_id TEXT,
  credential_hash TEXT NOT NULL UNIQUE,
  linked_via TEXT NOT NULL CHECK (linked_via IN ('app', 'token')),
  agent_version TEXT,
  created_by_session TEXT REFERENCES sessions (id),
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  paused_at TEXT,
  revoked_at TEXT
);
CREATE UNIQUE INDEX machines_local ON machines (owner_id, local_machine_id)
  WHERE revoked_at IS NULL AND local_machine_id IS NOT NULL;

CREATE TABLE workspace_machines (
  workspace_id TEXT NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
  machine_id TEXT NOT NULL REFERENCES machines (id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, machine_id)
);
CREATE INDEX workspace_machines_machine ON workspace_machines (machine_id);

CREATE TABLE audit_log (
  id TEXT PRIMARY KEY,
  at TEXT NOT NULL,
  actor_kind TEXT NOT NULL CHECK (actor_kind IN ('user', 'operator', 'machine', 'system')),
  actor_user_id TEXT REFERENCES users (id),
  session_id TEXT,
  machine_id TEXT REFERENCES machines (id),
  action TEXT NOT NULL,
  target_kind TEXT,
  target_id TEXT,
  command TEXT,
  result TEXT NOT NULL CHECK (result IN ('ok', 'denied', 'error', 'timeout')),
  status INTEGER,
  detail TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX audit_at ON audit_log (at);
CREATE INDEX audit_machine ON audit_log (machine_id, at);
```

En lugar de `machines.workspace_id` (borrador inicial) se usa `workspace_machines`: una máquina puede ejecutar proyectos de
varios campus y aparecer en cada uno. `local_machine_id` es el `machine_id` del agente (`[agent] machine_id` o el hostname): lo
fija `POST /v1/machines/link`, o el primer `hello` si la máquina se creó con token para VPS (§4.10).

`audit_log.action` ∈ `auth.login`, `auth.login_failed`, `auth.logout`, `auth.password_changed`, `auth.recovered`,
`auth.recovery_code_regenerated`, `session.revoked`, `user.disabled`, `user.enabled`, `invitation.created`,
`invitation.reissued`, `invitation.revoked`, `invitation.accepted`, `operator.bootstrap`, `operator.recover`,
`machine.linked`, `machine.token_issued`, `machine.paused`, `machine.resumed`, `machine.revoked`, `workspace.shared`,
`workspace.unshared`, `import.applied`, `command`. `detail` nunca lleva secretos, contraseñas, prompts ni IPs.

### `0003_structure.sql`

```sql
CREATE TABLE campus_layouts (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces (id) ON DELETE CASCADE,
  layout TEXT NOT NULL DEFAULT '{}',
  rev INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces (id),
  name TEXT NOT NULL,
  title TEXT,
  t3_project TEXT,
  repo TEXT,
  machine_id TEXT REFERENCES machines (id),
  runtime_mode TEXT NOT NULL DEFAULT 'approval-required'
    CHECK (runtime_mode IN ('approval-required', 'auto-accept-edits', 'auto', 'full-access')),
  model TEXT,
  settings TEXT NOT NULL DEFAULT '{}',
  position INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  disabled_at TEXT,
  archived_at TEXT
);
CREATE UNIQUE INDEX projects_name ON projects (name) WHERE archived_at IS NULL;
CREATE INDEX projects_workspace ON projects (workspace_id) WHERE archived_at IS NULL;
CREATE INDEX projects_machine ON projects (machine_id) WHERE archived_at IS NULL;

CREATE TABLE project_layouts (
  project_id TEXT PRIMARY KEY REFERENCES projects (id) ON DELETE CASCADE,
  layout TEXT NOT NULL DEFAULT '{}',
  rev INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE roles (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL DEFAULT '',
  model TEXT,
  match_rules TEXT NOT NULL DEFAULT '{}',
  wake TEXT NOT NULL DEFAULT '[]',
  settings TEXT NOT NULL DEFAULT '{}',
  position INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project_id, name)
);

CREATE TABLE import_offers (
  id TEXT PRIMARY KEY,
  machine_id TEXT NOT NULL REFERENCES machines (id) ON DELETE CASCADE,
  payload_hash TEXT NOT NULL,
  payload TEXT NOT NULL,
  summary TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  applied_at TEXT,
  applied_by TEXT REFERENCES users (id),
  dismissed_at TEXT,
  UNIQUE (machine_id, payload_hash)
);
```

Correspondencia con el perfil YAML actual (la usa el agente al materializar, §9.4, y la importación, §8.3):

| perfil hoy | nube |
|---|---|
| `project` (nombre del archivo) | `projects.name` (`[A-Za-z0-9][A-Za-z0-9_.-]{0,63}`, único) |
| `t3_project`, `repo`, `runtime_mode`, `model` | columnas homónimas de `projects` |
| `host`, `overflow_host` | se descartan: la máquina es `projects.machine_id` |
| `office.company` | el **workspace** (campus) del proyecto: `workspaces.name` |
| `office.floors`, `office.half_life`, `capacity`, `machine_rooms` | `project_layouts.layout` (JSON con esas claves) |
| `office.roles.<rol>` (`prompt_file` → contenido, `match`, `wake`, `model`, resto) | una fila de `roles` (`prompt` con el texto del archivo, `match_rules`, `wake`, `model`, `settings`) |
| `rack`, reacciones, `graph`, `integration`, `automations`, `scratch` y cualquier otra clave | `projects.settings` (JSON) |
| posición de edificios, calles, orden en la ciudad | `campus_layouts.layout` y `workspaces.position` |
| `projects.toml` `enabled = false` | `projects.disabled_at` |

### `0004_tasks.sql` (fase S2, DESPUÉS)

```sql
CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
  employee_key TEXT NOT NULL,
  title TEXT NOT NULL,
  prompt TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL CHECK (state IN ('queued', 'claimed', 'running', 'done', 'failed', 'cancelled')),
  position INTEGER NOT NULL DEFAULT 0,
  created_by TEXT NOT NULL,
  trigger TEXT,
  idem_key TEXT NOT NULL UNIQUE,
  machine_id TEXT REFERENCES machines (id),
  lease_until TEXT,
  cancel_requested_at TEXT,
  result_summary TEXT,
  rev INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX tasks_queue ON tasks (project_id, employee_key, state, position);
```

Hoy (fase S1) las colas siguen siendo locales en cada agente (K2, `chopshop/queue.py`) y suben como hasta ahora en la parte
`employees` del snapshot; la app las muestra en solo lectura.

---

## 3. Contraseñas, tokens y límites

Todo el backend cabe en el **plan gratis** de Cloudflare Workers (10 ms de CPU por petición HTTP del Worker; D1 y Durable
Objects con SQLite del plan gratis). No se depende de Workers Paid en ningún punto; ver la medición de abajo y §12.

- **Hash** (`src/crypto.ts`): primero `HMAC-SHA256(clave = PASSWORD_PEPPER, mensaje = contraseña NFC)` (32 bytes) y sobre eso
  WebCrypto `PBKDF2` con `SHA-256`, **10 000 iteraciones** (`PBKDF2_ITERATIONS`), sal aleatoria de 16 bytes, 32 bytes de salida.
  Formato versionado en `users.password_hash`: `esquema$iteraciones$sal$hash`, con
  `esquema = pbkdf2-sha256-p<versión del pepper>` (p. ej. `pbkdf2-sha256-p1$10000$<sal base64url>$<hash base64url>`). El esquema
  sin sufijo (`pbkdf2-sha256$…`) es el formato viejo sin pepper: se sigue verificando. Se aceptan de 1 a 100 000 iteraciones
  (`PBKDF2_MAX_ITERATIONS`, el tope de `crypto.subtle` en producción de Cloudflare); fuera de eso, el hash no es válido.
- **`needsRehash(hash, pepper)`** es verdadero si el esquema, la versión del pepper, las iteraciones o la longitud de la sal no
  son los vigentes. Al verificar con éxito una contraseña cuyo hash lo necesita (login), se rehace en la misma petición. Así se
  suben iteraciones o se rota el pepper sin forzar cambios ni romper hashes viejos.
- **Pepper**: secret del Worker `PASSWORD_PEPPER` (≥ 32 caracteres, p. ej. `openssl rand -base64 32`), **nunca** en D1, en el repo
  ni en `[vars]`; versión en la var `PASSWORD_PEPPER_VERSION` (por defecto `1`). Rotación: se sube la versión, el valor anterior
  pasa a `PASSWORD_PEPPER_V<n>` y cada login correcto rehace el hash; cuando no quedan hashes `-p<n>`, se borra el secret viejo.
  Sin `PASSWORD_PEPPER` válido las rutas de contraseña responden `503 internal` («contraseñas deshabilitadas»). El pepper hace
  que un volcado de D1 por sí solo no permita atacar las contraseñas fuera de línea: hace falta además el secret del Worker.
- **Solo ejecutan PBKDF2** las rutas que reciben una contraseña: `POST /v1/auth/login`, `POST /v1/invitations/accept`,
  `POST /v1/auth/password`, `POST /v1/auth/recover` y `POST /v1/auth/recovery-code`. Sesiones, credenciales de máquina,
  invitaciones, CSRF, operador y código de recuperación usan solo `sha256` (microsegundos). Ninguna ruta hace más de **dos**
  derivaciones (verificar + rehacer en login con rehash o en cambio de contraseña).
- Comparación en tiempo constante con `crypto.subtle.timingSafeEqual` sobre bytes de igual longitud (longitudes distintas → falso
  sin comparar). Con un correo inexistente, un hash ilegible o una versión de pepper desconocida se hace igualmente una
  derivación completa con los parámetros vigentes (`DUMMY_PASSWORD_HASH`) para igualar el tiempo.

**Medición de CPU** (`apps/backend/scripts/measure-pbkdf2.mjs`, reproducible, sin red ni credenciales: arranca un `workerd`
local con el binario que trae `wrangler`, un Worker que hace una derivación por petición, y lo mata al terminar). Mide el tiempo
de pared desde el cliente (`performance.now`) y el CPU de **todo el proceso `workerd`** (suma de `/proc/<pid>/task/*/schedstat`,
resolución de ns; equivale a `process.cpuUsage` del proceso `workerd`); «CPU neta» = mediana menos la de una petición con 1
iteración. Dentro del Worker `performance.now()` no avanza durante el cómputo (mitigación de Spectre de Workers), por eso se mide
desde fuera. Uso: `node apps/backend/scripts/measure-pbkdf2.mjs` (`ITERATIONS=…`, `REPS=…`).

Resultado (2026-10-30; `workerd 1.20261023.1`, AMD EPYC virtualizado, host con carga ~13 en 12 núcleos, 60 repeticiones más 3
de calentamiento; el p95 está inflado por esa carga, la mediana es estable entre corridas):

| iteraciones | pared mediana (ms) | pared p95 (ms) | CPU `workerd` mediana (ms) | CPU `workerd` p95 (ms) | CPU neta mediana (ms) | con pepper: CPU neta mediana (ms) |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1,26 | 6,43 | 0,42 | 1,47 | 0 | 0,39 |
| 10 000 | 5,12 | 21,97 | 3,34 | 5,11 | 2,91 | 3,06 |
| 20 000 | 9,39 | 36,81 | 6,28 | 24,70 | 5,86 | 5,54 |
| 30 000 | 11,03 | 65,27 | 8,45 | 47,92 | 8,03 | 7,73 |
| 50 000 | 15,68 | 38,03 | 13,12 | 26,44 | 12,70 | 12,38 |
| 100 000 | 28,80 | 55,84 | 24,93 | 52,24 | 24,51 | 24,20 |

Coste lineal: **~0,25 ms de CPU por cada 1000 iteraciones**; el HMAC del pepper no se nota. Coincide con mediciones publicadas en
producción (100 000 iteraciones ≈ 23 ms de CPU según `wrangler tail`). `workerd` local no aplica el tope de 100 000 (acepta
100 001); producción sí (`NotSupportedError`), por eso el tope está en el código.

**¿Cuenta WebCrypto contra los 10 ms?** Sí. La documentación oficial de límites
(<https://developers.cloudflare.com/workers/platform/limits/>, «CPU time») define el CPU como ejecución activa y solo excluye la
espera de red/I/O («Waiting on network requests (such as fetch() calls, KV reads, or database queries) does not count toward CPU
time»); `crypto.subtle.deriveBits` se ejecuta en el hilo del isolate (código nativo, pero no es I/O), así que cuenta. La misma
página: Free = 10 ms por petición HTTP, con cierta holgura («Each isolate has some built-in flexibility to allow for cases where
your Worker infrequently runs over the configured limit»), que no se usa como margen de diseño. La página de Web Crypto
(<https://developers.cloudflare.com/workers/runtime-apis/web-crypto/>) no documenta excepción alguna.

**Conclusión y calibración**: 100 000 iteraciones (≈ 25 ms) no caben nunca en 10 ms. Con **10 000** una derivación cuesta
≈ 3 ms; el peor caso (dos derivaciones + ≈ 1 ms de JSON, `sha256` y despacho; las consultas a D1 son I/O y no cuentan) queda en
≈ 7 ms, con margen. 20 000 ya dejaría el cambio de contraseña en ≈ 13 ms. Recalibrar con el script si cambia el runtime y subir
`PBKDF2_ITERATIONS` cuando haya margen: `needsRehash` migra en el siguiente login. 10 000 está por debajo de lo que pide OWASP
para PBKDF2-SHA256 sin pepper (600 000); se compensa con: pepper fuera de D1 (un volcado de la base no basta), contraseña de
≥ 12 caracteres, solo invitados (pocas cuentas) y los límites de intentos de abajo, que hacen inviable el ataque en línea.
Alternativa documentada, no implementada: los Durable Objects tienen 30 s de CPU por petición también en el plan gratis
(<https://developers.cloudflare.com/durable-objects/platform/limits/>), así que un DO dedicado a derivar permitiría 100 000
iteraciones sin pagar; no se hace hoy porque añade una llamada por login y otra clase de DO, y el pepper ya cubre el riesgo
principal.

- **Política**: 12 a 256 caracteres tras normalizar a NFC; distinta del correo y sin contener la parte local del correo (≥ 4
  caracteres). Nada de reglas de composición. Error: 400 `bad_request` con `field: "password"`.
- **Correo normalizado**: `trim`, NFC, minúsculas. Validación mínima: `^[^@\s]+@[^@\s]+\.[^@\s]+$`, máx. 254.
- **Tokens** (`ss1_`, `cm1_`, `ci1_`, `cx1_`): `crypto.getRandomValues(32 bytes)` en base64url; en D1 solo `sha256` hex. Se
  devuelven una única vez. Se validan primero con regex (`^ss1_[A-Za-z0-9_-]{43}$`, etc.) antes de tocar D1.
- **Código de recuperación**: 20 símbolos del alfabeto Crockford (100 bits) mostrados en 4 grupos de 5. Normalización igual que el
  código de pairing actual (sin guiones ni espacios, mayúsculas, `O→0`, `I/L→1`). Se guarda `sha256` del normalizado.
- **Límites y bloqueo progresivo** (`src/ratelimit.ts` sobre la tabla D1 `auth_attempts`; claves `sha256` para no guardar correos
  ni IPs en claro). Compensan el menor coste de PBKDF2: se consultan **antes** de derivar (una petición bloqueada no gasta CPU de
  PBKDF2) y cuentan los fallos tanto por correo como por IP, exista o no el correo. El contador se incrementa con un único
  `INSERT … ON CONFLICT DO UPDATE … RETURNING failures` (atómico en D1). La ventana se reinicia cuando han pasado `ventana`
  segundos desde el último fallo o desde el fin del último bloqueo (así el bloqueo progresivo sigue creciendo tras desbloquearse):

| clave | ruta | umbral | bloqueo |
|---|---|---|---|
| `ei:` + sha256(correo + "\|" + IP) | login, password | 5 fallos en 15 min | 2^(fallos−5) min (1, 2, 4…), máx. 60 min; un login correcto la borra |
| `e:` + sha256(correo) | login, recover | 20 fallos en 1 h | 15 min (todas las IPs) |
| `ip:` + sha256(IP) | login, recover, invitaciones | 100 fallos en 1 h | 60 min |
| `rc:` + sha256(IP) | `POST /v1/auth/recover` | 5 fallos en 1 h | 60 min |
| `inv:` + sha256(IP) | `inspect`/`accept` de invitaciones | 10 fallos en 1 min | 5 min |
| `op:` + sha256(IP) | `/v1/operator/*` | 5 fallos en 10 min | 60 min |

  Bloqueado → 429 `rate_limited` con `retry_after_s` (el mayor de las claves consultadas), cabecera `Retry-After` y mensaje fijo
  «demasiados intentos; vuelve a intentarlo más tarde» (`rateLimitedBody`). Credenciales malas, usuario desactivado o correo
  inexistente dan **la misma** respuesta: 401 `unauthorized`, mensaje «correo o contraseña incorrectos» (`authFailedBody`), con
  la misma derivación de PBKDF2. La IP es `CF-Connecting-IP`. El cron purga filas sin actividad ni bloqueo vigente en 24 h
  (`purgeAttempts`).
- **Sesiones**: token opaco con **expiración deslizante**. `mac`/`cli`: inactividad 30 días, absoluta 90 días. `web`: inactividad
  12 h, absoluta 7 días. En cada petición válida: si `now − last_seen_at ≥ 5 min`, `last_seen_at = now` y
  `expires_at = min(now + inactividad, absolute_expires_at)`. Caducada o revocada → 401. No hay refresh token: la app vuelve a
  pedir login cuando recibe 401.

---

## 4. Flujos

Notación de errores: `código HTTP code`. Todos los cuerpos de error tienen la forma de §5.1.

### 4.1 Bootstrap del dueño (una sola vez, sin registro abierto)

1. El operador en contabo: `chopshop relay admin bootstrap --email <correo> --token-file <f>` (o `--stdin`; nunca el secret en
   `argv`). La CLI llama `POST /v1/operator/bootstrap` con `Authorization: Bearer <RELAY_OPERATOR_TOKEN>`.
2. Worker: compara `sha256` del bearer con `sha256(env.RELAY_OPERATOR_TOKEN)` en tiempo constante. Si ya existe un usuario
   `owner` → `409 conflict`. Si no: revoca invitaciones `owner_bootstrap` pendientes y crea una nueva (`kind = owner_bootstrap`,
   `role = owner`, caduca en 24 h). Audita `operator.bootstrap`.
3. Respuesta `201 {invitation: {id, email, kind, expires_at}, link}` con
   `link = https://chopshop.novarix.online/invite#t=ci1_…`. La CLI imprime el enlace **una vez** en la terminal (es el único
   lugar donde se muestra) y nada más.
4. El dueño abre el enlace (web) o lo pega en la app Mac («Aceptar invitación») → §4.3. Al aceptar se crea el usuario `owner`, un
   workspace inicial `Personal` y se muestra el **código de recuperación** una sola vez.

Errores: secret ausente/incorrecto `401 unauthorized`; secret no configurado en el Worker `503 internal` («operador
deshabilitado»); `400 bad_request` correo inválido; `429 rate_limited`.

### 4.2 Invitar a un watcher (dueño, desde app o web)

`POST /v1/invitations {email, workspace_ids, ttl_h?}` → crea `invitations` (`kind = watcher`, `role = watcher`, caduca en
`ttl_h` horas, 1–720, por defecto 168) y sus `invitation_workspaces`. Respuesta `201 {invitation, link}`. La app y la web
muestran el enlace con un botón «Copiar enlace»; **no se envía correo** (DESPUÉS). El enlace no se puede volver a ver: para otro
enlace, `POST /v1/invitations/{id}/reissue` (nuevo token; el anterior deja de valer).

Errores: `409 conflict` si ya existe un usuario con ese correo (para darle más workspaces se usa §4.11); `404 not_found` si un
`workspace_id` no existe o está archivado; `400` si `workspace_ids` está vacío.

### 4.3 Aceptar invitación (fija la contraseña)

1. La web o la app extraen `t` del fragmento y llaman `POST /v1/invitations/inspect {token}` → `200 {email, kind, role,
   expires_at, workspaces: [{id, name}]}` para mostrar a quién invita.
2. `POST /v1/invitations/accept {token, password, display_name?, device_name, client}` en una transacción D1 (`batch`):
   - `watcher`: crea `users` (`role = watcher`), copia `invitation_workspaces` a `workspace_members`, marca `used_at/used_by`.
   - `owner_bootstrap`: crea el `owner` (falla con 409 si ya hay uno), crea el workspace `Personal`, genera el código de
     recuperación.
   - `owner_reset`: cambia la contraseña del dueño, revoca todas sus sesiones (`recovered`), genera un código de recuperación
     nuevo.
   - Crea una sesión como en §4.4 y responde igual que el login, más `recovery_code` en los dos casos `owner_*`.
3. Errores: token inválido `401 unauthorized`; usada, revocada o caducada `410 gone`; contraseña fuera de política `400`;
   `429`.

### 4.4 Login

`POST /v1/auth/login {email, password, device_name, client}`:

1. Límites de §3 (`retryAfter` con `loginKeys(correo, IP)`, antes de calcular PBKDF2; > 0 → 429). 2. Busca por
`email_normalized`; verifica hash (o el ficticio) con el pepper; fallo → `recordFailure` y 401. 3. Usuario `disabled` → mismo 401
(también `recordFailure`). Éxito → `clearLimit` de la clave `ei:` y, si `needsRehash`, guarda el hash nuevo. 4. Crea `sessions` con `token_hash`, `client`, `device_name` (máx. 64), `user_agent` (máx. 200),
`expires_at`, `absolute_expires_at`; si `client = web`, además `csrf_hash`. 5. Audita `auth.login` (o `auth.login_failed` sin
el correo en `detail`).

Respuesta `200`:

- `mac`/`cli`: `{user, session: {id, client, expires_at}, token: "ss1_…"}`.
- `web`: `{user, session, csrf_token: "cx1_…"}` + `Set-Cookie: __Host-chopshop_session=ss1_…; Path=/; Secure; HttpOnly;
  SameSite=Strict; Max-Age=<absoluta>`. El cuerpo **no** lleva el token.

`user` = `{id, email, display_name, role, status, created_at}`.

### 4.5 Logout

`POST /v1/auth/logout` (sesión) → marca `revoked_at`, `revoked_reason = logout`; el Worker llama `hub.sessionRevoked(id)`
(cierra sus streams SSE). `204`. En web, además `Set-Cookie` con `Max-Age=0`. La app borra el Keychain (§9.6).

### 4.6 Expiración y renovación

Deslizante (§3). No hay endpoint de refresh: cada petición válida renueva. `GET /v1/auth/me` sirve a la app para comprobar la
sesión al abrir (200 o 401).

### 4.7 Cambio de contraseña

`POST /v1/auth/password {current_password, new_password}` → verifica la actual (cuenta como intento de login en `ei:`), aplica
política, guarda hash, `password_changed_at`, revoca **las demás** sesiones del usuario (`password_changed`) y cierra sus streams.
`204`. Errores: actual incorrecta `401`, política `400`, `429`.

### 4.8 Recuperación del dueño

Dos caminos, los dos HOY:

- **Código de recuperación** (sin operador): `POST /v1/auth/recover {email, recovery_code, new_password}` → si el usuario es el
  `owner` y el código coincide: nueva contraseña, revoca todas las sesiones (`recovered`), genera y devuelve un código nuevo
  `200 {recovery_code}` (el anterior deja de valer). Fallo → `401` genérico; límites `rc:` y `e:`. Audita `auth.recovered`.
- **Operador** (si se perdió también el código): `chopshop relay admin recover --token-file <f>` → `POST /v1/operator/recover`
  → crea una invitación `owner_reset` para el correo del dueño (caduca en 1 h, revoca otras `owner_reset` pendientes) y
  responde `201 {invitation, link}`; se acepta como §4.3. Sin dueño → `409 conflict`. Después del bootstrap, el secret de
  operador **solo** sirve para `bootstrap` (que responde 409) y `recover`.
- Regenerar el código con sesión: `POST /v1/auth/recovery-code {password}` (solo dueño) → `200 {recovery_code}`.

### 4.9 Revocar sesión y desactivar usuario

- `DELETE /v1/sessions/{id}`: el dueño puede revocar cualquiera; un watcher solo las suyas (otra → `404 not_found`, no 403, para
  no revelar ids). `revoked_reason = revoked`, `hub.sessionRevoked(id)`. `204`.
- `PATCH /v1/users/{id} {status: "disabled"}` (dueño, solo watchers; sobre el dueño → `409 conflict`): revoca todas sus sesiones
  (`user_disabled`), `hub.viewerChanged(user_id)`. Volver a `active` no restaura sesiones. Las membresías se conservan.

### 4.10 Ligar una máquina

**A. Máquina con la app Mac (la propia Mac o la MacBook Air):**

1. La app (sesión del dueño) lee el `machine_id` del agente local con `GET http://127.0.0.1:<agent.port>/local/relay/status`
   (sin secretos, §9.2) y llama `POST /v1/machines/link {local_machine_id, name, platform, workspace_ids?}`.
2. Worker: si ya hay una máquina activa con ese `local_machine_id`, la **revoca** (credencial vieja fuera, `hub.machineChanged`)
   y crea otra; inserta `machines` (`linked_via = app`) y `workspace_machines` (por defecto: todos los workspaces no archivados si
   `workspace_ids` falta). Respuesta `201 {machine, credential: "cm1_…", api_url}`.
3. La app entrega la credencial al agente local: `POST http://127.0.0.1:<agent.port>/local/relay/link` con la cabecera
   `X-Chopshop-Link-Nonce` (§9.2) y `{api_url, machine_id, local_machine_id, credential}`. El agente la guarda 0600 y conecta.
   La app descarta la credencial de memoria. **El usuario nunca la ve.**
4. Si el paso 3 falla, la app revoca la máquina recién creada (`POST /v1/machines/{id}/revoke`) y muestra el error.

**B. VPS sin app (p. ej. contabo):**

1. En la app (o la web), «Máquinas → Token para VPS»: `POST /v1/machines {name, platform, workspace_ids?}` → `201 {machine,
   credential, api_url}` con `linked_via = token` y `local_machine_id = null`. La app muestra la credencial **una vez** con el
   comando a ejecutar: `chopshop relay link --api <api_url> --stdin` (se pega la credencial por stdin).
2. El agente guarda la credencial y conecta; su **primer `hello`** fija `local_machine_id`. Si ya hay otra máquina activa con
   ese `local_machine_id`, la conexión se rechaza (`409 conflict`, cierre 4409) y la app muestra el conflicto.

**Reconexión**: el agente solo usa su `cm1_` (`Authorization: Bearer cm1_…` en el upgrade de `/v1/connect`). Revocar
(`POST /v1/machines/{id}/revoke`) la invalida para siempre (401 en el upgrade y cierre 4401 del WebSocket abierto; el agente deja
de reintentar y queda «desligado»). **Desconectar** (`POST /v1/machines/{id}/pause`) corta el WebSocket y rechaza reconexiones
con `403 forbidden` (cierre 4403) hasta `POST /v1/machines/{id}/resume`; el agente reintenta cada 10 min.

### 4.11 Compartir y dejar de compartir un workspace

`PUT /v1/workspaces/{id}/watchers/{user_id}` (dueño) → inserta `workspace_members` (idempotente), audita `workspace.shared`,
`hub.viewerChanged(user_id)`. `DELETE` igual → borra la fila, `workspace.unshared`, `hub.viewerChanged(user_id)`: el Hub cierra
los streams abiertos de ese usuario (frame `error` `forbidden` con `close: true`) y el cliente reconecta ya con la vista nueva.

### 4.12 Cambiar la estructura (proyectos, roles, layouts, campus)

Toda escritura de estructura (§5.6) hace, en un `batch` de D1: el cambio + `UPDATE meta SET value = value + 1 WHERE key =
'structure_rev'`. Después el Worker llama `hub.structureChanged(rev, machine_ids)` con las máquinas afectadas (las de
`projects.machine_id` antes y después del cambio, o todas si cambia un workspace). El Hub manda un `sync` nuevo a esas máquinas
(§5.8) y un evento SSE `structure` `{rev}` a los visores para que relean `GET /v1/state`.

---

## 5. API

Todo bajo `https://api.chopshop.novarix.online`. JSON UTF-8, máx. 1 MiB por cuerpo (más → `413 too_large`). Toda respuesta lleva
`Cache-Control: no-store`. Los clientes envían `User-Agent` explícito (`chopshop-agent/<v>`, `chopshop-mac/<v>`, `chopshop-cli/<v>`).

### 5.1 Errores

`{v: 2, type: "error", id, ts, re: null, code, message, field?, retry_after_s?, current?}`. `code` ∈ `bad_request` (400),
`unauthorized` (401), `forbidden` (403), `not_found` (404), `conflict` (409), `gone` (410), `too_large` (413), `rate_limited`
(429), `unsupported_version` (426), `internal` (500/503), `timeout` (504). `current` solo en 409 por `rev` (el recurso actual).
`message` nunca contiene secretos, correos ajenos, hashes ni contenido de partes opacas.

### 5.2 Principales y regla central

El Worker resuelve **un** principal por petición, antes de mirar la ruta:

| cabecera | principal |
|---|---|
| ninguna (y sin cookie) | `anonymous` |
| `Authorization: Bearer ss1_…` o cookie `__Host-chopshop_session` | `user` `{user_id, role, session_id, client}` (sesión viva y usuario `active`) |
| `Authorization: Bearer cm1_…` | `machine` `{machine_id, local_machine_id}` (no revocada; pausada solo vale para `/v1/connect`, que responde 403) |
| `Authorization: Bearer <secret de operador>` | `operator` (solo en `/v1/operator/*`; en cualquier otra ruta es un bearer inválido → 401) |

Credencial mal formada, desconocida, revocada o caducada → `401 unauthorized` antes de enrutar. Reglas:

1. `user_id` y `role` salen **siempre** de la sesión, nunca del cuerpo, la query ni la ruta.
2. Toda consulta SQL de un `watcher` filtra por sus `workspace_members` (`… JOIN workspace_members m ON m.workspace_id = … AND
   m.user_id = ?`). Un recurso fuera de su alcance da `404 not_found` (no 403), para no revelar que existe.
3. Las escrituras son **solo del dueño**: cualquier método distinto de `GET` de un `watcher` → `403 forbidden`, salvo
   `POST /v1/auth/logout`, `POST /v1/auth/password`, `DELETE /v1/sessions/{id}` (suyas) y `GET`s permitidos.
4. El Hub siempre es `idFromName("owner")`; lo que el cliente manda (un `workspace_id`) solo **filtra** y se valida en D1 antes.

Tabla de acceso (columna `quién`): `anon` = sin credencial; `owner`; `watcher` (solo lectura de lo compartido); `any` = owner o
watcher; `machine`; `operator`.

### 5.3 Rutas

**Salud y operador**

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /health` | anon | — | `200 {ok: true, version}` | — |
| `POST /v1/operator/bootstrap` | operator | `{email}` | `201 {invitation, link}` | 400, 401, 409, 429, 503 |
| `POST /v1/operator/recover` | operator | `{}` | `201 {invitation, link}` | 401, 409, 429, 503 |

**Auth** (`/v1/auth/*`)

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `POST /v1/auth/login` | anon | `{email, password, device_name, client}` | `200` §4.4 | 400, 401, 429 |
| `POST /v1/auth/logout` | any | — | `204` | 401 |
| `GET /v1/auth/me` | any | — | `200 {user, session, csrf_token?}` (`csrf_token` nuevo solo en web) | 401 |
| `POST /v1/auth/password` | any | `{current_password, new_password}` | `204` | 400, 401, 429 |
| `POST /v1/auth/recover` | anon | `{email, recovery_code, new_password}` | `200 {recovery_code}` | 400, 401, 429 |
| `POST /v1/auth/recovery-code` | owner | `{password}` | `200 {recovery_code}` | 401, 403, 429 |

**Invitaciones**

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/invitations` | owner | — | `200 {invitations: [Invitation]}` (pendientes y últimas 50 usadas/revocadas) | 401, 403 |
| `POST /v1/invitations` | owner | `{email, workspace_ids, ttl_h?}` | `201 {invitation, link}` | 400, 404, 409 |
| `POST /v1/invitations/{id}/reissue` | owner | `{ttl_h?}` | `200 {invitation, link}` | 404, 410 (usada) |
| `DELETE /v1/invitations/{id}` | owner | — | `204` | 404 |
| `POST /v1/invitations/inspect` | anon | `{token}` | `200 {email, kind, role, expires_at, workspaces}` | 401, 410, 429 |
| `POST /v1/invitations/accept` | anon | `{token, password, display_name?, device_name, client}` | `201` como login + `recovery_code?` | 400, 401, 409, 410, 429 |

`Invitation` = `{id, email, kind, role, workspace_ids, created_at, expires_at, used_at, revoked_at, status}` con `status` ∈
`pending | used | revoked | expired`. Nunca incluye el token ni el hash.

**Usuarios y sesiones**

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/users` | owner | — | `200 {users: [User & {workspace_ids, last_login_at, sessions_active}]}` | 403 |
| `GET /v1/users/{id}` | owner | — | `200 {user}` | 404 |
| `PATCH /v1/users/{id}` | owner | `{status?, display_name?}` | `200 {user}` | 400, 404, 409 (el dueño) |
| `GET /v1/sessions` | any | query `user_id?` (solo owner) | `200 {sessions: [Session]}` (watcher: solo las suyas) | 401 |
| `DELETE /v1/sessions/{id}` | any | — | `204` | 404 |

`Session` = `{id, user_id, client, device_name, user_agent, created_at, last_seen_at, expires_at, current}`; `current` = es la de
esta petición. Nunca el token.

**Máquinas** (solo dueño)

| método y ruta | cuerpo | respuesta | errores |
|---|---|---|---|
| `GET /v1/machines` | — | `200 {machines: [Machine]}` | 403 |
| `POST /v1/machines/link` | `{local_machine_id, name, platform, workspace_ids?}` | `201 {machine, credential, api_url}` | 400, 404 |
| `POST /v1/machines` | `{name, platform, workspace_ids?}` | `201 {machine, credential, api_url}` (token para VPS) | 400, 404 |
| `GET /v1/machines/{id}` | — | `200 {machine}` | 404 |
| `PATCH /v1/machines/{id}` | `{name}` | `200 {machine}` | 400, 404 |
| `POST /v1/machines/{id}/pause` | — | `200 {machine}` (desconecta y bloquea) | 404, 410 (revocada) |
| `POST /v1/machines/{id}/resume` | — | `200 {machine}` | 404, 410 |
| `POST /v1/machines/{id}/revoke` | — | `204` (irreversible) | 404 |

`Machine` = `{id, name, platform, local_machine_id, linked_via, agent_version, workspace_ids, created_at, last_seen_at,
paused_at, revoked_at, online}` (`online` lo da el Hub). Las revocadas se listan 30 días.

**Workspaces / campus**

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/workspaces` | any | — | `200 {workspaces: [Workspace]}` (watcher: compartidos) | 401 |
| `POST /v1/workspaces` | owner | `{name, slug?, position?, style?}` | `201 {workspace}` (crea su `campus_layouts` vacío) | 400, 409 (slug) |
| `GET /v1/workspaces/{id}` | any | — | `200 {workspace}` | 404 |
| `PATCH /v1/workspaces/{id}` | owner | `{rev, name?, slug?, position?, style?}` | `200 {workspace}` | 400, 404, 409 |
| `DELETE /v1/workspaces/{id}` | owner | — | `204` (archiva) | 404, 409 (tiene proyectos no archivados) |
| `GET /v1/workspaces/{id}/campus` | any | — | `200 {layout, rev}` | 404 |
| `PUT /v1/workspaces/{id}/campus` | owner | `{layout, rev}` | `200 {layout, rev}` | 400, 404, 409 |
| `GET /v1/workspaces/{id}/watchers` | owner | — | `200 {watchers: [User]}` | 404 |
| `PUT /v1/workspaces/{id}/watchers/{user_id}` | owner | — | `204` | 404 (usuario no watcher o inexistente) |
| `DELETE /v1/workspaces/{id}/watchers/{user_id}` | owner | — | `204` | 404 |
| `PUT /v1/workspaces/{id}/machines/{machine_id}` | owner | — | `204` | 404 |
| `DELETE /v1/workspaces/{id}/machines/{machine_id}` | owner | — | `204` | 404, 409 (hay proyectos del workspace en esa máquina) |

`Workspace` = `{id, name, slug, position, style, rev, project_count, machine_ids, watcher_count?, created_at, updated_at}`;
`machine_ids` y `watcher_count` solo para el dueño.

**Proyectos, layouts y roles (empleados)**

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/workspaces/{id}/projects` | any | — | `200 {projects: [Project]}` | 404 |
| `POST /v1/workspaces/{id}/projects` | owner | `{name, title?, t3_project?, repo?, machine_id?, runtime_mode?, model?, settings?}` | `201 {project}` | 400, 404, 409 (nombre) |
| `GET /v1/projects/{id}` | any | — | `200 {project}` | 404 |
| `PATCH /v1/projects/{id}` | owner | `{rev, …mismos campos, workspace_id?, disabled?: bool}` | `200 {project}` | 400, 404, 409 |
| `DELETE /v1/projects/{id}` | owner | — | `204` (archiva) | 404 |
| `GET /v1/projects/{id}/layout` | any | — | `200 {layout, rev}` | 404 |
| `PUT /v1/projects/{id}/layout` | owner | `{layout, rev}` | `200 {layout, rev}` | 400, 404, 409 |
| `GET /v1/projects/{id}/roles` | any | — | `200 {roles: [Role]}` (watcher: sin `prompt`, `match_rules`, `wake`, `settings`) | 404 |
| `POST /v1/projects/{id}/roles` | owner | `{name, prompt?, model?, match_rules?, wake?, settings?, position?}` | `201 {role}` | 400, 404, 409 |
| `PATCH /v1/roles/{id}` | owner | `{rev, …}` | `200 {role}` | 400, 404, 409 |
| `DELETE /v1/roles/{id}` | owner | — | `204` | 404, 409 (el layout aún tiene salas de ese rol) |

`machine_id` de un proyecto debe estar en `workspace_machines` de su workspace (si no, `400` `field: "machine_id"`). El Worker
valida `layout` y `settings` solo en forma (objeto JSON, ≤ 256 KiB, claves de primer nivel conocidas para `layout`: `floors`,
`half_life`, `capacity`, `machine_rooms`); la validación semántica la hace el agente (`profile.validate`) y la reporta en
`sync.ack.errors`, visible en `GET /v1/state` como `projects[].sync_errors`.

**Colas** (fase S2, DESPUÉS; rutas reservadas)

`GET /v1/projects/{id}/tasks` (any), `POST /v1/projects/{id}/tasks {employee_key, title, prompt, idem_key}` (owner),
`PATCH /v1/tasks/{id} {rev, position?, cancel?: true}` (owner). Hasta S2 responden `404`.

**Importación de la configuración local** (HOY)

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/imports` | owner | — | `200 {imports: [{id, machine_id, created_at, summary, applied_at, dismissed_at}]}` | 403 |
| `GET /v1/imports/{id}` | owner | — | `200 {import, projects: [ImportProject]}` | 404 |
| `POST /v1/imports/{id}/apply` | owner | `{projects: [{name, workspace_id?, workspace_name?}]}` | `200 {created: [Project], skipped: [{name, reason}]}` | 400, 404, 409 |
| `DELETE /v1/imports/{id}` | owner | — | `204` (descarta) | 404 |

`ImportProject` = `{name, company, t3_project, repo, roles: [nombres], floors, has_prompts, conflicts: ["name_taken"…]}`. Si se
omite `workspace_id`, se usa (o crea) el workspace cuyo `name` = `workspace_name` o, en su defecto, `company` del perfil: cada
empresa del perfil local pasa a ser su campus. El proyecto queda con `machine_id` = la máquina que ofreció la importación (y esa
máquina entra en `workspace_machines`). Nombre ya existente → `skipped` `name_taken`.

**Estado, stream, agente, comandos, auditoría**

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/state` | any | query `workspace?` | `200 State` (§5.5) | 401, 404 |
| `GET /v1/stream` | any | query `workspace?`, cabecera `Last-Event-ID?` | SSE (§5.5) | 401, 404, 429 |
| `GET /v1/connect` | machine | upgrade WebSocket | `101` (§5.8) | 401, 403 (pausada), 409, 426 |
| `POST /v1/commands` | owner | `{machine_id, name, args}` | `200 {command_id, ok, status, body}` | 400, 403, 404, 409 (offline), 504 |
| `GET /v1/audit` | owner | query `limit≤200`, `before?`, `machine_id?`, `action?` | `200 {entries: [AuditEntry]}` | 403 |

### 5.4 Autorización por comando

`POST /v1/commands` solo acepta al dueño. Verificación en dos sitios:

1. **Worker**: principal `user` con `role = owner` y sesión viva (si no: `403`, se audita `command` con `result = denied`);
   `name` en el catálogo (si no: `400`); máquina existente, no revocada ni pausada (`404`/`409`). Inserta `audit_log` (`action =
   command`, `command = name`, `result` provisional `error`) y llama `hub.command(OwnerCtx, cmd)`.
2. **Hub**: comprueba `ctx.role === "owner"` y `ctx.user_id === ownerId` (el Hub lee y cachea el id del dueño de D1 al
   arrancar), que la máquina está conectada y no pausada en su `machine_cache`; si algo falla, no reenvía (`403`/`409`). Si pasa,
   manda `cmd` y espera `cmd.result` hasta 30 s (`504 timeout`). Esa espera es I/O (tiempo de pared), no CPU: cabe en el plan
   gratis.
3. El Worker actualiza la fila de auditoría con `result` (`ok`/`error`/`timeout`/`denied`) y `status`.

Catálogo v2 (`name` → ruta local del agente que ejecuta; `args` = cuerpo/query de esa ruta, validado por el agente):

| `name` | ruta local | tipo |
|---|---|---|
| `thread.read` | `GET /thread` | lectura |
| `t3.projects` | `GET /t3/projects` | lectura |
| `answer` | `POST /answer` | mando |
| `settle` | `POST /settle` | mando |
| `thread.launch` | `POST /threads` | mando |
| `thread.send` | `POST /threads/send` | mando |
| `thread.interrupt` | `POST /threads/interrupt` | mando |
| `desk.assign` | `POST /desks/{desk_id}/assign` | mando |
| `desk.note` | `POST /desks/{desk_id}/notes` | mando |
| `queue.cancel` | `POST /queue/cancel` | mando |
| `touch` | `POST /touch` | mando |

El tipo solo clasifica la auditoría: todos son del dueño. Los watchers no tienen canal de comandos.

### 5.5 Estado y stream (la ciudad)

`GET /v1/state` responde la ciudad del principal (el dueño: todo; un watcher: sus workspaces compartidos). Con `?workspace=<id>`
se limita a ese campus (`404` si no es visible). El Worker arma la estructura desde D1 y pide lo vivo a
`hub.state(ViewCtx)`; `ViewCtx = {user_id, role, session_id, workspace_ids: string[] | "all"}`.

```json
{
  "v": 2, "type": "state", "id": "<ULID>", "ts": "…", "rev": 42, "head": "<época>-<n>",
  "user": {"id": "…", "role": "owner"},
  "city": {
    "workspaces": [{
      "id": "…", "name": "Awesome GB", "slug": "awesome-gb", "position": 0, "style": {},
      "campus": {"layout": {}, "rev": 3},
      "projects": [{"id": "…", "name": "awesome-gb", "title": null, "machine_id": "…", "disabled": false,
                    "layout": {}, "roles": ["triage", "backend"], "sync_errors": []}],
      "machine_ids": ["…"]
    }]
  },
  "machines": [{"id": "…", "name": "mac-mini", "platform": "macos", "online": true, "paused": false, "stale": false,
                "seq": 10, "snapshot_age_s": 4, "expires_at": "…"}],
  "snapshots": [{"…snapshot v2 tal cual lo mandó el agente…": "", "workspace_id": "…"}]
}
```

- Para un **watcher**: `machines[]` solo trae las máquinas de sus workspaces y solo `{id, name, online, stale}`; `snapshots[]`
  solo los de `workspace_id` compartidos; nunca hay snapshots con `workspace_id: null` (proyectos aún no migrados: solo dueño).
- `GET /v1/stream`: SSE como el v1 (`retry`, `event: hello {v: 2, type: "hello", ts, head, resume, rev}`, reanudación con
  `Last-Event-ID`, latido `: ping` cada 15 s, máx. 64 visores) con eventos `snapshot`, `event` (frames del agente tal cual,
  ya llevan `workspace_id`), `machine` (`{id, online, paused}` al conectar/desconectar/pausar), `structure` (`{rev}`) y `error`
  (con `close: true` si la sesión se revoca o cambia la vista). El Hub filtra cada frame con el `ViewCtx` del visor.

### 5.6 Escrituras de estructura

Son todas las rutas `POST/PATCH/PUT/DELETE` de workspaces, campus, proyectos, layouts, roles, `workspace_machines` e
importaciones: siguen §4.12 (incrementan `structure_rev` y avisan al Hub).

### 5.7 Invariantes de aislamiento (los prueban los tests de T-ISO, §11)

1. Un watcher sin membresía en el workspace W recibe 404 en toda ruta con W, sus proyectos, roles o layouts, y no ve frames de
   W en `/v1/stream` ni entradas en `/v1/state`.
2. Un watcher recibe 403 en toda escritura (incluido `/v1/commands`) aunque el recurso sea de un workspace compartido.
3. Ninguna ruta acepta `user_id` del cliente para decidir permisos (`?user_id=` en `GET /v1/sessions` solo filtra para el dueño).
4. Una credencial `cm1_` no sirve en ninguna ruta salvo `/v1/connect`; una `ss1_` no sirve en `/v1/connect`.
5. Quitar a un watcher de W o desactivarlo cierra sus streams en < 1 s (RPC al Hub en la misma petición).

### 5.8 Protocolo del agente (WebSocket v2)

Mismo transporte y frames que el v1 (`docs/relay-protocol.md`: cabecera `{v, type, id, ts}`, 1 MiB, cuotas, `ping/pong`,
`error` con cierres `4000 + estado`) con estos cambios:

- Upgrade en `GET /v1/connect` con `Authorization: Bearer cm1_…`. `hello.protocol` debe incluir `2`; `v` de los frames = 2.
- `hello` igual que v1 (`machine_id` = `local_machine_id`). Si no coincide con `machines.local_machine_id` → `forbidden` +
  cierre; si la máquina aún no lo tenía (token VPS), se fija.
- `welcome` añade `machine: {id, name}` y `rev` (el `structure_rev` actual). Desaparece `whoami`/`whoami.result`.
- `snapshot` añade `workspace_id` (string o `null`) a la cabecera visible: el agente manda **un snapshot por workspace** con los
  proyectos de ese workspace (los no migrados, en uno con `null`). El Hub guarda el último por `(machine_id, workspace_id)`.
  `health` es de la máquina y va igual en todos.
- `event` añade `workspace_id` (del proyecto del evento; `null` si no es de un proyecto en la nube o no tiene proyecto).
- Nuevos frames:

| `type` | sentido | campos |
|---|---|---|
| `sync` | relay → agente | `rev`, `machine: {id, name}`, `workspaces: [{id, name, slug}]`, `projects: [SyncProject]` (los de `projects.machine_id` = esta máquina, no archivados) |
| `sync.ack` | agente → relay | `re`, `rev`, `applied: [nombre]`, `errors: [{project, message}]` |
| `import.offer` | agente → relay | `projects: [ImportPayload]` (≤ 768 KiB) |
| `import.result` | relay → agente | `re`, `import_id`, `status` ∈ `stored | duplicate` |
| `cmd` | relay → agente | `command_id`, `name`, `args` |
| `cmd.result` | agente → relay | `re`, `command_id`, `ok`, `status`, `body` (≤ 512 KiB, sin secretos ni rutas locales) |

`SyncProject` = `{id, name, workspace_id, title, t3_project, repo, runtime_mode, model, disabled, settings, layout, roles:
[{name, prompt, model, match_rules, wake, settings}], rev}`. `ImportPayload` = el perfil local entero como JSON con
`prompt_file` sustituido por `prompt` (texto) y la entrada de `projects.toml` en `registry`.

El Hub manda `sync` justo después de `welcome` y cada vez que `structureChanged` incluye a la máquina. La lista blanca de
`docs/relay-protocol.md` sigue rigiendo **todo lo que sube** en `snapshot` y `event`; la estructura (prompts incluidos) baja de
la nube porque es su fuente de verdad. `import.offer` es la única subida de estructura y solo la aplica el dueño.

---

## 6. Web, CORS, CSRF, cabeceras y logs

- La web (`chopshop.novarix.online`) y la API (`api.chopshop.novarix.online`) son **mismo sitio** (`novarix.online`) y distinto
  origen. La cookie `__Host-chopshop_session` es del host de la API (sin `Domain`), `Secure; HttpOnly; SameSite=Strict; Path=/`.
- **CORS** (solo para la web): si `Origin` es exactamente `https://chopshop.novarix.online` → `Access-Control-Allow-Origin` con
  ese valor, `Access-Control-Allow-Credentials: true`, `Vary: Origin`, métodos `GET, POST, PUT, PATCH, DELETE`, cabeceras
  `Content-Type, X-CSRF-Token`, `Max-Age: 600`. Cualquier otro `Origin` → sin cabeceras CORS. La app Mac, la CLI y el agente no
  mandan `Origin`.
- **CSRF**: toda petición autenticada **por cookie** con método distinto de `GET`/`HEAD` exige (a) `Origin` =
  `https://chopshop.novarix.online` y (b) `X-CSRF-Token: cx1_…` cuyo `sha256` = `sessions.csrf_hash`. Si falla → `403 forbidden`.
  Las peticiones con `Bearer` no usan cookie y no necesitan CSRF. Si llegan cookie y `Bearer` a la vez → `400`.
- **Cabeceras** en todas las respuestas: `Strict-Transport-Security: max-age=31536000; includeSubDomains`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`. En la web, además
  `Content-Security-Policy: default-src 'self'; connect-src 'self' https://api.chopshop.novarix.online; img-src 'self' data:;
  style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`.
- **Qué NO se loguea** (ni `console.log`, ni auditoría, ni mensajes de error): contraseñas, tokens (`ss1_`, `cm1_`, `ci1_`,
  `cx1_`), el secret de operador, códigos de recuperación, enlaces de invitación, cabeceras `Authorization` y `Cookie`, cuerpos
  de petición de `/v1/auth/*`, `/v1/invitations/*` y `/v1/operator/*`, prompts, partes opacas de snapshots/eventos, `args` y
  `body` de comandos, IPs en claro. Sí se puede loguear: método, ruta sin query, estado, duración, `user_id`, `machine_id`,
  `code` de error. Workers Logs con muestreo, sin `invocation logs` de cuerpos.

---

## 7. Web admin (`apps/web-admin`)

- **Tecnología**: React 19 + esbuild (las mismas herramientas que `apps/ui`, sin dependencias nuevas en el monorepo), salida
  estática en `apps/web-admin/dist`. La sirve el Worker con **Workers Assets** (`[assets] directory = "../web-admin/dist"`,
  `binding = "ASSETS"`, `not_found_handling = "single-page-application"`) en el host `chopshop.novarix.online`; las peticiones a
  ese host nunca llegan a la lógica de la API. Cliente HTTP con `credentials: "include"` contra la API.
- **Mismo alcance que la app Mac**, usando solo la API de §5. Pantallas:
  - **HOY**: `Aceptar invitación` (`/invite#t=…`: `inspect` → formulario de contraseña → `accept`; muestra el código de
    recuperación si es del dueño) y `Login`. Tras entrar, una página de bienvenida que dice que la gestión está en la app Mac.
  - **DESPUÉS**: Ciudad (lista de workspaces con proyectos y estado, solo lectura para watchers), Máquinas (ver, desconectar,
    revocar, token VPS), Sesiones (ver, revocar), Watchers e invitaciones (invitar, copiar enlace, reemitir, revocar,
    compartir workspaces, desactivar), Workspaces/proyectos/roles (CRUD), Importaciones, Auditoría reciente, Cuenta (contraseña,
    código de recuperación).

---

## 8. Migración desde el relay actual

### 8.1 Fases

| fase | qué | despliegue |
|---|---|---|
| **0 (hoy)** | Se implementa `apps/backend` (Worker nuevo `chopshop-api`, D1 nueva `chopshop`) y los cambios de agente y app. El relay viejo (`chopshop-relay` en workers.dev, `apps/relay`) **no se toca** y sigue sirviendo a quien use `cr1_`. | ninguno |
| **1 (con aprobación del dueño)** | Despliegue de `chopshop-api` en los dominios nuevos (workflow manual), migraciones D1, bootstrap del dueño desde contabo, enlace de la Mac/MacBook Air por la app y de contabo con token VPS, importación de perfiles y registro. El agente usa v2 si existe `machine.json`; si no, sigue con `cr1_`. | `chopshop-api` |
| **2** | La app deja de ofrecer «pegar token `cr1_`» (la fuente Relay solo funciona con sesión). Se dejan de crear códigos de pairing. | nueva versión de la app |
| **3 (con aprobación del dueño)** | Se borra el Worker `chopshop-relay` y su Durable Object, se elimina `apps/relay`, el camino `cr1_` del agente (`relaycfg` token, `relay pair`) y de la app; `relay-deploy.yml` se borra. | borrado del viejo |

El cambio de modelo de auth **no se despliega sin aprobación explícita del dueño** (ningún hilo ejecuta el workflow ni toca
Cloudflare). No hay migración de datos del relay viejo: sus tokens, códigos y cuentas `ac-…` no pasan a D1 (las máquinas se
vuelven a ligar por login, que es el requisito).

### 8.2 Rutas que se retiran

El Worker nuevo **no implementa**: `POST /v1/pair`, `POST /v1/pair/codes`, `DELETE /v1/pair/codes/<id>`,
`DELETE /v1/tokens/<id>`, `GET /whoami`, `GET /state`, `GET /stream` (sin `/v1`), `GET /agent/ws`, ni los frames
`whoami`/`whoami.result`. Desaparecen los tokens `cr1_` (y el `csv1_` de la propuesta original, que nunca existió en código) y el
rol `viewer`: lo sustituye una sesión de watcher.

### 8.3 Configuración local → nube (HOY)

1. El agente v2, al conectar, construye la oferta: perfiles de `~/.chopshop/profiles/*.yaml` + entradas de
   `~/.config/chopshop/projects.toml` cuyos proyectos **no** están ya en el `sync` recibido; manda `import.offer` si el
   `sha256` de la oferta cambió desde la última (guardado en `~/.chopshop/cloud/import.sha256`).
2. La app muestra «Importar configuración de <máquina>» (`GET /v1/imports`); el dueño elige proyectos y campus;
   `POST /v1/imports/{id}/apply` crea workspaces/proyectos/roles/layouts en una transacción y dispara `sync`.
3. El agente recibe el `sync` con esos proyectos y pasa a modo nube para ellos (§9.4). Los archivos locales **no se borran**:
   quedan ignorados para esos proyectos (un aviso por arranque: «perfil local ignorado: gestionado en la nube»).
   `chopshop relay import --dry-run` enseña qué se ofrecería, sin enviar.

### 8.4 Documentación

- `docs/relay-protocol.md` se mueve a `docs/relay-protocol-v1.md` con un aviso «obsoleto, fases 0–2» al principio.
- `docs/relay-protocol.md` nuevo describe el v2 (§5.8 de este plan, con schemas en `packages/api/backend/`), la lista blanca
  (sin cambios de campos, más `workspace_id`) y remite a `docs/backend-api.md` (nuevo: §3–§6 de este plan como referencia).
- `docs/relay.md` (operación) se reescribe para `chopshop-api`: dominios, secretos, migraciones D1, bootstrap, recuperación.

### 8.5 Dominio y despliegue

`apps/backend/wrangler.toml` (lo prepara la tarea X1; desplegar solo con aprobación):

```toml
name = "chopshop-api"
main = "src/index.ts"
compatibility_date = "2026-10-01"
workers_dev = false
routes = [
  { pattern = "api.chopshop.novarix.online", custom_domain = true },
  { pattern = "chopshop.novarix.online", custom_domain = true },
]

[[d1_databases]]
binding = "DB"
database_name = "chopshop"
database_id = "<id de la D1, lo rellena el primer despliegue>"
migrations_dir = "migrations"

[[durable_objects.bindings]]
name = "HUB"
class_name = "Hub"

[[migrations]]
tag = "v1"
new_sqlite_classes = ["Hub"]

[assets]
directory = "../web-admin/dist"
binding = "ASSETS"
not_found_handling = "single-page-application"
run_worker_first = true

[triggers]
crons = ["17 4 * * *"]

[vars]
API_ORIGIN = "https://api.chopshop.novarix.online"
WEB_ORIGIN = "https://chopshop.novarix.online"
PASSWORD_PEPPER_VERSION = "1"
```

El Worker despacha por `Host`: `chopshop.novarix.online` → `env.ASSETS.fetch(request)`; `api.chopshop.novarix.online` → API;
otro host → 404.

Workflow `.github/workflows/backend-deploy.yml`: **solo `workflow_dispatch`** (nada de tags automáticos), con un input
`confirm` que debe valer `deploy`; pasos: `pnpm install --frozen-lockfile --filter @chopshop/backend... --filter
@chopshop/web-admin...`, `check`, `test`, `build` de la web, `wrangler d1 migrations apply chopshop --remote`, `wrangler deploy`
con el secret `RELAY_OPERATOR_TOKEN` (mismo valor que hoy). Secrets del repo: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
`RELAY_OPERATOR_TOKEN`. El secret del Worker `PASSWORD_PEPPER` (§3) **no** pasa por el repo ni por Actions: el dueño lo fija una
vez a mano con `wrangler secret put PASSWORD_PEPPER` antes del primer despliegue (si se pierde, todas las contraseñas dejan de
verificar y se entra por la recuperación del operador, §4.8). `PASSWORD_PEPPER_VERSION` va en `[vars]` (`"1"`). Plan de la cuenta:
**Workers Free**; el `wrangler.toml` no lleva `[limits] cpu_ms` (solo existe en Paid).

Permisos del token `CLOUDFLARE_API_TOKEN` (token con permisos acotados, no la Global API Key):

| ámbito | permiso |
|---|---|
| Cuenta | Workers Scripts: Edit · D1: Edit · Account Settings: Read |
| Zona `novarix.online` | Zone: Read · DNS: Edit · Workers Routes: Edit |

(Custom Domains crea los registros DNS y el certificado por su cuenta; por eso pide DNS: Edit en la zona.)

Verificación tras el despliegue (la hace el dueño u operador, no un hilo): `dig +short api.chopshop.novarix.online` y
`chopshop.novarix.online` resuelven a Cloudflare; `curl -sS https://api.chopshop.novarix.online/health` → `{"ok":true,…}`; la web
carga con certificado válido; `curl -sSI https://api.chopshop.novarix.online/v1/auth/me` → 401 con las cabeceras de §6;
`wrangler d1 migrations list chopshop --remote` sin pendientes.

---

## 9. Cambios en el agente (Python, solo stdlib)

### 9.1 Configuración y credencial

- `[relay] url` pasa a ser la **base de la API** (`https://api.chopshop.novarix.online`). El agente deriva el WebSocket:
  `https→wss`, ruta `/v1/connect`. Compatibilidad: si `url` acaba en `/v1/connect` o empieza por `wss://`, se usa tal cual
  (configs viejas). `CHOPSHOP_RELAY__URL` sigue valiendo.
- Credencial en `$XDG_CONFIG_HOME/chopshop/relay/machine.json` (por defecto `~/.config/chopshop/relay/`), 0600, directorio 0700,
  escrita con `tmp` + `os.replace` como `relaycfg.write_token`:
  `{"v": 1, "api_url": "…", "machine_id": "<uuid>", "local_machine_id": "…", "credential": "cm1_…", "linked_at": "…"}`.
  Si existe, el agente usa v2 con `api_url` del archivo (manda sobre `[relay] url`); si no, cae al camino `cr1_` actual (fases
  0–2).
- `relaycfg.py` gana: `machine_path()`, `read_machine()`, `write_machine(d)`, `remove_machine()`, `MACHINE_CRED_RE =
  ^cm1_[A-Za-z0-9_-]{43}$`, y los subcomandos `chopshop relay link --stdin [--api URL]`, `relay status` (muestra API, máquina,
  credencial enmascarada `cm1_…abcd`, permisos), `relay unlink` (borra `machine.json`; avisa de revocar en la app),
  `relay import --dry-run`. `relay pair/unpair` siguen hasta la fase 3.
- `chopshop relay admin bootstrap --email E (--token-file F | --stdin) [--api URL]` y `chopshop relay admin recover (--token-file
  F | --stdin) [--api URL]` (nuevo módulo `chopshop/relayadmin.py`): llaman `/v1/operator/*` con `urllib`, imprimen el enlace
  una vez y nunca el secret; códigos de salida: 0 ok, 1 error, 2 conflicto (ya hay dueño / no hay dueño).

### 9.2 Endpoint local de enlace

En el router del agente (`agent/server.py`), solo en el listener de loopback (`127.0.0.1`/`::1`; en cualquier otro listener,
`404`):

| ruta | auth | cuerpo | respuesta |
|---|---|---|---|
| `GET /local/relay/status` | loopback | — | `200 {local_machine_id, linked: bool, api_url, machine_id, connected, last_error}` (nunca la credencial) |
| `POST /local/relay/link` | loopback + nonce | `{api_url, machine_id, local_machine_id, credential}` | `204`; `400` formato; `409` `local_machine_id` distinto del del agente |
| `POST /local/relay/unlink` | loopback + nonce | — | `204` |

Autenticación del enlace: al arrancar, el agente crea `$XDG_CONFIG_HOME/chopshop/agent/link.nonce` (0600, 32 bytes aleatorios en
base64url). La app (mismo usuario del sistema) lo lee y lo manda en `X-Chopshop-Link-Nonce`; comparación con
`hmac.compare_digest`. Tras cada `link`/`unlink` correcto el nonce se rota. Además: el peer debe ser loopback, `Host` debe ser
`127.0.0.1:<port>`, `localhost:<port>` o `[::1]:<port>`, y una petición con cabecera `Origin` se rechaza (`403`), lo que impide
que una web la dispare. Tras `link`, el hilo `relay` se reinicia con la credencial nueva sin reiniciar el servicio.

### 9.3 Reconexión (`agent/relay.py`)

- `RelayLink` recibe `(api_url, credential, …)`; en v2 `hello.protocol = [2]`; el camino `cr1_` (fases 0–2) sigue con `[1]`.
- Cierre 4401 o upgrade 401 → no borra `machine.json`, marca `last_error = "revocada"`, deja de reintentar hasta que cambie `machine.json`
  (lo vigila por `mtime` cada 30 s). 4403/403 (pausada) → reintenta cada 600 s. 4409 (conflicto) → 600 s. Resto: backoff actual.
- Snapshots: uno por workspace (`relaysync.snapshot(..., workspace_id=…, projects=…)`), con la misma lógica de digest por
  workspace. Eventos: `relaysync.event` añade `workspace_id` desde el mapa proyecto→workspace del último `sync`.
- `cmd` (fase de comandos): traduce `name` con la tabla de §5.4 y llama `Router.call(method, path, ident_relay, query, body)`
  con una identidad `relay` de escritura; responde `cmd.result`. Un `name` desconocido → `cmd.result {ok: false, status: 400}`.

### 9.4 Sincronización hacia abajo y modo nube

- Al recibir `sync`: escribe `~/.chopshop/cloud/state.json` (0600, `{rev, machine, workspaces, projects}`), materializa cada
  proyecto en `~/.chopshop/cloud/profiles/<name>.json` (perfil equivalente según la tabla de §2) y cada prompt en
  `~/.chopshop/cloud/prompts/<name>/<rol>.md` (el perfil apunta `prompt_file` ahí), borra los de proyectos que ya no vienen,
  valida con `profile.validate` y responde `sync.ack` con `applied` y `errors`. (`~/.chopshop` = `CHOPSHOP_HOME`.)
- `profile.load(name)` y `profile.list_projects()`: si hay `state.json`, los proyectos de la nube salen de
  `cloud/profiles/*.json` y **mandan** sobre `~/.chopshop/profiles/<name>.yaml` del mismo nombre. Override local opcional en
  `~/.chopshop/profiles/<name>.local.yaml`, solo con claves de la máquina: `worktree_root`, `t3_project`,
  `integration.test_cwd` (cualquier otra clave se ignora con aviso).
- `registry` (`projects.toml`): en modo nube, `list` devuelve los proyectos de `state.json` (con `company` = nombre del
  workspace, `host = "local"`); `POST /projects`, `POST /projects/<p>/disable` y `PUT /office/<p>` de la API local responden
  `409` «gestionado en la nube» para proyectos de la nube. Proyectos solo locales siguen como hoy (y se ofrecen para importar).
- **Conflictos**: la nube gana siempre en estructura; el agente nunca edita estructura localmente en modo nube.
- **Sin conexión**: el agente sigue con el último `state.json` (ejecuta, encola localmente, emite eventos al bus local); al
  reconectar recibe el `sync` vigente y aplica la diferencia. Sin `state.json` nunca recibido: modo local como hoy.
- **Subida**: eventos y snapshots como hoy (lista blanca) + `sync.ack`; en S2, `task.*`.
- **Fase S2 (DESPUÉS)**: tareas en la nube; el agente reclama con CAS (`task.claim {task_id, rev}` → `task.claimed` o
  `task.conflict`), arriendo de 24 h, informa `task.update {task_id, state, result_summary}`; las creadas sin conexión llevan
  `idem_key` y se suben al reconectar; una cancelación de la nube interrumpe el hilo; estados terminales: gana el primero.

---

## 10. Cambios en la app Mac (Swift; se compila y prueba solo en la Mac mini)

### 10.1 Sesión y Keychain

```swift
public struct BackendUser: Codable, Equatable, Sendable { public let id: String; public let email: String; public let displayName: String?; public let role: Role; public enum Role: String, Codable, Sendable { case owner, watcher } }
public struct BackendSession: Equatable, Sendable { public let apiURL: URL; public let token: String; public let user: BackendUser }
public protocol SessionStore: AnyObject, Sendable {
    func load(apiURL: URL) -> String?
    func save(_ token: String, apiURL: URL) throws
    func delete(apiURL: URL) throws
}
```

`KeychainSessionStore`: contraseña genérica, servicio `com.chopshop.session`, cuenta = host de la API, mismos atributos que
`KeychainCredentialStore` (`AfterFirstUnlockThisDeviceOnly`, sin iCloud). En la migración (fase 2) se borra el servicio viejo
`com.chopshop.relay`.

### 10.2 Cliente de la API

`BackendClient(apiURL:, session:, transport: HTTPTransport)` con un método por ruta de §5 (mismos nombres de campos, `Codable`
con `snake_case`): `login`, `logout`, `me`, `changePassword`, `recover`, `regenerateRecoveryCode`, `invitations`, `invite`,
`reissueInvitation`, `revokeInvitation`, `inspectInvitation`, `acceptInvitation`, `users`, `setUserStatus`, `sessions`,
`revokeSession`, `machines`, `linkMachine`, `createMachineToken`, `renameMachine`, `pauseMachine`, `resumeMachine`,
`revokeMachine`, `workspaces`, `createWorkspace`, `updateWorkspace`, `archiveWorkspace`, `campus`, `putCampus`, `watchers`,
`share`, `unshare`, `attachMachine`, `detachMachine`, `projects`, `createProject`, `updateProject`, `archiveProject`, `layout`,
`putLayout`, `roles`, `createRole`, `updateRole`, `deleteRole`, `imports`, `importDetail`, `applyImport`, `dismissImport`,
`state`, `command`, `audit`. Un 401 en cualquier llamada → borra la sesión del Keychain y vuelve a la pantalla de login.

`LocalAgentLinker.link(agentURL: URL, nonceFile: URL, payload: LinkPayload) async throws` y `status(agentURL:)`: implementan
§9.2 (lee el nonce, nunca lo registra).

### 10.3 Fuente de datos

`Config.destination == .relay` pasa a significar «Nube (sesión)»: `LiveStore.connect` usa `GET /v1/stream` con `Bearer ss1_`
y `GET /v1/state` para el estado inicial y cada evento `structure`. La fuente Local (Tailscale) se mantiene sin cambios. Con un
watcher, la app fuerza la fuente Nube y oculta todo lo que escribe (`canAct = false`, como hoy con `viewer`).

### 10.4 Pantallas y sidebar

Al abrir sin sesión válida: **Login** (URL de la API con el valor por defecto `https://api.chopshop.novarix.online`, correo,
contraseña) con enlaces «Aceptar invitación» (pegar enlace → `inspect` → contraseña → `accept`; si trae `recovery_code`, hoja
modal para guardarlo) y «Usar código de recuperación».

Se recupera el **sidebar izquierdo** con cinco entradas (watcher: solo 1 y 5):

| entrada | contenido | acciones (dueño) |
|---|---|---|
| 1. Ciudad / Workspaces | la ciudad (`CityModel`: cada workspace es un `CityCampus`, cada proyecto un edificio de su campus; orden por `workspaces.position`) y la lista de workspaces | crear/renombrar/archivar workspace, editar campus (posición, estilo), crear/editar/mover/archivar proyectos y su layout (pisos y salas), asignar máquina, importar configuración local |
| 2. Máquinas | lista con online/pausada/revocada, última vez, versión, workspaces | ligar esta Mac, token para VPS (se muestra una vez con el comando), renombrar, desconectar/permitir, revocar, asignar a workspaces |
| 3. Empleados / colas | por proyecto: roles (prompt, modelo, reglas de match y wake) y empleados permanentes con su cola (de la parte `employees` del snapshot) | CRUD de roles; colas en solo lectura hasta S2 |
| 4. Watchers | watchers con sus workspaces y sesiones; invitaciones pendientes | invitar (correo + workspaces) y **Copiar enlace**, reemitir, revocar invitación, compartir/dejar de compartir workspaces, desactivar |
| 5. Ajustes | cuenta, sesiones propias (y todas, el dueño), fuente de datos, cerrar sesión | cambiar contraseña, regenerar código de recuperación, revocar sesiones, auditoría reciente |

`CityModel` hoy agrupa por `company`; con la fuente Nube el campus de un proyecto es su `workspace.name` (y el id del campus,
`workspace.id`). Los snapshots se fusionan por `(machine_id, workspace_id)`.

---

## 11. Descomposición

### 11.1 Dominios y responsabilidades

| id | dominio | responsabilidad | dueño de |
|---|---|---|---|
| **IDN** | Identidad | usuarios (owner/watcher), contraseñas, sesiones, recuperación, operador, invitaciones, límites de intentos | tablas `users`, `sessions`, `invitations`, `invitation_workspaces`, `auth_attempts`; rutas `/v1/auth/*`, `/v1/operator/*`, `/v1/invitations*`, `/v1/users*`, `/v1/sessions*` |
| **WSP** | Workspaces = campus | workspaces, campus, compartición con watchers, `workspace_machines` | `workspaces`, `workspace_members`, `campus_layouts`, `workspace_machines`; rutas `/v1/workspaces*` |
| **STR** | Estructura en la nube | proyectos, layouts, roles/empleados, colas (S2), `structure_rev`, importaciones, documento `sync` | `projects`, `project_layouts`, `roles`, `import_offers`, `tasks`, `meta`; rutas `/v1/projects*`, `/v1/roles*`, `/v1/imports*` |
| **CTY** | Ciudad por usuario | composición de `GET /v1/state` (estructura visible + vivo filtrado) | módulo `state.ts`; nada de tablas |
| **MCH** | Máquinas | enlace por login, token VPS, pausa, revocación, credencial `cm1_` | `machines`; rutas `/v1/machines*` |
| **HUB** | Relay en vivo | WebSocket de agentes v2, snapshots por workspace, stream SSE filtrado, `sync` push, comandos, auditoría de comandos | DO `Hub` y su SQLite; rutas `/v1/connect`, `/v1/stream`, `/v1/commands`, `/v1/audit` |
| **AGT** | Agente local | credencial y CLI, endpoint local de enlace, relay v2, modo nube, importación, CLI de operador | `apps/agent` |
| **MAC** | App Mac | login, Keychain, fuente Nube, sidebar y todas las pantallas de edición | `apps/mac` |
| **WEB** | Web admin | aceptar invitación y login (HOY); resto de pantallas (DESPUÉS) | `apps/web-admin` |
| **OPS** | Infra y docs | refactor a `apps/`, wrangler, dominio, workflow, documentación | `apps/backend/wrangler.toml`, `.github/workflows/`, `docs/` |

### 11.2 Contratos entre dominios

Dentro del Worker (`apps/backend/src`), TypeScript:

```ts
type Principal =
  | { kind: "anonymous" }
  | { kind: "user"; userId: string; role: "owner" | "watcher"; sessionId: string; client: "mac" | "web" | "cli"; viaCookie: boolean }
  | { kind: "machine"; machineId: string; localMachineId: string | null; paused: boolean }
  | { kind: "operator" };

interface ViewCtx { userId: string; role: "owner" | "watcher"; sessionId: string; workspaceIds: string[] | "all" }
interface OwnerCtx { userId: string; role: "owner"; sessionId: string }
interface MachineCtx { machineId: string; localMachineId: string | null; name: string }
interface Command { commandId: string; machineId: string; name: string; args: unknown }
interface CommandResult { ok: boolean; status: number; body: unknown }
interface SyncDoc { rev: number; machine: { id: string; name: string }; workspaces: { id: string; name: string; slug: string }[]; projects: SyncProject[] }
```

| contrato | proveedor | consumidores | firma |
|---|---|---|---|
| resolver principal | IDN (`auth.ts`) | todas las rutas | `resolvePrincipal(req, env): Promise<Principal \| Response>` |
| alcance de lectura | WSP (`access.ts`) | CTY, STR, HUB (vía Worker) | `visibleWorkspaces(db, p): Promise<string[] \| "all">`; `assertVisible(db, p, workspaceId)` → 404 |
| solo dueño | IDN | todas las escrituras | `requireOwner(p): OwnerCtx \| Response` (403) |
| subida de revisión | STR (`structure.ts`) | WSP, STR, importaciones | `bumpStructure(db, stmts): Promise<number>` (batch + `structure_rev`) |
| documento de sync | STR | HUB | `syncDocFor(db, machineId): Promise<SyncDoc>` |
| verificar máquina | MCH (`machines.ts`) | `/v1/connect` | `verifyMachine(db, bearer): Promise<MachineCtx & {paused} \| null>` |
| auditoría | OPS/IDN (`audit.ts`) | todos | `audit(db, entry): Promise<string>`; `finishAudit(db, id, result, status)` |
| RPC del Hub | HUB (`hub.ts`) | Worker | `connectAgent(req, MachineCtx): Promise<Response>`; `state(ViewCtx): Promise<LiveState>`; `stream(req, ViewCtx): Promise<Response>`; `command(OwnerCtx, Command): Promise<CommandResult>`; `machineChanged(machineId, {paused?, revoked?, workspaceIds?}): Promise<void>`; `structureChanged(rev, machineIds \| "all"): Promise<void>`; `viewerChanged(userId): Promise<void>`; `sessionRevoked(sessionId): Promise<void>`; `online(): Promise<string[]>` |
| Hub → D1 | HUB | — | lee `syncDocFor`, el id del dueño; escribe `machines.last_seen_at/agent_version/local_machine_id` (máx. 1/min), `import_offers` |

Entre procesos:

| de → a | canal | contrato |
|---|---|---|
| MAC/WEB/CLI → Worker | HTTP §5 | schemas en `packages/api/backend/*.schema.json` + fixtures |
| AGT → Hub | WebSocket v2 §5.8 | schemas `packages/api/backend/ws-*.schema.json` |
| MAC → AGT | HTTP loopback §9.2 | `GET /local/relay/status`, `POST /local/relay/link`, `POST /local/relay/unlink` |
| operador → Worker | HTTP `/v1/operator/*` | CLI `chopshop relay admin` |
| Hub → visores | SSE §5.5 | eventos `hello`, `snapshot`, `event`, `machine`, `structure`, `error` |

Quién llama a quién: MAC/WEB → Worker → (D1, Hub); AGT → Worker (`/v1/connect`) → Hub; Hub → D1 (lectura de estructura y
escrituras puntuales); Worker → Hub tras cada cambio que afecte lo vivo (`machineChanged`, `structureChanged`, `viewerChanged`,
`sessionRevoked`). El Hub nunca llama al Worker.

### 11.3 Qué se reemplaza y qué se reutiliza

| archivo actual | destino | qué |
|---|---|---|
| `packages/relay/src/index.ts` | **reemplaza** → `apps/backend/src/index.ts` + `hub.ts` | `idFromName("global")` y `fetch` del DO pasan a Worker con auth + RPC; se reutiliza el esqueleto de `alarm`/`webSocket*` |
| `packages/relay/src/routes.ts` | **reemplaza** → `apps/backend/src/router.ts` + `auth.ts` | roles `anonymous/viewer/machine/admin` → principales de §5.2; se reutiliza la idea de tabla de rutas y el 405 con `Allow` |
| `packages/relay/src/db.ts` | **parte**: se reutilizan `sha256Hex`, base64url, `clampTtl`, `putSnapshot/getSnapshot/listSnapshots/purgeExpiredSnapshots/nextSnapshotExpiry` y `migrate()` (para el SQLite del Hub, clave `(machine_id, workspace_id)`); se **eliminan** `tokens`, `pair_codes`, `attempts`, `machines`(DO), `issueToken/verifyToken/revokeToken` |
| `packages/relay/src/pair.ts` | **elimina** | pairing por código; se reutiliza solo `timingSafeEqual` (pasa a `crypto.subtle.timingSafeEqual`) y `normalizeCode` (para el código de recuperación) |
| `packages/relay/src/agentws.ts` | **reutiliza** → `apps/backend/src/agentws.ts` | validación de frames, cuotas, hello/welcome, ping, sweep, ulid, errores; cambia: auth fuera (llega `MachineCtx`), sin `account`, `workspace_id` en snapshot/event, frames `sync`/`import.offer`/`cmd`/`cmd.result`, sin `whoami` |
| `packages/relay/src/viewer.ts` | **reutiliza** → `apps/backend/src/viewer.ts` | SSE, buffer, épocas, latido, backpressure; cambia: filtro por `ViewCtx.workspaceIds` en vez de `account`, revocación por `sessionId`/`userId`, eventos `machine`/`structure` |
| `packages/relay/test/*` | **reutiliza** el arnés (`cloudflare-workers.ts`, `register.mjs`, `hooks.mjs`) en `apps/backend/test/`, añadiendo un doble de D1 sobre `node:sqlite` | tests nuevos por tarea |
| `packages/relay` (paquete) | **mueve** a `apps/relay` (congelado, fases 0–2) y se borra en la fase 3 | |
| `packages/api/relay/*` (schemas v1) | se **conservan** hasta la fase 3; nuevos en `packages/api/backend/` | `snapshot`, `event`, `error`, `ping/pong`, `hello`, `welcome` se copian a v2 con `workspace_id`/`machine`/`rev`; `pair-*`, `whoami*` no pasan |
| `apps/agent/chopshop/relaycfg.py` | **amplía** (`machine.json`, `link/status/unlink/import`); el token `cr1_` se borra en fase 3 | |
| `apps/agent/chopshop/relaysync.py` | **reutiliza** (lista blanca, partes, digest); añade `workspace_id`, snapshot por workspace, `sync_ack`, `import_offer` | |
| `apps/agent/chopshop/agent/relay.py` | **reutiliza** el bucle (`RelayLink.run/_session`, backoff, ping); cambia credencial, protocolo 2, manejo de 4401/4403/4409, `sync`, `cmd` | |
| `apps/agent/chopshop/wsclient.py` | **reutiliza** sin cambios | |
| `apps/agent/chopshop/agent/pairing.py` (`cs1_`) | **sin cambios**: es el emparejamiento de la API local en la tailnet, no del relay | |
| `apps/agent/chopshop/agent/registry.py`, `chopshop/profile.py` | **amplía**: modo nube (§9.4) | |
| `apps/mac/.../ChopshopUI/RelayLogin.swift`, `ChopshopNative/Live/RelayLoginView.swift`, `RelayLoginSnapshots.swift` | **reemplaza** por login con correo/contraseña (`BackendLoginView`) | se reutilizan los estados de la vista (checking, rate limited con `retry_after_s`) |
| `apps/mac/.../Live/Credentials.swift` | **reutiliza** `KeychainCredentialStore` como base de `KeychainSessionStore`; `relayService` se retira en fase 2 | |
| `apps/mac/.../Live/LiveStore.swift` | **reutiliza**; la fuente relay pasa a `/v1/stream` + `/v1/state` con sesión | |
| `apps/mac/.../ChopshopUI/Config.swift`, `ConfigWriter.swift`, `SettingsView.swift` | **amplía**: destino «Nube (sesión)», sin campo de token | |
| `apps/mac/.../City/CityModel.swift` | **amplía**: campus = workspace con la fuente Nube | |
| `docs/relay-protocol.md`, `docs/relay.md` | **reemplaza** (§8.4) | |
| `.github/workflows/relay-deploy.yml` | se **conserva** hasta la fase 3; nuevo `backend-deploy.yml` | |

### 11.4 Tareas

Cada tarea incluye sus propios tests (unitarios con el arnés de `apps/backend/test` o `unittest` en el agente); «tests» en
criterios = `pnpm --filter <paquete> run check` y `run test` en verde, o `python3 -m unittest discover -s tests` en
`apps/agent`. **HOY** = entra en la implementación de hoy; **DESPUÉS** = no se empieza hoy. Las tareas de una misma ola sin
dependencia entre ellas van **en paralelo**.

**Ola 0 (secuencial, primero)**

| id | dom. | alcance | archivos | dep. | aceptación | cuándo |
|---|---|---|---|---|---|---|
| X0 | OPS | `git mv packages/relay apps/relay`; actualizar `pnpm-workspace.yaml` (`apps/*`), rutas en `relay-deploy.yml`, `tools/contract_audit.py` y docs que citen `packages/relay`; esqueleto `apps/backend` (`package.json` `@chopshop/backend` con `check`/`test`, `tsconfig.json`, `src/index.ts` con `/health`, arnés de tests copiado + doble de D1 sobre `node:sqlite`, `wrangler.toml` sin dominios) y `apps/web-admin` (`package.json` con `build`/`check`/`test` vacíos) | los citados | — | `pnpm install --frozen-lockfile` (con lock actualizado), tests de `@chopshop/relay`, `@chopshop/backend` y `contract_audit` en verde | HOY |

**Ola 1 (paralelo)**

| id | dom. | alcance | archivos | dep. | aceptación | cuándo |
|---|---|---|---|---|---|---|
| B1 | STR/IDN | migraciones `0001`–`0003` de §2 y capa de acceso `db.ts` (helpers `now()`, `uuid()`, `batch`) | `apps/backend/migrations/*`, `src/db.ts` | X0 | las migraciones aplican en el doble de D1; tests de restricciones: dos `owner` falla, email duplicado falla, `rev` CAS | HOY |
| B2 | IDN | `crypto.ts`: PBKDF2 (formato §3, rehash), tokens con prefijo, `sha256Hex`, `timingSafeEqual`, código de recuperación y normalización | `src/crypto.ts` | X0 | tests: verifica/rechaza, formato, 100 000 iteraciones, longitudes, normalización `O→0`/`I→1` (formato y iteraciones los sustituye B2b) | HOY |
| B2b | IDN | plan gratis: medición de CPU de PBKDF2 en `workerd`, 10 000 iteraciones, pepper HMAC-SHA256 versionado (`pepperFromEnv`, esquema `pbkdf2-sha256-p<v>`), `needsRehash` por pepper e iteraciones, límites de intentos (`limitKey`, `loginKeys`, `retryAfter`, `recordFailure`, `clearLimit`, `purgeAttempts`, cuerpos uniformes 401/429) | `src/crypto.ts`, `src/ratelimit.ts`, `scripts/measure-pbkdf2.mjs` | B2 | tests: hashes viejos sin pepper (100 000 y 1000) verifican y piden rehash, pepper incorrecto no verifica, rotación de versión, bloqueo progresivo `ei:`, `e:`/`ip:` para todas las IPs/correos, ventana, purga, mensajes uniformes | HOY |
| B3 | OPS | `http.ts` + `router.ts`: errores §5.1, tabla de rutas con 404/405, CORS, cabeceras §6, lectura de cookie, CSRF, límite de cuerpo, despacho por `Host` (web → `ASSETS`) | `src/http.ts`, `src/router.ts` | X0 | tests: CORS solo para el origen web, CSRF exige `Origin`+token, cabeceras presentes, 413 | HOY |
| S1 | OPS | schemas JSON y fixtures de §5 (HTTP) y §5.8 (WS v2) | `packages/api/backend/*` | X0 | `contract_audit` ampliado valida fixtures contra schemas | HOY |
| A1 | AGT | `relaycfg.py`: `machine.json` y `relay link/status/unlink`; `[relay] url` como base de API con compatibilidad | `chopshop/relaycfg.py`, tests | X0 | tests: 0600/0700, enmascarado, rechazo de formato, derivación `https→wss` y compatibilidad `wss://…/v1/connect` | HOY |
| A2 | AGT | `relayadmin.py` + `chopshop relay admin bootstrap/recover` | `chopshop/relayadmin.py`, `cli.py`, tests | X0 | tests con un servidor HTTP falso en loopback: secret por `--token-file`/`--stdin` nunca en salida ni `argv`; códigos de salida 0/1/2 | HOY |
| M1 | MAC | `BackendClient` (todas las llamadas de §10.2), modelos `Codable`, `KeychainSessionStore`, `LocalAgentLinker` | `apps/mac/Sources/ChopshopNative/Backend/*` | X0, S1 (fixtures) | `swift test` en la Mac mini: decodifica todas las fixtures de `packages/api/backend`, 401 borra la sesión | HOY |
| M3 | MAC | sidebar izquierdo con las 5 entradas (§10.4), vacías salvo Ciudad; oculta 2–4 para watcher | `apps/mac/Sources/ChopshopNative/Shell/*` | X0 | `swift build`/`swift test`; captura con las 5 entradas | HOY |

**Ola 2 (paralelo, tras B1–B3)**

| id | dom. | alcance | archivos | dep. | aceptación | cuándo |
|---|---|---|---|---|---|---|
| B4 | IDN | `auth.ts` (`resolvePrincipal`, `requireOwner`), login, logout, me, password, sesiones (lista/revocar, deslizante), límites `auth_attempts` con `src/ratelimit.ts` (antes de PBKDF2), pepper con `pepperFromEnv(env)` (503 si falta), rehash en login, auditoría de auth (`audit.ts`) | `src/auth.ts`, `src/audit.ts`, `src/routes/auth.ts`, `src/routes/sessions.ts` | B1, B2b, B3 | tests: login ok/401 genérico (mismo cuerpo con correo inexistente, contraseña mala y usuario desactivado), bloqueado no llama a PBKDF2, hash viejo se rehace al entrar, bloqueo progresivo y `Retry-After`, cookie web con atributos, `Bearer` mac, deslizamiento y absoluta, revocar cierra (stub del Hub llamado), watcher solo ve sus sesiones | HOY |
| B5 | IDN | `/v1/operator/bootstrap` y `/recover`, `/v1/auth/recover`, `/v1/auth/recovery-code` (límites y pepper de B2b) | `src/routes/operator.ts`, `src/routes/recovery.ts` | B1, B2b, B3 | tests: bootstrap 201 y luego 409, recover sin dueño 409, código de recuperación de un solo uso, todas las sesiones revocadas, límites `op:`/`rc:` | HOY |

**Ola 3 (paralelo, tras B4)**

| id | dom. | alcance | archivos | dep. | aceptación | cuándo |
|---|---|---|---|---|---|---|
| B6 | IDN | invitaciones: crear (link con fragmento), listar, reemitir, revocar, `inspect`, `accept` (3 tipos; workspace `Personal` y código en `owner_*`; hash con pepper; límites `inv:`/`ip:` de B2b); usuarios: listar, `PATCH` status | `src/routes/invitations.ts`, `src/routes/users.ts` | B4, B5 | tests: link `https://chopshop.novarix.online/invite#t=ci1_…`, reissue invalida el anterior, 410 usada/caducada, accept watcher crea membresías, desactivar revoca sesiones y llama `viewerChanged` | HOY |
| B7 | WSP/STR | workspaces (CRUD, campus, watchers, máquinas del workspace), proyectos, layouts, roles; `access.ts` y `structure.ts` (`bumpStructure`, `syncDocFor`) | `src/access.ts`, `src/structure.ts`, `src/routes/workspaces.ts`, `src/routes/projects.ts` | B4 | tests: CAS 409 con `current`, watcher 404 fuera de alcance y 403 en escrituras, rol sin `prompt` para watcher, `structure_rev` sube y `structureChanged` recibe las máquinas correctas, `machine_id` fuera del workspace → 400 | HOY |
| B8 | MCH | máquinas: `link`, token VPS, listar, renombrar, pausar/reanudar, revocar (`machineChanged`), `verifyMachine` | `src/machines.ts`, `src/routes/machines.ts` | B4 | tests: credencial solo en la respuesta de creación, `link` revoca la anterior del mismo `local_machine_id`, revocada → `verifyMachine` null, pausada → `paused: true`, auditoría `machine.*` | HOY |

**Ola 4 (paralelo)**

| id | dom. | alcance | archivos | dep. | aceptación | cuándo |
|---|---|---|---|---|---|---|
| H1 | HUB | Hub único con RPC (§11.2): `connectAgent` v2 (adaptar `agentws.ts`), snapshots por `(máquina, workspace)` (en memoria al llegar; al SQLite del Hub como mucho uno por minuto y par, por el límite gratis de filas escritas, §12), `machine_cache`, `state`/`stream` filtrados por `ViewCtx` (adaptar `viewer.ts`), `machineChanged`, `viewerChanged`, `sessionRevoked`, `online`; rutas `/v1/connect`, `/v1/state` (CTY), `/v1/stream` | `src/hub.ts`, `src/agentws.ts`, `src/viewer.ts`, `src/state.ts`, `src/routes/live.ts` | B7, B8 | tests de §5.7 (1, 4, 5), pausa → 4403, revocar → 4401, `hello` con otro `machine_id` → cierre, primer `hello` fija `local_machine_id` (VPS), conflicto 4409 | HOY |
| H2 | HUB/STR | `sync` al conectar y en `structureChanged`, `sync.ack` → `sync_errors` en el state, evento SSE `structure` | `src/hub.ts`, `src/agentws.ts`, `src/structure.ts` | H1 | tests: cambio de proyecto → `sync` solo a la máquina afectada (antes y después), `rev` monótono, `sync.ack` con errores visible en `/v1/state` | HOY |
| H3 | STR | `import.offer` → `import_offers` (dedupe por hash), `/v1/imports*` con `apply` transaccional (empresa → workspace) | `src/routes/imports.ts`, `src/agentws.ts` | H1 | tests: oferta duplicada → `duplicate`, apply crea workspace por `company`, roles con prompt, layout, `skipped name_taken`, `structure_rev` sube | HOY |
| A3 | AGT | endpoint local `/local/relay/*` con nonce (§9.2) y reinicio del hilo relay | `agent/server.py`, `agent/service.py`, tests | A1 | tests: 404 fuera de loopback, 403 con `Origin`, 401 nonce malo, rotación tras uso, 409 `local_machine_id` distinto, nunca devuelve la credencial | HOY |
| A4 | AGT | relay v2: `cm1_`, protocolo 2, snapshot por workspace y `workspace_id` en eventos, manejo 4401/4403/4409 | `agent/relay.py`, `relaysync.py`, tests | A1, S1 | tests con un `factory` falso: hello v2, un snapshot por workspace, deja de reintentar tras 4401 hasta cambiar `machine.json`, 600 s tras 4403 | HOY |
| W1 | WEB | `Aceptar invitación` y `Login` (§7), build esbuild a `dist`, CSP compatible | `apps/web-admin/*` | B3, S1 | `pnpm --filter @chopshop/web-admin run build` y `test` (test de lógica: extrae `t` del fragmento, nunca lo manda en la URL) | HOY |
| M2 | MAC | pantalla de login, aceptar invitación (pegar enlace), recuperación, fuente «Nube (sesión)» en `LiveStore`, cerrar sesión; reemplaza `RelayLogin*` | `apps/mac/Sources/...` (Live, ChopshopUI) | M1 | `swift test`; capturas login y aceptar invitación; 401 vuelve al login | HOY |

**Ola 5 (paralelo)**

| id | dom. | alcance | archivos | dep. | aceptación | cuándo |
|---|---|---|---|---|---|---|
| A5 | AGT/STR | modo nube: `sync` → `cloud/state.json`, perfiles `.json`, prompts, `sync.ack`; `profile`/`registry` leen la nube; override `.local.yaml`; 409 en la API local para proyectos de la nube | `agent/relay.py`, `chopshop/profile.py`, `agent/registry.py`, `agent/server.py`, módulo nuevo `chopshop/cloudsync.py`, tests | A4 | tests: materializa el ejemplo de `examples/profiles` ida y vuelta, borra proyectos que ya no vienen, sin conexión usa la caché, override solo con claves permitidas | HOY |
| A6 | AGT | `import.offer` desde perfiles y `projects.toml` (prompts inline, hash), `relay import --dry-run` | `relaysync.py`, `agent/relay.py`, `relaycfg.py`, tests | A4 | tests: no ofrece proyectos ya en el `sync`, no reenvía si el hash no cambió, ≤ 768 KiB, sin rutas locales fuera de los campos del perfil | HOY |
| M4 | MAC | Máquinas: lista, ligar esta Mac (`link` + `LocalAgentLinker`, revoca si falla), token VPS (una vez, con el comando), renombrar, desconectar/permitir, revocar, workspaces | `apps/mac/...` | M2, M3 | `swift test` con `BackendClient` falso; capturas | HOY |
| M5 | MAC | Watchers e invitaciones: invitar, **Copiar enlace**, reemitir, revocar, compartir/dejar de compartir, desactivar | `apps/mac/...` | M2, M3 | `swift test`; captura | HOY |
| M6 | MAC | Ciudad/Workspaces: ciudad por workspaces (campus = workspace), CRUD de workspaces/campus/proyectos/layout, importar configuración local | `apps/mac/...` (City, Shell) | M2, M3 | `swift test` (`CityTests` con campus por workspace); capturas | HOY |
| M7 | MAC | Empleados/colas: CRUD de roles; colas de la parte `employees` en solo lectura | `apps/mac/...` | M2, M3 | `swift test`; captura | HOY |
| M8 | MAC | Ajustes: cuenta, contraseña, código de recuperación, sesiones (propias/todas), auditoría reciente, cerrar sesión | `apps/mac/...` | M2, M3 | `swift test`; captura | HOY |
| X1 | OPS | `wrangler.toml` final (§8.5: dominios, D1, assets, cron, `PASSWORD_PEPPER_VERSION`, sin `[limits]`), `backend-deploy.yml` solo manual con `confirm`, sin ejecutarlo | `apps/backend/wrangler.toml`, `.github/workflows/backend-deploy.yml` | X0 | `pnpm --filter @chopshop/backend run check`; `wrangler deploy --dry-run --outdir dist` local sin credenciales | HOY |
| X2 | OPS | docs: `relay-protocol.md` v2 + `relay-protocol-v1.md`, `backend-api.md`, `relay.md` reescrito (dominio, permisos del token, bootstrap, recuperación, verificación) | `docs/*` | H2, B6, B8 | consistente con este plan y con `packages/api/backend` (`contract_audit` en verde) | HOY |
| T1 | OPS | suite de aislamiento de extremo a extremo en el arnés: dueño, dos watchers, dos workspaces, una máquina por workspace; invariantes §5.7 (1–5) | `apps/backend/test/isolation.test.ts` | H1, B6 | todos los invariantes en verde | HOY |

**DESPUÉS**

| id | dom. | alcance | dep. |
|---|---|---|---|
| C1 | HUB | `POST /v1/commands` + `cmd`/`cmd.result` + auditoría (§5.4), `GET /v1/audit` completo | H1 |
| C2 | AGT | ejecutor de `cmd` sobre el `Router` local (§9.3) | A4, C1 (contrato) |
| C3 | MAC | acciones de mando desde la ciudad por la Nube (responder, asentar, lanzar…) | C1, M6 |
| Q1 | STR | tareas en la nube (`0004_tasks.sql`, rutas `/v1/projects/{id}/tasks`, `/v1/tasks/{id}`) | B7 |
| Q2 | AGT | colas S2: claim CAS, arriendo, `task.update`, creación sin conexión con `idem_key` | Q1, A5 |
| Q3 | MAC | edición de colas en Empleados/colas | Q1, M7 |
| W2 | WEB | resto de pantallas de §7 | B6–B8, H1 |
| L1 | IDN | 2FA (TOTP) para el dueño | B4 |
| L2 | IDN | correo de invitaciones | B6 |
| L3 | OPS | auditoría extendida (lecturas, exportación, IP con hash diario) | C1 |
| R1 | OPS | fases 2 y 3 de §8.1 (retirar `cr1_`, `apps/relay`, `relay-deploy.yml`) con aprobación | despliegue fase 1 |

Grafo (HOY): `X0 → {B1, B2, B3, S1, A1, A2, M1, M3}`; `B2 → B2b`; `{B1, B2b, B3} → {B4, B5}`; `B4 → {B6 (también B5), B7, B8}`;
`{B7, B8} → H1 → {H2, H3, T1 (también B6)}`; `A1 → {A3, A4}`; `A4 → {A5, A6}`; `M1 → M2 → {M4, M5, M6, M7, M8}` (también M3);
`{B3, S1} → W1`; `X0 → X1`; `{H2, B6, B8} → X2`. Los hilos de MAC y AGT pueden empezar en cuanto exista S1 (fixtures), sin
esperar al backend.

---

## 12. Cloudflare (D1 + Durable Objects + Workers) vs AWS

| aspecto | Cloudflare | AWS (equivalente) |
|---|---|---|
| WebSocket de agentes con estado y bajo coste en reposo | Durable Object con Hibernation: una pieza, ya en producción en `packages/relay` | API Gateway WebSocket + Lambda + DynamoDB para conexiones; el estado en vivo se reparte en tres servicios |
| SQL | D1 (SQLite) con migraciones por wrangler | RDS/Aurora Postgres (coste fijo mensual, VPC) o DynamoDB (no relacional) |
| Web estática y dominio | Workers Assets + Custom Domains en la misma cuenta y despliegue | S3 + CloudFront + ACM + Route 53 |
| Operación | un `wrangler deploy` desde Actions; secretos del Worker | IaC (CDK/Terraform), IAM, varias consolas |
| Coste para un dueño y pocos watchers | **0 USD**: plan Workers Free (ver tabla siguiente); Workers Paid no es requisito | varias decenas de USD/mes con RDS; menos con DynamoDB pero más código |
| Riesgo | D1 es SQLite (límites de tamaño, sin `jsonb`); 10 ms de CPU por petición obligan a PBKDF2 de 10 000 iteraciones + pepper (§3) | más maduro para Postgres y Argon2 (en Lambda) |

**Plan gratis de Cloudflare: límites que aplican y cómo cabe el backend** (fuentes oficiales:
<https://developers.cloudflare.com/workers/platform/limits/>, <https://developers.cloudflare.com/d1/platform/limits/>,
<https://developers.cloudflare.com/d1/platform/pricing/>, <https://developers.cloudflare.com/durable-objects/platform/pricing/>,
<https://developers.cloudflare.com/durable-objects/platform/limits/>; consultadas el 2026-10-30):

| límite (Free) | valor | uso previsto y regla de diseño |
|---|---|---|
| CPU por petición HTTP del Worker | 10 ms | ruta más cara ≈ 7 ms (dos PBKDF2 de 10 000 iteraciones, §3); el resto, < 2 ms; esperas de D1, RPC al Hub y `cmd.result` son I/O y no cuentan |
| CPU por petición del Durable Object | 30 s (igual que Paid) | el Hub filtra snapshots y reenvía frames; nunca deriva contraseñas |
| peticiones del Worker | 100 000/día | app, web y SSE de un dueño y pocos watchers: órdenes de magnitud por debajo |
| Durable Objects | solo con SQLite; 100 000 peticiones/día, 13 000 GB-s/día; mensajes WebSocket entrantes cuentan 20:1 con Hibernation | un solo Hub con Hibernation (`new_sqlite_classes`, §8.5) |
| filas escritas en el SQLite del DO | 100 000/día | snapshots en memoria; al SQLite del Hub ≤ 1 por minuto y `(máquina, workspace)` (1440/día por par) |
| D1 | 500 MB por base, 5 GB por cuenta, 5 M filas leídas y 100 000 escritas al día, 50 consultas por invocación | escrituras: sesiones (`last_seen_at` cada ≥ 5 min), intentos, auditoría, estructura; los `batch` (importaciones, sync) deben quedar en ≤ 50 sentencias o partirse; superar el diario hace fallar las consultas hasta las 00:00 UTC |

Si algún día hiciera falta Paid (más CPU para subir iteraciones, más filas), no cambia el código: se sube `PBKDF2_ITERATIONS` y
`needsRehash` migra en cada login.

**Recomendación: Cloudflare.** Ya está desplegado y probado, el patrón Hub con Hibernation encaja exacto con «un dueño, pocas
máquinas, pocos visores», y el coste y la operación son mínimos. La salida a AWS u otro proveedor queda abierta por las reglas
de portabilidad de §2 (UUID en texto, fechas ISO, sin booleanos ni rarezas de SQLite, JSON en texto, migraciones numeradas):
las migraciones se pueden aplicar a Postgres cambiando solo los tipos `TEXT` de JSON a `jsonb` si se quiere, y la lógica del Hub
se reescribiría sobre un servicio de WebSocket con estado.
