import AppKit
import Foundation

/// Pure dotted-version comparison ("0.1.0" vs "0.0.1", with or without a leading
/// "v" as GitHub tags use). Kept free of networking so it's unit-testable without
/// fixtures. Malformed/non-numeric components compare as 0 rather than crashing —
/// a bad tag should degrade to "no update", never a bad experience.
enum AppVersion {
    static func stripLeadingV(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }

    /// Component-wise numeric compare; missing trailing components count as 0
    /// (so "1.2" == "1.2.0").
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs)
        let b = components(rhs)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av < bv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidateTag: String, than currentVersion: String) -> Bool {
        compare(stripLeadingV(candidateTag), stripLeadingV(currentVersion)) == .orderedDescending
    }

    private static func components(_ version: String) -> [Int] {
        stripLeadingV(version).split(separator: ".").map { Int($0) ?? 0 }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// "Check for Updates…" menu item glue. GETs the latest GitHub release ONLY on
/// explicit click — no timers, no phone-home at launch (DESIGN.md privacy
/// identity). Reports the outcome via NSAlert.
@MainActor
enum UpdateChecker {
    // ponytail: single hardcoded owner/repo constant, kept in sync with the real
    // GitHub repo (or overridden per-build — see repo below).
    static let defaultRepo = "manateeit/sotto"

    /// Overridable via the app bundle's Info.plist (key `SottoUpdateRepo`), which
    /// scripts/make-app.sh can set from an env var without touching source.
    static var repo: String {
        (Bundle.main.object(forInfoDictionaryKey: "SottoUpdateRepo") as? String) ?? defaultRepo
    }

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    static func checkForUpdates() {
        Task { await performCheck() }
    }

    private static func performCheck() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            presentAlert(title: "Check for Updates", message: "Couldn't check — invalid update repo configured.")
            return
        }

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(from: url)
        } catch {
            presentAlert(title: "Check for Updates", message: "Couldn't check for updates — you may be offline.")
            return
        }

        guard let http = result.1 as? HTTPURLResponse else {
            presentAlert(title: "Check for Updates", message: "Couldn't check for updates — no response from GitHub.")
            return
        }

        switch http.statusCode {
        case 200:
            guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: result.0) else {
                presentAlert(title: "Check for Updates", message: "Couldn't check — GitHub's response was unreadable.")
                return
            }
            let remoteVersion = AppVersion.stripLeadingV(release.tagName)
            if AppVersion.isNewer(release.tagName, than: currentVersion) {
                presentUpdateAvailable(remoteVersion: remoteVersion, downloadURLString: release.htmlURL)
            } else {
                presentAlert(title: "You're up to date", message: "Sotto \(currentVersion) is the latest version.")
            }
        case 404:
            presentAlert(title: "Check for Updates", message: "Couldn't check — no releases have been published yet.")
        case 403:
            presentAlert(title: "Check for Updates", message: "Couldn't check — rate-limited by GitHub. Try again later.")
        default:
            presentAlert(title: "Check for Updates", message: "Couldn't check for updates (GitHub returned \(http.statusCode)).")
        }
    }

    private static func presentUpdateAvailable(remoteVersion: String, downloadURLString: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sotto \(remoteVersion) is available (you have \(currentVersion))"
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: downloadURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
