# chopshop-agent como servicio `systemd --user`

Guía para instalar, probar y operar el agente en una máquina Linux. Contrato de la API: [`agent-api.md`](agent-api.md);
diseño: [`agent-architecture.md`](agent-architecture.md). Todos los nombres de máquina, IPs y usuarios de esta guía son ejemplos
(`host-a`, `100.64.0.10`, `usuario@github`): pon los tuyos **solo** en tu `~/.config/chopshop/config.toml`, que no se versiona.

> **Nada se habilita ni se arranca solo.** Ni el instalador ni el agente ejecutan `systemctl enable`, `loginctl enable-linger` ni
> `start`. Primero se prueba a mano (`start` / `stop`); habilitarlo para que arranque con tu sesión es una decisión tuya, al final.

## Qué hace el servicio

Un proceso Python (solo stdlib, >= 3.9) con: API HTTP (`/health`, `/snapshot`, `/metrics`, `/events`, `/threads`, `/leases`, ...),
muestreo de CPU/RAM por app y proyecto desde `/proc`, vigilancia de los hilos de T3, servidores de prueba con cola por capacidad
(`systemd-run --user`), eventos y webhooks. La base de datos es SQLite (WAL) en `agent.db_path`.

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
   | `t3.*`, `t3_enabled` | cómo hablar con T3 de esta máquina (`false` = máquina solo sensor) |
   | `projects.<p>.test_server.cmd` | comando del servidor de pruebas de cada proyecto (el agente **solo** ejecuta lo que pones aquí) |
   | `webhook_files.<nombre>` | **ruta** a un archivo 0600 que contiene la URL del webhook (la URL nunca va en la config) |

   Valida:

   ```sh
   apps/agent/bin/chopshop agent check-config
   ```

   Muestra errores (exit 1) y avisos: token flojo de permisos, `owner_login` que parece un marcador, helper de T3 ausente, etc.

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
   apps/agent/bin/chopshop agent status            # resumen: versión, T3, última muestra/sondeo, leases, estado de la unidad
   systemctl --user stop chopshop-agent
   ```

   La parada es limpia (SIGTERM): se cierran los sockets, se esperan los hilos y se vacía la cola de webhooks. Los servidores de prueba
   que el agente lanzó son unidades aparte (`chopshop-ts-*`): no mueren con él; se liberan con `/leases/release` o por inactividad.

7. **Probar la API con `curl`**. Desde la propia máquina (origen local, sin token):

   ```sh
   curl -s http://127.0.0.1:3790/health
   curl -s http://127.0.0.1:3790/snapshot | python3 -m json.tool | head -40
   ```

   Desde otra máquina de tu tailnet contra `host-a` (IP de ejemplo; identidad Tailscale para leer, más bearer para escribir):

   ```sh
   TOKEN="$(cat ~/.chopshop/agent/token)"      # el archivo copiado en el paso 3
   curl -s http://100.64.0.10:3790/snapshot | head -c 300
   curl -s -X POST http://100.64.0.10:3790/sweep \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"dry_run": true}'
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
| `tailscale+token` | identidad de Tailscale (`tailscale whois --json <ip>`, cache 60 s): `owner_login` lee y escribe, `allowed_logins` solo leen. **Escribir exige además el bearer.** |
| `token` | solo el bearer, en toda petición. Para clientes sin identidad Tailscale o si no usas Tailscale |
| `none-local` | nadie por red; solo el origen local |

El **origen local** (misma máquina: MCP, CLI, `curl` a `127.0.0.1`) se acepta siempre mientras `trust_local = true`; ponlo en `false`
si en la máquina hay otros usuarios en los que no confíes. Los logins se escriben completos, como los muestra `tailscale whois`
(el `usuario@` de `config.example.toml` es un marcador). Para `whois` el usuario del servicio debe poder hablar con `tailscaled`
(`sudo tailscale set --operator=$USER`). Si `bind` no es loopback, el agente abre además `127.0.0.1:<port>` (`local_listener`).

El agente **no ejecuta comandos que le pida un cliente**: `POST /leases/request` solo lanza el `test_server.cmd` de la config
(`allow_request_cmd = false`), y solo para worktrees bajo `projects_root` / `worktrees_root` / proyectos configurados.

## MCP y `runOnSettle` para los hilos de T3

Los ejemplos están en [`examples/`](../examples):

- **MCP** (`examples/mcp.json`): registra el servidor `chopshop` (`chopshop mcp`) en el cliente MCP de tu agente. Habla con el agente en
  `CHOPSHOP_AGENT_URL` (por defecto `http://127.0.0.1:<port>`). Tools: `chopshop_request_test_server`, `chopshop_request_port`,
  `chopshop_release`, `chopshop_status`. Instrucciones para los agentes: `examples/AGENTS-chopshop.md`.
- **`runOnSettle`** (`examples/t3.json`): script de T3 que al hacer *settle* de un hilo ejecuta `chopshop release --worktree ... --thread ...`
  y libera sus servidores de prueba. Siempre sale con 0 aunque el agente esté caído.

Para usarlos desde otra máquina, apunta `CHOPSHOP_AGENT_URL` a `http://100.64.0.10:3790` y deja el token en `agent.token_file` del cliente.

## Troubleshooting

| Síntoma | Causa y arreglo |
|---|---|
| `chopshop agent check-config` dice `bind = "auto" pero no pude obtener la IP de Tailscale` | `tailscaled` no está activo o `tailscale_bin` no es el correcto. Arráncalo o pon la IP en `agent.bind` |
| La unidad falla al arrancar y reintenta cada 10 s | `journalctl --user -u chopshop-agent -n 50`. Típico: puerto ocupado, `bind` inválido o IP de Tailscale aún sin levantar al iniciar sesión (reintenta solo) |
| `403 sin identidad válida` desde otra máquina | `owner_login`/`allowed_logins` no coincide con el login real (`tailscale whois 100.64.0.x`), o `tailscale whois` no responde (falta `tailscale set --operator`). Con `auth = "token"` falta el bearer |
| `403 las escrituras exigen el bearer` | añade `Authorization: Bearer $(cat token)`; el token del cliente debe ser el mismo archivo del agente |
| `403 esta identidad es de solo lectura` | el login está en `allowed_logins`; solo `owner_login` escribe |
| `400 cmd no permitido` | definido a propósito: pon `test_server.cmd` en el proyecto (o `allow_request_cmd = true` si aceptas el riesgo) |
| `400 worktree fuera de ...` | el worktree no cuelga de `projects_root`/`worktrees_root`/proyectos configurados |
| `agent.t3_ok` es `false` / evento `t3_unreachable` | revisa `agent.t3.helper`, `node`, `t3_bin` y que T3 esté arriba; el agente reintenta con backoff (10 s → 5 min) y avisa `t3_recovered` |
| `503 T3 desactivado` | `agent.t3_enabled = false` en esa máquina |
| Un servidor de prueba no arranca (`lease_failed`) | mira `reason`/`detail` del lease (`GET /leases`): directorio inexistente, sin comando o fallo de `systemd-run` |
| El agente no puede escribir en alguna carpeta | `ProtectSystem=strict` deja todo en solo lectura salvo `ReadWritePaths`: añade `--rw` en `print-unit` o `[agent.service] read_write_paths` y reinstala |
| `MemoryMax`/`CPUQuota` no se aplican | el gestor de usuario no tiene esos controladores delegados; la unidad funciona igual, solo sin topes |
| Cambié la config | `systemctl --user restart chopshop-agent` (la config se lee al arrancar) |
| Cambié la plantilla de la unidad | `scripts/install-user-unit.sh --force` y `systemctl --user daemon-reload` (ya lo hace) y reinicia |

Reglas de seguridad que el agente respeta siempre: nunca `pkill`/`killall`; los barridos solo paran la unidad exacta (`systemctl --user
stop chopshop-ts-...`) o señalan PIDs exactos de un `cgroup.procs` concreto (y solo con `sweep.agent_scopes = "kill"`); nunca archiva
hilos (solo `settle`); nunca imprime tokens ni URLs de webhook.
