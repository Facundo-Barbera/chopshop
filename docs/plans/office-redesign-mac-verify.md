# Verificación en el Mac: rediseño de la oficina (integración de las ramas `feat/or-*`)

Rama: `feat/office-redesign` (fase 0 + las 13 ramas `feat/or-*` integradas). Todo el Swift se escribió y se integró **sin
toolchain** (contabo-dev no tiene Swift): nada de lo de abajo está compilado ni ejecutado. El agente (Python) sí: suite
completa en verde en contabo-dev.

## 1. Compilar

- [ ] `cd apps/mac && swift build` (app) y `cd apps/mac/native && swift build` (banco de pruebas, `NATIVE_PREVIEWS`).
- [ ] Puntos de la integración con más riesgo de no compilar:
  - **Dos tipos `MachineRoom`**: `LiveState.MachineRoom` (anidado, JSON, `Live/LiveStateOffice.swift`; lo usan `LiveState`,
    `LiveStateNames`, `OfficeFixture`, `OfficeTests`) y el `MachineRoom` de nivel superior (`MachineRoom/MachineRoomModel.swift`;
    lo usan `LiveStore`, `MachineRoomView`, `MachineRoomSnapshots`, `MachineRoomTests`). Dentro de `LiveState` el anidado tapa al
    otro a propósito. Si el compilador se queja de ambigüedad, renombrar el anidado (p. ej. `MachineRoomJSON`).
  - `City/CityOffice.swift`: dos `init?` sobrecargados (`JSONValue.Object?` y `LiveState.Office?`); `CityModel.build` y
    `CityOfficeTests` pasan `LiveState.Project.office` (tipado).
  - `ChopshopUI/Views.swift`: `LiveMachineRoomScreen(store:) { PairingScreen() }` (el init pide `unpaired`).
  - `MachineRoom/MachineRoomSnapshots.swift`: `Bundle.module` + `FixtureStream.parse` + `MachineRoom.fold`.

## 2. Doradas (si cambia el contrato o un fixture)

```sh
cd apps/agent && CHOPSHOP_UPDATE_GOLDEN=1 python3 -m unittest discover -s tests && cd ../..
python3 apps/mac/Tests/ChopshopNativeTests/tools/make_golden.py            # ui-fixture.state.json de la app
cp apps/agent/tests/fixtures/office/office-fixture.{jsonl,state.json} apps/mac/Tests/ChopshopNativeTests/Resources/office/
cp apps/agent/tests/fixtures/events/machine-room-fixture.{jsonl,state.json} apps/mac/Tests/ChopshopNativeTests/Resources/
cp apps/agent/tests/fixtures/events/machine-room-fixture.jsonl apps/mac/Sources/ChopshopNative/Resources/
```

## 3. `swift test`

- [ ] `ContractTests` / `LiveStateTests` (dorada `ui-fixture.state.json` regenerada: v3 con `lobby` y `machine_room`).
- [ ] `OfficeEquivalenceTests` (nuevo en la integración): oficina, vestíbulo y sala de máquinas == `projection.fold` de Python.
- [ ] `OfficeTests` (incluye la tabla `office/halflife.json` de semivida), `CityOfficeTests`, `CityTests`, `FloorPlanTests`,
      `MachineRoomTests`, `StreamTests`, `SnapshotMapperTests`.

## 4. Capturas (`docs/screenshots.md`)

- [ ] `ChopshopSnap <salida> machine-room` → `machine-room-dark.png` / `-light.png`: listeners (t3watch caído), scripts, y el
      rack de Awesome GB con **dos módulos**: repo principal (rojo, 3 runs: hilo, cron, bot) y Engine CX (ámbar, run de
      automatización en cola). La vista calcula "hace X" con el reloj real: el texto relativo cambia entre capturas.
- [ ] Ciudad con varios pisos por proyecto y vestíbulo en planta baja (escena de `CityOfficeTests`).
- [ ] Previews de `Office/FloorOfficeView.swift` (piso Producto, triage seleccionado, vestíbulo).
- [ ] Ciudad: clic en un piso de un proyecto con `office` → zoom continuo que acaba en `FloorOfficeView` de **ese** piso (etiquetas
      y barra de atención iguales durante el zoom y al montarse); un proyecto sin `office` sigue abriendo la vista Grafo.

## 5. Comportamiento a mirar a ojo

- [ ] Ciudad: un proyecto con `office` ocupa hasta 4 pisos consecutivos; planta baja = vestíbulo (hilos sin rol); empresa desde
      `office.company` y `CompanyDirectory` solo como respaldo; proyectos sin `office` siguen en un piso.
- [ ] Piso (`FloorOfficeView`): departamentos por rol, escritorios fijos, ocupante con opacidad de semivida (T½ del perfil,
      ×2 si falló, sale bajo 0,1), retirado en gris, triage permanente "dormido" con su lámpara y notas pendientes.
- [ ] Sala de máquinas (barra lateral, macOS 26): ámbar parpadea; chips de origen (hilo con rol · escritorio, automatización,
      bot, cron, humano); webhooks sin URL.

## 6. Huecos conocidos (no son de compilar)

- `FloorOfficeView` ya se monta al hacer zoom a un piso desde la Ciudad (rama fix/or-floor-view): `CityView` la alimenta con
  `FloorPlan.floors(in: LiveState, …)` (el `office` tipado, sin JSON crudo), el zoom se encuadra con `FloorLayout` y el piso
  elegido (no solo el primero del proyecto) se abre por su `CityFloor.id`. Proyectos sin `office` siguen abriendo `IsoOfficeView`.
  `onInspect` (→ `POST /touch`) queda expuesto en `CityView(state:…)` pero nadie lo cablea aún. El vestíbulo no tiene zoom.
- `IsoScene`/`IsoOfficeView` siguen con salas por rango de dependencias (modo Grafo); la oficina por departamentos vive en
  `Office/` aparte.
