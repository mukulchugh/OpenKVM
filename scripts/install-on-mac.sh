#!/bin/bash
# Run this on the Mac where KeySwitch shows as "damaged".
# Usage: chmod +x install-on-mac.sh && ./install-on-mac.sh
set -euo pipefail

APP_NAME="KeySwitch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="$SCRIPT_DIR/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

if [[ ! -d "$SRC_APP" ]]; then
    echo "Error: ${APP_NAME}.app not found next to this script."
    exit 1
fi

echo "Removing quarantine flags..."
xattr -cr "$SRC_APP" 2>/dev/null || true

echo "Installing to ${DEST}..."
rm -rf "$DEST"
ditto "$SRC_APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

echo ""
echo "Installed. First launch:"
echo "  1. Open Finder → Applications"
echo "  2. Right-click KeySwitch → Open"
echo "  3. Click Open in the dialog (only needed once)"
echo "  4. Grant Bluetooth + Local Network when prompted"