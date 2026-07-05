import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon `RegisterEventHotKey` — works system-wide with **no**
/// Input Monitoring permission (DESIGN.md §2, §4).
///
/// Delivers the key's down *and* up so the caller can distinguish push-to-talk
/// from toggle (M1). Esc-to-cancel is handled separately in AppDelegate via a
/// passive `NSEvent` global monitor, so we don't register Esc as a hotkey (which
/// would swallow it from every other app).
///
// ponytail: hardcoded ⌥+Space. M3 adds a settings hotkey recorder that
// re-registers on change; the Carbon plumbing here stays the same.
final class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x534F_5454 // 'SOTT'

    func register() {
        // Handle both key-down and key-up for the hotkey.
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            specs.count,
            &specs,
            selfPtr,
            &handlerRef
        )
        if installStatus != noErr {
            NSLog("Sotto: InstallEventHandler failed with status \(installStatus); hotkey will not fire.")
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            NSLog("Sotto: RegisterEventHotKey failed with status \(registerStatus); ⌥Space may be taken by another app.")
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    fileprivate func handle(kind: UInt32) {
        if kind == UInt32(kEventHotKeyPressed) {
            onKeyDown?()
        } else if kind == UInt32(kEventHotKeyReleased) {
            onKeyUp?()
        }
    }
}

/// C callback trampoline. Reads whether the event was a press or a release, then
/// bounces to the main thread.
private func hotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    let kind = GetEventKind(event)
    // Pass the manager's address as a Sendable integer and reconstruct it inside the
    // main-queue closure, rather than sending the non-Sendable pointer/instance.
    let address = UInt(bitPattern: userData)
    DispatchQueue.main.async {
        guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(raw).takeUnretainedValue()
        manager.handle(kind: kind)
    }
    return noErr
}
