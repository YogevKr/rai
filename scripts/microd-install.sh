#!/bin/bash
# Install (or remove) the rai-microd privileged helper as a launchd daemon.
#
# macOS 26.6 blocks raw HID access to keyboard-class devices for non-root
# processes, which kills rai's direct Codex Micro link (input withheld, writes
# refused with kIOReturnNotPermitted). rai-microd runs as root, owns the pad
# link, and serves it to rai over a uid-restricted unix socket.
#
# From a source checkout, build first (as your normal user), then install:
#   swift build -c release --product rai-microd
#   sudo scripts/microd-install.sh
# From an installed Rai.app (cask), the helper binary ships in the bundle:
#   sudo /Applications/Rai.app/Contents/Resources/microd-install.sh
# Remove with:
#   sudo .../microd-install.sh --uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="gr.krig.rai.microd"
HELPER_DIR="/Library/PrivilegedHelperTools"
HELPER="$HELPER_DIR/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SOCKET="/var/run/rai-microd.sock"

[ "$EUID" -eq 0 ] || { echo "error: run with sudo"; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$HELPER" "$SOCKET" "$SOCKET.lock"
  echo "==> rai-microd removed"
  exit 0
fi

# The socket is chowned to (and peer-checked against) the invoking user, not
# root — rai runs as that user.
ALLOWED_UID="${SUDO_UID:-}"
[ -n "$ALLOWED_UID" ] && [ "$ALLOWED_UID" != "0" ] \
  || { echo "error: run via sudo from your user account (SUDO_UID missing)"; exit 1; }

# Repo build first (freshest), then the copy shipped inside Rai.app.
BIN=""
for candidate in \
  "$SCRIPT_DIR/../.build/release/rai-microd" \
  "$SCRIPT_DIR/../MacOS/rai-microd" \
  "/Applications/Rai.app/Contents/MacOS/rai-microd" \
  "/Users/${SUDO_USER:-}/Applications/Rai.app/Contents/MacOS/rai-microd"; do
  [ -x "$candidate" ] && { BIN="$candidate"; break; }
done
[ -n "$BIN" ] || {
  echo "error: rai-microd binary not found — from a checkout, build it first:"
  echo "  swift build -c release --product rai-microd"
  exit 1
}
echo "==> installing from $BIN"

mkdir -p "$HELPER_DIR"
install -m 755 -o root -g wheel "$BIN" "$HELPER"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HELPER</string>
        <string>--socket</string>
        <string>$SOCKET</string>
        <string>--uid</string>
        <string>$ALLOWED_UID</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>/var/log/rai-microd.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/rai-microd.log</string>
</dict>
</plist>
PLIST
chmod 644 "$PLIST"
chown root:wheel "$PLIST"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo "==> rai-microd installed (socket $SOCKET, uid $ALLOWED_UID)"
echo "==> toggle the Codex Micro integration off/on in rai, or relaunch rai"
