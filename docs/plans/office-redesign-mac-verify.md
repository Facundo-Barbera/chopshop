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
- [ ] Sala de máquinas (barra lateral, macOS 26): ámbar parpadea; chips de origen (hilo con rol · escritorio, automatización,
      bot, cron, humano); webhooks sin URL.

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
