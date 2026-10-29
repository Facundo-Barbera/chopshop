# Capturas (`assets/`)

Las capturas del repo muestran **solo datos de ejemplo**: hosts `host-a`/`host-b`, proyectos `proyecto-demo`/`app-ejemplo`, URLs reservadas (`*.example.test`) y personas/bots ficticios (`persona-demo`, `bot-demo`). Las capturas anteriores, hechas con el estado real de una instalación, se eliminaron porque mostraban nombres de máquinas, proyectos y rutas privadas. **No guardes en `assets/` capturas de un `~/.chopshop` real.**

| Archivo | Vista |
|---|---|
| `assets/overview.png` | Resumen |
| `assets/machines.png` | Máquinas (métricas y alertas) |
| `assets/project.png` | Proyecto: lotes, tareas y detalle |
| `assets/batches.png` | Lotes |
| `assets/questions.png` | Preguntas pendientes y respondidas |
| `assets/graph.png` | Grafo de tareas |
| `assets/reactions.png` | Reacciones por niveles (auto / bot / humano) |
| `assets/events.png` | Actividad / eventos |

## Cómo se generan

`tools/screenshots/` no levanta ningún servidor ni abre la app:

- `fixture.json`: lo que devolverían dos agentes ficticios en `GET /snapshot` (forma de [`agent-api.md`](agent-api.md): `host-a` con el orquestador y `host-b` solo sensor), los parámetros del historial de métricas y la hora fija de la captura. También lo usan las pruebas de renderizado de la UI (`apps/ui/test`, `pnpm test`).
- `shoot.py`: toma el bundle estático de la UI (`apps/mac/Resources/web`), genera en un directorio temporal un HTML que emula el puente nativo de `WKWebView` (`window.webkit.messageHandlers.chopshop`, ver `apps/ui/src/bridge.js`) y le entrega el fixture (`agents`, `history`, `select`: los mismos mensajes que envía la app nativa), y lo captura con Chromium headless desde `file://`. Congela el reloj (`page.clock`) para que los «hace N min» sean estables.

```sh
pip install playwright && playwright install chromium   # una vez; hace falta alguna fuente del sistema
python3 tools/screenshots/shoot.py                       # las 8 vistas en assets/
python3 tools/screenshots/shoot.py --only graph,events   # solo algunas
python3 tools/screenshots/shoot.py --build               # recompila la UI (apps/ui) en un directorio temporal
```

Notas:

- Las capturas muestran solo el contenido web; el shell SwiftUI (barra lateral, ventana) no se emula. El fondo degradado imita el vidrio nativo sobre el que va la web.
- Si cambias la UI, ejecuta antes `pnpm build` (actualiza el bundle de `apps/mac/Resources/web`) o usa `--build`.
- Para añadir una vista, agrégala a `SCENES` en `shoot.py` (clave = nombre del PNG, valor = `vista[:argumento]`, como en el mensaje `select` de la app).
- Mantén cada PNG por debajo de ~300 KB (el tamaño por defecto es 1200×760).
- Cualquier dato nuevo del fixture debe ser inventado: nada de nombres, rutas, IPs, correos ni URLs reales.
