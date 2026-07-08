import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation

/// Whether an Esc should discard the recording outright, or first arm a confirm.
/// Pure + unit-tested. Short recordings discard instantly (frictionless common
/// path); long ones require a second, armed Esc so a stray keypress can't nuke a
/// long dictation.
enum CancelPolicy {
    static func discardsImmediately(elapsed: TimeInterval, armed: Bool, threshold: TimeInterval) -> Bool {
        armed || elapsed < threshold
    }
}

/// Menu-bar-only orchestrator for the dictation loop:
/// hotkey (push-to-talk or toggle) → record + HUD → SpeechAnalyzer → paste.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyManager()
    private let recorder = Recorder()
    private let engine: TranscriptionEngine = SpeechAnalyzerEngine()
    private var vocabulary = VocabularyRewriter.empty
    private var smart = SmartProcessor()
    private let rawProcessor: PostProcessor = Passthrough()
    /// The external-model cleanup processor (Ollama, later cloud). nil unless the
    /// user picked a provider — so with the default `.none` NO network-capable
    /// object is ever constructed. Built only in `reloadProvider()`.
    private var llm: (any PostProcessor)?
    private let pipeline = ProcessingPipeline()
    // M6 command subsystem: parse (FM, behind the CommandParsing seam) → human
    // confirm → dispatch through the VoiceCommand seam. The FM is a PARSER ONLY.
    private let commandParser: any CommandParsing = SmartCommandParser()
    private let commandPipeline = CommandPipeline()
    private lazy var commandRegistry = CommandRegistry(injector: injector)
    private let clipboard = ClipboardMonitor()
    /// Fingerprints Sotto's own pasteboard writes so the clipboard-history monitor
    /// ignores them (self-paste loop guard). Shared by the injector and the monitor.
    private let clipboardWriteGuard = ClipboardWriteGuard()
    private lazy var injector = OutputInjector(writeGuard: clipboardWriteGuard)
    private lazy var clipboardMonitor = ClipboardHistoryMonitor(writeGuard: clipboardWriteGuard)
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
    /// The dynamically-rebuilt History submenu in the menu-bar dropdown.
    private var historyMenu: NSMenu?
    /// The dynamically-rebuilt Clipboard-history submenu.
    private var clipboardMenu: NSMenu?

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
    /// A long recording's first Esc arms discard (rather than discarding outright);
    /// a second Esc within the window confirms. Protects long dictations from a
    /// stray Esc while keeping short-cancel frictionless.
    private var cancelArmed = false
    private var cancelDisarmWork: DispatchWorkItem?
    // ponytail: 30s is the "long enough to be worth protecting" line; 4s is how long
    // the armed window stays open before reverting to plain recording.
    private static let cancelConfirmThreshold: TimeInterval = 30
    private static let cancelArmWindow: TimeInterval = 4
    /// Set while capturing a spoken reply for a coding agent (sotto://reply). When
    /// non-nil, the finished transcript is written here as text instead of pasted —
    /// it never executes anything.
    private var replyResponsePath: String?
    private var replyAgentName = "your agent"

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

        // Resume clipboard capture only if it was left on AND the disclosure was
        // accepted — so a wrongly-persisted enabled flag can never silently start
        // capture without informed consent.
        if settings.clipboardHistoryEnabled && settings.clipboardDisclosureSeen {
            clipboardMonitor.start()
        }

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

        // Start/stop clipboard capture live when the opt-in toggle flips (and show
        // the one-time disclosure the first time it's enabled).
        settings.$clipboardHistoryEnabled
            .dropFirst()
            .sink { [weak self] enabled in self?.applyClipboardHistory(enabled: enabled) }
            .store(in: &cancellables)

        // Keep the cleanup processors' domain bias in sync as the user edits it.
        settings.$domainProfile
            .sink { [weak self] profile in
                guard let self else { return }
                self.smart.domainProfile = profile
                self.reloadProvider() // rebuild the external processor with the new bias
            }
            .store(in: &cancellables)

        // Build/tear down the external-model processor live as the user changes the
        // provider or model. Flipping back to "none" sets llm = nil (teardown), so
        // the network path becomes unreachable again without a restart.
        settings.$modelProvider.dropFirst()
            .sink { [weak self] _ in self?.applyProviderChange() }
            .store(in: &cancellables)
        settings.$ollamaModel.dropFirst()
            .sink { [weak self] _ in self?.reloadProvider() }
            .store(in: &cancellables)
        settings.$cloudModel.dropFirst()
            .sink { [weak self] _ in self?.reloadProvider() }
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
        smart.domainProfile = settings.domainProfile // survive the processor recreate
        reloadProvider() // the external processor uses the same vocab + domain bias
    }

    /// Build (or tear down) the external-model processor. THE ONLY site that
    /// constructs a network-capable backend — and only when a provider is selected.
    /// With `provider == .none` (default) `llm` stays nil and nothing can egress.
    private func reloadProvider() {
        let provider = ModelProvider(rawValue: settings.modelProvider) ?? .none
        // Cloud never activates without the one-time disclosure accepted (defense in
        // depth: a wrongly-persisted provider can't silently start egressing).
        if provider.isCloud && !settings.cloudDisclosureSeen { llm = nil; updateCloudIndicator(); return }
        let keyPresent = provider.keyAccount.map { KeychainStore.get($0) != nil } ?? false
        guard let backend = ProviderFactory.make(provider: provider, ollamaModel: settings.ollamaModel,
                                                 cloudModel: settings.cloudModel, cloudKeyPresent: keyPresent) else {
            llm = nil
            updateCloudIndicator()
            return
        }
        llm = LLMPostProcessor(backend: backend,
                               vocabTerms: vocabulary.hintTerms,
                               domainProfile: settings.domainProfile)
        updateCloudIndicator()
    }

    /// Rebuild the provider from settings on demand (e.g. after the Settings key
    /// field writes to the Keychain, which has no @Published signal).
    func refreshProviderFromSettings() {
        reloadProvider()
        reflectReadyStatus()
    }

    /// Always-visible egress cue (critique B6): a "☁" on the menu-bar item whenever a
    /// CLOUD provider is actively running cleanup, so the user sees text is leaving
    /// the machine without opening the menu. Ollama (loopback) shows no cloud glyph.
    private func updateCloudIndicator() {
        let cloudActive = (ModelProvider(rawValue: settings.modelProvider)?.isCloud ?? false) && llm != nil
        statusItem?.button?.title = cloudActive ? " ☁" : ""
        statusItem?.button?.toolTip = cloudActive
            ? "Sotto — ⚠︎ cloud cleanup: \(settings.modelProvider) (your key)"
            : "Sotto — ⌥Space to dictate (tap = toggle, hold = push-to-talk)"
    }

    /// Handle a provider change from Settings: gate cloud behind the one-time
    /// disclosure, else just rebuild.
    private func applyProviderChange() {
        let provider = ModelProvider(rawValue: settings.modelProvider) ?? .none
        if provider.isCloud && !settings.cloudDisclosureSeen {
            showCloudDisclosure()
            return
        }
        reloadProvider()
        reflectReadyStatus()
    }

    private func showCloudDisclosure() {
        let alert = NSAlert()
        alert.messageText = "Send cleanup to the cloud?"
        alert.informativeText = """
        This turns on Sotto's only outbound cloud connection. Your dictated text — \
        and, when you dictate over a selection, the selected text too — will be sent to \
        \(settings.modelProvider) using your own API key. Sotto adds no account, logging, \
        or telemetry of its own. Whether this meets HIPAA/ZDR depends entirely on your \
        agreement with the provider; Sotto cannot verify or guarantee it. The default \
        build makes zero network calls — you're opting into this one.
        """
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.cloudDisclosureSeen = true
            reloadProvider()
            reflectReadyStatus()
        } else {
            // Revert on the next runloop turn (the @Published-reentrancy fix, as in
            // the clipboard disclosure) so declining actually leaves it on-device.
            DispatchQueue.main.async { [weak self] in self?.settings.modelProvider = ModelProvider.none.rawValue }
        }
    }

    /// The cleanup processor in force: the external model if configured, else the
    /// on-device SmartProcessor. When `llm` is nil this is a network-silent value,
    /// so even a routing bug can't reach a socket.
    private var activeSmart: any PostProcessor { llm ?? smart }

    /// Whether the smart route is available: honored only when the user hasn't
    /// turned cleanup off; a configured provider counts as available.
    private var activeSmartAvailable: Bool {
        guard settings.smartCleanupEnabled else { return false }
        return llm != nil || SmartProcessor.isAvailable
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
        // A configured external provider is always announced — the user must know
        // which model runs cleanup, and (for anything but on-device) where text goes.
        if llm != nil, let provider = ModelProvider(rawValue: settings.modelProvider) {
            if provider.isCloud {
                setStatus("Ready — ⚠︎ Cloud cleanup: \(provider.rawValue) (your key)")
                return
            }
            if provider == .ollama {
                setStatus("Ready — Local model (Ollama)")
                return
            }
        }
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

    // MARK: Agent reply bridge (sotto://reply)

    /// URL-scheme entry point. A coding-agent hook opens `sotto://reply?...` when the
    /// agent stops or asks; we record a spoken reply and hand the transcript back as
    /// text. Opt-in, and it never executes anything.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = ReplyBridge.parse(url) else { continue }
            handleReplyRequest(request)
        }
    }

    private func handleReplyRequest(_ request: ReplyBridge.Request) {
        // Declining still writes an empty response so the agent's hook unblocks
        // immediately instead of polling until its timeout.
        guard settings.agentRepliesEnabled else {
            _ = ReplyBridge.write("", toPath: request.responsePath)
            NSLog("Sotto: ignoring sotto://reply — enable Agents in Settings › General.")
            return
        }
        guard phase == .idle else {
            _ = ReplyBridge.write("", toPath: request.responsePath)
            NSLog("Sotto: busy — ignoring agent reply request.")
            return
        }
        replyResponsePath = request.responsePath
        replyAgentName = request.agent
        startRecording()
    }

    /// The single choke point for leaving reply mode. Writes an empty response (so
    /// the agent's hook unblocks at once) unless the real transcript was already
    /// written, then clears the target so it can NEVER leak into a later dictation.
    /// A no-op when not in reply mode.
    private func clearReplyState(writeEmpty: Bool) {
        guard let path = replyResponsePath else { return }
        if writeEmpty { _ = ReplyBridge.write("", toPath: path) }
        replyResponsePath = nil
    }

    // MARK: Dictation loop

    private func startRecording() {
        guard phase == .idle else { return }
        // A failed start must not leave a reply target armed for the next dictation.
        guard ensureMicrophoneAuthorized() else { clearReplyState(writeEmpty: true); return }

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
        if replyResponsePath != nil {
            hud.show(.reply("Reply → \(replyAgentName) · ⌥Space to send"))
            setStatus("Reply → \(replyAgentName)…")
        } else {
            hud.show(.recording)
            setStatus("Listening… (⌥Space or hold)")
        }
        setRecordingIcon(true)
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
                clearReplyState(writeEmpty: true)
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
        cancelArmed = false
        cancelDisarmWork?.cancel()
        cancelDisarmWork = nil
        hud.update(.transcribing)
        setMenuIcon(.processing)
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

            // Capture-and-clear the reply target up front so it can never leak into a
            // later dictation, whichever branch we take below.
            let replyPath = replyResponsePath
            replyResponsePath = nil

            guard !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                setStatus("No speech detected.")
                hud.hide()
                setMenuIcon(.idle)
                // A reply that transcribed to nothing still unblocks the hook at once.
                if let replyPath { _ = ReplyBridge.write("", toPath: replyPath) }
                return
            }

            // Agent reply (sotto://reply): hand the transcript back as TEXT — never a
            // command, never a paste. Empty context so no transform is attempted; a
            // spoken reply is dictation to the agent, cleaned like any dictation.
            if let replyPath {
                let smartAvailable = activeSmartAvailable
                let outcome = await pipeline.run(text: rewritten, context: ContextSnapshot(),
                                                 shiftHeld: shiftHeld, smartAvailable: smartAvailable,
                                                 smart: activeSmart, raw: rawProcessor)
                let text: String
                if case .paste(let cleaned, _) = outcome { text = cleaned } else { text = rewritten }
                if ReplyBridge.write(text, toPath: replyPath) {
                    setStatus("Sent reply to \(replyAgentName).")
                    flashDoneThenHide()
                } else {
                    showError("Couldn't write reply")
                }
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
            let smartAvailable = activeSmartAvailable
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
                smart: activeSmart,
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
            setMenuIcon(.idle)
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
            setMenuIcon(.idle)
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
            let elapsed = Date().timeIntervalSince(recordStartDate)
            if CancelPolicy.discardsImmediately(elapsed: elapsed, armed: cancelArmed,
                                                threshold: Self.cancelConfirmThreshold) {
                performCancel(playSound: true)
            } else {
                armCancelConfirm(elapsed: elapsed)
            }
        case .idle, .finishing, .confirmingCommand:
            // The confirm phase has its own Esc handler (cancelPendingCommand).
            break
        }
    }

    /// First Esc on a long recording: warn instead of discarding, and keep recording.
    private func armCancelConfirm(elapsed: TimeInterval) {
        cancelArmed = true
        hud.update(.confirmCancel("Esc again to discard \(Int(elapsed))s"))
        let work = DispatchWorkItem { [weak self] in self?.disarmCancelConfirm() }
        cancelDisarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cancelArmWindow, execute: work)
    }

    /// Revert the armed warning back to plain recording (the window lapsed).
    private func disarmCancelConfirm() {
        cancelDisarmWork?.cancel()
        cancelDisarmWork = nil
        guard cancelArmed else { return }
        cancelArmed = false
        if phase == .recording {
            // Revert to the right label — a reply capture must keep its framing.
            hud.update(replyResponsePath != nil
                ? .reply("Reply → \(replyAgentName) · ⌥Space to send")
                : .recording)
        }
    }

    /// Discard the in-flight dictation without transcribing or pasting.
    private func performCancel(playSound: Bool) {
        phase = .finishing
        cancelArmed = false
        cancelDisarmWork?.cancel()
        cancelDisarmWork = nil
        // A cancelled reply writes an empty response so the agent's hook unblocks
        // at once (empty = "no reply", the hook injects nothing).
        clearReplyState(writeEmpty: true)
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
        setMenuIcon(.idle) // the command path left the icon on "processing"
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
        let work = DispatchWorkItem { [weak self] in
            self?.hud.hide()
            self?.setMenuIcon(.idle)
        }
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
            button.image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: "Sotto")
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

        // History submenu — favorites + last 10, each with Copy / Star, without
        // opening Settings. Rebuilt on demand via the menu delegate.
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let historySubmenu = NSMenu(title: "History")
        historySubmenu.delegate = self
        historyItem.submenu = historySubmenu
        historyMenu = historySubmenu
        menu.addItem(historyItem)

        // Clipboard history — a flat click-to-copy list of recent clips (only
        // meaningful when the opt-in feature is on). Rebuilt on demand.
        let clipboardItem = NSMenuItem(title: "Clipboard", action: nil, keyEquivalent: "")
        let clipboardSubmenu = NSMenu(title: "Clipboard")
        clipboardSubmenu.delegate = self
        clipboardItem.submenu = clipboardSubmenu
        clipboardMenu = clipboardSubmenu
        menu.addItem(clipboardItem)

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

    // MARK: History / Clipboard submenus

    /// Rebuild the relevant submenu just before it opens so it always reflects the store.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu { rebuildHistoryMenu(menu) }
        else if menu === clipboardMenu { rebuildClipboardMenu(menu) }
    }

    /// Voice history: favorites pinned on top, then the 10 most recent non-favorites.
    private func rebuildHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let all = Array(HistoryStore.load().reversed()) // newest first
        let favorites = all.filter { $0.isFavorite }
        let recent = Array(all.filter { !$0.isFavorite }.prefix(10))

        if favorites.isEmpty && recent.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            if !favorites.isEmpty {
                menu.addItem(historySectionHeader("Favorites"))
                for entry in favorites { menu.addItem(historyEntryItem(entry)) }
                menu.addItem(.separator())
            }
            menu.addItem(historySectionHeader("Recent"))
            for entry in recent { menu.addItem(historyEntryItem(entry)) }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open in Settings…", action: #selector(openVoiceHistorySettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    /// Clipboard history: favorites pinned on top, then the 10 most recent
    /// non-favorites. Mirrors the voice-history submenu (Copy + Star/Unstar per row).
    private func rebuildClipboardMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if !settings.clipboardHistoryEnabled {
            let off = NSMenuItem(title: "Clipboard history is off — enable in Settings", action: nil, keyEquivalent: "")
            off.isEnabled = false
            menu.addItem(off)
        } else {
            let all = Array(ClipboardHistoryStore.load().reversed()) // newest first
            let favorites = all.filter { $0.isFavorite }
            let recent = Array(all.filter { !$0.isFavorite }.prefix(10))

            if favorites.isEmpty && recent.isEmpty {
                let empty = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                if !favorites.isEmpty {
                    menu.addItem(historySectionHeader("Favorites"))
                    for entry in favorites { menu.addItem(clipboardEntryItem(entry)) }
                    menu.addItem(.separator())
                }
                menu.addItem(historySectionHeader("Recent"))
                for entry in recent { menu.addItem(clipboardEntryItem(entry)) }
            }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open in Settings…", action: #selector(openClipboardSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    /// One clipboard row: a star prefix if favorited, a truncated preview, and a
    /// submenu offering Copy and Star/Unstar right there.
    private func clipboardEntryItem(_ entry: ClipboardEntry) -> NSMenuItem {
        let prefix = entry.isFavorite ? "★ " : ""
        let item = NSMenuItem(title: prefix + historyPreview(entry.text), action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let copy = NSMenuItem(title: "Copy", action: #selector(copyClipboardItem(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = entry
        sub.addItem(copy)

        let star = NSMenuItem(title: entry.isFavorite ? "Unstar" : "Star",
                              action: #selector(toggleClipboardFavorite(_:)), keyEquivalent: "")
        star.target = self
        star.representedObject = entry
        sub.addItem(star)

        item.submenu = sub
        return item
    }

    @objc private func copyClipboardItem(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ClipboardEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        // Stamp so re-copying a clip isn't re-captured as a fresh entry.
        clipboardWriteGuard.markOwnWrite(changeCount: NSPasteboard.general.changeCount)
        setStatus("Copied from clipboard.")
    }

    @objc private func toggleClipboardFavorite(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ClipboardEntry else { return }
        ClipboardHistoryStore.setFavorite(id: entry.id, !entry.isFavorite)
    }

    @objc private func openClipboardSettings() { openHistorySettings(source: .clipboard) }
    @objc private func openVoiceHistorySettings() { openHistorySettings(source: .voice) }

    /// Open Settings straight to the History tab with the given Voice/Clipboard side.
    private func openHistorySettings(source: HistorySource) {
        guard phase == .idle else { setStatus("Finish dictating first — then open Settings."); return }
        windows.showSettings(settings: settings, tab: .history, source: source)
    }

    /// Put text on the clipboard as a Sotto-originated write, so the clipboard
    /// monitor won't re-capture it. Used by the Settings clipboard list.
    func copyToPasteboardSuppressed(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        clipboardWriteGuard.markOwnWrite(changeCount: NSPasteboard.general.changeCount)
    }

    // MARK: Clipboard history lifecycle

    /// Start/stop the capture monitor as the opt-in toggle flips. On first enable,
    /// gate behind a one-time disclosure of what a clipboard log does and does not
    /// protect.
    private func applyClipboardHistory(enabled: Bool) {
        guard enabled else { clipboardMonitor.stop(); return }
        if settings.clipboardDisclosureSeen {
            clipboardMonitor.start()
        } else {
            showClipboardDisclosure()
        }
    }

    private func showClipboardDisclosure() {
        let alert = NSAlert()
        alert.messageText = "Turn on clipboard history?"
        alert.informativeText = """
        Sotto will save the text of things you copy to a private, on-device history — \
        separate from your voice history and never sent anywhere. It skips items marked \
        secret by password managers, but some passwords and tokens aren't marked and \
        would be stored. Only the last \(ClipboardHistoryStore.maxCount) clips are kept — \
        except ones you star, which stay until you unstar or delete them. You can clear \
        them anytime.
        """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.clipboardDisclosureSeen = true
            clipboardMonitor.start()
        } else {
            // Revert on the NEXT runloop turn, not here: we're inside the sink that
            // observes this very @Published property, and @Published broadcasts in
            // willSet (before storage commits), so a reentrant write now would be
            // clobbered by the outer `= true` setter finishing last — silently
            // leaving the feature ON after the user declined (consent bypass).
            DispatchQueue.main.async { [weak self] in self?.settings.clipboardHistoryEnabled = false }
        }
    }

    private func historySectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// One history row: a star prefix if favorited, a truncated preview, and a
    /// submenu offering Copy and Star/Unstar right there.
    private func historyEntryItem(_ entry: HistoryEntry) -> NSMenuItem {
        let prefix = entry.isFavorite ? "★ " : ""
        let item = NSMenuItem(title: prefix + historyPreview(entry.finalOutput), action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let copy = NSMenuItem(title: "Copy", action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = entry
        sub.addItem(copy)

        let star = NSMenuItem(title: entry.isFavorite ? "Unstar" : "Star",
                              action: #selector(toggleHistoryFavorite(_:)), keyEquivalent: "")
        star.target = self
        star.representedObject = entry
        sub.addItem(star)

        item.submenu = sub
        return item
    }

    /// Single-line preview, collapsed and truncated for a menu row.
    private func historyPreview(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 48 ? String(oneLine.prefix(47)) + "…" : oneLine
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.finalOutput, forType: .string)
        clipboardWriteGuard.markOwnWrite(changeCount: NSPasteboard.general.changeCount)
        setStatus("Copied from history.")
    }

    @objc private func toggleHistoryFavorite(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        HistoryStore.setFavorite(id: entry.id, !entry.isFavorite)
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
        clipboardWriteGuard.markOwnWrite(changeCount: NSPasteboard.general.changeCount)
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
            || menuItem.action == #selector(checkForUpdates)
            || menuItem.action == #selector(openClipboardSettings)
            || menuItem.action == #selector(openVoiceHistorySettings) {
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

    /// The menu-bar icon mirrors the dictation lifecycle so state is glanceable
    /// without the pill: idle = old-style mic, recording = filled mic badge,
    /// processing = waveform.
    private enum MenuIcon { case idle, recording, processing }

    private func setMenuIcon(_ icon: MenuIcon) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch icon {
        case .idle: symbol = "music.mic"
        case .recording: symbol = "music.mic.circle.fill"
        case .processing: symbol = "waveform"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sotto")
        button.image?.isTemplate = true
    }

    private func setRecordingIcon(_ recording: Bool) {
        setMenuIcon(recording ? .recording : .idle)
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

            let smartAvailable = activeSmartAvailable
            let outcome = await pipeline.run(
                text: rewritten,
                context: ContextSnapshot(),  // Empty context for reprocessing
                shiftHeld: false,  // Reprocessing defaults to smart route
                smartAvailable: smartAvailable,
                smart: activeSmart,
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
