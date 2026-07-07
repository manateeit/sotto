import AppKit
import SwiftUI

/// What the HUD is currently showing. Colour language from DESIGN.md:
/// recording = red, processing = blue, done = green. M6 adds command confirmation =
/// violet (a distinct state: the app is waiting on the human, not working).
enum HUDState: Equatable {
    case recording
    case transcribing
    case done
    case error(String)
    /// Awaiting an explicit confirm for a parsed voice command. The associated value
    /// is the full pill text (summary + "⌥Space to run · Esc to cancel").
    case confirming(String)

    var dotColor: Color {
        switch self {
        case .recording: return .red
        case .transcribing: return .blue
        case .done: return .green
        case .error: return .yellow
        case .confirming: return HUDState.violet
        }
    }

    /// The command-confirmation accent (violet), distinct from the record/process/done
    /// language so a pending action never reads as "working".
    static let violet = Color(red: 0.55, green: 0.35, blue: 0.95)

    var label: String {
        switch self {
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .done: return "Done"
        case .error(let message): return message
        case .confirming(let text): return text
        }
    }

    /// Whether the waveform should react to live audio.
    var isListening: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// Observable backing the HUD view. Main-actor confined — all mutations happen on
/// the main thread.
@MainActor
final class HUDModel: ObservableObject {
    static let barCount = 21

    @Published var state: HUDState = .recording
    @Published var levels: [Float] = Array(repeating: 0, count: HUDModel.barCount)

    /// Push one audio level sample (0...1) onto the scrolling waveform.
    func pushLevel(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append(min(max(level, 0), 1))
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: HUDModel.barCount)
    }
}

/// The compact recording pill (DESIGN.md §2: one pill, no mini/maxi dual window).
struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            StateDot(state: model.state)
            Waveform(levels: model.levels, listening: model.state.isListening)
                .frame(width: 120, height: 22)
            Text(model.state.label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sotto")
        .accessibilityValue(model.state.label)
        .accessibilityHint(accessibilityHint(for: model.state))
    }

    private func accessibilityHint(for state: HUDState) -> String {
        switch state {
        case .recording:
            return "Recording. Speak into the microphone."
        case .transcribing:
            return "Processing your speech."
        case .done:
            return "Transcription complete. Text has been pasted."
        case .error(let msg):
            return "Error: \(msg)"
        case .confirming:
            return "Voice command pending. Press Option-Space to execute or Escape to cancel."
        }
    }
}

private struct StateDot: View {
    let state: HUDState
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state.dotColor)
            .frame(width: 10, height: 10)
            .opacity(state.isListening && pulse ? 0.4 : 1)
            .animation(state.isListening
                ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

private struct Waveform: View {
    let levels: [Float]
    let listening: Bool

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 2
            let barWidth = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(listening ? Color.red.opacity(0.85) : Color.secondary.opacity(0.5))
                        .frame(
                            width: barWidth,
                            height: max(2, CGFloat(level) * geo.size.height)
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: levels)
        }
    }
}

/// Owns the floating pill window. Show it on record, hide on completion/cancel.
@MainActor
final class HUDController {
    let model = HUDModel()
    private var panel: NSPanel?

    func show(_ state: HUDState) {
        model.state = state
        if state.isListening { model.resetLevels() }
        let panel = panel ?? makePanel()
        self.panel = panel
        // Re-fit before ordering front so longer labels (error messages) don't clip
        // — the pill's Text uses .fixedSize(), so it never truncates.
        resizeToFit(panel)
        // orderFrontRegardless (not makeKey) keeps the pill from stealing focus.
        panel.orderFrontRegardless()
    }

    func update(_ state: HUDState) {
        model.state = state
        if let panel { resizeToFit(panel) }
    }

    func hide() {
        panel?.orderOut(nil)
        model.resetLevels()
    }

    /// Re-measure the SwiftUI content for the current state and resize + reposition
    /// the panel to fit it. The panel is fitted once at creation for the short
    /// "Listening…" label, so every state change must recompute.
    private func resizeToFit(_ panel: NSPanel) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.setFrameSize(size)
        panel.setContentSize(size)
        position(panel) // depends on the (now updated) panel.frame.size
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.setFrameSize(hosting.fittingSize)

        // Focus-safety, three ways (see report): `.nonactivatingPanel` means
        // ordering it in never activates the app; `becomesKeyOnlyIfNeeded` means it
        // only takes key focus if a control demands it (ours never does, and it also
        // ignores mouse events); `.floating` keeps it above normal windows without
        // being a true overlay.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI capsule draws its own shadow
        panel.ignoresMouseEvents = true // non-interactive; Esc-to-cancel is a global monitor
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    private func position(_ panel: NSPanel) {
        // Bottom-center of the screen the user is actually on (under the cursor),
        // falling back to the main screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 96 // sit above the Dock, near the bottom
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
