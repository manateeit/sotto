import Foundation

/// Cleanup/transform through an external model (Ollama, later cloud) behind the
/// PostProcessor seam. Its control flow is a copy of `SmartProcessor.process`,
/// swapping the Foundation Models calls for `backend.complete(system:user:)` — so
/// every provider inherits the same prompts (the "never changes your meaning"
/// cleanup contract + domain bias + vocab hints) and the SAME error asymmetry:
/// a failed transform throws (leave the selection untouched); a failed clean
/// returns the raw transcript (never lose the paste).
struct LLMPostProcessor: PostProcessor {
    let backend: any LLMBackend
    var vocabTerms: [String] = []
    var domainProfile: String = ""

    func process(_ text: String, context: ContextSnapshot) async throws -> PostProcessorResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return PostProcessorResult(text: text, mode: "dictate") }

        if SmartProcessor.canTransform(context: context), let selection = context.selectedText {
            let intent: Intent
            do {
                intent = try await withTimeout(backend.timeout) {
                    try await classify(utterance: trimmed, selection: selection)
                }
            } catch {
                throw TransformFailed()
            }
            if intent == .transform {
                do {
                    let out = try await withTimeout(backend.timeout) {
                        try await transform(instruction: trimmed, selection: selection)
                    }
                    return PostProcessorResult(text: out, mode: "transform")
                } catch {
                    throw TransformFailed()
                }
            }
            // intent == .dictate → fall through to cleanup.
        }

        do {
            let cleaned = try await withTimeout(backend.timeout) {
                try await clean(trimmed, context: context)
            }
            return PostProcessorResult(text: cleaned, mode: "dictate")
        } catch {
            return PostProcessorResult(text: text, mode: "dictate") // non-fatal → raw
        }
    }

    // MARK: model calls (reuse Prompts verbatim)

    private enum Intent { case dictate, transform }

    /// A plain chat model can't return a constrained schema like FM, so demand a
    /// single bare word and match only the FIRST word — a substring search would
    /// misfire on a verbose reply like "this isn't a transform request" and wrongly
    /// overwrite the selection. Anything that isn't exactly "transform" is dictation
    /// (matches FM's unsure-→-dictate fail-safe, which never surprises the user).
    private func classify(utterance: String, selection: String) async throws -> Intent {
        let reply = try await backend.complete(
            system: Prompts.intentInstructions + "\n\nAnswer with exactly one word: \"transform\" or \"dictate\". No other text.",
            user: Prompts.intentPrompt(selection: selection, utterance: utterance))
        let firstWord = reply.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return firstWord == "transform" ? .transform : .dictate
    }

    private func clean(_ text: String, context: ContextSnapshot) async throws -> String {
        let reply = try await backend.complete(
            system: Prompts.cleanupInstructions(context: context, vocabTerms: vocabTerms, domainProfile: domainProfile),
            user: Prompts.cleanupPrompt(transcript: text))
        let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }

    private func transform(instruction: String, selection: String) async throws -> String {
        let reply = try await backend.complete(
            system: Prompts.transformInstructions,
            user: Prompts.transformPrompt(selection: selection, instruction: instruction))
        let out = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? selection : out
    }
}
