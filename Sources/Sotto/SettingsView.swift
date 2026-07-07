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

            // Agents lives here as a section, deliberately NOT a fourth tab — the
            // whole point is that Sotto stays a three-tab app (superwhisper analysis).
            Section {
                Toggle("Voice replies to coding agents", isOn: $settings.agentRepliesEnabled)
                LabeledContent("Claude Code plugin") {
                    Button("Install instructions…") {
                        if let url = URL(string: "https://github.com/manateeit/sotto/tree/main/integrations/claude-code") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Speak to Claude Code hands-free: when the agent stops or asks, Sotto pops up, you talk, and your words go back as its next input — on-device, and it never runs anything on its own.")
                    .font(.caption).foregroundStyle(.secondary)
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

            Section {
                Toggle("Clipboard history", isOn: $settings.clipboardHistoryEnabled)
            } footer: {
                Text("Save what you copy (⌘C) to a separate, local-only history — never sent anywhere. Skips items marked secret by password managers; keeps the last \(ClipboardHistoryStore.maxCount) clips.")
                    .font(.caption).foregroundStyle(.secondary)
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

/// Small color-coded pill for a history entry's route (dictate / transform / raw).
private struct RouteBadge: View {
    let route: String

    private var color: Color {
        switch route {
        case "transform": return .purple
        case "raw": return .gray
        default: return .blue
        }
    }

    var body: some View {
        Text(route.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

private enum HistorySource: Hashable { case voice, clipboard }

private struct HistoryTab: View {
    @State private var source: HistorySource = .voice
    @State private var entries: [HistoryEntry] = []
    @State private var reprocessingID: String?
    @State private var reprocessResult: (raw: String, cleaned: String, route: String)?
    @State private var showReprocessAlert = false
    @State private var query = ""
    /// Entry ids currently showing the raw (uncleaned) transcript instead of the
    /// cleaned output. Both are already stored on every entry.
    @State private var showRawIDs: Set<String> = []

    /// Entries after the search filter, favorites already pinned to the top by reload().
    private var shown: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.finalOutput.lowercased().contains(q)
                || $0.rawTranscript.lowercased().contains(q)
                || ($0.app?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("", selection: $source) {
                Text("Voice").tag(HistorySource.voice)
                Text("Clipboard").tag(HistorySource.clipboard)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if source == .clipboard {
                ClipboardHistoryList()
            } else {
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts…", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            List(shown) { entry in
                let showingRaw = showRawIDs.contains(entry.id)
                HStack(spacing: 8) {
                    Button(action: { toggleFavorite(entry) }) {
                        Image(systemName: entry.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(entry.isFavorite ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(entry.isFavorite ? "Unstar" : "Star (pin to top)")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(showingRaw ? entry.rawTranscript : entry.finalOutput).lineLimit(2)
                        HStack(spacing: 6) {
                            RouteBadge(route: entry.route)
                            Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            if let app = entry.app {
                                Text(app).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { copy(showingRaw ? entry.rawTranscript : entry.finalOutput) }
                    Spacer()
                    // Raw ⇄ Cleaned: only meaningful when the two actually differ.
                    if entry.rawTranscript != entry.finalOutput {
                        Button(showingRaw ? "Cleaned" : "Raw") {
                            if showingRaw { showRawIDs.remove(entry.id) } else { showRawIDs.insert(entry.id) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .help("Toggle raw transcript vs cleaned output")
                    }
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
            if shown.isEmpty && !query.isEmpty {
                Text("No transcripts match “\(query)”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 8)
            }
            } // end else (voice source)
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

/// The Clipboard side of the History tab. Plain text clips, newest-first, with
/// search + click-to-copy + delete. No star/reprocess/Raw-Cleaned — those are
/// voice-only. Reads the SEPARATE ClipboardHistoryStore.
private struct ClipboardHistoryList: View {
    @State private var entries: [ClipboardEntry] = []
    @State private var query = ""

    private var shown: [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.text.lowercased().contains(q) || ($0.sourceApp?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Click a clip to copy it. Local-only; passwords skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete All", role: .destructive) {
                    ClipboardHistoryStore.deleteAll()
                    entries = []
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clips…", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            if entries.isEmpty {
                Text("No clips yet. Copy something (⌘C) and it'll appear here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 12)
            }
            List(shown) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            if let app = entry.sourceApp {
                                Text(app).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { copy(entry.text) }
                    Spacer()
                    Button(action: { deleteEntry(entry) }) {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this clip")
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .sottoSettingsDidShow)) { _ in reload() }
    }

    private func reload() { entries = Array(ClipboardHistoryStore.load().reversed()) }

    private func copy(_ text: String) {
        // Suppressed so re-copying a clip isn't re-captured as a new entry.
        (NSApplication.shared.delegate as? AppDelegate)?.copyToPasteboardSuppressed(text)
    }

    private func deleteEntry(_ entry: ClipboardEntry) {
        ClipboardHistoryStore.delete(id: entry.id)
        reload()
    }
}
