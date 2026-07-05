import Foundation

/// The second protocol seam (see DESIGN.md §2). This is where the product's
/// "agentic ceiling" lives: M2 adds `SmartProcessor` (Foundation Models guided
/// generation) behind this same interface, and later Ollama / Anthropic providers.
/// M0 ships only the raw pass-through.
protocol PostProcessor: Sendable {
    func process(_ text: String) async throws -> String
}

/// Raw transcript, unchanged. The MVP escape hatch and the M0 default.
struct Passthrough: PostProcessor {
    func process(_ text: String) async throws -> String { text }
}
