import Testing
@testable import Sotto

/// The tap-vs-hold decision is the one piece of M1 logic worth isolating: it
/// decides push-to-talk vs toggle from raw key events and must never emit a
/// spurious start/stop. Pure, so it runs without the OS.
@Suite struct HotkeyGestureTests {
    private let threshold = HotkeyGesture.defaultHoldThreshold // 0.4s

    @Test func quickTapStartsThenNextTapStops() {
        var g = HotkeyGesture(holdThreshold: threshold)
        #expect(g.keyDown(at: 0.00, isRecording: false) == .start)
        // Released quickly → stays recording (toggle mode).
        #expect(g.keyUp(at: 0.05, isRecording: true) == HotkeyGesture.Intent.none)
        // A later tap toggles off.
        #expect(g.keyDown(at: 2.00, isRecording: true) == .stop)
        #expect(g.keyUp(at: 2.05, isRecording: false) == HotkeyGesture.Intent.none)
    }

    @Test func holdIsPushToTalk() {
        var g = HotkeyGesture(holdThreshold: threshold)
        #expect(g.keyDown(at: 0.00, isRecording: false) == .start)
        // Held past the threshold, then released → stop.
        #expect(g.keyUp(at: 0.60, isRecording: true) == .stop)
    }

    @Test func holdUnderThresholdStaysToggle() {
        var g = HotkeyGesture(holdThreshold: threshold)
        #expect(g.keyDown(at: 0.00, isRecording: false) == .start)
        #expect(g.keyUp(at: 0.20, isRecording: true) == HotkeyGesture.Intent.none)
    }

    @Test func autoRepeatDownDuringHoldIsIgnored() {
        var g = HotkeyGesture(holdThreshold: threshold)
        #expect(g.keyDown(at: 0.00, isRecording: false) == .start)
        // A repeated key-down while still held (no release yet) must be ignored,
        // otherwise a held push-to-talk would stop itself.
        #expect(g.keyDown(at: 0.10, isRecording: true) == HotkeyGesture.Intent.none)
        #expect(g.keyUp(at: 0.60, isRecording: true) == .stop)
    }

    @Test func droppedKeyUpRecoversOnNextDown() {
        var g = HotkeyGesture(holdThreshold: threshold)
        _ = g.keyDown(at: 0.0, isRecording: false) // start; key-up never arrives
        // A down well past the stale ceiling must be treated as a fresh press, not
        // eaten as auto-repeat — otherwise the hotkey wedges permanently.
        #expect(g.keyDown(at: 20.0, isRecording: true) == .stop)  // fresh press, recording → toggle off
        #expect(g.keyDown(at: 40.0, isRecording: false) == .start) // fresh press, idle → start
    }

    @Test func releaseAfterToggleStopDoesNotStopAgain() {
        var g = HotkeyGesture(holdThreshold: threshold)
        _ = g.keyDown(at: 0.00, isRecording: false) // start (toggle)
        _ = g.keyUp(at: 0.05, isRecording: true)    // stays recording
        #expect(g.keyDown(at: 1.00, isRecording: true) == .stop) // toggle off
        // Even though this release is "long", recording already stopped, so no
        // second stop is emitted.
        #expect(g.keyUp(at: 1.40, isRecording: false) == HotkeyGesture.Intent.none)
    }
}
