#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET="${1:-}"; ZIP="${2:-}"
if [ -d "$TARGET/Contents" ] && [ -n "$ZIP" ]; then
  KIND=app; SUBMIT="$ZIP"
elif [ -f "$TARGET" ] && [[ "$TARGET" == *.dmg ]]; then
  KIND=dmg; SUBMIT="$TARGET"
else
  die "uso: notarize.sh <Chopshop.app> <zip_para_enviar> | notarize.sh <Chopshop-VERSION.dmg>"
fi
require_env ASC_API_KEY_P8_BASE64 ASC_API_KEY_ID ASC_API_ISSUER_ID
TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEY="$TMP/chopshop-notary-$$.p8"
RESULT="$TMP/chopshop-notary-result-$$.json"
trap 'rm -f "$KEY" "$RESULT"' EXIT
printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$KEY"
chmod 600 "$KEY"
auth=(--key "$KEY" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")

if [ "$KIND" = app ]; then ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$ZIP"; fi
log "enviando a notarizar (espera hasta ${NOTARY_TIMEOUT:-30m})"
rc=0
xcrun notarytool submit "$SUBMIT" "${auth[@]}" --wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json > "$RESULT" || rc=$?
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

stapler_retry staple "$TARGET"
if [ "$KIND" = dmg ]; then
  codesign --verify --strict --verbose=2 "$TARGET"
  spctl -a -t open --context context:primary-signature -vv "$TARGET" 2>&1 | sed 's/^origin=.*/origin=<oculto>/'
  stapler_retry validate "$TARGET"
  write_sha256 "$TARGET" >/dev/null
  log "DMG: firma, Gatekeeper y ticket grapado verificados; checksum actualizado"
  exit 0
fi
stapler_retry validate "$TARGET"
spctl --assess --type execute -vv "$TARGET" 2>&1 | sed 's/^origin=.*/origin=<oculto>/'
codesign --verify --deep --strict --verbose=2 "$TARGET"
log "Gatekeeper, ticket grapado y firma verificados"
