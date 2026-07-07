#!/usr/bin/env bash
#
# Clean uninstall of Sotto. Removes the app, its privacy grants (TCC),
# Launch Services registration, preferences, and all user data.
#
# Apple stores microphone/accessibility/speech grants in the TCC database,
# NOT in the app or its prefs — so removing the .app leaves stale grants
# behind. `tccutil reset` is the supported way to clear them.
#
set -uo pipefail

BUNDLE_ID="com.chrismckenna.sotto"
APP_NAME="Sotto"

echo "🧹 Uninstalling ${APP_NAME} (${BUNDLE_ID})…"

# 1. Quit any running instance.
if pgrep -f "$APP_NAME" >/dev/null; then
  echo "   • Quitting running ${APP_NAME}…"
  pkill -f "$APP_NAME" || true
  sleep 1
fi

# 2. Reset all privacy grants (microphone, accessibility, speech recognition).
#    Scoped to our bundle ID so no other app is affected.
echo "   • Resetting privacy permissions (TCC)…"
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true

# 3. Remove app bundles from every location it may have been installed/built to.
echo "   • Removing app bundles…"
for path in \
  "/Applications/${APP_NAME}.app" \
  "${HOME}/Applications/${APP_NAME}.app" \
  "$(cd "$(dirname "$0")/.." && pwd)/dist/${APP_NAME}.app"; do
  if [[ -e "$path" ]]; then
    echo "     - $path"
    # Unregister from Launch Services before deleting, so `open Sotto.app`
    # can't resolve to a ghost record afterward.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -u "$path" 2>/dev/null || true
    rm -rf "$path"
  fi
done

# 4. Remove preferences.
echo "   • Removing preferences…"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "${HOME}/Library/Preferences/${BUNDLE_ID}.plist"

# 5. Remove user data (history JSONL, WAV audio, vocabulary.json).
echo "   • Removing application support data…"
rm -rf "${HOME}/Library/Application Support/${APP_NAME}"

# 6. Remove caches and logs.
echo "   • Removing caches and logs…"
rm -rf "${HOME}/Library/Caches/${BUNDLE_ID}"
rm -rf "${HOME}/Library/Logs/${APP_NAME}"

echo "✅ ${APP_NAME} fully removed (app, TCC grants, prefs, data)."
echo ""
echo "   Microphone/Accessibility grants are cleared — the next launch will"
echo "   prompt fresh. Reinstall with:  bash scripts/make-app.sh && open dist/${APP_NAME}.app"
