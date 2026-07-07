# Sotto vs superwhisper — Strategic Analysis

*Generated 2026-07-07 from a 9-agent research workflow (7 parallel research dimensions across superwhisper's site/docs/changelog + GitHub, an Opus synthesis grounded in Sotto's actual source, and an adversarial identity-fit critique). The critique's verdict overrides the report where they disagree.*

---

## The headline finding: how superwhisper's Claude Code / Codex integration actually works

It is **not** an MCP server, **not** a REST API, and **not** an in-app feature. It's a **deeplink + temp-file polling bridge**:

1. An agent-side plugin captures a lifecycle event (agent finished / asking a question / needs permission).
2. It writes the agent's last message to a **temp file** for context.
3. It fires a `superwhisper://` **deeplink** to hand off to the app.
4. superwhisper pops its recording window, pre-loaded with that context.
5. You speak; it transcribes to a **response temp file**.
6. The plugin **polls that file** and injects the transcript back into the agent.

For Claude Code, the public repo (`superultrainc/superwhisper-claude-code`) is just a `hooks/hooks.json` registering five lifecycle hooks (`Stop`, `Notification`, `PreToolUse[AskUserQuestion]`, `PermissionRequest`, `UserPromptSubmit`) — all pointing at **one closed compiled binary inside the .app bundle**. Per-project on/off is an `md5($PWD)` flag file in `/tmp`. Codex/OpenCode/Pi use the identical pattern per their plugin bus.

**Two structural weaknesses:** (a) you must trust one binary blob; (b) it's **inbound-reactive only** — the agent has to stop and hand off; it can't *pull* voice on demand. superwhisper has **no MCP server** (reviewers call this out as a gap).

### Where Sotto already stands
- **Outbound half: DONE and cleaner.** `TypeIntoTerminalCommand` types a parsed command into an allowlisted terminal and **never presses Return** — the human's Return is the execution gate. Genuinely ahead of superwhisper on safety.
- **Inbound half: MISSING.** Nothing lets Claude Code wake Sotto when it finishes or asks. Sotto only starts from ⌥Space.

### The recommended build (per the critique — decisive)
Ship **one** thing: a **local stdio MCP server** exposing `ask_user_by_voice(prompt) → transcript`.
- stdio = child process over pipes → **zero network, zero standing service, no URL scheme, no temp-file polling, no flag files.**
- Typed in/out instead of scraping "the last message."
- Agent-**pull** (asks for voice exactly when it wants an answer) — the thing superwhisper structurally cannot do.
- Returns **text only, never an action** → confirm-gate stays intact; the existing violet confirm pill remains mandatory for any voice→command path.

The critique explicitly **cuts** the `sotto://` hooks-bridge, response-temp-file protocol, per-project flag file, and statusline as "matching a competitor's workaround when you have the better primitive."

---

## Feature & configuration gap matrix (the honest read)

**~60% of superwhisper's config surface is exactly what Sotto deliberately cut.** Closing those would betray "radically simpler."

| superwhisper | Sotto today | Verdict |
|---|---|---|
| Global hotkey (toggle + PTT) | parity | — |
| Modes (Message/Email/Note/Super/Custom + per-mode prompts) | none (Dictate/Transform auto) | **by design — never add** |
| STT model zoo (Whisper tiers + Parakeet + cloud) | SpeechAnalyzer only | by design (Parakeet behind seam = later) |
| LLM model picker (Claude/GPT/Gemini per mode) | Foundation Models only | by design |
| BYOK / custom providers | none wired | later (off-by-default, per-provider) |
| Context awareness (per-mode toggles) | all 3 sources, always on | parity (zero-config is better) |
| Realtime transcript | Nova cloud only | later (SpeechAnalyzer streams natively — cheap) |
| History (searchable, Voice/AI toggle, reprocess) | JSONL+WAV, star/delete/reprocess | **close: add full-text search + Raw⇄Cleaned toggle** |
| Deep-link automation (`superwhisper://`) | none | close (agentic) — but critique says MCP makes it redundant |
| **Agent hooks (Claude Code/Codex)** | outbound only | **close: build inbound via MCP voice-pull** |
| **MCP server** | none (superwhisper lacks it too) | **close: Sotto's leapfrog** |
| Cancel safety (confirm if >30s) | Esc = instant discard | **close (cheap): time-gated confirm** |
| Onboarding (guided first dictation + verify) | grants walk only | **close: highest-ROI UX borrow** |
| Modes/enterprise/accounts/translation/dual-window | none | **by design** |

---

## UI redesign brief (critique-trimmed)

Sotto's HUD (`HUD.swift`) is already good: one color-coded dot (red/blue/green/violet), 21-bar waveform, `.ultraThinMaterial` capsule, non-activating panel. **Don't rebuild it; sharpen it.** superwhisper wins on *information density per pixel* and *named recurring micro-polish* — adopt the discipline, reject the window-count and settings sprawl.

**SHIP (real polish, no new mental model):**
- **Violet confirm-state distinction** — hairline violet stroke so "waiting on YOU" reads instantly differently from "working." The signature safety gate; the one place extra visual weight is justified.
- **Menu-bar dot mirrors HUD state** — glanceable state without the pill; zero new concept.
- **History full-text search** (search only).
- **Onboarding: guided first dictation + "we heard: '…' looks good?" verify** — turns run-one anxiety into confirmed success.
- **Time-gated cancel confirm (>30s)** — protects long dictations, keeps short-cancel frictionless.
- **Motion-polish cadence** — one surface's micro-interactions per release as a named changelog line (a process, not a feature).

**HOLD / REJECT (complexity masquerading as polish):**
- **REJECT: HUD mode/target labels** ("Transform · Notes", "Reply → Claude Code") — the mode maze in disguise; teaches users Sotto has modes. Neutral `Transform`/`Dictate` at most.
- **HOLD: context-capture micro-indicator** — a status light that exists to explain behavior that should be invisible; if Transform surprises users, fix the heuristic, not add chrome.
- **REJECT: fourth "Integrations" settings tab** — keep three tabs; agent setup goes in an "Agents" *section inside General*, never a tab.
- **REJECT visually:** mini/maxi dual-window, hover-interactive HUD controls (focus safety), theme picker, any per-mode settings UI.
- **History v2, not v1:** Raw⇄Cleaned toggle + card redesign is defensible (data exists) but ships after search.

---

## Ranked next actions (critique's re-ranking)

| # | Action | Effort | Fit |
|---|---|---|---|
| 1 | **Onboarding: guided first dictation + verify** — do first, helps every user | S | Strong |
| 2 | **`ask_user_by_voice` stdio MCP server (only)** — the differentiated agent feature | M | Strong |
| 3 | **History full-text search** (search only) | S | Strong |
| 4 | **Time-gated cancel confirm (>30s)** | S | Strong |
| 5 | **Violet confirm-state visual distinction** | S | Strong |
| 6 | **Menu-bar dot mirrors HUD state** | S | Strong |
| 7 | **Motion-polish cadence** (ongoing process) | S | Neutral/good |
| 8 | **History Raw⇄Cleaned toggle** (v2 of History) | M | OK |
| — | HOLD: context micro-indicator | — | Weak |
| — | REJECT: HUD mode labels; `sotto://`+hooks-bridge+flag-file+statusline; modes/model-pickers/cloud-zoo/BYOK-default/enterprise/translation/dual-window | — | Violates identity |

**Bottom line:** superwhisper's agent integration is clever but closed, one-directional, and MCP-less. Sotto is already ahead on safety (confirm-gate, never-press-Return) and privacy (on-device, open data). The winning move: build the *inbound* half of the agent loop as an on-device voice-pull MCP tool, add low-chrome polish (onboarding verify, history search, confirm-state), and treat ~60% of superwhisper's config catalog as a list of things to keep *not* building.
