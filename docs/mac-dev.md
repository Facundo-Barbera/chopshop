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
