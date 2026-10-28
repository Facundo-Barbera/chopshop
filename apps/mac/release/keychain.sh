#!/usr/bin/env bash
# Keychain TEMPORAL para firmar en el runner.
#   keychain.sh setup     importa el .p12 en un keychain nuevo y exporta SIGN_KEYCHAIN y SIGN_IDENTITY (a GITHUB_ENV)
#   keychain.sh cleanup   restaura la lista de keychains y borra keychain y archivos temporales (idempotente, nunca falla)
# Entrada (setup): MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD; opcional MACOS_KEYCHAIN_PASSWORD (si falta se
# genera una aleatoria del run) y MACOS_SIGN_IDENTITY (si hay varias identidades Developer ID).
# Nunca imprime valores: los derivados sensibles (nombre del certificado, Team ID) se enmascaran.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEYCHAIN="$TMP/chopshop-signing.keychain-db"
P12="$TMP/chopshop-cert.p12"
SEARCH_LIST="$TMP/chopshop-keychain-search-list.txt"

setup() {
  require_env MACOS_CERT_P12_BASE64 MACOS_CERT_PASSWORD
  local kc_pass="${MACOS_KEYCHAIN_PASSWORD:-}"
  if [ -z "$kc_pass" ]; then kc_pass="$(openssl rand -hex 24)"; fi
  mask_value "$kc_pass"
  # Pase lo que pase, el .p12 en claro no se queda en disco
  trap 'rm -f "$P12"' EXIT

  # Guarda la lista actual de keychains para restaurarla al final
  security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//' > "$SEARCH_LIST"

  printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode > "$P12"
  chmod 600 "$P12"

  security create-keychain -p "$kc_pass" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$kc_pass" "$KEYCHAIN"
  security import "$P12" -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$KEYCHAIN" >/dev/null
  rm -f "$P12"

  # El keychain temporal va primero y se conservan los demás (notarytool/stapler necesitan los del sistema)
  local -a existing=()
  while IFS= read -r kc; do
    if [ -n "$kc" ]; then existing+=("$kc"); fi
  done < "$SEARCH_LIST"
  security list-keychains -d user -s "$KEYCHAIN" ${existing[@]+"${existing[@]}"}

  # Identidad: hash SHA-1 (sin nombre, sin comillas); el nombre y el Team ID van enmascarados
  local ids count identity="${MACOS_SIGN_IDENTITY:-}"
  ids="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep 'Developer ID Application' || true)"
  count="$(printf '%s' "$ids" | grep -c . || true)"
  local line cn team
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cn="$(printf '%s' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')"
    mask_value "$cn"
    mask_value "${cn#*: }"
    team="$(printf '%s' "$cn" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
    mask_value "$team"
  done <<< "$ids"
  if [ -z "$identity" ]; then
    [ "$count" -ge 1 ] || die "el .p12 no contiene una identidad 'Developer ID Application' válida"
    [ "$count" -eq 1 ] || die "el .p12 trae $count identidades Developer ID Application; define MACOS_SIGN_IDENTITY (hash SHA-1) para elegir una"
    identity="$(printf '%s' "$ids" | awk '{print $2}')"
  else
    mask_value "$identity"
  fi
  set_env SIGN_KEYCHAIN "$KEYCHAIN"
  set_env SIGN_IDENTITY "$identity"
  log "keychain temporal listo (identidades Developer ID: $count)"
}

cleanup() {
  set +e
  if [ -f "$SEARCH_LIST" ]; then
    local -a existing=()
    while IFS= read -r kc; do
      if [ -n "$kc" ]; then existing+=("$kc"); fi
    done < "$SEARCH_LIST"
    if [ "${#existing[@]}" -gt 0 ]; then security list-keychains -d user -s "${existing[@]}" >/dev/null 2>&1; fi
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1
  rm -f "$P12" "$SEARCH_LIST" "$KEYCHAIN" 2>/dev/null
  # Archivos de notarización que pudieran haber quedado (ver notarize.sh)
  rm -f "$TMP"/chopshop-notary-*.p8 2>/dev/null
  log "keychain temporal y archivos de credenciales eliminados"
  return 0
}

case "${1:-}" in
  setup) setup ;;
  cleanup) cleanup ;;
  *) die "uso: keychain.sh <setup|cleanup>" ;;
esac
