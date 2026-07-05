import Foundation

struct TimeoutError: Error, CustomStringConvertible {
    var description: String { "operation exceeded its time budget" }
}

/// Runs `operation`, throwing `TimeoutError` if it doesn't finish within
/// `seconds`. Used to keep a slow Foundation Models pass from blocking the paste
/// (DESIGN.md §3) — on timeout the caller falls back to the raw transcript.
///
// ponytail: cancelling the losing task cancels the Swift Task, but that may not
// actually halt the FoundationModels inference running underneath — the model
// could keep computing until it finishes on its own. Unverifiable off-hardware;
// watch on the 20-dictation hardware run that a timed-out call doesn't wedge a
// later one. If it does, the fix is a session/inference cancel, not just Task cancel.
func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        // First task to finish wins; the other is cancelled by the defer.
        guard let result = try await group.next() else { throw TimeoutError() }
        return result
    }
}
