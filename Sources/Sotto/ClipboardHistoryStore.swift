import AppKit
import Foundation
import os

/// One captured clipboard copy. Deliberately minimal and PLAIN TEXT ONLY — no
/// dictation fields (rawTranscript/route/audio), no favorites. Physically separate
/// from `HistoryEntry` so voice history and clipboard history can never mix.
struct ClipboardEntry: Codable, Sendable, Identifiable {
    let id: String
    let date: Date
    /// The copied string (length-capped at capture).
    let text: String
    /// Frontmost app at capture time, for attribution.
    let sourceApp: String?
    let bundleID: String?

    init(id: String = UUID().uuidString, date: Date = Date(),
         text: String, sourceApp: String?, bundleID: String?) {
        self.id = id
        self.date = date
        self.text = text
        self.sourceApp = sourceApp
        self.bundleID = bundleID
    }
}

/// Append-only JSONL clipboard history at ~/Library/Application Support/Sotto/
/// clipboard/clipboard.jsonl — a SEPARATE subtree and file from voice history
/// (DESIGN.md separation-by-construction). Opt-in, on-device, zero network.
/// Bounded by a hard count cap (not a 30-day window): a plaintext log of
/// everything you copy is a bigger liability than your own dictations, so it stays
/// small. File is created 0600 and excluded from backup/Spotlight.
enum ClipboardHistoryStore {
    /// Hard cap on retained clips. Not user-configurable — keeps the secret-payload
    /// small and the settings surface minimal.
    static let maxCount = 50
    /// Skip anything longer than this (a giant paste shouldn't bloat the log).
    static let maxLength = 100_000

    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto", isDirectory: true)
            .appendingPathComponent("clipboard", isDirectory: true)
    }
    static var jsonlURL: URL { directoryURL.appendingPathComponent("clipboard.jsonl") }

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

    static func append(_ entry: ClipboardEntry) {
        guard let line = encode(entry) else { return }
        ensureDirectory()
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: jsonlURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write: create 0600 so only this user account can read the log,
            // and keep it out of Time Machine / Spotlight.
            FileManager.default.createFile(atPath: jsonlURL.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
            excludeFromBackup(jsonlURL)
        }
        enforceCap()
    }

    static func load() -> [ClipboardEntry] {
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return [] }
        return decode(jsonl: text)
    }

    static func encode(_ entry: ClipboardEntry) -> String? {
        guard let data = try? encoder.encode(entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pure: decode a JSONL blob, skipping malformed lines.
    static func decode(jsonl: String) -> [ClipboardEntry] {
        jsonl.split(separator: "\n").compactMap {
            try? decoder.decode(ClipboardEntry.self, from: Data($0.utf8))
        }
    }

    // MARK: Bounding

    /// Pure: keep only the newest `max` lines (append order == chronological).
    static func capLines(_ lines: [String], max: Int) -> [String] {
        guard max > 0, lines.count > max else { return lines }
        return Array(lines.suffix(max))
    }

    /// Trim the file to the newest `maxCount` lines. No-op unless it's over cap.
    static func enforceCap() {
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > maxCount else { return }
        let kept = capLines(lines, max: maxCount).joined(separator: "\n")
        try? (kept.isEmpty ? "" : kept + "\n").data(using: .utf8)?.write(to: jsonlURL, options: .atomic)
    }

    // MARK: Mutation (mirrors HistoryStore, preserving unparseable lines)

    private static func rewrite(_ transform: (ClipboardEntry) -> ClipboardEntry?) {
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return }
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if let entry = try? decoder.decode(ClipboardEntry.self, from: Data(s.utf8)) {
                if let mapped = transform(entry), let encoded = encode(mapped) { out.append(encoded) }
            } else {
                out.append(s)
            }
        }
        let joined = out.joined(separator: "\n")
        try? (joined.isEmpty ? "" : joined + "\n").data(using: .utf8)?.write(to: jsonlURL, options: .atomic)
    }

    static func delete(id: String) {
        rewrite { $0.id == id ? nil : $0 }
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: jsonlURL)
    }

    // MARK: Helpers

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        excludeFromBackup(directoryURL)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Shared registry that tells the clipboard-history monitor which NSPasteboard
/// `changeCount` values Sotto itself produced (its paste, its clipboard restore,
/// its copy-from-history) so the monitor never records Sotto's own writes as a
/// "user copy" — the self-paste loop guard.
///
/// Lock-backed and `Sendable` so the writers (OutputInjector, which is not actor-
/// isolated) and the MainActor monitor can share one instance without actor
/// friction. Bounded to the last `cap` stamps so it can never grow unbounded even
/// if a stamp is never matched by a poll (the critique's leak). Reads are one-shot.
final class ClipboardWriteGuard: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Int]())
    private let cap = 16

    /// Record a changeCount Sotto just produced (call right after each write).
    func markOwnWrite(changeCount: Int) {
        state.withLock { counts in
            counts.append(changeCount)
            if counts.count > cap { counts.removeFirst(counts.count - cap) }
        }
    }

    /// True (one-shot) if this changeCount was one of Sotto's own writes.
    func isOwnWrite(_ changeCount: Int) -> Bool {
        state.withLock { counts in
            guard let idx = counts.firstIndex(of: changeCount) else { return false }
            counts.remove(at: idx)
            return true
        }
    }
}
