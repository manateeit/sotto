import Foundation

/// What kind of action a spoken command names (M6). Kept a small closed set: this
/// is a PARSER classification, never a tool the model auto-invokes.
enum CommandKind: String, Sendable, CaseIterable, Equatable {
    case openTarget
    case systemControl
    case typeIntoTerminal
    case unknown
}

/// How sure the parse is. Low confidence is treated the same as `unknown` — nothing
/// executes (never invent a command the user didn't say).
enum CommandConfidence: String, Sendable, Equatable {
    case high
    case low
}

/// A parsed command: the classified kind plus the literal argument (app/URL, the
/// normalized system action, or the words to type). Pure data.
struct ParsedCommand: Sendable, Equatable {
    var kind: CommandKind
    var argument: String
    var confidence: CommandConfidence
}

/// The command-parser seam (M6). `SmartCommandParser` is the real Foundation Models
/// implementation; tests inject a fake to drive the dispatch composition without a
/// model. Mirrors the `PostProcessor` seam — the FM is a PARSER ONLY, never a tool
/// attached to a session (attached tools auto-invoke before the human confirms,
/// which is forbidden).
protocol CommandParsing: Sendable {
    func parse(_ utterance: String) async throws -> ParsedCommand
}

/// The outcome of planning a command from a stripped utterance.
enum CommandPlan: Equatable, Sendable {
    /// A recognized command to confirm-then-run.
    case execute(ParsedCommand)
    /// Unknown / low-confidence / parser unavailable → "Didn't catch a command".
    case notACommand
}

/// Composes the command-recognition path (M6), mirroring `ProcessingPipeline`:
/// a deterministic curated pre-pass runs BEFORE the model, and a curated hit skips
/// the FM call entirely. Only non-curated utterances reach the injected parser.
/// Unknown, low-confidence, empty, or parser-failure all resolve to `.notACommand`
/// so nothing executes. Pure orchestration; the parser is injected so tests can
/// drive the whole composition with a fake (and prove the curated path never
/// consults the model).
struct CommandPipeline {
    func plan(utterance: String, parser: any CommandParsing) async -> CommandPlan {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notACommand }

        // Deterministic pre-pass: curated universal phrases resolve without any FM
        // call (fast, private, offline).
        if let curated = CommandVocabulary.match(trimmed) {
            return .execute(curated)
        }

        // Everything else goes to the model. A throw (FM unavailable / timeout /
        // error) means "not a command" — never guess.
        guard let parsed = try? await parser.parse(trimmed) else {
            return .notACommand
        }
        if parsed.kind == .unknown || parsed.confidence == .low {
            return .notACommand
        }
        return .execute(parsed)
    }
}

/// The deterministic curated command map (M6). Only UNIVERSAL phrases live here —
/// nothing project-specific ("run the tests" → "npm test" is NOT hardcodable). A
/// match returns a high-confidence `ParsedCommand` and short-circuits the FM call.
/// Matching is case-insensitive on ASCII verbs; the ARGUMENT keeps its original
/// case (so "type Hello World" types "Hello World"). Pure + unit-tested.
enum CommandVocabulary {
    static func match(_ utterance: String) -> ParsedCommand? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Verb-prefixed commands that take a literal argument.
        if let arg = argument(after: "open", in: trimmed) {
            return ParsedCommand(kind: .openTarget, argument: arg, confidence: .high)
        }
        if let arg = argument(after: "type", in: trimmed) {
            return ParsedCommand(kind: .typeIntoTerminal, argument: arg, confidence: .high)
        }
        if let arg = argument(after: "run", in: trimmed) {
            return ParsedCommand(kind: .typeIntoTerminal, argument: arg, confidence: .high)
        }
        // Whole-utterance system-control phrases.
        if let action = SystemControlCommand.curatedAction(for: trimmed) {
            return ParsedCommand(kind: .systemControl, argument: action, confidence: .high)
        }
        return nil
    }

    /// The literal text after an ASCII verb + space, or nil if the utterance doesn't
    /// start with "<verb> " or the remainder is empty. Operates on the original
    /// string so the argument keeps its case; the prefix is matched case-insensitively.
    private static func argument(after verb: String, in trimmed: String) -> String? {
        let prefix = verb + " "
        guard trimmed.count > prefix.count,
              trimmed.lowercased().hasPrefix(prefix) else { return nil }
        // Safe drop: `prefix` is ASCII, so its character count aligns between the
        // original and lowercased forms.
        let arg = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return arg.isEmpty ? nil : arg
    }
}
