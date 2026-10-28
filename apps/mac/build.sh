#!/bin/bash
# Construye la UI: React (apps/ui, esbuild) -> apps/mac/Resources/web, y el shell SwiftUI -> ~/Applications/Chopshop.app (con el motor python embebido)
set -euo pipefail
cd "$(dirname "$0")"
UI=../ui
export PATH=/opt/homebrew/bin:$PATH
if [ -d $UI/node_modules ] || [ "${REBUILD_WEB:-0}" = 1 ]; then
  (cd $UI && { [ -d node_modules ] || pnpm install --silent; } && pnpm run --silent build)
else
  echo "apps/ui/node_modules no existe: uso apps/mac/Resources/web ya construido (REBUILD_WEB=1 para reconstruir)"
fi
swift build -c release 2>&1 | tail -25
APP=${CHOPSHOP_APP:-$HOME/Applications/Chopshop.app}
rm -rf "$APP"; mkdir -p "$(dirname "$APP")" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ChopshopUI "$APP/Contents/MacOS/Chopshop"
cp -R Resources/web "$APP/Contents/Resources/web"
[ -d assets/AppIcon.iconset ] && iconutil -c icns assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/engine/bin"
cp -R ../agent/chopshop "$APP/Contents/Resources/engine/chopshop"
find "$APP/Contents/Resources/engine" -name __pycache__ -prune -exec rm -rf {} +
cp ../agent/bin/chopshop "$APP/Contents/Resources/engine/bin/chopshop"
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
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PL
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "listo: $APP"
