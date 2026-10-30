# Plan: interfaz centrada en la oficina (la oficina como juego)

**Estado: fase 1 implementada en la rama `feat/office-first-ui` (sin compilar: se escribió en contabo-dev, sin Swift; la
compilación, los tests de Swift y las capturas se hacen en el Mac mini, ver «Qué verifica el Mac»).**

Dependencias:

- **El mundo** (ciudad → edificio → piso → escritorios, vestíbulo, semivida) lo construye otro hilo en
  `fix/or-office-layout` (`OfficeWorldView`, `ProjectWorkspace`, `WorldLayout`). Este plan **no** lo rehace: construye el
  armazón alrededor y lo consume por un único hueco (`OfficeShell(world:)`, ver «Contrato con el mundo»).
- **Qué conserva cada vista vieja** lo detalla `docs/plans/views-review.md` (rama `fix/views-polish`, todavía sin escribir
  cuando se hizo la fase 1). La tabla «Qué se queda de cada pantalla» de abajo sale del código actual (`apps/ui/src/App.jsx`,
  `ChopshopUI/Views.swift`); cuando llegue `views-review.md` manda ese documento y se corrige esta tabla.

## Concepto

La ventana es el mundo. Al abrir la app se ve la ciudad de proyectos a ventana completa; se entra a un piso con un clic o
desde la paleta, y todo lo demás (preguntas, actividad, lotes, reacciones, sala de máquinas, máquinas) son **controles
encima del mundo**, no pantallas aparte. Como en un juego de gestión: un HUD fino arriba que dice cuánto te necesita, una
paleta de órdenes para hacer cosas sin buscar botones, paneles que entran deslizándose para lo seleccionado, atajos de
teclado para todo y un minimapa para orientarse.

Reglas de aspecto (las mismas del resto de la app nativa):

- macOS nativo y sobrio. El HUD vive en la **barra de la ventana** (toolbar unificada: en macOS 26 ya es vidrio, no se añade
  otro). Los paneles son el **inspector** del sistema (`.inspector`, el panel lateral que usan Xcode y Finder). Vidrio
  explícito solo en la paleta (como Spotlight) y en el minimapa (pieza flotante sobre el contenido).
- Neutro: grises del sistema y tipografía SF. Color **solo para atención** (`Attention.needsYou` ámbar, `Attention.stuck`
  rojo); el resto en `.primary`/`.secondary`.
- **Sin tooltips en el mundo** (ni `.help` ni popovers al pasar el ratón): lo que haya que leer está en el panel o en la
  paleta. Lo comprueba `apps/mac/tests/test_office_first_ui.py`.

## Boceto

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  ◧ Chopshop  ● en vivo     ◉ 3 te necesitan   ▶ 7 corriendo   ▤ 3/4 máquinas    ⌘K  ◨ │  ← HUD (toolbar)
├──────────────────────────────────────────────────────────────────┬───────────────────────┤
│                                                                  │ Panel (inspector)     │
│                                                                  │  · hilo / escritorio  │
│                    MUNDO (ciudad → piso → escritorios)           │  · sala (piso)        │
│                    a ventana completa                            │  · Atención           │
│                                                                  │  · Actividad          │
│              ┌──────────────── ⌘K ───────────────┐               │  · Lotes              │
│              │ › responder                        │               │  · Reacciones         │
│              │   Responder «¿migrar?» → Sí        │               │  · Sala de máquinas   │
│              │   Settle hilo t-12                 │               │  · Máquinas           │
│              │   Ir a nuskills                    │               │                       │
│              └────────────────────────────────────┘               │                       │
│ ┌─────────┐                                                      │                       │
│ │ ▦ ▦  ▦  │ ← minimapa (edificios, pisos con atención en color)  │                       │
│ └─────────┘                                                      │                       │
└──────────────────────────────────────────────────────────────────┴───────────────────────┘
```

## Qué se quita

| Hoy | Después |
|---|---|
| Vista **Grafo** (web: `Graph`, `GraphCanvas`, `GraphDetail`; nativa: `GraphView`, `GraphBackdrop`, `GraphCameraBox`, selector Oficina/Grafo `GraphMode`/`ModeSwitch`, segmento «Grafo» de `CitySwitch`, captura `nuskills-dark-grafo.png`, entrada de la barra lateral y su test) | **Se borra entera (fase 1).** Los grafos siguen existiendo como datos (`snapshot.graphs`, `chopshop graph run`): su progreso se ve en la oficina (cada nodo es un hilo con escritorio) y en el panel Lotes. `GraphScene`/`GraphLayout`/`GraphInspector` se quedan: son la escena de `IsoOfficeView`, la oficina de reserva para agentes sin `office` (v2); se renombran cuando esa reserva desaparezca (fase 4). |
| Barra lateral (`NavigationSplitView`: Resumen, Preguntas, Actividad, Reacciones, Grafo, Lotes, Sala de máquinas, proyectos, máquinas) | Fuera en macOS 26 (fase 1): el mundo ocupa la ventana. Proyectos → minimapa y paleta; máquinas → HUD y panel Máquinas. |
| Pantallas Resumen, Preguntas, Actividad, Reacciones, Lotes (web) y Sala de máquinas (nativa) | Paneles del inspector + paleta + HUD (fase 1 en macOS 26). La UI web se queda solo como **reserva** para macOS < 26 y para agentes sin `/stream` (`preferWeb`); se poda en la fase 4. |
| Menú «Ir a» (⌘1…⌘7 = secciones) | Menú «Oficina» con los atajos de abajo. |

## Qué se queda de cada pantalla

| Pantalla vieja | Lo que tiene que seguir pudiéndose hacer | Dónde vive ahora |
|---|---|---|
| Resumen | cuánto te necesita, cuánto corre, estado de las máquinas, qué proyecto pide algo | HUD (3 contadores) + minimapa (pisos en color) + panel Atención |
| Preguntas | ver cada pregunta abierta con sus opciones, responder (`POST /answer`), abrir el hilo en T3 | panel Atención (`AttentionRow` + botones) y paleta («Responder … → opción») |
| Actividad | los últimos eventos, legibles, el más nuevo arriba | panel Actividad (`snapshot.events`) |
| Reacciones | qué hizo el decisor por cada tarea (nivel, acción, nota) | panel Reacciones (`task.reactions`) |
| Lotes | lotes por proyecto con su máquina, paralelismo y tareas (en curso, en cola, terminadas); settle de hilos terminados | panel Lotes + paleta («Settle …») |
| Grafo | progreso del grafo (nodos hechos/fallidos, hilos usados de su presupuesto); planificador (modo de throttle, CPU/RAM) y bitácora | panel Lotes (fila del grafo: nodos hechos/fallidos y `n de m hilos`, fase 1); planificador y bitácora en esa fila (fase 2); la oficina muestra los hilos |
| Sala de máquinas | listeners, automatizaciones, suscripciones, rack | panel Sala de máquinas (`LiveMachineRoomScreen` dentro del inspector); en la fase 3, sala del sótano en el mundo |
| Máquinas (sidebar) | CPU/RAM por máquina, cuáles fallan | HUD (`ok/total`, ámbar si alguna ≥ 100 % CPU) + panel Máquinas |

## Órdenes

Lo que la paleta puede hacer depende de lo que expone la API del agente (`docs/agent-api.md`):

| Orden | Ruta | Fase |
|---|---|---|
| Responder una pregunta (una entrada por opción) | `POST /answer` | 1 |
| Settle de un hilo terminado | `POST /settle` | 1 |
| Abrir el hilo en T3 | `t3-thread://` | 1 |
| Ir a proyecto / siguiente que te necesita / abrir un panel | (local) | 1 |
| Tocar un hilo (reinicia la semivida) | `POST /touch` | 2 |
| Asignar un hilo del vestíbulo a un escritorio · dejar una nota | `POST /desks/<id>/assign` · `/notes` | 2 |
| **Lanzar** un hilo, **parar** hilos/lote, **fanout**, **correr un grafo** | `POST /fanout` · `/stop` · `/graph/run` (api_version 4) | 3 |

En la fase 1 esas órdenes copiaban el comando de la CLI al portapapeles. La fase 3 añadió las rutas al agente (mismo modelo
de auth que `/settle`): la paleta las llama directamente; fanout pide la tarea en el propio campo de la paleta. Con un agente
anterior a api_version 4 (404/405) la paleta vuelve a copiar el comando exacto.

## Atajos

Fuente única: `ShellKeymap.all` (`apps/mac/Sources/ChopshopNative/Shell/ShellModel.swift`); el menú «Oficina» se genera
de ahí y el test de Python comprueba que esta tabla coincide.

| Atajo | Acción |
|---|---|
| ⌘K | Paleta de órdenes |
| ⌘J | Siguiente que te necesita |
| ⇧⌘J | Anterior que te necesita |
| ⌘1 | Panel Atención |
| ⌘2 | Panel Actividad |
| ⌘3 | Panel Lotes |
| ⌘4 | Panel Reacciones |
| ⌘5 | Panel Sala de máquinas |
| ⌘6 | Panel Máquinas |
| ⌘\ | Mostrar u ocultar el panel |
| ⇧⌘M | Mostrar u ocultar el minimapa |
| ⌘O | Abrir en T3 el hilo elegido |
| ⌘R | Actualizar |
| Esc | Cerrar la paleta; si no, el panel; si no, salir del piso (lo hace el mundo) |

## Contrato con el mundo

`OfficeShell` (fase 1) recibe el mundo como vista (`world: (ShellWorldContext) -> World`) y habla con él sin conocer su dibujo:

- mundo → armazón: `context.select(ShellTarget)`: el usuario pulsó un piso (`.project`) o un escritorio (`.thread`, con el hilo
  de T3 traducido a la tarea del snapshot por `MockSnapshot.shellTask`). Abre el panel de ese objetivo, sin mover la cámara.
- armazón → mundo: `context.focus: ShellFocus?` (objetivo + `token` que sube en cada petición): la paleta, el minimapa o ⌘J
  piden ir a un proyecto o a un hilo; el mundo hace su zoom. En la fase 1 lo cumple `CityView` (`focusRequest`: zoom al piso
  del proyecto, sin volver a avisar al armazón); `OfficeWorldView` lo adopta al integrarse (fase 2).
- `context.ownsEscape`: `false` mientras hay paleta o panel abiertos. El Esc del mundo es un atajo de botón (se procesa antes
  que el `onKeyPress` del armazón), así que el mundo lo desactiva entonces (`CityView(escapeZoomsOut:)`).
- El mundo no lleva tooltips ni tarjetas de hover (fase 1: fuera `IsoTooltip` de `FloorOfficeView`/`IsoOfficeView`; el
  resaltado de hover se queda).

## Fases

| Fase | Qué | Dónde |
|---|---|---|
| **1** | Quitar Grafo entero (web y nativo, tests). Modelo puro del armazón (`ShellModel.swift`: HUD, paneles, paleta con búsqueda difusa, atajos, ciclo de atención, minimapa) con tests de Swift. `OfficeShell` en macOS 26: mundo a ventana completa (`LiveCityScreen`), HUD en la toolbar, inspector con los paneles, paleta ⌘K, minimapa, menú «Oficina». Fuera la barra lateral en macOS 26 (la web queda de reserva). Settle cableado (`AttentionActions.settle`). Fuera las tarjetas de hover del mundo (`IsoTooltip`). `MockTask.threadID` para casar escritorio (hilo) y tarea. Test de Python de invariantes (sin Grafo, sin tooltips en el mundo, atajos = doc). | `feat/office-first-ui` |
| 2 | Integrar el mundo de `fix/or-office-layout` (`OfficeWorldView` en el hueco, `focus` en su cámara, `ThreadDetail` como panel de hilo). Paleta: tocar, asignar del vestíbulo, notas. Panel de escritorio (linaje, notas). | tras fusionar `fix/or-office-layout` |
| 3 | Rutas del agente para lanzar, parar, fanout y correr grafos (con tests de Python del agente) y sus órdenes en la paleta. Sala de máquinas como sótano del mundo. | agente + app |
| 4 | Podar la UI web a lo que necesita la reserva (macOS < 26) o retirarla; renombrar `GraphScene`/`GraphInspector` o borrarlos con `IsoOfficeView` si ya no hay agentes v2. | |

## Qué verifica el Mac (fase 1)

1. `swift build` y `swift test` en `apps/mac` (tests nuevos: `ShellModelTests.swift`).
2. `pnpm --filter @chopshop/ui test` y `build` (se borró la vista Grafo de la web y su test).
3. Arranque en macOS 26 con `--demo-fixture`: ventana sin barra lateral, ciudad a ventana completa, HUD en la toolbar con
   los 3 contadores (ámbar solo si hay atención), ⌘K abre la paleta y responde/settle funcionan contra un agente real.
4. Prioridad de Esc: paleta > panel > salir del piso. El `onKeyPress(.escape)` del armazón necesita foco: comprobar que llega
   con el foco en el mundo y en el inspector (si no, pasar a un atajo de menú que solo se active con algo abierto).
5. Capturas headless de `OfficeShell` (`ChopshopSnap shell`): HUD, panel Atención abierto, paleta abierta, minimapa.
6. macOS < 26 (o `preferWeb`): sigue la UI web de siempre, sin la entrada Grafo.
