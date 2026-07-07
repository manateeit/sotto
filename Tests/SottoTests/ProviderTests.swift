import Foundation
import Testing
@testable import Sotto

/// A backend that never touches the network — returns a canned reply, or throws.
private struct FakeBackend: LLMBackend {
    var timeout: TimeInterval = 1
    var reply: String?   // nil = throw (simulate a failed/timed-out call)
    func complete(system: String, user: String) async throws -> String {
        guard let reply else { throw ProviderError.malformed }
        return reply
    }
}

@Suite struct ProviderTests {

    // MARK: network-silent default (the crux)

    @MainActor @Test func defaultSettingsUseOnDeviceProviderAndBuildNoBackend() {
        // A fresh install defaults to on-device, and that yields NO backend.
        let settings = Settings(defaults: UserDefaults(suiteName: "sotto.test.\(UUID().uuidString)")!)
        #expect(settings.modelProvider == ModelProvider.none.rawValue)
        #expect(ProviderFactory.make(provider: ModelProvider(rawValue: settings.modelProvider) ?? .ollama,
                                     ollamaModel: settings.ollamaModel) == nil)
    }

    @Test func factoryReturnsNilForNone() {
        // With provider .none, NO network-capable backend is ever constructed.
        #expect(ProviderFactory.make(provider: .none, ollamaModel: "llama3.1:8b") == nil)
    }

    @Test func ollamaRequiresAModelId() {
        #expect(ProviderFactory.make(provider: .ollama, ollamaModel: "") == nil)
        #expect(ProviderFactory.make(provider: .ollama, ollamaModel: "   ") == nil)
        #expect(ProviderFactory.make(provider: .ollama, ollamaModel: "llama3.1:8b") != nil)
    }

    @Test func cloudRequiresModelAndKey() {
        // B7: a half-configured cloud provider must not egress.
        #expect(ProviderFactory.make(provider: .anthropic, ollamaModel: "",
                                     cloudModel: "claude-3-5-haiku-latest", cloudKeyPresent: false) == nil) // no key
        #expect(ProviderFactory.make(provider: .anthropic, ollamaModel: "",
                                     cloudModel: "", cloudKeyPresent: true) == nil)                          // no model
        #expect(ProviderFactory.make(provider: .anthropic, ollamaModel: "",
                                     cloudModel: "claude-3-5-haiku-latest", cloudKeyPresent: true) != nil)   // both
    }

    @Test func anthropicIsCloudOllamaIsNot() {
        #expect(ModelProvider.anthropic.isCloud)
        #expect(!ModelProvider.ollama.isCloud)
        #expect(!ModelProvider.none.isCloud)
        #expect(ModelProvider.anthropic.keyAccount == "anthropic-api-key")
        #expect(ModelProvider.ollama.keyAccount == nil)
    }

    /// B2 (critique): every network/egress marker must live ONLY in Providers.swift
    /// (opt-in models) or UpdateChecker.swift (explicit update check). This is the
    /// automatable guard that "all egress is in one greppable file" can't rot.
    @Test func networkEgressIsIsolatedToTwoFiles() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SottoTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/Sotto")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        // The teeth: any actual network call (URLSession) or cloud endpoint literal.
        // A bare port/IP in descriptive UI copy is not egress; URLSession catches a
        // real call regardless of the host.
        let markers = ["URLSession", "api.anthropic", "api.openai", "api.groq"]
        let allowed: Set<String> = ["Providers.swift", "UpdateChecker.swift"]

        for file in files where !allowed.contains(file.lastPathComponent) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for marker in markers {
                #expect(!text.contains(marker),
                        "\(file.lastPathComponent) contains egress marker '\(marker)' — network must stay in Providers.swift")
            }
        }
    }

    // MARK: LLMPostProcessor preserves SmartProcessor's error asymmetry

    @Test func cleanFailureReturnsRawTranscript() async throws {
        // No selection → cleanup path. Backend fails → return the raw text, never throw.
        let p = LLMPostProcessor(backend: FakeBackend(reply: nil))
        let result = try await p.process("hello there", context: ContextSnapshot())
        #expect(result.text == "hello there")
        #expect(result.mode == "dictate")
    }

    @Test func cleanSuccessReturnsCleaned() async throws {
        let p = LLMPostProcessor(backend: FakeBackend(reply: "Hello there."))
        let result = try await p.process("hello there", context: ContextSnapshot())
        #expect(result.text == "Hello there.")
        #expect(result.mode == "dictate")
    }

    @Test func transformFailureThrows() async {
        // Selection present → transform path. A failing backend must THROW
        // TransformFailed so the caller leaves the selection untouched.
        let p = LLMPostProcessor(backend: FakeBackend(reply: nil))
        let ctx = ContextSnapshot(selectedText: "the quick brown fox")
        await #expect(throws: TransformFailed.self) {
            _ = try await p.process("make it uppercase", context: ctx)
        }
    }
}
