import Foundation

/// Which model runs cleanup. `.none` (default) = Apple's on-device Foundation
/// Models; the others route through the PostProcessor seam to an external model.
/// Persisted as the raw string. Cloud providers (anthropic/openai/groq) land in
/// Milestone B; Milestone A ships `.none` + `.ollama` only.
enum ModelProvider: String, CaseIterable, Sendable {
    case none
    case ollama
}

enum ProviderError: Error, CustomStringConvertible {
    case badResponse(Int)
    case malformed
    var description: String {
        switch self {
        case .badResponse(let code): return "provider returned HTTP \(code)"
        case .malformed: return "provider response was malformed"
        }
    }
}

/// A single chat-completion round-trip: system + user in, one string out. Pure
/// request/response mapping — no control flow, no routing. Ollama and (later) the
/// cloud vendors are the same shape; only endpoint/auth/JSON-paths differ.
protocol LLMBackend: Sendable {
    var timeout: TimeInterval { get }
    func complete(system: String, user: String) async throws -> String
}

/// Local model via Ollama (`http://127.0.0.1:11434`). Loopback only — the
/// transcript never leaves the machine. `127.0.0.1` (not `localhost`) to avoid DNS
/// and read unambiguously in a traffic audit.
struct OllamaBackend: LLMBackend {
    let model: String
    var timeout: TimeInterval = 20 // local models are slower than FM; still bounded
    private static let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!

    func complete(system: String, user: String) async throws -> String {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        let body: [String: Any] = [
            "model": model,
            "stream": false, // one JSON object, no SSE parsing
            "options": ["temperature": 0.2],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // data(for:) is natively cancellation-aware: when withTimeout cancels the
        // losing task, the request is actually aborted (not left running).
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProviderError.malformed
        }
        return content
    }
}

/// The SINGLE construction site for any network-capable backend. Returns nil when
/// no provider is configured, so with `provider == .none` (the default) no
/// URLSession-bearing object is ever instantiated — the structural guarantee that
/// the default build is network-silent. Pure + unit-tested.
enum ProviderFactory {
    static func make(provider: ModelProvider, ollamaModel: String) -> (any LLMBackend)? {
        switch provider {
        case .none:
            return nil
        case .ollama:
            let model = ollamaModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? nil : OllamaBackend(model: model)
        }
    }
}
