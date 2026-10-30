#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Chopshop.app solo se construye en macOS (Swift/SwiftUI). En otro sistema usa 'pnpm lint' para el resto del monorepo." >&2
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
BIN_DIR=$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)
BIN=$BIN_DIR/ChopshopUI
BUNDLE_ID=local.chopshop.ui

APP=${CHOPSHOP_APP:-$PWD/dist/Chopshop.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Chopshop"
cp -R Resources/web "$APP/Contents/Resources/web"
if [ -d assets/AppIcon.iconset ]; then
  iconutil -c icns assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Chopshop</string>
<key>CFBundleDisplayName</key><string>Chopshop</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
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

if [ "${EMBED_AGENT:-1}" != 0 ]; then
  cp "$BIN_DIR/ChopshopAgent" "$APP/Contents/MacOS/chopshop-agent"
  mkdir -p "$APP/Contents/Library/LaunchAgents"
  cat > "$APP/Contents/Library/LaunchAgents/chopshop-agent.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$BUNDLE_ID.agent</string>
<key>BundleProgram</key><string>Contents/MacOS/chopshop-agent</string>
<key>ProgramArguments</key><array><string>chopshop-agent</string><string>--launchd</string></array>
<key>AssociatedBundleIdentifiers</key><array><string>$BUNDLE_ID</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>30</integer>
<key>ProcessType</key><string>Background</string>
<key>LowPriorityIO</key><true/>
<key>Nice</key><integer>10</integer>
</dict></plist>
PL
  bash "$PWD/release/embed-agent.sh" "$APP"
fi

bash "$PWD/release/embed-sparkle.sh" "$APP"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "listo: $APP"
