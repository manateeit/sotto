import Foundation

/// Result of a post-processing pass: the text to paste plus which behavior
/// produced it (for open history). `mode` is "dictate", "transform", or "raw".
struct PostProcessorResult: Sendable, Equatable {
    var text: String
    var mode: String
}

/// The second protocol seam (see DESIGN.md §2). This is where the product's
/// "agentic ceiling" lives: M2 adds `SmartProcessor` (Foundation Models) behind
/// this same interface, and later Ollama / Anthropic providers. The processor
/// receives the context captured at record start (selection, frontmost app,
/// recent clipboard).
protocol PostProcessor: Sendable {
    func process(_ text: String, context: ContextSnapshot) async throws -> PostProcessorResult
}

/// Raw transcript, unchanged. The ⇧ escape hatch and the graceful-degradation
/// default when Foundation Models is unavailable.
struct Passthrough: PostProcessor {
    func process(_ text: String, context: ContextSnapshot) async throws -> PostProcessorResult {
        PostProcessorResult(text: text, mode: "raw")
    }
}
