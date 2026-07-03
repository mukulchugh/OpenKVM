#!/bin/bash
# Turnkey installer for the OTHER Mac (the receiver).
# Unzip, then double-click this file — or run: ./install-on-mac.sh
set -euo pipefail

APP_NAME="KeySwitch"
BUNDLE_ID="com.keyswitch.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="$SCRIPT_DIR/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

if [[ ! -d "$SRC_APP" ]]; then
    echo "Error: ${APP_NAME}.app not found next to this script."
    exit 1
fi

echo "==> Quitting any running KeySwitch..."
osascript -e 'quit app "KeySwitch"' 2>/dev/null || true
sleep 1

echo "==> Installing to ${DEST}..."
xattr -cr "$SRC_APP" 2>/dev/null || true
rm -rf "$DEST"
ditto "$SRC_APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

echo "==> Clearing stale permission entries from older builds..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset PostEvent     "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ListenEvent   "$BUNDLE_ID" 2>/dev/null || true

echo "==> Launching..."
open "$DEST"

echo ""
echo "Installed and running. On THIS Mac (the receiver):"
echo "  1. Approve the Accessibility prompt (or System Settings →"
echo "     Privacy & Security → Accessibility → enable KeySwitch)."
echo "  2. Open KeySwitch Settings and make sure"
echo "     \"This Mac has the physical keyboard\" is OFF."
echo ""
echo "Then on the Mac WITH the keyboard, press Command+Shift+K to switch."
