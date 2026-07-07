# Multilingual Coverage Verification Spike

**Status**: Completed analysis. Findings document gaps; ready for P2 prioritization decision.

**Summary**: Sotto's transcription works in 100+ languages (via SpeechTranscriber), but post-processing instructions (cleanup, intent detection) are English-only. Non-English users get English-optimized cleanup rules that may not recognize language-specific filler words or patterns.

## Findings

### Transcription (STT)
✅ **Status: Broad coverage**
- SpeechTranscriber supports 100+ languages (OpenAI Whisper backend)
- Current locale resolution: tries `Locale.current`, then falls back to en-US
- **Gap**: No runtime inventory of which locales are actually supported on the device. We discover support only at first-use time; `SpeechTranscriber.isAvailable` ≠ `SpeechTranscriber.supportedLocale(Locale.current)` necessarily succeeding.

### Post-Processing (Cleanup, Intent Detection, Command Parsing)
❌ **Status: English-only**

**Cleanup Instructions** (`Prompts.swift:87–94`)
```
- Remove filler words (um, uh, er, "you know", "like", "I mean" when used as filler)
- Fix punctuation, capitalization, paragraph breaks
- Apply spoken self-corrections
```
- **Problem**: These rules assume English phonetics and pragmatics
  - German filler words ("ähm", "na ja") not removed
  - English self-correction patterns may not match French/Japanese
  - Filler-word list is English-specific

**Intent Gate** (`Prompts.swift:32–34`)
```
Example: "make this a bullet list", "translate to formal English", "fix the grammar"
```
- **Problem**: Examples are English-oriented; may not surface the right intent patterns for speakers of other languages

**Transform Instructions** (`Prompts.swift:48–50`)
- Language-neutral, minimal — no problem here

**Command Parsing** (`Prompts.swift:68–75`)
- Terminal commands ("typeIntoTerminal") are mostly used in English context
- Acceptable: system control (volume, mute) transcends language

### Current User Experience
| Scenario | Behavior |
|----------|----------|
| Spanish user, es-ES locale, Spanish speech | Transcription ✅, cleanup 🟡 (English rules applied) |
| German user, de-DE locale, German speech | Transcription ✅, cleanup 🟡 (English rules applied) |
| English user, en-US locale, English speech | Transcription ✅, cleanup ✅ (English rules match) |
| User speaks language, system locale doesn't match | Falls back to en-US; transcription/cleanup both en-US |

## Options for P2

### Option A: Localize Post-Processing (Effort: M–L per language)
Translate `cleanupContract`, `intentInstructions` into top-N languages; update filler-word lists.
- **Pro**: Non-English users get tailored cleanup
- **Con**: 10–15x maintenance burden per new language; every language needs linguistic expertise
- **Recommended for**: 2–3 highest-demand languages (Spanish, Mandarin, German)

### Option B: English-Only Post-Processing, Full STT Coverage (Effort: S)
Keep prompts English. Verify SpeechTranscriber fully supports non-English transcription (it does).
- **Pro**: No maintenance burden; Sotto stays simple
- **Con**: Non-English cleanup quality may be suboptimal; users get English-optimized behavior
- **Recommended for**: MVP; revisit if non-English users report cleanup issues

### Option C: Hybrid (Effort: M)
Localize for top-3 languages (Spanish, Mandarin, German); others get English prompts.
- **Pro**: 80/20 coverage; manageable maintenance
- **Con**: Creates 4 versions of Prompts; localization expertise required

## Recommendation

**Ship Option B for v0.1.0** (English-only prompts). Provides non-English transcription immediately; users understand that cleanup is English-optimized. If non-English users report cleanup issues post-launch, escalate to Option C in a follow-up release.

**Validation needed before shipping**:
1. Confirm SpeechTranscriber supports non-English transcription on the M1 Mac (likely yes, but verify)
2. Test 2–3 non-English dictations; document cleanup quality vs. English baseline
3. Add a note in DESIGN.md under Limitations: "Post-processing (cleanup, intent detection) is English-optimized; transcription works in 100+ languages."

## Code Locations
- Locale resolution: `TranscriptionEngine.swift:199–209`
- Post-processing prompts: `Prompts.swift:87–94` (cleanup), `:32–34` (intent), `:68–75` (commands)
- Smart cleanup toggle: `Settings.swift` (`smartCleanupEnabled`)
