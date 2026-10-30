# Guía para los bots de estructura (Grok) — `PUT /office/<proyecto>`

Los bots mantienen la **estructura** de la oficina (pisos, departamentos/roles, escritorios, roles permanentes, rack y
actores). No ejecutan código ni lanzan hilos, y **no borran** escritorios: lo que dejan de declarar queda retirado.
Contrato: `docs/agent-api.md` («`api_version 3`»); plan: `docs/plans/office-redesign.md`.

## Credencial

Todas las rutas exigen identidad y credencial del agente (igual que el resto de la API): en `tailscale+token`, la identidad
de Tailscale del dueño **y** una credencial de dispositivo (`chopshop pair create` → `POST /pair`) o el bearer de
`token_file`; en modo `token`, el bearer. Las identidades de solo lectura (`allowed_logins`) pueden hacer `GET` pero no `PUT`
(403). Sin credencial → 401.

## Flujo

1. `GET /office/<proyecto>` → `{rev, office, rack, structure, limits}`.
2. Edita el bloque `office` (y, si hace falta, `rack`) **completo**. Topes (`limits`): 4 pisos por proyecto, 6
   departamentos y 24 escritorios por piso, 6 escritorios por departamento, 16 pisos de proyecto por edificio (empresa).
3. `PUT /office/<proyecto>` con `Content-Type: application/json`:

```json
{"by": "Grok · Facundo", "base_rev": "<rev del paso 1>",
 "office": {"company": "Awesome GB", "half_life": "30m",
            "floors": [{"name": "Producto", "rooms": [{"role": "triage", "desks": 1, "permanent": true},
                                                      {"role": "backend", "desks": 3}]}],
            "roles": {"backend": {"match": {"title": "^\\[be\\]"}}}}}
```

4. Respuestas:
   - 200 `{changed, rev, seq, office, diff: {added, retired, reactivated}}`; se emite `office.changed {by}`.
   - 400 `{error, problems: [...]}`: los mismos mensajes que `chopshop profile check`. Corrige y reintenta.
   - 409 por `base_rev`: otro bot (o un humano) cambió el perfil; vuelve al paso 1.
   - 409 por reactivación: el cambio vuelve a declarar escritorios retirados. Solo con permiso de un humano, repite con
     `"reactivate": ["<id>", ...]`.

## Reglas

- Los ids de escritorio son `<proyecto>/<piso>/<rol>/<n>`: mover un departamento de piso o reducir `desks` retira los
  antiguos y crea otros. Prefiere añadir al final y ampliar `desks` antes que reordenar.
- `prompt_file` es una ruta relativa dentro de `~/.chopshop/automations/<proyecto>/`; la API no crea ni ejecuta scripts.
- Slugs de repos y logins reales solo en el perfil local, nunca en el repo.
- Las salas `_flex` (y los pisos `temporary` y `outsourced`) de `structure` las crea la capacidad elástica (`capacity:` del
  perfil, ver `docs/agent-api.md`): no van en el bloque `office` del `PUT`.
