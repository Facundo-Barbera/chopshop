#!/usr/bin/env bash
# Genera/actualiza <dir>/appcast.xml con generate_appcast (Sparkle fijado) y lo valida.
#   appcast.sh <dir> [--new-build N] [--version V] [--channel C]
#     --new-build N  release nueva: solo ese build entra como item nuevo (--versions N); las demás
#                    versiones y sus firmas se conservan tal cual del appcast descargado.
#     (sin --new-build)  regenerar el feed con lo que haya en <dir> (rollback: la versión retirada ya no está).
# <dir> debe contener appcast.xml previo (si existe), los zips/deltas referenciados y, para la nueva versión,
# su zip Chopshop-<V>.zip y Chopshop-<V>.html (notas: las incrusta el feed).
# Env: SPARKLE_BIN, SPARKLE_ED_PRIVATE_KEY (solo por stdin), SPARKLE_PUBLIC_ED_KEY, UPDATES_BASE_URL,
#      SPARKLE_SIGNING_PUBLIC_ED_KEY (opcional: pública de la clave que FIRMA; solo difiere en el release puente de una rotación),
#      MIN_MACOS_VERSION (13.0), MAX_DELTAS (3), MAX_VERSIONS (5), DELTA_COMPRESSION (lzma),
#      PHASED_ROLLOUT_INTERVAL (vacío = sin rollout gradual), FULL_RELEASE_NOTES_URL (opcional).
# `sparkle:minimumSystemVersion` sale de LSMinimumSystemVersion del Info.plist de la app (= MIN_MACOS_VERSION).
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
require_env SPARKLE_BIN SPARKLE_ED_PRIVATE_KEY SPARKLE_PUBLIC_ED_KEY UPDATES_BASE_URL
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "no encuentro generate_appcast en SPARKLE_BIN"
BASE="$(strip_slash "$UPDATES_BASE_URL")"
MIN="${MIN_MACOS_VERSION:-13.0}"
# Pública de la clave con la que se firma. Normalmente es la que lleva la app (SUPublicEDKey); en el release
# puente de una rotación la app ya lleva la nueva y se firma todavía con la vieja (ver docs/release.md).
SIGNING_PUB="${SPARKLE_SIGNING_PUBLIC_ED_KEY:-$SPARKLE_PUBLIC_ED_KEY}"

# La clave privada tiene que ser la pareja de la pública esperada; si no, ningún cliente aceptaría el update
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | python3 -I "$HERE/appcast.py" check-key --public "$SIGNING_PUB"

args=(--ed-key-file - --download-url-prefix "$BASE/" --maximum-versions "${MAX_VERSIONS:-5}"
  --maximum-deltas "${MAX_DELTAS:-3}" --delta-compression "${DELTA_COMPRESSION:-lzma}" --embed-release-notes)
if [ -n "$NEW_BUILD" ]; then
  args+=(--versions "$NEW_BUILD")
  if [ -n "$CHANNEL" ]; then args+=(--channel "$CHANNEL"); fi
  # El rollout gradual es para el canal estable; las betas llegan a todos los que las pidieron
  if [ -n "${PHASED_ROLLOUT_INTERVAL:-}" ] && [ -z "$CHANNEL" ]; then args+=(--phased-rollout-interval "$PHASED_ROLLOUT_INTERVAL"); fi
fi
if [ -n "${FULL_RELEASE_NOTES_URL:-}" ]; then args+=(--full-release-notes-url "$FULL_RELEASE_NOTES_URL"); fi

# cwd neutro: con `--ed-key-file -` Sparkle lee stdin solo si no existe un archivo llamado "-"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
log "generate_appcast (deltas<=${MAX_DELTAS:-3}, versiones<=${MAX_VERSIONS:-5}${NEW_BUILD:+, nuevo build $NEW_BUILD}${CHANNEL:+, canal $CHANNEL})"
(cd "$work" && printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" "${args[@]}" "$DIR")
[ -f "$DIR/appcast.xml" ] || die "generate_appcast no produjo appcast.xml"

verify_args=(--dir "$DIR" --base-url "$BASE" --min-system "$MIN" --public "$SIGNING_PUB" --require-signed-feed)
if [ -n "$NEW_BUILD" ]; then verify_args+=(--version "$VERSION" --build "$NEW_BUILD" --channel "$CHANNEL"); fi
if [ -n "${ABSENT_VERSION:-}" ]; then verify_args+=(--absent "$ABSENT_VERSION"); fi
if ! python3 -I "$HERE/appcast.py" verify "${verify_args[@]}"; then
  # Rollback: si generate_appcast conservó el item retirado, se quita a mano y se re-firma el feed con sign_update
  if [ -n "${ABSENT_VERSION:-}" ] && grep -q "<sparkle:shortVersionString>$ABSENT_VERSION<" "$DIR/appcast.xml"; then
    log "el item $ABSENT_VERSION seguía en el feed: se retira a mano y se re-firma"
    python3 -I "$HERE/appcast.py" remove-item --appcast "$DIR/appcast.xml" --version "$ABSENT_VERSION"
    printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | (cd "$work" && "$SPARKLE_BIN/sign_update" --ed-key-file - "$DIR/appcast.xml")
    python3 -I "$HERE/appcast.py" verify "${verify_args[@]}"
  else
    die "el appcast generado no pasa la validación"
  fi
fi

# Segunda opinión con la herramienta oficial: la firma del zip nuevo debe verificar con sign_update
if [ -n "$NEW_BUILD" ]; then
  sig="$(python3 -I "$HERE/appcast.py" get-sig --appcast "$DIR/appcast.xml" --version "$VERSION")"
  printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | (cd "$work" && "$SPARKLE_BIN/sign_update" --verify --ed-key-file - "$DIR/Chopshop-$VERSION.zip" "$sig")
  log "sign_update --verify: firma del zip válida"
fi
