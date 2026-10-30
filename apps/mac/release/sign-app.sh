#!/usr/bin/env bash
# Firma Chopshop.app de dentro hacia fuera (hardened runtime + sello de tiempo + entitlements mínimos).
#   sign-app.sh <Chopshop.app>
# Env: SIGN_IDENTITY (hash SHA-1 de Developer ID Application; "-" = ad-hoc para dry-run; sin ella y con APPLE_TEAM_ID se busca en el llavero),
#      SIGN_KEYCHAIN (keychain temporal, opcional), ENTITLEMENTS (por defecto Chopshop.entitlements),
#      APPLE_TEAM_ID (si se define y la firma es real, el TeamIdentifier resultante debe coincidir).
# Orden: todo el código anidado (XPC, Autoupdate, Updater.app, binarios sueltos...) del más profundo al más
# superficial, luego Sparkle.framework y por último la app. Es el orden que exige Sparkle con hardened runtime
# y se obtiene ordenando por profundidad, sin depender de la estructura interna de cada versión de Sparkle.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP="${1:-}"
[ -d "$APP/Contents" ] || die "uso: sign-app.sh <Chopshop.app>"
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  ids="$(security find-identity -v -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} | grep -F "Developer ID Application" | grep -F "($APPLE_TEAM_ID)\"" || true)"
  [ "$(printf '%s' "$ids" | grep -c .)" = 1 ] || die "no hay exactamente una identidad Developer ID Application del equipo APPLE_TEAM_ID en el llavero"
  IDENTITY="$(printf '%s' "$ids" | awk '{print $2}')"
fi
[ -n "$IDENTITY" ] || die "falta SIGN_IDENTITY (usa '-' para firma ad-hoc) o APPLE_TEAM_ID para buscar la identidad en el llavero"
# Una release real jamás sale con firma ad-hoc: RELEASE_MODE=release exige una identidad Developer ID
if [ "${RELEASE_MODE:-}" = release ] && [ "$IDENTITY" = "-" ]; then die "RELEASE_MODE=release no admite firma ad-hoc"; fi
ENTITLEMENTS="${ENTITLEMENTS:-$RELEASE_SCRIPTS/Chopshop.entitlements}"
[ -f "$ENTITLEMENTS" ] || die "no existe el archivo de entitlements"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
EXE="$APP/Contents/MacOS/$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

sign_one() { # ruta [args extra de codesign]
  local path="$1"
  shift
  local -a args=(--force --sign "$IDENTITY" --options runtime)
  if [ "$IDENTITY" = "-" ]; then args+=(--timestamp=none); else args+=(--timestamp); fi
  if [ -n "${SIGN_KEYCHAIN:-}" ]; then args+=(--keychain "$SIGN_KEYCHAIN"); fi
  codesign "${args[@]}" ${1+"$@"} "$path"
}

# Código anidado: bundles (.xpc .app .framework .bundle) y binarios Mach-O sueltos, de mayor a menor profundidad
nested_code() {
  {
    find "$APP/Contents" -type d \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' -o -name '*.bundle' \) -print
    find "$APP/Contents" -type f -print | while IFS= read -r f; do
      if [ "$f" != "$EXE" ] && is_macho "$f"; then printf '%s\n' "$f"; fi
    done
  } | awk -F/ '{print NF "\t" $0}' | sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2-
}

count=0
while IFS= read -r item; do
  [ -n "$item" ] || continue
  log "firmando ${item#"$APP"/}"
  sign_one "$item" --preserve-metadata=entitlements
  count=$((count + 1))
done < <(nested_code)

log "firmando la app (entitlements mínimos)"
sign_one "$APP" --entitlements "$ENTITLEMENTS"

codesign --verify --deep --strict --verbose=2 "$APP"
# hardened runtime activo (y sello de tiempo en firmas reales); sin imprimir identidades
codesign -d --verbose=2 "$APP" 2>&1 | grep 'flags=0x[0-9a-f]*(.*runtime' >/dev/null || die "la app firmada no tiene hardened runtime"
if [ "$IDENTITY" != "-" ]; then
  codesign -d --verbose=2 "$APP" 2>&1 | grep '^Timestamp=' >/dev/null || die "la firma no lleva sello de tiempo seguro"
  if [ -n "${APPLE_TEAM_ID:-}" ]; then
    codesign -d --verbose=2 "$APP" 2>&1 | grep -x "TeamIdentifier=$APPLE_TEAM_ID" >/dev/null || die "el TeamIdentifier de la firma no coincide con APPLE_TEAM_ID"
  fi
fi
log "firma verificada ($count componente(s) anidados)"
