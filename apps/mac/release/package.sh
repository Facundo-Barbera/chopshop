#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP="${1:-}"; ZIP="${2:-}"
if [ ! -d "$APP/Contents" ] || [ -z "$ZIP" ]; then die "uso: package.sh <Chopshop.app> <zip_salida>"; fi
mkdir -p "$(dirname "$ZIP")"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
ditto -x -k "$ZIP" "$check"
unpacked="$check/$(basename "$APP")"
[ -d "$unpacked" ] || die "el zip no contiene $(basename "$APP") en su raíz"
codesign --verify --deep --strict --verbose=2 "$unpacked"
if [ "${REQUIRE_STAPLE:-0}" = 1 ]; then stapler_retry validate "$unpacked"; fi

sum="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
printf '%s  %s\n' "$sum" "$(basename "$ZIP")" > "$ZIP.sha256"
set_output zip_name "$(basename "$ZIP")"
set_output zip_sha256 "$sum"
log "zip final: $(basename "$ZIP") ($(wc -c < "$ZIP" | tr -d ' ') bytes)"
