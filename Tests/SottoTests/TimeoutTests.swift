import Foundation
import Testing
@testable import Sotto

/// The wall-clock timeout that keeps a slow model from blocking the paste. A fast
/// operation returns its value; a slow one throws so the caller can fall back to
/// the raw transcript.
@Suite struct TimeoutTests {
    @Test func fastOperationReturnsValue() async throws {
        let result = try await withTimeout(1.0) { 42 }
        #expect(result == 42)
    }

    @Test func slowOperationThrowsTimeout() async {
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(0.1) {
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3s, well past 0.1s
                return 0
            }
        }
    }
}
