# Verificación en el Mac: edificios de la ciudad (`feat/city-buildings`)

Escrito en contabo-dev **sin Swift**: nada compilado. Python sí (`pnpm --filter @chopshop/mac test` → `tools/test_city_style.py`).

Qué cambia: `City/CityStyle.swift` (nuevo, puro) da a cada edificio un `CityBuildingStyle` determinista desde la empresa
(material, ritmo de ventanas, azotea, plinto, alto de planta baja, puerta, retranqueo) y alturas/persianas por `CityFloor.id`.
`CityBuilding.style` es el gancho de la personalización (`CityBuildingStyle(seed:)` o el estilo entero). `CityRenderer` pinta
plinto con escalón, vestíbulo de vidrio con puerta y marquesina, huecos por patrón (banda/sueltos/pareados/verticales), impostas
enrasadas (sin cornisa por piso salvo la banda), terrazas con pretil y remates (máquinas, depósito, ático, mástil).
`CityHit`, `OfficeEmbedding`, etiquetas y `CityModel.bounds` usan la geometría nueva (`floorZ`, `floorHeight`, `rect`).

- [ ] `swift build` en `apps/mac` y `apps/mac/native`. Riesgos: función anidada `unit` que captura `inout g` en
      `drawRoofKit`; `Openings.init` con `case .ribbon?`; `typealias Faces` privado en firmas privadas.
- [ ] `swift test`: `CityStyleTests` (dorada `Resources/city-styles.json` == Python), `CityTests` (clic con `floorZ`),
      `CityOfficeTests`. Si cambia la derivación: `python3 apps/mac/Tests/ChopshopNativeTests/tools/city_style.py`.
- [ ] Capturas `city-keys` (oscuro y claro) y `city-office`: que se lean como edificios (entrada abajo a la izquierda, filas de
      ventanas, azotea) y no como libros; cada empresa distinta; paleta neutra, color solo en pisos ámbar/rojo.
- [ ] Vídeo/zoom: el piso elegido se ahueca en su sitio (también con retranqueo y planta baja alta); la oficina cae en la losa.
- [ ] Clic/hover: el contorno coincide con cada piso (la planta baja incluye el plinto).

## Resultado en el Mac (2026-10-29)

- `swift build` en `apps/mac` y `apps/mac/native`: compila sin cambios (ninguno de los riesgos se materializó).
- `swift test` (apps/mac): 95 tests en verde, incluidos `CityStyleTests`, `CityTests` y `CityOfficeTests`; `test_city_style.py`: 10 OK.
- Capturas offscreen (`ChopshopSnap … city-keys` y `city-office`): se leen como edificios (plinto, vestíbulo con puerta y
  marquesina, filas de ventanas, azotea con remate); paleta neutra, color solo en pisos ámbar/rojo.
- Distinción: con las sales originales 4 de 6 empresas salían `punched` (y 4 de 6 con mástil; `ribbon` nunca). Sales nuevas
  (`windows29`, `roof41`, en Swift y Python, dorada regenerada): ritmos y remates como mucho dos veces cada uno, y los cuatro
  edificios con pisos altos (Personal, ozom, Otros, Awesome GB) con ritmos distintos (pareados, banda, sueltos, verticales).
- Pendiente (no se hizo sin input real): vídeo/zoom interactivo y clic/hover a mano.
