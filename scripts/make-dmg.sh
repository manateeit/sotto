#!/usr/bin/env bash
#
# Package dist/Sotto.app into a distributable DMG: dist/Sotto-<version>.dmg.
# Stages the app + an /Applications symlink in a temp dir, then hdiutil
# compresses it into a UDZO image.
#
# Signing identity comes from $SIGN_IDENTITY, defaulting to "-" (ad-hoc, the
# signature scripts/make-app.sh already applied). Set it to a "Developer ID
# Application: ..." identity to slot in real signing with no script edits —
# see RELEASING.md for the full notarization flow.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Sotto"
APP="dist/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ ! -d "$APP" ]]; then
  echo "==> ${APP} not found; building it first…"
  bash scripts/make-app.sh
fi

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "==> Re-signing ${APP} with \"${SIGN_IDENTITY}\" (hardened runtime)…"
  codesign --force --deep --options runtime -s "$SIGN_IDENTITY" "$APP"
else
  echo "==> Using existing ad-hoc signature from scripts/make-app.sh"
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging DMG contents…"
cp -R "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Building ${DMG}…"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "==> Done: ${DMG}"
