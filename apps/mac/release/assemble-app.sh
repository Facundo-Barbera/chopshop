#!/usr/bin/env bash
# Ensambla Chopshop.app listo para firmar. Reutiliza apps/mac/build.sh (UI + Swift + motor + icono) y le
# aplica, vía PlistBuddy, lo que depende del release: bundle id, versiones, sistema mínimo y claves de Sparkle.
# Así el Info.plist de desarrollo y el de release no divergen (cualquier clave nueva de build.sh se conserva).
#
# Entrada (env): SHORT_VERSION, BUILD_NUMBER (obligatorias); BUNDLE_ID (com.example.chopshop),
#   MIN_MACOS_VERSION (13.0), SPARKLE_FEED_URL, SPARKLE_PUBLIC_ED_KEY, SPARKLE_AUTO_UPDATE (false),
#   SPARKLE_CHECK_INTERVAL (86400), APP_OUT (apps/mac/build/release/Chopshop.app),
#   RELEASE_MODE=release|dryrun (en release faltar el feed o la clave pública es un error).
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
FEED="${SPARKLE_FEED_URL:-}"
PUBKEY="${SPARKLE_PUBLIC_ED_KEY:-}"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

case "$AUTO_UPDATE" in true | false) ;; *) die "SPARKLE_AUTO_UPDATE debe ser true o false" ;; esac
if [ "$MODE" = release ]; then
  [ -n "$FEED" ] || die "SPARKLE_FEED_URL vacío: sin feed la app publicada no podría actualizarse"
  [ -n "$PUBKEY" ] || die "SPARKLE_PUBLIC_ED_KEY vacía: sin clave pública Sparkle rechazaría todas las actualizaciones"
fi
if [ -n "$PUBKEY" ] && [ "$(b64_len "$PUBKEY")" != 32 ]; then die "SPARKLE_PUBLIC_ED_KEY no es base64 de 32 bytes"; fi

# 1) UI (pnpm) + Swift + motor + Info.plist base: lo hace build.sh con la ruta de salida parametrizada
log "build.sh -> $OUT"
rm -rf "$OUT"
CHOPSHOP_APP="$OUT" bash "$MAC_DIR/build.sh"
[ -f "$OUT/Contents/Info.plist" ] || die "build.sh no generó $OUT"
PLIST="$OUT/Contents/Info.plist"

plist_put() { # clave tipo valor
  local key="$1" type="$2" value="$3"
  case "$value" in *\"* | *$'\n'*) die "valor inválido para $key" ;; esac
  "$PLISTBUDDY" -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :$key $type \"$value\"" "$PLIST"
}
plist_del() { "$PLISTBUDDY" -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || true; }
plist_get() { "$PLISTBUDDY" -c "Print :$1" "$PLIST" 2>/dev/null || true; }

# 2) Identidad y versiones
plist_put CFBundleIdentifier string "$BUNDLE_ID"
plist_put CFBundleShortVersionString string "$SHORT_VERSION"
plist_put CFBundleVersion string "$BUILD_NUMBER"
plist_put LSMinimumSystemVersion string "$MIN_MACOS_VERSION"

# 3) Sparkle: solo si hay feed y clave pública; si no (dev/dry-run sin vars) el updater queda desactivado
if [ -n "$FEED" ] && [ -n "$PUBKEY" ]; then
  plist_put SUFeedURL string "$FEED"
  plist_put SUPublicEDKey string "$PUBKEY"
  plist_put SUEnableAutomaticChecks bool true
  plist_put SUAutomaticallyUpdate bool "$AUTO_UPDATE"
  plist_put SUScheduledCheckInterval integer "$CHECK_INTERVAL"
  # Feed firmado (generate_appcast lo firma si ve esta clave) y firma verificada antes de extraer
  plist_put SURequireSignedFeed bool true
  plist_put SUVerifyUpdateBeforeExtraction bool true
else
  warn "sin SPARKLE_FEED_URL/SPARKLE_PUBLIC_ED_KEY: la app no incluirá claves de Sparkle (updater desactivado)"
  for k in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUScheduledCheckInterval SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do plist_del "$k"; done
fi

# 4) Sparkle.framework dentro del bundle (y rpath)
bash "$RELEASE_SCRIPTS/embed-sparkle.sh" "$OUT"

# 5) Comprobaciones: el plist quedó como se pidió y el binario puede correr en el sistema mínimo declarado
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
