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

# Ship the Codex Micro privileged helper and its installer with the app, so a
# cask install (no source checkout) can still run
# `sudo /Applications/Rai.app/Contents/Resources/microd-install.sh` on
# macOS 26.6+, where the pad needs the root helper.
[ -x "${BIN_DIR}/rai-microd" ] || { echo "error: ${BIN_DIR}/rai-microd not built"; exit 1; }
cp "${BIN_DIR}/rai-microd" "$STAGE/Contents/MacOS/rai-microd"
cp scripts/microd-install.sh "$STAGE/Contents/Resources/microd-install.sh"

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
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID" \
  || SIGN_ID="-"

# The ONLY place that pattern-matches $SIGN_ID into a signing tier — both
# sign_path() and the build-log line below switch on this plain string
# instead of each re-matching the glob, so the two can no longer drift out
# of sync with each other (they did, briefly: a prior version of this script
# printed the tier via its own separate case statement).
case "$SIGN_ID" in
  "-") SIGN_KIND="adhoc" ;;
  "Developer ID Application"*) SIGN_KIND="developer-id" ;;
  *) SIGN_KIND="local" ;;
esac

sign_path() {
  if [ "$SIGN_KIND" = "developer-id" ]; then
    # Notarization rejects anything without a hardened runtime and a secure
    # timestamp, so a Developer ID build must have both — no silent fallback
    # to an unstamped signature, or the release ships unnotarizable.
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$1"
  else
    # Local/ad-hoc identity: skip both. The timestamp server needs network,
    # and the hardened runtime only matters for distribution.
    codesign --force --sign "$SIGN_ID" --timestamp=none "$1" >/dev/null 2>&1 || \
      codesign --force --sign "$SIGN_ID" "$1"
  fi
}

# Nested standalone binaries are not covered by the bundle signature — sign
# inside-out (every Contents/MacOS binary, then the bundle). Only covers
# Contents/MacOS: a future Frameworks/XPCServices/embedded .app needs its own
# codesign call added here too — this loop does not walk those locations.
case "$SIGN_KIND" in
  adhoc) echo "==> ad-hoc sign" ;;
  developer-id) echo "==> sign ($SIGN_ID) + hardened runtime" ;;
  local) echo "==> sign ($SIGN_ID)" ;;
esac
for nested in "$STAGE"/Contents/MacOS/*; do
  [ "$(basename "$nested")" = "$BIN_NAME" ] && continue
  sign_path "$nested"
done
sign_path "$STAGE"

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
