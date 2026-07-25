#!/bin/bash
# Build corral (release), wrap the SwiftPM executable in a proper Corral.app
# bundle (SwiftUI @main needs a bundle to present its window), ad-hoc sign it,
# and install to /Applications (falls back to ~/Applications). Repeatable.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
APP_NAME="Corral"
BIN_NAME="corral"

echo "==> swift build -c release"
swift build -c release
BIN=".build/release/${BIN_NAME}"
[ -x "$BIN" ] || { echo "error: $BIN not built"; exit 1; }

STAGE="$(mktemp -d)/${APP_NAME}.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/${BIN_NAME}"
[ -f Resources/Corral.icns ] && cp Resources/Corral.icns "$STAGE/Contents/Resources/Corral.icns"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>gr.krig.corral</string>
  <key>CFBundleExecutable</key><string>${BIN_NAME}</string>
  <key>CFBundleIconFile</key><string>Corral</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc sign"
codesign --force --sign - --timestamp=none "$STAGE" >/dev/null 2>&1 || \
  codesign --force --sign - "$STAGE"

if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/${APP_NAME}.app"
# ditto preserves bundle + resource forks
/usr/bin/ditto "$STAGE" "$DEST/${APP_NAME}.app"
rm -rf "$(dirname "$STAGE")"

echo "==> installed: $DEST/${APP_NAME}.app"
echo "    launch with: open -a ${APP_NAME}    (or double-click it)"
