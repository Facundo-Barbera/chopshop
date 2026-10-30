# Verificación en el Mac: rediseño de la oficina (integración de las ramas `feat/or-*`)

Rama: `feat/office-redesign` (fase 0 + las 13 ramas `feat/or-*` integradas). Todo el Swift se escribió y se integró **sin
toolchain** (contabo-dev no tiene Swift): nada de lo de abajo está compilado ni ejecutado. El agente (Python) sí: suite
completa en verde en contabo-dev.

## 1. Compilar

- [x] `cd apps/mac && swift build` (app) y `cd apps/mac/native && swift build` (banco de pruebas, `NATIVE_PREVIEWS`).
- [x] Puntos de la integración con más riesgo de no compilar:
  - **Sala de máquinas, dos tipos**: `LiveState.MachineRoomState` (anidado, JSON, `Live/LiveStateOffice.swift`; lo usan
    `LiveState`, `LiveStateNames`, `OfficeFixture`, `OfficeTests`) y el `MachineRoom` tipado de nivel superior
    (`MachineRoom/MachineRoomModel.swift`; lo usan `LiveStore`, `MachineRoomView`, `MachineRoomSnapshots`, `MachineRoomTests`).
    Ya no comparten nombre (rama `fix/or-swift-risk`): dentro de `LiveState` `MachineRoom` es siempre el tipado.
  - `City/CityOffice.swift`: `init?(json:)` (`JSONValue.Object?`) e `init?(_:)` (`LiveState.Office?`), con etiqueta distinta para
    que `CityOffice(nil)` o un literal no sean ambiguos; `CityModel.build` y `CityOfficeTests` pasan `LiveState.Project.office`.
  - `ChopshopUI/Views.swift`: `LiveMachineRoomScreen(store:) { PairingScreen() }` (cierre final = `unpaired`, como
    `LiveProjectScreen`; ambas dentro de `if #available(macOS 26.0, *)`).
  - `MachineRoom/MachineRoomSnapshots.swift`: `Bundle.module` (solo en `native/`, que copia `machine-room-fixture.jsonl`) +
    `FixtureStream.parse` + `MachineRoom.fold`; si falta el fixture avisa y no escribe el PNG; reloj fijo en el último `ts`.

## 2. Doradas (si cambia el contrato o un fixture)

```sh
cd apps/agent && CHOPSHOP_UPDATE_GOLDEN=1 python3 -m unittest discover -s tests && cd ../..
python3 apps/mac/Tests/ChopshopNativeTests/tools/make_golden.py            # ui-fixture.state.json de la app
cp apps/agent/tests/fixtures/office/office-fixture.{jsonl,state.json} apps/mac/Tests/ChopshopNativeTests/Resources/office/
cp apps/agent/tests/fixtures/events/machine-room-fixture.{jsonl,state.json} apps/mac/Tests/ChopshopNativeTests/Resources/
cp apps/agent/tests/fixtures/events/machine-room-fixture.jsonl apps/mac/Sources/ChopshopNative/Resources/
```

## 3. `swift test`

- [x] `ContractTests` / `LiveStateTests` (dorada `ui-fixture.state.json` regenerada: v3 con `lobby` y `machine_room`).
- [x] `OfficeEquivalenceTests` (nuevo en la integración): oficina, vestíbulo y sala de máquinas == `projection.fold` de Python.
- [x] `OfficeTests` (incluye la tabla `office/halflife.json` de semivida), `CityOfficeTests`, `CityTests`, `FloorPlanTests`,
      `MachineRoomTests`, `StreamTests`, `SnapshotMapperTests`.

## 4. Capturas (`docs/screenshots.md`)

- [x] `ChopshopSnap <salida> machine-room` → `machine-room-dark.png` / `-light.png`: listeners (t3watch caído), scripts, y el
      rack de Awesome GB con **dos módulos**: repo principal (rojo, 3 runs: hilo, cron, bot) y Engine CX (ámbar, run de
      automatización en cola). La vista calcula "hace X" con el reloj real: el texto relativo cambia entre capturas.
- [x] Ciudad con varios pisos por proyecto y vestíbulo en planta baja (escena de `CityOfficeTests`).
- [x] Previews de `Office/FloorOfficeView.swift` (piso Producto, triage seleccionado, vestíbulo).
- [x] Ciudad: clic en un piso de un proyecto con `office` → zoom continuo que acaba en `FloorOfficeView` de **ese** piso (etiquetas
      y barra de atención iguales durante el zoom y al montarse); un proyecto sin `office` sigue abriendo la vista Grafo.

## 5. Comportamiento a mirar a ojo

- [ ] Ciudad: un proyecto con `office` ocupa hasta 4 pisos consecutivos; planta baja = vestíbulo (hilos sin rol); empresa desde
      `office.company` y `CompanyDirectory` solo como respaldo; proyectos sin `office` siguen en un piso.
- [ ] Piso (`FloorOfficeView`): departamentos por rol, escritorios fijos, ocupante con opacidad de semivida (T½ del perfil,
      ×2 si falló, sale bajo 0,1), retirado en gris, triage permanente "dormido" con su lámpara y notas pendientes.
- [ ] Sala de máquinas (ahora una sala del piso más bajo de cada proyecto, ver §7): ámbar parpadea; chips de origen (hilo con
      rol · escritorio, automatización, bot, cron, humano); webhooks sin URL.

## Resultado en el Mac (2026-10-29, Xcode 27.1, Swift 6.4, rama `fix/or-mac-verify`)

- `swift build` en `apps/mac` y `apps/mac/native`: verde tras un arreglo (`CityModel.build`: acceso solapado a `floors[k]` al
  asignar `alert?.floor`, error de exclusividad en Swift 6.4). `native/` no tiene target de tests.
- `swift test` en `apps/mac`: 91 + 15 tests en verde tras un arreglo: `LiveState.trimRuns` reordenaba los runs del rack por
  `updated_at`; ahora conserva el orden de llegada como `_trim` de `machine_room.py` (fallaba `OfficeEquivalenceTests`).
  Doradas sin regenerar (no cambió el contrato).
- Capturas: `ChopshopSnap <salida> machine-room | floor | city-office` (los dos últimos, nuevos: `Office/FloorSnapshots.swift`;
  la escena de `CityOfficeTests` pasa a `City/CityOfficeFixture.swift`). Arreglado de paso en `RackRender`: con el rack estrecho
  el subtítulo "proveedor · tipo · rama" se pisaba con el nombre del módulo; ahora la rejilla cede sitio y, si no cabe, se omite.
  Los cuadros amarillos 🚫 a la derecha de cada run son los `Link` que `ImageRenderer` no sabe dibujar (solo en la captura).
- El zoom de la ciudad se comprobó congelado (`frozenZoom` p = 0,5 y 1 hacia el piso Docs, el segundo del proyecto); el montaje
  interactivo de `FloorOfficeView` tras el clic no se probó a mano.

## 6. Huecos conocidos (no son de compilar)

- `FloorOfficeView` ya se monta al hacer zoom a un piso desde la Ciudad (rama fix/or-floor-view): `CityView` la alimenta con
  `FloorPlan.floors(in: LiveState, …)` (el `office` tipado, sin JSON crudo), el zoom se encuadra con `FloorLayout` y el piso
  elegido (no solo el primero del proyecto) se abre por su `CityFloor.id`. Proyectos sin `office` siguen abriendo `IsoOfficeView`.
  `onInspect` (→ `POST /touch`) queda expuesto en `CityView(state:…)` pero nadie lo cablea aún. El vestíbulo no tiene zoom.
- `IsoScene`/`IsoOfficeView` siguen con salas por rango de dependencias (modo Grafo); la oficina por departamentos vive en
  `Office/` aparte.

## La oficina en la app real (rama `fix/or-office-layout`, 2026-10-29)

Las capturas de v0.8 salían de `ChopshopSnap`, que pinta `FloorOfficeView` directamente; la app nunca la montaba:

- La pestaña «Oficina» del proyecto (`LiveProjectScreen` → `ProjectContent`) seguía con `IsoOfficeView` sobre el grafo sintético
  (un nodo por tarea, todas en el rango 0 → una sala de 3 × 16 en diagonal) y con **todas** las tareas: la proyección no poda
  `tasks` y ese camino ignoraba `ended_at`/`touched_at` (el agente sí los manda). Ahora monta `ProjectOfficeView` con
  `ProjectOffice.floors` (perfil o pisos sintéticos por rol, vestíbulo, semivida aplicada).
- La Ciudad no tenía entrada en la app (`LiveCityScreen` no se usaba) y además se construía sin `state`, así que su zoom tampoco
  podía montar los pisos. Ahora: «Ciudad» arriba en la barra lateral, con `state`, y el zoom monta `ProjectOfficeView` en el piso pulsado.
- Capturas nuevas: `ChopshopSnap <salida> floor` → `floor-proyecto-46-*.png`; `city-office` → `city-office-46-*.png`.

### Tras el WIP «mundo continuo» (`fd90e81`), en contabo-dev sin compilar

- `WorldLayout`: las regiones iban en una rejilla del **mundo** (filas a lo largo de +x, la siguiente fila en +y), que en
  isométrico es una diagonal: con la escena de 46 hilos (vestíbulo, Producto, máquinas) salía una columna, la franja diagonal, a
  cualquier proporción. Ahora van en **filas de pantalla** (cada fila horizontal y centrada) con el corte que mejor llena la
  proporción: 0,6–1 → 3 filas; 1,6–2,4 → vestíbulo y piso arriba, máquinas debajo; 3,5 → una fila. API sin cambios (`columns` =
  regiones de la fila más larga).
- `ProjectWorkspace`: con el reloj real, los pisos se rehacen cada 15 s (`TimelineView(.periodic)`) para que lo que la semivida
  desvaneció salga aunque no llegue nada del stream.
- Ciudad de la barra lateral: `LiveCityScreen(perProject: true)` → `CityModel.build(perProject:)`: un edificio por proyecto; la
  píldora del piso no repite el proyecto; el vestíbulo de un edificio de un solo proyecto también entra en su oficina.
- `WorldLayoutTests` (nuevo): losas sin solaparse y salas dentro de su losa a 5 proporciones, filas según la ventana, ids únicos,
  semivida (16 visibles; 6 h después solo el que corre), sala de máquinas por proyecto, ciudad por proyecto.

Pendiente en el Mac (sin ratón ni teclado reales: compilar, tests y capturas sin interfaz):

- [ ] `swift build` en `apps/mac` y `apps/mac/native`; `swift test` (`WorldLayoutTests` nuevo; el resto sin cambios esperados).
- [ ] `ChopshopSnap <salida> floor` → `floor-proyecto-46-*`: el mundo en filas horizontales (no en diagonal) a 1440×900 y
      2560×1440, llenando el ancho.
- [ ] `ChopshopSnap <salida> city-office` → `city-office-*` y `city-office-46-*` (zoom terminado en el mundo, encuadrado en el piso).
      Nuevas: `city-por-proyecto-dark.png` (un edificio por proyecto) y `city-por-proyecto-zoom-fin.png` (mundo encuadrado en Docs).

## 7. Sala de máquinas dentro del piso (rama `fix/or-machine-room-in-floor`, sin compilar en Linux)

Cambio: la sala deja de ser una vista aparte (fuera `Section.machineRoom`, `LiveMachineRoomScreen` y `LiveStore.machineRoom`) y
pasa a ser una sala del piso más bajo de cada proyecto, con solo lo suyo (`MachineRoom.scoped(to:)`; el agente publica lo mismo
en `projects[].machine_room`). Doradas regeneradas: `ui-fixture.state.json`, `office/office-fixture.state.json` (ganan
`projects[].machine_room`) y nueva `machine-room-fixture.rooms.json` (copiada a `Tests/ChopshopNativeTests/Resources/`).

- [ ] `swift build` en `apps/mac` y `apps/mac/native` (tocado: `MachineRoomModel`, `MachineRoomView`, `MachineRoomSnapshots`,
      `FloorPlan`, `FloorRender`, `FloorOfficeView`, `FloorSnapshots`, `CityOfficeFixture`, `LiveStore`, `ChopshopUI/Model` y
      `Views`). Puntos a mirar: `fnmatch` en `SubscriptionStatus.serves` (Darwin vía Foundation), literales de `FloorFixture`
      (si el type-checker tarda, partirlos más), `FloorPanelBackground` (sacado de `FloorInspector`).
- [ ] `swift test` en `apps/mac`: nuevos `FloorPlanTests.testMachineRoom*`/`testAgentPerProjectRoomWins`,
      `MachineRoomTests.testScopedToProject`/`testSubscriptionServesGlobs`, `OfficeEquivalenceTests.testPerProjectRoomMatchesPythonScope`;
      cambiado `testLiveStoreFeedsMachineRoom` (lee `store.state.machineRoom`).
- [ ] Capturas: `ChopshopSnap <salida> floor` → `floor-producto-*.png` con la sala a la derecha de los departamentos (armarios de
      repo-principal en rojo y Engine CX en ámbar, sin el repo de `otro`) y `floor-machine-room-selected.png` con el panel;
      `city-office` → `city-office-zoom-producto.png` (la sala aparece en el zoom); `machine-room` → panel de Awesome GB.
- [ ] En la app: la barra lateral ya no tiene «Sala de máquinas»; Ciudad → clic en el piso más bajo de un proyecto → la sala
      está en el piso; hover en un armario (tooltip con luz y runs en curso), clic → panel con el repo elegido; clic en otro
      armario cambia el repo; Esc lo cierra; un repo en rojo sale en la barra «Atención» y al pulsarlo enfoca su armario.
- [ ] Los pisos superiores del proyecto no tienen sala; un proyecto sin `office` sigue abriendo el Grafo (sin sala).

## 8. Salas de máquinas opcionales, 0..N por proyecto (rama `fix/or-machine-rooms-n`, sin compilar en Linux)

Cambio: ya no hay exactamente una sala en el piso más bajo; cada proyecto declara 0..N en su perfil (`machine_rooms:`, ver
`docs/plans/office-redesign.md` §4). Modelo: `MachineRoomConfig`, `LiveState.Office.machineRooms`, `MachineRoom.name/floor` y
`scoped(to:_:)` (fuera `scoped(to:)`); `FloorPlan.machineRooms`, `FloorLayout.machines` con ids `rack:<k>:<unidad>` y
`machine:<k>` (antes `rack:<unidad>` y `machine`). Doradas regeneradas: `machine-room-fixture.jsonl` (+2 `office.changed`:
Awesome GB con dos salas, chopshop sin ninguna), `machine-room-fixture.rooms.json` (ahora `{proyecto: [salas]}`),
`office/office-fixture.*` (ganan `office.machine_rooms: []`).

- [ ] `swift build` en `apps/mac` y `apps/mac/native` (tocado: `MachineRoomModel`, `MachineRoomSnapshots`, `LiveStateOffice`,
      `OfficeFixture`, `FloorPlan`, `FloorRender`, `FloorOfficeView`, `FloorSnapshots`, `CityOfficeFixture`).
- [ ] `swift test` en `apps/mac`: `FloorPlanTests.testNoRoomsDeclaredNoRoom`/`testRoomsOnTheirFloorsHoldWhatTheProfileSays`/
      `testAgentPerProjectRoomsWin`/`testMachineRoomsLayoutCabinetsConsolesAndRows`/`testMachineRoomAlertsAndLabels`/
      `testTypedLiveStateMachineRoomsMatchJSON`, `MachineRoomTests.testScopedToProjectRoom`,
      `OfficeEquivalenceTests.testPerProjectRoomsMatchPythonScope`.
- [ ] Capturas: `floor-producto-*.png` con dos salas en Producto («SALA DE MÁQUINAS» con repo-principal en rojo, «SALA DE
      DOCS» con Engine CX en ámbar; la segunda en la fila siguiente); `city-office` con una sala en Producto y otra en Docs.
- [ ] En la app: un proyecto sin `machine_rooms:` no pinta sala; con dos, cada consola abre el panel de su sala.

## 8. Integración v0.8.1: mundo continuo + salas de máquinas 0..N (sin compilar en Linux)

`fix/or-office-layout` (mundo de un solo lienzo, panel lateral) y `fix/or-machine-rooms-n` (salas del perfil dentro de su piso)
juntas. La región aparte «SALA DE MÁQUINAS» del mundo (`MachineRoomPlan`, `WorldLayout.Kind.machines`, `lights`/`drawRack`)
desaparece: las salas salen de `FloorPlan.machineRooms` y las pinta `FloorRenderer` dentro de cada piso (losa, armarios, consola,
rótulos con el prefijo de la región). Elegir un armario (`rack:<k>:<unidad>`) o la consola (`machine:<k>`) abre su detalle en el
panel lateral (`MachineRoomDetail` en `ThreadPanel`); ya no hay `MachineRoomInspector` flotante ni barra de atención encima.
Proyectos sin `machine_rooms` en el perfil: ninguna sala (el fixture de 46 hilos ya no trae sala).

- [ ] `swift build` en `apps/mac` y `apps/mac/native`; `swift test` (`WorldLayoutTests.testMachineRoomsLiveInTheirFloor` nuevo).
- [ ] Corregido sin compilar: en `FloorRenderer.drawMachineRoom` el margen `k = 6.0` tapaba el parámetro `k: Int` (ahora `e`).
- [ ] `ChopshopSnap <salida> floor` → `floor-machine-room-selected.png`: armario resaltado en el piso (el detalle va en el panel
      lateral, que esta captura no monta); `machine-room` → panel `MachineRoomDetail`.
- [ ] En la app: oficina de Awesome GB → clic en un armario y en la consola; el panel lateral muestra la sala; «Todos los hilos»
      vuelve a la lista.
