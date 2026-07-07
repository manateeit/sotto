#!/usr/bin/env bash
#
# Sotto voice-reply bridge for Claude Code.
#
# Fires on the Stop hook (agent finished a turn). Opens Sotto's recording pill
# via the sotto://reply deep link, waits for the user's spoken reply to be
# transcribed on-device, and feeds the transcript back as the next turn's
# context. Sotto only ever returns TEXT — nothing is executed.
#
# Requires: macOS (`open`), `jq`, and Sotto installed with "Voice replies to
# coding agents" enabled (Settings › General › Agents).
#
set -uo pipefail

# --- read the hook payload ---------------------------------------------------
INPUT="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0   # no jq → do nothing, let Claude stop

EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty')"
[ "$EVENT" = "Stop" ] || exit 0

# Loop guard: if this Stop is happening because a prior Stop hook already
# continued the turn, don't offer voice again — otherwise we'd never stop.
ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')"
[ "$ACTIVE" = "true" ] && exit 0

# Per-project off switch: `touch .sotto-disabled` in a repo to silence it there.
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
[ -n "$CWD" ] && [ -e "$CWD/.sotto-disabled" ] && exit 0

# --- hand off to Sotto -------------------------------------------------------
# A path that does NOT yet exist; Sotto creates it (atomically) when done —
# non-empty = the spoken reply, empty = user declined/cancelled.
RESP="${TMPDIR:-/tmp}/sotto-reply-$$-$(date +%s).txt"
RESP_ENC="$(printf '%s' "$RESP" | jq -sRr @uri)"

open "sotto://reply?response=${RESP_ENC}&agent=Claude%20Code" >/dev/null 2>&1 || exit 0

# --- wait for the reply ------------------------------------------------------
TIMEOUT="${SOTTO_REPLY_TIMEOUT:-90}"          # seconds
ITERS=$(( TIMEOUT * 5 ))                       # 0.2s polls
i=0
while [ ! -e "$RESP" ] && [ "$i" -lt "$ITERS" ]; do
  sleep 0.2
  i=$(( i + 1 ))
done

[ -e "$RESP" ] || exit 0                        # timed out (Sotto off / not installed)
TRANSCRIPT="$(cat "$RESP" 2>/dev/null)"
rm -f "$RESP"

# Empty = declined/cancelled → let Claude stop normally.
[ -n "$(printf '%s' "$TRANSCRIPT" | tr -d '[:space:]')" ] || exit 0

# --- inject the reply as the next turn --------------------------------------
jq -n --arg t "$TRANSCRIPT" '{
  decision: "block",
  reason: "Voice reply from the user via Sotto.",
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: ("The user replied by voice: " + $t)
  }
}'
exit 0
