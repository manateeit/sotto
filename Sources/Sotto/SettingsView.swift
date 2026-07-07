import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    /// Posted after the vocabulary editor saves, so the AppDelegate reloads it.
    static let sottoVocabularyChanged = Notification.Name("SottoVocabularyChanged")
    /// Posted while the hotkey recorder is capturing, so the AppDelegate frees the
    /// global hotkey (and re-registers when capture ends).
    static let sottoHotkeyCaptureBegan = Notification.Name("SottoHotkeyCaptureBegan")
    static let sottoHotkeyCaptureEnded = Notification.Name("SottoHotkeyCaptureEnded")
    /// Posted every time the Settings window is presented, so tabs backed by
    /// on-disk data (History) reload — the window is cached and reused, so
    /// `.onAppear` alone won't re-fire on reopen.
    static let sottoSettingsDidShow = Notification.Name("SottoSettingsDidShow")
}

/// The one settings window (DESIGN.md §2). Three spartan tabs.
struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            VocabularyTab()
                .tabItem { Label("Vocabulary", systemImage: "textformat") }
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 500, height: 480)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: Settings
    private let retentionOptions = [7, 30, 90, 0] // 0 = keep forever

    var body: some View {
        Form {
            Section {
                LabeledContent("Dictation shortcut") {
                    VStack(alignment: .trailing, spacing: 2) {
                        HotkeyRecorder(settings: settings)
                        if let error = settings.hotkeyError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            } footer: {
                Text("Tap to toggle recording, or hold for push-to-talk. Hold ⇧ on stop to paste the raw transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play start / stop / cancel sounds", isOn: $settings.soundsEnabled)
                Toggle("Smart cleanup (Apple Intelligence)", isOn: $settings.smartCleanupEnabled)
                Toggle("Voice commands (say “Sotto, …”)", isOn: $settings.voiceCommandsEnabled)
                Toggle("Launch Sotto at login", isOn: $settings.launchAtLogin)
            }

            Section("History") {
                Toggle("Save dictation history", isOn: $settings.historyEnabled)
                Toggle("Keep audio (WAV)", isOn: $settings.keepAudio)
                Picker("Keep history for", selection: $settings.historyRetentionDays) {
                    ForEach(retentionOptions, id: \.self) { days in
                        Text(days == 0 ? "Forever" : "\(days) days").tag(days)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click to record a new global shortcut. Captures the next key-down via a local
/// event monitor (the settings window is key, so a local monitor sees it).
private struct HotkeyRecorder: View {
    @ObservedObject var settings: Settings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Press a shortcut…" : HotkeyFormatter.displayString(
                keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers))
                .frame(minWidth: 120)
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        settings.hotkeyError = nil
        // Free the global hotkey so pressing the current combo is captured, not fired.
        NotificationCenter.default.post(name: .sottoHotkeyCaptureBegan, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = HotkeyFormatter.carbonModifiers(from: event.modifierFlags)
            // Require at least one modifier so we don't grab bare keys globally.
            guard mods != 0 else { return nil }
            settings.hotkeyKeyCode = Int(event.keyCode)
            settings.hotkeyModifiers = mods
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .sottoHotkeyCaptureEnded, object: nil)
    }
}

private struct VocabularyTab: View {
    @State private var literalRules: [EditableRule] = []
    @State private var regexRuleCount = 0
    @State private var importMessage: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Replace known misrecognitions before cleanup. Applies in order.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($literalRules) { $rule in
                    HStack {
                        TextField("spoken", text: $rule.pattern)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("replacement", text: $rule.replacement)
                    }
                }
                .onDelete { literalRules.remove(atOffsets: $0) }
            }
            if regexRuleCount > 0 {
                Text("\(regexRuleCount) regex rule(s) are preserved but editable only in vocabulary.json.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Regex rules are supported in vocabulary.json directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let msg = importMessage {
                Text(msg).font(.caption).foregroundStyle(.green)
            }
            HStack {
                Button("Add") { literalRules.append(EditableRule()) }
                Button("Import…") { importVocabulary() }
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear(perform: load)
    }

    private func load() {
        let all = VocabularyStore.loadCreatingExampleIfNeeded().rules
        literalRules = all.filter { !$0.isRegex }.map {
            EditableRule(pattern: $0.pattern, replacement: $0.replacement)
        }
        regexRuleCount = all.filter { $0.isRegex }.count
    }

    private func save() {
        // Preserve the file's regex rules; only literal rules are edited here.
        let preservedRegex = VocabularyStore.loadCreatingExampleIfNeeded().rules.filter { $0.isRegex }
        let edited = literalRules.filter { !$0.pattern.isEmpty }.map {
            VocabularyRewriter.Rule($0.pattern, $0.replacement, isRegex: false)
        }
        VocabularyStore.save(VocabularyRewriter(rules: edited + preservedRegex))
        NotificationCenter.default.post(name: .sottoVocabularyChanged, object: nil)
    }

    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .text, .commaSeparatedText]
        panel.message = "Import vocabulary from a competitor (JSON, CSV, or text file)"
        panel.prompt = "Import"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            if let imported = VocabularyImporter.importVocabulary(from: url) {
                let current = VocabularyStore.loadCreatingExampleIfNeeded()
                let merged = VocabularyImporter.merge(current, with: imported)
                VocabularyStore.save(merged)

                // Reload and show status
                literalRules = merged.rules.filter { !$0.isRegex }.map {
                    EditableRule(pattern: $0.pattern, replacement: $0.replacement)
                }
                regexRuleCount = merged.rules.filter { $0.isRegex }.count
                importMessage = "Imported \(imported.count) rule(s)"
                NotificationCenter.default.post(name: .sottoVocabularyChanged, object: nil)

                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    importMessage = nil
                }
            }
        }
    }
}

private struct EditableRule: Identifiable {
    let id = UUID()
    var pattern: String = ""
    var replacement: String = ""
}

private struct HistoryTab: View {
    @State private var entries: [HistoryEntry] = []
    @State private var reprocessingID: String?
    @State private var reprocessResult: (raw: String, cleaned: String, route: String)?
    @State private var showReprocessAlert = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Click an entry to copy it. Star to pin it to the top.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.jsonlURL])
                }
                Button("Delete All", role: .destructive) {
                    HistoryStore.deleteAll()
                    entries = []
                }
            }
            List(entries) { entry in
                HStack(spacing: 8) {
                    Button(action: { toggleFavorite(entry) }) {
                        Image(systemName: entry.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(entry.isFavorite ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(entry.isFavorite ? "Unstar" : "Star (pin to top)")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.finalOutput).lineLimit(2)
                        HStack {
                            Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            if let app = entry.app {
                                Text(app).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.route).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { copy(entry.finalOutput) }
                    Spacer()
                    if entry.audioFile != nil {
                        Button(action: { reprocess(entry) }) {
                            if reprocessingID == entry.id {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Text("Reprocess")
                            }
                        }
                        .disabled(reprocessingID != nil)
                    }
                    Button(action: { deleteEntry(entry) }) {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this entry")
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .sottoSettingsDidShow)) { _ in
            reload()
        }
        .alert("Reprocessed Transcript", isPresented: $showReprocessAlert) {
            Button("Copy Cleaned", action: {
                if let result = reprocessResult {
                    copy(result.cleaned)
                    showReprocessAlert = false
                }
            })
            Button("Copy Raw", action: {
                if let result = reprocessResult {
                    copy(result.raw)
                    showReprocessAlert = false
                }
            })
            Button("Close") { showReprocessAlert = false }
        } message: {
            if let result = reprocessResult {
                Text(result.cleaned)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Newest-first, with starred entries pinned to the top (stable within groups).
    private func reload() {
        let all = Array(HistoryStore.load().reversed())
        entries = all.filter { $0.isFavorite } + all.filter { !$0.isFavorite }
    }

    private func toggleFavorite(_ entry: HistoryEntry) {
        HistoryStore.setFavorite(id: entry.id, !entry.isFavorite)
        reload()
    }

    private func deleteEntry(_ entry: HistoryEntry) {
        HistoryStore.delete(id: entry.id)
        reload()
    }

    private func reprocess(_ entry: HistoryEntry) {
        reprocessingID = entry.id
        Task {
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                let result = await delegate.reprocessEntry(withID: entry.id)
                await MainActor.run {
                    reprocessingID = nil
                    reprocessResult = result
                    showReprocessAlert = true
                }
            }
        }
    }
}
