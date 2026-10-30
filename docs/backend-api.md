# API del backend (`chopshop-api`)

Referencia de la API pública del backend con cuentas (`apps/backend`): principales, rutas, autorización, errores, contraseñas,
sesiones, límites de intentos, CORS/CSRF y qué no se registra. La consumen la app Mac, la web admin (`apps/web-admin`) y la
CLI; el agente solo usa `GET /v1/connect` ([`relay-protocol.md`](relay-protocol.md)). Contrato de diseño:
`docs/plans/auth-backend.md` §3–§6; operación: [`relay.md`](relay.md).

Schemas y fixtures: `packages/api/backend/<dominio>/<ruta>.<método>.<request|response>.schema.json` (`<ruta>` sin `/v1/`, con
`/` → `-` y `{id}` → `id`; p. ej. `POST /v1/auth/login` → `idn/auth-login.post.request`). Dominios: `ops`, `idn`, `mch`, `wsp`,
`str`, `cty`, `hub`. Las rutas que responden `204` no tienen schema de respuesta. Los valida `python3 tools/contract_audit.py
--backend`. Si este documento y un schema no coinciden, manda el schema.

## Hosts

| host | qué sirve |
|---|---|
| `https://api.chopshop.novarix.online` | la API (HTTP JSON, SSE y el WebSocket de los agentes) |
| `https://chopshop.novarix.online` | la web admin estática (Workers Assets); nunca llega a la lógica de la API |
| cualquier otro | `404` |

Todo es JSON UTF-8, cuerpo máx. 1 MiB (más → `413 too_large`) y toda respuesta lleva `Cache-Control: no-store`. Los clientes
mandan `User-Agent` explícito (`chopshop-mac/<v>`, `chopshop-cli/<v>`, `chopshop-agent/<v>`). Los ids son UUID v4 en
minúsculas y las fechas, ISO-8601 UTC con milisegundos y `Z`.

## Errores

`{v: 2, type: "error", id, ts, re: null, code, message, field?, retry_after_s?, current?}` (`error.schema.json`):

| `code` | HTTP | cuándo |
|---|---|---|
| `bad_request` | 400 (405 con `Allow` si el método no existe en la ruta) | cuerpo o campo inválido (`field` dice cuál); cookie y `Bearer` a la vez |
| `unauthorized` | 401 | sin credencial o credencial mal formada, desconocida, revocada o caducada |
| `forbidden` | 403 | principal válido sin permiso (watcher que escribe, máquina fuera de `/v1/connect`, CSRF) |
| `not_found` | 404 | ruta desconocida o recurso inexistente **o fuera del alcance** del principal |
| `conflict` | 409 | `rev` desactualizado (con `current` = recurso actual), duplicados, dueño ya existente |
| `gone` | 410 | invitación usada, revocada o caducada; máquina revocada |
| `too_large` | 413 | cuerpo > 1 MiB |
| `unsupported_version` | 426 | versión de protocolo no soportada |
| `rate_limited` | 429 | límite de intentos; `retry_after_s` y cabecera `Retry-After` |
| `internal` | 500 / 503 | error interno; 503 si falta un secret (pepper, operador) o el Hub |
| `timeout` | 504 | un comando no respondió a tiempo (fase de comandos) |

`message` nunca contiene secretos, correos ajenos, hashes ni contenido de partes opacas.

## Principales

El Worker resuelve **un** principal por petición antes de mirar la ruta:

| credencial | principal |
|---|---|
| ninguna (ni cabecera ni cookie) | `anonymous` |
| `Authorization: Bearer ss1_…` o cookie `__Host-chopshop_session` | `user` `{user_id, role, session_id, client}`: sesión viva y usuario `active` (la cookie solo vale para sesiones `web`) |
| `Authorization: Bearer cm1_…` | `machine` `{machine_id, local_machine_id, paused}`: máquina no revocada; solo sirve en `/v1/connect` |
| `Authorization: Bearer <RELAY_OPERATOR_TOKEN>` | `operator`: solo en `/v1/operator/*`; en cualquier otra ruta, 401 |

Reglas:

1. `user_id` y `role` salen **siempre** de la sesión, nunca del cuerpo, la query ni la ruta.
2. Un **watcher** solo ve los workspaces que el dueño le comparte (`workspace_members`); un recurso fuera de ese alcance da
   `404`, no `403`, para no revelar que existe.
3. Las escrituras son **solo del dueño**: un watcher recibe `403` en todo método distinto de `GET`, salvo `POST /v1/auth/logout`,
   `POST /v1/auth/password` y `DELETE /v1/sessions/{id}` sobre sus propias sesiones.
4. Hay un único Hub (`idFromName("owner")`); lo que manda el cliente (un `workspace_id`) solo **filtra** y se valida antes en D1.

Invariantes de aislamiento (los prueba la suite T1): un watcher sin membresía en W recibe 404 en toda ruta de W y no ve sus
frames ni su estado; recibe 403 en toda escritura; ninguna ruta usa un `user_id` del cliente para decidir permisos; una `cm1_`
solo sirve en `/v1/connect` y una `ss1_` no sirve ahí; quitar a un watcher de W o desactivarlo cierra sus streams en < 1 s.

## Rutas

`quién`: `anon` = sin credencial; `owner`; `watcher`; `any` = owner o watcher; `machine`; `operator`. Estado: **hoy** =
implementada en `apps/backend/src`; **reservada** = contrato fijado (schema y fixture), hoy responde `404`.

### Salud y operador

| método y ruta | quién | cuerpo | respuesta | errores | estado |
|---|---|---|---|---|---|
| `GET /health` | anon | — | `200 {ok: true, version}` | — | hoy |
| `POST /v1/operator/bootstrap` | operator | `{email}` | `201 {invitation, link}` | 400, 401, 409 (ya hay dueño), 429, 503 | hoy |
| `POST /v1/operator/recover` | operator | `{}` | `201 {invitation, link}` | 401, 409 (no hay dueño), 429, 503 | hoy |

### Auth

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `POST /v1/auth/login` | anon | `{email, password, device_name, client}` | `200` (ver «Login») | 400, 401, 429 |
| `POST /v1/auth/logout` | any | — | `204` (web: además borra la cookie) | 401 |
| `GET /v1/auth/me` | any | — | `200 {user, session, csrf_token?}` (`csrf_token` nuevo solo en web) | 401 |
| `POST /v1/auth/password` | any | `{current_password, new_password}` | `204`; revoca las demás sesiones | 400, 401, 429 |
| `POST /v1/auth/recover` | anon | `{email, recovery_code, new_password}` | `200 {recovery_code}` (nuevo) | 400, 401, 429 |
| `POST /v1/auth/recovery-code` | owner | `{password}` | `200 {recovery_code}` | 401, 403, 429 |

`client` ∈ `mac | web | cli`. `user` = `{id, email, display_name, role, status, created_at}`.

### Invitaciones

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/invitations` | owner | — | `200 {invitations: [Invitation]}` (pendientes y últimas 50 usadas/revocadas) | 401, 403 |
| `POST /v1/invitations` | owner | `{email, workspace_ids, ttl_h?}` | `201 {invitation, link}` | 400, 404, 409 |
| `POST /v1/invitations/{id}/reissue` | owner | `{ttl_h?}` | `200 {invitation, link}` (el token anterior deja de valer) | 404, 410 |
| `DELETE /v1/invitations/{id}` | owner | — | `204` | 404 |
| `POST /v1/invitations/inspect` | anon | `{token}` | `200 {email, kind, role, expires_at, workspaces: [{id, name}]}` | 401, 410, 429 |
| `POST /v1/invitations/accept` | anon | `{token, password, display_name?, device_name, client}` | `201` como el login + `recovery_code` en `owner_*` | 400, 401, 409, 410, 429 |

`Invitation` = `{id, email, kind, role, workspace_ids, created_at, expires_at, used_at, revoked_at, status}`, `kind` ∈
`owner_bootstrap | owner_reset | watcher`, `status` ∈ `pending | used | revoked | expired`; nunca lleva el token ni su hash.
`link` = `https://chopshop.novarix.online/invite#t=ci1_…`: el token va en el fragmento, que el navegador no envía al servidor;
solo se muestra en la respuesta que lo crea. `ttl_h` de 1 a 720 (168 por defecto). No se envían correos: el dueño copia el
enlace.

### Usuarios y sesiones

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/users` | owner | — | `200 {users: [User & {workspace_ids, last_login_at, sessions_active}]}` | 403 |
| `GET /v1/users/{id}` | owner | — | `200 {user}` | 404 |
| `PATCH /v1/users/{id}` | owner | `{status?, display_name?}` | `200 {user}` | 400, 404, 409 (sobre el dueño) |
| `GET /v1/sessions` | any | query `user_id?` (solo filtra para el dueño) | `200 {sessions: [Session]}` (watcher: solo las suyas) | 401 |
| `DELETE /v1/sessions/{id}` | any | — | `204` | 404 (también la de otro usuario, para un watcher) |

`Session` = `{id, user_id, client, device_name, user_agent, created_at, last_seen_at, expires_at, current}`; nunca el token.
Desactivar un usuario (`status: "disabled"`, solo watchers) revoca todas sus sesiones y cierra sus streams; volver a `active` no
las restaura y las membresías se conservan.

### Máquinas (solo dueño)

| método y ruta | cuerpo | respuesta | errores |
|---|---|---|---|
| `GET /v1/machines` | — | `200 {machines: [Machine]}` (las revocadas, 30 días) | 403 |
| `POST /v1/machines/link` | `{local_machine_id, name, platform, workspace_ids?}` | `201 {machine, credential, api_url}`; revoca la activa con el mismo `local_machine_id` | 400, 404 |
| `POST /v1/machines` | `{name, platform, workspace_ids?}` | `201 {machine, credential, api_url}` (token para VPS, `local_machine_id: null`) | 400, 404 |
| `GET /v1/machines/{id}` | — | `200 {machine}` | 404 |
| `PATCH /v1/machines/{id}` | `{name}` | `200 {machine}` | 400, 404 |
| `POST /v1/machines/{id}/pause` | — | `200 {machine}`: corta el WebSocket (4403) y rechaza reconexiones | 404, 410 |
| `POST /v1/machines/{id}/resume` | — | `200 {machine}` | 404, 410 |
| `POST /v1/machines/{id}/revoke` | — | `204`, irreversible: cierra el WebSocket (4401) | 404 |

`Machine` = `{id, name, platform, local_machine_id, linked_via, agent_version, workspace_ids, created_at, last_seen_at,
paused_at, revoked_at, online}`; `platform` ∈ `macos | linux | other`, `linked_via` ∈ `app | token`. `credential` (`cm1_…`) solo
aparece en la respuesta que la crea. Sin `workspace_ids`, la máquina entra en todos los workspaces no archivados.

### Workspaces = campus

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/workspaces` | any | — | `200 {workspaces: [Workspace]}` (watcher: los compartidos) | 401 |
| `POST /v1/workspaces` | owner | `{name, slug?, position?, style?}` | `201 {workspace}` (con campus vacío) | 400, 409 (slug) |
| `GET /v1/workspaces/{id}` | any | — | `200 {workspace}` | 404 |
| `PATCH /v1/workspaces/{id}` | owner | `{rev, name?, slug?, position?, style?}` | `200 {workspace}` | 400, 404, 409 |
| `DELETE /v1/workspaces/{id}` | owner | — | `204` (archiva) | 404, 409 (tiene proyectos no archivados) |
| `GET /v1/workspaces/{id}/campus` | any | — | `200 {layout, rev}` | 404 |
| `PUT /v1/workspaces/{id}/campus` | owner | `{layout, rev}` | `200 {layout, rev}` | 400, 404, 409 |
| `GET /v1/workspaces/{id}/watchers` | owner | — | `200 {watchers: [User]}` | 404 |
| `PUT /v1/workspaces/{id}/watchers/{user_id}` | owner | — | `204` (comparte; idempotente) | 404 |
| `DELETE /v1/workspaces/{id}/watchers/{user_id}` | owner | — | `204` (deja de compartir; cierra sus streams) | 404 |
| `PUT /v1/workspaces/{id}/machines/{machine_id}` | owner | — | `204` | 404 |
| `DELETE /v1/workspaces/{id}/machines/{machine_id}` | owner | — | `204` | 404, 409 (hay proyectos del workspace en esa máquina) |

`Workspace` = `{id, name, slug, position, style, rev, project_count, machine_ids, watcher_count?, created_at, updated_at}`;
`machine_ids` y `watcher_count` solo para el dueño. Cada usuario ve como **ciudad** la unión de los campus a los que tiene
acceso (el dueño, todos). Por ahora el único rol de miembro es `watcher` (solo lectura).

### Proyectos, layouts y roles

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/workspaces/{id}/projects` | any | — | `200 {projects: [Project]}` | 404 |
| `POST /v1/workspaces/{id}/projects` | owner | `{name, title?, t3_project?, repo?, machine_id?, runtime_mode?, model?, settings?}` | `201 {project}` | 400, 404, 409 (nombre) |
| `GET /v1/projects/{id}` | any | — | `200 {project}` | 404 |
| `PATCH /v1/projects/{id}` | owner | `{rev, …mismos campos, workspace_id?, disabled?}` | `200 {project}` | 400, 404, 409 |
| `DELETE /v1/projects/{id}` | owner | — | `204` (archiva) | 404 |
| `GET /v1/projects/{id}/layout` | any | — | `200 {layout, rev}` | 404 |
| `PUT /v1/projects/{id}/layout` | owner | `{layout, rev}` | `200 {layout, rev}` | 400, 404, 409 |
| `GET /v1/projects/{id}/roles` | any | — | `200 {roles: [Role]}` (watcher: sin `prompt`, `match_rules`, `wake`, `settings`) | 404 |
| `POST /v1/projects/{id}/roles` | owner | `{name, prompt?, model?, match_rules?, wake?, settings?, position?}` | `201 {role}` | 400, 404, 409 |
| `PATCH /v1/roles/{id}` | owner | `{rev, …}` | `200 {role}` | 400, 404, 409 |
| `DELETE /v1/roles/{id}` | owner | — | `204` | 404, 409 (el layout aún tiene salas de ese rol) |

`machine_id` de un proyecto debe estar en las máquinas de su workspace (si no, `400` con `field: "machine_id"`). `layout` y
`settings` se validan solo en forma (objeto JSON ≤ 256 KiB; claves de primer nivel de `layout`: `floors`, `half_life`,
`capacity`, `machine_rooms`); la validación semántica la hace el agente y vuelve en `sync.ack`, visible como
`projects[].sync_errors` en `GET /v1/state`.

**Concurrencia optimista**: toda entidad editable lleva `rev`. Un `PATCH`/`PUT` manda el `rev` que leyó; si otro lo cambió antes
→ `409 conflict` con `current` = el recurso actual. **Escrituras de estructura** (todas las de workspaces, campus, proyectos,
layouts, roles, máquinas de un workspace e importaciones): suben `structure_rev` en el mismo batch de D1, el Hub manda un `sync`
nuevo a las máquinas afectadas y un evento SSE `structure {rev}` a los visores.

### Importación de la configuración local (reservada, H3)

| método y ruta | quién | cuerpo | respuesta | errores |
|---|---|---|---|---|
| `GET /v1/imports` | owner | — | `200 {imports: [{id, machine_id, created_at, summary, applied_at, dismissed_at}]}` | 403 |
| `GET /v1/imports/{id}` | owner | — | `200 {import, projects: [ImportProject]}` | 404 |
| `POST /v1/imports/{id}/apply` | owner | `{projects: [{name, workspace_id?, workspace_name?}]}` | `200 {created: [Project], skipped: [{name, reason}]}` | 400, 404, 409 |
| `DELETE /v1/imports/{id}` | owner | — | `204` (descarta) | 404 |

Sin `workspace_id`, cada proyecto va al workspace llamado `workspace_name` o, en su defecto, `company` del perfil (se crea si no
existe): cada empresa del perfil local pasa a ser su campus. Un nombre ya existente → `skipped` `name_taken`.

### Estado, stream, agente, comandos y auditoría

| método y ruta | quién | cuerpo | respuesta | errores | estado |
|---|---|---|---|---|---|
| `GET /v1/state` | any | query `workspace?` | `200 State` (ver «Ciudad») | 401, 404 | hoy |
| `GET /v1/stream` | any | query `workspace?`, cabecera `Last-Event-ID?` | SSE | 401, 404, 429 | hoy |
| `GET /v1/connect` | machine | upgrade WebSocket | `101` ([`relay-protocol.md`](relay-protocol.md)) | 401, 403, 409, 426 | hoy |
| `POST /v1/commands` | owner | `{machine_id, name, args}` | `200 {command_id, ok, status, body}` | 400, 403, 404, 409, 504 | reservada (C1) |
| `GET /v1/audit` | owner | query `limit≤200`, `before?`, `machine_id?`, `action?` | `200 {entries: [AuditEntry]}` | 403 | reservada (C1) |

Las colas en la nube (`/v1/projects/{id}/tasks`, `/v1/tasks/{id}`) están reservadas para la fase S2 y responden `404`.

## Ciudad: `GET /v1/state` y `GET /v1/stream`

`GET /v1/state` responde la ciudad del principal: el dueño, todo; un watcher, sus workspaces compartidos. Con
`?workspace=<id>` se limita a ese campus (`404` si no es visible).

```json
{
  "v": 2, "type": "state", "id": "<ULID>", "ts": "…", "rev": 42, "head": "<época>-<n>",
  "user": {"id": "…", "role": "owner"},
  "city": {"workspaces": [{"id": "…", "name": "Awesome GB", "slug": "awesome-gb", "position": 0, "style": {},
    "campus": {"layout": {}, "rev": 3},
    "projects": [{"id": "…", "name": "awesome-gb", "title": null, "machine_id": "…", "disabled": false,
                  "layout": {}, "roles": ["triage"], "sync_errors": []}],
    "machine_ids": ["…"]}]},
  "machines": [{"id": "…", "name": "mac-mini", "platform": "macos", "online": true, "paused": false, "stale": false,
                "seq": 10, "snapshot_age_s": 4, "expires_at": "…"}],
  "snapshots": [{"…snapshot v2 tal cual lo mandó el agente…": "", "workspace_id": "…"}]
}
```

- Watcher: `machines[]` solo con las máquinas de sus workspaces y solo `{id, name, online, stale}`; `snapshots[]` solo de sus
  workspaces y nunca con `workspace_id: null`.
- `GET /v1/stream` (SSE): `retry: 3000`, `event: hello` con `{v: 2, type: "hello", ts, head, resume, rev}`; luego `snapshot` y
  `event` (frames del agente tal cual), `machine` (`{id, online, paused}`), `structure` (`{rev}`: releer `GET /v1/state`) y
  `error` (con `close: true` si la sesión se revoca o cambia la vista). Reanuda con `Last-Event-ID` de la misma época (búfer de
  512 frames o 5 min; si no, `resume: "snapshot"`), latido `: ping` cada 15 s, máx. 64 visores (429 con `Retry-After: 3`).

## Comandos

Solo el dueño, por `POST /v1/commands` (reservada, C1). Doble verificación: el Worker (sesión de dueño, `name` del catálogo,
máquina existente, no revocada ni pausada, auditoría) y el Hub (dueño, máquina conectada y no pausada); espera `cmd.result` hasta
30 s (`504 timeout`). Catálogo:

| `name` | ruta local del agente | tipo |
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

Los watchers no tienen canal de comandos.

## Flujos

- **Login** (`POST /v1/auth/login`): primero los límites de intentos (si hay bloqueo, `429` sin calcular PBKDF2); busca el
  correo normalizado y verifica la contraseña (con un hash ficticio si el correo no existe); correo inexistente, contraseña mala o
  usuario desactivado dan **el mismo** `401` «correo o contraseña incorrectos». Éxito: borra el contador `ei:`, rehace el hash si
  hace falta y crea la sesión.
  - `mac`/`cli`: `200 {user, session: {id, client, expires_at}, token: "ss1_…"}`.
  - `web`: `200 {user, session, csrf_token: "cx1_…"}` + `Set-Cookie: __Host-chopshop_session=ss1_…; Path=/; Secure; HttpOnly;
    SameSite=Strict; Max-Age=<absoluta>`; el cuerpo **no** lleva el token.
- **Aceptar invitación**: `inspect` para mostrar a quién invita y `accept` para fijar la contraseña. `watcher`: crea el usuario y
  sus membresías. `owner_bootstrap`: crea el dueño (409 si ya hay uno), el workspace `Personal` y el código de recuperación.
  `owner_reset`: nueva contraseña del dueño, revoca todas sus sesiones y código de recuperación nuevo. Responde como el login
  más `recovery_code` en los dos `owner_*` (se muestra una sola vez).
- **Cambio de contraseña**: verifica la actual (cuenta como intento en `ei:`), aplica la política, revoca **las demás**
  sesiones y cierra sus streams.
- **Recuperación del dueño**: con el código (`POST /v1/auth/recover`, sin sesión) o, si también se perdió, con el operador
  (`POST /v1/operator/recover` → invitación `owner_reset` de 1 h). Ver [`relay.md`](relay.md#recuperación-del-dueño).
- **Logout / revocar sesión**: marca la sesión revocada y el Hub cierra sus streams en la misma petición.

## Contraseñas, tokens y límites

Todo cabe en el plan **Workers Free** (10 ms de CPU por petición HTTP); nada depende de Workers Paid.

- **Hash** (`src/crypto.ts`): `HMAC-SHA256(PASSWORD_PEPPER, contraseña NFC)` y sobre eso PBKDF2-SHA256 con **10 000
  iteraciones** (`PBKDF2_ITERATIONS`, ≈ 3 ms de CPU medidos con `apps/backend/scripts/measure-pbkdf2.mjs`), sal de 16 bytes y 32
  bytes de salida. Formato en `users.password_hash`: `pbkdf2-sha256-p<versión del pepper>$<iteraciones>$<sal>$<hash>` (base64url).
  El formato viejo sin pepper (`pbkdf2-sha256$…`) se sigue verificando; se aceptan de 1 a 100 000 iteraciones. Un login correcto
  con un hash que no tiene el esquema, el pepper o las iteraciones vigentes lo rehace (`needsRehash`).
- **Solo derivan PBKDF2** las rutas que reciben una contraseña: login, `invitations/accept`, `auth/password`, `auth/recover` y
  `auth/recovery-code`; como mucho dos derivaciones por petición. Sesiones, credenciales de máquina, invitaciones, CSRF, operador
  y código de recuperación usan solo `sha256`.
- **Pepper**: secret del Worker `PASSWORD_PEPPER` (≥ 32 caracteres), nunca en D1, en el repo ni en `[vars]`; versión en la var
  `PASSWORD_PEPPER_VERSION` (`1` por defecto); el valor anterior de una rotación va en `PASSWORD_PEPPER_V<n>`. Sin pepper válido,
  las rutas de contraseña responden `503 internal`.
- **Política**: 12 a 256 caracteres tras NFC, distinta del correo y sin contener su parte local (si tiene ≥ 4 caracteres); sin
  reglas de composición. Error: `400` con `field: "password"`.
- **Correo**: `trim`, NFC y minúsculas; `^[^@\s]+@[^@\s]+\.[^@\s]+$`, máx. 254.
- **Secretos** (32 bytes aleatorios en base64url = 43 caracteres; en D1 solo su `sha256` hex; se devuelven una única vez):

| secreto | formato | quién lo tiene |
|---|---|---|
| sesión | `ss1_<43>` | app Mac (Keychain), CLI; la web solo como cookie HttpOnly |
| credencial de máquina | `cm1_<43>` | agente (`machine.json`, 0600) |
| invitación | `ci1_<43>` | el enlace de invitación (fragmento `#t=`) |
| CSRF (web) | `cx1_<43>` | memoria de la web |
| código de recuperación | `XXXXX-XXXXX-XXXXX-XXXXX` (20 símbolos Crockford, 100 bits; se normaliza sin guiones, mayúsculas, `O→0`, `I/L→1`) | el dueño, fuera de línea |
| secret de operador | `RELAY_OPERATOR_TOKEN` | secret del Worker y del repo; nunca en D1 |

- **Sesiones** con expiración deslizante: `mac`/`cli` 30 días de inactividad y 90 de máximo; `web` 12 h y 7 días. Cada petición
  válida renueva (`last_seen_at` como mucho cada 5 min). Caducada o revocada → `401`; no hay refresh token: la app vuelve al
  login.
- **Límites de intentos** (`src/ratelimit.ts`, tabla `auth_attempts`, claves `sha256` sin correos ni IPs en claro; se consultan
  **antes** de derivar; IP = `CF-Connecting-IP`):

| clave | rutas | umbral | bloqueo |
|---|---|---|---|
| `ei:` correo + IP | login, password | 5 fallos en 15 min | 2^(fallos−5) min, máx. 60; un login correcto la borra |
| `e:` correo | login, recover | 20 fallos en 1 h | 15 min (todas las IPs) |
| `ip:` IP | login, recover, invitaciones | 100 fallos en 1 h | 60 min |
| `rc:` IP | `POST /v1/auth/recover` | 5 fallos en 1 h | 60 min |
| `inv:` IP | `inspect`/`accept` | 10 fallos en 1 min | 5 min |
| `op:` IP | `/v1/operator/*` | 5 fallos en 10 min | 60 min |

  Bloqueado → `429 rate_limited` con `retry_after_s`, `Retry-After` y el mensaje fijo «demasiados intentos; vuelve a intentarlo
  más tarde».

## Web: CORS, CSRF y cabeceras

- La web y la API son el mismo sitio (`novarix.online`) y distinto origen. La cookie `__Host-chopshop_session` es del host de la
  API, sin `Domain`.
- **CORS** solo si `Origin` es exactamente `https://chopshop.novarix.online`: `Access-Control-Allow-Origin` con ese valor,
  `Access-Control-Allow-Credentials: true`, `Vary: Origin`, métodos `GET, POST, PUT, PATCH, DELETE`, cabeceras
  `Content-Type, X-CSRF-Token`, `Max-Age: 600`. Otro `Origin` → sin cabeceras CORS. App, CLI y agente no mandan `Origin`.
- **CSRF**: una petición autenticada por cookie con método distinto de `GET`/`HEAD` exige `Origin` = la web y
  `X-CSRF-Token: cx1_…` cuyo `sha256` coincida con el de la sesión; si no, `403`. Con `Bearer` no hay CSRF. Cookie y `Bearer` a
  la vez → `400`.
- **Cabeceras** en todas las respuestas: `Strict-Transport-Security: max-age=31536000; includeSubDomains`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`; en la web, además
  `Content-Security-Policy: default-src 'self'; connect-src 'self' https://api.chopshop.novarix.online; img-src 'self' data:;
  style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`.

## Qué no se registra

Ni en logs, ni en auditoría, ni en mensajes de error: contraseñas, tokens (`ss1_`, `cm1_`, `ci1_`, `cx1_`), el secret de
operador, códigos de recuperación, enlaces de invitación, cabeceras `Authorization` y `Cookie`, cuerpos de `/v1/auth/*`,
`/v1/invitations/*` y `/v1/operator/*`, prompts, partes opacas, `args` y `body` de comandos, IPs en claro. Sí: método, ruta sin
query, estado, duración, `user_id`, `machine_id` y `code` de error.

La auditoría (`audit_log` en D1) registra `auth.*`, `session.revoked`, `user.*`, `invitation.*`, `operator.bootstrap`,
`operator.recover`, `machine.*`, `workspace.shared`/`unshared`, `import.applied` y `command`, con `detail` sin secretos,
contraseñas, prompts ni IPs.
