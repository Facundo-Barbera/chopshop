#!/usr/bin/env bash
# Keychain TEMPORAL para firmar en el runner.
#   keychain.sh setup     importa el .p12 en un keychain nuevo y exporta SIGN_KEYCHAIN y SIGN_IDENTITY (a GITHUB_ENV)
#   keychain.sh cleanup   restaura la lista de keychains y borra keychain y archivos temporales (idempotente, nunca falla)
# Entrada (setup): MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD, KEYCHAIN_PASSWORD (secrets) y
# SIGNING_IDENTITY (var: nombre «Developer ID Application: Nombre (TEAMID)» o hash SHA-1) y APPLE_TEAM_ID (var).
# Nunca imprime valores: los derivados sensibles (nombre del certificado, Team ID) se enmascaran.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEYCHAIN="$TMP/chopshop-signing.keychain-db"
P12="$TMP/chopshop-cert.p12"
SEARCH_LIST="$TMP/chopshop-keychain-search-list.txt"

setup() {
  require_env MACOS_CERT_P12_BASE64 MACOS_CERT_PASSWORD KEYCHAIN_PASSWORD SIGNING_IDENTITY APPLE_TEAM_ID
  local kc_pass="$KEYCHAIN_PASSWORD"
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

  # Identidad: se elige la que pide SIGNING_IDENTITY (nombre o hash) y debe ser del equipo APPLE_TEAM_ID.
  # Se exporta el hash SHA-1 (sin nombre ni comillas); el nombre y el Team ID se enmascaran por si los imprime otra herramienta.
  local ids count identity line cn
  mask_value "$SIGNING_IDENTITY"
  mask_value "${SIGNING_IDENTITY#*: }"
  mask_value "$APPLE_TEAM_ID"
  ids="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep 'Developer ID Application' || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cn="$(printf '%s' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')"
    mask_value "$cn"
  done <<< "$ids"
  local match
  match="$(printf '%s\n' "$ids" | grep -F -- "$SIGNING_IDENTITY" || true)"
  count="$(printf '%s' "$match" | grep -c . || true)"
  [ "$count" -ge 1 ] || die "el .p12 no contiene la identidad indicada en SIGNING_IDENTITY (ni una 'Developer ID Application' que coincida)"
  [ "$count" -eq 1 ] || die "SIGNING_IDENTITY coincide con $count identidades; usa el nombre completo o el hash SHA-1"
  printf '%s' "$match" | grep -F -- "($APPLE_TEAM_ID)" >/dev/null || die "la identidad elegida no pertenece al equipo APPLE_TEAM_ID"
  identity="$(printf '%s' "$match" | awk '{print $2}')"
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
