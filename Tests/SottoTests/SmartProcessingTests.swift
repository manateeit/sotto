import Testing
@testable import Sotto

/// Deterministic scaffolding around the (non-deterministic, hardware-only)
/// Foundation Models calls: the raw/smart routing, the transform-gate guard, and
/// the clipboard recency rule. The model's actual output quality is verified on
/// hardware, not here.
@Suite struct SmartProcessingTests {
    // MARK: Route policy

    @Test func shiftHeldForcesRaw() {
        let policy = ProcessingPolicy(rawLengthCap: 1200)
        #expect(policy.route(shiftHeld: true, smartAvailable: true, textLength: 10) == .raw)
    }

    @Test func unavailableModelForcesRaw() {
        let policy = ProcessingPolicy(rawLengthCap: 1200)
        #expect(policy.route(shiftHeld: false, smartAvailable: false, textLength: 10) == .raw)
    }

    @Test func overLengthCapForcesRaw() {
        let policy = ProcessingPolicy(rawLengthCap: 1200)
        #expect(policy.route(shiftHeld: false, smartAvailable: true, textLength: 5000) == .raw)
    }

    @Test func normalDictationGoesSmart() {
        let policy = ProcessingPolicy(rawLengthCap: 1200)
        #expect(policy.route(shiftHeld: false, smartAvailable: true, textLength: 40) == .smart)
    }

    // MARK: Transform gate guard

    @Test func noSelectionCannotTransform() {
        #expect(SmartProcessor.canTransform(context: ContextSnapshot()) == false)
    }

    @Test func whitespaceSelectionCannotTransform() {
        #expect(SmartProcessor.canTransform(context: ContextSnapshot(selectedText: "   \n")) == false)
    }

    @Test func realSelectionCanTransform() {
        #expect(SmartProcessor.canTransform(context: ContextSnapshot(selectedText: "some text")) == true)
    }

    // MARK: Clipboard recency rule (changed since [recordStart − window])

    @Test func clipboardChangedJustBeforeStartCounts() {
        // start=100, window=3 → threshold 97; a copy at 99 (1s before start) counts.
        #expect(ClipboardMonitor.changed(lastChangeAt: 99, since: 97) == true)
    }

    @Test func clipboardChangedDuringRecordingCounts() {
        // a copy at 105 (during recording) is ≥ threshold 97.
        #expect(ClipboardMonitor.changed(lastChangeAt: 105, since: 97) == true)
    }

    @Test func clipboardChangedLongBeforeStartDoesNotCount() {
        // a copy at 92 (8s before start) is before threshold 97.
        #expect(ClipboardMonitor.changed(lastChangeAt: 92, since: 97) == false)
    }

    @Test func clipboardNeverChangedDoesNotCount() {
        // Sentinel lastChangeAt of 0 against a real uptime threshold.
        #expect(ClipboardMonitor.changed(lastChangeAt: 0, since: 499_997) == false)
    }
}
