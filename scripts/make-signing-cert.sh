#!/bin/bash
# Creates a self-signed code-signing certificate named "KeySwitch Dev" in the
# login keychain. Run ONCE per Mac. build-app.sh picks it up automatically.
#
# Why: macOS ties Accessibility (TCC) permission to the app's code signature.
# Ad-hoc signatures change on every build, so the permission breaks after each
# rebuild. A stable local cert means you grant Accessibility once and it sticks.
set -euo pipefail

CERT_NAME="KeySwitch Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "'$CERT_NAME' already exists. Nothing to do."
    exit 0
fi

echo "==> Generating self-signed code-signing certificate '$CERT_NAME'..."
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

echo "==> Importing into login keychain (allow codesign access)..."
security import "$TMP/key.pem" -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign

echo "==> Trusting for code signing (macOS may show a password prompt — approve it)..."
security add-trusted-cert -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"

echo ""
security find-identity -v -p codesigning | grep "$CERT_NAME" || true
echo "Done. build-app.sh will now sign with '$CERT_NAME'."
echo "After the NEXT install, re-add KeySwitch in System Settings → Privacy & Security"
echo "→ Accessibility one final time. It will survive all future rebuilds."
