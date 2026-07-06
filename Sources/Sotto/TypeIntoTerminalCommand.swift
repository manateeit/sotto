import Foundation

/// Tier-1 command: paste the argument into the frontmost terminal via the existing
/// OutputInjector (⌘V) — and NEVER send Return (M6). The human pressing Return is
/// the execution gate: Sotto only ever stages the command text; nothing runs until
/// the person at the keyboard runs it. `canRun` requires the frontmost app to be a
/// known terminal, so command text is never pasted into an editor, chat, or shell
/// prompt the user didn't intend.
struct TypeIntoTerminalCommand: VoiceCommand {
    let id = "terminal"
    let trustTier = TrustTier.one

    /// Bundle ids treated as terminals (the paste target allowlist). A closed set:
    /// pasting shell text into a non-terminal is exactly what we must not do.
    nonisolated static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.microsoft.VSCode",
    ]

    private let injector: any PasteInjecting

    init(injector: any PasteInjecting) {
        self.injector = injector
    }

    func summary(argument: String) -> String { "⏎ Terminal: \(Self.sanitizedForTerminal(argument))" }

    func canRun(context: CommandContext) -> Bool {
        Self.isTerminal(context.frontmostBundleID)
    }

    func run(argument: String) async throws {
        // Stage the text only — ⌘V, never Return. But "never synthesize Return" is
        // not enough: an embedded newline in the argument is submitted by the shell
        // ON PASTE (the first line would execute before any human Return). So collapse
        // all line breaks to spaces first — one code path covers curated and
        // FM-parsed arguments, and `summary` shows the same sanitized text, so the
        // confirm pill is exactly what lands. Refusals (secure input, no
        // Accessibility) come back as non-`.pasted`; surface them as an error.
        switch injector.inject(Self.sanitizedForTerminal(argument)) {
        case .pasted:
            break
        case .refusedSecureInput, .refusedNoAccessibility, .empty:
            throw CommandError.injectionRefused
        }
    }

    /// Pure allowlist predicate — unit-tested.
    nonisolated static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    /// Collapse every line break (CRLF, LF, CR, and the Unicode line/paragraph
    /// separators) to a single space, then trim. This is the load-bearing safety
    /// step: it guarantees the pasted text is one line, so the human's Return remains
    /// the only thing that submits it. Pure — unit-tested.
    nonisolated static func sanitizedForTerminal(_ argument: String) -> String {
        // Work on Unicode scalars, not Characters: Swift treats "\r\n" as a single
        // grapheme cluster, so a Character-level check would miss CRLF. As scalars,
        // CR and LF are separate and both matched; the run-dedup collapses CRLF to one
        // space.
        let lineBreaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}"]
        let space: Unicode.Scalar = " "
        var result = String.UnicodeScalarView()
        var lastWasBreak = false
        for scalar in argument.unicodeScalars {
            if lineBreaks.contains(scalar) {
                if !lastWasBreak { result.append(space) } // runs (incl. CRLF) → one space
                lastWasBreak = true
            } else {
                result.append(scalar)
                lastWasBreak = false
            }
        }
        return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Seam for pasting text into the frontmost app, so the terminal command's
/// injection is assertable in tests without touching the real pasteboard. The
/// production conformer is `OutputInjector`.
protocol PasteInjecting {
    @discardableResult func inject(_ text: String) -> OutputInjector.Result
}

extension OutputInjector: PasteInjecting {}
