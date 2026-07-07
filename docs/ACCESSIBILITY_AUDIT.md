# Accessibility Audit — Sotto

**Status**: Partial implementation. HUD has VoiceOver labels; Settings needs follow-up pass.

## Completed

### HUD (Recording Pill)
✅ **VoiceOver support added**
- `accessibilityLabel`: "Sotto"
- `accessibilityValue`: Current state (Listening, Transcribing, Done, Error, Confirming)
- `accessibilityHint`: Context-specific explanation for each state

**Result**: Screen reader users can understand the pill's state and next actions without seeing it.

## Remaining Work

### Settings Window
⚠️ **Needs accessibility labels** (M effort)
- GeneralTab toggles (sounds, smart cleanup, voice commands, launch at login, history retention)
- VocabularyTab buttons (Add, Import, Save)
- HistoryTab buttons (Reveal in Finder, Delete All, Reprocess)

**Blocker**: Early attempt to add labels encountered unicode quote encoding issues; deferred to avoid compile errors. Recommend:
1. Create SettingsAccessibility.swift extension with safe string literals (no curly quotes)
2. Add `.accessibilityLabel()` and `.accessibilityHint()` to each toggle and button
3. Test with VoiceOver

### Onboarding Window
⚠️ **Needs audit**
- Permission request buttons (Microphone, Accessibility)
- Guide steps (may need accessibility structure)
- "Got it" confirmation button

### Voice Command Confirmation Pill
⚠️ **Needs review**
- Currently only ⌥Space triggers it (keyboard-only)
- Motor-impaired users cannot trigger voice commands
- **Mitigation**: Document that severe motor impairment requires hands-free alternative setup (e.g., foot pedal remapping to ⌥Space via Accessibility › Keyboard › Sticky Keys)

## Accessibility Gaps

### Motor Impairment
**Issue**: Starting dictation requires pressing ⌥Space (or custom hotkey) — physical button press required.
**Current**: Not addressable in app code (hotkey must come from OS event).
**Mitigation**: Document workaround for users with severe motor impairment (foot pedal via Accessibility settings, Dragon NaturallySpeaking integration, etc.).

### Dyslexic Users
**Issue**: Text-heavy settings and vocabulary editor may be hard to parse.
**Current**: No special support.
**Future**: Consider dyslexia-friendly font (OpenDyslexic) as optional setting; low priority (estimated L effort).

### Keyboard Navigation
**Status**: SwiftUI defaults to standard macOS keyboard nav (Tab, Space to toggle, Enter to click).
**Missing**: Explicit tested keyboard flow for all Settings tabs.
**Recommendation**: QA pass: Tab through all controls, ensure Tab order is logical, verify Space activates toggles.

## Recommendation for v0.1.0

**Deliver HUD VoiceOver support as-is** (✅ done). For Settings accessibility, defer detailed work pending user feedback. If accessibility is a blocker post-launch, prioritize SettingsAccessibility.swift extension + comprehensive toggle labels.

## Files to Update

- `Sources/Sotto/HUD.swift` ✅ (done)
- `Sources/Sotto/SettingsView.swift` (GeneralTab, VocabularyTab, HistoryTab toggles and buttons)
- `Sources/Sotto/OnboardingView.swift` (audit + labels)
- `docs/ACCESSIBILITY_AUDIT.md` (this file; update after SettingsAccessibility.swift is added)

## Test Plan

Once Settings labels are added:
1. Enable VoiceOver (Cmd+F5)
2. Open Sotto settings
3. Tab through each control; verify VoiceOver announces label + hint
4. Test toggle interaction (Space to toggle, hear state change)
5. Test button activation (Enter, hear action confirmed)
