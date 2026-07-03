#!/bin/bash
# Full clean install: quit, remove app, reset ALL permissions, clear saved
# settings, reinstall the unified signed build from release/, relaunch.
# Run on BOTH Macs. Usage: ./scripts/clean-install.sh
set -euo pipefail

APP="KeySwitch"
BUNDLE="com.keyswitch.app"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/release/${APP}.zip"

if [[ ! -f "$ZIP" ]]; then
    echo "Error: $ZIP not found. Run 'git pull' first."
    exit 1
fi

echo "==> Quitting KeySwitch..."
osascript -e 'quit app "KeySwitch"' 2>/dev/null || true
sleep 1
pkill -9 -f "KeySwitch.app/Contents/MacOS" 2>/dev/null || true
sleep 1

echo "==> Removing old app..."
rm -rf "/Applications/${APP}.app"

echo "==> Resetting permissions (Accessibility, Input Monitoring, PostEvent)..."
tccutil reset Accessibility "$BUNDLE" 2>/dev/null || true
tccutil reset PostEvent     "$BUNDLE" 2>/dev/null || true
tccutil reset ListenEvent   "$BUNDLE" 2>/dev/null || true

echo "==> Clearing saved settings..."
defaults delete "$BUNDLE" 2>/dev/null || true

echo "==> Installing fresh from release/${APP}.zip..."
TMP="$(mktemp -d)"
unzip -oq "$ZIP" -d "$TMP"
xattr -cr "$TMP/${APP}.app" 2>/dev/null || true
ditto "$TMP/${APP}.app" "/Applications/${APP}.app"
xattr -cr "/Applications/${APP}.app" 2>/dev/null || true
rm -rf "$TMP"

echo "==> Launching..."
open "/Applications/${APP}.app"

echo ""
echo "Clean install done. Next:"
echo "  1. Grant Accessibility (and Input Monitoring on the keyboard Mac) when macOS prompts."
echo "  2. On the Mac WITH the keyboard: Settings → turn ON 'This Mac has the keyboard & mouse'."
echo "     On the other Mac: leave it OFF."
echo "  3. Pair: Settings → click Pair next to the other Mac → Approve on that Mac."
echo "  4. Press Cmd+Shift+K on the keyboard Mac to switch."
