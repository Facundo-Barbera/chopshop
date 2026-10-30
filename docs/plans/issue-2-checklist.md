# Borrador: checklist del issue #2 (relay en Cloudflare)

Estado al 2026-10-30, sobre `dev` (merge de E12). Borrador para actualizar el issue a mano: aquí no se tocó GitHub. Operación
del relay en `docs/relay.md`; protocolo en `docs/relay-protocol.md`. `[x]` = hecho y con tests o comprobado; `[~]` = hecho en
parte; `[ ]` = pendiente.

## Qué se construyó y en qué difiere de la propuesta del issue

- Un Worker y **un** Durable Object (`Hub`, `idFromName("global")`) con SQLite y WebSocket Hibernation para los agentes
  (`apps/relay`, R1-R9). Los visores leen por HTTP (`GET /state`, `GET /stream` SSE), no por WebSocket.
- Tokens `cr1_` con dos scopes (`agent`, `viewer`) más un token de operador (`RELAY_OPERATOR_TOKEN`), en lugar de los cuatro
  prefijos de la propuesta (`csv1_`, `csm1_`, `css1_`, `cso1_`). No hay token de servicio.
- El relay es **de solo lectura**: no hay `cmd`/`res` hacia los agentes ni MCP en Cloudflare (fases 3-6 de la propuesta, sin
  empezar). Los snapshots van con lista blanca y partes opacas (`relaysync.py`), no con el `GET /state` en claro.
- Desplegado: el tag `relay-v0.1.0` disparó `Relay deploy` en Actions con éxito (2026-10-30), en `*.workers.dev`.

## Requisitos

- [x] **Diseñar el relay en Cloudflare** (API de mensajes/eventos, SSE hacia la app): `docs/relay-protocol.md`, schemas
  `packages/api/relay/` (R1, K1, A6). La auditoría `python3 tools/contract_audit.py` cruza agente, relay y app.
- [~] **Login para la app y tokens de máquina emitibles y revocables; pairing por CLI con token.** Tokens emitibles
  (`POST /v1/pair/codes`, operador) y revocables con efecto inmediato (`DELETE /v1/tokens/<id>`, cierra WebSockets y `/stream`:
  R3, R8). El agente guarda el token con `chopshop relay pair --stdin` (A3). Falta: un `chopshop relay join <código>` que canjee
  el código (hoy es un `curl`); un login real en la app (hoy se pega el token `cr1_`); listar tokens emitidos.
- [x] **Agentes conectados de salida; nada expuesto de entrada.** Hilo `relay` del agente con reconexión y backoff
  (`agent/relay.py`, A4); el agente sigue escuchando solo donde diga `[agent] bind`.
- [x] **Solo lectura para el visor.** Rol `viewer` solo `GET` (R6), app con guarda `canAct` (M6), `GET /whoami` por HTTP (M12).
- [x] **Rate limit de pairing:** 5 fallos por IP y minuto, 20 fallos invalidan los códigos vivos (R3).
- [~] **Pantalla de login/emparejamiento en la app:** URL + token `viewer` validados con `/whoami` y `/state` (M5, M2, M10). No
  canjea códigos.

## Pendiente

- [~] **Dominio / cuenta de Cloudflare.** Cuenta: sí (el deploy funcionó con `CLOUDFLARE_API_TOKEN` y `CLOUDFLARE_ACCOUNT_ID`).
  Dominio propio: no; se usa `*.workers.dev` (`workers_dev = true`).

## Lo que #1 necesita de este issue

- [x] **Registro de empleados/roles vía relay:** `hello.projects[].roles` y la parte `employees` del snapshot (A2, A6). No hay
  mensaje `delta`: cada snapshot es completo y los eventos llevan el estado del sujeto.
- [x] **Snapshot con colas y estado de empleados** (A6). La app los fusiona por `machine_id` (M10).
- [~] **Emparejar la máquina Linux por token del relay.** Listo el mecanismo (ver «Requisitos»); falta hacerlo en la máquina real.
- [ ] **MCP servido desde Cloudflare.** Sin empezar; hoy fuera de alcance por la decisión de relay de solo lectura.
- [ ] **Quién emite los webhooks a los bots.** De hecho siguen saliendo de los agentes y del MCP local; el relay no emite
  webhooks. Falta cerrar la decisión en el issue.

## Fallos y huecos

- **BUG-1 (E13, arreglado en esta rama, sin desplegar):** `POST /v1/pair/codes` sin `?account=` abría una cuenta nueva y la
  respuesta no decía cuál, así que el operador no podía crear el código `viewer` en la misma cuenta que el agente (el visor no
  veía nada). Ahora la respuesta trae `account` (`pair.ts`, schema y fixture `pair-code`). Llega con el próximo tag `relay-v*`;
  mientras tanto, usar siempre `?account=ac-…` (`docs/relay.md` «Elegir la cuenta»).
- **BUG-10 (K4, abierto):** `GET /state` no dice si una máquina está conectada ni distingue «caducada» de «nunca vista».
- `apps/relay` no tiene tests propios (solo `tsc --noEmit` en el deploy); los contratos se cubren con
  `tools/contract_audit.py` y los tests del agente y de la app.
- La app no usa `GET /stream` del relay: refresca leyendo `GET /state`, así que los eventos en vivo no llegan al visor.
- En `pair.ts` la ruta de un token `agent` que crea o revoca códigos de su cuenta es inalcanzable: `routes.ts` solo deja esas
  rutas al rol `admin`. Decidir si se habilita o se borra.
- Rotar `RELAY_OPERATOR_TOKEN` exige un deploy nuevo (el workflow sube el secret en cada deploy).
