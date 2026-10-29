# Plan: personalización de empresas y oficinas (identidad por empresa, proyecto y piso)

**Estado: diseño para la próxima versión (después de 0.8.0), rama `feat/office-personalization`. El prototipo del agente
(fase 1: perfil, resolución, `/state`) ya está en la rama; la app aún no pinta nada nuevo.** Parte de
`docs/plans/office-redesign.md`: un edificio por empresa, pisos por proyecto, departamentos por rol.

Hoy todos los edificios y pisos se ven iguales: la ciudad solo distingue empresas por posición y etiqueta, y la oficina
solo cambia de color para lo que pide algo (atención, trabado). El objetivo es que **cada oficina y cada piso se
reconozcan de un vistazo** (ozom no se parece a iAware, y el piso de Datos de ozom no se parece al de Producto) sin
perder el aspecto nativo y sobrio de macOS.

## Principios

1. **Personalidad por matices y materiales, no por color.** Un acento por empresa, siempre apagado; el resto son
   materiales (suelo, paredes, muebles), forma del edificio y temperatura de la luz.
2. **El estado manda.** Ámbar (corre/cola), rojo (trabado) y el aviso de atención siguen siendo los únicos colores
   fuertes. El acento nunca se usa para estado ni compite con él (superficies pequeñas, opacidad baja).
3. **Funciona sin configurar.** Lo que el perfil no declara se **deriva** de forma determinista del nombre de la empresa
   (y del proyecto y del piso para la variación). Dos empresas sin `brand` ya se ven distintas; declarar solo fija.
4. **Local y sin versionar.** Todo vive en los perfiles por proyecto (`~/.chopshop/profiles/<proyecto>.yaml`) y los logos
   en `~/.chopshop/brand/`. En el repo solo ejemplos (`examples/profiles/ozom-gv.example.yaml`).
5. **Aditivo.** `api_version` sigue en 3; los campos nuevos son opcionales y un cliente que no los conoce pinta como
   hoy. `state == fold(apply, sobres)` sigue valiendo: la identidad viaja en `office.changed`.
6. **El agente resuelve, la app pinta.** La herencia empresa → proyecto → piso, los valores derivados y la contención
   del acento se calculan en una sola función pura (`agent/identity.py`); la app no reimplementa reglas, solo traduce
   nombres de material/estilo a su render.

## Modelo de datos

### Perfil local (bloques nuevos, todos opcionales)

```yaml
project: ozom-gv
office:
  company: ozom
  brand:                       # identidad de la EMPRESA (ver «Fusión entre perfiles»)
    name: ozom                 # nombre visible (por defecto, company)
    accent: teal               # nombre de la paleta o #rrggbb (se contiene solo)
    monogram: oz               # 1-3 letras/números (por defecto, iniciales)
    logo_file: ozom/logo.svg   # relativo a ~/.chopshop/brand/ (.svg, .png, .pdf)
    building: {style: brick, roof: garden}
    materials: {floor: oak, walls: plaster, furniture: walnut}
    lighting: warm
  look:                        # sobrescritura del PROYECTO: accent, materials, lighting
    materials: {floor: terrazzo}
  floors:
    - name: Datos
      look: {accent: slate, lighting: cool, materials: {furniture: steel}}   # sobrescritura del PISO
      rooms: [...]
```

Vocabulario cerrado (lo valida `chopshop profile check` y `PUT /office`):

| clave | valores |
|---|---|
| `accent` | `graphite`, `slate`, `indigo`, `teal`, `sage`, `olive`, `ochre`, `clay`, `rose`, `plum`, o `#rrggbb` |
| `building.style` | `glass`, `brick`, `concrete`, `timber`, `stone`, `metal` |
| `building.roof` | `flat`, `terrace`, `sawtooth`, `garden`, `antenna` |
| `materials.floor` | `oak`, `walnut`, `ash`, `concrete`, `terrazzo`, `carpet`, `tile`, `cork` |
| `materials.walls` | `white`, `plaster`, `brick`, `timber`, `glass`, `concrete` |
| `materials.furniture` | `oak`, `walnut`, `white`, `black`, `steel` |
| `lighting` | `warm`, `neutral`, `cool` |

Qué se puede sobrescribir en cada nivel:

| nivel | dónde | claves |
|---|---|---|
| empresa | `office.brand` | `name`, `accent`, `monogram`, `logo_file`, `building`, `materials`, `lighting` |
| proyecto | `office.look` | `accent`, `materials`, `lighting` |
| piso | `office.floors[i].look` | `accent`, `materials`, `lighting` |

Nombre, monograma, logo y edificio son **solo de empresa**: un edificio tiene una fachada. Un proyecto o un piso
cambian el interior (y el acento de su franja en la fachada, ver abajo).

**Contención del acento.** Un hex se pasa a HLS y se acota: saturación ≤ 0,45 y luminosidad entre 0,32 y 0,62, con el
tono intacto (`#ff0000` → un rojo ladrillo apagado). La paleta con nombre ya cumple el tope. La app aclara el acento en
modo oscuro (misma regla en Swift, tabla compartida en la fase 2).

**Fusión entre perfiles.** Una empresa no tiene archivo propio: su `brand` es la fusión de los `office.brand` de todos
los perfiles con la misma `company` (por clave hoja, p. ej. `building.roof`). Si dos perfiles dan valores distintos a
la misma clave, `profile check` (y un `PUT /office` que lo provoque) lo reporta como problema del edificio, igual que el
tope de pisos; mientras tanto gana el proyecto de nombre menor para que el render sea estable. Lo normal es declararlo
en un solo perfil por empresa.

**Derivados.** Sin `brand`, `sha1(empresa)` elige acento, estilo, tejado y materiales base dentro del vocabulario;
`variant = sha1(proyecto/piso) mod 4` da a cada piso una variación sutil (veta, alfombra, plantas) aunque nadie declare
nada. Con los nombres actuales salen, p. ej., Personal = índigo/hormigón/antena, iAware = oliva/hormigón/terraza,
ozom = grafito/hormigón/jardín, Bixku = oliva/ladrillo/plano, Awesome GB = arcilla/madera/diente de sierra. Las
colisiones se resuelven declarando `brand` (ver preguntas abiertas).

### `GET /state` y `office.changed` (aditivo)

`layout.structure()` gana `identity` (proyecto) y `floors[].identity` (piso); como `office.changed` es la estructura
completa, la identidad viaja con él y `projection.apply` la copia. Si cambia un `brand`/`look`, la estructura cambia y
el agente reemite `office.changed` (mismo mecanismo de `meta office_struct:*`).

```json
"office": {"company": "ozom", "half_life_s": 1800,
  "identity": {"name": "ozom", "monogram": "oz", "logo": "/brand/ozom/logo",
               "accent": {"name": "teal", "hex": "#4b7f82"},
               "building": {"style": "brick", "roof": "garden"},
               "materials": {"floor": "terrazzo", "walls": "plaster", "furniture": "walnut"},
               "lighting": "warm"},
  "floors": [{"index": 1, "name": "Datos", "rooms": ["..."],
              "identity": {"accent": {"name": "slate", "hex": "#5b6b7c"},
                           "materials": {"floor": "terrazzo", "walls": "plaster", "furniture": "steel"},
                           "lighting": "cool", "variant": 2}}]}
```

- `identity` es **efectiva** (ya resuelta): el cliente no mira el perfil ni hereda nada.
- `accent.hex` siempre viene (contenido); `accent.name` es `null` si el perfil dio un hex.
- `logo` es una ruta relativa del agente (`GET /brand/<empresa>/logo`, fase 2) o `null`; la app usa el monograma
  mientras no haya logo o falle la descarga.
- Sin `identity` en el sobre (agente viejo, fixtures viejos) la proyección no añade la clave.

### API nueva (fase 2)

- `GET /brand/<slug>/logo`: sirve `~/.chopshop/brand/<logo_file>` de la empresa (credencial de dispositivo, igual que
  `/state`; `ETag` por hash; ≤ 256 KB; solo `.svg/.png/.pdf`; ruta resuelta dentro de `~/.chopshop/brand/`, nunca
  fuera). SVG se rasteriza en la app (sin scripts).
- `PUT /office/<proyecto>` ya acepta `brand`/`look` (son parte del bloque `office`) y valida igual que `profile check`.

## Cómo se pinta

### Ciudad (`City/CityRender.swift`, `CityModel.swift`)

- `CityModel.build` toma el nombre y orden de empresas de `identity.name` (con `CompanyDirectory.standard` como
  respaldo, como hoy con `office.company`). `CityBuilding` gana `identity` (de la empresa; todos los proyectos del
  edificio traen la misma por la fusión).
- **Fachada por `building.style`** (`drawBuilding`/`ribbon`): solo cambian textura y proporción, en grises del
  `CityPalette` actual:
  - `glass`: muros cortina, montantes finos, reflejo frío leve;
  - `brick`: tono cálido desaturado, ventanas más estrechas con dintel;
  - `concrete`: liso, bandas horizontales marcadas;
  - `timber`: lamas verticales finas;
  - `stone`: base más alta y pesada, ventanas hundidas;
  - `metal`: paneles con juntas, ventanas en franja.
- **Tejado por `building.roof`** (`drawRoof`): plano, terraza con barandilla, diente de sierra, jardín (verde apagado)
  o antena.
- **Acento** en superficies pequeñas: placa con el monograma (o logo) en la planta baja/vestíbulo, una línea fina en la
  cornisa y un punto en la píldora de la etiqueta del edificio. Cada piso de proyecto lleva su acento de piso como
  filete de 1 px en el forjado (así un piso con `look.accent` se distingue en la fachada).
- Las ventanas siguen siendo **estado** (neutra, ámbar, roja): el acento no tiñe ventanas.

### Piso / oficina (`Office/FloorRender.swift`, `FloorPlan.swift`)

- `drawFloor`: material de suelo como textura sutil (veta de madera, juntas de baldosa, moteado de terrazo/corcho, liso
  de hormigón/moqueta) a ±4 % de luminosidad sobre el gris actual; `variant` cambia dirección de veta, alfombras y
  plantas.
- `drawRoom`: paredes por `materials.walls` (yeso/blanco lisos, ladrillo/madera con trama fina, vidrio translúcido).
  El borde (`rim`) de los departamentos usa el acento del piso al 25 %; el borde de atención/trabado sigue igual y
  gana siempre.
- `drawDesk`: tablero por `materials.furniture`; placa del escritorio con el acento del piso.
- `lighting`: tinte ambiental global muy leve (cálido/neutro/frío, ≤ 3 %), nunca sobre los muñecos ni el estado.
- Entrada del piso: felpudo con el monograma de la empresa.

### Modo oscuro y accesibilidad

- Cada material tiene par claro/oscuro en una tabla (`IdentityPalette.swift`); el acento se aclara en oscuro con la misma
  función en Python y Swift (tabla de casos compartida, como `halflife.json`).
- Nada de la identidad lleva información: con «Aumentar contraste» o «Reducir transparencia» se baja la textura a
  liso y el acento a gris; el estado no cambia.

## Fases

| fase | entregables | hecho cuando |
|---|---|---|
| **1. Contrato y agente** (prototipo en esta rama) | `agent/identity.py` (validación, contención del acento, derivados, fusión entre perfiles, resolución por nivel); `layout.structure(…, brand)` con `identity`; `office.py`/`structure.py` pasan el brand fusionado; `projection` copia `identity`; doc de API y de sobres; ejemplo `ozom-gv.example.yaml` | `tests/test_identity.py` y la suite completa en verde en contabo-dev |
| **2. Logo y tablas compartidas** | `GET /brand/<slug>/logo`; `fixtures/office/identity.json` (casos de contención y aclarado oscuro) para Python y Swift | test de ruta (rechaza `..`, tamaño, extensión) y de la tabla en ambos lados |
| **3. Ciudad** | `CityIdentity` en `CityModel`, fachadas por estilo, tejados, placa/monograma, filete de acento por piso; capturas de fixture (`docs/screenshots.md`) | `swift test` en el Mac + capturas claro/oscuro de 4 empresas |
| **4. Piso** | materiales de suelo/paredes/muebles, `variant`, luz ambiental, placas y felpudo; `IdentityPalette.swift` | capturas de 2 pisos de la misma empresa con `look` distinto |
| **5. Edición** | `chopshop profile brand <empresa>` (muestra el brand fusionado y sus conflictos); guía para bots en `docs/office-bots.md` (los Grok pueden cambiar `look`, no `brand` sin permiso) | un bot cambia el `look` de un piso en contabo-dev |

Cada fase, rama y PR propios; nada directo a `main`. Pruebas solo en contabo-dev (agente) y en el build de Mac (app), sin
dev servers.

## Preguntas abiertas

1. **¿Dónde vive la empresa?** Propuesta: `office.brand` en cualquier perfil de la empresa, fusionado (lo pedido: todo en
   perfiles por proyecto). Alternativa más limpia: `~/.chopshop/companies/<empresa>.yaml`. ¿Seguimos con la fusión?
2. **Conflictos de `brand`**: ¿error que bloquea `profile check`/`PUT /office` (propuesta) o solo aviso?
3. **Paleta**: ¿bastan los 10 acentos apagados? ¿Hex libre (contenido) o solo paleta?
4. **Acento cercano al estado**: un acento rojizo/ámbar (`clay`, `ochre`) puede confundirse con trabado/corriendo. ¿Los
   apartamos del rango de tonos de estado o basta con que nunca toquen ventanas ni bordes de estado?
5. **Valores reales** por empresa (Personal, iAware, ozom, Bixku, Awesome GB): acento, estilo, tejado, materiales y si hay
   logo. Los derivados son un punto de partida.
6. **Logo**: ¿SVG rasterizado en la app, o solo PNG/PDF para no meter un parser de SVG? ¿Tope de 256 KB?
7. **Departamentos**: ¿hace falta `look` por departamento (rol) o con piso basta?
8. **Bots**: ¿pueden los Grok cambiar `brand` (fachada de toda la empresa) o solo `look` de proyecto/piso?
9. **Proyectos sin bloque `office`** (los que la ciudad agrupa con `CompanyDirectory`): ¿se les da identidad derivada en
   la app con la misma función (duplicada en Swift) o se exige un `office: {company: …}` mínimo en su perfil?
