# Chopshop · capa nativa (maquetas)

Maquetas SwiftUI nativas con datos de prueba (`Fixtures`), sin motor ni red. Todavía no están conectadas al agente.

- **Oficina isométrica** (`IsoOfficeView`): salas por rango, escritorios por tarea, cables, barra "Atención", inspector.
- **Grafo en capas** (`GraphView`) y la vista de proyecto (`ProjectView`) con el selector Oficina / Grafo.
- **Demo de población y crecimiento** (`DemoTimeline.swift`, `DemoView.swift`): un guion de eventos (con forma de *envelope*) se aplica
  a un store y la oficina se levanta sola: salas que suben, escritorios que brotan, figuras que caminan, cables que se dibujan,
  pregunta (ámbar), tarea atascada (rojo), tareas nuevas a mitad con la cámara ajustándose. ~56 s en bucle.

Requiere **macOS 26** y **Xcode 27** (usa Liquid Glass). Es un paquete aparte de `apps/mac/Package.swift` (la app real, macOS 13 + Sparkle).

## Probarlo

```sh
open apps/mac/native/Package.swift     # Xcode 27
```

- Scheme **ChopshopPlayground** → Run → botón **Reproducir demo** en la barra de herramientas (Reiniciar dentro de la demo).
- Scheme **ChopshopNative** → Canvas → `#Preview "Oficina · demo crecimiento"` (y las vistas "Oficina · …").
- Sin Xcode: `cd apps/mac/native && swift run ChopshopPlayground`.
- Fotogramas: `swift run ChopshopSnap /tmp/snaps` (capturas) o `swift run ChopshopSnap /tmp/demo demo` (claves + secuencia a 12 fps).
