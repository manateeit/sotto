import Foundation
import Testing
@testable import Sotto

/// Onboarding gates on missing permissions (DESIGN.md M3 exit criterion) *and*,
/// as of M5, on the "how to dictate" guide not having been seen yet.
@Suite struct OnboardingGatingTests {
    @Test func showsWhenAnyPermissionMissing() {
        #expect(Onboarding.shouldShow(micAuthorized: false, axTrusted: false, completedGuide: true) == true)
        #expect(Onboarding.shouldShow(micAuthorized: true, axTrusted: false, completedGuide: true) == true)
        #expect(Onboarding.shouldShow(micAuthorized: false, axTrusted: true, completedGuide: true) == true)
    }

    @Test func showsWhenGuideNotYetCompleted() {
        #expect(Onboarding.shouldShow(micAuthorized: true, axTrusted: true, completedGuide: false) == true)
    }

    @Test func hiddenWhenBothGrantedAndGuideCompleted() {
        #expect(Onboarding.shouldShow(micAuthorized: true, axTrusted: true, completedGuide: true) == false)
    }
}

/// Hotkey keycode+modifiers persist and restore through UserDefaults.
@Suite @MainActor struct SettingsTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "sotto.test.\(UUID().uuidString)")!
    }

    @Test func hotkeyStorageRoundTrip() {
        let suite = freshSuite()
        let settings = Settings(defaults: suite)
        settings.hotkeyKeyCode = 40      // D
        settings.hotkeyModifiers = 4096  // some Carbon mask
        let reloaded = Settings(defaults: suite)
        #expect(reloaded.hotkeyKeyCode == 40)
        #expect(reloaded.hotkeyModifiers == 4096)
    }

    @Test func defaultsAreSaneOnFreshSuite() {
        let settings = Settings(defaults: freshSuite())
        #expect(settings.soundsEnabled == true)
        #expect(settings.smartCleanupEnabled == true)
        #expect(settings.historyRetentionDays == HistoryStore.defaultRetentionDays)
    }
}
