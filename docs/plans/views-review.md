# Revisión de vistas: Resumen, Preguntas, Actividad, Reacciones, Lotes, barra lateral y Ajustes

**Rama `fix/views-polish`.** Fuera de alcance: oficina, ciudad, piso y Grafo (otros hilos) y la lista de máquinas de Ajustes
(otro hilo). Criterio: aspecto nativo y sobrio de macOS: colores neutros, color solo para lo que pide atención, vidrio
real solo donde macOS lo usa (barra lateral, barra de herramientas), sin ruido y aprovechando ventanas grandes.

## Arreglado en esta rama

Vistas web (`apps/ui`, bundle regenerado en `apps/mac/Resources/web`):

- **Sin vidrio falso en el contenido.** Los paneles eran `backdrop-filter` + sombra + brillo interior sobre un degradado;
  ahora son planos (relleno blanco al 3,5 %, borde fino, radio 10 px).
- **Color solo para atención.** Lo terminado (tareas, lotes, hilos, respondidas, «webhook entregado») va en gris; lo
  que corre, en azul; pregunta, permiso y «necesita humano», en naranja (antes rosa/violeta/ámbar/naranja mezclados);
  los fallos, en rojo. «Esperando al bot» va en gris (no es tarea del usuario). Los niveles N1/N2/N3 y las columnas de
  Reacciones van en gris; el panel «Necesita humano» ya no tiene borde rosa.
- **Chips sin cápsula**: punto + texto en gris; el texto solo toma color si el estado pide atención.
- **Solo late lo que pide atención**; lo que corre ya no parpadea.
- **Cabeceras al estilo macOS**: sin MAYÚSCULAS espaciadas (paneles, subtítulos, tablas, detalle).
- **Sin título duplicado**: la vista ya no repite en grande el título que muestra la barra de la ventana; queda la línea
  descriptiva y los controles.
- **Sin animación de entrada** al cambiar de vista desde la barra lateral.
- **Actividad**: la etiqueta de webhook solo aparece cuando falló; el icono de evento solo lleva color si es atención.
- **Resumen**: las tarjetas compactas con opciones ya no muestran el campo de respuesta libre (está en Preguntas);
  sin franja de color a la izquierda en las tarjetas.
- **Detalle con ancho de lectura** (máx. 760 px) en ventanas grandes.
- **Selección** como en las listas del sistema (relleno de acento, sin recuadro).
- **Texto obsoleto**: la pantalla de conexión hablaba de `token_file`; ahora explica Ajustes… y el emparejamiento.

Shell SwiftUI (`apps/mac/Sources/ChopshopUI`):

- **Ventana opaca**: fuera `WindowGlass` (ventana transparente que dejaba ver el escritorio) y el degradado grafito;
  el detalle usa `windowBackgroundColor`, como ya hacían la oficina y la sala de máquinas. La barra lateral conserva su
  material del sistema.
- **Barra lateral**: sin fila de logo (el título ya está en la ventana); cabeceras de sección del sistema (sin
  mayúsculas forzadas); proyectos sin punto animado (naranja si hay preguntas, acento si corre); máquinas en **una
  línea** (icono, nombre, minigráfica de CPU, %; RAM/disco en la ayuda) en lugar de tres; pie sin cápsula de vidrio y
  con la **versión real del bundle** (decía «v0.6» fijo con la app en 0.8.0).
- **Ajustes**: `Form` agrupado (secciones Conexión y Emparejamiento con pie explicativo), botones abajo fuera del
  scroll, aviso de variables de entorno con icono en lugar de «⚠︎». La lista de emparejamiento (`PairingView` por
  agente) queda igual.
- `tools/screenshots/shoot.py`: fondo gris liso (el de ventana) en lugar del degradado azul/violeta.

## Problemas mayores (sin arreglar)

1. **Modo oscuro forzado.** `App.swift` y `SettingsView` fijan `.preferredColorScheme(.dark)` y el CSS solo tiene
   colores para fondo oscuro (blancos con alfa). Una app nativa sigue la apariencia del sistema: hace falta un juego de
   variables CSS para `prefers-color-scheme: light` y quitar el forzado.
2. **Ajustes como hoja, no como ventana.** ⌘, debería abrir una escena `Settings` (ventana propia, con pestañas si
   crece), no una hoja modal sobre la ventana principal.
3. **Las cinco vistas son HTML en un `WKWebView`.** Selección, foco, flechas del teclado en listas, menús contextuales,
   tamaño de texto y desplazamiento no se comportan como en macOS. La oficina ya es nativa; lo coherente es portar estas
   vistas a SwiftUI (`List`/`Table` + inspector) y retirar la web.
4. **Tres indicadores de estado**: pie de la barra lateral (agentes), `LiveIndicator` en la barra de herramientas
   (stream, punto verde que late) y subtítulo «actualizado HH:mm:ss», más el botón Actualizar. Conviene uno solo
   (p. ej. el subtítulo) y quitar el latido.
5. **Detalle como inspector.** Preguntas, Actividad y Lotes usan rejillas fijas de 2–3 columnas proporcionales; en
   ventanas muy anchas la lista y el detalle crecen sin control. Mejor: lista a ancho fijo y detalle como inspector
   (`.inspector`) plegable.
6. **Reacciones**: tres columnas iguales, casi siempre vacías salvo una. Una sola tabla (cuándo, tarea, disparador,
   acción, nivel, resultado) aprovecha mejor el espacio.
7. **Resumen denso**: cuatro tarjetas de cifras + tres paneles + tarjetas de pregunta completas duplican Preguntas y
   Actividad. Propuesta: lista «Necesita atención» arriba y actividad reciente compacta; cifras en una sola línea.
8. **Metadatos ruidosos**: casi cada fila repite `proyecto · lote · tarea · host`. Llevarlos al detalle/inspector y
   dejar en la fila el título y el tiempo.
9. **Iconos de texto** en Actividad (`? ! ✓ ⚡ ◆`): al portar a nativo, usar SF Symbols.
10. **Vista web Máquinas** (al pulsar una máquina en la barra lateral): anillos de colores, gráficas azul/verde, puntos
    que laten; no se tocó (no estaba en la lista). Merece la misma pasada o fundirse con la Sala de máquinas.
11. **Estilos compartidos con el Grafo**: `.glass`, `.chip`, `.lvl` y `taskState` son comunes; el Grafo web hereda los
    paneles planos y los chips sin cápsula. Sus colores propios (rosa/violeta de atención, verde de «listo») siguen ahí
    y los decide el hilo del Grafo.

## Qué debe verificar el Mac

- `swift build` y `swift test` (cambian `Views.swift` y `SettingsView.swift`; se borraron `WindowGlass`,
  `GlassBackdrop` → `WindowBackdrop`, `VisualEffect`, `StatusCapsule`, `ChopLogo`/`ChopMark`, `LinkState.isLive` y
  `Sidebar.header`). `pnpm --filter @chopshop/ui test` ya pasa aquí.
- Ventana opaca: la barra lateral sigue translúcida (macOS 26 y 13–15), el detalle es gris de ventana, y la oficina y
  la sala de máquinas se ven igual encima.
- Barra lateral: cabeceras «Proyectos»/«Máquinas», filas de máquina de una línea con minigráfica legible, pie con
  «v0.8.0» en el `.app` de `build.sh` (sin versión con `swift run`).
- Ajustes: el formulario agrupado cabe en 560×460 con uno y con varios agentes; la fila de `PairingView` (campo de
  código de 150 pt + botón) no se corta dentro del `Form`; Esc cierra, Intro guarda; el texto «Guardado. Ahora
  empareja…» se ve junto a los botones.
- Capturas: `python3 tools/screenshots/shoot.py` (regenera `assets/*.png` con el bundle nuevo) y capturas de la app
  real con `--capture` de Resumen, Preguntas, Actividad, Reacciones, Lotes y Ajustes.
