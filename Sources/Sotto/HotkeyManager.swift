import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon `RegisterEventHotKey` — works system-wide with **no**
/// Input Monitoring permission (DESIGN.md §2, §4). M0 is toggle-only: each press
/// fires `onToggle`. Push-to-talk (down/up) is M1.
///
// ponytail: hardcoded ⌥+Space. M3 adds a settings hotkey recorder that
// re-registers on change; the Carbon plumbing here stays the same.
final class HotkeyManager {
    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x534F_5454 // 'SOTT'

    func register() {
        // Install the handler that Carbon calls when the hotkey fires.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
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

    fileprivate func fire() {
        onToggle?()
    }
}

/// C callback trampoline. Bounces to the main thread and into the owning manager.
private func hotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { manager.fire() }
    return noErr
}
