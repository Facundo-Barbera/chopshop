# App Mac en modo dev (hot reload)

Para iterar la UI en vivo sin tocar la app instalada en /Applications.

1. Requisitos: Xcode, InjectionIII en /Applications y `Resources/web` generado (`pnpm install && pnpm app` desde la raíz).
2. `apps/mac/dev.sh` compila en Debug con `CHOPSHOP_HOT_RELOAD=1` y deja `apps/mac/dist/Chopshop Dev.app` (bundle id `local.chopshop.ui.dev`).
   La firma usa la identidad «Apple Development» si está en el llavero; si no, la firma es ad-hoc.
3. En InjectionIII, elige «Open Project» y apunta a `apps/mac`. Luego `open "apps/mac/dist/Chopshop Dev.app"`. Cada `.swift` guardado en `apps/mac/Sources` se ve en caliente.
4. `dev.sh` no incrusta el agente. Para probar «Usar esta Mac» en dev hay que incrustarlo aparte (`release/embed-agent.sh` sobre el bundle y volver a firmar).
   El agente de dev (`local.chopshop.ui.dev.agent`) usa el mismo puerto 3790 que el de release, así que no hay que dejar los dos activos.
   La app de dev trae «Usar esta Mac» apagado (`defaults write local.chopshop.ui.dev chopshop.useThisMac -bool false`).
5. En Debug, la credencial del agente se guarda en `~/Library/Application Support/Chopshop Dev/credentials.json` (0600), no en el llavero, así que los rebuilds no piden permiso. Release usa siempre el llavero.

Variables útiles: `CHOPSHOP_CONFIG=<toml>` para usar otra configuración, `CHOPSHOP_DEMO_FIXTURE=<jsonl>` y `CHOPSHOP_DEMO_SPEED` para reproducir sobres sin agente, `CHOPSHOP_DEMO_TOUR=1` para el recorrido automático de cámara (solo para capturas; apagado por defecto) y `CHOPSHOP_NO_SETTINGS=1` para no abrir Ajustes al arrancar.

Para cerrar dev: sal de la app y de InjectionIII, y retira el agente de dev si quedó cargado (`launchctl bootout gui/$(id -u)/local.chopshop.ui.dev.agent`).

## Backend de cuentas: URL y prueba de login en vivo

La app habla con el backend de cuentas (`/v1/auth/*`) mediante `BackendClient` (`Sources/ChopshopNative/Backend/BackendClient.swift`),
envuelto por `BackendAuth` (`Sources/ChopshopNative/Live/BackendAuth.swift`).

- URL por defecto: `BackendClient.defaultAPIURL` = `https://api.chopshop.novarix.online` (el backend en vivo; no hay otra por defecto
  de desarrollo). Al arrancar, `Model.auth` usa la URL del primer agente con `destination = "relay"` del config local
  (`[app.agents.<nombre>]` con `url` y `destination = "relay"`) si existe y es válida; si no, la de por defecto.
- Para apuntar a otro servidor: en la pantalla de login, «Servidor» (se muestra sola si la URL no es la de por defecto), o el agente
  `relay` del config. Solo se aceptan `https://` (o `http://` a `localhost`/`127.0.0.1`).
- Sesión (`ss1_…`): `SessionStore`, una por host de la API. Release: Keychain, servicio `com.chopshop.session`. Debug (Chopshop Dev):
  archivo `~/Library/Application Support/Chopshop Dev/session-credentials.json`. Nunca en config ni UserDefaults.

Prueba de login en vivo (`Tests/ChopshopNativeTests/LiveLoginTests.swift`): hace login con el mismo `BackendAuth`/`BackendClient` y
transporte `URLSession` de la app, comprueba que la sesión empieza por `ss1_` (sin imprimirla), que `GET /v1/auth/me` responde 200 y
cierra la sesión al final (`POST /v1/auth/logout`). Sin credenciales se salta.

```sh
cd apps/mac
CHOPSHOP_TEST_EMAIL='usuario@ejemplo.com' CHOPSHOP_TEST_PASSWORD='…' swift test --filter LiveLoginTests
```

`CHOPSHOP_TEST_API_URL` (opcional) cambia el servidor de la prueba; por defecto, el backend en vivo.
