# Construir y usar Chopshop.app (macOS)

`Chopshop.app` es un **cliente puro** de la API del agente ([`agent-api.md`](agent-api.md)): se conecta por Tailscale al `chopshop-agent` de cada máquina, pinta su estado y envía las únicas acciones que tiene (responder y cerrar hilos pendientes); todo lo demás es de solo lectura. No lleva Python ni motor embebido y no habla con T3 directamente.

Todos los nombres, IPs y rutas de esta guía son de ejemplo (`host-a`, `100.64.0.10`...).

## Requisitos

- macOS 13 (Ventura) o posterior. En macOS 26 la barra lateral usa vidrio líquido y el detalle de cada proyecto es la **oficina
  nativa en vivo** (ver «Oficina en vivo»); en versiones anteriores, un material translúcido y la vista web.
- Xcode, o al menos las Command Line Tools con Swift 6 (`xcode-select --install`; compruébalo con `swift --version`). Para que el
  binario incluya la oficina con vidrio líquido hace falta el **SDK de macOS 26+ (Xcode ≥ 26)**; con un Xcode anterior la app
  debería compilar igual (solo el vidrio, `glassEffect`, va tras `#if compiler(>=6.2)` con un sustituto plano; no se ha probado con
  Xcode < 26), así que el release en CI debe usar Xcode ≥ 26
  (variable `XCODE_VERSION` del workflow, ver [`release.md`](release.md)).
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

La app lee `~/.config/chopshop/config.toml` (o la ruta de `CHOPSHOP_CONFIG`; con `XDG_CONFIG_HOME` definido, `$XDG_CONFIG_HOME/chopshop/config.toml`). También puedes configurar un agente desde la propia app: **Ajustes… (⌘,)**, que se abre sola si no hay ninguno configurado (o con el primer 401: sin emparejar), pide `agent_url`, escribe solo esa clave de `[app]` (conserva el resto del archivo y los comentarios, permisos 600; quita un `token_file` viejo de `[app]`), recarga los agentes sin reiniciar y muestra el emparejamiento de cada agente. Para editarlo a mano, parte de la plantilla del repo:

```sh
mkdir -p ~/.config/chopshop
cp config.example.toml ~/.config/chopshop/config.toml   # el archivo local no se versiona
```

y deja en él (como mínimo) la sección `[app]`:

```toml
[app]
agent_url = "http://100.64.0.10:3790"    # IP de Tailscale del agente + puerto (agent.port)
refresh_seconds = 3                      # segundos entre sondeos (1-300)
```

Varias máquinas: una tabla por agente; la app las combina en una sola vista (cada snapshot lleva su `machine_id`). Si defines `agent_url` y además `[app.agents.*]`, se usan todos.

```toml
[app.agents.host-b]
url = "http://100.64.0.11:3790"
```

También se puede configurar por entorno (tiene prioridad sobre el archivo): `CHOPSHOP_APP__AGENT_URL`, `CHOPSHOP_APP__REFRESH_SECONDS`, `CHOPSHOP_APP__AGENTS__HOST_B__URL` (en el nombre, `_` equivale a `-`). `token_file` (y `CHOPSHOP_APP__*TOKEN_FILE`) de versiones anteriores se ignora sin error.

### Emparejar este Mac con el agente

Con el agente en `api_version 2` **toda** petición (lecturas incluidas) exige una credencial de dispositivo (docs/agent-api.md,
«Emparejamiento por dispositivo»). Se obtiene una vez por agente:

1. En la máquina del agente (CLI local, no hay ruta HTTP): `chopshop pair create --name "MacBook"`. Imprime un código de un solo
   uso (p. ej. `K7QM-93XD`) que caduca en 10 minutos.
2. En la app: **Ajustes… (⌘,) → Emparejamiento**, escribe el código (con o sin guion, da igual mayúsculas) y pulsa **Emparejar**
   (o, en macOS 26, directamente en el detalle del proyecto).

La app llama a `POST /pair` y guarda la credencial (`cs1_…`) en el **Llavero** (contraseña genérica, servicio `com.chopshop.agent`,
cuenta `<máquina>@<host:puerto>`, solo este dispositivo, sin sincronizar con iCloud). **Nunca** va a `config.toml` ni a
`UserDefaults` ni a los logs. Se manda como `Authorization: Bearer cs1_…` en cada petición (`/snapshot`, `/stream`, `/answer`, `/settle`).

- **Desemparejar** (Ajustes) borra la credencial de este Mac; para invalidarla también en el agente: `chopshop pair list` y
  `chopshop pair revoke <device_id>`. Si el agente la revoca, la app recibe 401, borra la entrada del Llavero y vuelve a pedir código.
- Errores al emparejar: código incorrecto (401), usado o caducado (410), demasiados intentos (429), o agente sin emparejamiento
  (anterior a `api_version 2`: actualízalo). Contra un agente antiguo las acciones fallan con 403 y la app lo explica; en macOS 26
  el detalle del proyecto ofrece «Seguir con la vista clásica».
- Al primer arranque con un ad-hoc nuevo, macOS puede preguntar si la app puede usar el Llavero: pulsa «Permitir siempre».

## Oficina en vivo (macOS 26)

En macOS 26 o posterior el detalle de un **proyecto** es la vista nativa `ChopshopNative` (oficina isométrica / grafo en capas,
«necesita tu atención», lista compacta), alimentada por el stream de eventos del agente principal (el primero configurado):

- `LiveStore` abre `GET /stream` (SSE) con la credencial, pliega cada sobre con la misma regla que `projection.py`
  (`LiveState.apply`; hay test de equivalencia con la proyección dorada) y reconecta con `Last-Event-ID` y backoff 3→30 s.
  El indicador de la barra dice **en vivo**, **reconectando** o **sin emparejar**.
- Los botones de una pregunta responden por `POST /answer`; permitir/denegar y reintentar no tienen API: el botón abre el hilo en T3.
- La vista web (`WKWebView`) sigue cargada detrás: Resumen, Preguntas, Actividad… y todo en macOS < 26 siguen con `GET /snapshot`.
  Si el stream no responde y no hay datos (agente antiguo), se ve la vista web.
- Modo demo sin agente: `Chopshop.app/Contents/MacOS/Chopshop --demo-fixture apps/agent/tests/fixtures/events/ui-fixture.jsonl`
  (o `CHOPSHOP_DEMO_FIXTURE=…`): reproduce la secuencia acelerada. `--demo-speed 0` (o `CHOPSHOP_DEMO_SPEED`) la entrega de golpe.
  Escena de muchos hilos (46, 1 corriendo; tiempos relativos a ahora):
  `python3 apps/mac/Tests/ChopshopNativeTests/tools/make_office_layout_fixture.py /tmp/office-46.jsonl [--no-office]`.
- **Oficina** de un proyecto: pisos (`ProjectOfficeView`, un selector abajo a la izquierda): el vestíbulo y los pisos de escritorios
  por rol (los del perfil `office`; sin perfil, departamentos sintéticos por `role` de hasta 6 escritorios, ≤ 24 por piso, el resto
  sube a otro piso). Los hilos terminados se desvanecen con la semivida y salen; un terminado sin `ended_at` usa la hora de su
  último `task.state`. Etiqueta = nombre corto del hilo; el título entero, al pasar el ratón. «Grafo» sigue siendo el grafo.
- **Ciudad** (barra lateral, arriba): todos los proyectos como edificios; clic en un piso → zoom a la oficina de ese piso.
- Con `--capture`, `apps/mac/shot.sh <salida.png> click:<x>,<y>` hace clic en esos puntos de la ventana y captura tras el zoom.
- Por ahora el stream es de un solo agente; los demás se ven por `/snapshot` en la vista web.
- Requiere un agente con `api_version 2` (`/stream`, `/state`, `/pair`). Mientras el agente instalado sea anterior, el
  emparejamiento responde «agente sin emparejamiento», las acciones dan 403 con un mensaje claro y los proyectos se ven en la web.

Código: `apps/mac/Sources/ChopshopNative` (lógica pura en `Live/`, sin requisito de macOS 26; vistas con `@available(macOS 26.0, *)`).
Banco de pruebas con Previews: `apps/mac/native` (ver su README).

## Abrir la app la primera vez

La firma es ad-hoc (sin cuenta de desarrollador), así que Gatekeeper la bloquea al abrirla por primera vez:

1. En Finder, clic derecho (o Ctrl+clic) sobre `Chopshop.app` → **Abrir**.
2. En el aviso, pulsa **Abrir**. Las siguientes veces se abre con doble clic.

Si macOS la marca como «dañada» (por haberla copiado desde otra máquina o descargado), quita la cuarentena: `xattr -dr com.apple.quarantine apps/mac/dist/Chopshop.app`. Si macOS pregunta por acceso a la **Red local**, acéptalo.

## Qué verás

- **Conectando…**: primer sondeo en curso. **Ningún agente configurado**: falta `[app]` en el `config.toml` (la pantalla indica la ruta que busca la app).
- **«agente no alcanzable»**: no hay conexión (Tailscale desconectado, agente parado, IP o puerto incorrectos) o se agotó el tiempo de espera. La app sigue abierta, reintenta cada ciclo y, si ya había datos, los muestra marcados como viejos.
- **«acceso denegado (403)»**: tu identidad Tailscale no es el dueño ni está en `allowed_logins` del agente (o el agente es anterior a `api_version 2`). **«sin emparejar o credencial revocada (401)»**: empareja este Mac (ver arriba).
- La barra lateral muestra cuántos agentes responden (p. ej. «2 de 3 agentes»).

## Solución de problemas

| Síntoma | Qué revisar |
|---|---|
| `Falta swift` al construir | Instala Xcode o `xcode-select --install`. |
| `Falta Resources/web` | Ejecuta `pnpm install && pnpm app` desde la raíz (construye la UI antes del `.app`). |
| La ventana abre pero dice que no hay agente configurado | Crea `~/.config/chopshop/config.toml` con `[app]` (ver arriba) y reabre la app. Si usas `CHOPSHOP_CONFIG`, ten en cuenta que una app abierta desde Finder no hereda las variables de tu terminal: lánzala con `open` desde esa misma terminal o usa la ruta por defecto. |
| «agente no alcanzable» siempre | `curl http://100.64.0.10:3790/health` desde este Mac; `tailscale status`; que el agente escuche en esa IP (`agent.bind`) y el puerto sea el de `agent.port`. |
| Se ve todo pero responder falla con 403/401 | 401: empareja de nuevo (Ajustes → Emparejamiento). 403: identidad Tailscale sin permiso de escritura, o agente anterior a `api_version 2`. |
| Los datos de una máquina salen «de hace N s» | Esa máquina dejó de responder; el resto sigue en vivo. |
| Cambié el `config.toml` y no pasa nada | La configuración se lee al abrir: cierra y vuelve a abrir la app. |
| Quiero ver errores del arranque | Ejecuta el binario desde la terminal: `apps/mac/dist/Chopshop.app/Contents/MacOS/Chopshop`. |

## Desarrollo

- `swift build` en `apps/mac` compila sin empaquetar; `swift run` busca la UI en `CHOPSHOP_WEB_DIR` o en `Resources/web` del directorio actual.
- `swift test` (requiere Xcode) ejecuta las pruebas de la lógica pura: lectura del config, cliente con transporte falso, resumen y combinación de agentes (`ChopshopUITests`), y el contrato del bus (sobres dorados, `LiveState.fold` == proyección dorada de `projection.py`), parser SSE, stream con transporte falso, reconexión, emparejamiento y mapeo a la oficina (`ChopshopNativeTests`). La proyección dorada se regenera con `python3 apps/mac/Tests/ChopshopNativeTests/tools/make_golden.py <apps/agent con projection.py>`. La combinación de snapshots que pinta la UI se prueba en JS: `pnpm test` (`packages/api/test`).
- Capturas con datos de ejemplo, sin servidores: [`screenshots.md`](screenshots.md).
