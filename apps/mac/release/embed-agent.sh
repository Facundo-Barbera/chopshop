#!/usr/bin/env bash
# Incrusta el agente de Chopshop en <app> para que este Mac sea una máquina sin instalar nada más (docs/mac-build.md,
# «Usar esta Mac como máquina»). Idempotente.
#   embed-agent.sh <Chopshop.app>
#
#   Contents/MacOS/chopshop-agent                       lanzador (Sources/ChopshopAgent; lo copia build.sh)
#   Contents/Library/LaunchAgents/chopshop-agent.plist  LaunchAgent que la app registra con SMAppService (lo escribe build.sh)
#   Contents/Resources/agent/chopshop/                  el paquete apps/agent/chopshop, con .pyc precompilados
#   Contents/Resources/agent/chopshop-agent.py          punto de entrada (`python3 -I -B chopshop-agent.py <args>`)
#   Contents/Resources/agent/python/                    python-build-standalone FIJADO en python-runtime.version (recortado)
#
# Env: UNIVERSAL=1 (arm64 + x86_64 con lipo), PYTHON_RUNTIME_CACHE (descargas; por defecto apps/mac/.build/python-runtime),
#   PYTHON_RUNTIME_SRC (solo pruebas/offline: carpeta con un `python/` ya extraído; se usa tal cual, sin descargar ni lipo).
# Los Mach-O del runtime quedan firmados ad-hoc; sign-app.sh los vuelve a firmar (Developer ID + hardened runtime).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=python-runtime.version
source "${PYTHON_RUNTIME_VERSION_FILE:-$RELEASE_SCRIPTS/python-runtime.version}"  # PYTHON_RUNTIME_VERSION_FILE: solo para pruebas

APP="${1:-}"
[ -d "$APP/Contents" ] || die "uso: embed-agent.sh <Chopshop.app>"
AGENT_SRC="$REPO_ROOT/apps/agent/chopshop"
[ -f "$AGENT_SRC/__main__.py" ] || die "no encuentro el paquete del agente en apps/agent/chopshop"
PYMINOR="${PYTHON_RUNTIME_VERSION%.*}"
DEST="$APP/Contents/Resources/agent"
CACHE="${PYTHON_RUNTIME_CACHE:-$MAC_DIR/.build/python-runtime}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -- runtime: descarga verificada por SHA-256 (una por arquitectura) y, en universal, lipo de cada Mach-O
fetch() { # arquitectura(aarch64|x86_64) sha256 -> extrae en $WORK/<arquitectura>/python
  local arch="$1" sum="$2" name url tarball actual
  name="cpython-$PYTHON_RUNTIME_VERSION+$PYTHON_RUNTIME_RELEASE-$arch-apple-darwin-install_only_stripped.tar.gz"
  url="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RUNTIME_RELEASE/$name"
  tarball="$CACHE/$name"
  mkdir -p "$CACHE"
  if [ ! -f "$tarball" ]; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 --output "$tarball.part" "$url"
    mv "$tarball.part" "$tarball"
  fi
  actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  if [ "$actual" != "$sum" ]; then
    rm -f "$tarball"
    die "SHA-256 del runtime de Python ($arch) no coincide con python-runtime.version (esperado $sum, obtenido $actual)"
  fi
  mkdir -p "$WORK/$arch"
  tar -xzf "$tarball" -C "$WORK/$arch"
  [ -x "$WORK/$arch/python/bin/python3" ] || die "el tarball $name no trae python/bin/python3"
}

if [ -n "${PYTHON_RUNTIME_SRC:-}" ]; then
  [ -d "$PYTHON_RUNTIME_SRC/python" ] || die "PYTHON_RUNTIME_SRC no contiene python/"
  RUNTIME="$PYTHON_RUNTIME_SRC/python"
else
  fetch aarch64 "$PYTHON_RUNTIME_SHA256_ARM64"
  RUNTIME="$WORK/aarch64/python"
  if [ "${UNIVERSAL:-0}" = 1 ]; then
    fetch x86_64 "$PYTHON_RUNTIME_SHA256_X86_64"
    while IFS= read -r f; do
      rel="${f#"$RUNTIME"/}"
      other="$WORK/x86_64/python/$rel"
      [ -f "$other" ] || die "el runtime x86_64 no trae $rel"
      lipo -create "$f" "$other" -output "$f.fat"
      mv "$f.fat" "$f"
    done < <(find "$RUNTIME" -type f -print | while IFS= read -r f; do if is_macho "$f"; then printf '%s\n' "$f"; fi; done)
  fi
fi

# -- recorte: el agente es solo stdlib sin GUI; fuera tests, Tk, IDLE, cabeceras, pip y demás
rm -rf "$DEST"
mkdir -p "$DEST"
ditto "$RUNTIME" "$DEST/python"
PY="$DEST/python"
LIB="$PY/lib/python$PYMINOR"
[ -d "$LIB" ] || die "el runtime no trae lib/python$PYMINOR (¿python-runtime.version desfasado?)"
rm -rf "$PY/include" "$PY/share" "$PY/lib/pkgconfig" "$PY/lib/itcl"* "$PY/lib/tcl"* "$PY/lib/tk"* "$PY/lib/thread"* \
  "$PY/lib/libtcl"* "$PY/lib/libtk"* \
  "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/turtle.py" "$LIB/ensurepip" "$LIB/lib2to3" \
  "$LIB/pydoc_data" "$LIB/config-$PYMINOR-darwin" "$LIB/site-packages"/* "$LIB/lib-dynload/_tkinter"* "$LIB/lib-dynload/"*_test*
find "$PY/bin" -mindepth 1 ! -name python3 ! -name "python$PYMINOR" -exec rm -rf {} +
find "$DEST" -name __pycache__ -type d -prune -exec rm -rf {} +

# -- el agente y su punto de entrada
ditto "$AGENT_SRC" "$DEST/chopshop"
find "$DEST/chopshop" -name __pycache__ -type d -prune -exec rm -rf {} +
cat > "$DEST/chopshop-agent.py" <<'PY'
# Punto de entrada del agente incrustado en Chopshop.app (lo ejecuta Contents/MacOS/chopshop-agent con -I -B).
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop.cli import main  # noqa: E402

sys.exit(main(sys.argv[1:]))
PY

# -- firma ad-hoc de cada Mach-O (lipo invalida la firma original; arm64 no ejecuta código sin firmar)
while IFS= read -r f; do
  if is_macho "$f"; then
    out="$(codesign --force --sign - --timestamp=none "$f" 2>&1)" || die "no pude firmar ${f#"$DEST"/}: $out"
  fi
done < <(find "$PY" -type f -print)

# -- .pyc precompilados (sin comprobar mtime: el bundle firmado es de solo lectura y el agente corre con -B)
"$PY/bin/python3" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash "$LIB" "$DEST/chopshop" >/dev/null \
  || die "compileall falló"

# -- humo: el runtime arranca, trae lo que usa el agente y la CLI responde
"$PY/bin/python3" -I -B -c 'import sqlite3, ssl, json, http.server, hashlib, zlib' || die "al runtime le faltan módulos del agente"
"$PY/bin/python3" -I -B "$DEST/chopshop-agent.py" pair --help >/dev/null || die "la CLI del agente incrustado no arranca"
log "agente incrustado: Python $("$PY/bin/python3" -I -c 'import platform; print(platform.python_version())') ($(du -sh "$DEST" | awk '{print $1}'))"
