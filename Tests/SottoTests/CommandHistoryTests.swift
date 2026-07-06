import Testing
@testable import Sotto

/// An executed voice command is recorded to the same open JSONL history with route
/// "command" (DESIGN.md §3 / M6). This exercises the pure encode/decode path — the
/// AppDelegate only appends after a command actually runs, never on cancel/timeout.
@Suite struct CommandHistoryTests {
    @Test func commandRouteRoundTrips() {
        let entry = HistoryEntry(
            rawTranscript: "Sotto, run npm test",
            finalOutput: "⏎ Terminal: npm test",
            route: "command",
            app: "iTerm2",
            bundleID: "com.googlecode.iterm2",
            durationSeconds: 2.0,
            engineID: "SpeechAnalyzer",
            audioFile: nil
        )
        let line = HistoryStore.encode(entry)
        #expect(line != nil)
        let decoded = HistoryStore.decode(jsonl: line ?? "")
        #expect(decoded.count == 1)
        #expect(decoded.first?.route == "command")
        #expect(decoded.first?.rawTranscript == "Sotto, run npm test")
        #expect(decoded.first?.finalOutput == "⏎ Terminal: npm test")
    }
}
