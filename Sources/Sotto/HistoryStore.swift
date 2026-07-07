import Foundation

/// One completed dictation, persisted to the open JSONL history (DESIGN.md §2/§4).
struct HistoryEntry: Codable, Sendable, Identifiable {
    let id: String
    let date: Date
    /// Transcript straight from the STT engine, before post-processing.
    let rawTranscript: String
    /// What was actually pasted.
    let finalOutput: String
    /// "dictate", "transform", or "raw".
    let route: String
    let app: String?
    let bundleID: String?
    /// Recording length in seconds.
    let durationSeconds: Double
    let engineID: String
    /// WAV filename under the audio directory, if audio was kept.
    let audioFile: String?
    /// Starred by the user to pin it to the top of the History list. Optional so
    /// pre-favorites entries (no key in their JSONL line) still decode.
    var favorite: Bool?

    /// Whether this entry is starred. Treats a missing flag as not-favorited.
    var isFavorite: Bool { favorite ?? false }

    init(id: String = UUID().uuidString,
         date: Date = Date(),
         rawTranscript: String,
         finalOutput: String,
         route: String,
         app: String?,
         bundleID: String?,
         durationSeconds: Double,
         engineID: String,
         audioFile: String?,
         favorite: Bool? = nil) {
        self.id = id
        self.date = date
        self.rawTranscript = rawTranscript
        self.finalOutput = finalOutput
        self.route = route
        self.app = app
        self.bundleID = bundleID
        self.durationSeconds = durationSeconds
        self.engineID = engineID
        self.audioFile = audioFile
        self.favorite = favorite
    }
}

/// Append-only JSONL history + WAV audio at ~/Library/Application Support/Sotto/
/// history/, with a retention sweep. Open, greppable format — no database
/// (DESIGN.md §4). Failed/cancelled dictations are never recorded (the AppDelegate
/// only appends after a successful paste).
enum HistoryStore {
    // ponytail: default 30-day retention; the settings picker overrides it.
    static let defaultRetentionDays = 30

    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }
    static var jsonlURL: URL { directoryURL.appendingPathComponent("history.jsonl") }
    static var audioDirectoryURL: URL { directoryURL.appendingPathComponent("audio", isDirectory: true) }

    /// URL to write/read the WAV for a given entry id.
    static func audioURL(forID id: String) -> URL {
        audioDirectoryURL.appendingPathComponent("\(id).wav")
    }

    // MARK: Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func append(_ entry: HistoryEntry) {
        guard let line = encode(entry) else { return }
        ensureDirectory()
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: jsonlURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: jsonlURL)
        }
    }

    static func load() -> [HistoryEntry] {
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return [] }
        return decode(jsonl: text)
    }

    /// Pure: encode one entry to a single JSONL line.
    static func encode(_ entry: HistoryEntry) -> String? {
        guard let data = try? encoder.encode(entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pure: decode a JSONL blob, skipping malformed lines.
    static func decode(jsonl: String) -> [HistoryEntry] {
        jsonl.split(separator: "\n").compactMap { line in
            try? decoder.decode(HistoryEntry.self, from: Data(line.utf8))
        }
    }

    // MARK: Retention

    /// Whether an entry is past its retention window. `retentionDays <= 0` keeps
    /// everything forever. Pure — unit-tested.
    static func isExpired(_ entry: HistoryEntry, retentionDays: Int, now: Date = Date()) -> Bool {
        guard retentionDays > 0 else { return false }
        return now.timeIntervalSince(entry.date) > Double(retentionDays) * 86_400
    }

    /// Partition entries into (kept, expired) by the retention policy. Pure.
    static func partition(_ entries: [HistoryEntry], retentionDays: Int, now: Date = Date())
        -> (kept: [HistoryEntry], expired: [HistoryEntry]) {
        var kept: [HistoryEntry] = []
        var expired: [HistoryEntry] = []
        for entry in entries {
            if isExpired(entry, retentionDays: retentionDays, now: now) { expired.append(entry) }
            else { kept.append(entry) }
        }
        return (kept, expired)
    }

    /// Pure line-level prune: keep every line that either fails to parse (preserved
    /// byte-intact so we never silently destroy data we don't understand) OR parses
    /// and is unexpired; drop only lines that parse AND are expired.
    static func pruneLines(_ lines: [String], retentionDays: Int, now: Date = Date())
        -> (kept: [String], expired: [HistoryEntry]) {
        guard retentionDays > 0 else { return (lines, []) }
        var kept: [String] = []
        var expired: [HistoryEntry] = []
        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let entry = try? decoder.decode(HistoryEntry.self, from: Data(line.utf8)) {
                if isExpired(entry, retentionDays: retentionDays, now: now) {
                    expired.append(entry)
                } else {
                    kept.append(line)
                }
            } else {
                kept.append(line) // unparseable → preserve exactly
            }
        }
        return (kept, expired)
    }

    /// Rewrite the JSONL dropping only parsed+expired lines (unparseable lines are
    /// preserved) and delete the expired WAVs.
    static func prune(retentionDays: Int, now: Date = Date()) {
        guard retentionDays > 0 else { return }
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let (kept, expired) = pruneLines(lines, retentionDays: retentionDays, now: now)
        guard !expired.isEmpty else { return } // nothing removed → leave the file untouched
        let rewritten = kept.joined(separator: "\n")
        try? (rewritten.isEmpty ? "" : rewritten + "\n").data(using: .utf8)?.write(to: jsonlURL)
        for entry in expired {
            if let file = entry.audioFile {
                try? FileManager.default.removeItem(at: audioDirectoryURL.appendingPathComponent(file))
            }
        }
    }

    /// Rewrite the JSONL, mapping each PARSED entry through `transform` (return nil
    /// to drop it) while preserving unparseable lines byte-intact — same "never
    /// destroy data we don't understand" rule as prune. ponytail: full rewrite per
    /// mutation is O(n), fine for a retention-bounded personal history file.
    private static func rewrite(_ transform: (HistoryEntry) -> HistoryEntry?) {
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return }
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if let entry = try? decoder.decode(HistoryEntry.self, from: Data(s.utf8)) {
                if let mapped = transform(entry), let encoded = encode(mapped) {
                    out.append(encoded)
                }
            } else {
                out.append(s) // preserve unparseable
            }
        }
        let joined = out.joined(separator: "\n")
        try? (joined.isEmpty ? "" : joined + "\n").data(using: .utf8)?.write(to: jsonlURL)
    }

    /// Delete one entry (its JSONL line + WAV).
    static func delete(id: String) {
        rewrite { $0.id == id ? nil : $0 }
        try? FileManager.default.removeItem(at: audioURL(forID: id))
    }

    /// Star / unstar one entry.
    static func setFavorite(id: String, _ favorite: Bool) {
        rewrite { entry in
            guard entry.id == id else { return entry }
            var updated = entry
            updated.favorite = favorite
            return updated
        }
    }

    /// Wipe all history (JSONL + audio). The "Delete all history" button.
    static func deleteAll() {
        try? FileManager.default.removeItem(at: jsonlURL)
        try? FileManager.default.removeItem(at: audioDirectoryURL)
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
    }
}
