# M1: línea base Swift (apps/mac)

Base: `origin/dev` @ 0adbe47 · Swift 6.4 (swiftlang-6.4.0.34.1) · macOS 27.2 arm64 · 2026-10-30.

## Resultado

| Paso | Resultado |
| --- | --- |
| `swift build` (debug) | OK, 0 errores |
| `swift test` antes de los arreglos | no compila (3 errores en tests) |
| `swift test` después de los arreglos | compila; ChopshopUITests 49/49; ChopshopNativeTests 128/130 (2 fallos) |
| `CHOPSHOP_APP=$PWD/dist/Chopshop.app bash build.sh` | OK: `swift build -c release`, agente incrustado (Python 3.13.18), Sparkle 2.10.1, firma ad-hoc; `codesign --verify --deep --strict` OK. Nada instalado: el resultado queda solo en `apps/mac/dist/` |

## Arreglos (fallos de compilación en tests con Swift 6.4)

- `FloorPlanTests.swift:147` y `MachineRoomTests.swift:193`: `XCTAssertEqual` sobre tuplas, que no son `Equatable`. Se separaron en aserciones sobre arrays y valores.
- `ShellModelTests.swift:188`: `testShellTaskFindsByTaskOrThread` usa `FloorFixture` (`@available(macOS 26.0, *)`). Se marcó el test con `@available(macOS 26.0, *)`.

## Fallos pendientes

- **BUG-1** `FloorPlanTests.testLayoutDependsOnlyOnStructure` (`FloorPlanTests.swift:78`): espera 3 huecos sin máquina («el retirado conserva su hueco») y hay 2. Probablemente viene de 2be7d04 («salas por rol del tamaño de sus escritorios ocupados (más uno libre)»): hay que decidir si el test está obsoleto o si el generador debe conservar el hueco del retirado.
- **BUG-2** `WorldLayoutTests.testSpotIDsAreUniqueAcrossRegions` (`WorldLayoutTests.swift:70`): hay 3 regiones pero solo 2 IDs de región distintos. Al añadir `FloorFixture.floor`, su ID choca con el de un piso de `ProjectOfficeFixture`.

## No cubierto

- La firma con Developer ID (`release/assemble-app.sh` + `release/sign-app.sh`, ver `docs/mac-local-install.md`) no se ejecutó: necesita `UPDATES_BASE_URL`, `SPARKLE_ED_PUBLIC_KEY` y la identidad del llavero. `build.sh` firma solo ad-hoc.
- La build Release deja 8 warnings (capturas `weak self`, `var` sin mutar), sin errores.
