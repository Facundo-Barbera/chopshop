#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

DIR="${1:-}"; shift || true
NEW_BUILD="" VERSION="" CHANNEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --new-build) NEW_BUILD="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    *) die "argumento desconocido: $1" ;;
  esac
done
[ -d "$DIR" ] || die "uso: appcast.sh <dir> [--new-build N --version V] [--channel C]"
require_env SPARKLE_BIN SPARKLE_ED_PRIVATE_KEY SPARKLE_ED_PUBLIC_KEY UPDATES_BASE_URL
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "no encuentro generate_appcast en SPARKLE_BIN"
BASE="$(strip_slash "$UPDATES_BASE_URL")"
MIN="${MIN_MACOS_VERSION:-13.0}"
SIGNING_PUB="${SPARKLE_ED_SIGNING_PUBLIC_KEY:-$SPARKLE_ED_PUBLIC_KEY}"

printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | python3 -I "$HERE/appcast.py" check-key --public "$SIGNING_PUB"

work="$(mktemp -d)"
KEY_FILE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/chopshop-sparkle-key-$$"
trap 'rm -f "$KEY_FILE"; rm -rf "$work"' EXIT
( umask 077; printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE" )
chmod 600 "$KEY_FILE"

args=(--ed-key-file "$KEY_FILE" -o "$DIR/appcast.xml" --download-url-prefix "$BASE/" --maximum-versions "${MAX_VERSIONS:-5}"
  --maximum-deltas "${MAX_DELTAS:-3}" --delta-compression "${DELTA_COMPRESSION:-lzma}" --embed-release-notes)
if [ -n "$NEW_BUILD" ]; then
  args+=(--versions "$NEW_BUILD")
  if [ -n "$CHANNEL" ]; then args+=(--channel "$CHANNEL"); fi
  if [ -n "${PHASED_ROLLOUT_INTERVAL:-}" ] && [ -z "$CHANNEL" ]; then args+=(--phased-rollout-interval "$PHASED_ROLLOUT_INTERVAL"); fi
fi
if [ -n "${FULL_RELEASE_NOTES_URL:-}" ]; then args+=(--full-release-notes-url "$FULL_RELEASE_NOTES_URL"); fi

log "generate_appcast (deltas<=${MAX_DELTAS:-3}, versiones<=${MAX_VERSIONS:-5}${NEW_BUILD:+, nuevo build $NEW_BUILD}${CHANNEL:+, canal $CHANNEL})"
(cd "$work" && "$SPARKLE_BIN/generate_appcast" "${args[@]}" "$DIR")
[ -f "$DIR/appcast.xml" ] || die "generate_appcast no produjo appcast.xml"

verify_args=(--dir "$DIR" --base-url "$BASE" --min-system "$MIN" --public "$SIGNING_PUB" --require-signed-feed)
if [ -n "$NEW_BUILD" ]; then verify_args+=(--version "$VERSION" --build "$NEW_BUILD" --channel "$CHANNEL"); fi
if [ -n "${ABSENT_VERSION:-}" ]; then verify_args+=(--absent "$ABSENT_VERSION"); fi
if ! python3 -I "$HERE/appcast.py" verify "${verify_args[@]}"; then
  if [ -n "${ABSENT_VERSION:-}" ]; then
    log "poda manual del feed (item $ABSENT_VERSION y deltas huérfanos) y re-firma"
    python3 -I "$HERE/appcast.py" prune --appcast "$DIR/appcast.xml" --dir "$DIR" --version "$ABSENT_VERSION"
    (cd "$work" && "$SPARKLE_BIN/sign_update" --ed-key-file "$KEY_FILE" "$DIR/appcast.xml")
    python3 -I "$HERE/appcast.py" verify "${verify_args[@]}" || die "el appcast podado no pasa la validación"
  else
    die "el appcast generado no pasa la validación"
  fi
fi

if [ -n "$NEW_BUILD" ]; then
  sig="$(python3 -I "$HERE/appcast.py" get-sig --appcast "$DIR/appcast.xml" --version "$VERSION")"
  own="$(cd "$work" && "$SPARKLE_BIN/sign_update" --ed-key-file "$KEY_FILE" -p "$DIR/Chopshop-$VERSION.zip")"
  [ "$own" = "$sig" ] || die "la firma de sign_update no coincide con la del appcast"
  (cd "$work" && "$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY_FILE" "$DIR/Chopshop-$VERSION.zip" "$sig")
  log "sign_update: firma EdDSA del zip idéntica a la del feed y válida"
fi
