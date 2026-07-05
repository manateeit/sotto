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
        .frame(width: 480, height: 420)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: Settings
    private let retentionOptions = [7, 30, 90, 0] // 0 = keep forever

    var body: some View {
        Form {
            LabeledContent("Dictation shortcut") {
                VStack(alignment: .leading, spacing: 2) {
                    HotkeyRecorder(settings: settings)
                    if let error = settings.hotkeyError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Text("Tap to toggle recording, or hold for push-to-talk. Hold ⇧ on stop to paste the raw transcript.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Toggle("Play start / stop / cancel sounds", isOn: $settings.soundsEnabled)
            Toggle("Smart cleanup (Apple Intelligence)", isOn: $settings.smartCleanupEnabled)
            Toggle("Launch Sotto at login", isOn: $settings.launchAtLogin)

            Divider()
            Toggle("Save dictation history", isOn: $settings.historyEnabled)
            Toggle("Keep audio (WAV)", isOn: $settings.keepAudio)
            Picker("Keep history for", selection: $settings.historyRetentionDays) {
                ForEach(retentionOptions, id: \.self) { days in
                    Text(days == 0 ? "Forever" : "\(days) days").tag(days)
                }
            }
        }
        .padding()
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
            HStack {
                Button("Add") { literalRules.append(EditableRule()) }
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
}

private struct EditableRule: Identifiable {
    let id = UUID()
    var pattern: String = ""
    var replacement: String = ""
}

private struct HistoryTab: View {
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Click an entry to copy it.").font(.caption).foregroundStyle(.secondary)
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
            }
        }
        .padding()
        .onAppear { entries = HistoryStore.load().reversed() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
