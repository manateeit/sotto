import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// A deep copy of a pasteboard's contents (types + raw data per item), used to
/// restore the user's clipboard after we borrow it for a paste. Works against any
/// `NSPasteboard`, so it is unit-testable against a private named pasteboard
/// without touching the real system clipboard.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var typed: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typed[type] = data
                }
            }
            if !typed.isEmpty { saved.append(typed) }
        }
        return PasteboardSnapshot(items: saved)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        var restored: [NSPasteboardItem] = []
        for typed in items {
            let item = NSPasteboardItem()
            for (type, data) in typed {
                item.setData(data, forType: type)
            }
            restored.append(item)
        }
        pasteboard.writeObjects(restored)
    }
}

/// Injects text into the frontmost app. M0 strategy: save the clipboard, set our
/// text, synthesize ⌘V via CGEvent, then restore the clipboard shortly after.
/// AX `setValue` insertion is M-later (DESIGN.md §2 fallback chain).
///
/// Refuses when secure input is active: we leave the text on the clipboard for the
/// user to paste manually and report it, rather than silently dropping it.
final class OutputInjector {
    enum Result {
        case pasted
        case refusedSecureInput
        case refusedNoAccessibility
        case empty
    }

    /// Restore delay: long enough for the target app to service the synthetic ⌘V
    /// before we put the old clipboard back.
    private let restoreDelay: TimeInterval = 0.35

    /// The scheduled clipboard restore, if one is pending. Cancelled and replaced
    /// whenever a new injection begins. Main-thread confined.
    private var pendingRestore: DispatchWorkItem?

    @discardableResult
    func inject(_ text: String) -> Result {
        guard !text.isEmpty else { return .empty }

        let pasteboard = NSPasteboard.general

        // A new injection supersedes any restore still pending from a previous one,
        // so an earlier dictation's stale snapshot can't stomp this one's paste.
        pendingRestore?.cancel()
        pendingRestore = nil

        if IsSecureEventInputEnabled() {
            // Secure input (e.g. a password field) blocks synthetic key events.
            // Leave the transcript on the clipboard and let the caller notify.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .refusedSecureInput
        }

        if !AXIsProcessTrusted() {
            // Accessibility not granted / revoked → a synthetic ⌘V won't be
            // delivered. Leave the transcript on the clipboard rather than losing it.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .refusedNoAccessibility
        }

        let snapshot = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writtenChangeCount = pasteboard.changeCount

        synthesizeCommandV()

        let restore = DispatchWorkItem { [weak self] in
            // Only restore if the user hasn't copied something new in the meantime —
            // otherwise we'd clobber their fresh clipboard.
            if Self.shouldRestore(writtenChangeCount: writtenChangeCount, currentChangeCount: pasteboard.changeCount) {
                snapshot.restore(to: pasteboard)
            }
            self?.pendingRestore = nil
        }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: restore)
        return .pasted
    }

    /// Restore the prior clipboard only if nothing has changed it since we wrote the
    /// transcript. Pure decision logic, unit-tested.
    static func shouldRestore(writtenChangeCount: Int, currentChangeCount: Int) -> Bool {
        writtenChangeCount == currentChangeCount
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // 'V'
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
