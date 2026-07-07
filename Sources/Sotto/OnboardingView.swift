import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// Onboarding gating logic, kept pure so "shows only when a permission is missing,
/// or the guide hasn't been seen yet" is unit-testable.
enum Onboarding {
    static func shouldShow(micAuthorized: Bool, axTrusted: Bool, completedGuide: Bool) -> Bool {
        !(micAuthorized && axTrusted && completedGuide)
    }
}

/// First-run walkthrough (DESIGN.md §5 M3, expanded in M5): two steps — grant
/// permissions, then a "how to dictate" guide — shown on first launch and
/// reachable on demand via the "Welcome & Permissions…" menu item. Plain SwiftUI,
/// no mascots or animation.
struct OnboardingView: View {
    var onDone: () -> Void
    /// Opens the Settings window (e.g. to change the hotkey) from the guide step.
    var onOpenSettings: () -> Void
    /// Reports whether the menu bar is currently hiding Sotto's status icon
    /// (macOS hides overflow items when the bar is full). Injected so this view
    /// stays testable/preview-able without a real NSStatusItem.
    var statusItemHidden: () -> Bool

    private enum Step { case permissions, guide, verify }

    @State private var step: Step
    @State private var micGranted: Bool
    @State private var axTrusted: Bool
    @State private var iconHidden = false
    /// The user's live first dictation, pasted straight into the verify field so
    /// they watch the whole capture→transcribe→paste pipeline work on run one.
    @State private var verifyText = ""
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(onDone: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void = {},
         statusItemHidden: @escaping () -> Bool = { false }) {
        self.onDone = onDone
        self.onOpenSettings = onOpenSettings
        self.statusItemHidden = statusItemHidden
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        _micGranted = State(initialValue: mic)
        _axTrusted = State(initialValue: ax)
        _step = State(initialValue: (mic && ax) ? .guide : .permissions)
    }

    var body: some View {
        VStack(spacing: 18) {
            switch step {
            case .permissions: permissionsStep
            case .guide: guideStep
            case .verify: verifyStep
            }
        }
        .padding(28)
        .frame(width: 460, height: 440)
        .onAppear { refreshIconVisibility() }
        .onReceive(poll) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            axTrusted = AXIsProcessTrusted()
            refreshIconVisibility()
            // Once both grants land, move on to the guide instead of closing —
            // the guide is the other half of onboarding now.
            if step == .permissions, micGranted, axTrusted {
                step = .guide
            }
        }
    }

    private func refreshIconVisibility() {
        let hidden = statusItemHidden()
        if hidden, !iconHidden {
            NSLog("Sotto: menu bar is full — macOS is hiding Sotto's status icon.")
        }
        iconHidden = hidden
    }

    // MARK: Step 1 — permissions

    @ViewBuilder
    private var permissionsStep: some View {
        Text("Welcome to Sotto").font(.title).bold()
        Text("Press ⌥Space, speak, press again — your words paste wherever you're typing. Sotto needs two grants:")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

        grantRow(title: "Microphone", detail: "to hear your dictation", granted: micGranted) {
            Button("Grant") { requestMicrophone() }.disabled(micGranted)
        }
        grantRow(title: "Accessibility", detail: "to paste into other apps", granted: axTrusted) {
            Button("Grant") { requestAccessibility() }.disabled(axTrusted)
        }

        if iconHidden { menuBarFullNotice }

        Spacer()
        Text(micGranted && axTrusted ? "All set — continuing to the quick guide…"
                                     : "This continues once both are granted.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Step 2 — how to dictate

    @ViewBuilder
    private var guideStep: some View {
        Text("How to dictate").font(.title).bold()

        if iconHidden { menuBarFullNotice }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                guideRow(title: "⌥Space, tap", detail: "Start recording; tap again to stop and paste.")
                guideRow(title: "⌥Space, hold", detail: "Push-to-talk — records while held, stops on release.")
                guideRow(title: "Esc, while recording", detail: "Cancel — discards the recording, nothing is pasted.")
                guideRow(title: "⇧, while stopping", detail: "Raw escape hatch — pastes the unprocessed transcript, skipping smart cleanup.")
                guideRow(title: "Select text, then speak an instruction",
                         detail: "\"Make this a bullet list\" replaces the selection instead of dictating.")
                guideRow(title: "Settings & history", detail: "Menu bar icon → Settings… for the hotkey, sounds, vocabulary, and dictation history.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Spacer()
        HStack {
            if step == .guide, !(micGranted && axTrusted) {
                Button("Back to permissions") { step = .permissions }
            }
            Spacer()
            Button("Change hotkey…") { onOpenSettings() }
            Button("Try it now →") { step = .verify }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Step 3 — verify the pipeline end-to-end

    @ViewBuilder
    private var verifyStep: some View {
        Text("Try your first dictation").font(.title).bold()
        Text("Click the box, press ⌥Space, say a sentence, then press ⌥Space again. Your words appear here — proof the whole thing works.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .font(.callout)

        TextEditor(text: $verifyText)
            .font(.body)
            .frame(height: 120)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3)))
            .overlay(alignment: .topLeading) {
                if verifyText.isEmpty {
                    Text("Your dictation lands here…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

        if !verifyText.isEmpty {
            Label("That came straight from your voice — you're set.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        }

        Spacer()
        HStack {
            Button("Back") { step = .guide }
            if !verifyText.isEmpty {
                Button("Clear & retry") { verifyText = "" }
            }
            Spacer()
            Button(verifyText.isEmpty ? "Skip" : "Perfect — start dictating") { finishGuide() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func finishGuide() {
        onDone()
    }

    @ViewBuilder
    private func guideRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var menuBarFullNotice: some View {
        Text("Your menu bar is full, so macOS is hiding Sotto's icon — remove an icon (⌘-drag it off) to see Sotto's mic. Sotto still works: ⌥Space dictates even without the icon.")
            .font(.callout)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func grantRow<Trailing: View>(
        title: String, detail: String, granted: Bool, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal)
    }

    private func requestMicrophone() {
        // First run: the system shows an Allow/Don't-Allow dialog that grants
        // directly. If the user already decided (denied), the system won't
        // re-prompt, so we send them to Settings to change it manually.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            openSettings("Privacy_Microphone")
        }
    }

    private func requestAccessibility() {
        // Show the system trust prompt (this also registers Sotto in the
        // Accessibility list). Its "Open System Settings" button is the single,
        // user-driven way into Settings — don't also open Settings ourselves,
        // or the user gets two dialogs at once.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
