#!/bin/bash
# Build rai, wrap the executable in an app bundle, sign it, and install it.
#
# Env overrides (used by CI, optional for local runs):
#   RAI_VERSION    CFBundleShortVersionString (default 0.1.0)
#   RAI_UNIVERSAL  =1 → build a universal arm64 + x86_64 binary
#   RAI_APP_DEST   place Rai.app in this dir instead of /Applications
#   RAI_BUILD_CHANNEL  development (default) or release
#   RAI_SIGN_IDENTITY  stable signing identity; required for releases
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
BUILD_CHANNEL="${RAI_BUILD_CHANNEL:-development}"
case "$BUILD_CHANNEL" in
  development)
    APP_NAME="Rai Dev"
    BUNDLE_ID="gr.krig.rai.dev"
    SIGN_ID="${RAI_SIGN_IDENTITY:-rai-dev-signing}"
    ;;
  release)
    APP_NAME="Rai"
    BUNDLE_ID="gr.krig.rai"
    SIGN_ID="${RAI_SIGN_IDENTITY:-}"
    case "$SIGN_ID" in
      "Developer ID Application"*) ;;
      *) echo "error: release builds require a Developer ID Application signing identity" >&2; exit 1 ;;
    esac
    ;;
  *) echo "error: RAI_BUILD_CHANNEL must be development or release" >&2; exit 1 ;;
esac
# Check before building or replacing an app. Never change the signing identity
# silently: macOS ties Input Monitoring grants to the code requirement.
if [ "$SIGN_ID" = "-" ] || ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
  echo "error: signing identity '$SIGN_ID' is unavailable; set RAI_SIGN_IDENTITY to a stable identity" >&2
  exit 1
fi
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

STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/${APP_NAME}.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/${BIN_NAME}"
cp "$BIN_DIR/rai-updater" "$STAGE/Contents/MacOS/rai-updater"
[ -f Resources/Rai.icns ] && cp Resources/Rai.icns "$STAGE/Contents/Resources/Rai.icns"
[ -f Resources/rai-hook.sh ] && cp Resources/rai-hook.sh "$STAGE/Contents/Resources/rai-hook.sh"

# SwiftPM resource bundles (e.g. SwiftTerm_SwiftTerm.bundle, which carries
# Shaders.metal). Without these in Contents/Resources, SwiftTerm's Metal
# renderer cannot find its shader source and falls back to CoreGraphics at
# runtime — a silent, GPU-less terminal.
for res_bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$res_bundle" ] || continue
  cp -R "$res_bundle" "$STAGE/Contents/Resources/"
done

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
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

case "$SIGN_ID" in
    "Developer ID Application"*)
      # Notarization rejects anything without a hardened runtime and a secure
      # timestamp, so a Developer ID build must have both — no silent fallback
      # to an unstamped signature, or the release ships unnotarizable.
      echo "==> sign ($SIGN_ID) + hardened runtime"
      codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$STAGE/Contents/MacOS/rai-updater"
      codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$STAGE"
      ;;
    *)
      # Local dev identity: skip both. The timestamp server needs network, and
      # the hardened runtime only matters for distribution.
      echo "==> sign ($SIGN_ID)"
      codesign --force --sign "$SIGN_ID" --timestamp=none "$STAGE/Contents/MacOS/rai-updater"
      codesign --force --sign "$SIGN_ID" --timestamp=none "$STAGE" >/dev/null 2>&1 || \
        codesign --force --sign "$SIGN_ID" "$STAGE"
      ;;
esac

if [ "$BUILD_CHANNEL" = release ]; then
  # Match the updater's publisher requirement before replacing any installed app.
  RELEASE_REQUIREMENT='identifier "gr.krig.rai" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "T2XB37WVYD"'
  codesign --verify --strict "-R=$RELEASE_REQUIREMENT" "$STAGE"
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

echo "==> installed: $DEST/${APP_NAME}.app"
echo "    launch with: open -a ${APP_NAME}    (or double-click it)"
