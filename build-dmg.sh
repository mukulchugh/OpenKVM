#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="KeySwitch"
DMG_NAME="KeySwitch"
STAGING="$ROOT/dist/dmg-staging"
DMG_RW="$ROOT/dist/${DMG_NAME}.rw.dmg"
DMG_FINAL="$ROOT/dist/${DMG_NAME}.dmg"
ZIP_FINAL="$ROOT/dist/${DMG_NAME}.zip"
APP_DIR="$ROOT/dist/${APP_NAME}.app"

echo "==> Building universal app..."
"$ROOT/build-app.sh"

echo "==> Preparing DMG staging folder..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP_DIR" "$STAGING/${APP_NAME}.app"
cp "$ROOT/scripts/install-on-mac.sh" "$STAGING/"
chmod +x "$STAGING/install-on-mac.sh"
ln -sf /Applications "$STAGING/Applications"

echo "==> Creating DMG..."
rm -f "$DMG_RW" "$DMG_FINAL"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$DMG_RW"

echo "==> Compressing DMG..."
hdiutil convert "$DMG_RW" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_FINAL"

rm -f "$DMG_RW"
rm -rf "$STAGING"
xattr -cr "$DMG_FINAL" 2>/dev/null || true

echo "==> Creating ZIP (use this if DMG says damaged)..."
rm -f "$ZIP_FINAL"
(
  cd "$ROOT/dist"
  zip -r -y "$ZIP_FINAL" "${APP_NAME}.app" -x "*.DS_Store"
  cp "$ROOT/scripts/install-on-mac.sh" "$ROOT/dist/"
  zip -j "$ZIP_FINAL" "$ROOT/scripts/install-on-mac.sh"
)
xattr -cr "$ZIP_FINAL" 2>/dev/null || true
rm -f "$ROOT/dist/install-on-mac.sh"

echo "==> Verifying DMG..."
hdiutil verify "$DMG_FINAL"

echo "==> Mount test..."
MOUNT_OUTPUT=$(hdiutil attach "$DMG_FINAL" -nobrowse -readonly)
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | awk '/\/Volumes\// {print $3; exit}')
cleanup() {
  if [[ -n "${MOUNT_POINT:-}" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
}
trap cleanup EXIT

test -d "$MOUNT_POINT/${APP_NAME}.app"
test -x "$MOUNT_POINT/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

echo ""
echo "Done:"
echo "  DMG: $DMG_FINAL ($(du -h "$DMG_FINAL" | awk '{print $1}'))"
echo "  ZIP: $ZIP_FINAL ($(du -h "$ZIP_FINAL" | awk '{print $1}')) — preferred for the other Mac"
echo ""
echo "On the other Mac, if DMG says damaged:"
echo "  1. Use KeySwitch.zip instead"
echo "  2. Unzip, then run: chmod +x install-on-mac.sh && ./install-on-mac.sh"
echo "  Or: xattr -cr KeySwitch.dmg && open KeySwitch.dmg"