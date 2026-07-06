# Sotto Market-Gap Backlog

*Generated 2026-07-06 from an 11-agent market research pass across 8 competitors (superwhisper, Wispr Flow, MacWhisper, VoiceInk, Aqua Voice, Willow Voice, Spokenly, and Handy), followed by an adversarial critique pass that reprioritized and stress-tested the resulting backlog against Sotto's own stated identity. See [DESIGN.md](DESIGN.md) for the three identity principles (privacy-absolute, radically simpler, agentic ceiling) that every item below is judged against.*

---

## Critical path (do this before any feature work)

The competitive research is strong, but the single biggest finding of the critique pass is that **this backlog conflates code-complete with done.** M0–M6 are marked complete in project tracking, but none of that work has been exercised on a real Mac, and the one sanctioned network call in the app currently points partly at the wrong place in the docs. Three things gate everything else:

**1. Reconcile the repo-URL bug — fixed in this pass.** `UpdateChecker.swift` already hardcodes the correct canonical repo (`defaultRepo = "manateeit/sotto"`), but `README.md`'s clone instructions and `RELEASING.md`'s `gh repo create` command both referenced `chrismckenna/sotto` — a different GitHub org than the one the app actually checks for releases and the one release instructions would have published to. Both docs now say `manateeit/sotto`, matching the code. One cosmetic loose end remains out of scope for this pass: `scripts/make-app.sh` still hardcodes `BUNDLE_ID="com.chrismckenna.sotto"`, and `TranscriptionEngine.swift` has a `DispatchQueue` label with the same old org string — harmless today (bundle IDs don't need to match a GitHub org), but worth a deliberate cleanup pass before it causes confusion.

**2. Ship one hand-notarized, Developer-ID-signed DMG.** This is mostly a human/money gate, not an engineering task — `make-app.sh` and `make-dmg.sh` already do the signing and packaging work. What's missing: a human enrolling in the Apple Developer Program (~$99/yr), obtaining a Developer ID Application certificate, running the existing pipeline (`VERSION=x.y.z bash scripts/make-app.sh` → `SIGN_IDENTITY="..." bash scripts/make-dmg.sh` → `notarytool submit --wait` → `stapler staple`), and publishing via `gh release create` with a matching git tag. Every competitor in the matrix below ships a ready-to-run signed binary; Sotto is the only one that doesn't.

**3. Verify M0–M6 on real hardware before calling any of it shipped.** Project tracking lists five pending human-exercise tasks that block the release: M0 (dictation), M1 (recording UX), M2 (smart processing), M3 (settings/onboarding/history), and M6 (voice commands) — all still unverified on a real macOS 26 + Apple Silicon machine. DESIGN.md §5 is explicit that a milestone "isn't done until its check passes on a real app in real apps." At minimum this means confirming: the confirm-gated voice-command pill actually blocks execution until re-tap, secure-input refusal actually holds in a real password field, the HUD is genuinely non-activating (never steals focus), 20 consecutive dictations complete without failure, and onboarding completes cleanly on a clean account. None of this has been exercised outside development.

**Only after these three close does the feature backlog below start to matter.** Two caveats worth setting expectations on now: signing is necessary but not sufficient for mass reach — the hard floor (macOS 26 + Apple Silicon + Apple Intelligence enabled) still excludes most of the installed Mac base, and Sotto's zero-telemetry stance means there's no way to even measure how much of the market that floor excludes. And this backlog's own P0 item (below) is the *first* engineering slice of this critical path, not a separate concern — treat it as one release milestone, not three.

---

## Feature comparison matrix

## Sotto vs. the macOS dictation market — capability matrix

Legend: ✅ full / native · ◐ partial, planned, or gated · ❌ absent · ❔ unconfirmed in available sources. Cell notes are terse qualifiers.

| Capability | Sotto | Superwhisper | Wispr Flow | MacWhisper | VoiceInk | Aqua Voice | Willow | Spokenly | Handy |
|---|---|---|---|---|---|---|---|---|---|
| On-device / offline STT | ✅ SpeechAnalyzer | ✅ Whisper/Parakeet | ❌ cloud-only | ✅ Whisper/WhisperKit | ✅ whisper.cpp/Parakeet | ❌ cloud-only | ◐ Pro offline mode | ✅ Whisper/Parakeet | ✅ Whisper/Parakeet V2-V3/Moonshine/Cohere/custom GGML |
| On-device LLM cleanup (no cloud) | ✅ Foundation Models | ❌ BYOK cloud | ❌ cloud Polish | ◐ Ollama/LM Studio | ❌ BYOK cloud | ❌ cloud | ❌ cloud | ❌ BYOK/Pro cloud | ◐ optional, experimental (local or Bedrock) |
| Cloud STT (BYOK or managed) | ◐ planned | ✅ S1/ElevenLabs | ✅ default | ✅ BYOK | ✅ BYOK | ✅ Avalon | ✅ default | ✅ BYOK/Pro | ❌ local-only by design |
| BYOK cloud LLM post-processing | ◐ planned | ✅ all frontier | ❌ own pipeline | ✅ 12+ providers | ✅ many | ❌ own model | ❌ own model | ✅ many | ◐ Bedrock only, experimental, custom prompt template |
| AI cleanup (filler/punct/casing) | ✅ | ✅ | ✅ Polish | ✅ | ✅ | ✅ | ✅ | ✅ | ◐ optional/experimental (off by default) |
| Per-app / context Modes | ◐ context, no Modes | ✅ deepest | ✅ Styles | ✅ per-app prompts | ✅ Modes | ✅ screen ctx | ✅ style memory | ✅ App Focus | ❔ unconfirmed |
| Custom vocabulary | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (5/800) | ✅ | ✅ | ❔ unconfirmed |
| Transcription history | ✅ open JSONL+WAV | ✅ full-text search | ✅ synced | ✅ | ✅ | ✅ | ◐ local-only | ✅ | ❔ unconfirmed |
| File / audio-file transcription | ◐ planned | ✅ Pro | ❌ | ✅ specialty | ✅ | ❌ | ❌ | ✅ CLI/MCP | ❔ unconfirmed |
| Meeting capture + diarization | ◐ planned | ✅ | ❌ | ✅ bot-free | ❌ | ❌ | ❌ | ◐ file diarization | ❌ not offered |
| Realtime on-screen transcript | ◐ planned | ✅ | ◐ | ❌ | ✅ | ✅ streaming | ✅ | ◐ | ✅ v0.9.0 (transcribe.cpp) |
| Voice commands / agentic actions | ✅ confirm-gated | ◐ agent hooks | ◐ Command Mode | ◐ CLI/webhooks | ◐ shell (beta) | ❌ text only | ❌ format cmds | ✅ Agent Mode | ❌ dictation only |
| MCP / coding-agent integration | ❌ seam only | ✅ CC/Cursor/Codex | ◐ gated API | ◐ community MCP | ❌ | ◐ IDE context | ◐ IDE dictation | ✅ MCP server | ❌ none |
| Wake-word activation | ✅ "Sotto" | ❌ | ❌ | ❌ | ◐ trigger words | ❌ | ✅ "Hey Willow" | ❌ | ❌ none |
| Cross-platform (Win/iOS/Android) | ❌ macOS only | ✅ Mac/Win/iOS | ✅ +Android | ◐ +iOS | ◐ iOS companion | ✅ Mac/Win/iOS | ✅ Mac/Win/iOS | ✅ +Win/Linux | ◐ Mac/Win/Linux (no iOS) |
| No account required | ✅ zero | ◐ account implied | ❌ mandatory | ✅ for local | ✅ for local | ❌ required | ❌ required | ✅ for local | ✅ zero |
| Zero-network by default | ✅ | ❌ | ❌ | ◐ local never phones home | ◐ Sparkle bg checks | ❌ | ❌ | ✅ Local-Only Mode | ✅ 100% local by default |
| Team / Enterprise (SSO/SOC2) | ❌ not a goal | ✅ | ✅ +HIPAA | ◐ MDM/bulk | ❌ | ✅ | ✅ +HIPAA | ❌ | ❌ not a goal |
| Open-source | ✅ | ❌ | ❌ | ❌ | ✅ GPLv3 | ❌ | ❌ | ❌ | ✅ MIT, ~26k stars |
| Prebuilt notarized download | ❌ build-from-source | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ signed, personal Developer ID |
| Mac App Store | ❌ | ✅ | ❌ iOS-only | ✅ sibling app | ◐ companion SKU | ❌ | ❌ | ◐ frozen legacy | ❌ |
| Homebrew cask | ❌ | ✅ | ✅ community | ✅ | ✅ community | ✅ | ❌ | ✅ | ◐ community-maintained (unofficial) |
| Auto-update (Sparkle/equiv) | ❌ click-only check | ◐ channel-dependent | ✅ Electron, silent | ◐ undocumented | ✅ Sparkle | ◐ Electron, inferred | ◐ in-app prompts | ✅ Sparkle | ✅ Tauri native updater, in-app |

**Reading the matrix:** Sotto is alone in three columns that define its identity — true zero-network-by-default, on-device LLM cleanup (only MacWhisper's optional Ollama comes close), and no account. It is *also* alone in the wrong direction on one row that hurts real users today: it is the only app in the set with no prebuilt binary. Its agentic voice-command layer (✅ confirm-gated) is more mature than everyone except Spokenly, yet it has no MCP/coding-agent surface while that is exactly where Superwhisper, Spokenly, Aqua, and Wispr are investing hardest in 2026. Handy is Sotto's closest philosophical cousin — MIT-licensed, local-by-default, no account — but it trades some of that purity for optional cloud post-processing (Bedrock) and is reported slower and less polished than Wispr Flow; it is also the only app in the set with a Linux build, a reach dimension Sotto's Apple-only stack cannot match.

---

## Install & update comparison

## Install & Update mechanics — Sotto vs. the field

Distribution is the single area where Sotto is objectively behind *every* competitor, not by philosophy but by not-having-shipped-yet. This section maps how each app is installed and kept current, then extracts what Sotto should adopt without compromising principle 1.

### At-a-glance

| App | Primary install | Also available on | Notarized DMG? | Account to *use*? | Update mechanism |
|---|---|---|---|---|---|
| **Sotto** | **Build from source (Swift toolchain)** | — (DMG "coming soon") | ❌ ad-hoc signed only | ✅ **No account ever** | Manual: click-only GitHub check, opens browser, user re-downloads |
| Superwhisper | Direct download + Mac App Store | Homebrew cask, Setapp, Win, iOS | Not stated (likely) | ◐ account implied even on free | Channel-dependent; direct-download updater undocumented |
| Wispr Flow | Direct DMG (arch-specific) | Homebrew cask (community), signed .pkg for MDM | Inferred yes (drag-to-/Applications) | ❌ **mandatory sign-in** before first word | Electron/Squirrel silent auto-update (~1h idle); no user opt-out |
| MacWhisper | Direct .zip (Gumroad) | Homebrew cask, Mac/iOS App Store (sibling "Whisper Transcription") | Not confirmed (needs it for Gatekeeper) | ✅ no login for local | Undocumented; "lifetime updates"; App Store side normal |
| VoiceInk | Direct notarized DMG | Homebrew cask (community), separate iOS SKU | ✅ confirmed | ✅ no login for local | **Sparkle** appcast, ~4h background checks, EdDSA-signed |
| Aqua Voice | Direct DMG (arch-specific) | Homebrew cask, iOS App Store | Not stated | ❌ account required even on free | Electron auto-update (inferred from bundle id) |
| Willow | Direct DMG | Microsoft Store (Win), iOS App Store | Not stated | ❌ sign-in required to function | In-app update prompts (framework unnamed) |
| Spokenly | Direct notarized DMG | Homebrew cask, frozen Mac App Store build | ✅ confirmed | ✅ no login for local | **Sparkle** (active build); MAS build frozen |
| **Handy** | Direct DMG (Apple-signed, personal Developer ID) | Community Homebrew cask (unofficial); Windows and Linux builds (Tauri) | ✅ signed, though under the individual maintainer's personal Developer ID rather than an org | ✅ **No account ever** (free, donations) | **Tauri native updater** — signed artifacts, in-app auto-update |

### The patterns worth internalizing

1. **A prebuilt, ready-to-run binary is table stakes.** All seven competitors ship one; Sotto is the only app that forces a `git clone` + `make-app.sh`. This gates out 100% of non-developer users and is called out as "coming soon" in Sotto's own README. This is not an identity trade-off — it is unfinished distribution work.
2. **Direct-download + Homebrew cask is the winning combo for the developer audience Sotto targets.** Six of seven are `brew install --cask`-able (Willow being the lone exception). For a privacy-first, terminal-driving tool, the Homebrew path is the *most* on-brand install channel.
3. **Sparkle (or an Electron equivalent) is the norm for out-of-store apps — but Sotto's click-only check is a choice, not an oversight.** VoiceInk, Spokenly, and Handy — the three closest architectural cousins to Sotto (local-first, notarized/signed DMG, Homebrew-adjacent) — all ship a native background updater (Sparkle, Sparkle, Tauri's updater respectively). Wispr and Aqua use Electron auto-updaters. Judged purely on convenience, Sotto's "opens a browser, you re-download" flow is the least automated in the field. But DESIGN.md §7 lists Sparkle as opt-in and gated on demonstrated need for a reason: a background updater is a standing network call, and "Check for Updates…" firing only on click is the one deliberate exception to zero-network-by-default (README, DESIGN §1) — not an unfinished feature. The real gap Sotto has today isn't the updater's manual-ness, it's that the checked repo has no signed release to find yet. Once a notarized DMG exists, opt-in Sparkle (default off) is the market-parity move that closes the convenience gap without touching the privacy default.
4. **Notarization is universal-in-practice even where undocumented.** Every non-App-Store app must be Developer-ID-signed + notarized to clear current Gatekeeper cleanly. Sotto ships ad-hoc-signed only, meaning users hit the "unidentified developer" wall — a first-run trust tax none of the competitors pay.
5. **Account gates cleanly split the market on the privacy axis — and this is Sotto's moat.** Wispr, Aqua, and Willow *require* sign-in before you can dictate a single word; Superwhisper implies an account even on free. MacWhisper, VoiceInk, and Spokenly (and Sotto) let you use local dictation with zero account. Sotto is the *purest* here — not just no-login, but no-telemetry and no-network-at-all. This should be marketed loudly, not just honored quietly.
6. **App Store presence is optional and often a liability for this app class.** The Mac App Store sandbox fights the exact capabilities Sotto needs — Accessibility injection, typing into terminals, system control. Note that Spokenly *froze* its MAS build and moved active development to a sideloaded DMG, and Superwhisper's own docs surface App Store-specific license-recovery pain. Sotto should not treat MAS as a priority.

### Where Sotto stands

Sotto's runtime privacy posture is best-in-class, but its *delivery* posture is worst-in-class. The good news: closing the delivery gap is almost entirely orthogonal to the privacy identity. A notarized DMG, a Homebrew cask, and CI-automated notarization involve zero new runtime network calls. Only auto-update introduces genuine tension, and only if done wrong.

### What Sotto should adopt (in order)

*(Reordered per the adversarial critique pass — see Backlog below for the full reprioritization rationale.)*

- **P0 — Ship a Developer-ID-signed, notarized DMG**, folding in the app-translocation / "not in /Applications" guard as part of the same release milestone, and reconciling the canonical GitHub org first (see Critical Path). The signing/build scripts already exist in RELEASING.md; the remaining work is mostly a human obtaining a Developer ID cert, not engineering.
- **P1 — Publish a Homebrew cask.** Cheap (S) once a notarized artifact exists; sequence it immediately after the first signed release, not before — a cask needs a stable DMG URL + checksum to point at.
- **P2 — Automate notarization + stapling in CI.** Demoted from P1: you can't automate a pipeline that hasn't run once by hand, and it means committing signing secrets to CI — a deliberate decision to make after the first manual release, not before.
- **P2 — Add opt-in Sparkle auto-update, off by default.** Reuse the existing GitHub-release source; keep it a Settings toggle, never default-on. This is the one item with genuine identity tension — a background updater is a standing network call — so it stays opt-in with a visible network-egress disclosure.
- **Do NOT prioritize the Mac App Store.** Its sandbox is hostile to Sotto's Accessibility/terminal-control core, and the closest peer (Spokenly) actively retreated from it.

---

## Backlog

The 24 items the synthesis pass produced, with every critique reprioritization applied: CI-notarization and the translocation guard moved out of P1, meeting capture and translation demoted P2→P3, Undo-AI-edit elevated P2→P1, the three overlapping "voice for AI coding" items consolidated into one P2 theme, and five new items added from the critique's gap-finding pass. Items are marked **(new)** where they didn't exist in the original synthesis.

### P0 — blocks everything else

**Ship a Developer-ID-signed, notarized DMG release**
Effort: L (mostly human/process, not code) · Category: install-update · Identity fit: fits
Every competitor (Superwhisper, Wispr Flow, MacWhisper, VoiceInk, Aqua, Willow, Spokenly, Handy) ships a ready-to-run signed binary; Sotto uniquely forces build-from-source. The signing scripts already exist in RELEASING.md — the remaining work is a human enrolling in the Apple Developer Program, obtaining a cert, and running the pipeline once. This item now also carries the app-translocation/"not in /Applications" guard (previously tracked standalone at P1) and the canonical-repo reconciliation (done in this pass), folded in as one release milestone per the critique.

**Real-hardware verification gate for M0–M6 (new)**
Effort: M (test execution, not new code) · Category: verification · Identity fit: fits
The backlog otherwise treats M0–M6 as shipped because their code is complete, but five human-exercise tasks are still pending: dictation (M0), recording UX (M1), smart processing (M2), settings/onboarding/history (M3), and voice commands (M6), none yet run on real macOS 26 + Apple Silicon hardware. DESIGN.md §5's own bar is that a milestone isn't done until it passes on a real app in real apps. Gate the P0 release tag on these five checks passing, with particular attention to the confirm-gated voice-command pill, secure-input refusal, and the HUD's non-activating behavior — the three places a hardware-only bug would be most damaging to trust.

### P1

**Publish a Homebrew cask**
Effort: S · Category: ecosystem · Identity fit: fits
Superwhisper, MacWhisper, VoiceInk, Aqua, Spokenly, and (unofficially) Handy are all `brew install --cask`-able. It's the most on-brand install path for Sotto's developer/power-user audience — sequence it immediately after the first signed DMG lands, since a cask needs a stable URL + checksum to point at.

**Verify and expand multilingual dictation coverage**
Effort: S (verification spike) then M (expansion where gaps are proven) · Category: dictation-core · Identity fit: fits
Every competitor touts 100+ languages with auto-detect. `TranscriptionEngine.resolveLocale()` only tries `[Locale.current, en-US]` and throws `localeUnsupported` otherwise, and the cleanup/transform prompts are English-authored — non-English users may be silently broken or get English-biased cleanup today. Measure actual SpeechAnalyzer locale coverage and cleanup quality first; only expand where a real gap is confirmed.

**Accessibility audit for motor-impaired, RSI, and dyslexic users (new)**
Effort: M (audit + high-priority fixes; may expand) · Category: accessibility · Identity fit: fits
Dictation's core demographic includes people who can't type comfortably, yet there are zero `accessibilityLabel`/VoiceOver hooks anywhere in the app — the HUD, Settings, onboarding, and the violet confirm pill are all unlabeled for screen readers. Starting a dictation still requires physically pressing ⌥Space (the wake word only classifies mid-transcript, it doesn't trigger hands-free start), which excludes users with severe motor impairment from the product entirely. This deserves its own track above most P2 feature work, not a line item buried in UX polish.

**'Undo AI edit' / one-tap raw-transcript reveal after paste**
Effort: S · Category: ux · Identity fit: fits
Elevated from P2 — the highest-leverage trust win in the backlog for the lowest cost. Wispr Flow's "Undo AI edit" and Aqua's base-transcript retrieval are praised trust features. Sotto's core promise is "never changes your meaning," yet today the only safety net is the pre-hoc Shift-raw escape hatch; there's no recourse once cleanup mangles something after paste already happened. A post-hoc raw reveal/restore directly reinforces that promise at near-zero cost, using data (WAV+JSONL) the app already stores.

**Docs/website + privacy trust-proof page (new)**
Effort: M · Category: docs · Identity fit: fits
There's no landing page, `docs/demo.gif` is still a placeholder, and — most importantly for a privacy-absolute product — nothing lets a skeptic verify the "zero network" claim. Every competitor's site sells convenience; Sotto's should sell verifiability: a documented Little Snitch/`nettop` walkthrough, or better, an automated CI test asserting no outbound connections in the default build. Right now the core differentiator is an unverified assertion, which is a strange place for the most privacy-serious app in the category to be.

### P2

**Automate notarization + stapling in CI**
Effort: M · Category: install-update · Identity fit: fits
Demoted from P1. MacWhisper, VoiceInk, and Spokenly ship frequent notarized point releases, and Sotto's process is fully manual per RELEASING.md — but you can't automate a pipeline that's never run once by hand, and doing so means committing Apple ID app-specific-password + signing secrets to CI. Do this only after the first hand-driven release validates the pipeline.

**Opt-in Sparkle auto-update (default off)**
Effort: M · Category: install-update · Identity fit: tension
VoiceInk and Spokenly use Sparkle; Wispr Flow and Aqua use Electron auto-updaters. Sotto's click-only check can't download or install a new build, making it the least convenient updater in the field — but that's the sanctioned exception to zero-network-by-default, not a bug. Ship this strictly opt-in, off by default, with a visible network-egress disclosure; never let it become a default-on background poller.

**FluidAudio Parakeet STT engine behind the TranscriptionEngine seam**
Effort: M · Category: ai-processing · Identity fit: fits
Superwhisper, MacWhisper, VoiceInk, and Spokenly all offer Parakeet for better and multilingual on-device accuracy. The seam already exists for exactly this second implementation; no identity tension.

**Ollama / local-LLM backend behind the PostProcessor seam**
Effort: M · Category: ai-processing · Identity fit: fits
MacWhisper (Ollama/LM Studio) and Spokenly support local LLM backends. Lets power users run a larger-than-Foundation-Models model with zero cloud egress. Guardrail: treat an Ollama server as a user-configured, off-by-default localhost listener — never let it silently become the default cleanup path.

**Provider plug-ins: BYOK cloud STT + LLM, off by default**
Effort: L · Category: ai-processing · Identity fit: tension
Superwhisper, MacWhisper, VoiceInk, and Spokenly all offer BYOK to OpenAI/Anthropic/Groq/etc. DESIGN.md already permits "cloud is opt-in, per-provider, BYO-key" — fits only if it never touches the default build's zero-network guarantee. Hard guardrail: explicit per-provider opt-in with a visible egress warning, and the default install must stay provably network-silent even with plug-in code present.

**Realtime on-screen transcript**
Effort: M · Category: ux · Identity fit: fits
Superwhisper, VoiceInk, Aqua, and Willow display text as you speak. SpeechAnalyzer streams natively, so this stays fully on-device. Watch: keep it unobtrusive/optional so it doesn't drift the deliberately minimal HUD toward a busy UI.

**File / audio-file transcription (drag onto menu bar icon)**
Effort: M · Category: ecosystem · Identity fit: fits
MacWhisper (the category leader here), Superwhisper, VoiceInk, and Spokenly all transcribe dropped audio files. On-device, reuses the existing engine, common ask beyond live dictation.

**Reprocess / re-transcribe from history**
Effort: S · Category: ux · Identity fit: fits
Aqua and MacWhisper let users re-run transcription/formatting on past items. Sotto already stores WAV+JSONL, so the source data exists — arguably the best value-per-effort item in the whole backlog, and pairs naturally with the Undo/raw-reveal trust feature above.

**Voice input for AI coding agents (consolidated theme)**
Effort: L overall (components individually M/M/L) · Category: ecosystem · Identity fit: fits
Consolidated from three overlapping synthesis items that were all circling the same "voice for AI coding" niche — tracking them separately triple-counted effort on a single initiative. One theme, three sub-bullets:
- *Local MCP "Voice for Agents" server* — Spokenly ships a localhost MCP server letting Claude Code/Cursor/Codex ask the user spoken questions; directly extends Sotto's agentic-ceiling thesis. Note: "zero network" has meant zero *outbound* calls — a localhost MCP server is an *inbound* listening socket, so it must be explicitly opt-in and clearly scoped, or it will draw scrutiny from a privacy-skeptical reviewer.
- *First-class voice input for coding-agent prompt boxes (Claude Code / Cursor)* — Superwhisper, Aqua, and Willow all court this niche; Sotto already types into allowlisted terminals, so extending to agent prompt boxes is incremental.
- *Expanded voice-command kinds* (media keys, more system actions, per-terminal profiles) — Spokenly's Agent Mode is broader than Sotto's current tier 0/1 set; this is DESIGN.md's own explicit "Next" item and stays inside the mandatory confirm-gate model.

**UI localization (new)**
Effort: L · Category: localization · Identity fit: fits
Separate from dictation-language coverage above: there is no `NSLocalizedString`/`.strings` anywhere. Settings, onboarding, HUD, and confirm-pill copy are all hardcoded English, and the Foundation Models cleanup/transform/intent prompts are English-authored — so even users on supported STT locales get an English-only app and English-biased cleanup.

**Competitor migration / import (new)**
Effort: S · Category: ecosystem · Identity fit: fits
Switchers from superwhisper/MacWhisper/VoiceInk carry large custom dictionaries and history; Sotto currently offers no vocabulary or history import. A small importer into the existing `vocabulary.json`/JSONL formats is a cheap adoption lever for exactly the audience most likely to try Sotto.

### P3

**Meeting capture (system audio) + speaker diarization**
Effort: XL · Category: ai-processing · Identity fit: fits
Demoted from P2 — this was the backlog's single biggest mis-prioritization per the critique. MacWhisper and Superwhisper do bot-free meeting capture with diarization, and it's achievable on-device via ScreenCaptureKit + FluidAudio. But at XL effort it's effectively a second product (a meeting recorder) that pulls Sotto toward the "notes app" category and away from "press key, speak, paste" — it sits last on DESIGN.md's own roadmap for good reason.

**On-device translation (dictate language X, output English)**
Effort: M · Category: ai-processing · Identity fit: fits, but see note
Demoted from P2. Superwhisper, Wispr Flow, MacWhisper, and Willow all offer speech translation, and Foundation Models could handle common pairs on-device without breaking zero-network. But DESIGN.md §1 currently lists Translation under "Cut (deliberately)," while translate-of-selection already ships as a Transform example — a new dictate-and-translate *behavior* would add a third mode beyond Dictate/Transform (in tension with principle 2) and strains the "never changes your meaning" cleanup contract. Reconcile the cut-list contradiction before this moves forward; it's defensible later, not now.

**Local usage stats (WPM, words dictated, time saved)**
Effort: S · Category: ux · Identity fit: fits
Stays P3. Wispr Flow (Insights), Aqua ("Wrapped"), and Superwhisper (Stats/WPM) all surface usage. Fully computable on-device from the existing history store — a cheap delight/retention win that doesn't become telemetry.

**Fn / Globe-key hotkey support (CGEventTap)**
Effort: M · Category: dictation-core · Identity fit: tension
Aqua, Willow, and MacWhisper default to the Fn/dictation key, and it's the native macOS dictation trigger, so demand is real. But CGEventTap requires the Input Monitoring permission Sotto deliberately avoids today (a shipped selling point via Carbon `RegisterEventHotKey`). Only viable if isolated so the default build never requests Input Monitoring, and strictly opt-in for users who ask.

---

## Cut by design

These are not "someday" items and don't carry a priority number — putting a P-number on them implies they're just waiting their turn, which re-litigates a settled identity question every time the backlog is reviewed. Each violates one of DESIGN.md's three principles; move them here rather than into P3.

**Per-app behavior overrides**
Violates: principle 2 (radically simpler / no mode system). Superwhisper Modes, Wispr Styles, VoiceInk Modes, Willow style-memory, and Spokenly App Focus all auto-switch behavior per app — the single most common competitor differentiator. But any UI-configurable version is exactly the camel's nose for the mode maze Sotto deliberately deleted. On-brand alternative (if ever pursued): silently remembering last behavior per app with zero settings surface, and only after hard usage evidence forces it — not a configurable "Modes" system.

**Cross-platform Windows / iOS clients**
Violates: principle 1 (privacy-absolute, on-device by default). Wispr Flow, Aqua, Willow, Spokenly, and Superwhisper span Win/iOS/Android — the biggest reach gap in the matrix. But Sotto's entire stack (SpeechAnalyzer + Foundation Models + AX text injection) is Apple-macOS-only and on-device; a Windows port would force cloud STT/LLM, and iOS lacks the Accessibility injection this app depends on. No on-brand alternative — do not build.

**Team / Enterprise tier (SSO, SOC2, HIPAA, admin console)**
Violates: principle 1 root-and-branch. Wispr Flow, Aqua, Willow, and Superwhisper monetize a large enterprise TAM, but this requires accounts, centralized billing, and cloud data-retention/admin controls — the exact opposite of no-accounts/no-telemetry/zero-network. DESIGN.md §1 already lists this under deliberate cuts.

**Cross-device history / dictionary sync**
Violates: principle 1 (server-side sync means cloud storage of transcripts). Wispr Flow and Aqua sync history and vocabulary across devices. On-brand alternative: history and vocabulary are already plain JSONL/WAV/JSON files in `~/Library/Application Support/Sotto/`, so a user can point their own iCloud Drive or Syncthing folder at that directory and get sync with zero Sotto-operated servers. Document that path instead of building a server-side feature.

---

## Sources appendix

**Superwhisper**
- https://superwhisper.com
- https://superwhisper.com/download
- https://superwhisper.com/changelog
- https://superwhisper.com/models
- https://superwhisper.com/docs/llms.txt
- https://superwhisper.com/docs/get-started/introduction.md
- https://superwhisper.com/docs/get-started/activate-mac.md
- https://superwhisper.com/docs/common-issues/appstore.md
- https://superwhisper.com/docs/enterprise/getting-started
- https://superwhisper.com/billing
- https://superwhisper.mintlify.app/get-started/settings-overview
- https://apps.apple.com/us/app/superwhisper-ai-dictation/id6471464415
- https://formulae.brew.sh/cask/superwhisper
- https://setapp.com/de/apps/superwhisper/customer-reviews
- https://releasebot.io/updates/superwhisper
- https://sotto.to/compare/superwhisper
- https://spokenly.app/blog/superwhisper-pricing
- https://spokenly.app/blog/superwhisper-review
- https://www.getvoibe.com/resources/superwhisper-review/
- https://www.getvoibe.com/blog/superwhisper-alternatives/
- https://x.com/superwhisperapp/status/1891671083788443952

**Wispr Flow**
- https://wisprflow.ai/
- https://wisprflow.ai/pricing
- https://wisprflow.ai/whats-new
- https://wisprflow.ai/business
- https://wisprflow.ai/developers
- https://wisprflow.ai/data-controls
- https://wisprflow.ai/privacy
- https://docs.wisprflow.ai/articles/7682075140-how-to-install-wispr-flow-on-mac
- https://docs.wisprflow.ai/articles/7982516224-how-to-update-the-wispr-flow-app
- https://docs.wisprflow.ai/articles/3152211871-setup-guide
- https://docs.wisprflow.ai/articles/1036674442-supported-devices-and-system-requirements
- https://docs.wisprflow.ai/articles/9363440133-deploy-wispr-flow-via-mdm
- https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode
- https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles
- https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness
- https://docs.wisprflow.ai/articles/2458545840-faqs-for-flow-pro-team-and-flow-enterprise-plans
- https://docs.wisprflow.ai/articles/6939510703-compliance-certifications-standards
- https://docs.wisprflow.ai/articles/6558671428-access-controls-authentication
- https://docs.wisprflow.ai/articles/5510622673-re-verify-wispr-flow-permissions-after-updating
- https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages
- https://roadmap.wisprflow.ai/changelog
- https://apps.apple.com/us/app/wispr-flow-ai-voice-keyboard/id6497229487
- https://formulae.brew.sh/cask/wispr-flow
- https://api-docs.wisprflow.ai/quickstart
- https://platform.wisprflow.ai/
- https://superwhisper.com/vs/wispr-flow
- https://www.bloomberg.com/news/articles/2026-05-12/ai-dictation-startup-wispr-in-funding-talks-at-2-billion-value
- https://techcrunch.com/2026/02/23/wispr-flow-launches-an-android-app-for-ai-powered-dictation/
- https://github.com/Wispr-Flow/
- https://github.com/wispr-flow-linux/wispr-flow-linux

**MacWhisper**
- https://www.macwhisper.com/
- https://goodsnooze.gumroad.com/l/macwhisper
- https://docs.macwhisper.com/article/40-macwhisper-whisper-transcription-difference
- https://docs.macwhisper.com/article/27-deploying-macwhisper-with-mdm
- https://docs.macwhisper.com/article/57-macwhisper-command-line-tool
- https://docs.macwhisper.com/article/22-assistant
- https://macwhisper.helpscoutdocs.com/article/31-app-specific-dictation-prompts
- https://macwhisper.helpscoutdocs.com/article/30-record-meetings
- https://macwhisper.helpscoutdocs.com/article/33-macwhisper-for-ios
- https://formulae.brew.sh/cask/macwhisper
- https://macwhisper-site.vercel.app/release_notes.html
- https://macupdater.net/app_updates/appinfo/com.goodsnooze.MacWhisperMacWhisper.MacWhisper/index.html
- https://apps.apple.com/us/app/whisper-transcription/id1668083311
- https://github.com/ggml-org/whisper.cpp/discussions/420
- https://www.todayonmac.com/macwhisper-your-private-transcription-assistant-that-never-phones-home/
- https://9to5mac.com/2024/12/06/macwhisper-11-brings-a-friendly-redesign-to-the-best-ai-powered-transcription-app/
- https://lumevoice.com/blog/macwhisper-review-2026/ (secondary/aggregator — treat pricing specifics with caution)
- https://medium.com/ai-tools-tips-and-news/macwhispers-pricing-is-confusing-on-purpose-here-s-what-i-actually-paid-51c39d1a18fe (secondary — anecdotal pricing account)
- https://www.getvoibe.com/resources/macwhisper-pricing/ (secondary/aggregator — 'Pro Max $149' claim unconfirmed elsewhere)

**VoiceInk**
- https://tryvoiceink.com/
- https://tryvoiceink.com/docs/installation
- https://tryvoiceink.com/docs/introduction
- https://tryvoiceink.com/docs (sidebar/table of contents)
- https://tryvoiceink.com/docs/local-models
- https://tryvoiceink.com/pricing
- https://tryvoiceink.com/ios
- https://github.com/Beingpax/VoiceInk
- https://github.com/Beingpax/VoiceInk/releases
- https://github.com/Beingpax/VoiceInk/blob/main/appcast.xml
- https://api.github.com/repos/Beingpax/VoiceInk/releases
- https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/v/voiceink.rb
- https://apps.apple.com/us/app/voiceink-ai-dictation/id6751431158
- https://www.getvoibe.com/resources/voiceink-review/
- https://www.getvoibe.com/resources/voiceink-pricing/
- https://www.getvoibe.com/resources/superwhisper-vs-voiceink/
- https://www.getvoibe.com/resources/is-voiceink-safe/
- https://github.com/Beingpax/VoiceInk/issues/593
- https://github.com/Beingpax/VoiceInk/issues/687

**Aqua Voice**
- https://aquavoice.com/
- https://aquavoice.com/download
- https://aquavoice.com/pricing
- https://aquavoice.com/changelog
- https://aquavoice.com/info/faq
- https://aquavoice.com/guide
- https://formulae.brew.sh/cask/aqua-voice
- https://apps.apple.com/us/app/aqua-voice-ai-voice-keyboard/id6759074969
- https://macupdater.net/app_updates/appinfo/com.electron.aqua-voice/index.html
- https://webcatalog.io/en/apps/aqua-voice
- https://www.getvoibe.com/resources/aqua-voice-review/
- https://www.getvoibe.com/resources/aqua-voice-pricing/
- https://www.getvoibe.com/resources/is-aqua-voice-safe/
- https://spokenly.app/blog/aqua-voice-review
- https://spokenly.app/blog/aqua-voice-pricing
- https://9to5mac.com/2025/08/15/aqua-voice-shows-just-how-good-mac-dictation-could-be-if-apple-just-tried/
- https://9to5mac.com/2026/04/17/aqua-voice-the-best-dictation-app-ive-ever-used-is-now-available-on-iphone/
- https://www.producthunt.com/products/aqua
- https://www.ycombinator.com/companies/aqua-voice
- https://news.ycombinator.com/item?id=39828686
- https://github.com/aqua-voice
- https://status.aquavoice.com/
- https://status.withaqua.com/public-api

**Willow Voice**
- https://willowvoice.com/
- https://willowvoice.com/download
- https://willowvoice.com/pricing
- https://willowvoice.com/post-download
- https://willowvoice.com/manifesto
- https://willowvoice.com/success-open-app
- https://help.willowvoice.com/en/articles/12854184-willow-pricing-plans-overview
- https://help.willowvoice.com/en/articles/10876111-install-and-setup-willow-voice-mac-windows
- https://help.willowvoice.com/en/articles/10876920-dictating-with-willow-voice
- https://feedback.willowvoice.com/changelog
- https://apps.microsoft.com/detail/xp9cnbc75hd844?hl=en-US&gl=US
- https://apps.apple.com/us/app/willow-dictation-ai-keyboard/id6753057525
- https://techcrunch.com/2025/11/12/willows-voice-keyboard-lets-you-type-across-all-your-ios-apps-and-actually-edit-what-you-said/
- https://www.ycombinator.com/companies/willow
- https://www.linkedin.com/posts/allan-guo_im-excited-to-announce-that-willow-yc-x25-activity-7350951044551462912-u7h3
- https://www.getvoibe.com/resources/willow-voice-review/
- https://www.getvoibe.com/resources/willow-voice-pricing/
- https://www.getvoibe.com/resources/is-willow-voice-safe/
- https://makerstack.co/reviews/willow-voice-review/
- https://usevoicy.com/blog/willow-voice-pricing
- https://www.producthunt.com/products/willow-voice

**Spokenly**
- https://spokenly.app/
- https://spokenly.app/docs
- https://spokenly.app/pricing
- https://spokenly.app/changelog
- https://spokenly.app/download
- https://spokenly.app/releases/macos
- https://spokenly.app/docs/modes
- https://spokenly.app/docs/macos/agent-mode
- https://spokenly.app/docs/macos/voice-for-agents
- https://spokenly.app/open-source
- https://spokenly.app/about
- https://apps.apple.com/us/app/spokenly-audio-to-text-ai-app/id6740315592
- https://formulae.brew.sh/cask/spokenly
- https://www.getvoibe.com/resources/spokenly-review/
- https://metawhisp.com/blog/spokenly-review/
- https://getseam.app/blog/seam-vs-spokenly
- https://spokenly.app/comparison/macwhisper
- https://spokenly.app/comparison/voicy
- https://spokenly.app/comparison/wispr-flow

**Handy**
- https://github.com/cjpais/Handy
- https://github.com/cjpais/Handy/releases
- https://handy.computer/docs/faq
- https://handy.computer/docs/post-processing
- https://www.getvoibe.com/resources/handy-vs-wispr-flow/
