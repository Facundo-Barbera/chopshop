#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MAC_DIR=$PWD
REPO_ROOT=$(cd ../.. && pwd)

[ "$(uname -s)" = "Darwin" ] || { echo "dev.sh solo funciona en macOS." >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Falta xcodebuild: instala Xcode." >&2; exit 1; }
[ -f Resources/web/index.html ] && [ -f Resources/web/app.js ] || { echo "Falta Resources/web: ejecuta 'pnpm install && pnpm app' desde la raíz del repo." >&2; exit 1; }

INJECTION_APP=${INJECTION_APP:-/Applications/InjectionIII.app}
[ -d "$INJECTION_APP/Contents/Resources/macOSInjection.bundle" ] || echo "aviso: no encuentro $INJECTION_APP (descárgalo de https://github.com/johnno1962/InjectionIII/releases)" >&2

TAG=$(basename "$REPO_ROOT" | tr -c 'A-Za-z0-9\n' '_')_$(printf '%s' "$REPO_ROOT" | shasum | cut -c1-6)
WORKSPACE_NAME=ChopshopDev_$TAG
WORKSPACE=$MAC_DIR/$WORKSPACE_NAME.xcworkspace
for w in ChopshopDev_*.xcworkspace; do
  [ -e "$w" ] && [ "$MAC_DIR/$w" != "$WORKSPACE" ] && rm -rf "$w"
done
mkdir -p "$WORKSPACE"
cat > "$WORKSPACE/contents.xcworkspacedata" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "group:.">
   </FileRef>
</Workspace>
XML

RESOLVED_BACKUP=$(mktemp)
cp Package.resolved "$RESOLVED_BACKUP"
trap 'cp "$RESOLVED_BACKUP" Package.resolved; rm -f "$RESOLVED_BACKUP"' EXIT

export CHOPSHOP_HOT_RELOAD=1
XCB=(xcodebuild -workspace "$WORKSPACE" -scheme ChopshopUI -configuration Debug -destination "platform=macOS,arch=$(uname -m)")
"${XCB[@]}" EMIT_FRONTEND_COMMAND_LINES=YES COMPILER_INDEX_STORE_ENABLE=NO build -quiet
PRODUCTS=
for d in "$HOME/Library/Developer/Xcode/DerivedData/$WORKSPACE_NAME"-*; do
  [ "$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null)" = "$WORKSPACE" ] && PRODUCTS=$d/Build/Products/Debug
done
BIN=$PRODUCTS/ChopshopUI
[ -f "$BIN" ] || { echo "no encuentro el binario en $PRODUCTS" >&2; exit 1; }

VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' ../../package.json | head -1)
VERSION=${VERSION:-0.0.0}
APP=${CHOPSHOP_DEV_APP:-$MAC_DIR/dist/Chopshop Dev.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Chopshop"
cp -R Resources/web "$APP/Contents/Resources/web"
[ -d assets/AppIcon.iconset ] && iconutil -c icns assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Chopshop Dev</string>
<key>CFBundleDisplayName</key><string>Chopshop Dev</string>
<key>CFBundleIdentifier</key><string>local.chopshop.ui.dev</string>
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
SPARKLE_FRAMEWORK_SRC=$PRODUCTS/Sparkle.framework bash "$MAC_DIR/release/embed-sparkle.sh" "$APP"
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development: /{print $2; exit}')
if [ -n "$SIGN_ID" ]; then
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  echo "aviso: sin identidad «Apple Development» en el llavero; firma ad-hoc" >&2
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

cat <<TXT
listo: $APP

Hot reload:
  1. Abre $INJECTION_APP y, en su menú (icono de la jeringa), «Open Project» → elige la carpeta:
       $MAC_DIR
     (contiene $WORKSPACE_NAME.xcworkspace; InjectionIII vigila esa carpeta y lee los logs de su DerivedData)
  2. Abre la app:  open "$APP"
     En la consola (Console.app, proceso Chopshop) verás «💉 InjectionIII connected».
  3. Edita y guarda un .swift de Sources/: la vista se recompila y se redibuja sin reiniciar.
     Si cambias Package.swift, añades archivos o cambias de rama, vuelve a ejecutar $0.
TXT
