import AppKit
import Carbon.HIToolbox

/// Pure conversions between AppKit modifier flags, Carbon modifier masks, and a
/// human-readable shortcut string. Kept separate so it can be unit-tested.
enum HotkeyFormatter {
    /// AppKit modifier flags → Carbon modifier mask (what RegisterEventHotKey wants).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.shift) { mask |= shiftKey }
        return mask
    }

    /// A readable shortcut like "⌥Space" or "⌘⇧D".
    static func displayString(keyCode: Int, modifiers: Int) -> String {
        var prefix = ""
        if modifiers & controlKey != 0 { prefix += "⌃" }
        if modifiers & optionKey != 0 { prefix += "⌥" }
        if modifiers & shiftKey != 0 { prefix += "⇧" }
        if modifiers & cmdKey != 0 { prefix += "⌘" }
        return prefix + keyName(keyCode)
    }

    /// A minimal key-code → name map for the keys people actually bind. Unknown
    /// codes fall back to a numeric label rather than guessing.
    static func keyName(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_Z: return "Z"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F5: return "F5"
        default: return "Key \(keyCode)"
        }
    }
}
