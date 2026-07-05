import Testing
@testable import Sotto

/// Pure dotted-version comparison — the only deterministic surface of the update
/// checker (network + NSAlert glue is hardware-verified, DESIGN.md working rules).
@Suite struct AppVersionTests {
    @Test func newerVersionWins() {
        #expect(AppVersion.isNewer("0.1.0", than: "0.0.1"))
        #expect(AppVersion.isNewer("1.0.0", than: "0.9.9"))
        #expect(AppVersion.isNewer("0.1.1", than: "0.1.0"))
    }

    @Test func olderVersionLoses() {
        #expect(!AppVersion.isNewer("0.0.1", than: "0.1.0"))
        #expect(!AppVersion.isNewer("0.9.9", than: "1.0.0"))
    }

    @Test func equalVersionsAreNotNewer() {
        #expect(!AppVersion.isNewer("0.1.0", than: "0.1.0"))
        #expect(!AppVersion.isNewer("v0.1.0", than: "0.1.0"))
    }

    @Test func leadingVIsStripped() {
        #expect(AppVersion.stripLeadingV("v0.1.0") == "0.1.0")
        #expect(AppVersion.stripLeadingV("V0.1.0") == "0.1.0")
        #expect(AppVersion.stripLeadingV("0.1.0") == "0.1.0")
    }

    @Test func missingTrailingComponentsCountAsZero() {
        #expect(AppVersion.compare("1.2", "1.2.0") == .orderedSame)
        #expect(AppVersion.isNewer("1.2.1", than: "1.2"))
    }

    @Test func malformedTagsDoNotCrashAndCompareAsZero() {
        #expect(AppVersion.compare("garbage", "0.0.0") == .orderedSame)
        #expect(!AppVersion.isNewer("not-a-version", than: "0.1.0"))
        #expect(AppVersion.isNewer("1.0.0", than: "garbage"))
    }
}
