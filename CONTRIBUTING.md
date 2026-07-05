# Contributing to Sotto

Sotto is CLT-only: no Xcode project, no `xcodebuild`. Everything is `swift build` and shell scripts.

## Build

```bash
bash scripts/make-app.sh   # release build → dist/Sotto.app, ad-hoc signed
open dist/Sotto.app
```

For iteration, `swift build` (debug) is faster, but the app needs a real bundle to be granted microphone/Accessibility permissions — running the raw binary from `.build/` won't work.

## Tests

```bash
bash scripts/test.sh
```

Not `swift test` directly. The test suite uses Swift Testing (`import Testing`, `@Suite`, `@Test`), which Command Line Tools ships under a non-default search path (`/Library/Developer/CommandLineTools/Library/Developer/...`). `scripts/test.sh` passes the `-F`/`-rpath` flags SwiftPM needs to find it; without them, `swift test` silently discovers zero tests and "passes." On a full Xcode toolchain (e.g. CI), Testing.framework is already on the default path and the script detects that and no-ops to plain `swift test` — see the guard at the top of `scripts/test.sh`.

## Architecture rule: two protocol seams, no more

Sotto has exactly two `protocol` boundaries — `TranscriptionEngine` and `PostProcessor` (see `DESIGN.md` §2) — because both have concrete, planned second implementations (FluidAudio's Parakeet engine; Ollama/Anthropic/OpenAI cloud providers). Everything else in the codebase is a plain concrete type.

Don't add a third protocol seam speculatively. If you're tempted to abstract something "for flexibility," it almost certainly belongs as a plain type today, with the abstraction added when the second implementation actually shows up. Read `DESIGN.md` before proposing an architecture change — it explains what was cut and why.

## The `ponytail:` comment convention

A deliberate shortcut — a hardcoded constant, a punted edge case, a "good enough for now" — gets a comment starting with `// ponytail:` that names two things: the ceiling (what this doesn't handle) and the upgrade path (what would replace it, and roughly when). For example:

```swift
// ponytail: hardcoded 0.4s tap/hold cutoff. M3's settings can expose it, but a
// fixed default keeps the gesture predictable until real usage says otherwise.
```

This isn't a TODO — it's a note that the tradeoff was made on purpose, so a future reader (including future-you) doesn't waste time "fixing" something that was already a considered decision, and knows where to look when it's time to revisit it.

## Review expectations

- Tests are for pure logic only — `VocabularyRewriter`, the intent gate, clipboard timing, the cleanup contract, anything with a deterministic input→output. Don't write tests that mock `AVAudioEngine`, `AXUIElement`, or Foundation Models; those are verified by driving the real app (see `DESIGN.md` §5's exit-test rule for each milestone), not by mocking Apple frameworks.
- Shortest diff that passes the relevant exit test wins. Speculative generality goes in `DESIGN.md` §7 (roadmap), not into code.
- If a change touches one of the two protocol seams, explain in the PR description why the existing seam doesn't already cover it.
- New shortcuts get a `// ponytail:` comment, not a silent gap.
