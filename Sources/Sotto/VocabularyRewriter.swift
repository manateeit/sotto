import Foundation

/// Deterministic replacement table applied to the raw transcript before the
/// PostProcessor (DESIGN.md §2). Covers custom vocabulary / known misrecognitions
/// that SpeechAnalyzer has no API for. Pure and order-sensitive.
///
/// Default is EMPTY so the raw (⇧) path is byte-for-byte the transcript; M3's
/// settings will let the user populate the table.
struct VocabularyRewriter: Sendable {
    struct Rule: Sendable {
        let pattern: String
        let replacement: String
        let isRegex: Bool

        init(_ pattern: String, _ replacement: String, isRegex: Bool = false) {
            self.pattern = pattern
            self.replacement = replacement
            self.isRegex = isRegex
        }
    }

    var rules: [Rule]

    init(rules: [Rule] = []) {
        self.rules = rules
    }

    static let empty = VocabularyRewriter()

    func rewrite(_ text: String) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        for rule in rules {
            if rule.isRegex {
                guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                    continue
                }
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.replacement)
            } else {
                result = result.replacingOccurrences(of: rule.pattern, with: rule.replacement)
            }
        }
        return result
    }

    /// Canonical terms to bias the model toward (the literal replacements), passed
    /// as prompt hints to the SmartProcessor. Regex replacements (which contain
    /// templates like `$1`) are excluded.
    var hintTerms: [String] {
        rules.filter { !$0.isRegex }
            .map { $0.replacement.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: JSON

    private struct File: Decodable {
        var rules: [StoredRule]
        struct StoredRule: Decodable {
            var pattern: String
            var replacement: String
            var regex: Bool?
        }
    }

    /// Decode rules from `vocabulary.json` data. Pure; malformed data → empty table.
    static func decode(_ data: Data) -> VocabularyRewriter {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return .empty }
        return VocabularyRewriter(rules: file.rules.map {
            Rule($0.pattern, $0.replacement, isRegex: $0.regex ?? false)
        })
    }

    private struct OutFile: Encodable {
        struct OutRule: Encodable {
            let pattern: String
            let replacement: String
            let regex: Bool
        }
        let rules: [OutRule]
    }

    /// Encode the rules back to the `vocabulary.json` format. Pure.
    func encoded() -> Data? {
        let file = OutFile(rules: rules.map { .init(pattern: $0.pattern, replacement: $0.replacement, regex: $0.isRegex) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return try? encoder.encode(file)
    }
}
