# Sotto — Voice replies for Claude Code

Answer Claude Code **by voice**. When the agent finishes a turn, Sotto's
recording pill pops up; you speak your next instruction; your words become the
agent's next input. Everything is transcribed **on your Mac** — no cloud, no
account — and Sotto **never executes anything**: it only hands back text.

This is the *inbound* half of Sotto's agent story. The *outbound* half already
ships in the app: say "Sotto, type `npm test` into the terminal" and Sotto types
it — but **never presses Return**. Your keypress is always the execution gate.

## How it works

```
Claude Code finishes a turn
      │  (Stop hook)
      ▼
sotto-reply.sh  ──opens──►  sotto://reply?response=<tmpfile>
      │                           │
      │                     Sotto pops the pill: "Reply → Claude Code · ⌥Space to send"
      │                     you speak → on-device transcription → writes <tmpfile>
      ▼                           │
  polls <tmpfile> ◄───────────────┘
      │
      ▼
  injects your words as the next turn  ({"decision":"block", …additionalContext})
```

- **Press ⌥Space** to send your spoken reply; **Esc** to cancel (Claude just stops).
- Each agent turn offers **one** voice reply (a loop guard via `stop_hook_active`
  prevents an endless voice→turn→voice cycle).
- If Sotto is closed, the feature is off, or you don't reply, the hook unblocks
  and Claude stops normally — it never hangs your session.

## Requirements

- **macOS** with [Sotto](https://github.com/manateeit/sotto) installed.
- In Sotto: **Settings › General › Agents → enable "Voice replies to coding agents"** (off by default).
- [`jq`](https://jqlang.github.io/jq/) on your `PATH` (`brew install jq`).

## Install

**As a plugin (recommended):**

```bash
claude plugin marketplace add https://github.com/manateeit/sotto
claude plugin install sotto-voice
```

**Or for one session (dev):**

```bash
claude --plugin-dir /path/to/sotto/integrations/claude-code
```

**Or wire the hook by hand** — add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "/path/to/sotto/integrations/claude-code/hooks/sotto-reply.sh", "timeout": 120 }
        ]
      }
    ]
  }
}
```

## Tuning

- **Per-project off switch:** `touch .sotto-disabled` in a repo to silence voice
  replies there (stateless, keyed on the project dir).
- **Wait time:** `SOTTO_REPLY_TIMEOUT` (seconds, default `90`) — how long the hook
  waits for you to speak before letting Claude stop. Keep the `hooks.json`
  `timeout` a bit higher than this.

## Privacy

- Transcription is 100% on-device (Apple SpeechAnalyzer). No audio or text leaves
  your Mac.
- The handoff is a local temp file + a `sotto://` deep link — **no network, no
  loopback socket**. It preserves Sotto's zero-network-by-default guarantee.
- Sotto returns your reply as **text only**. It cannot run commands on the agent's
  behalf; any action the agent then takes still goes through Claude Code's own
  permission prompts.
