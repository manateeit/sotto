import Foundation

/// Imports vocabulary from common competitor formats (JSON arrays, CSV, plain text).
/// No account needed — pure file I/O. Converts to Sotto's Rule format.
enum VocabularyImporter {
    /// Import from a file path. Returns a list of Rule objects.
    /// Format detection is heuristic: tries JSON first, then CSV, then plain text (one term per line).
    static func importVocabulary(from url: URL) -> [VocabularyRewriter.Rule]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let contents = String(data: data, encoding: .utf8) else { return nil }

        // Try JSON format first (Superwhisper, MacWhisper, VoiceInk all export as JSON)
        if let rules = parseJSON(contents) { return rules }

        // Fall back to CSV (term,replacement or just term per line)
        if let rules = parseCSV(contents) { return rules }

        // Last resort: plain text (one term per line)
        return parsePlainText(contents)
    }

    /// Parse JSON format: [{ "term": "...", "replacement": "..." }, ...] or [{ "word": "...", "correct": "..." }]
    /// Flexible: handles multiple field names.
    private static func parseJSON(_ contents: String) -> [VocabularyRewriter.Rule]? {
        guard let data = contents.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var rules: [VocabularyRewriter.Rule] = []
        for item in items {
            let term = item["term"] as? String
                ?? item["word"] as? String
                ?? item["pattern"] as? String
                ?? item["from"] as? String

            let replacement = item["replacement"] as? String
                ?? item["correct"] as? String
                ?? item["to"] as? String

            if let term = term, let replacement = replacement {
                rules.append(VocabularyRewriter.Rule(term, replacement, isRegex: false))
            }
        }
        return rules.isEmpty ? nil : rules
    }

    /// Parse CSV: term,replacement per line. If only one column, treat as both pattern and replacement.
    private static func parseCSV(_ contents: String) -> [VocabularyRewriter.Rule]? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        var rules: [VocabularyRewriter.Rule] = []

        for line in lines {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty {
                rules.append(VocabularyRewriter.Rule(String(parts[0]), String(parts[1]), isRegex: false))
            } else if parts.count == 1, !parts[0].isEmpty {
                // Single column: use as both pattern and replacement (canonical term)
                rules.append(VocabularyRewriter.Rule(String(parts[0]), String(parts[0]), isRegex: false))
            }
        }
        return rules.isEmpty ? nil : rules
    }

    /// Parse plain text: one term per line. Duplicates become identity rules (term → term).
    private static func parsePlainText(_ contents: String) -> [VocabularyRewriter.Rule]? {
        let terms = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return nil }
        return terms.map { VocabularyRewriter.Rule($0, $0, isRegex: false) }
    }

    /// Merge imported rules into existing vocabulary (imported rules come first, so they take precedence).
    static func merge(_ existing: VocabularyRewriter, with imported: [VocabularyRewriter.Rule]) -> VocabularyRewriter {
        // Dedup by pattern: keep first occurrence (imported > existing)
        var seen = Set<String>()
        var merged: [VocabularyRewriter.Rule] = []

        for rule in imported {
            if !seen.contains(rule.pattern) {
                merged.append(rule)
                seen.insert(rule.pattern)
            }
        }

        for rule in existing.rules {
            if !seen.contains(rule.pattern) {
                merged.append(rule)
                seen.insert(rule.pattern)
            }
        }

        return VocabularyRewriter(rules: merged)
    }
}
