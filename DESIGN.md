# Sotto — Design & MVP Plan

*(working name — "sotto voce", speak quietly; trivially renameable)*

A native macOS dictation app: press a key, speak, polished text appears in whatever app you're using.
Open source (MIT). Everything on-device by default. Cloud is opt-in, per-provider, BYO-key.

**Identity — three principles, in priority order:**

1. **Privacy-absolute.** Default build makes zero network calls. On-device STT, on-device LLM. No accounts, no telemetry, no update phone-home without consent.
2. **Radically simpler.** superwhisper has 7 modes, model pickers, and a settings maze. We ship **two behaviors and no mode system**. If a user opens settings in the first week, we've failed.
3. **Agentic ceiling.** The post-processing seam is designed so voice can eventually *act* (tool calling, Claude Code integration), not just format. MVP does transforms only; the seam makes actions cheap later.

---

## 1. Feature scorecard vs superwhisper

### Clone (MVP)
| superwhisper feature | Our version |
|---|---|
| Global hotkey → record → paste anywhere | Same. Push-to-talk *and* toggle on one key. |
| Floating recording HUD w/ waveform + states | Same, one compact pill (no mini/maxi dual window). |
| Local transcription (whisper.cpp model zoo) | **Apple SpeechAnalyzer** — zero model downloads, ANE-fast. |
| AI post-processing via cloud LLMs | **Apple Foundation Models** — on-device, free. |
| Modes (Message/Email/Note/Super/Custom…) | **Deleted.** Two auto behaviors: Dictate + Transform (§3). |
| Context awareness (selection/clipboard/app) | Same three sources, same timing rules. Always on. |
| Custom vocabulary | Replacement table + prompt-bias in cleanup pass. |
| History + reprocess | JSONL + audio files, open format. Reprocess post-MVP. |
| Sounds, cancel, Esc, launch-at-login | Same. |

### Cut (deliberately — most may never come back)
- Mode system, per-mode model/prompt config, auto-activation rules
- Accounts, billing, Pro tiers, enterprise (SSO/SCIM/MDM)
- Windows, iOS
- Meeting recording + speaker diarization *(roadmap — FluidAudio ships diarization when we want it)*
- File transcription, realtime streaming display *(roadmap; SpeechAnalyzer supports streaming, cheap to add)*
- Translation

### Add (our differentiators)
- **Zero-config smart dictation** — context awareness isn't a "Super mode" you configure; it's just how the app works.
- **Open data** — history is JSONL + WAV in Application Support. Grep it, script it, delete it.
- **Agentic seam (post-MVP)** — "voice command" behavior with Foundation Models tool calling; route to Ollama/Claude by user choice. Target use case: driving Claude Code / terminal by voice.

---

## 2. Architecture

```
        HotkeyManager (RegisterEventHotKey — no Input Monitoring perm needed)
              │ down/up (push-to-talk)  or  tap (toggle)
              ▼
        Recorder ── AVAudioEngine, 16 kHz mono float ──► ring buffer + WAV to disk
              │ streaming buffers                        │
              ▼                                          ▼
   ┌─ TranscriptionEngine (protocol) ─┐            HistoryStore (JSONL + audio)
   │  SpeechAnalyzerEngine   (MVP)    │
   │  ParakeetEngine (FluidAudio, later)
   └──────────────┬───────────────────┘
                  │ raw transcript
                  ▼
        VocabularyRewriter — plain string/regex replacement table
                  ▼
   ┌─ PostProcessor (protocol) ───────┐    ◄── ContextSnapshot
   │  SmartProcessor (FoundationModels│         • selected text   (AX, at record start)
   │    guided generation, MVP)       │         • clipboard       (≤3 s before / during)
   │  Passthrough (raw)               │         • frontmost app, window title, focused-field text
   │  (later: Ollama / Anthropic /    │
   │   OpenAI behind the same seam)   │
   └──────────────┬───────────────────┘
                  │ final text
                  ▼
        OutputInjector — AX setValue into focused element when possible,
                         else pasteboard + synthetic ⌘V, then restore pasteboard.
                         Refuses when secure input is active (IsSecureEventInputEnabled).
```

**Exactly two protocol seams** — `TranscriptionEngine` and `PostProcessor` — because both have concrete planned second implementations. Everything else is a plain type. No plugin system, no DI framework.

UI: `MenuBarExtra` (menu bar icon, no Dock), one non-activating floating `NSPanel` HUD, one SwiftUI settings window. State in `UserDefaults` via `@AppStorage`.

---

## 3. The two behaviors (replaces the mode system)

**Dictate** (default): speak → transcript → SmartProcessor cleanup → paste.
Cleanup contract: fix punctuation/casing/paragraphs, drop filler ("um", false starts), apply self-corrections ("meet at 3 — no, 4" → "meet at 4"), spoken URLs/emails → real ones, **never change meaning or tone, never add content**. Foundation Models guided generation returns a typed struct, so output is the cleaned string — no prompt-injection-shaped surprises from the transcript.

**Transform**: if text was selected when recording started *and* the utterance is imperative ("make this a bullet list", "translate to formal English"), apply the instruction to the selection and replace it. Intent classification = one guided-generation call returning an enum (`.dictation` / `.transform`). When unsure → Dictate (never surprise the user).

**Raw escape hatch**: hold ⇧ when stopping → skip post-processing entirely. Also auto-skip when Foundation Models is unavailable (Apple Intelligence off) or the recording exceeds a length cap — paste fast, never hostage the user to a slow model.

**Voice commands** (M6): commands ride the same ⌥Space flow. After transcription + vocabulary rewrite, a deterministic prefix check looks for the spoken wake word "Sotto" (first word only, fuzzy STT variants accepted). No wake word → the dictate/transform pipeline above runs byte-for-byte unchanged (a prefix check is the only added cost); ⇧-raw bypasses the check entirely. With the wake word, the stripped utterance is parsed by one Foundation Models call — a **parser only**, never an attached tool (attached tools auto-invoke before a human confirms, which is forbidden). A curated map of *universal* phrases ("open …", "volume up/down/mute", "type/run …") resolves without any model call. The typed result routes to one of three commands behind the `VoiceCommand` seam — open an app/https-URL (tier 0), volume up/down/mute via CoreAudio (tier 0), or paste text into an allowlisted terminal and **never press Return** (tier 1, the human's Return is the execution gate). Every command — tier 0 included — shows a violet confirm pill and does nothing until the user re-taps ⌥Space (Esc or a 10 s timeout cancels, leaving the world untouched). Unknown / low-confidence / model-unavailable → "Didn't catch a command", nothing runs. Off by default? No — on by default, one toggle to disable. Parsing is on-device; nothing about commands changes the privacy story.

That's the whole product surface. Per-app behavior overrides only if real usage demands them.

---

## 4. Tech choices & rationale

| Concern | Choice | Why (and what we rejected) |
|---|---|---|
| Language/UI | Swift 6 + SwiftUI, AppKit where needed | Native APIs are the product (AX, hotkeys, panels). Rejected Tauri/Electron: AX bridging pain, footprint. |
| STT | **SpeechAnalyzer / DictationTranscriber** (macOS 26) | Native platform feature: on-device, ANE, streaming, ~55% faster than Whisper in benchmarks, **zero model management**. Rejected whisper.cpp for MVP: 1.5–3 GB downloads + C++ build contradict "radically simpler". |
| STT fallback | FluidAudio ParakeetEngine (post-MVP, behind the seam) | MIT/Apache Swift package, ANE CoreML, 25 langs; covers SpeechAnalyzer quality gaps incl. its missing custom-vocab API. |
| LLM cleanup | **Foundation Models framework** | On-device ~3B, free, private, guided generation gives typed output, tool calling for the agentic roadmap. WWDC26 opened the framework to third-party providers → Ollama/Claude plug into the *same* API later. |
| Hotkey | Carbon `RegisterEventHotKey` | Works globally with **no Input Monitoring permission**. CGEventTap (needed for Fn/Globe key) is roadmap. |
| Context capture | `AXUIElement` + NSPasteboard changeCount polling | Same mechanism superwhisper uses; needs Accessibility permission (also enables ⌘V synth). |
| Persistence | JSONL + WAV files; `UserDefaults` for settings | No DB, no schema migration, user-greppable. Rejected SwiftData/GRDB: nothing here needs queries. |
| Distribution | Non-sandboxed, Developer ID signed, notarized DMG | AX APIs rule out App Store sandbox. GitHub Releases; Sparkle updates post-MVP (opt-in, privacy note). |
| License | MIT | FluidAudio is MIT/Apache — compatible. **VoiceInk is GPLv3: reference behavior only, never copy code.** |
| CI | GitHub Actions, macOS 26 runner: build + unit tests | Notarization in CI post-MVP. |

**Prior art, studied not copied:** VoiceInk (GPLv3 superwhisper clone, whisper.cpp), parakey (~100 ms Parakeet push-to-talk, proves the ANE latency story), FluidVoice, macparakeet. Our niche vs. all of them: native Apple AI stack end-to-end (no model downloads at all) + the agentic seam.

---

## 5. MVP development process

Prereq: **install full Xcode 26** (only CommandLineTools active today: `xcode-select -p` → CLT). Then `git init`, MIT LICENSE, this doc, CI skeleton.

Tracer-bullet milestones. Each has an exit test; a milestone isn't done until its check passes on a real app in real apps.

**M0 — Tracer bullet** *(the whole loop, ugly)*
Menu-bar skeleton; hotkey; AVAudioEngine capture; SpeechAnalyzer transcription; pasteboard+⌘V injection with clipboard restore.
✅ *Exit: hotkey-dictate a sentence into TextEdit and Slack. Latency stop→paste < 1.5 s for a 10 s utterance.*

**M1 — Recording UX**
Floating HUD pill (waveform, state dot, Esc = cancel), push-to-talk *and* toggle semantics, start/stop/cancel sounds, error surfacing (no mic, no permission).
✅ *Exit: 20 consecutive dictations without touching the mouse; cancel discards; HUD never steals focus.*

**M2 — Smart processing + context**
ContextSnapshot (AX selection at record start, 3 s clipboard rule, frontmost app); SmartProcessor with cleanup contract; Dictate/Transform intent gate; ⇧ raw escape; VocabularyRewriter; graceful degradation when Apple Intelligence is off.
✅ *Exit: golden-transcript unit suite for cleanup contract passes; "make this a bullet list" over a selection works in Notes; filler removal demonstrably works; raw path unaffected.*

**M3 — App-ness**
History (JSONL + WAV, retention setting, list in settings window with copy), settings (hotkey recorder, sounds toggle, vocabulary editor, history retention), first-run onboarding that walks mic + Accessibility grants, launch-at-login (`SMAppService`), secure-input refusal.
✅ *Exit: on a clean macOS user account, onboarding → working dictation with no manual System Settings spelunking; app survives permission revocation without crashing.*

**M4 — Ship it**
App icon, README with GIF, Developer ID signing + notarized DMG, GitHub Actions (build + tests), CONTRIBUTING, tagged v0.1.0 release.
✅ *Exit: a stranger downloads the DMG, opens it, dictates within 2 minutes.*

**Working rules** (ponytail-aligned): every non-trivial pure component (VocabularyRewriter, intent gate, clipboard timing, cleanup contract) lands with one runnable check — plain XCTest, no fixtures. UI and AX behavior verified by driving the real app, not mocks. Shortest diff that passes the exit test wins; anything speculative goes to §7, not into code. Deliberate ceilings get a `// ponytail:` comment naming the upgrade path.

Rough shape: ~2–4 k LOC Swift. M0 is a day-scale task; each later milestone is days, not weeks.

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| SpeechAnalyzer accuracy on jargon (no custom-vocab API) | VocabularyRewriter post-pass + prompt-bias in cleanup; ParakeetEngine behind the seam if quality still short. |
| Foundation Models needs Apple Intelligence enabled + Apple Silicon | Detect at launch; degrade to Passthrough with a one-line notice. Ollama provider later for the same seam. |
| FM latency/quality on long dictations | Length cap → auto-raw beyond it; async reprocess-from-history later. Never block paste on a slow model. |
| Paste injection edge cases (Electron apps, secure fields, vim) | Fallback chain AX→⌘V; secure-input detection refuses + notifies; keep a "copy only, no paste" toggle. |
| macOS 26-only APIs shrink audience | Accept: floor = macOS 26 + Apple Silicon. It's the cost of the zero-download story; whisper.cpp back-port only if demand is real. |
| GPL contamination from reading VoiceInk | Behavior reference only; MIT codebase; no code copying. |

---

## 7. Post-MVP roadmap (ordered)

1. ✅ **Agentic voice commands** — v1 shipped (M6): spoken "Sotto, …" wake word → on-device FM parse (classify-only) → violet confirm pill → dispatch behind the `VoiceCommand` seam (open app/URL, volume, type-into-terminal). See §3. The reason the PostProcessor seam exists. Next: more command kinds, media keys, per-terminal profiles.
2. **Provider plug-ins** — ✅ cleanup providers shipped: Ollama (local) + Anthropic BYOK behind the PostProcessor seam, off by default, network-silent unless selected (§8-adjacent; see docs/PROVIDER_PLUGINS_DESIGN.md). Next: OpenAI/Groq backends (~15 lines each), and Parakeet + optional cloud STT behind TranscriptionEngine.
3. **Realtime on-screen transcript** (SpeechAnalyzer streams natively).
4. **Reprocess from history**, file transcription (drag audio onto menu bar icon).
5. **Fn/Globe-key hotkey** via CGEventTap (accepting the Input Monitoring permission).
6. **Meeting capture** — ScreenCaptureKit system audio + FluidAudio diarization.
7. Sparkle auto-updates (opt-in), per-app overrides *only if* real usage demands them.

## 8. Clipboard history (opt-in)

A separate, opt-in (default OFF) clipboard manager, folded in so users don't run
a second app. Kept honest to the identity:

- **Separate by construction.** Its own `ClipboardEntry` type and its own file
  (`~/Library/Application Support/Sotto/clipboard/clipboard.jsonl`) — never mixed
  with voice `HistoryEntry`/`history.jsonl`. No `source` discriminator to get wrong.
- **Zero network**, on-device only — same guarantee as everything else.
- **Secrets:** skips items marked `org.nspasteboard.{Concealed,Transient,AutoGenerated}Type`
  (what 1Password/Bitwarden set) and captures `.string` only. Unmarked secrets
  (a token pasted from a plain note) *can't* be detected — a one-time first-run
  disclosure says so plainly. Not full at-rest encryption (that needs key
  management that fights "radically simpler"); instead: file `0600`, excluded from
  backup/Spotlight, **count-capped at 50** (a small breach payload, not a 30-day log).
- **Self-paste loop:** a shared `ClipboardWriteGuard` fingerprints every pasteboard
  changeCount Sotto itself produces (paste, restore, copy-from-history) so the
  monitor never records Sotto's own output as a "user copy". Bounded, one-shot.
- **Surfaced** in the menu-bar "Clipboard" submenu (flat click-to-copy) and a
  Voice/Clipboard segmented control in Settings › History. No favorites/reprocess
  on clips — those are voice-only.
