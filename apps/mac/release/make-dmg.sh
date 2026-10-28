#!/usr/bin/env bash
# Crea el DMG de instalación con la app YA firmada y grapada (arrastrar Chopshop.app a Aplicaciones) y su SHA-256.
#   make-dmg.sh <Chopshop.app> <Chopshop-VERSION.dmg>     [REQUIRE_STAPLE=1 para exigir el ticket grapado en la app]
# Solo hdiutil/ditto (incluidos en macOS): carpeta temporal con la app + enlace `Applications` -> /Applications,
# `hdiutil create -volname Chopshop -fs HFS+ -format UDZO`. Aquí NO se firma ni se notariza (ver sign-dmg.sh y
# notarize.sh): en dry-run el DMG queda sin firmar. El DMG no entra nunca al appcast de Sparkle (que sigue usando el zip).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP="${1:-}"; DMG="${2:-}"
if [ ! -d "$APP/Contents" ] || [ -z "$DMG" ]; then die "uso: make-dmg.sh <Chopshop.app> <Chopshop-VERSION.dmg>"; fi
if [[ "$DMG" != *.dmg ]]; then die "el DMG debe terminar en .dmg"; fi

if [ "${REQUIRE_STAPLE:-0}" = 1 ]; then xcrun stapler validate "$APP"; fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# ditto conserva symlinks, xattrs y el ticket grapado dentro del bundle
ditto "$APP" "$stage/$(basename "$APP")"
ln -s /Applications "$stage/Applications"
codesign --verify --deep --strict --verbose=2 "$stage/$(basename "$APP")"
if [ "${REQUIRE_STAPLE:-0}" = 1 ]; then xcrun stapler validate "$stage/$(basename "$APP")"; fi

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG" "$DMG.sha256"
# hdiutil falla a veces con "Resource busy" en los runners: se reintenta un par de veces
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
