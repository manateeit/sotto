#!/usr/bin/env bash
#
# Create a stable, self-signed code-signing identity ("Sotto Dev") in the
# login keychain, so ad-hoc rebuilds stop breaking the TCC Accessibility grant.
#
# Ad-hoc signatures (codesign -s -) change every build, so macOS treats each
# rebuild as a new app and drops privacy grants. A stable identity keeps the
# code's Designated Requirement constant across builds → grant once, forever.
#
# Idempotent: does nothing if the identity already exists. Remove with:
#   security delete-identity -c "Sotto Dev" ~/Library/Keychains/login.keychain-db
#
set -uo pipefail

CERT_NAME="Sotto Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✅ Code-signing identity \"${CERT_NAME}\" already present."
  exit 0
fi

echo "==> Creating self-signed code-signing identity \"${CERT_NAME}\"…"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Key + self-signed cert with the codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TMP}/key.pem" \
  -out "${TMP}/cert.pem" \
  -days 3650 \
  -subj "/CN=${CERT_NAME}" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Import the PEM key and cert directly (avoids the OpenSSL 3.x PKCS#12 MAC
# incompatibility with macOS `security`). macOS pairs the key + matching cert
# into a single identity automatically. -T pre-authorizes codesign to use the key.
security import "${TMP}/key.pem" \
  -k "$KEYCHAIN" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security import "${TMP}/cert.pem" \
  -k "$KEYCHAIN" \
  -T /usr/bin/codesign

# Trust the cert for code signing in the user domain (no sudo). May prompt once
# for the keychain password via a GUI dialog — approve it.
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "${TMP}/cert.pem" 2>/dev/null || \
  echo "   (trust step skipped or already trusted — signing still works)"

echo ""
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✅ \"${CERT_NAME}\" is ready. Build with: bash scripts/make-app.sh"
else
  echo "⚠️  Identity imported but not yet listed as valid. The first codesign"
  echo "    run may show a keychain prompt — click \"Always Allow\"."
fi
