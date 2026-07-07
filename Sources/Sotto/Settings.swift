import Carbon.HIToolbox
import Foundation
import SwiftUI

/// User settings, backed by UserDefaults, observable by the SwiftUI settings
/// window and read by the AppDelegate. Deliberately small (DESIGN.md §identity:
/// "if a user opens settings in the first week, we've failed").
@MainActor
final class Settings: ObservableObject {
    enum Key {
        static let sounds = "sotto.soundsEnabled"
        static let smartCleanup = "sotto.smartCleanupEnabled"
        static let voiceCommands = "sotto.voiceCommandsEnabled"
        static let historyEnabled = "sotto.historyEnabled"
        static let keepAudio = "sotto.keepAudio"
        static let retentionDays = "sotto.historyRetentionDays"
        static let hotkeyKeyCode = "sotto.hotkeyKeyCode"
        static let hotkeyModifiers = "sotto.hotkeyModifiers"
        static let completedOnboardingGuide = "sotto.completedOnboardingGuide"
        static let agentReplies = "sotto.agentRepliesEnabled"
        static let clipboardHistory = "sotto.clipboardHistoryEnabled"
        static let clipboardDisclosureSeen = "sotto.clipboardDisclosureSeen"
        static let domainProfile = "sotto.domainProfile"
        static let modelProvider = "sotto.modelProvider"
        static let ollamaModel = "sotto.ollamaModel"
    }

    private let defaults: UserDefaults

    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: Key.sounds) } }
    @Published var smartCleanupEnabled: Bool { didSet { defaults.set(smartCleanupEnabled, forKey: Key.smartCleanup) } }
    /// Whether a spoken "Sotto, …" wake word routes to the command flow. OFF skips
    /// the prefix check entirely — dictation behaves exactly as before M6 (DESIGN.md §3).
    @Published var voiceCommandsEnabled: Bool { didSet { defaults.set(voiceCommandsEnabled, forKey: Key.voiceCommands) } }
    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) } }
    @Published var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: Key.keepAudio) } }
    @Published var historyRetentionDays: Int { didSet { defaults.set(historyRetentionDays, forKey: Key.retentionDays) } }
    @Published var hotkeyKeyCode: Int { didSet { defaults.set(hotkeyKeyCode, forKey: Key.hotkeyKeyCode) } }
    @Published var hotkeyModifiers: Int { didSet { defaults.set(hotkeyModifiers, forKey: Key.hotkeyModifiers) } }
    /// Whether the user has clicked through the "how to dictate" onboarding step at
    /// least once. Combined with the permission grants to decide `Onboarding.shouldShow`.
    @Published var completedOnboardingGuide: Bool { didSet { defaults.set(completedOnboardingGuide, forKey: Key.completedOnboardingGuide) } }
    /// Whether Sotto answers `sotto://reply` deep links from coding-agent hooks
    /// (Claude Code, etc.). OFF by default — an inbound trigger is opt-in. It never
    /// executes anything: the dictation is written back as text for the agent to read.
    @Published var agentRepliesEnabled: Bool { didSet { defaults.set(agentRepliesEnabled, forKey: Key.agentReplies) } }
    /// Opt-in, OFF by default. Captures general-clipboard copies into a SEPARATE
    /// on-device history (its own file). Zero network. Skips concealed/transient
    /// pasteboard items (password managers). Count-capped, 0600, backup-excluded.
    @Published var clipboardHistoryEnabled: Bool { didSet { defaults.set(clipboardHistoryEnabled, forKey: Key.clipboardHistory) } }
    /// Whether the one-time "this stores everything you copy" disclosure was shown.
    @Published var clipboardDisclosureSeen: Bool { didSet { defaults.set(clipboardDisclosureSeen, forKey: Key.clipboardDisclosureSeen) } }
    /// Free-text description of the user's field/role (e.g. "Cardiologist"). Fed to
    /// on-device cleanup as a bias hint so ambiguous words resolve toward their
    /// domain — never rewrites meaning. Empty = no domain bias (default).
    @Published var domainProfile: String { didSet { defaults.set(domainProfile, forKey: Key.domainProfile) } }
    /// Which model runs cleanup: "none" (on-device Foundation Models, default) or
    /// "ollama" (local). Cloud providers land in a later milestone. Selecting a
    /// non-"none" provider is the ONLY thing that constructs a network-capable path.
    @Published var modelProvider: String { didSet { defaults.set(modelProvider, forKey: Key.modelProvider) } }
    /// The Ollama model id (e.g. "llama3.1:8b"), used only when modelProvider == "ollama".
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) } }
    /// Reflects SMAppService; the didSet applies the change to the system.
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }
    /// Transient UI feedback if a hotkey couldn't be registered (not persisted).
    @Published var hotkeyError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.sounds: true,
            Key.smartCleanup: true,
            Key.voiceCommands: true,
            Key.historyEnabled: true,
            Key.keepAudio: true,
            Key.retentionDays: HistoryStore.defaultRetentionDays,
            Key.hotkeyKeyCode: kVK_Space,
            Key.hotkeyModifiers: Int(optionKey),
            Key.completedOnboardingGuide: false,
            Key.agentReplies: false,
            Key.clipboardHistory: false,
            Key.clipboardDisclosureSeen: false,
            Key.domainProfile: "",
            Key.modelProvider: ModelProvider.none.rawValue,
            Key.ollamaModel: ""
        ])
        soundsEnabled = defaults.bool(forKey: Key.sounds)
        smartCleanupEnabled = defaults.bool(forKey: Key.smartCleanup)
        voiceCommandsEnabled = defaults.bool(forKey: Key.voiceCommands)
        historyEnabled = defaults.bool(forKey: Key.historyEnabled)
        keepAudio = defaults.bool(forKey: Key.keepAudio)
        historyRetentionDays = defaults.integer(forKey: Key.retentionDays)
        hotkeyKeyCode = defaults.integer(forKey: Key.hotkeyKeyCode)
        hotkeyModifiers = defaults.integer(forKey: Key.hotkeyModifiers)
        completedOnboardingGuide = defaults.bool(forKey: Key.completedOnboardingGuide)
        agentRepliesEnabled = defaults.bool(forKey: Key.agentReplies)
        clipboardHistoryEnabled = defaults.bool(forKey: Key.clipboardHistory)
        clipboardDisclosureSeen = defaults.bool(forKey: Key.clipboardDisclosureSeen)
        domainProfile = defaults.string(forKey: Key.domainProfile) ?? ""
        modelProvider = defaults.string(forKey: Key.modelProvider) ?? ModelProvider.none.rawValue
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? ""
        launchAtLogin = LoginItem.isEnabled // didSet does not fire during init
    }

    private func applyLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(launchAtLogin)
        } catch {
            NSLog("Sotto: launch-at-login toggle failed: \(error)")
            // Reflect the real system state if the toggle didn't take.
            let actual = LoginItem.isEnabled
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }
}
