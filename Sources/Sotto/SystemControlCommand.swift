import CoreAudio
import Foundation

/// Tier-0 command: system volume up / down / mute / unmute (M6). Volume is driven
/// through CoreAudio's HAL (no deprecated AudioHardwareService, no AppleScript).
///
// ponytail: media play/pause is intentionally NOT in v1. The only routes are a
// synthetic NX_SYSDEFINED aux-key event or an IOKit HID consumer-usage post, both
// brittle and unverifiable off-hardware — exactly the kind of hack the brief says to
// skip. Add it behind this same command (a `.playPause` action) once there's a
// device to verify the HID post against.
struct SystemControlCommand: VoiceCommand {
    let id = "system"
    let trustTier = TrustTier.zero

    /// The system actions v1 supports.
    enum Action: String, Equatable, Sendable {
        case volumeUp
        case volumeDown
        case mute
        case unmute
    }

    /// One volume step per command (1/16 of the range).
    static let volumeStep: Float = 0.0625

    func summary(argument: String) -> String {
        switch Self.action(for: argument) {
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .unmute: return "Unmute"
        case nil: return argument // unsupported; run() throws a clear error
        }
    }

    // Tier 0, environment-independent — always offerable through the confirm pill.
    // An unsupported argument surfaces as a thrown error from run().
    func canRun(context: CommandContext) -> Bool { true }

    func run(argument: String) async throws {
        guard let action = Self.action(for: argument) else { throw CommandError.unsupported }
        switch action {
        case .volumeUp: try SystemVolume.adjust(by: Self.volumeStep)
        case .volumeDown: try SystemVolume.adjust(by: -Self.volumeStep)
        case .mute: try SystemVolume.setMuted(true)
        case .unmute: try SystemVolume.setMuted(false)
        }
    }

    // MARK: Argument mapping (pure)

    /// Map a normalized argument (or a natural phrase) to a supported action, or nil.
    /// Handles both the curated canonical strings and looser FM phrasings.
    nonisolated static func action(for argument: String) -> Action? {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "volume up", "volumeup", "louder", "up": return .volumeUp
        case "volume down", "volumedown", "quieter", "down": return .volumeDown
        case "mute", "mute volume", "volume mute": return .mute
        case "unmute", "unmute volume", "volume unmute": return .unmute
        default: return nil
        }
    }

    /// The curated pre-pass entry: whole universal volume phrases → the canonical
    /// argument string. Only unambiguous phrases; anything else falls to the FM.
    nonisolated static func curatedAction(for utterance: String) -> String? {
        switch utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "volume up", "louder", "turn it up", "turn up the volume", "turn the volume up":
            return "volume up"
        case "volume down", "quieter", "turn it down", "turn down the volume", "turn the volume down":
            return "volume down"
        case "mute", "mute volume", "volume mute", "mute the volume", "mute sound", "mute audio":
            return "mute"
        case "unmute", "unmute volume", "volume unmute", "unmute the volume", "unmute sound", "unmute audio":
            return "unmute"
        default:
            return nil
        }
    }
}

/// Default-output-device volume via the CoreAudio HAL. Non-deprecated
/// AudioObject* API; thread-safe, so callable from the main actor.
enum SystemVolume {
    struct Unavailable: Error {}

    /// Pure: clamp a proposed level to 0...1. Unit-tested.
    static func stepped(current: Float, by delta: Float) -> Float {
        min(1, max(0, current + delta))
    }

    static func adjust(by delta: Float) throws {
        let device = try defaultOutputDevice()
        let current = try currentVolume(device: device)
        try setVolume(stepped(current: current, by: delta), device: device)
    }

    static func setMuted(_ muted: Bool) throws {
        let device = try defaultOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { throw Unavailable() }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            throw Unavailable()
        }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw Unavailable() }
    }

    // MARK: CoreAudio plumbing

    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { throw Unavailable() }
        return deviceID
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    private static func currentVolume(device: AudioDeviceID) throws -> Float {
        // Prefer the device's main-element volume; fall back to channel 1.
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var address = volumeAddress(element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var volume = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        throw Unavailable()
    }

    private static func setVolume(_ value: Float, device: AudioDeviceID) throws {
        let clamped = min(1, max(0, value))
        var didSet = false
        // Main element first (covers all channels); else set each stereo channel.
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for element in elements {
            var address = volumeAddress(element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
                continue
            }
            var v = clamped
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &v) == noErr {
                didSet = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        guard didSet else { throw Unavailable() }
    }
}
