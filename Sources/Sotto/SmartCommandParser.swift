import Foundation
import FoundationModels

/// The real command parser (M6): one on-device Foundation Models guided-generation
/// call that CLASSIFIES a spoken command. It is a PARSER ONLY — no FoundationModels
/// `Tool` is ever attached to the session, because attached tools auto-invoke before
/// the human confirms, which is forbidden here. Same DynamicGenerationSchema +
/// withTimeout(8s) shape as `SmartProcessor`. Only non-curated utterances reach this
/// (the curated pre-pass in `CommandPipeline` runs first).
///
// ponytail: the schema returns flat String fields and this maps them to the
// CommandKind/CommandConfidence enums, mirroring SmartProcessor's use of the runtime
// DynamicGenerationSchema API (the @Generable macro isn't on the CLT toolchain).
// Under a full Xcode toolchain, a `@Generable enum` would hard-constrain the `kind`
// field at the model boundary instead of validating the string here — identical
// behavior, less code. An unrecognized `kind` maps to `.unknown` ⇒ nothing runs.
struct SmartCommandParser: CommandParsing {
    // ponytail: hardcoded 8s model-call budget, matching SmartProcessor.
    static let timeout: TimeInterval = 8

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func parse(_ utterance: String) async throws -> ParsedCommand {
        guard SystemLanguageModel.default.isAvailable else {
            // Unavailable ⇒ caller treats a throw as "not a command".
            throw CommandError.unsupported
        }
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedCommand(kind: .unknown, argument: "", confidence: .low)
        }
        return try await withTimeout(Self.timeout) {
            try await classify(trimmed)
        }
    }

    private func classify(_ utterance: String) async throws -> ParsedCommand {
        let root = DynamicGenerationSchema(
            name: "ParsedCommand",
            properties: [
                .init(name: "command",
                      description: "one of exactly: openTarget, systemControl, typeIntoTerminal, unknown",
                      schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "argument",
                      description: "the literal argument — an app name or https URL, a volume action, or the exact words to type; empty if none",
                      schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "confidence",
                      description: "high only if the utterance is clearly one of the commands; otherwise low",
                      schema: DynamicGenerationSchema(type: String.self)),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: Prompts.commandInstructions)
        let response = try await session.respond(
            to: Prompts.commandPrompt(utterance: utterance),
            schema: schema,
            options: GenerationOptions(temperature: 0)
        )
        let kindRaw = (try? response.content.value(String.self, forProperty: "command")) ?? "unknown"
        let argument = (try? response.content.value(String.self, forProperty: "argument")) ?? ""
        let confidenceRaw = (try? response.content.value(String.self, forProperty: "confidence")) ?? "low"

        let kind = CommandKind(rawValue: kindRaw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .unknown
        let confidence = CommandConfidence(rawValue: confidenceRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .low
        return ParsedCommand(
            kind: kind,
            argument: argument.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence
        )
    }
}
