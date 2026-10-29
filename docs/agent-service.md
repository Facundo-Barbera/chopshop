# chopshop-agent como servicio `systemd --user`

Guía para instalar, probar y operar el agente en una máquina Linux. Contrato de la API: [`agent-api.md`](agent-api.md);
diseño: [`agent-architecture.md`](agent-architecture.md). Todos los nombres de máquina, IPs y usuarios de esta guía son ejemplos
(`host-a`, `100.64.0.10`, `usuario@github`): pon los tuyos **solo** en tu `~/.config/chopshop/config.toml`, que no se versiona.

> **Nada se habilita ni se arranca solo.** Ni el instalador ni el agente ejecutan `systemctl enable`, `loginctl enable-linger` ni
> `start`. Primero se prueba a mano (`start` / `stop`); habilitarlo para que arranque con tu sesión es una decisión tuya, al final.

## Qué hace el servicio

Un proceso Python (solo stdlib, >= 3.9) con: API HTTP (`/health`, `/snapshot`, `/metrics`, `/events`, `/threads`, `/answer`,
`/settle`, `/subscriptions`), muestreo de CPU/RAM/disco por app y proyecto desde `/proc` (solo lectura), vigilancia de los hilos de T3,
eventos y webhooks y, opcional, ingreso de GitHub por polling (ver [más abajo](#ingreso-de-github-agentgithub)). La base de datos es SQLite (WAL) en `agent.db_path`.

Es una capa delgada sobre T3: **no** lanza servidores de prueba, no reparte puertos, no barre procesos ni ejecuta comandos. Todo eso
(worktrees, servidores, comandos de cada hilo) lo gestiona T3; el agente solo observa, resume y, por `answer`/`settle`, habla con T3.

## Instalación paso a paso

1. **Clonar el repo** en la máquina:

   ```sh
   git clone https://github.com/Facundo-Barbera/chopshop.git ~/projects/chopshop
   cd ~/projects/chopshop
   ```

   Opcional: un enlace `~/.local/bin/chopshop` → `apps/agent/bin/chopshop` (el instalador usa la ruta del repo si no lo hay).

2. **Configuración local**: copia la plantilla y edítala (el archivo real no se versiona):

   ```sh
   mkdir -p ~/.config/chopshop
   cp config.example.toml ~/.config/chopshop/config.toml
   $EDITOR ~/.config/chopshop/config.toml
   ```

   Lo mínimo en `[agent]` (el resto tiene valores por defecto razonables; cualquier clave también se puede dar por entorno,
   p. ej. `CHOPSHOP_AGENT__PORT=3791`):

   | Clave | Para qué |
   |---|---|
   | `machine_id` | nombre de la máquina en la API (vacío = hostname) |
   | `bind`, `port` | dónde escucha. **`127.0.0.1` por defecto** (solo local). Para otras máquinas: `"auto"` (IP de Tailscale) o la IP concreta, p. ej. `"100.64.0.10"`. `0.0.0.0` y `::` se rechazan |
   | `auth`, `owner_login`, `allowed_logins`, `token_file` | ver [Autenticación](#autenticación) |
   | `t3.*`, `t3_enabled` | cómo hablar con T3 de esta máquina (`false` = máquina solo sensor): `t3.origin` (vacío = se lee de `~/.t3/userdata/server-runtime.json`), `t3.access`, `t3.t3_bin` (CLI que emite el pairing local) y `t3.credential_file`. El cliente MCP nativo se autentica solo por pairing local (OAuth+PKCE) y cachea el token en `<CHOPSHOP_HOME>/t3-credential.json` (0600); sin helper node ni `fleet` |
   | `projects.<p>.root`, `worktrees` | dónde vive cada proyecto, para atribuirle métricas e hilos (opcional: por defecto `projects_root`/`worktrees_root`) |
   | `webhook_files.<nombre>` | **ruta** a un archivo 0600 que contiene la URL del webhook (la URL nunca va en la config) |

   Valida:

   ```sh
   apps/agent/bin/chopshop agent check-config
   ```

   Muestra errores (exit 1) y avisos: token flojo de permisos, `owner_login` que parece un marcador, `agent.t3` sin `t3_bin` ni `origin`, claves viejas (`helper`, `node`) que ya no se usan, etc.

3. **Token** (bearer para escrituras remotas y para el modo `token`). Se crea con permisos 0600 y **no se imprime**:

   ```sh
   apps/agent/bin/chopshop agent token            # crea el archivo si falta; --rotate genera uno nuevo
   ```

   Para dárselo a otra máquina cliente, copia el archivo (`scp`/`ssh host-a 'cat <token_file>' > <su token_file>` con `chmod 600`);
   la app lo lee de `[app] token_file`.

4. **Ver la unidad** que se instalaría (solo imprime; no escribe nada):

   ```sh
   apps/agent/bin/chopshop agent print-unit
   ```

   Se renderiza desde [`systemd/chopshop-agent.service`](../systemd/chopshop-agent.service) con las rutas de tu entorno
   (ejecutable, `PATH`, carpetas de escritura; lo que cuelga de tu home sale como `%h`). Opciones: `--exec RUTA`, `--rw CARPETA`
   (repetible; también `[agent.service] read_write_paths` en la config). Endurecimiento incluido: `NoNewPrivileges`, `PrivateTmp`,
   `ProtectSystem=strict` con `ReadWritePaths` (db, `general.home`, extras), `Nice=10`, `CPUQuota=30%`, `MemoryHigh/Max`,
   `Slice=chopshop.slice`, `Restart=on-failure`.

   Con el T3 local (`agent.t3.origin` vacío) la unidad añade sola a `ReadWritePaths` la carpeta de datos de T3 (`$T3CODE_HOME` o `~/.t3`):
   el agente emite el pairing ejecutando `t3 auth pairing create` y ese CLI escribe ahí. Los topes de memoria (`MemoryHigh=1G`,
   `MemoryMax=1500M`) dejan sitio a ese CLI (~300-500 MB); con topes menores queda en estado D y el `stop` de la unidad hace timeout.

   Para verificarla sin arrancar nada (si tienes `systemd-analyze`):

   ```sh
   apps/agent/bin/chopshop agent print-unit > /tmp/chopshop-agent.service
   systemd-analyze --user verify /tmp/chopshop-agent.service
   ```

5. **Instalar la unidad (sin enable ni start)**. El instalador solo la copia a `~/.config/systemd/user/` y hace `daemon-reload`:

   ```sh
   scripts/install-user-unit.sh --dry-run     # muestra destino y unidad renderizada; no escribe nada
   scripts/install-user-unit.sh               # copia + systemctl --user daemon-reload
   ```

   Si ya hay una unidad distinta, muestra el diff y se detiene; `--force` la reemplaza. Otras opciones: `--chopshop RUTA`,
   `--dest DIR`, `--no-reload`, y tras `--` argumentos para `print-unit` (p. ej. `-- --rw /srv/datos`).

6. **Probarlo a mano**:

   ```sh
   systemctl --user start chopshop-agent
   systemctl --user status chopshop-agent
   journalctl --user -u chopshop-agent -f          # logs (nunca contienen tokens ni URLs de webhook)
   apps/agent/bin/chopshop agent status            # resumen: versión, T3, última muestra/sondeo, hilos, estado de la unidad
   systemctl --user stop chopshop-agent
   ```

   La parada es limpia (SIGTERM): se cierran los sockets, se esperan los hilos y se vacía la cola de webhooks.

7. **Probar la API con `curl`**. Desde la propia máquina (origen local, sin token):

   ```sh
   curl -s http://127.0.0.1:3790/health
   curl -s http://127.0.0.1:3790/snapshot | python3 -m json.tool | head -40
   ```

   Desde otra máquina de tu tailnet contra `host-a` (IP de ejemplo; identidad Tailscale **y** una credencial en toda petición
   salvo `/health`: la de un dispositivo emparejado o el bearer legado del paso 3):

   ```sh
   # en host-a:            chopshop pair create --name "portátil"     -> código de un solo uso, p. ej. K7QM-93XD (10 min)
   # en la otra máquina:   canjearlo una vez y guardar la credencial cs1_… (la app de Mac lo hace sola y la guarda en el Keychain)
   curl -s -X POST http://100.64.0.10:3790/pair -H 'Content-Type: application/json' \
        -d '{"code": "K7QM-93XD", "device_name": "portátil"}'
   TOKEN="cs1_..."                             # o el bearer legado: "$(cat ~/.chopshop/agent/token)"
   curl -s -H "Authorization: Bearer $TOKEN" http://100.64.0.10:3790/snapshot | head -c 300
   curl -sN -H "Authorization: Bearer $TOKEN" http://100.64.0.10:3790/stream      # eventos en vivo (SSE)
   curl -s -X POST http://100.64.0.10:3790/settle \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"thread_id": "<id del hilo>"}'
   ```

8. **(Opcional, decisión tuya) arranque automático**. Solo cuando ya lo hayas probado y lo quieras:

   ```sh
   systemctl --user enable chopshop-agent            # arranca con tu sesión de usuario
   loginctl enable-linger "$USER"                    # además, sin sesión abierta (solo si lo necesitas)
   ```

   Para deshacerlo: `systemctl --user disable chopshop-agent` y `loginctl disable-linger "$USER"`.

## Autenticación

`agent.auth` (por defecto el más seguro, `tailscale+token`):

| Modo | Quién entra |
|---|---|
| `tailscale+token` | identidad de Tailscale (`tailscale whois --json <ip>`, cache 60 s): `owner_login` lee y escribe, `allowed_logins` solo leen. **Toda petición (salvo `GET /health` y `POST /pair`) exige además una credencial**: la de un dispositivo emparejado (`chopshop pair create|list|revoke|prune`, ver docs/agent-api.md) o el bearer legado. |
| `token` | solo el bearer, en toda petición. Para clientes sin identidad Tailscale o si no usas Tailscale |
| `none-local` | nadie por red; solo el origen local |

El **origen local** (misma máquina: CLI, `curl` a `127.0.0.1`) se acepta siempre mientras `trust_local = true`; ponlo en `false`
si en la máquina hay otros usuarios en los que no confíes. Los logins se escriben completos, como los muestra `tailscale whois`
(el `usuario@` de `config.example.toml` es un marcador). Para `whois` el usuario del servicio debe poder hablar con `tailscaled`
(`sudo tailscale set --operator=$USER`). Si `bind` no es loopback, el agente abre además `127.0.0.1:<port>` (`local_listener`).

El agente **no ejecuta comandos que le pida un cliente**: no hay ninguna ruta que lance procesos (el único proceso propio,
con `[agent.github] enabled`, es `gh api` de solo lectura con argumentos fijos); las únicas escrituras son
`answer`/`settle` en T3 y las suscripciones de webhooks.

## Ingreso de GitHub (`[agent.github]`)

Hilo `github` opcional (`enabled = false` por defecto: sin él no se crea el hilo) que convierte la actividad de los repos de
`repos` en eventos `github.*` por **polling con ETag**. No abre puertos ni recibe webhooks: llama al `gh` ya autenticado de la
máquina (`gh auth login` una vez, como el usuario del servicio) con `gh api -i`. El agente **nunca** lee, pasa ni imprime el token.

```toml
[agent.github]
enabled = true
repos = ["dueño/repo"]
interval_s = 45        # GitHub puede pedir más con X-Poll-Interval; se respeta
gh_bin = "gh"
ci = true              # check-runs del HEAD de los PRs abiertos
```

Cada pasada, por repo:

- `GET /repos/{o}/{r}/events` con `If-None-Match` (un 304 no gasta cuota y no emite). Cursor en la tabla `meta` de la DB:
  `gh_etag:<repo>` y `gh_last_event_id:<repo>`; solo se emiten eventos con id mayor que el cursor, así que reiniciar el agente
  no repite nada. **La primera pasada siembra los cursores sin emitir.**
- Con `ci = true`: `GET /repos/{o}/{r}/pulls?state=open` y `GET /repos/{o}/{r}/commits/<HEAD>/check-runs` de cada PR abierto
  (hasta 30), también con ETag. Estado en `meta` `gh_ci:<repo>`. Se emite `github.ci.completed` cuando el agregado de los
  check-runs de un HEAD pasa a `success` o `failure` (`pending` no emite; un HEAD nuevo vuelve a empezar).

| GitHub | Evento |
|---|---|
| `IssuesEvent` `opened` / `closed` / otro (`reopened`, `labeled`...) | `github.issue.opened` / `github.issue.closed` / `github.issue.updated` |
| `PullRequestEvent` `opened` / `closed` con merge / otro (`synchronize`, `closed` sin merge...) | `github.pr.opened` / `github.pr.merged` / `github.pr.updated` |
| `PullRequestReviewEvent` | `github.pr.review` (`review` = `approved`, `changes_requested`, `commented`) |
| `PushEvent` | `github.push` (`head` = rama, `sha`, `commits`) |
| check-runs del HEAD de un PR abierto | `github.ci.completed` (`ci` = `success` \| `failure`) |

Cuerpo común: `{repo, number, title, url, actor, action, labels, head, base, state, ci, etag_source}` (+ `text` truncado a 2 KB
con el cuerpo del issue/PR/revisión, `review`, `sha`, `commits` según el tipo). Solo metadatos; a todo texto se le quitan
patrones de credenciales (`ghp_…`, `github_pat_…`, `Authorization: …`, `usuario:clave@` en URLs). El resto de tipos de GitHub
(`WatchEvent`, comentarios...) no se publican. `repo` va normalizado en minúsculas (`dueño/repo`).

**Proyecto**: se resuelve por repo, primero con `repo:` de los perfiles (`~/.chopshop/profiles/<proyecto>.yaml`) y si no con
`repo = "dueño/repo"` en `[agent.projects.<proyecto>]` (vale también una URL de GitHub https o ssh). Sin coincidencia, `project` es nulo.

**Errores**: un 403 por cuota (`X-RateLimit-Remaining: 0`), un 429, un 5xx o un `gh` que no responde paran la pasada y aplican
backoff exponencial desde `interval_s` (tope 15 min; respeta `Retry-After` y `X-RateLimit-Reset`). Se emite **un solo**
`machine.health` con `{"state":"degraded","source":"github","reason":"rate_limit|forbidden|server_error|gh|http"}` y otro con
`"state":"ok"` y `down_seconds` al recuperarse; el hilo nunca muere. Un repo inexistente o sin acceso (404) solo deja un aviso
en el log y no degrada. Los logs llevan repo, código HTTP y motivo; nunca la salida de error de `gh`.

`chopshop agent check-config` valida `repos` e `interval_s` y avisa si no encuentra `gh_bin`. Con la unidad systemd
(`ProtectSystem=strict`) `gh` lee su config de `~/.config/gh` sin problema; si tu `gh` necesita escribir su estado
(`~/.local/state/gh`), añádelo con `--rw` o `[agent.service] read_write_paths`.

## Troubleshooting

| Síntoma | Causa y arreglo |
|---|---|
| `chopshop agent check-config` dice `bind = "auto" pero no pude obtener la IP de Tailscale` | `tailscaled` no está activo o `tailscale_bin` no es el correcto. Arráncalo o pon la IP en `agent.bind` |
| La unidad falla al arrancar y reintenta cada 10 s | `journalctl --user -u chopshop-agent -n 50`. Típico: puerto ocupado, `bind` inválido o IP de Tailscale aún sin levantar al iniciar sesión (reintenta solo) |
| `403 sin identidad válida` desde otra máquina | `owner_login`/`allowed_logins` no coincide con el login real (`tailscale whois 100.64.0.x`), o `tailscale whois` no responde (falta `tailscale set --operator`). Con `auth = "token"` falta el bearer |
| `401 falta una credencial válida` | empareja el dispositivo (`chopshop pair create` en el agente + `POST /pair`) o usa `Authorization: Bearer $(cat token)` con el mismo archivo del agente; si el dispositivo fue revocado, vuelve a emparejarlo |
| `403 Host no reconocido` / `cabecera Origin` / `Content-Type` | conecta por IP o por `machine_id`/hostname (o añade el nombre a `agent.allowed_hosts`); no llames al agente desde un navegador; las escrituras van con `Content-Type: application/json` |
| `403 esta identidad es de solo lectura` | el login está en `allowed_logins`; solo `owner_login` escribe |
| `agent.t3_ok` es `false` / evento `t3_unreachable` | revisa `agent.t3.t3_bin` / `origin`, la credencial cacheada en `<CHOPSHOP_HOME>/t3-credential.json` (bórrala para forzar un pairing nuevo) y que T3 esté arriba; el agente reintenta con backoff (10 s → 5 min) y avisa `t3_recovered` |
| `503 T3 desactivado` | `agent.t3_enabled = false` en esa máquina |
| `404 ruta desconocida` | la ruta no existe en esta versión (ver [`agent-api.md`](agent-api.md)); servidores de prueba y puertos los gestiona T3 |
| El agente no puede escribir en alguna carpeta | `ProtectSystem=strict` deja todo en solo lectura salvo `ReadWritePaths`: añade `--rw` en `print-unit` o `[agent.service] read_write_paths` y reinstala |
| `MemoryMax`/`CPUQuota` no se aplican | el gestor de usuario no tiene esos controladores delegados; la unidad funciona igual, solo sin topes |
| Cambié la config | `systemctl --user restart chopshop-agent` (la config se lee al arrancar) |
| Cambié la plantilla de la unidad | `scripts/install-user-unit.sh --force` y `systemctl --user daemon-reload` (ya lo hace) y reinicia |

Reglas de seguridad que el agente respeta siempre: no lanza ni mata procesos (solo lee `/proc`); nunca archiva hilos (solo `settle`);
nunca imprime tokens ni URLs de webhook.
