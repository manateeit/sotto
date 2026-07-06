import AppKit
import Foundation

/// Tier-0 command: open an installed app by name, or open an explicit https URL
/// (M6). No browser-tab automation, no arbitrary scheme — https only, so a spoken
/// command can never open a plaintext or custom-scheme link. App matching is against
/// the standard application directories.
struct OpenTargetCommand: VoiceCommand {
    let id = "open"
    let trustTier = TrustTier.zero

    /// Fixed application directories scanned for app bundles (the user's
    /// ~/Applications is added at scan time).
    // ponytail: shallow scan of these dirs only; nested app folders beyond
    // /System/Applications/Utilities aren't walked. Enough for the apps users open by
    // voice; deepen if a real miss shows up on the hardware run.
    nonisolated static let appDirectories = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]

    /// How an argument resolves. Pure over an injected app map, so it's unit-tested
    /// without touching the filesystem.
    enum Resolution: Equatable {
        case openURL(URL)
        case launchApp(URL)
        case notFound
    }

    func summary(argument: String) -> String { "Open \(argument)" }

    // Tier 0 has no environment gate — it's always offerable through the confirm
    // pill. An argument that resolves to nothing surfaces as a thrown error from
    // `run`, not a silent no-op.
    func canRun(context: CommandContext) -> Bool { true }

    func run(argument: String) async throws {
        switch Self.resolve(argument: argument, installedApps: Self.installedApps()) {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .launchApp(let appURL):
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        case .notFound:
            throw CommandError.targetNotFound(argument)
        }
    }

    // MARK: Resolution (pure)

    /// Decide what an argument names, given the installed-app map (lowercased base
    /// name → bundle URL). https URLs win; then an exact app-name match; then a unique
    /// substring app match ("chrome" → "Google Chrome"); then a bare domain upgraded
    /// to https. Anything else is `.notFound` — never guess.
    nonisolated static func resolve(argument: String, installedApps: [String: URL]) -> Resolution {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("https://") {
            return URL(string: trimmed).map(Resolution.openURL) ?? .notFound
        }
        if lower.hasPrefix("http://") {
            return .notFound // https only
        }
        if let url = installedApps[lower] {
            return .launchApp(url)
        }
        let substringMatches = installedApps.filter { $0.key.contains(lower) }
        if substringMatches.count == 1, let url = substringMatches.first?.value {
            return .launchApp(url)
        }
        if looksLikeDomain(trimmed), let url = URL(string: "https://" + trimmed) {
            return .openURL(url)
        }
        return .notFound
    }

    /// A single dotted token with a plausible alphabetic TLD (no whitespace). Pure.
    nonisolated static func looksLikeDomain(_ s: String) -> Bool {
        guard !s.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" }), s.contains(".") else { return false }
        guard let lastDot = s.lastIndex(of: ".") else { return false }
        let tld = s[s.index(after: lastDot)...]
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    /// Lowercased base-name → bundle URL for apps in the standard directories.
    /// Filesystem I/O; the pure decision above is what the tests exercise.
    nonisolated static func installedApps() -> [String: URL] {
        var directories = appDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        directories.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true))

        var map: [String: URL] = [:]
        for dir in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                let name = entry.deletingPathExtension().lastPathComponent.lowercased()
                if map[name] == nil { map[name] = entry }
            }
        }
        return map
    }
}
