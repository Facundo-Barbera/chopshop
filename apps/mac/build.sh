#!/bin/bash
# Construye Chopshop.app: un único .app (SwiftUI + WKWebView) que es cliente puro de la API del agente.
# Sin Python ni motor embebido: solo el ejecutable, la UI web (Resources/web) y el icono.
#
#   pnpm app                       # desde la raíz: construye la UI (apps/ui) y llama a este script
#   apps/mac/build.sh              # solo el .app, con la UI ya construida en apps/mac/Resources/web
#
# Salida: apps/mac/dist/Chopshop.app (ignorada por git). Variables opcionales:
#   CHOPSHOP_APP=/ruta/Chopshop.app   otra ruta de salida
#   REBUILD_WEB=1                     reconstruir antes la UI (requiere `pnpm install`)
#   UNIVERSAL=1                       binario arm64 + x86_64 (requiere Xcode completo)
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Chopshop.app solo se construye en macOS (Swift/SwiftUI). En otro sistema usa 'pnpm test' para el resto del monorepo." >&2
  exit 1
fi
command -v swift >/dev/null || { echo "Falta swift: instala Xcode o las Command Line Tools (xcode-select --install)." >&2; exit 1; }

if [ "${REBUILD_WEB:-0}" = 1 ]; then
  (cd ../ui && pnpm run --silent build)
fi
[ -f Resources/web/index.html ] && [ -f Resources/web/app.js ] || { echo "Falta Resources/web: ejecuta 'pnpm install && pnpm app' desde la raíz del repo." >&2; exit 1; }

VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' ../../package.json | head -1)
VERSION=${VERSION:-0.0.0}
ARCHS=()
[ "${UNIVERSAL:-0}" = 1 ] && ARCHS=(--arch arm64 --arch x86_64)

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN=$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/ChopshopUI

APP=${CHOPSHOP_APP:-$PWD/dist/Chopshop.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Chopshop"
cp -R Resources/web "$APP/Contents/Resources/web"
if [ -d assets/AppIcon.iconset ]; then
  iconutil -c icns assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# ATS: el agente habla HTTP plano, pero solo por Tailscale (cifrado WireGuard), a veces con nombres MagicDNS que ATS
# bloquearía; la app solo se conecta a las URLs que el usuario pone en su config.toml.
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Chopshop</string>
<key>CFBundleDisplayName</key><string>Chopshop</string>
<key>CFBundleIdentifier</key><string>local.chopshop.ui</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>Chopshop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>NSLocalNetworkUsageDescription</key><string>Chopshop se conecta a los agentes de tus máquinas por la red (Tailscale).</string>
</dict></plist>
PL

# Sparkle (auto-actualización): el ejecutable enlaza Sparkle.framework, así que va dentro del bundle. Sin SUFeedURL en
# el Info.plist (build local) el updater queda inactivo; las claves de release las pone release/assemble-app.sh.
bash "$PWD/release/embed-sparkle.sh" "$APP"

# Firma ad-hoc (sin cuenta de desarrollador): Gatekeeper pedirá «Abrir» la primera vez (ver docs/mac-build.md).
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "listo: $APP"
