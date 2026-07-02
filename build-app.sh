#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="KeySwitch"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
ARM_BIN="$ROOT/.build/arm64-apple-macosx/release/$APP_NAME"
INTEL_BIN="$ROOT/.build/x86_64-apple-macosx/release/$APP_NAME"

echo "Building ${APP_NAME} (Apple Silicon + Intel)..."
cd "$ROOT"
swift build -c release --arch arm64
swift build -c release --arch x86_64

echo "Packaging ${APP_NAME}.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

lipo -create -output "$APP_DIR/Contents/MacOS/$APP_NAME" "$ARM_BIN" "$INTEL_BIN"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "Binary architectures:"
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
    # Stable identity keeps TCC/Accessibility permission across rebuilds
    # (ad-hoc "-" changes every build, breaking the permission each time).
    # Create it once with: ./scripts/make-signing-cert.sh
    if security find-identity -v -p codesigning | grep -q "KeySwitch Dev"; then
        SIGN_ID="KeySwitch Dev"
    else
        SIGN_ID="-"
        echo "NOTE: signing ad-hoc. Run ./scripts/make-signing-cert.sh once so"
        echo "      Accessibility permission survives rebuilds."
    fi
    codesign --force --deep --sign "$SIGN_ID" "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"
fi

echo "Done: $APP_DIR"
echo "Install: cp -R '$APP_DIR' /Applications/"