#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ZIP="${1:-}"
[ -f "$ZIP" ] || die "uso: publish.sh <Chopshop-VERSION.zip>"
require_env VERSION BUILD_NUMBER
if [ "${DRY_RUN:-false}" = true ]; then
  [ "${R2_TEST_ONLY:-0}" = 1 ] || die "dry-run exige R2_TEST_ONLY=1 y R2_PREFIX=test/<id>"
  TAG=""
  export NOTES_VERSION="$VERSION"
else
  require_env TAG
fi
NAME="Chopshop-$VERSION.zip"
[ "$(basename "$ZIP")" = "$NAME" ] || die "el zip debe llamarse $NAME"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bash "$HERE/r2.sh" pull "$work"

status=0
python3 -I "$HERE/appcast.py" check-new --dir "$work" --archive "$ZIP" --version "$VERSION" --build "$BUILD_NUMBER" || status=$?
case "$status" in
  0) ;;
  3) log "reintento idempotente de una versión ya publicada" ;;
  *) exit 1 ;;
esac

cp "$ZIP" "$work/$NAME"
bash "$HERE/notes.sh" "${TAG:-}" "$work" "Chopshop-$VERSION"
if [ -n "${NOTES_MD_OUT:-}" ]; then cp "$work/notes/$VERSION.md" "$NOTES_MD_OUT"; fi
bash "$HERE/appcast.sh" "$work" --new-build "$BUILD_NUMBER" --version "$VERSION" --channel "${CHANNEL:-}"
bash "$HERE/r2.sh" push "$work" "$VERSION"
bash "$HERE/r2.sh" verify "$work" "$NAME"

BASE="$(strip_slash "$UPDATES_BASE_URL")"
summary "### Publicado en R2"
summary "- Versión: \`$VERSION\` (CFBundleVersion \`$BUILD_NUMBER\`)${CHANNEL:+, canal \`$CHANNEL\`}"
summary "- Feed: \`$BASE/appcast.xml\`"
log "release $VERSION publicado"
