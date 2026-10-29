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

## 5. Comportamiento a mirar a ojo

- [ ] Ciudad: un proyecto con `office` ocupa hasta 4 pisos consecutivos; planta baja = vestíbulo (hilos sin rol); empresa desde
      `office.company` y `CompanyDirectory` solo como respaldo; proyectos sin `office` siguen en un piso.
- [ ] Piso (`FloorOfficeView`): departamentos por rol, escritorios fijos, ocupante con opacidad de semivida (T½ del perfil,
      ×2 si falló, sale bajo 0,1), retirado en gris, triage permanente "dormido" con su lámpara y notas pendientes.
- [ ] Sala de máquinas (barra lateral, macOS 26): ámbar parpadea; chips de origen (hilo con rol · escritorio, automatización,
      bot, cron, humano); webhooks sin URL.

## 6. Huecos conocidos (no son de compilar)

- `FloorOfficeView` (rama or-mac-office) no está enganchada a la navegación: lee el `/state` crudo (`JSONValue`) y solo la usan
  sus previews/fixtures. Falta montarla al hacer zoom a un piso desde la Ciudad (y alimentarla desde `LiveState`/`LiveStore`).
- `IsoScene`/`IsoOfficeView` siguen con salas por rango de dependencias (modo Grafo); la oficina por departamentos vive en
  `Office/` aparte.
