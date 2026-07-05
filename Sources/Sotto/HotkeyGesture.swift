import Foundation

/// Decides dictation intent from raw hotkey down/up events, supporting BOTH
/// push-to-talk and toggle on one key (DESIGN.md §5 M1):
///   • Hold the key (down, then up after `holdThreshold`) → push-to-talk: record
///     while held, stop on release.
///   • Tap the key (down/up quicker than `holdThreshold`) → toggle: first tap
///     starts, next tap stops.
///
/// Pure and deterministic: the caller passes the current recording state and a
/// monotonic timestamp, so this is unit-testable without the OS. The AppDelegate
/// owns the real recording state; this type only remembers what happened on the
/// press currently in progress.
struct HotkeyGesture {
    enum Intent: Equatable {
        case start
        case stop
        case none
    }

    /// Minimum key-hold to read as push-to-talk; anything shorter is a toggle tap.
    var holdThreshold: TimeInterval

    // ponytail: hardcoded 0.4s tap/hold cutoff. M3's settings can expose it, but a
    // single well-chosen constant is almost certainly all this ever needs.
    static let defaultHoldThreshold: TimeInterval = 0.4

    // ponytail: hardcoded 8s ceiling. Far beyond any intentional hold; a downTime
    // older than this means the key-up was dropped (sleep/wake, event hiccup), so
    // the next down is a fresh press, not auto-repeat. Guards against a wedged key.
    static let staleHoldCeiling: TimeInterval = 8

    private var downTime: TimeInterval?
    private var startedRecordingOnThisPress = false

    init(holdThreshold: TimeInterval = HotkeyGesture.defaultHoldThreshold) {
        self.holdThreshold = holdThreshold
    }

    /// - Parameter isRecording: whether a dictation is currently active.
    mutating func keyDown(at time: TimeInterval, isRecording: Bool) -> Intent {
        // Recover from a dropped key-up: a downTime older than any plausible hold
        // means the release was lost, so this is a fresh press, not auto-repeat.
        if let existing = downTime, time - existing > Self.staleHoldCeiling {
            downTime = nil
            startedRecordingOnThisPress = false
        }
        // Ignore auto-repeat: a second down with no intervening up is not a new
        // press, so it must not toggle a held push-to-talk off.
        if downTime != nil { return .none }
        downTime = time
        if isRecording {
            // Pressing again while recording is a toggle-off.
            startedRecordingOnThisPress = false
            return .stop
        } else {
            startedRecordingOnThisPress = true
            return .start
        }
    }

    /// - Parameter isRecording: whether a dictation is currently active.
    mutating func keyUp(at time: TimeInterval, isRecording: Bool) -> Intent {
        defer {
            downTime = nil
            startedRecordingOnThisPress = false
        }
        // Only a release that ended the press which *started* the current recording
        // can be a push-to-talk release.
        guard isRecording, startedRecordingOnThisPress, let downTime else { return .none }
        if time - downTime >= holdThreshold {
            return .stop // held → push-to-talk release
        }
        return .none // quick tap → stay recording in toggle mode
    }
}
