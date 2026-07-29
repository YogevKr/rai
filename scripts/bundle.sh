#!/bin/bash
# Build rai (release), wrap the SwiftPM executable in a proper Rai.app
# bundle (SwiftUI @main needs a bundle to present its window), ad-hoc sign it,
# and install to /Applications (falls back to ~/Applications). Repeatable.
#
# Env overrides (used by CI, optional for local runs):
#   RAI_VERSION    CFBundleShortVersionString (default 0.1.0)
#   RAI_UNIVERSAL  =1 → build a universal arm64 + x86_64 binary
#   RAI_APP_DEST   place Rai.app in this dir instead of /Applications
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
APP_NAME="Rai"
BIN_NAME="rai"
APP_VERSION="${RAI_VERSION:-0.1.0}"

BUILD_ARGS=(-c release)
if [ "${RAI_UNIVERSAL:-0}" = "1" ]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${BUILD_ARGS[*]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
swift build "${BUILD_ARGS[@]}"
BIN="${BIN_DIR}/${BIN_NAME}"
[ -x "$BIN" ] || { echo "error: $BIN not built"; exit 1; }

STAGE="$(mktemp -d)/${APP_NAME}.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/${BIN_NAME}"
[ -f Resources/Rai.icns ] && cp Resources/Rai.icns "$STAGE/Contents/Resources/Rai.icns"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>gr.krig.rai</string>
  <key>CFBundleExecutable</key><string>${BIN_NAME}</string>
  <key>CFBundleIconFile</key><string>Rai</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>gr.krig.rai.tab</string>
      <key>UTTypeDescription</key><string>Rai Tab</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>gr.krig.rai.workspace</string>
      <key>UTTypeDescription</key><string>Rai Space</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>gr.krig.rai.pane</string>
      <key>UTTypeDescription</key><string>Rai Pane</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Prefer a stable local code-signing identity so macOS TCC grants (e.g. Input
# Monitoring for the Codex Micro pad) persist across rebuilds. Falls back to
# ad-hoc where the identity isn't present (CI, other machines).
SIGN_ID="${RAI_SIGN_IDENTITY:-rai-dev-signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  case "$SIGN_ID" in
    "Developer ID Application"*)
      # Notarization rejects anything without a hardened runtime and a secure
      # timestamp, so a Developer ID build must have both — no silent fallback
      # to an unstamped signature, or the release ships unnotarizable.
      echo "==> sign ($SIGN_ID) + hardened runtime"
      codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$STAGE"
      ;;
    *)
      # Local dev identity: skip both. The timestamp server needs network, and
      # the hardened runtime only matters for distribution.
      echo "==> sign ($SIGN_ID)"
      codesign --force --sign "$SIGN_ID" --timestamp=none "$STAGE" >/dev/null 2>&1 || \
        codesign --force --sign "$SIGN_ID" "$STAGE"
      ;;
  esac
else
  echo "==> ad-hoc sign"
  codesign --force --sign - --timestamp=none "$STAGE" >/dev/null 2>&1 || \
    codesign --force --sign - "$STAGE"
fi

if [ -n "${RAI_APP_DEST:-}" ]; then
  DEST="$RAI_APP_DEST"; mkdir -p "$DEST"
elif [ -w /Applications ]; then
  DEST=/Applications
else
  DEST="$HOME/Applications"; mkdir -p "$DEST"
fi
rm -rf "$DEST/${APP_NAME}.app"
# ditto preserves bundle + resource forks
/usr/bin/ditto "$STAGE" "$DEST/${APP_NAME}.app"
rm -rf "$(dirname "$STAGE")"

echo "==> installed: $DEST/${APP_NAME}.app"
echo "    launch with: open -a ${APP_NAME}    (or double-click it)"
