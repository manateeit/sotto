import AppKit
import SwiftUI

/// Hosts the settings and onboarding SwiftUI windows for the menu-bar app. Because
/// Sotto is LSUIElement (.accessory), it flips to .regular while a window is open
/// so the window can take focus, then back to .accessory when the last one closes.
@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func showSettings(settings: Settings) {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Sotto Settings", content: SettingsView(settings: settings))
        }
        present(settingsWindow)
        // The window is cached, so data-backed tabs (History) must reload on
        // every show — `.onAppear` won't re-fire on a reused window.
        NotificationCenter.default.post(name: .sottoSettingsDidShow, object: nil)
    }

    func showOnboarding(onDone: @escaping () -> Void,
                        onOpenSettings: @escaping () -> Void = {},
                        statusItemHidden: @escaping () -> Bool = { false }) {
        if onboardingWindow == nil {
            let view = OnboardingView(
                onDone: { [weak self] in
                    self?.onboardingWindow?.close()
                    onDone()
                },
                onOpenSettings: { [weak self] in
                    // Close the guide and hand off to Settings so the user can
                    // change the hotkey. onDone marks the guide as seen.
                    self?.onboardingWindow?.close()
                    onDone()
                    onOpenSettings()
                },
                statusItemHidden: statusItemHidden
            )
            onboardingWindow = makeWindow(title: "Welcome to Sotto", content: view)
        }
        present(onboardingWindow)
    }

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing == onboardingWindow { onboardingWindow = nil }
        // Restore accessory policy once no managed window is visible.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let anyVisible = [self.settingsWindow, self.onboardingWindow]
                .compactMap { $0 }
                .contains { $0.isVisible }
            if !anyVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
