# Model-Provider Plugins — Design + Privacy Verdict

*From a 6-agent design+critique workflow (2026-07-07). Lets a user run cleanup on a
different model behind the existing `PostProcessor` seam — local **Ollama** or
**BYOK cloud** (Anthropic/OpenAI/Groq) with their own key. The invariant above
everything: **the default build stays provably network-silent.***

---

## Verdict: ship in two milestones, not one

The critique's decisive call: **Milestone A (Ollama-only) now; Milestone B (cloud BYOK)
as a separate, individually-reviewed build.** Ollama is loopback — the transcript never
leaves the machine, no key, no Keychain, no cloud disclosure — so it delivers the
"bigger cleanup model" value without touching the internet-egress third rail. Cloud BYOK
is the identity-threatening change and must not ride in on the benign one.

## Architecture (both milestones)

- **One `LLMPostProcessor: PostProcessor`** parametrized by an `LLMBackend` value — NOT
  one type per provider (Ollama + 3 cloud vendors are the same chat-completion shape).
  Its `process(_:context:)` is a line-for-line copy of `SmartProcessor.process`,
  swapping the Foundation Models calls for `backend.complete(system:user:)`.
- **Reuse `Prompts` verbatim** — every provider inherits the "never changes your meaning"
  cleanup contract, the domain-profile bias, and vocab hints for free.
- **Preserve the error asymmetry exactly:** transform/classify failure → `throw
  TransformFailed()`; clean failure → return raw transcript (never throw).
- **Network-silent default is STRUCTURAL, not a runtime `if`:** a single optional
  `llm: (any PostProcessor)?`, built only inside one `reloadProvider()` via one
  `ProviderFactory.make()` — the sole construction site of any `URLSession`-bearing type.
  With `provider == .none` (default) it's never called; routing falls back to a
  network-silent `SmartProcessor` value. All provider networking lives in ONE file
  (`Providers.swift`) so `grep URLSession Sources/` enumerates every egress site.

## Blocking items before build (from the critique)

- **B1 — Fix the published audit claim in the SAME commit.** `docs/landing.html` tells
  users "the only network call is UpdateChecker.swift." That goes false the moment
  `Providers.swift` ships. Reword to scope it to the default build + name the opt-in
  providers, in the exact commit that adds the code. A window of a wrong audit claim is
  itself a trust breach.
- **B2 — Source-enumeration regression test:** assert no `URLSession`/host literal
  appears in `Sources/` outside `Providers.swift` + `UpdateChecker.swift`. The only
  automatable guard that the "one greppable file" invariant doesn't rot.
- **B3 (cloud) — A cancelled/timed-out cloud call MUST abort the socket.** `withTimeout`
  has a cancellation caveat; for cloud, "cancelled" that still transmits = a betrayal.
  Use the async `URLSession.data(for:)` (natively cancellation-aware) + verify end-to-end.
- **B4 (cloud) — Transform sends the SELECTED text too**, which may be content the user
  never dictated. The disclosure must say so, not just "your dictated text."
- **B5 (cloud) — Don't let Sotto promise compliance.** ZDR/BAA are provider-side
  enterprise agreements; default API access retains data ~30 days. Copy must say "whether
  this meets HIPAA/ZDR depends entirely on your own agreement with the provider — Sotto
  cannot guarantee it."
- **B6 — The egress cue must be the menu-bar ICON,** not just the menu's status string
  (which is only seen after opening the menu). At-a-glance, while running.
- **B7 — `isConfigured` requires model AND key both present** (default model is `""`);
  a half-configured provider must not egress.
- Standing invariants: **no retry logic** (could double-transmit after cancel), never
  NSLog the key or transcript, fetch the key from Keychain per-call, `HistoryEntry` gains
  no key/provider field, Keychain item is `WhenUnlocked` (never synchronizable).

## Milestone A — Ollama-only (ship now)

`OllamaBackend` → `http://127.0.0.1:11434/api/chat` (`127.0.0.1`, not `localhost`, for a
clean traffic audit), `stream:false`, `.message.content`. `isAvailable` = model field
non-empty (never ping the server at rest). Files: `Providers.swift` (Ollama backend +
`ProviderFactory`), `LLMPostProcessor.swift`, Settings (`modelProvider`, `ollamaModel`),
SettingsView "Cleanup model" picker + model field + light one-liner disclosure, AppDelegate
`reloadProvider()` + `activeSmart`/`smartAvailable` + a **distinct loopback menu-bar cue**
("Local model (Ollama)", not the cloud warning). Plus **B1** (landing reword, scoped to
default build) + **B2** (enumeration test). No Keychain, no key UI, no cloud sheet.

## Milestone B — cloud BYOK, one provider (Anthropic) — separate review

Adds `KeychainStore` (SecItem, per-provider account, `WhenUnlocked`, never UserDefaults),
`AnthropicBackend` (`api.anthropic.com/v1/messages`, `x-api-key` from Keychain),
key `SecureField` bound directly to Keychain, the full first-run cloud disclosure sheet,
and **B3–B7**. Start with one provider; OpenAI/Groq are ~15-line backends to add later
(each is another host to disclose). The doctor/ZDR case lives here.
