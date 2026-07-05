import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// Onboarding gating logic, kept pure so "shows only when a permission is missing"
/// is unit-testable.
enum Onboarding {
    static func shouldShow(micAuthorized: Bool, axTrusted: Bool) -> Bool {
        !(micAuthorized && axTrusted)
    }
}

/// First-run walkthrough (DESIGN.md §5 M3): shown only when a required grant is
/// missing. Two rows (Microphone, Accessibility) with live status and deep links
/// into the right System Settings pane; it dismisses itself when both go green.
struct OnboardingView: View {
    var onDone: () -> Void

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axTrusted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
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

            Spacer()
            Text(micGranted && axTrusted ? "All set — you can dictate now."
                                         : "This window closes itself once both are granted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 440, height: 320)
        .onReceive(poll) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            axTrusted = AXIsProcessTrusted()
            if !Onboarding.shouldShow(micAuthorized: micGranted, axTrusted: axTrusted) {
                onDone() // both green → dismiss itself
            }
        }
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
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        openSettings("Privacy_Microphone")
    }

    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
