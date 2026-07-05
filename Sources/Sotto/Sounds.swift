import AppKit

/// Short feedback cues for the dictation lifecycle. Uses the built-in macOS system
/// sounds so there are no bundled audio assets to ship in M1.
///
// ponytail: `enabled` is hardcoded true for M1; M3's settings window wires it to a
// UserDefaults toggle.
final class Sounds {
    enum Cue {
        case start
        case stop
        case cancel
    }

    var enabled = true

    func play(_ cue: Cue) {
        guard enabled else { return }
        let name: String
        switch cue {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .cancel: name = "Funk"
        }
        NSSound(named: name)?.play()
    }
}
