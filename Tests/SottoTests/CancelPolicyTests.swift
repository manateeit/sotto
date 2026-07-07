import Foundation
import Testing
@testable import Sotto

/// The time-gated discard rule: short recordings discard instantly, long ones
/// need a confirming second (armed) Esc.
@Suite struct CancelPolicyTests {
    private let threshold: TimeInterval = 30

    @Test func shortRecordingDiscardsImmediately() {
        #expect(CancelPolicy.discardsImmediately(elapsed: 5, armed: false, threshold: threshold))
    }

    @Test func longRecordingRequiresConfirm() {
        #expect(!CancelPolicy.discardsImmediately(elapsed: 45, armed: false, threshold: threshold))
    }

    @Test func armedLongRecordingDiscards() {
        // Second Esc (armed) confirms the discard even past the threshold.
        #expect(CancelPolicy.discardsImmediately(elapsed: 45, armed: true, threshold: threshold))
    }

    @Test func boundaryIsExclusive() {
        // Exactly at the threshold is treated as "long" (needs confirm).
        #expect(!CancelPolicy.discardsImmediately(elapsed: 30, armed: false, threshold: threshold))
        #expect(CancelPolicy.discardsImmediately(elapsed: 29.999, armed: false, threshold: threshold))
    }
}
