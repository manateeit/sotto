<p align="center">
  <img src="Assets/AppIcon.iconset/icon_128x128@2x.png" width="128" height="128" alt="Sotto icon">
</p>

<h1 align="center">Sotto</h1>

<p align="center"><em>sotto voce — speak quietly</em></p>

Press a key, speak, polished text appears in whatever app you're using. That's the whole product.

Sotto is a native macOS dictation app built on two ideas that most dictation apps trade away:

- **Private by default.** Zero network calls. Transcription runs on-device with Apple's SpeechAnalyzer; cleanup runs on-device with Apple's Foundation Models. No accounts, no telemetry, nothing phones home. Cloud providers are opt-in and BYO-key, later.
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
git clone https://github.com/chrismckenna/sotto.git
cd sotto
bash scripts/make-app.sh
open dist/Sotto.app
```

No Xcode required — the build uses the Swift toolchain that ships with Command Line Tools.

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

Everything else lives in the menu bar dropdown:

- **Settings…** — hotkey rebinding, sounds, smart cleanup toggle, launch at login, and a History tab (retention period, keep/discard audio, browse/reveal the JSONL + WAV files, Delete All)
- **Permissions…** — microphone and Accessibility grant status, with deep links to System Settings
- Vocabulary — hand-edit `~/Library/Application Support/Sotto/vocabulary.json` to teach Sotto names, jargon, and known misrecognitions; it's applied before smart cleanup, on both the smart and raw paths

## Troubleshooting

**Nothing happens when I press ⌥Space.** Sotto needs Microphone and Accessibility permission to record and paste. Open the menu bar icon → Permissions… and grant both. If you previously denied a permission, macOS won't re-prompt — you have to flip it on in System Settings yourself.

**Dictation pastes raw, unpunctuated text.** This means smart cleanup is unavailable — either Apple Intelligence is off (System Settings → Apple Intelligence & Siri) or your Mac doesn't support it. Click the menu bar icon to see the status line note (e.g. "Ready — smart cleanup off").

**First dictation after install is slow.** Apple Intelligence downloads its on-device model the first time it's used — this is a one-time cost, not a per-dictation delay. Subsequent runs are fast.

**Sotto won't paste into a password field.** That's intentional — Sotto refuses to inject text when secure input is active, the same protection your system already gives password fields.

## License

MIT. See [LICENSE](LICENSE).

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
