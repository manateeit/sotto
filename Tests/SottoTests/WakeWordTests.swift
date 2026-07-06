import Testing
@testable import Sotto

/// The wake-word prefix check is the ONLY added cost on the normal dictation path,
/// so it's covered exhaustively here: variants, first-word-only matching, separator
/// stripping, and the pure hotkey-routing branch the confirm UX depends on.
@Suite struct WakeWordTests {
    // MARK: Detection + strip

    @Test func plainWakeWordStripsToCommand() {
        #expect(WakeWord.command(in: "Sotto open Safari") == "open Safari")
    }

    @Test func commaSeparatorIsStripped() {
        #expect(WakeWord.command(in: "Sotto, open Safari") == "open Safari")
    }

    @Test func colonSeparatorIsStripped() {
        #expect(WakeWord.command(in: "Sotto: run npm test") == "run npm test")
    }

    @Test func fuzzySTTVariantsMatch() {
        #expect(WakeWord.command(in: "soto open Safari") == "open Safari")
        #expect(WakeWord.command(in: "Sato, mute") == "mute")
        #expect(WakeWord.command(in: "SOTTO type hello") == "type hello")
        #expect(WakeWord.command(in: "sotta volume up") == "volume up")
    }

    @Test func matchesFirstWordOnly() {
        // A "sotto" anywhere but the first word is NOT a wake word — normal dictation.
        #expect(WakeWord.command(in: "please tell sotto to stop") == nil)
        #expect(WakeWord.command(in: "the word sotto means quietly") == nil)
    }

    @Test func nonWakeWordIsDictation() {
        #expect(WakeWord.command(in: "open the door") == nil)
        #expect(WakeWord.command(in: "the plan is ready") == nil)
    }

    @Test func bareWakeWordYieldsEmptyCommand() {
        // "" ⇒ the caller resolves to "Didn't catch a command".
        #expect(WakeWord.command(in: "Sotto.") == "")
        #expect(WakeWord.command(in: "sotto") == "")
    }

    @Test func emptyOrWhitespaceIsNil() {
        #expect(WakeWord.command(in: "   ") == nil)
        #expect(WakeWord.command(in: "") == nil)
    }

    @Test func leadingWhitespaceTolerated() {
        #expect(WakeWord.command(in: "  Sotto open Notes") == "open Notes")
    }

    // MARK: Hotkey routing (confirm phase branch)

    @Test func confirmingPhaseRoutesKeyDownToConfirm() {
        #expect(HotkeyRouting.keyDownAction(confirmingCommand: true) == .confirmCommand)
    }

    @Test func normalPhaseRoutesKeyDownToGesture() {
        #expect(HotkeyRouting.keyDownAction(confirmingCommand: false) == .gesture)
    }
}
