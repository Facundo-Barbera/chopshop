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

