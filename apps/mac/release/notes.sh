#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

TAG="${1:-}"; OUT="${2:-}"; BASE="${3:-}"
if [ -z "$OUT" ] || [ -z "$BASE" ]; then die "uso: notes.sh <tag> <dir_salida> <nombre_base>  (tag vacío = dry-run, con NOTES_VERSION)"; fi
VERSION="${TAG#v}"
if [ -z "$TAG" ]; then VERSION="${NOTES_VERSION:?dry-run sin tag: falta NOTES_VERSION}"; fi
mkdir -p "$OUT/notes"
MD="$OUT/notes/$VERSION.md"

source_used=""
if [ -z "$TAG" ]; then
  printf '## Prueba (dry-run)\n- Build de CI sin firma Developer ID ni notarización; no es una release.\n' > "$MD"
  source_used="dry-run (sin tag)"
elif [ "$(git cat-file -t "refs/tags/$TAG" 2>/dev/null || true)" = "tag" ]; then
  git tag -l --format='%(contents)' "$TAG" | sed '/^-----BEGIN PGP SIGNATURE-----$/,$d' > "$MD"
  if [ -s "$MD" ] && grep -q '[^[:space:]]' "$MD"; then source_used="mensaje del tag"; else : > "$MD"; fi
fi
if [ -z "$source_used" ] && [ -f "$REPO_ROOT/CHANGELOG.md" ]; then
  python3 "$HERE/notes.py" changelog --file "$REPO_ROOT/CHANGELOG.md" --version "$VERSION" > "$MD"
  if grep -q '[^[:space:]]' "$MD"; then source_used="CHANGELOG.md"; else : > "$MD"; fi
fi
if [ -z "$source_used" ]; then
  prev="$(git describe --tags --abbrev=0 --match 'v*' "$TAG^" 2>/dev/null || true)"
  range="${prev:+$prev..}$TAG"
  { echo "## Cambios"; git log --no-merges --max-count=50 --pretty='- %s' "$range"; } > "$MD"
  source_used="commits ${prev:+desde $prev}"
fi

python3 "$HERE/notes.py" html < "$MD" > "$OUT/$BASE.html"
python3 "$HERE/notes.py" html --page --title "Chopshop $VERSION" < "$MD" > "$OUT/notes/$VERSION.html"
log "notas de ${TAG:-$VERSION} generadas desde: $source_used"
