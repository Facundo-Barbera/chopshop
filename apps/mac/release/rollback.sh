#!/usr/bin/env bash
# Retira UNA versión del feed de Sparkle sin tocar las demás.
#   rollback.sh <versión>            versión corta, p. ej. 1.2.3 (sin la v)
# Env: ROLLBACK_DRY_RUN=true|false (por defecto true: calcula y valida, no publica),
#      KEEP_FILES=true|false (false: mueve el zip y sus deltas a retired/; nunca se borran),
#      además las de appcast.sh y r2.sh.
# Orden seguro: 1) regenera el feed sin esa versión (la firma el mismo generate_appcast), 2) publica el
# appcast, 3) recién entonces mueve los archivos. Los usuarios que YA instalaron la versión mala no
# retroceden (Sparkle solo va hacia adelante): publica un release corregido con build mayor.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "uso: rollback.sh <versión> (p. ej. 1.2.3, sin la v)"
DRY="${ROLLBACK_DRY_RUN:-true}"
KEEP="${KEEP_FILES:-false}"

work="$(mktemp -d)"
trap 'rm -rf "$work" "$work.retired"' EXIT
bash "$HERE/r2.sh" pull "$work"
[ -f "$work/appcast.xml" ] || die "no hay appcast publicado: nada que retirar"

info="$(python3 -I "$HERE/appcast.py" find --appcast "$work/appcast.xml" --version "$VERSION")"
remaining="$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["remaining"])')"
files="$(printf '%s' "$info" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["files"]))')"
[ "$remaining" -ge 1 ] || die "retirar $VERSION dejaría el appcast vacío; publica primero un release sano"
log "se retirará $VERSION; archivos asociados:"
printf '%s\n' "$files" | sed 's/^/  /'

mkdir -p "$work.retired"
while IFS= read -r f; do
  if [ -f "$work/$f" ]; then mv "$work/$f" "$work.retired/$f"; fi
done <<< "$files"

# Regenera sin esa versión; ABSENT_VERSION hace que la validación falle si sigue en el feed
ABSENT_VERSION="$VERSION" bash "$HERE/appcast.sh" "$work"

if [ "$DRY" = true ]; then
  log "dry-run: el feed resultante es válido y no contiene $VERSION. No se publicó nada."
  summary "Rollback de \`$VERSION\` en dry-run: feed regenerado y validado, sin publicar."
  exit 0
fi

bash "$HERE/r2.sh" push-appcast "$work"
if [ "$KEEP" != true ]; then
  # shellcheck disable=SC2086
  bash "$HERE/r2.sh" retire $files
fi
bash "$HERE/r2.sh" purge
bash "$HERE/r2.sh" verify "$work"
summary "Rollback de \`$VERSION\` publicado. Quienes ya lo instalaron necesitan un release nuevo con build mayor."
log "rollback de $VERSION completado"
