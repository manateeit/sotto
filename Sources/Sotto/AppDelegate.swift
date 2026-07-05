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
    private var vocabulary = VocabularyRewriter.empty
    private var smart = SmartProcessor()
    private let rawProcessor: PostProcessor = Passthrough()
    private let pipeline = ProcessingPipeline()
    private let clipboard = ClipboardMonitor()
    private let injector = OutputInjector()
    private let hud = HUDController()
    private let sounds = Sounds()
    private var gesture = HotkeyGesture()

    /// Context captured at record start; AX pieces merge in asynchronously and the
    /// clipboard field is filled at stop.
    private var context = ContextSnapshot()
    /// Uptime at record start, for the clipboard "changed since (start − 3s)" rule.
    private var contextStartUptime: TimeInterval = 0
    /// How far before record start a clipboard change still counts as context.
    private let clipboardWindow: TimeInterval = 3
    /// Off-main AX capture; guarded by `recordingGeneration` so a stale result can't
    /// merge into a newer recording's context.
    private var axCaptureTask: Task<Void, Never>?
    private var recordingGeneration = 0
    // ponytail: 1s budget for the off-main AX read; if it doesn't resolve in time
    // the dictation proceeds without selection/window/field context.
    private static let axCaptureTimeout: TimeInterval = 1.0

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
        clipboard.start()

        // Load the user's vocabulary (writes an example file on first run) and feed
        // its canonical terms to the smart processor as bias hints.
        vocabulary = VocabularyStore.loadCreatingExampleIfNeeded()
        smart = SmartProcessor(vocabTerms: vocabulary.hintTerms)

        // Kick off model asset preparation; reflect progress in the menu.
        Task { [weak self] in
            do {
                try await self?.engine.prepare { message in
                    Task { @MainActor in self?.setStatus(message) }
                }
                await MainActor.run { self?.reflectReadyStatus() }
            } catch {
                await MainActor.run { self?.setStatus("Speech unavailable: \(error)") }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        removeEscMonitor()
        axCaptureTask?.cancel()
        recorder.stop()
        clipboard.stop()
    }

    /// "Ready", noting when smart cleanup is degraded to raw (Apple Intelligence
    /// off, etc.) — DESIGN.md §6's one-line degradation notice.
    private func reflectReadyStatus() {
        if let note = SmartProcessor.unavailableNote {
            setStatus("Ready — smart cleanup off (\(note))")
        } else {
            setStatus("Ready")
        }
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

    /// Fold the off-main AX read into the current context, unless a newer recording
    /// has since started (generation mismatch).
    private func mergeAccessibilityContext(_ accessibility: AccessibilityContext, generation: Int) {
        guard generation == recordingGeneration else { return }
        context.merge(accessibility)
    }

    // MARK: Dictation loop

    private func startRecording() {
        guard phase == .idle else { return }
        guard ensureMicrophoneAuthorized() else { return }

        // Recording must start immediately — capture only the cheap context (app,
        // bundle, date) synchronously. The AX pieces (selection/window/field) are
        // read off the main thread and merged in when ready; they never gate start.
        contextStartUptime = now
        recordingGeneration += 1
        let generation = recordingGeneration
        context = ContextSnapshot.captureImmediate()
        axCaptureTask?.cancel()
        axCaptureTask = Task { [weak self] in
            let accessibility = await AccessibilityContext.capture(timeout: AppDelegate.axCaptureTimeout)
            await MainActor.run { self?.mergeAccessibilityContext(accessibility, generation: generation) }
        }

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
        axCaptureTask?.cancel()
        sounds.play(.stop)
        hud.update(.transcribing)
        setRecordingIcon(false)
        setStatus("Transcribing…")

        // ⇧ held at stop → raw escape (skip smart processing). Read now, before the
        // async work, while the modifier is still down.
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)

        // Resolve the clipboard piece now: include it if it changed from just before
        // record start through now (i.e. during recording too). Bind immutably so it
        // can cross into the concurrent processing closure.
        let snapshot: ContextSnapshot = {
            var s = context
            s.clipboard = clipboard.textChanged(since: contextStartUptime - clipboardWindow)
            return s
        }()

        Task { @MainActor in
            defer { phase = .idle }
            let raw: String
            do {
                raw = try await engine.finishSession()
            } catch {
                setStatus("Transcription failed: \(error)")
                showError("Transcription failed")
                return
            }

            let rewritten = vocabulary.rewrite(raw)
            guard !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                setStatus("No speech detected.")
                hud.hide()
                return
            }

            let smartAvailable = SmartProcessor.isAvailable
            let goingSmart = pipeline.policy.route(
                shiftHeld: shiftHeld,
                smartAvailable: smartAvailable,
                textLength: rewritten.count
            ) == .smart
            if goingSmart { setStatus("Polishing…") }

            // Raw route runs through Passthrough (no model call). Smart route may
            // fail: a transform-attempt failure yields `.transformFailed` and we do
            // NOT paste — leaving the selection untouched rather than clobbering it
            // with the spoken command. A dictate failure yields `.paste` of the raw
            // transcript (never lose the paste, DESIGN.md §3).
            let outcome = await pipeline.run(
                text: rewritten,
                context: snapshot,
                shiftHeld: shiftHeld,
                smartAvailable: smartAvailable,
                smart: smart,
                raw: rawProcessor
            )

            switch outcome {
            case .transformFailed:
                NSLog("Sotto: transform attempt failed — selection left unchanged.")
                setStatus("Transform failed — selection unchanged.")
                showError("Transform failed — selection left as-is")
            case .paste(let text):
                paste(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// Inject the final text and reflect the result on the HUD + status line.
    private func paste(_ output: String) {
        guard !output.isEmpty else {
            setStatus("No speech detected.")
            hud.hide()
            return
        }
        switch injector.inject(output) {
        case .pasted:
            setStatus("Pasted \(output.count) chars.")
            flashDoneThenHide()
        case .refusedSecureInput:
            NSLog("Sotto: secure input active — left transcript on clipboard.")
            setStatus("Secure field — copied to clipboard.")
            flashDoneThenHide()
        case .empty:
            setStatus("No speech detected.")
            hud.hide()
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
        axCaptureTask?.cancel()
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
        // The key is kAXTrustedCheckOptionPrompt's value, used as a literal to avoid
        // the imported global var (not concurrency-safe under Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("Sotto: grant Accessibility in System Settings › Privacy › Accessibility to enable paste.")
        }
    }
}
