import AppKit

// Menu-bar-only app: no Dock icon, no main window (LSUIElement in Info.plist,
// .accessory activation policy here so it also behaves when run unbundled).
//
// The process entry point runs on the main thread; assert that so we can touch
// the main-actor-isolated AppKit + AppDelegate APIs from top-level code.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
