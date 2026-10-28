#!/usr/bin/env bash
# Descarga las herramientas de Sparkle (generate_appcast, sign_update, BinaryDelta...) de la release FIJADA en
# sparkle.version, verifica su SHA-256 y las deja en <dir>. Exporta SPARKLE_BIN y SPARKLE_FRAMEWORK_SRC.
#   sparkle-tools.sh install <dir>
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=sparkle.version
source "${SPARKLE_VERSION_FILE:-$RELEASE_SCRIPTS/sparkle.version}"  # SPARKLE_VERSION_FILE: solo para pruebas

if [ "${1:-}" != install ] || [ -z "${2:-}" ]; then die "uso: sparkle-tools.sh install <dir>"; fi
DEST="$2"
mkdir -p "$DEST"
TARBALL="$DEST/Sparkle-$SPARKLE_VERSION.tar.xz"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

if [ ! -f "$TARBALL" ]; then
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 --output "$TARBALL" "$URL"
fi
actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$actual" != "$SPARKLE_SHA256" ]; then
  rm -f "$TARBALL"
  die "SHA-256 de Sparkle $SPARKLE_VERSION no coincide con el fijado en sparkle.version (esperado $SPARKLE_SHA256, obtenido $actual)"
fi
tar -xf "$TARBALL" -C "$DEST"
for t in generate_appcast sign_update; do
  [ -x "$DEST/bin/$t" ] || die "falta $t en el tarball de Sparkle"
done
set_env SPARKLE_BIN "$DEST/bin"
set_env SPARKLE_FRAMEWORK_SRC "$DEST/Sparkle.framework"
log "Sparkle $SPARKLE_VERSION verificado e instalado en $DEST"
