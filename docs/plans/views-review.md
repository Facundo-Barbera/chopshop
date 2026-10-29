# Revisión de vistas: qué conservar y cómo llevarlo a la oficina

**Rama `fix/views-polish`.** Cambio de alcance: la interfaz base se rediseña alrededor de la oficina (otro hilo), así que
estas vistas **no se pulen en código**. Una primera pasada de pulido (paneles planos, color solo para atención, barra
lateral y Ajustes) se subió y se revirtió en esta misma rama; queda en el historial (`18c485c`) por si algo sirve.

Fuera de alcance: oficina, ciudad, piso y Grafo (otros hilos) y la lista de máquinas de Ajustes (otro hilo).

Criterio para el destino: macOS sobrio (colores neutros, color solo para lo que pide atención, vidrio real solo en
barra lateral/barra de herramientas/superposiciones, sin ruido, aprovechando ventanas grandes). La oficina es la
pantalla principal; lo demás se vuelve **panel** (inspector lateral), **superposición** (popover u hoja sobre la
oficina) o **control dentro de la oficina** (algo en un escritorio, en la pared o en el vestíbulo).

Hoy cinco de estas vistas son HTML en un `WKWebView` (`apps/ui/src/App.jsx`) alimentado por `GET /snapshot`; la
oficina nativa lee `GET /stream` (`LiveState`). Al migrar, todo debe salir de `LiveState` y la web puede retirarse.

## Resumen (`overview`)

**Para qué:** de un vistazo, qué corre y qué necesita una decisión, en todos los proyectos.

**Debe sobrevivir**
- Cifras: corriendo (y en cola), preguntas, permisos, completadas.
- La lista «necesita atención» con respuesta directa (opciones de la pregunta) y «abrir en T3» para permisos.
- Lo último respondido (qué se respondió y quién: humano o bot).

**En la oficina**
- La oficina *es* el resumen: corriendo = escritorios ocupados; atención = escritorios marcados. Las cifras pasan a una
  línea en la barra de herramientas o al subtítulo de la ventana (sin tarjetas grandes).
- «Necesita atención» → **bandeja de atención** como superposición (popover desde un botón de la barra con contador),
  la misma lista de `AttentionButtons` que ya usa la oficina, con todos los proyectos.
- En la ciudad, cada edificio/piso lleva el contador de atención.
- Se elimina como vista propia.

## Preguntas (`questions`)

**Para qué:** responder lo que preguntó un hilo; el hilo sigue al enviar (`POST /answer`).

**Debe sobrevivir**
- Pregunta, opciones, **respuesta libre** (texto propio), estado «en cola / enviada / falló» con el error.
- Distinguir pregunta, permiso (solo «abrir en T3»: no hay API), «necesita humano» (escalada: a quién y por qué) y
  «esperando al bot».
- Contexto: tarea, proyecto, máquina, prompt resumido, tiempo esperando.
- Historial de respondidas con la opción y quién respondió.

**En la oficina**
- Control en el escritorio: el agente con pregunta muestra un globo; al pulsarlo, popover con la pregunta, opciones y
  campo libre (falta el campo libre en `AttentionButtons`).
- El contexto y el historial de esa tarea van en el **inspector** del escritorio.
- La lista global de pendientes es la bandeja de atención (ver Resumen). Historial global: sección plegable de la
  bandeja o del vestíbulo («respondidas hoy»).
- Notificación del sistema (`UNUserNotification`) con acciones para las opciones: responder sin abrir la app.

## Actividad (`events`)

**Para qué:** registro de lo que ocurrió (pregunta, permiso, tarea/lote/hilo terminado o fallido, reacciones, T3 caído,
alertas de máquina) y si el webhook se entregó.

**Debe sobrevivir**
- Línea de tiempo con hora y «hace…», filtros (todo / preguntas / tareas / lotes).
- Estado de entrega de webhooks por suscripción, sobre todo **los fallos**.
- Del evento, saltar a su tarea (detalle) o lote.

**En la oficina**
- **Panel lateral** «Actividad» (inspector plegable a la derecha) con `LiveState.recent`; filtros como control
  segmentado en su cabecera. Al seleccionar un evento, la cámara va al escritorio de la tarea.
- Momentos breves en la escena: un evento nuevo hace un gesto en el escritorio (terminó, falló) sin texto.
- Los fallos de webhook son configuración/infraestructura: van a la Sala de máquinas (panel de webhooks) con un
  indicador; no hace falta mostrar «entregado» en cada fila.

## Reacciones (`reactions`)

**Para qué:** ver qué hicieron las reglas del perfil ante cada evento: nivel 1 (Chopshop solo: settle, reintento),
nivel 2 (despertar al bot por webhook), nivel 3 (escalar a una persona), y si se resolvió.

**Debe sobrevivir**
- Escaladas abiertas a humano con respuesta directa (son preguntas con prioridad).
- Por reacción: cuándo, tarea, disparador (tarea terminada/falló/sin progreso/pregunta), acción, nivel, resultado
  («resuelta por …» o «esperando al bot»).

**En la oficina**
- Escaladas abiertas → bandeja de atención, primeras y con «a quién se escaló y por qué».
- Esperando al bot → estado visible en el escritorio (el bot «está en la mesa»), sin color de atención.
- El historial de reacciones de una tarea → sección del inspector del escritorio.
- El historial global → filtro «Reacciones» del panel de Actividad (una tabla con el nivel como columna, no tres
  columnas casi vacías).
- Las reglas en sí (qué dispara qué) → Sala de máquinas, junto a automatizaciones y webhooks.

## Lotes (`batches`) y Proyecto (`project`, vista web clásica)

**Para qué:** lotes del orquestador (`fanout`) y lotes sintéticos de hilos sueltos; por lote, sus tareas con estado; por
tarea, resultado, diff propuesto, respuestas, error, prompt y acciones.

**Debe sobrevivir**
- Progreso por lote (n/m) y estado por tarea (corriendo, pregunta, permiso, completada, falló, omitida, en cola).
- Detalle de tarea: resultado, **diff**, preguntas respondidas, error, motivo de omisión, prompt.
- Acciones: **cerrar hilo (settle)** y **abrir hilo en T3**.

**En la oficina**
- Tarea = escritorio; su detalle completo (resultado, diff, respuestas, settle, abrir en T3) → **inspector** del
  escritorio. El diff, en una hoja propia si es largo.
- Lote = agrupación visual en el piso (resaltar sus escritorios al elegirlo) y una lista compacta «Lotes» en el
  inspector del piso con la barra de progreso.
- Los lotes terminados salen de la escena; quedan en el inspector del piso («terminados»).
- Se elimina como vista propia; «Proyecto» ya lo cubre `LiveProjectScreen` (la vista web clásica queda solo como
  respaldo de agentes sin emparejar mientras existan).

## Barra lateral: proyectos y máquinas

**Para qué:** navegar entre vistas, proyectos y máquinas; ver de un vistazo qué proyecto pide atención y la carga de
cada máquina; estado de la conexión con los agentes.

**Debe sobrevivir**
- Por proyecto: corriendo y preguntas pendientes (indicador de atención).
- Por máquina: alcanzable o no (y por qué), CPU y RAM recientes.
- Estado de la conexión (conectado / parcial / caído / sin configurar) y del stream en vivo.

**En la oficina**
- Proyectos → los pisos de la ciudad/edificio; la barra lateral se reduce a la lista de pisos (o desaparece si la
  ciudad navega). El indicador de atención va en el piso.
- Máquinas → la Sala de máquinas (ya muestra el rack); la carga, en un indicador pequeño por máquina allí o en la barra
  de herramientas. Quitar la lista de máquinas de la barra lateral (duplicada).
- Conexión y stream → **un solo** indicador en la barra de herramientas (hoy hay tres: pie de la barra lateral,
  `LiveIndicator` y subtítulo «actualizado …»).
- La versión de la app (hoy «v0.6» fijo en el pie, con la app en 0.8.0) → menú Acerca de.

## Ajustes

**Para qué:** URL del agente (`agent_url` de `[app]`) y emparejamiento de este Mac con cada agente (credencial en el
Llavero).

**Debe sobrevivir**
- Campo de URL con validación y aviso si `CHOPSHOP_APP__*` pisa el archivo; ruta del config.
- Emparejar/desemparejar por agente (lo rediseña otro hilo: lista de máquinas).
- Apertura automática si no hay agente o con el primer 401.

**En la oficina**
- Escena `Settings` propia (⌘, abre una ventana, no una hoja) con `Form` agrupado: «Conexión» y «Emparejamiento».
- El primer arranque sin agente o sin emparejar → superposición sobre la oficina vacía (ya existe `PairingScreen` en
  el detalle del proyecto); no hace falta abrir Ajustes a la fuerza.

## Problemas transversales

1. **Modo oscuro forzado** (`.preferredColorScheme(.dark)` en `App.swift` y `SettingsView`; CSS solo oscuro). Lo nativo
   sigue la apariencia del sistema.
2. **Ventana transparente** (`WindowGlass` + degradado `GlassBackdrop`): el contenido deja ver el escritorio. La oficina
   ya usa `windowBackgroundColor`; quitarlo al retirar la web.
3. **Exceso de color** en la web: rosa, violeta, menta, ámbar, naranja, verde, azul para estados. En lo nuevo: naranja
   = te necesita, rojo = falló, acento = corre, gris para el resto.
4. **Animaciones constantes** (puntos que laten en filas que corren, barra lateral, barra de herramientas). Solo para
   atención, y con moderación.
5. **Metadatos repetidos** en cada fila (`proyecto · lote · tarea · host`): al inspector.
6. **Iconos de texto** (`? ! ✓ ⚡ ◆`): SF Symbols.
7. **Vista web Máquinas** (al pulsar una máquina): anillos y gráficas de colores; fundir con la Sala de máquinas.

## Faltantes en la oficina para retirar la web

- Respuesta libre en `AttentionButtons` (hoy solo opciones).
- Settle de un hilo terminado (`POST /settle`) desde el inspector.
- Diff y resultado completo de la tarea en el inspector.
- Historial de respondidas y de reacciones por tarea (`LiveState.answered`; reacciones del stream).
- Panel de Actividad sobre `LiveState.recent` con filtros y estado de webhooks.
- Bandeja de atención global (todos los proyectos), con escaladas primero.
- Lotes: agrupación y progreso en el piso.
