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
        static let historyEnabled = "sotto.historyEnabled"
        static let keepAudio = "sotto.keepAudio"
        static let retentionDays = "sotto.historyRetentionDays"
        static let hotkeyKeyCode = "sotto.hotkeyKeyCode"
        static let hotkeyModifiers = "sotto.hotkeyModifiers"
        static let completedOnboardingGuide = "sotto.completedOnboardingGuide"
    }

    private let defaults: UserDefaults

    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: Key.sounds) } }
    @Published var smartCleanupEnabled: Bool { didSet { defaults.set(smartCleanupEnabled, forKey: Key.smartCleanup) } }
    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) } }
    @Published var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: Key.keepAudio) } }
    @Published var historyRetentionDays: Int { didSet { defaults.set(historyRetentionDays, forKey: Key.retentionDays) } }
    @Published var hotkeyKeyCode: Int { didSet { defaults.set(hotkeyKeyCode, forKey: Key.hotkeyKeyCode) } }
    @Published var hotkeyModifiers: Int { didSet { defaults.set(hotkeyModifiers, forKey: Key.hotkeyModifiers) } }
    /// Whether the user has clicked through the "how to dictate" onboarding step at
    /// least once. Combined with the permission grants to decide `Onboarding.shouldShow`.
    @Published var completedOnboardingGuide: Bool { didSet { defaults.set(completedOnboardingGuide, forKey: Key.completedOnboardingGuide) } }
    /// Reflects SMAppService; the didSet applies the change to the system.
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }
    /// Transient UI feedback if a hotkey couldn't be registered (not persisted).
    @Published var hotkeyError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.sounds: true,
            Key.smartCleanup: true,
            Key.historyEnabled: true,
            Key.keepAudio: true,
            Key.retentionDays: HistoryStore.defaultRetentionDays,
            Key.hotkeyKeyCode: kVK_Space,
            Key.hotkeyModifiers: Int(optionKey),
            Key.completedOnboardingGuide: false
        ])
        soundsEnabled = defaults.bool(forKey: Key.sounds)
        smartCleanupEnabled = defaults.bool(forKey: Key.smartCleanup)
        historyEnabled = defaults.bool(forKey: Key.historyEnabled)
        keepAudio = defaults.bool(forKey: Key.keepAudio)
        historyRetentionDays = defaults.integer(forKey: Key.retentionDays)
        hotkeyKeyCode = defaults.integer(forKey: Key.hotkeyKeyCode)
        hotkeyModifiers = defaults.integer(forKey: Key.hotkeyModifiers)
        completedOnboardingGuide = defaults.bool(forKey: Key.completedOnboardingGuide)
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
