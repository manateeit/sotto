import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// Menu-bar-only orchestrator for the dictation loop:
/// hotkey (push-to-talk or toggle) → record + HUD → SpeechAnalyzer → paste.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyManager()
    private let recorder = Recorder()
    private let engine: TranscriptionEngine = SpeechAnalyzerEngine()
    private let postProcessor: PostProcessor = Passthrough()
    private let injector = OutputInjector()
    private let hud = HUDController()
    private let sounds = Sounds()
    private var gesture = HotkeyGesture()

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?

    /// Lifecycle of one dictation. `starting` covers the async engine/mic spin-up
    /// so a stop or cancel arriving during it can be honored.
    private enum Phase {
        case idle
        case starting
        case recording
        case finishing
    }
    private var phase: Phase = .idle
    private var cancelRequestedDuringStart = false
    private var hudDismissWork: DispatchWorkItem?
    private var escMonitor: Any?

    private var isActive: Bool { phase == .starting || phase == .recording }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        requestMicrophoneAccess()
        promptForAccessibilityTrust()

        // hotKeyHandler dispatches to main, so assuming main isolation here is safe.
        hotkey.onKeyDown = { [weak self] in
            MainActor.assumeIsolated { self?.handleKeyDown() }
        }
        hotkey.onKeyUp = { [weak self] in
            MainActor.assumeIsolated { self?.handleKeyUp() }
        }
        hotkey.register()

        // Kick off model asset preparation; reflect progress in the menu.
        Task { [weak self] in
            do {
                try await self?.engine.prepare { message in
                    Task { @MainActor in self?.setStatus(message) }
                }
            } catch {
                await MainActor.run { self?.setStatus("Speech unavailable: \(error)") }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        removeEscMonitor()
        recorder.stop()
    }

    // MARK: Hotkey → intent

    private func handleKeyDown() {
        apply(gesture.keyDown(at: now, isRecording: isActive))
    }

    private func handleKeyUp() {
        apply(gesture.keyUp(at: now, isRecording: isActive))
    }

    private func apply(_ intent: HotkeyGesture.Intent) {
        switch intent {
        case .start: startRecording()
        case .stop: stopAndTranscribe()
        case .none: break
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Dictation loop

    private func startRecording() {
        guard phase == .idle else { return }
        guard ensureMicrophoneAuthorized() else { return }

        phase = .starting
        cancelRequestedDuringStart = false
        cancelHUDDismiss()

        sounds.play(.start)
        hud.show(.recording)
        setRecordingIcon(true)
        setStatus("Listening… (⌥Space or hold)")
        installEscMonitor()

        Task { @MainActor in
            do {
                try await engine.beginSession()
                recorder.onBuffer = { [engine] buffer in engine.append(buffer) }
                recorder.onLevel = { [weak self] level in
                    Task { @MainActor in self?.hud.model.pushLevel(level) }
                }
                try recorder.start()

                if cancelRequestedDuringStart {
                    performCancel(playSound: false)
                    return
                }
                phase = .recording
            } catch {
                teardownAudioCallbacks()
                removeEscMonitor()
                await engine.cancelSession()
                phase = .idle
                sounds.play(.cancel)
                showError("Couldn't start recording")
            }
        }
    }

    private func stopAndTranscribe() {
        switch phase {
        case .starting:
            // Stop before spin-up finished; nothing captured yet — treat as cancel.
            cancelRequestedDuringStart = true
        case .recording:
            finishRecording()
        case .idle, .finishing:
            break
        }
    }

    private func finishRecording() {
        phase = .finishing
        teardownAudioCallbacks()
        recorder.stop()
        removeEscMonitor()
        sounds.play(.stop)
        hud.update(.transcribing)
        setRecordingIcon(false)
        setStatus("Transcribing…")

        Task { @MainActor in
            defer { phase = .idle }
            do {
                let raw = try await engine.finishSession()
                let text = try await postProcessor.process(raw)
                guard !text.isEmpty else {
                    setStatus("No speech detected.")
                    hud.hide()
                    return
                }
                switch injector.inject(text) {
                case .pasted:
                    setStatus("Pasted \(text.count) chars.")
                    flashDoneThenHide()
                case .refusedSecureInput:
                    NSLog("Sotto: secure input active — left transcript on clipboard.")
                    setStatus("Secure field — copied to clipboard.")
                    flashDoneThenHide()
                case .empty:
                    setStatus("No speech detected.")
                    hud.hide()
                }
            } catch {
                setStatus("Transcription failed: \(error)")
                showError("Transcription failed")
            }
        }
    }

    /// Briefly show the green "done" dot, then dismiss the HUD.
    private func flashDoneThenHide() {
        hud.update(.done)
        scheduleHUDDismiss(after: 0.6)
    }

    private func cancelDictation() {
        switch phase {
        case .starting:
            cancelRequestedDuringStart = true
        case .recording:
            performCancel(playSound: true)
        case .idle, .finishing:
            break
        }
    }

    /// Discard the in-flight dictation without transcribing or pasting.
    private func performCancel(playSound: Bool) {
        phase = .finishing
        teardownAudioCallbacks()
        recorder.stop()
        removeEscMonitor()
        if playSound { sounds.play(.cancel) }
        setRecordingIcon(false)
        setStatus("Cancelled.")
        hud.hide()

        Task { @MainActor in
            await engine.cancelSession()
            phase = .idle
        }
    }

    private func teardownAudioCallbacks() {
        recorder.onBuffer = nil
        recorder.onLevel = nil
    }

    // MARK: Error surfacing + HUD dismissal

    private func showError(_ message: String) {
        hud.show(.error(message))
        scheduleHUDDismiss(after: 3)
    }

    private func scheduleHUDDismiss(after seconds: TimeInterval) {
        hudDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hud.hide() }
        hudDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelHUDDismiss() {
        hudDismissWork?.cancel()
        hudDismissWork = nil
    }

    // MARK: Esc-to-cancel (passive global monitor)

    /// Observe Esc while recording via a *passive* global monitor — it never
    /// consumes the key, so Esc still works in the target app; it just also
    /// cancels our dictation. Requires Accessibility trust (which we already need
    /// for paste); degrade gracefully without it.
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        guard AXIsProcessTrusted() else {
            NSLog("Sotto: Esc-to-cancel unavailable — grant Accessibility trust.")
            return
        }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // 53 = Escape
            // Hop to main explicitly (like the Carbon path) so assumeIsolated can't
            // trap if AppKit ever delivers this off the main thread.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.cancelDictation() }
            }
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Sotto")
            button.image?.isTemplate = true
            button.toolTip = "Sotto — ⌥Space to dictate (tap = toggle, hold = push-to-talk)"
        }

        let menu = NSMenu()
        let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Sotto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )

        item.menu = menu
        statusItem = item
        statusMenuItem = status
    }

    private func setStatus(_ text: String) {
        statusMenuItem?.title = text
    }

    private func setRecordingIcon(_ recording: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = recording ? "mic.fill" : "mic"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sotto")
        button.image?.isTemplate = true
    }

    // MARK: Permissions

    private func ensureMicrophoneAuthorized() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            showError("Grant microphone access, then try again")
            return false
        default:
            showError("Microphone access denied")
            return false
        }
    }

    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            NSLog("Sotto: microphone access denied — enable in System Settings › Privacy › Microphone.")
        }
    }

    private func promptForAccessibilityTrust() {
        // Needed to post the synthetic ⌘V CGEvent. Prompts the user once.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("Sotto: grant Accessibility in System Settings › Privacy › Accessibility to enable paste.")
        }
    }
}
