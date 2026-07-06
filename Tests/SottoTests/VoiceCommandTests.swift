import Foundation
import Testing
@testable import Sotto

/// Deterministic scaffolding around the three voice commands: the terminal
/// allowlist, open-target resolution, system-action mapping, the volume step, and
/// the registry wiring. The actual side effects (launching apps, ⌘V, CoreAudio) are
/// verified on hardware, not here.
@Suite struct VoiceCommandTests {
    // MARK: Terminal allowlist (Tier 1 gate)

    @Test func terminalAllowlistAcceptsKnownTerminals() {
        #expect(TypeIntoTerminalCommand.isTerminal("com.apple.Terminal"))
        #expect(TypeIntoTerminalCommand.isTerminal("com.googlecode.iterm2"))
        #expect(TypeIntoTerminalCommand.isTerminal("com.mitchellh.ghostty"))
        #expect(TypeIntoTerminalCommand.isTerminal("com.microsoft.VSCode"))
    }

    @Test func terminalAllowlistRejectsOthers() {
        #expect(!TypeIntoTerminalCommand.isTerminal("com.apple.Safari"))
        #expect(!TypeIntoTerminalCommand.isTerminal("com.tinyspeck.slackmacgap"))
        #expect(!TypeIntoTerminalCommand.isTerminal(nil))
    }

    // MARK: Open-target resolution (pure over an injected app map)

    @Test func httpsURLResolvesToURL() {
        #expect(OpenTargetCommand.resolve(argument: "https://example.com", installedApps: [:])
            == .openURL(URL(string: "https://example.com")!))
    }

    @Test func httpURLIsRefusedHTTPSOnly() {
        #expect(OpenTargetCommand.resolve(argument: "http://example.com", installedApps: [:]) == .notFound)
    }

    @Test func exactAppNameResolvesToApp() {
        let url = URL(fileURLWithPath: "/Applications/Safari.app")
        #expect(OpenTargetCommand.resolve(argument: "Safari", installedApps: ["safari": url]) == .launchApp(url))
    }

    @Test func uniqueSubstringResolvesToApp() {
        let url = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        #expect(OpenTargetCommand.resolve(argument: "chrome", installedApps: ["google chrome": url]) == .launchApp(url))
    }

    @Test func ambiguousSubstringDoesNotResolve() {
        let notes = URL(fileURLWithPath: "/Applications/Notes.app")
        let notability = URL(fileURLWithPath: "/Applications/Notability.app")
        #expect(OpenTargetCommand.resolve(argument: "not", installedApps: ["notes": notes, "notability": notability])
            == .notFound)
    }

    @Test func bareDomainUpgradesToHTTPS() {
        #expect(OpenTargetCommand.resolve(argument: "github.com", installedApps: [:])
            == .openURL(URL(string: "https://github.com")!))
    }

    @Test func unknownArgumentIsNotFound() {
        #expect(OpenTargetCommand.resolve(argument: "the door", installedApps: [:]) == .notFound)
    }

    @Test func looksLikeDomainRules() {
        #expect(OpenTargetCommand.looksLikeDomain("example.com"))
        #expect(!OpenTargetCommand.looksLikeDomain("just words"))
        #expect(!OpenTargetCommand.looksLikeDomain("nodot"))
        #expect(!OpenTargetCommand.looksLikeDomain("trailing."))
    }

    // MARK: System control (argument mapping + curated phrases + volume step)

    @Test func systemActionMapping() {
        #expect(SystemControlCommand.action(for: "volume up") == .volumeUp)
        #expect(SystemControlCommand.action(for: "louder") == .volumeUp)
        #expect(SystemControlCommand.action(for: "volume down") == .volumeDown)
        #expect(SystemControlCommand.action(for: "mute") == .mute)
        #expect(SystemControlCommand.action(for: "unmute") == .unmute)
        // Media play/pause is intentionally out of v1.
        #expect(SystemControlCommand.action(for: "play") == nil)
    }

    @Test func curatedVolumePhrases() {
        #expect(SystemControlCommand.curatedAction(for: "turn it up") == "volume up")
        #expect(SystemControlCommand.curatedAction(for: "quieter") == "volume down")
        #expect(SystemControlCommand.curatedAction(for: "mute the volume") == "mute")
        #expect(SystemControlCommand.curatedAction(for: "pause the music") == nil)
    }

    @Test func volumeStepClamps() {
        #expect(SystemVolume.stepped(current: 0.5, by: 0.0625) == 0.5625)
        #expect(SystemVolume.stepped(current: 0.98, by: 0.0625) == 1.0)   // clamps high
        #expect(SystemVolume.stepped(current: 0.02, by: -0.0625) == 0.0)  // clamps low
    }

    // MARK: Registry + surfaces (construct commands → main actor)

    @MainActor @Test func registryMapsEveryKind() {
        let registry = CommandRegistry(injector: OutputInjector())
        #expect(registry.command(for: .openTarget)?.id == "open")
        #expect(registry.command(for: .systemControl)?.id == "system")
        #expect(registry.command(for: .typeIntoTerminal)?.id == "terminal")
        #expect(registry.command(for: .unknown) == nil)
    }

    @MainActor @Test func summariesAreHumanReadable() {
        #expect(OpenTargetCommand().summary(argument: "Safari") == "Open Safari")
        #expect(SystemControlCommand().summary(argument: "volume up") == "Volume up")
        #expect(TypeIntoTerminalCommand(injector: OutputInjector()).summary(argument: "npm test")
            == "⏎ Terminal: npm test")
    }

    @MainActor @Test func trustTiersReflectBlastRadius() {
        #expect(OpenTargetCommand().trustTier == .zero)
        #expect(SystemControlCommand().trustTier == .zero)
        #expect(TypeIntoTerminalCommand(injector: OutputInjector()).trustTier == .one)
    }

    @MainActor @Test func terminalCanRunGatesOnFrontmostApp() {
        let terminal = TypeIntoTerminalCommand(injector: OutputInjector())
        #expect(terminal.canRun(context: CommandContext(frontmostBundleID: "com.apple.Terminal")))
        #expect(!terminal.canRun(context: CommandContext(frontmostBundleID: "com.apple.Safari")))
        #expect(!terminal.canRun(context: CommandContext(frontmostBundleID: nil)))
    }

    // MARK: Terminal newline safety — a pasted newline the shell would submit on paste

    @Test func sanitizerCollapsesEveryLineBreak() {
        // CRLF and consecutive breaks collapse to a single space; ends are trimmed.
        #expect(TypeIntoTerminalCommand.sanitizedForTerminal("echo hi\nrm -rf /") == "echo hi rm -rf /")
        #expect(TypeIntoTerminalCommand.sanitizedForTerminal("a\r\nb") == "a b")
        #expect(TypeIntoTerminalCommand.sanitizedForTerminal("a\n\nb") == "a b")
        #expect(TypeIntoTerminalCommand.sanitizedForTerminal("line1\u{2028}line2\u{2029}line3") == "line1 line2 line3")
        #expect(TypeIntoTerminalCommand.sanitizedForTerminal("\n trailing \n") == "trailing")
    }

    /// Captures exactly what would be pasted, so the "single line, no submission on
    /// paste" invariant is asserted end-to-end (not just on the helper).
    private final class RecordingInjector: PasteInjecting {
        var injected: [String] = []
        func inject(_ text: String) -> OutputInjector.Result {
            injected.append(text)
            return .pasted
        }
    }

    @MainActor @Test func multiLineArgumentInjectsSingleLine() async throws {
        let recorder = RecordingInjector()
        let terminal = TypeIntoTerminalCommand(injector: recorder)
        try await terminal.run(argument: "echo one\nsudo rm -rf /\r\necho three")
        #expect(recorder.injected.count == 1)
        let pasted = recorder.injected.first ?? ""
        #expect(pasted == "echo one sudo rm -rf / echo three")
        #expect(!pasted.contains("\n"))
        #expect(!pasted.contains("\r"))
        // The confirm pill shows exactly what will be pasted.
        #expect(terminal.summary(argument: "echo one\nsudo rm -rf /") == "⏎ Terminal: echo one sudo rm -rf /")
    }
}
