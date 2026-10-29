# Chopshop · capa nativa (banco de pruebas)

Banco de pruebas de `ChopshopNative`, la capa nativa que **la app real** (`apps/mac`, target `ChopshopNative`) usa en macOS 26
para el detalle de proyecto en vivo. Aquí se ve con datos de prueba (`Fixtures`) o reproduciendo `ui-fixture.jsonl` (`FixtureStream`).

- **Oficina isométrica** (`IsoOfficeView`): salas por rango, escritorios por tarea, cables, barra "Atención", inspector.
- **Grafo en capas** (`GraphView`) y la vista de proyecto (`ProjectView`) con el selector Oficina / Grafo.
- **Demo de población y crecimiento** (`DemoTimeline.swift`, `DemoView.swift`): un guion de eventos (con forma de *envelope*) se aplica
  a un store y la oficina se levanta sola: salas que suben, escritorios que brotan, figuras que caminan, cables que se dibujan,
  pregunta (ámbar), tarea atascada (rojo), tareas nuevas a mitad con la cámara ajustándose. ~56 s en bucle.

Requiere **macOS 26** y **Xcode 27** (usa Liquid Glass). Es un paquete aparte de `apps/mac/Package.swift` (la app real, macOS 13 + Sparkle).

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
