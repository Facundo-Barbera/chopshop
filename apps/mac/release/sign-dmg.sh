#!/usr/bin/env bash
# Firma el DMG con Developer ID (misma identidad y keychain temporal que la app). Solo para releases reales.
#   sign-dmg.sh <Chopshop-VERSION.dmg>
# Env: SIGN_IDENTITY (hash SHA-1; lo exporta keychain.sh), SIGN_KEYCHAIN (keychain temporal, opcional),
#      APPLE_TEAM_ID (si se define, el TeamIdentifier resultante debe coincidir).
# Después: notarize.sh <dmg> (notariza, grapa y verifica).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DMG="${1:-}"
[ -f "$DMG" ] || die "uso: sign-dmg.sh <Chopshop-VERSION.dmg>"
require_env SIGN_IDENTITY
if [ "$SIGN_IDENTITY" = "-" ]; then die "el DMG de una release se firma con Developer ID; no admite firma ad-hoc"; fi

args=(--force --sign "$SIGN_IDENTITY" --timestamp)
if [ -n "${SIGN_KEYCHAIN:-}" ]; then args+=(--keychain "$SIGN_KEYCHAIN"); fi
codesign "${args[@]}" "$DMG"

codesign --verify --strict --verbose=2 "$DMG"
# sello de tiempo y equipo, sin imprimir identidades
codesign -d --verbose=2 "$DMG" 2>&1 | grep '^Timestamp=' >/dev/null || die "la firma del DMG no lleva sello de tiempo seguro"
if [ -n "${APPLE_TEAM_ID:-}" ]; then
  codesign -d --verbose=2 "$DMG" 2>&1 | grep -x "TeamIdentifier=$APPLE_TEAM_ID" >/dev/null || die "el TeamIdentifier del DMG no coincide con APPLE_TEAM_ID"
fi
log "DMG firmado y verificado"
