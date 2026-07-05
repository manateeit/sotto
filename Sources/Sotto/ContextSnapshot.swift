import AppKit
import ApplicationServices
import Foundation

/// Context captured around a dictation (DESIGN.md §2). The cheap pieces (app,
/// bundle id, date) are captured synchronously at record start; the Accessibility
/// pieces (selection, window title, focused-field text) are captured OFF the main
/// thread with a timeout and merged in when ready, so a busy frontmost app can
/// never freeze record-start. `clipboard` is filled at stop. Any field may be nil.
struct ContextSnapshot: Sendable {
    var selectedText: String?
    var frontmostApp: String?
    var bundleID: String?
    var windowTitle: String?
    var focusedFieldText: String?
    var clipboard: String?
    var date: Date

    init(selectedText: String? = nil,
         frontmostApp: String? = nil,
         bundleID: String? = nil,
         windowTitle: String? = nil,
         focusedFieldText: String? = nil,
         clipboard: String? = nil,
         date: Date = Date()) {
        self.selectedText = selectedText
        self.frontmostApp = frontmostApp
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.focusedFieldText = focusedFieldText
        self.clipboard = clipboard
        self.date = date
    }

    /// Cheap, main-thread-safe pieces captured synchronously at record start. No AX
    /// element queries — those go through `AccessibilityContext` off the main thread.
    @MainActor
    static func captureImmediate() -> ContextSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        return ContextSnapshot(
            frontmostApp: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            date: Date()
        )
    }

    /// Merge the (later-resolved) Accessibility pieces in.
    mutating func merge(_ accessibility: AccessibilityContext) {
        selectedText = accessibility.selectedText
        windowTitle = accessibility.windowTitle
        focusedFieldText = accessibility.focusedFieldText
    }
}

/// The Accessibility-derived context. Captured off the main thread with a hard
/// timeout — cross-process `AXUIElementCopyAttributeValue` calls can block on a
/// busy app, and record-start must never wait on them.
struct AccessibilityContext: Sendable {
    var selectedText: String?
    var windowTitle: String?
    var focusedFieldText: String?

    // ponytail: fixed 800-char cap on borrowed focused-field text.
    static let maxFieldTextLength = 800

    /// Read AX off the main thread, bounded by `timeout`. Returns empty on timeout
    /// or when the app isn't Accessibility-trusted.
    static func capture(timeout: TimeInterval) async -> AccessibilityContext {
        let result = try? await withTimeout(timeout) {
            await Task.detached(priority: .userInitiated) { read() }.value
        }
        return result ?? AccessibilityContext()
    }

    /// Synchronous cross-process AX reads — safe to call off the main thread.
    static func read() -> AccessibilityContext {
        guard AXIsProcessTrusted() else { return AccessibilityContext() }
        guard let element = copyElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString) else {
            return AccessibilityContext()
        }
        return AccessibilityContext(
            selectedText: copyString(element, kAXSelectedTextAttribute as CFString),
            windowTitle: windowTitle(of: element),
            focusedFieldText: fieldText(of: element)
        )
    }

    private static func windowTitle(of element: AXUIElement) -> String? {
        guard let window = copyElement(element, kAXWindowAttribute as CFString) else { return nil }
        return copyString(window, kAXTitleAttribute as CFString)
    }

    private static func fieldText(of element: AXUIElement) -> String? {
        guard let value = copyString(element, kAXValueAttribute as CFString) else { return nil }
        return String(value.prefix(maxFieldTextLength))
    }

    private static func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let raw = ref,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }
}

/// Tracks how recently the clipboard changed so ContextSnapshot can apply the
/// "changed ≤3s before start or during recording" rule (DESIGN.md §2). Polls
/// `changeCount` on a light timer and timestamps changes it observes.
@MainActor
final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    /// Uptime of the last observed change; sentinel 0 (far before any real uptime)
    /// means "not changed while we were watching".
    private var lastChangeAt: TimeInterval = 0
    private var timer: Timer?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        lastChangeAt = ProcessInfo.processInfo.systemUptime
    }

    /// Clipboard string if it last changed at or after `sinceUptime`, else nil.
    /// Callers pass (recordStart − window) so both a just-before-start copy and a
    /// during-recording copy qualify.
    func textChanged(since sinceUptime: TimeInterval) -> String? {
        guard ClipboardMonitor.changed(lastChangeAt: lastChangeAt, since: sinceUptime) else { return nil }
        return pasteboard.string(forType: .string)
    }

    /// Pure predicate (unit-tested).
    nonisolated static func changed(lastChangeAt: TimeInterval, since: TimeInterval) -> Bool {
        lastChangeAt >= since
    }
}
