# Chopshop · capa nativa (banco de pruebas)

Banco de pruebas de `ChopshopNative`, la capa nativa que **la app real** (`apps/mac`, target `ChopshopNative`) usa en macOS 26
para el detalle de proyecto en vivo. Aquí se ve con datos de prueba (`Fixtures`) o reproduciendo `ui-fixture.jsonl` (`FixtureStream`).

- **Oficina isométrica** (`IsoOfficeView`): salas por rango, escritorios por tarea, cables, barra "Atención", inspector.
- **Grafo en capas** (`GraphView`) y la vista de proyecto (`ProjectView`) con el selector Oficina / Grafo.
- **Demo de población y crecimiento** (`DemoTimeline.swift`, `DemoView.swift`): un guion de eventos (con forma de *envelope*) se aplica
  a un store y la oficina se levanta sola: salas que suben, escritorios que brotan, figuras que caminan, cables que se dibujan,
  pregunta (ámbar), tarea atascada (rojo), tareas nuevas a mitad con la cámara ajustándose. ~56 s en bucle.

Requiere **macOS 26** y **Xcode 27** (usa Liquid Glass). Es un paquete aparte de `apps/mac/Package.swift` (la app real, macOS 13 + Sparkle).

## Ciudad

La flota como ciudad isométrica (`City/`): un edificio por empresa, un piso por proyecto, una ventana encendida por hilo vivo;
pisos en ámbar (te necesita) o rojo (trabada). Clic en un piso → zoom continuo hasta que el piso se convierte en la oficina del
proyecto; Esc vuelve. Lógica pura en `CityModel`/`CityLights`/`CityCamera`/`CityTimeline` (macOS 13, con tests); vistas en
`CityView`/`CityRender` (macOS 26).

- En la app: `LiveCityScreen(store:onSelectFloor:)` es la entrada pública (la flota del `LiveStore`; `onSelectFloor` recibe el
  proyecto del piso pulsado).
- Playground: menú Ventana → **Abrir la ciudad** (⌘⇧C). "Reproducir cronología" (reloj 0,5×–4×, pausa, reiniciar, en bucle) o
  "Interactivo" (estado final, clic para el zoom).
- Datos: `Resources/city-fixture.jsonl`, generado con `python3 apps/mac/Tests/ChopshopNativeTests/tools/make_city_fixture.py`.
  `CityTimeline` fija la coreografía (~24 s: edificios que suben, rojo 8,2 s, ámbar 9,6 s, zoom 11,4 → 17,0 s, oficina).
- Capturas y vídeo deterministas (cada fotograma es `CityTimeline.frame(at: t)` con el tiempo congelado):

```sh
cd apps/mac/native
swift run ChopshopSnap /tmp/city city-keys                      # city-01-ciudad.png … city-07-claro.png
swift run ChopshopSnap /tmp/city city-video /tmp/city/city.mp4  # MP4 H.264 1400×900 a 30 fps
```

## Sala de máquinas

Tercera vista (Ciudad · Oficina · **Sala de máquinas**, `MachineRoom/`): el rack de repos (un módulo 1U por repo con su luz:
verde, ámbar parpadeante si hay runs en curso, rojo, gris sin datos) con los runs de GitHub Actions de cada uno (workflow,
disparador, rama@sha y **origen**: hilo/escritorio, automatización, bot, horario, persona), más los listeners del agente, las
automatizaciones (última ejecución, exit, próximo horario) y los webhooks salientes. Lógica pura en `MachineRoomModel.swift`
(`MachineRoomState` pliega `machine_room` con la misma regla que `agent/machine_room.py`; tests en `MachineRoomTests`); vistas en
`MachineRoomView`/`RackRender` (macOS 26).

- En la app: barra lateral → **Sala de máquinas** (`LiveMachineRoomScreen(store:)`, macOS 26).
- Datos de prueba: `Resources/machine-room-fixture.jsonl` (copia de `apps/agent/tests/fixtures/events/machine-room-fixture.jsonl`;
  su proyección dorada está en `Tests/ChopshopNativeTests/Resources/machine-room-fixture.state.json`).
- Capturas: `swift run ChopshopSnap /tmp/mr machine-room` → `machine-room-dark.png` / `machine-room-light.png`.

## Estructura

- `Sources/ChopshopNative` es un **symlink** a `apps/mac/Sources/ChopshopNative`: el mismo código que compila la app.
  Aquí se compila con plataforma macOS 26 y `-DNATIVE_PREVIEWS` (activa los `#Preview` y `FixtureStream.bundled()`, que lee
  `Resources/ui-fixture.jsonl`, copia de `apps/agent/tests/fixtures/events/ui-fixture.jsonl`). La app lo excluye.
- `Live/` = lógica pura, sin SwiftUI ni requisito de macOS 26: `JSONValue`, `Envelope`, `LiveState` (port de
  `apps/agent/chopshop/agent/projection.py`), `SSEParser`, `AgentStream` (`GET /stream`), `LiveStore` (reconexión, backoff,
  `Last-Event-ID`), `FixtureStream`, `SnapshotMapper` (proyección → modelos de la oficina), `PairingClient` y `CredentialStore`
  (Keychain). Pruebas: `apps/mac/Tests/ChopshopNativeTests` (`cd apps/mac && swift test`).
- Las vistas (`IsoOfficeView`, `GraphView`, `ProjectView`/`ProjectContent`, `LiveProjectScreen`, …) llevan `@available(macOS 26.0, *)`;
  la app las usa tras `if #available(macOS 26, *)` y en macOS < 26 se queda con la vista web. El vidrio (`glassEffect`) va tras
  `#if compiler(>=6.2)`: con un Xcode anterior a 26 cae a un sustituto plano (no probado: solo se ha compilado con Xcode 27).
- Acciones: `\.attentionActions` en el entorno (responder por `POST /answer`, abrir el hilo en T3). Sin ellas (aquí) los
  botones se ven pero no hacen nada.

## En vivo contra un agente

1. En la máquina del agente: `chopshop pair create --name "MacBook"` → código `K7QM-93XD` (10 min).
2. En la app: Ajustes… (⌘,) → Emparejamiento, pega el código. La credencial va al Llavero (`com.chopshop.agent`).
3. Abre un proyecto: el indicador de la barra pasa a **en vivo**. Sin agente: `--demo-fixture <ui-fixture.jsonl>`.

## Probarlo

```sh
open apps/mac/native/Package.swift     # Xcode 27
```

- Scheme **ChopshopPlayground** → Run → botón **Reproducir demo** en la barra de herramientas (Reiniciar dentro de la demo).
- Scheme **ChopshopNative** → Canvas → `#Preview "Oficina · demo crecimiento"` (y las vistas "Oficina · …").
- Sin Xcode: `cd apps/mac/native && swift run ChopshopPlayground`.
- Fotogramas: `swift run ChopshopSnap /tmp/snaps` (capturas) o `swift run ChopshopSnap /tmp/demo demo` (claves + secuencia a 12 fps).
