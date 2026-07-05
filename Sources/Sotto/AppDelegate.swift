import AppKit
import ApplicationServices
import AVFoundation
import Combine
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
    private let settings = Settings()
    private let windows = AppWindows()
    private var cancellables: Set<AnyCancellable> = []
    /// History id for the in-flight dictation (and its WAV filename).
    private var currentEntryID: String?
    /// Wall-clock start of the in-flight recording, for history duration.
    private var recordStartDate = Date()
    /// Last hotkey combo that registered, for revert-on-failure.
    private var lastGoodHotkey: (keyCode: Int, modifiers: Int)?
    /// Set while reverting a rejected hotkey, so the observer doesn't re-process the
    /// reverted values (and clobber the error message).
    private var revertingHotkey = false

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
        sounds.enabled = settings.soundsEnabled
        requestMicrophoneAccess()
        promptForAccessibilityTrust()

        // hotKeyHandler dispatches to main, so assuming main isolation here is safe.
        hotkey.onKeyDown = { [weak self] in
            MainActor.assumeIsolated { self?.handleKeyDown() }
        }
        hotkey.onKeyUp = { [weak self] in
            MainActor.assumeIsolated { self?.handleKeyUp() }
        }
        if hotkey.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers) {
            lastGoodHotkey = (settings.hotkeyKeyCode, settings.hotkeyModifiers)
        }
        clipboard.start()

        // Load the user's vocabulary (writes an example file on first run) and feed
        // its canonical terms to the smart processor as bias hints.
        reloadVocabulary()
        observeSettings()

        // Retire history past its retention window.
        HistoryStore.prune(retentionDays: settings.historyRetentionDays)

        // Onboarding is shown *only* when a required permission is missing.
        if Onboarding.shouldShow(micAuthorized: micAuthorized, axTrusted: AXIsProcessTrusted()) {
            windows.showOnboarding(onDone: {})
        }

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

    /// React to settings changes: sounds, hotkey rebind, and vocabulary reloads.
    private func observeSettings() {
        settings.$soundsEnabled
            .sink { [weak self] in self?.sounds.enabled = $0 }
            .store(in: &cancellables)

        settings.$smartCleanupEnabled
            .dropFirst() // don't clobber the "Preparing…" status at launch
            .sink { [weak self] _ in self?.reflectReadyStatus() }
            .store(in: &cancellables)

        // Coalesce the two properties (a hotkey change sets both) into one rebind.
        settings.$hotkeyKeyCode.combineLatest(settings.$hotkeyModifiers)
            .dropFirst() // skip the initial value; already registered at launch
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] keyCode, modifiers in
                guard let self else { return }
                if self.revertingHotkey { self.revertingHotkey = false; return }
                self.applyHotkey(keyCode: keyCode, modifiers: modifiers)
            }
            .store(in: &cancellables)

        // Free / re-register the global hotkey around a recorder capture so the
        // current combo can be re-recorded without firing dictation.
        NotificationCenter.default.publisher(for: .sottoHotkeyCaptureBegan)
            .sink { [weak self] _ in self?.hotkey.suspend() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .sottoHotkeyCaptureEnded)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hotkey.resume(keyCode: self.settings.hotkeyKeyCode, modifiers: self.settings.hotkeyModifiers)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .sottoVocabularyChanged)
            .sink { [weak self] _ in self?.reloadVocabulary() }
            .store(in: &cancellables)
    }

    /// Re-register the hotkey; on failure (e.g. the combo is taken) surface an error
    /// and revert the settings to the last combo that registered.
    private func applyHotkey(keyCode: Int, modifiers: Int) {
        if hotkey.rebind(keyCode: keyCode, modifiers: modifiers) {
            lastGoodHotkey = (keyCode, modifiers)
            settings.hotkeyError = nil
        } else {
            let attempted = HotkeyFormatter.displayString(keyCode: keyCode, modifiers: modifiers)
            if let good = lastGoodHotkey, good.keyCode != keyCode || good.modifiers != modifiers {
                let kept = HotkeyFormatter.displayString(keyCode: good.keyCode, modifiers: good.modifiers)
                settings.hotkeyError = "Couldn't register \(attempted) — kept \(kept)."
                // Re-register the known-good combo and revert the persisted values.
                // Suppress the observer so the revert doesn't re-run applyHotkey and
                // clear the error we just set.
                _ = hotkey.rebind(keyCode: good.keyCode, modifiers: good.modifiers)
                revertingHotkey = true
                settings.hotkeyKeyCode = good.keyCode
                settings.hotkeyModifiers = good.modifiers
            } else {
                settings.hotkeyError = "Couldn't register \(attempted)."
            }
        }
    }

    private var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func reloadVocabulary() {
        vocabulary = VocabularyStore.loadCreatingExampleIfNeeded()
        smart = SmartProcessor(vocabTerms: vocabulary.hintTerms)
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
        if !settings.smartCleanupEnabled {
            setStatus("Ready — smart cleanup off")
        } else if let note = SmartProcessor.unavailableNote {
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

        // History id for this dictation; write a WAV alongside it if enabled.
        let entryID = UUID().uuidString
        currentEntryID = entryID
        recordStartDate = Date()
        let wavURL = (settings.historyEnabled && settings.keepAudio)
            ? HistoryStore.audioURL(forID: entryID) : nil

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
                try recorder.start(writingWAVTo: wavURL)

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

            // Smart cleanup is used only when available AND the user hasn't turned it
            // off; otherwise route falls to raw.
            let smartAvailable = SmartProcessor.isAvailable && settings.smartCleanupEnabled
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
            case .paste(let text, let route):
                paste(text.trimmingCharacters(in: .whitespacesAndNewlines),
                      rawTranscript: raw, route: route, snapshot: snapshot)
            }
        }
    }

    /// Inject the final text, reflect the result on the HUD + status line, and record
    /// the dictation to open history.
    private func paste(_ output: String, rawTranscript: String, route: String, snapshot: ContextSnapshot) {
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
        case .refusedNoAccessibility:
            NSLog("Sotto: Accessibility not granted — left transcript on clipboard.")
            setStatus("Accessibility not granted — text copied.")
            showError("Accessibility not granted — text copied") // notice + auto-dismiss
        case .empty:
            setStatus("No speech detected.")
            hud.hide()
            return
        }
        // History write sits AFTER inject — off the critical paste path.
        recordHistory(rawTranscript: rawTranscript, finalOutput: output, route: route, snapshot: snapshot)
    }

    private func recordHistory(rawTranscript: String, finalOutput: String, route: String, snapshot: ContextSnapshot) {
        guard settings.historyEnabled else { return }
        let id = currentEntryID ?? UUID().uuidString
        let audioFile = settings.keepAudio ? "\(id).wav" : nil
        HistoryStore.append(HistoryEntry(
            id: id,
            date: recordStartDate,
            rawTranscript: rawTranscript,
            finalOutput: finalOutput,
            route: route,
            app: snapshot.frontmostApp,
            bundleID: snapshot.bundleID,
            durationSeconds: Date().timeIntervalSince(recordStartDate),
            engineID: "SpeechAnalyzer",
            audioFile: audioFile
        ))
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
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let permissionsItem = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Sotto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )

        item.menu = menu
        statusItem = item
        statusMenuItem = status
    }

    @objc private func openSettings() {
        guard phase == .idle else { setStatus("Finish dictating first — then open Settings."); return }
        windows.showSettings(settings: settings)
    }

    /// Reopen the onboarding/permissions window — a path back after a revocation.
    @objc private func openPermissions() {
        guard phase == .idle else { setStatus("Finish dictating first — then open Settings."); return }
        windows.showOnboarding(onDone: {})
    }

    /// Don't let Settings/Permissions open during an active dictation: activating
    /// Sotto's window would redirect the eventual ⌘V into it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openSettings) || menuItem.action == #selector(openPermissions) {
            return phase == .idle
        }
        return true
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
