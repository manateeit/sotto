<p align="center">
  <img src="Assets/AppIcon.iconset/icon_128x128@2x.png" width="128" height="128" alt="Sotto icon">
</p>

<h1 align="center">Sotto</h1>

<p align="center"><em>sotto voce — speak quietly</em></p>

Press a key, speak, polished text appears in whatever app you're using. That's the whole product.

Sotto is a native macOS dictation app built on two ideas that most dictation apps trade away:

- **Private by default.** Zero network calls. Transcription runs on-device with Apple's SpeechAnalyzer; cleanup runs on-device with Apple's Foundation Models. No accounts, no telemetry, nothing phones home. The one exception is **Check for Updates…**, and it only ever runs when you click it — no background or startup checks. Cloud providers are opt-in and BYO-key, later.
- **Radically simple.** No mode system, no model picker, no settings maze. Sotto has exactly two behaviors — see below — and if you find yourself opening Settings in the first week, we've failed.

Your dictation history lives as plain JSONL + WAV files in `~/Library/Application Support/Sotto/history/`. Grep it, script it, delete it — it's yours.

![demo](docs/demo.gif)

## Requirements

- macOS 26 or later
- Apple Silicon
- Apple Intelligence enabled, for smart cleanup (see below)

Sotto works without Apple Intelligence too — it just degrades to raw, unprocessed dictation instead of refusing to run.

## Install

Prebuilt DMG: coming soon — link will go here once notarized releases start.

Until then, build from source (takes about a minute):

```bash
git clone https://github.com/manateeit/sotto.git
cd sotto
bash scripts/make-app.sh
open dist/Sotto.app
```

No Xcode required — the build uses the Swift toolchain that ships with Command Line Tools.

### Installing from the DMG

Open the DMG and a Finder window appears with Sotto on the left and an Applications shortcut on the right — drag one onto the other. On first launch, a welcome window walks you through granting Microphone and Accessibility, then a short "how to dictate" guide (the same guide reachable later from the menu bar via **Welcome & Permissions…**). If your menu bar is too full for macOS to show Sotto's icon, that same window tells you so — ⌥Space still dictates either way.

## Usage

Sotto lives in the menu bar. There's no Dock icon and no main window.

| Action | What it does |
|---|---|
| **⌥Space**, tap | Toggle recording — tap to start, tap again to stop |
| **⌥Space**, hold | Push-to-talk — record while held, stop on release |
| **Esc** while recording | Cancel — discards the recording, nothing is pasted |
| **⇧** held when you stop | Raw escape hatch — skips AI cleanup (vocabulary replacements still apply) |

That's the entire hotkey surface. One key, two gestures, one modifier.

**Dictate** is the default behavior: speak, and the cleaned-up transcript is pasted wherever your cursor is. Cleanup fixes punctuation and casing, drops filler words ("um", false starts), resolves self-corrections ("meet at 3 — no, 4" becomes "meet at 4"), and turns spoken URLs and emails into real ones. It never changes your meaning and never adds content that wasn't spoken.

**Transform** kicks in automatically when you select text before recording and speak an instruction — "make this a bullet list," "translate to formal English." Sotto applies the instruction to the selection and replaces it. If Sotto isn't confident your utterance was an instruction, it falls back to Dictate rather than guessing wrong.

Smart cleanup requires Apple Intelligence to be turned on (System Settings → Apple Intelligence & Siri). Without it, Sotto still works — it just always pastes raw transcripts, the same as holding ⇧.

## Voice commands

Start a dictation with the wake word **"Sotto"** and Sotto treats what follows as a command instead of text to paste:

- **"Sotto, open Safari"** — opens an app by name, or an https address ("Sotto, open github.com").
- **"Sotto, volume up"** — volume up, down, or mute.
- **"Sotto, run npm test"** — types `npm test` into your terminal and stops. **Sotto never presses Return** — you do. The command only lands if a supported terminal (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, VS Code) is frontmost.

Nothing runs on its own. When a command is recognized, a violet pill shows what will happen ("⏎ Terminal: npm test — ⌥Space to run · Esc to cancel"); it runs only when you re-tap ⌥Space, and Esc (or waiting 10 seconds) cancels it with nothing changed. If Sotto can't make sense of the command, it says "Didn't catch a command" and does nothing — the wake word only ever does something when a command actually parses.

Everything without the wake word is dictated exactly as before, so a sentence that isn't a command is never mistaken for one. Holding ⇧ on stop skips wake-word detection entirely (raw means raw). Parsing runs on-device with Apple's Foundation Models — no network, same privacy story as dictation. Turn the whole feature off with **Voice commands** in Settings.

Everything else lives in the menu bar dropdown:

- **Settings…** — hotkey rebinding, sounds, smart cleanup toggle, launch at login, and a History tab (retention period, keep/discard audio, browse/reveal the JSONL + WAV files, Delete All)
- **Check for Updates…** — on click, checks GitHub for a newer release and tells you whether one's available. Never runs automatically; see the privacy note below.
- **Welcome & Permissions…** — microphone and Accessibility grant status with deep links to System Settings, plus the "how to dictate" guide from first launch
- Vocabulary — hand-edit `~/Library/Application Support/Sotto/vocabulary.json` to teach Sotto names, jargon, and known misrecognitions; it's applied before smart cleanup, on both the smart and raw paths

## Troubleshooting

**Nothing happens when I press ⌥Space.** Sotto needs Microphone and Accessibility permission to record and paste. Open the menu bar icon → Permissions… and grant both. If you previously denied a permission, macOS won't re-prompt — you have to flip it on in System Settings yourself.

**Dictation pastes raw, unpunctuated text.** This means smart cleanup is unavailable — either Apple Intelligence is off (System Settings → Apple Intelligence & Siri) or your Mac doesn't support it. Click the menu bar icon to see the status line note (e.g. "Ready — smart cleanup off").

**First dictation after install is slow.** Apple Intelligence downloads its on-device model the first time it's used — this is a one-time cost, not a per-dictation delay. Subsequent runs are fast.

**Sotto won't paste into a password field.** That's intentional — Sotto refuses to inject text when secure input is active, the same protection your system already gives password fields.

## License

MIT. See [LICENSE](LICENSE).

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
