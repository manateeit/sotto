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
    // M6 command subsystem: parse (FM, behind the CommandParsing seam) → human
    // confirm → dispatch through the VoiceCommand seam. The FM is a PARSER ONLY.
    private let commandParser: any CommandParsing = SmartCommandParser()
    private let commandPipeline = CommandPipeline()
    private lazy var commandRegistry = CommandRegistry(injector: injector)
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
    /// Raw transcript from the last successful paste, for "Undo AI edit" menu item.
    private var lastRawTranscript: String?

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
    /// so a stop or cancel arriving during it can be honored. `confirmingCommand`
    /// (M6) is the window where a parsed voice command waits on an explicit human
    /// re-tap before anything executes.
    private enum Phase {
        case idle
        case starting
        case recording
        case finishing
        case confirmingCommand
    }
    private var phase: Phase = .idle
    private var cancelRequestedDuringStart = false
    private var hudDismissWork: DispatchWorkItem?
    private var escMonitor: Any?

    /// A parsed voice command staged and awaiting the human confirm (M6).
    private struct PendingCommand {
        let command: any VoiceCommand
        let argument: String
        /// The full raw transcript (with wake word), for history.
        let utterance: String
        let summary: String
        let snapshot: ContextSnapshot
    }
    private var pendingCommand: PendingCommand?
    private var confirmTimeoutWork: DispatchWorkItem?
    private var confirmEscMonitor: Any?
    // ponytail: 10s confirm window — a named constant, not exposed in settings.
    private static let confirmTimeout: TimeInterval = 10

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

        // Onboarding is shown when a required permission is missing, or the "how to
        // dictate" guide hasn't been seen yet (first launch).
        if Onboarding.shouldShow(
            micAuthorized: micAuthorized,
            axTrusted: AXIsProcessTrusted(),
            completedGuide: settings.completedOnboardingGuide
        ) {
            showOnboardingWindow()
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
        cancelConfirmMonitors()
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
        // M6 phase-machine branch: while a command awaits confirmation the SAME key
        // confirms it rather than starting a new recording.
        switch HotkeyRouting.keyDownAction(confirmingCommand: phase == .confirmingCommand) {
        case .confirmCommand:
            confirmPendingCommand()
        case .gesture:
            apply(gesture.keyDown(at: now, isRecording: isActive))
        }
    }

    private func handleKeyUp() {
        // The confirm fires on key-down; swallow its release so it never reaches the
        // dictation gesture.
        if phase == .confirmingCommand { return }
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
        case .idle, .finishing, .confirmingCommand:
            // .confirmingCommand never reaches here — ⌥Space is intercepted as a
            // confirm before the gesture runs.
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
            // Command flow hands off to the confirm phase and must NOT be reset to
            // idle by this defer; every other path returns to idle here.
            var handedOffToConfirm = false
            defer { if !handedOffToConfirm { phase = .idle } }
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

            // M6: spoken wake-word command branch. ⇧-raw bypasses it entirely (raw
            // means raw); the setting can disable it; otherwise a first-word "Sotto"
            // routes to the command flow with the wake word stripped. With no wake
            // word, the existing dictate/transform pipeline below runs unchanged — the
            // only added cost on that path is this one prefix check.
            if !shiftHeld, settings.voiceCommandsEnabled, let utterance = WakeWord.command(in: rewritten) {
                handedOffToConfirm = await beginCommandFlow(
                    utterance: utterance, rawTranscript: raw, snapshot: snapshot)
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
        lastRawTranscript = rawTranscript
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
        case .idle, .finishing, .confirmingCommand:
            // The confirm phase has its own Esc handler (cancelPendingCommand).
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

    // MARK: Voice commands (M6)

    /// Recognize and STAGE a spoken command (never execute — a human confirm is
    /// required). Returns true when it entered the confirm phase (the caller must not
    /// reset the phase to idle); false when it resolved immediately (nothing staged).
    /// Parsing is literal-leaning: unknown / low-confidence / FM-unavailable all end
    /// as "Didn't catch a command" and nothing runs.
    private func beginCommandFlow(utterance: String, rawTranscript: String, snapshot: ContextSnapshot) async -> Bool {
        setStatus("Understanding…")
        let plan = await commandPipeline.plan(utterance: utterance, parser: commandParser)
        guard case .execute(let parsed) = plan, let command = commandRegistry.command(for: parsed.kind) else {
            setStatus("Didn't catch a command.")
            showError("Didn't catch a command")
            return false
        }
        let context = CommandContext(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard command.canRun(context: context) else {
            showError(canRunFailureMessage(for: command))
            return false
        }
        let summary = command.summary(argument: parsed.argument)
        pendingCommand = PendingCommand(
            command: command, argument: parsed.argument,
            utterance: rawTranscript, summary: summary, snapshot: snapshot)
        phase = .confirmingCommand
        hud.show(.confirming("\(summary) — ⌥Space to run · Esc to cancel"))
        setStatus("Confirm: \(summary)")
        installConfirmMonitors()
        return true
    }

    /// The human confirmed (⌥Space during the confirm phase): run the staged command.
    private func confirmPendingCommand() {
        guard phase == .confirmingCommand, let pending = pendingCommand else { return }
        cancelConfirmMonitors()
        pendingCommand = nil
        phase = .finishing
        hud.update(.transcribing)
        setStatus("Running…")

        Task { @MainActor in
            defer { phase = .idle }
            // Defensive re-check: the frontmost app could have changed since the pill
            // appeared. A terminal paste must still land in a terminal.
            let context = CommandContext(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            guard pending.command.canRun(context: context) else {
                showError(canRunFailureMessage(for: pending.command))
                return
            }
            do {
                try await pending.command.run(argument: pending.argument)
                setStatus("Ran: \(pending.summary)")
                flashDoneThenHide()
                recordCommandHistory(pending)
            } catch {
                NSLog("Sotto: command failed: \(error)")
                showError(runFailureMessage(for: error, command: pending.command))
            }
        }
    }

    /// Esc or the 10s timeout: cancel the staged command. The world is left untouched
    /// — nothing was ever executed. History is NOT recorded for a cancelled command.
    private func cancelPendingCommand(reason: String) {
        guard phase == .confirmingCommand else { return }
        cancelConfirmMonitors()
        pendingCommand = nil
        phase = .idle
        setStatus(reason)
        hud.hide()
    }

    private func installConfirmMonitors() {
        installConfirmEscMonitor()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.cancelPendingCommand(reason: "Command timed out.") }
        }
        confirmTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmTimeout, execute: work)
    }

    private func cancelConfirmMonitors() {
        confirmTimeoutWork?.cancel()
        confirmTimeoutWork = nil
        removeConfirmEscMonitor()
    }

    /// Esc-to-cancel during the confirm phase — a passive global monitor, same shape
    /// as the recording Esc monitor. Requires Accessibility trust; without it the 10s
    /// timeout still cancels.
    private func installConfirmEscMonitor() {
        guard confirmEscMonitor == nil else { return }
        guard AXIsProcessTrusted() else {
            NSLog("Sotto: Esc-to-cancel-command needs Accessibility trust; 10s timeout still applies.")
            return
        }
        confirmEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // 53 = Escape
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.cancelPendingCommand(reason: "Cancelled.") }
            }
        }
    }

    private func removeConfirmEscMonitor() {
        if let confirmEscMonitor { NSEvent.removeMonitor(confirmEscMonitor) }
        confirmEscMonitor = nil
    }

    /// Short reason shown when a command can't run in the current environment.
    private func canRunFailureMessage(for command: any VoiceCommand) -> String {
        switch command.id {
        case "terminal": return "Front app isn't a terminal"
        default: return "Can't run that command here"
        }
    }

    /// Short reason shown when a confirmed command threw.
    private func runFailureMessage(for error: Error, command: any VoiceCommand) -> String {
        guard let commandError = error as? CommandError else { return "Command failed" }
        switch commandError {
        case .targetNotFound(let target): return "Couldn't find \(target)"
        case .unsupported: return "Can't do that yet"
        case .injectionRefused: return "Couldn't type into the terminal"
        }
    }

    /// Record an executed command to open history with route "command" (reusing
    /// HistoryStore). Never called for a cancelled/timed-out command.
    private func recordCommandHistory(_ pending: PendingCommand) {
        guard settings.historyEnabled else { return }
        let id = currentEntryID ?? UUID().uuidString
        let audioFile = settings.keepAudio ? "\(id).wav" : nil
        HistoryStore.append(HistoryEntry(
            id: id,
            date: recordStartDate,
            rawTranscript: pending.utterance,
            finalOutput: pending.summary,
            route: "command",
            app: pending.snapshot.frontmostApp,
            bundleID: pending.snapshot.bundleID,
            durationSeconds: Date().timeIntervalSince(recordStartDate),
            engineID: "SpeechAnalyzer",
            audioFile: audioFile
        ))
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
        let undoItem = NSMenuItem(title: "Undo Last Paste", action: #selector(undoLastPaste), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command, .option]
        undoItem.target = self
        menu.addItem(undoItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        let permissionsItem = NSMenuItem(title: "Welcome & Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Sotto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )

        item.menu = menu
        statusItem = item
        statusMenuItem = status

        // The menu bar can silently hide our icon when it's full; surface that in
        // the welcome window rather than leaving the user wondering where Sotto
        // went. Deferred a tick so AppKit has finished laying out the status bar.
        DispatchQueue.main.async { [weak self] in self?.logIfStatusItemHidden() }
    }

    private func logIfStatusItemHidden() {
        guard let statusItem, !statusItem.isVisible else { return }
        NSLog("Sotto: menu bar is full — macOS is hiding Sotto's status icon. ⌥Space still works without it.")
    }

    /// Shared onboarding presentation: wires the "guide seen" persistence and the
    /// hidden-icon check into every entry point (first launch + on-demand menu item).
    private func showOnboardingWindow() {
        windows.showOnboarding(
            onDone: { [weak self] in self?.settings.completedOnboardingGuide = true },
            onOpenSettings: { [weak self] in guard let self else { return }; self.windows.showSettings(settings: self.settings) },
            statusItemHidden: { [weak self] in self?.statusItem?.isVisible == false }
        )
    }

    /// Restore the raw (uncleaned) transcript from the last paste to clipboard.
    @objc private func undoLastPaste() {
        guard let raw = lastRawTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
        setStatus("Raw transcript restored.")
    }

    @objc private func openSettings() {
        guard phase == .idle else { setStatus("Finish dictating first — then open Settings."); return }
        windows.showSettings(settings: settings)
    }

    /// Reopen the onboarding/permissions window — a path back after a revocation,
    /// and how to revisit the "how to dictate" guide on demand.
    @objc private func openPermissions() {
        guard phase == .idle else { setStatus("Finish dictating first — then open Settings."); return }
        showOnboardingWindow()
    }

    /// GET the latest GitHub release and report newer/up-to-date/error via NSAlert.
    /// Only ever runs on this explicit click — no background/timer checks, no
    /// phoning home at launch (DESIGN.md privacy identity).
    @objc private func checkForUpdates() {
        guard phase == .idle else { setStatus("Finish dictating first — then check for updates."); return }
        UpdateChecker.checkForUpdates()
    }

    /// Don't let Settings/Permissions/Updates open during an active dictation:
    /// activating Sotto's window would redirect the eventual ⌘V into it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openSettings)
            || menuItem.action == #selector(openPermissions)
            || menuItem.action == #selector(checkForUpdates) {
            return phase == .idle
        }
        if menuItem.action == #selector(undoLastPaste) {
            return lastRawTranscript != nil
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
        // Check if we have Accessibility trust WITHOUT prompting (to avoid repeat dialogs).
        // If not trusted, show onboarding window which has the permissions guide.
        guard !AXIsProcessTrusted() else { return }

        // Permission not granted. Show onboarding so user can see the instructions.
        NSLog("Sotto: Accessibility permission required. Opening permissions guide.")
        showOnboardingWindow()
    }

    // MARK: Reprocessing (for history re-transcription)

    /// Re-transcribe a WAV from history and post-process it.
    /// Returns (rawTranscript, cleanedOutput, route) or nil if the audio file is missing.
    func reprocessEntry(withID entryID: String) async -> (raw: String, cleaned: String, route: String)? {
        let audioURL = HistoryStore.audioURL(forID: entryID)
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }

        do {
            let inputFile = try AVAudioFile(forReading: audioURL)
            let format = inputFile.processingFormat
            let engine = SpeechAnalyzerEngine()

            try await engine.beginSession()

            let frameSize = 4096
            let totalFrames = Int(inputFile.length)
            var currentFrame = 0

            while currentFrame < totalFrames {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameSize)) else { break }
                let framesToRead = min(frameSize, totalFrames - currentFrame)
                try inputFile.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
                engine.append(buffer)
                currentFrame += framesToRead
            }

            let rawTranscript = try await engine.finishSession()
            let rewritten = vocabulary.rewrite(rawTranscript)

            let smartAvailable = SmartProcessor.isAvailable && settings.smartCleanupEnabled
            let outcome = await pipeline.run(
                text: rewritten,
                context: ContextSnapshot(),  // Empty context for reprocessing
                shiftHeld: false,  // Reprocessing defaults to smart route
                smartAvailable: smartAvailable,
                smart: smart,
                raw: rawProcessor
            )

            switch outcome {
            case .paste(let text, let route):
                return (raw: rawTranscript, cleaned: text, route: route)
            case .transformFailed:
                return (raw: rawTranscript, cleaned: rewritten, route: "raw")
            }
        } catch {
            NSLog("Reprocess error: \(error)")
            return nil
        }
    }
}
