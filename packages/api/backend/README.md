# Contratos del backend (v2)

Schemas JSON (draft 2020-12, subconjunto) y fixtures de `docs/plans/auth-backend.md` §5 (HTTP) y §5.8 (WebSocket v2).
Los valida `python3 tools/contract_audit.py` (o `--backend` para solo esta parte) con un validador propio en stdlib.

## Organización

- `common.schema.json`: tipos base (`uuid`, `time`, tokens, enums) y entidades (`user`, `session`, `invitation`, `machine`,
  `workspace`, `project`, `role`, `audit_entry`, `part`…). `error.schema.json`: error de §5.1 (HTTP, SSE y WS; `close` solo en
  WS/SSE).
- Una carpeta por dominio (§11.1): `ops`, `idn`, `mch`, `wsp`, `str`, `cty`, `hub`.
- HTTP: `<ruta>.<método>.<request|response>.schema.json`, donde `<ruta>` es la ruta sin `/v1/`, con `/` → `-` y `{id}` →
  `id`. Ej.: `POST /v1/auth/login` → `idn/auth-login.post.request`; `PUT /v1/workspaces/{id}/campus` →
  `wsp/workspaces-id-campus.put.request`. Las rutas sin cuerpo (`204`) no tienen schema.
- WebSocket v2: `hub/ws-<type>.schema.json` (`sync.ack` → `ws-sync-ack`). SSE de `/v1/stream`: `cty/stream-<evento>`; los
  eventos `snapshot`/`event` usan `hub/ws-snapshot`/`hub/ws-event` y `error` usa `error.schema.json`.
- Fixtures: `<dominio>/fixtures/<schema>[.<variante>].json` deben validar; `<dominio>/fixtures/invalid/…` deben fallar.
  Cada schema tiene al menos una fixture válida.

## Palabras clave admitidas

`type`, `enum`, `const`, `pattern`, `minLength`, `maxLength`, `minimum`, `maximum`, `items`, `minItems`, `maxItems`,
`uniqueItems`, `properties`, `required`, `additionalProperties`, `$ref`, `oneOf` (más `$schema`, `$id`, `title`,
`description`, `$defs`). Cualquier otra hace fallar la auditoría. Las fechas de la API son ISO-8601 UTC con milisegundos
(`time`); los frames del agente aceptan milisegundos opcionales (`ts`).
