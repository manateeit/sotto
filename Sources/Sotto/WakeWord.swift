import Foundation

/// Deterministic spoken wake-word detection (M6). Commands ride the NORMAL ⌥Space
/// dictation flow: after transcription + VocabularyRewriter, if the FIRST word of
/// the utterance is the wake word "Sotto" (accepting common STT mishearings), the
/// rest is routed to the command flow; otherwise the existing dictate/transform
/// pipeline runs byte-for-byte unchanged. The only cost added to the normal path
/// when no wake word is spoken is this one prefix check. Pure + unit-tested.
enum WakeWord {
    /// Fuzzy STT variants of "Sotto" accepted as the wake word. Deliberately loose:
    /// a false positive only ever leads to "Didn't catch a command" — never a wrong
    /// action, because every command still requires an explicit confirm re-tap. The
    /// set is intentionally small and oriented at plausible two-syllable mishearings
    /// of "Sotto"; keep universal, not per-user.
    // ponytail: hardcoded variant set. A settings-configurable wake word is a clear
    // upgrade path, but a fixed curated set is enough for v1 and keeps the check pure.
    static let variants: Set<String> = ["sotto", "soto", "sato", "sotta", "sodo"]

    /// The command utterance with the wake word + its separator stripped, or nil if
    /// the utterance doesn't begin with the wake word. Matches on the FIRST word
    /// only, case-insensitively, tolerating a single trailing comma/colon/period/etc.
    /// A bare wake word ("Sotto.") returns "" — the caller treats an empty command as
    /// "Didn't catch a command".
    static func command(in transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split off the first whitespace-delimited token.
        guard let breakIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else {
            // Whole utterance is a single word — is it the bare wake word?
            return normalizedIsWakeWord(String(trimmed)) ? "" : nil
        }
        let firstWord = String(trimmed[trimmed.startIndex..<breakIndex])
        guard normalizedIsWakeWord(firstWord) else { return nil }
        return String(trimmed[breakIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased word with trailing sentence punctuation stripped, tested against
    /// the variant set.
    private static func normalizedIsWakeWord(_ word: String) -> Bool {
        var w = word.lowercased()
        while let last = w.last, ",:.;!?".contains(last) {
            w.removeLast()
        }
        return variants.contains(w)
    }
}

/// Pure decision for what a ⌥Space key-down means given the lifecycle (M6). During a
/// pending command confirmation the SAME key confirms the command rather than
/// starting a new recording — this is the phase-machine branch the confirm UX needs.
enum HotkeyRouting {
    enum KeyDownAction: Equatable {
        /// Confirm the pending command (do NOT feed the dictation gesture).
        case confirmCommand
        /// Normal dictation gesture handling (start / stop / toggle).
        case gesture
    }

    static func keyDownAction(confirmingCommand: Bool) -> KeyDownAction {
        confirmingCommand ? .confirmCommand : .gesture
    }
}
