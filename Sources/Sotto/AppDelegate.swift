import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// Menu-bar-only orchestrator for the whole M0 loop:
/// hotkey → record → SpeechAnalyzer → post-process → paste.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyManager()
    private let recorder = Recorder()
    private let engine: TranscriptionEngine = SpeechAnalyzerEngine()
    private let postProcessor: PostProcessor = Passthrough()
    private let injector = OutputInjector()

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?

    private var isRecording = false
    private var isBusy = false

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        requestMicrophoneAccess()
        promptForAccessibilityTrust()

        // hotKeyHandler dispatches to main, so assuming main isolation here is safe.
        hotkey.onToggle = { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
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
        recorder.stop()
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Sotto")
            button.image?.isTemplate = true
            button.toolTip = "Sotto — ⌥Space to dictate"
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

    @MainActor
    private func setStatus(_ text: String) {
        statusMenuItem?.title = text
    }

    private func setRecordingIcon(_ recording: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = recording ? "mic.fill" : "mic"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sotto")
        button.image?.isTemplate = true
    }

    // MARK: Dictation loop

    private func toggle() {
        if isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording, !isBusy else { return }
        isBusy = true

        Task { @MainActor in
            do {
                try await engine.beginSession()
                recorder.onBuffer = { [engine] buffer in engine.append(buffer) }
                try recorder.start()
                isRecording = true
                setRecordingIcon(true)
                setStatus("Recording… (⌥Space to stop)")
            } catch {
                setStatus("Couldn't start: \(error)")
                await engine.cancelSession()
            }
            isBusy = false
        }
    }

    private func stopAndTranscribe() {
        guard isRecording, !isBusy else { return }
        isBusy = true
        isRecording = false

        recorder.stop()
        recorder.onBuffer = nil
        setRecordingIcon(false)
        setStatus("Transcribing…")

        Task { @MainActor in
            do {
                let raw = try await engine.finishSession()
                let text = try await postProcessor.process(raw)
                guard !text.isEmpty else {
                    setStatus("No speech detected.")
                    isBusy = false
                    return
                }
                switch injector.inject(text) {
                case .pasted:
                    setStatus("Pasted \(text.count) chars.")
                case .refusedSecureInput:
                    NSLog("Sotto: secure input active — left transcript on clipboard.")
                    setStatus("Secure field — copied to clipboard instead.")
                case .empty:
                    setStatus("No speech detected.")
                }
            } catch {
                setStatus("Transcription failed: \(error)")
            }
            isBusy = false
        }
    }

    // MARK: Permissions

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
