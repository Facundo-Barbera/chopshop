#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP="${1:-}"; DMG="${2:-}"
if [ ! -d "$APP/Contents" ] || [ -z "$DMG" ]; then die "uso: make-dmg.sh <Chopshop.app> <Chopshop-VERSION.dmg>"; fi
if [[ "$DMG" != *.dmg ]]; then die "el DMG debe terminar en .dmg"; fi

if [ "${REQUIRE_STAPLE:-0}" = 1 ]; then stapler_retry validate "$APP"; fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/$(basename "$APP")"
ln -s /Applications "$stage/Applications"
codesign --verify --deep --strict --verbose=2 "$stage/$(basename "$APP")"
if [ "${REQUIRE_STAPLE:-0}" = 1 ]; then stapler_retry validate "$stage/$(basename "$APP")"; fi

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG" "$DMG.sha256"
attempt=1
until hdiutil create -volname Chopshop -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"; do
  if [ "$attempt" -ge 3 ]; then die "hdiutil create falló tras $attempt intentos"; fi
  attempt=$((attempt + 1))
  warn "hdiutil create falló; reintento $attempt/3"
  rm -f "$DMG"
  sleep "${DMG_RETRY_DELAY:-5}"
done
hdiutil verify "$DMG"

sum="$(write_sha256 "$DMG")"
set_output dmg_name "$(basename "$DMG")"
set_output dmg_sha256 "$sum"
log "DMG creado: $(basename "$DMG") ($(wc -c < "$DMG" | tr -d ' ') bytes)"
