import Foundation
import FoundationModels

/// Which path a finished dictation takes.
enum ProcessingRoute: Equatable {
    case smart
    case raw
}

/// Thrown by SmartProcessor when a *transform attempt* (the classify or transform
/// model call) fails or times out. It signals the caller to leave the user's
/// selection untouched rather than paste the raw spoken command over it.
struct TransformFailed: Error {}

/// Decides smart-vs-raw. Pure + unit-tested. Raw when the user held ⇧ (explicit
/// escape), Foundation Models is unavailable (Apple Intelligence off / device not
/// eligible), or the transcript is too long to be worth a model pass — never keep
/// the paste hostage to a slow model (DESIGN.md §3).
struct ProcessingPolicy {
    // ponytail: hardcoded 1200-char cap (~300 tokens, well under the ~4k context
    // window). M3 settings could expose it, but one well-chosen constant is enough.
    var rawLengthCap: Int = 1200

    func route(shiftHeld: Bool, smartAvailable: Bool, textLength: Int) -> ProcessingRoute {
        if shiftHeld || !smartAvailable || textLength > rawLengthCap {
            return .raw
        }
        return .smart
    }
}

/// The paste decision for a finished dictation.
enum PipelineOutcome: Equatable {
    /// Paste this text.
    case paste(String)
    /// A transform attempt failed — do not paste; leave the selection untouched.
    case transformFailed
}

/// Composes the finished-dictation path: route smart-vs-raw and produce the paste
/// decision. Both branches go through the PostProcessor seam (`raw` is Passthrough),
/// so the two-seam architecture stays honest and the raw route provably makes no
/// model call. A thrown error from `smart` means a transform attempt failed
/// (SmartProcessor throws only for that); dictate failures return the raw text
/// instead of throwing, so they arrive as `.paste`. The processors are injected so
/// tests can drive the whole composition with fakes.
struct ProcessingPipeline {
    var policy = ProcessingPolicy()

    func run(text: String,
             context: ContextSnapshot,
             shiftHeld: Bool,
             smartAvailable: Bool,
             smart: any PostProcessor,
             raw: any PostProcessor) async -> PipelineOutcome {
        let route = policy.route(shiftHeld: shiftHeld, smartAvailable: smartAvailable, textLength: text.count)
        if route == .raw {
            let out = (try? await raw.process(text, context: context)) ?? text
            return .paste(out)
        }
        do {
            return .paste(try await smart.process(text, context: context))
        } catch {
            return .transformFailed
        }
    }
}

/// Smart post-processor: on-device cleanup (dictate) or selection edit (transform)
/// via Apple's Foundation Models, behind the PostProcessor seam (DESIGN.md §2/§3).
///
// ponytail: uses the runtime `DynamicGenerationSchema` API for constrained,
// typed output because CommandLineTools doesn't ship the `@Generable` macro
// plugin. Under a full Xcode toolchain, swap these schemas for `@Generable`
// structs/enums — identical behavior and prompts, less code. The seam is unchanged.
struct SmartProcessor: PostProcessor {
    /// Canonical vocabulary terms passed to cleanup as bias hints.
    var vocabTerms: [String] = []

    // ponytail: hardcoded 8s per-stage model-call budget.
    static let timeout: TimeInterval = 8

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// A short human-readable reason when smart processing is off, for the menu
    /// bar's one-line degradation notice (nil when available).
    static var unavailableNote: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence off"
        case .unavailable(.deviceNotEligible):
            return "device not eligible"
        case .unavailable(.modelNotReady):
            return "model downloading"
        case .unavailable:
            return "unavailable"
        }
    }

    /// Cleanup (dictate) returns the polished text; a failure/timeout there is
    /// non-fatal and returns the raw transcript. A transform attempt (classify or
    /// transform) that fails/times out throws `TransformFailed` so the caller can
    /// leave the selection untouched — pasting the raw command would clobber it.
    func process(_ text: String, context: ContextSnapshot) async throws -> String {
        // Defensive: caller routes on availability, but never trust a stale check.
        guard SystemLanguageModel.default.isAvailable else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        if Self.canTransform(context: context), let selection = context.selectedText {
            let intent: Intent
            do {
                intent = try await withTimeout(Self.timeout) {
                    try await classify(utterance: trimmed, selection: selection)
                }
            } catch {
                throw TransformFailed()
            }
            if intent == .transform {
                do {
                    return try await withTimeout(Self.timeout) {
                        try await transform(instruction: trimmed, selection: selection)
                    }
                } catch {
                    throw TransformFailed()
                }
            }
            // intent == .dictate → fall through to cleanup below.
        }

        do {
            return try await withTimeout(Self.timeout) {
                try await clean(trimmed, context: context)
            }
        } catch {
            return text // dictate failure is non-fatal: paste the raw transcript
        }
    }

    /// Transform is only possible when there was a non-empty selection at record
    /// start; no selection ⇒ always dictation (never surprise the user). Pure.
    static func canTransform(context: ContextSnapshot) -> Bool {
        guard let selection = context.selectedText else { return false }
        return !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Foundation Models calls

    private enum Intent: String {
        case dictate
        case transform
    }

    private func classify(utterance: String, selection: String) async throws -> Intent {
        let root = DynamicGenerationSchema(
            name: "Intent",
            anyOf: [Intent.dictate.rawValue, Intent.transform.rawValue]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: Prompts.intentInstructions)
        let response = try await session.respond(
            to: Prompts.intentPrompt(selection: selection, utterance: utterance),
            schema: schema,
            options: GenerationOptions(temperature: 0)
        )
        let value = try response.content.value(String.self)
        return Intent(rawValue: value) ?? .dictate // unsure → dictate
    }

    private func clean(_ text: String, context: ContextSnapshot) async throws -> String {
        let root = DynamicGenerationSchema(
            name: "CleanedTranscript",
            properties: [.init(name: "text", description: "the cleaned transcript", schema: DynamicGenerationSchema(type: String.self))]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: Prompts.cleanupInstructions(context: context, vocabTerms: vocabTerms))
        let response = try await session.respond(
            to: Prompts.cleanupPrompt(transcript: text),
            schema: schema,
            options: GenerationOptions(temperature: 0.2)
        )
        let cleaned = try response.content.value(String.self, forProperty: "text")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }

    private func transform(instruction: String, selection: String) async throws -> String {
        let root = DynamicGenerationSchema(
            name: "TransformedText",
            properties: [.init(name: "text", description: "the selected text after applying the instruction", schema: DynamicGenerationSchema(type: String.self))]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: Prompts.transformInstructions)
        let response = try await session.respond(
            to: Prompts.transformPrompt(selection: selection, instruction: instruction),
            schema: schema,
            options: GenerationOptions(temperature: 0.2)
        )
        let out = try response.content.value(String.self, forProperty: "text")
        return out.isEmpty ? selection : out
    }
}
