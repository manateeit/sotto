import Foundation
import Testing
@testable import Sotto

/// Pure JSONL encode/decode and retention logic for the open history store.
@Suite struct HistoryStoreTests {
    private func entry(id: String = "x", daysAgo: Double = 0, now: Date = Date()) -> HistoryEntry {
        HistoryEntry(id: id, date: now.addingTimeInterval(-daysAgo * 86_400),
                     rawTranscript: "hi there", finalOutput: "Hi there.", route: "dictate",
                     app: "TextEdit", bundleID: "com.apple.TextEdit",
                     durationSeconds: 3.2, engineID: "SpeechAnalyzer", audioFile: "\(id).wav")
    }

    @Test func encodeDecodeRoundTrip() {
        let original = HistoryEntry(id: "abc", date: Date(timeIntervalSince1970: 1000),
                                    rawTranscript: "hello world", finalOutput: "Hello world.",
                                    route: "raw", app: "Notes", bundleID: "com.apple.Notes",
                                    durationSeconds: 4.5, engineID: "SpeechAnalyzer", audioFile: nil)
        let line = HistoryStore.encode(original)!
        let decoded = HistoryStore.decode(jsonl: line)
        #expect(decoded.count == 1)
        #expect(decoded[0].id == "abc")
        #expect(decoded[0].rawTranscript == "hello world")
        #expect(decoded[0].finalOutput == "Hello world.")
        #expect(decoded[0].route == "raw")
        #expect(decoded[0].bundleID == "com.apple.Notes")
        #expect(decoded[0].durationSeconds == 4.5)
        #expect(decoded[0].audioFile == nil)
    }

    @Test func decodeSkipsMalformedLines() {
        let good = HistoryStore.encode(entry(id: "g"))!
        let jsonl = good + "\nnot json\n{bad}\n"
        #expect(HistoryStore.decode(jsonl: jsonl).count == 1)
    }

    @Test func retentionZeroKeepsEverything() {
        let now = Date()
        #expect(HistoryStore.isExpired(entry(daysAgo: 1000, now: now), retentionDays: 0, now: now) == false)
    }

    @Test func retentionExpiresOnlyOldEntries() {
        let now = Date()
        #expect(HistoryStore.isExpired(entry(daysAgo: 40, now: now), retentionDays: 30, now: now) == true)
        #expect(HistoryStore.isExpired(entry(daysAgo: 10, now: now), retentionDays: 30, now: now) == false)
    }

    @Test func partitionSplitsByRetention() {
        let now = Date()
        let entries = [entry(id: "old", daysAgo: 40, now: now), entry(id: "new", daysAgo: 5, now: now)]
        let (kept, expired) = HistoryStore.partition(entries, retentionDays: 30, now: now)
        #expect(kept.map(\.id) == ["new"])
        #expect(expired.map(\.id) == ["old"])
    }

    @Test func pruneKeepsUnparseableLinesByteIntact() {
        let now = Date()
        let old = HistoryStore.encode(entry(id: "old", daysAgo: 40, now: now))!
        let fresh = HistoryStore.encode(entry(id: "new", daysAgo: 1, now: now))!
        let garbage = "{ this is not valid json"
        let (kept, expired) = HistoryStore.pruneLines([old, garbage, fresh], retentionDays: 30, now: now)
        #expect(kept.contains(garbage)) // unparseable preserved, never destroyed
        #expect(kept.contains(fresh))   // unexpired kept
        #expect(!kept.contains(old))    // parsed + expired dropped
        #expect(expired.map(\.id) == ["old"])
    }
}
