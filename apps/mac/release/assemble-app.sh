#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_env SHORT_VERSION BUILD_NUMBER
OUT="${APP_OUT:-$MAC_DIR/build/release/Chopshop.app}"
BUNDLE_ID="${BUNDLE_ID:-com.example.chopshop}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-13.0}"
AUTO_UPDATE="${SPARKLE_AUTO_UPDATE:-false}"
CHECK_INTERVAL="${SPARKLE_CHECK_INTERVAL:-86400}"
MODE="${RELEASE_MODE:-release}"
FEED=""
if [ -n "${UPDATES_BASE_URL:-}" ]; then FEED="$(strip_slash "$UPDATES_BASE_URL")/appcast.xml"; fi
PUBKEY="${SPARKLE_ED_PUBLIC_KEY:-}"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

case "$AUTO_UPDATE" in true | false) ;; *) die "SPARKLE_AUTO_UPDATE debe ser true o false" ;; esac
if [ "$MODE" = release ]; then
  [ -n "$FEED" ] || die "UPDATES_BASE_URL vacío: sin feed la app publicada no podría actualizarse"
  [ -n "$PUBKEY" ] || die "SPARKLE_ED_PUBLIC_KEY vacía: sin clave pública Sparkle rechazaría todas las actualizaciones"
fi
if [ -n "$PUBKEY" ] && [ "$(b64_len "$PUBKEY")" != 32 ]; then die "SPARKLE_ED_PUBLIC_KEY no es base64 de 32 bytes"; fi

log "build.sh -> $OUT"
rm -rf "$OUT"
CHOPSHOP_APP="$OUT" bash "${BUILD_SCRIPT:-$MAC_DIR/build.sh}"
[ -f "$OUT/Contents/Info.plist" ] || die "build.sh no generó $OUT"
PLIST="$OUT/Contents/Info.plist"

plist_put() {
  local key="$1" type="$2" value="$3"
  case "$value" in *\"* | *$'\n'*) die "valor inválido para $key" ;; esac
  if [ "$type" != string ] && ! [[ "$value" =~ ^(true|false|[0-9]+)$ ]]; then die "valor inválido para $key"; fi
  "$PLISTBUDDY" -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
  if [ "$type" = string ]; then
    "$PLISTBUDDY" -c "Add :$key string \"$value\"" "$PLIST"
  else
    "$PLISTBUDDY" -c "Add :$key $type $value" "$PLIST"
  fi
}
plist_del() { "$PLISTBUDDY" -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || true; }
plist_get() { "$PLISTBUDDY" -c "Print :$1" "$PLIST" 2>/dev/null || true; }

plist_put CFBundleIdentifier string "$BUNDLE_ID"
plist_put CFBundleShortVersionString string "$SHORT_VERSION"
plist_put CFBundleVersion string "$BUILD_NUMBER"
plist_put LSMinimumSystemVersion string "$MIN_MACOS_VERSION"

AGENT_PLIST="$OUT/Contents/Library/LaunchAgents/chopshop-agent.plist"
if [ -f "$AGENT_PLIST" ]; then
  APP_PLIST="$PLIST"
  PLIST="$AGENT_PLIST"
  plist_put Label string "$BUNDLE_ID.agent"
  plist_del AssociatedBundleIdentifiers
  "$PLISTBUDDY" -c "Add :AssociatedBundleIdentifiers array" "$PLIST"
  "$PLISTBUDDY" -c "Add :AssociatedBundleIdentifiers:0 string $BUNDLE_ID" "$PLIST"
  [ "$(plist_get Label)" = "$BUNDLE_ID.agent" ] || die "Label del LaunchAgent no quedó aplicado"
  PLIST="$APP_PLIST"
fi

if [ -n "$FEED" ] && [ -n "$PUBKEY" ]; then
  plist_put SUFeedURL string "$FEED"
  plist_put SUPublicEDKey string "$PUBKEY"
  plist_put SUEnableAutomaticChecks bool true
  plist_put SUAutomaticallyUpdate bool "$AUTO_UPDATE"
  plist_put SUScheduledCheckInterval integer "$CHECK_INTERVAL"
  plist_put SURequireSignedFeed bool true
  plist_put SUVerifyUpdateBeforeExtraction bool true
else
  warn "sin UPDATES_BASE_URL/SPARKLE_ED_PUBLIC_KEY: la app no incluirá claves de Sparkle (updater desactivado)"
  for k in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUScheduledCheckInterval SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do plist_del "$k"; done
fi

bash "$RELEASE_SCRIPTS/embed-sparkle.sh" "$OUT"

[ "$(plist_get CFBundleIdentifier)" = "$BUNDLE_ID" ] || die "CFBundleIdentifier no quedó aplicado"
[ "$(plist_get CFBundleShortVersionString)" = "$SHORT_VERSION" ] || die "CFBundleShortVersionString no quedó aplicado"
[ "$(plist_get CFBundleVersion)" = "$BUILD_NUMBER" ] || die "CFBundleVersion no quedó aplicado"
if [ -n "$FEED" ] && [ -n "$PUBKEY" ]; then
  [ "$(plist_get SUPublicEDKey)" = "$PUBKEY" ] || die "SUPublicEDKey no quedó aplicada"
  [ "$(plist_get SUFeedURL)" = "$FEED" ] || die "SUFeedURL no quedó aplicado"
fi
EXE="$OUT/Contents/MacOS/$(plist_get CFBundleExecutable)"
minos="$(otool -l "$EXE" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="minos"{print $2; exit} /LC_VERSION_MIN_MACOSX/{g=1} g && $1=="version"{print $2; exit}')"
if [ -n "$minos" ] && ! version_ge "$MIN_MACOS_VERSION" "$minos"; then
  die "el binario exige macOS $minos (Package.swift) pero MIN_MACOS_VERSION=$MIN_MACOS_VERSION promete un sistema más antiguo; ajusta la variable o baja el deployment target"
fi
set_output app_path "$OUT"
log "app ensamblada: versión $SHORT_VERSION (build $BUILD_NUMBER), macOS >= $MIN_MACOS_VERSION"
