#!/usr/bin/env bash
#
# Package dist/Sotto.app into a distributable, Finder-styled DMG:
# dist/Sotto-<version>.dmg. Stages the app + an /Applications symlink + a
# generated background image, then attempts the classic guided-install look:
# build a writable DMG, mount it, drive Finder via AppleScript to set icon
# positions/background/window chrome (which Finder persists as a .DS_Store),
# unmount, then convert to a compressed read-only image.
#
# Finder scripting needs a real WindowServer session and Automation permission
# for osascript to control Finder — neither is guaranteed in a headless CI
# runner or a fresh permission-less session. try_style_dmg therefore runs
# entirely inside its own subshell; ANY failure there (missing background
# asset, hdiutil error, osascript denied/timeout) falls through to the plain
# `hdiutil create -format UDZO` path used before this script grew styling.
# This must never turn into a broken/failed build — only a plainer DMG.
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
BACKGROUND="Assets/dmg-background.png"

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
if [[ -f "$BACKGROUND" ]]; then
  mkdir -p "$STAGE/.background"
  cp "$BACKGROUND" "$STAGE/.background/background.png"
fi

rm -f "$DMG"

# Run "$@" with a hard wall-clock timeout, so a permission dialog with no one
# around to click it (or a wedged osascript) can't hang the build forever.
# macOS ships no `timeout(1)`, so this rolls a minimal one with a watcher job.
run_with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local watcher=$!
  local status=0
  wait "$pid" 2>/dev/null || status=$?
  kill "$watcher" 2>/dev/null || true
  return "$status"
}

# Everything in here runs in its own subshell with its own `set -e`: any failed
# command returns from the subshell (and thus this function) with a non-zero
# status, WITHOUT tripping the parent script's `set -e` — that's what lets the
# caller fall back to a plain DMG instead of aborting the build.
try_style_dmg() (
  set -euo pipefail
  [[ -f "$BACKGROUND" ]] || { echo "==> No ${BACKGROUND}; skipping Finder styling." >&2; exit 1; }

  rw="$(mktemp -u "${TMPDIR:-/tmp}/sotto-dmg-rw-XXXXXX").dmg"
  mnt="$(mktemp -d)"
  cleanup() { hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; rm -rf "$mnt" "$rw"; }
  trap cleanup EXIT

  size_mb=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -fs HFS+ \
    -format UDRW -size "${size_mb}m" "$rw" >/dev/null
  hdiutil attach "$rw" -mountpoint "$mnt" >/dev/null

  # Two-pass open/close: Finder is more reliable about actually writing the
  # .DS_Store with our icon view options if the window is closed once after
  # they're set, then reopened before the final `update`.
  run_with_timeout 30 osascript <<OSA
tell application "Finder"
  tell disk "${APP_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 120, 1060, 520}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "${APP_NAME}.app" of container window to {180, 170}
    set position of item "Applications" of container window to {480, 170}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA

  sync
  # osascript can exit 0 without doing anything useful when there's no
  # WindowServer/Finder session for it to drive (headless CI, no Automation
  # permission) — it just never renders a window, so no .DS_Store is written.
  # Exit status alone can't be trusted here; check the artifact it should have
  # produced.
  [[ -f "$mnt/.DS_Store" ]] || {
    echo "==> Finder never wrote a .DS_Store (no GUI session to script?) — treating styling as failed." >&2
    exit 1
  }
  hdiutil detach "$mnt" >/dev/null
  hdiutil convert "$rw" -format UDZO -ov -o "$DMG" >/dev/null
)

echo "==> Styling DMG via Finder…"
if try_style_dmg; then
  echo "==> Styled DMG built: ${DMG}"
else
  echo "warning: DMG Finder styling failed or unavailable (no WindowServer session, Automation permission denied, or timed out) — falling back to a plain DMG. Drag-to-Applications still works via the symlink." >&2
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

echo "==> Done: ${DMG}"
