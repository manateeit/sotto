import Foundation

/// Loads the user's vocabulary table from a hand-editable JSON file at
/// ~/Library/Application Support/Sotto/vocabulary.json, writing a commented
/// example there on first run. The editor UI is M3; this is just the file glue.
enum VocabularyStore {
    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("vocabulary.json")
    }

    /// Load the table, creating the example file if it doesn't exist yet.
    static func loadCreatingExampleIfNeeded() -> VocabularyRewriter {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            writeExample(to: url)
            return .empty
        }
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return VocabularyRewriter.decode(data)
    }

    /// Persist the edited table back to the JSON file (settings vocabulary editor).
    static func save(_ rewriter: VocabularyRewriter) {
        guard let data = rewriter.encoded() else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }

    /// The example file written on first run. Empty `rules` by default (raw path
    /// stays byte-for-byte); `_comment` / `_example` teach the format and are
    /// ignored by the decoder, which only reads `rules`. Exposed for a round-trip
    /// parse test.
    static let exampleFileContents = """
    {
      "_comment": "Sotto vocabulary. Each rule in `rules` replaces `pattern` with `replacement`. Set `regex` to true for a case-insensitive regular-expression pattern; regex replacements can use $1 etc. Rules apply in order, before smart cleanup. Delete this comment and add rules.",
      "_example": { "pattern": "github", "replacement": "GitHub", "regex": false },
      "rules": []
    }

    """

    private static func writeExample(to url: URL) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? exampleFileContents.data(using: .utf8)?.write(to: url)
    }
}
