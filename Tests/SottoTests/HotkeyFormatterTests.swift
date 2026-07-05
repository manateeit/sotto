import AppKit
import Carbon.HIToolbox
import Testing
@testable import Sotto

/// Pure hotkey display + modifier conversion (used by the settings recorder).
@Suite struct HotkeyFormatterTests {
    @Test func defaultShortcutRendersAsOptionSpace() {
        #expect(HotkeyFormatter.displayString(keyCode: kVK_Space, modifiers: Int(optionKey)) == "⌥Space")
    }

    @Test func modifiersRenderInStableOrder() {
        let mods = Int(cmdKey | shiftKey)
        #expect(HotkeyFormatter.displayString(keyCode: kVK_ANSI_D, modifiers: mods) == "⇧⌘D")
    }

    @Test func carbonModifiersFromAppKitFlags() {
        let mods = HotkeyFormatter.carbonModifiers(from: [.option, .command])
        #expect(mods & optionKey != 0)
        #expect(mods & cmdKey != 0)
        #expect(mods & shiftKey == 0)
    }

    @Test func unknownKeyFallsBackToNumericLabel() {
        #expect(HotkeyFormatter.keyName(999) == "Key 999")
    }
}
