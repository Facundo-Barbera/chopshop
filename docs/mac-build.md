# Construir y usar Chopshop.app (macOS)

`Chopshop.app` es un **cliente puro** de la API del agente ([`agent-api.md`](agent-api.md)): se conecta por Tailscale al `chopshop-agent` de cada máquina, pinta su estado y envía las acciones (responder, cerrar hilos, liberar servidores de prueba). No lleva Python ni motor embebido y no habla con T3 directamente.

Todos los nombres, IPs y rutas de esta guía son de ejemplo (`host-a`, `100.64.0.10`...).

## Requisitos

- macOS 13 (Ventura) o posterior. En macOS 26 la barra lateral usa vidrio líquido; en versiones anteriores, un material translúcido.
- Xcode, o al menos las Command Line Tools con Swift 6 (`xcode-select --install`; compruébalo con `swift --version`).
- Node.js 20+ y [pnpm](https://pnpm.io) (para construir la UI web que va dentro del `.app`).
- Un agente de Chopshop corriendo en alguna máquina de tu red Tailscale, y Tailscale conectado en este Mac.

## Construir

```sh
git clone <url-del-repo> chopshop && cd chopshop
pnpm install
pnpm app
```

`pnpm app` construye la UI (`apps/ui` → `apps/mac/Resources/web`) y luego ejecuta `apps/mac/build.sh`, que hace `swift build -c release`, arma el bundle a mano (ejecutable, `Resources/web`, icono, `Info.plist`) y lo firma de forma ad-hoc (`codesign -s -`).

El resultado queda en:

```
apps/mac/dist/Chopshop.app
```

(`dist/` y `.build/` están en `.gitignore`.) Para copiarla a Aplicaciones: `cp -R apps/mac/dist/Chopshop.app ~/Applications/`.

Variables opcionales de `build.sh`: `CHOPSHOP_APP=/otra/ruta/Chopshop.app` (salida), `REBUILD_WEB=1` (reconstruir antes la UI), `UNIVERSAL=1` (arm64 + x86_64; requiere Xcode completo).

## Configurar la conexión

La app lee `~/.config/chopshop/config.toml` (o la ruta de `CHOPSHOP_CONFIG`; con `XDG_CONFIG_HOME` definido, `$XDG_CONFIG_HOME/chopshop/config.toml`). Parte de la plantilla del repo:

```sh
mkdir -p ~/.config/chopshop
cp config.example.toml ~/.config/chopshop/config.toml   # el archivo local no se versiona
```

y deja en él (como mínimo) la sección `[app]`:

```toml
[app]
agent_url = "http://100.64.0.10:3790"    # IP de Tailscale del agente + puerto (agent.port)
token_file = "~/.chopshop/agent/token"   # ruta a un archivo con el token (nunca el token en sí)
refresh_seconds = 3                      # segundos entre sondeos (1-300)
```

Varias máquinas: una tabla por agente; la app las combina en una sola vista (cada snapshot lleva su `machine_id`). Si defines `agent_url` y además `[app.agents.*]`, se usan todos.

```toml
[app.agents.host-b]
url = "http://100.64.0.11:3790"
token_file = "~/.chopshop/agent/host-b.token"
```

También se puede configurar por entorno (tiene prioridad sobre el archivo): `CHOPSHOP_APP__AGENT_URL`, `CHOPSHOP_APP__TOKEN_FILE`, `CHOPSHOP_APP__REFRESH_SECONDS`, `CHOPSHOP_APP__AGENTS__HOST_B__URL`, `CHOPSHOP_APP__AGENTS__HOST_B__TOKEN_FILE` (en el nombre, `_` equivale a `-`).

### Token del agente

Las lecturas (`GET`) se autorizan por identidad Tailscale; las **acciones** (`POST`: responder, `settle`, servidores de prueba) exigen además el token del agente (o ser el propio dueño por origen local). El token es el contenido del archivo `agent.token_file` del agente (por defecto `~/.chopshop/agent/token`). Cópialo a este Mac por `scp`, con permisos restrictivos:

```sh
mkdir -p ~/.chopshop/agent
scp host-a:.chopshop/agent/token ~/.chopshop/agent/token
chmod 600 ~/.chopshop/agent/token
```

La app lee el archivo en cada petición (puedes rotar el token sin reabrirla), lo envía solo como `Authorization: Bearer …` y **nunca** lo imprime ni lo guarda en otro sitio. No lo pegues en `config.toml`: ahí va solo la ruta.

## Abrir la app la primera vez

La firma es ad-hoc (sin cuenta de desarrollador), así que Gatekeeper la bloquea al abrirla por primera vez:

1. En Finder, clic derecho (o Ctrl+clic) sobre `Chopshop.app` → **Abrir**.
2. En el aviso, pulsa **Abrir**. Las siguientes veces se abre con doble clic.

Si macOS la marca como «dañada» (por haberla copiado desde otra máquina o descargado), quita la cuarentena: `xattr -dr com.apple.quarantine apps/mac/dist/Chopshop.app`. Si macOS pregunta por acceso a la **Red local**, acéptalo.

## Qué verás

- **Conectando…**: primer sondeo en curso. **Ningún agente configurado**: falta `[app]` en el `config.toml` (la pantalla indica la ruta que busca la app).
- **«agente no alcanzable»**: no hay conexión (Tailscale desconectado, agente parado, IP o puerto incorrectos) o se agotó el tiempo de espera. La app sigue abierta, reintenta cada ciclo y, si ya había datos, los muestra marcados como viejos.
- **«acceso denegado (403)»**: tu identidad Tailscale no es el dueño ni está en `allowed_logins` del agente. **«token rechazado (401)»**: el archivo `token_file` no existe o no coincide con el del agente (afecta sobre todo a las acciones).
- La barra lateral muestra cuántos agentes responden (p. ej. «2 de 3 agentes»).

## Solución de problemas

| Síntoma | Qué revisar |
|---|---|
| `Falta swift` al construir | Instala Xcode o `xcode-select --install`. |
| `Falta Resources/web` | Ejecuta `pnpm install && pnpm app` desde la raíz (construye la UI antes del `.app`). |
| La ventana abre pero dice que no hay agente configurado | Crea `~/.config/chopshop/config.toml` con `[app]` (ver arriba) y reabre la app. Si usas `CHOPSHOP_CONFIG`, ten en cuenta que una app abierta desde Finder no hereda las variables de tu terminal: lánzala con `open` desde esa misma terminal o usa la ruta por defecto. |
| «agente no alcanzable» siempre | `curl http://100.64.0.10:3790/health` desde este Mac; `tailscale status`; que el agente escuche en esa IP (`agent.bind`) y el puerto sea el de `agent.port`. |
| Se ve todo pero responder falla con 403/401 | Falta el token o no coincide: vuelve a copiar el archivo (ver «Token del agente») y comprueba su ruta en `token_file`. |
| Los datos de una máquina salen «de hace N s» | Esa máquina dejó de responder; el resto sigue en vivo. |
| Cambié el `config.toml` y no pasa nada | La configuración se lee al abrir: cierra y vuelve a abrir la app. |
| Quiero ver errores del arranque | Ejecuta el binario desde la terminal: `apps/mac/dist/Chopshop.app/Contents/MacOS/Chopshop`. |

## Desarrollo

- `swift build` en `apps/mac` compila sin empaquetar; `swift run` busca la UI en `CHOPSHOP_WEB_DIR` o en `Resources/web` del directorio actual.
- `swift test` (requiere Xcode) ejecuta las pruebas de la lógica pura: lectura del config, cliente con transporte falso, resumen y combinación de agentes. La combinación de snapshots que pinta la UI se prueba en JS: `pnpm test` (`packages/api/test`).
- Capturas con datos de ejemplo, sin servidores: [`screenshots.md`](screenshots.md).
