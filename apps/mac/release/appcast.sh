#!/usr/bin/env bash
# Genera/actualiza <dir>/appcast.xml con generate_appcast (Sparkle fijado) y lo valida.
#   appcast.sh <dir> [--new-build N] [--version V] [--channel C]
#     --new-build N  release nueva: solo ese build entra como item nuevo (--versions N); las demás
#                    versiones y sus firmas se conservan tal cual del appcast descargado.
#     (sin --new-build)  regenerar el feed con lo que haya en <dir> (rollback: la versión retirada ya no está).
# <dir> debe contener appcast.xml previo (si existe), los zips/deltas referenciados y, para la nueva versión,
# su zip Chopshop-<V>.zip y Chopshop-<V>.html (notas: las incrusta el feed).
# Env: SPARKLE_BIN, SPARKLE_ED_PRIVATE_KEY (semilla ed25519 de 32 bytes en base64; se escribe a un archivo temporal 0600
#      que se borra siempre al salir y nunca se imprime), SPARKLE_ED_PUBLIC_KEY, UPDATES_BASE_URL,
#      SPARKLE_ED_SIGNING_PUBLIC_KEY (opcional: pública de la clave que FIRMA; solo difiere en el release puente de una rotación),
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
require_env SPARKLE_BIN SPARKLE_ED_PRIVATE_KEY SPARKLE_ED_PUBLIC_KEY UPDATES_BASE_URL
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "no encuentro generate_appcast en SPARKLE_BIN"
BASE="$(strip_slash "$UPDATES_BASE_URL")"
MIN="${MIN_MACOS_VERSION:-13.0}"
# Pública de la clave con la que se firma. Normalmente es la que lleva la app (SUPublicEDKey); en el release
# puente de una rotación la app ya lleva la nueva y se firma todavía con la vieja (ver docs/release.md).
SIGNING_PUB="${SPARKLE_ED_SIGNING_PUBLIC_KEY:-$SPARKLE_ED_PUBLIC_KEY}"

# La clave privada tiene que ser la pareja de la pública esperada; si no, ningún cliente aceptaría el update
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | python3 -I "$HERE/appcast.py" check-key --public "$SIGNING_PUB"

# Clave privada en un archivo temporal 0600 (sign_update/generate_appcast --ed-key-file); se borra siempre (trap EXIT).
# GitHub ya enmascara el secret en los logs; este script no lo imprime en ningún caso.
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
  # El rollout gradual es para el canal estable; las betas llegan a todos los que las pidieron
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
  # Rollback: si generate_appcast dejó el item retirado o deltas hacia archivos que ya no están (no limpia los
  # <sparkle:deltas> de items existentes), se podan a mano y el feed se vuelve a firmar con sign_update
  if [ -n "${ABSENT_VERSION:-}" ]; then
    log "poda manual del feed (item $ABSENT_VERSION y deltas huérfanos) y re-firma"
    python3 -I "$HERE/appcast.py" prune --appcast "$DIR/appcast.xml" --dir "$DIR" --version "$ABSENT_VERSION"
    (cd "$work" && "$SPARKLE_BIN/sign_update" --ed-key-file "$KEY_FILE" "$DIR/appcast.xml")
    python3 -I "$HERE/appcast.py" verify "${verify_args[@]}" || die "el appcast podado no pasa la validación"
  else
    die "el appcast generado no pasa la validación"
  fi
fi

# Segunda opinión con la herramienta oficial: sign_update firma el zip nuevo con la misma clave; Ed25519 es
# determinista, así que su firma debe ser idéntica a la que generate_appcast puso en el feed, y además verificar.
if [ -n "$NEW_BUILD" ]; then
  sig="$(python3 -I "$HERE/appcast.py" get-sig --appcast "$DIR/appcast.xml" --version "$VERSION")"
  own="$(cd "$work" && "$SPARKLE_BIN/sign_update" --ed-key-file "$KEY_FILE" -p "$DIR/Chopshop-$VERSION.zip")"
  [ "$own" = "$sig" ] || die "la firma de sign_update no coincide con la del appcast"
  (cd "$work" && "$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY_FILE" "$DIR/Chopshop-$VERSION.zip" "$sig")
  log "sign_update: firma EdDSA del zip idéntica a la del feed y válida"
fi
