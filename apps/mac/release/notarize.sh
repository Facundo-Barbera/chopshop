#!/usr/bin/env bash
# Notariza la app (App Store Connect API key), grapa el ticket y verifica con las herramientas de Apple.
#   notarize.sh <Chopshop.app> <zip_para_enviar>
# Env: APPLE_API_KEY_P8_BASE64, APPLE_API_KEY_ID, APPLE_API_ISSUER; NOTARY_TIMEOUT (30m).
# Si Apple no acepta el envío, imprime `notarytool log` (no contiene secretos) y falla. La .p8 solo vive en
# un archivo temporal 0600 que se borra al salir (y también en el paso de limpieza del workflow).
# La identidad del certificado se enmascara en logs aunque spctl la imprima.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP="${1:-}"; ZIP="${2:-}"
[ -d "$APP/Contents" ] && [ -n "$ZIP" ] || die "uso: notarize.sh <Chopshop.app> <zip_para_enviar>"
require_env APPLE_API_KEY_P8_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER
TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEY="$TMP/chopshop-notary-$$.p8"
RESULT="$TMP/chopshop-notary-result-$$.json"
trap 'rm -f "$KEY" "$RESULT"' EXIT
printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$KEY"
chmod 600 "$KEY"
auth=(--key "$KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
log "enviando a notarizar (espera hasta ${NOTARY_TIMEOUT:-30m})"
rc=0
xcrun notarytool submit "$ZIP" "${auth[@]}" --wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json > "$RESULT" || rc=$?
parsed="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(d.get("id", ""))
print(d.get("status", ""))
' "$RESULT")"
sub_id="$(printf '%s\n' "$parsed" | sed -n 1p)"
status="$(printf '%s\n' "$parsed" | sed -n 2p)"
if [ "$rc" -ne 0 ] || [ "$status" != "Accepted" ]; then
  printf '::error::notarización no aceptada (estado: %s, código de salida: %s)\n' "${status:-desconocido}" "$rc" >&2
  if [ -n "$sub_id" ]; then
    echo "--- notarytool log ($sub_id) ---"
    xcrun notarytool log "$sub_id" "${auth[@]}" || true
  else
    echo "--- respuesta de notarytool ---"
    cat "$RESULT" || true
  fi
  exit 1
fi
log "notarización aceptada ($sub_id)"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# spctl imprime "origin=Developer ID Application: <nombre> (<TeamID>)": se oculta por si el logger no lo enmascarara
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^origin=.*/origin=<oculto>/'
codesign --verify --deep --strict --verbose=2 "$APP"
log "Gatekeeper, ticket grapado y firma verificados"
