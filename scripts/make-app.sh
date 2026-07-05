#!/usr/bin/env bash
#
# Assemble dist/Sotto.app from a release build and ad-hoc codesign it.
# The app bundle is required for microphone + TCC permissions — the raw
# SwiftPM binary won't be granted them.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Sotto"
BUNDLE_ID="com.chrismckenna.sotto"
VERSION="0.0.1"
APP="dist/${APP_NAME}.app"

echo "==> Building release…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "$BIN_PATH" "${APP}/Contents/MacOS/${APP_NAME}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Sotto transcribes your dictation on-device.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Sotto transcribes your speech to text entirely on-device.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "==> Ad-hoc codesigning…"
codesign --force --deep -s - "$APP"

echo "==> Verifying signature…"
codesign -dv "$APP"

echo "==> Done: ${APP}"
