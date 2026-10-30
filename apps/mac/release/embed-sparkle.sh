#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=sparkle.version
source "$RELEASE_SCRIPTS/sparkle.version"

APP="${1:-}"
[ -d "$APP/Contents" ] || die "uso: embed-sparkle.sh <Chopshop.app>"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
EXE_NAME="$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
EXE="$APP/Contents/MacOS/$EXE_NAME"
[ -f "$EXE" ] || die "no existe el ejecutable $EXE"

SRC="${SPARKLE_FRAMEWORK_SRC:-}"
if [ -z "$SRC" ]; then
  SRC="$(find "$MAC_DIR/.build" -maxdepth 8 -type d -path '*Sparkle.xcframework/macos-*/Sparkle.framework' 2>/dev/null | head -n 1)"
fi
if [ -z "$SRC" ]; then
  bin_path="$( (cd "$MAC_DIR" && swift build -c release --show-bin-path 2>/dev/null) || true)"
  if [ -n "$bin_path" ] && [ -d "$bin_path/Sparkle.framework" ]; then SRC="$bin_path/Sparkle.framework"; fi
fi
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then die "no encuentro Sparkle.framework (¿falló la resolución de SwiftPM?)"; fi

FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
rm -rf "$FRAMEWORKS/Sparkle.framework"
ditto "$SRC" "$FRAMEWORKS/Sparkle.framework"

got="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$FRAMEWORKS/Sparkle.framework/Resources/Info.plist" 2>/dev/null || true)"
[ "$got" = "$SPARKLE_VERSION" ] || die "Sparkle.framework es $got pero sparkle.version fija $SPARKLE_VERSION (actualiza Package.swift y sparkle.version juntos)"

if ! otool -l "$EXE" | grep '@executable_path/../Frameworks' >/dev/null; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$EXE"
fi
otool -L "$EXE" | grep 'Sparkle.framework' >/dev/null || die "el ejecutable no enlaza Sparkle.framework (¿falta la dependencia en Package.swift?)"
log "Sparkle $got incrustado en $(basename "$APP")"
