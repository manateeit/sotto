import Foundation

/// The inbound half of Sotto's coding-agent integration: a coding-agent hook
/// (Claude Code, etc.) opens a `sotto://reply` deep link when the agent stops or
/// asks a question; Sotto records a spoken reply on-device and writes the
/// transcript to a response file the hook polls. It only ever produces TEXT — the
/// agent reads it as its next input; nothing is executed (DESIGN.md confirm-gate).
///
/// URL shape:
///   sotto://reply?response=<path>&ctx=<path>&agent=<name>
///     response  (required) file Sotto writes the spoken transcript to
///     ctx       (optional) file holding the agent's last message, for display
///     agent     (optional) display name, e.g. "Claude Code"
enum ReplyBridge {
    struct Request: Equatable {
        let responsePath: String
        let agent: String
    }

    /// Parse a `sotto://reply` URL. Returns nil for anything that isn't a valid
    /// reply request (wrong scheme/host, or no response path). Pure — unit-tested.
    static func parse(_ url: URL) -> Request? {
        guard url.scheme == "sotto", url.host == "reply" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces)
        }
        guard let response = value("response"), !response.isEmpty else { return nil }
        let agent = value("agent").flatMap { $0.isEmpty ? nil : $0 } ?? "your agent"
        return Request(responsePath: response, agent: agent)
    }

    /// The response path comes from an external URL, so only ever write inside a
    /// system temp directory — never an arbitrary user-writable location. Pure —
    /// unit-tested.
    static func isAllowedTempPath(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        guard !p.contains("..") else { return false }
        let allowed = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        return allowed.contains { p.hasPrefix($0) }
    }

    /// Write the spoken transcript to the response file atomically. Refuses paths
    /// outside a temp directory. Returns success.
    static func write(_ text: String, toPath path: String) -> Bool {
        guard isAllowedTempPath(path) else {
            NSLog("Sotto: refusing reply write outside a temp directory: \(path)")
            return false
        }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            NSLog("Sotto: reply write failed: \(error)")
            return false
        }
    }
}
