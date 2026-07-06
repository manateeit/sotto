import AppKit
import Foundation

/// Why a command couldn't complete. Surfaced as a short HUD error; never fatal.
enum CommandError: Error, Equatable {
    case targetNotFound(String)
    case unsupported
    case injectionRefused
}

/// Trust tier for a voice command (M6). v1 keeps this descriptive — EVERY command,
/// tier 0 included, still goes through the confirm pill; no tier auto-runs. The tier
/// documents blast radius and leaves room for a future "skip confirm for tier 0"
/// setting without reworking the seam.
enum TrustTier: Int, Sendable, Equatable {
    /// Reversible, no content injected into another app (open an app/URL, volume).
    case zero = 0
    /// Injects content into another app (types into the terminal). Higher scrutiny.
    case one = 1
}

/// The world a command needs to decide whether it can run and to act. Captured on
/// the main actor at recognition time (and re-checked at run time). Sendable so it
/// can cross into the async dispatch.
struct CommandContext: Sendable, Equatable {
    /// Bundle id of the frontmost app — the app that will receive a terminal paste,
    /// and the gate for the terminal allowlist.
    var frontmostBundleID: String?
}

/// The third protocol seam (M6), justified by three concrete implementations
/// (`OpenTargetCommand`, `SystemControlCommand`, `TypeIntoTerminalCommand`). The FM
/// classifies; THIS dispatches — and only ever after an explicit human confirm.
///
/// MainActor-isolated because `run` touches AppKit / the injector / CoreAudio on the
/// main thread; the query members are `nonisolated` so the pure logic (summaries,
/// allowlist checks) is testable off the main actor.
@MainActor
protocol VoiceCommand {
    nonisolated var id: String { get }
    nonisolated var trustTier: TrustTier { get }
    /// One-line pill text for the confirm HUD (no affordance hint — the HUD appends
    /// "⌥Space to run · Esc to cancel").
    nonisolated func summary(argument: String) -> String
    /// Whether the command can run in the given context. False ⇒ don't offer the
    /// confirm pill; the caller surfaces a short reason instead.
    nonisolated func canRun(context: CommandContext) -> Bool
    /// Perform the command. Called ONLY after the human confirms. Must never take an
    /// irreversible action the summary didn't describe.
    func run(argument: String) async throws
}

/// Maps a parsed command kind to its handler (M6). Main-actor confined: it owns the
/// command instances, one of which holds the shared `OutputInjector`.
@MainActor
struct CommandRegistry {
    private let open = OpenTargetCommand()
    private let system = SystemControlCommand()
    private let terminal: TypeIntoTerminalCommand

    init(injector: OutputInjector) {
        terminal = TypeIntoTerminalCommand(injector: injector)
    }

    func command(for kind: CommandKind) -> (any VoiceCommand)? {
        switch kind {
        case .openTarget: return open
        case .systemControl: return system
        case .typeIntoTerminal: return terminal
        case .unknown: return nil
        }
    }
}
