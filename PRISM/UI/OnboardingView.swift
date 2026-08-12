// OnboardingView.swift
// PRISM
//
// The §9 setup state machine as a persistent banner atop the popover until
// all three grants are satisfied: camera+microphone TCC, camera extension
// approval, and the audio HAL package. Each row shows a state icon and a
// single action.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var state: AppState

    @State private var showingAudioWarning = false
    @State private var showingAudioInstructions = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            Text("Finish setting up PRISM")
                .font(.headline)
            permissionsRow
            extensionRow
            audioRow
        }
        .prismCard()
        // §9 — the postinstall restarts coreaudiod; warn before running.
        .alert("Install audio component", isPresented: $showingAudioWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") { openAudioPackage() }
        } message: {
            Text("The installer briefly interrupts all system audio while the audio system restarts.")
        }
        .alert("Audio installer not found", isPresented: $showingAudioInstructions) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Download PRISM-Audio.pkg from the PRISM release you installed, run it, then reopen PRISM.")
        }
    }

    // MARK: - Rows

    private var permissionsRow: some View {
        let camera = state.setup.camera
        let microphone = state.setup.microphone
        if camera == .granted && microphone == .granted {
            return setupRow(.done,
                            title: "Camera and microphone access",
                            caption: nil, buttonTitle: nil) {}
        }
        if camera == .denied || microphone == .denied {
            return setupRow(.problem,
                            title: "Camera and microphone access",
                            caption: "Allow camera and microphone for PRISM in System Settings",
                            buttonTitle: "Open System Settings") {
                openPrivacySettings()
            }
        }
        return setupRow(.pending,
                        title: "Camera and microphone access",
                        caption: nil,
                        buttonTitle: "Request access") {
            requestPermissions()
        }
    }

    private var extensionRow: some View {
        switch state.setup.cameraExtension {
        case .installed:
            return setupRow(.done, title: "Camera extension",
                            caption: nil, buttonTitle: nil) {}
        case .needsApproval:
            // §8.4 copy, verbatim.
            return setupRow(.pending, title: "Camera extension",
                            caption: "Approve PRISM Camera in System Settings to continue",
                            buttonTitle: "Approve in System Settings") {
                state.extensionInstaller.install()
            }
        case .failed(let message):
            return setupRow(.problem, title: "Camera extension",
                            caption: message,
                            buttonTitle: "Try again") {
                state.extensionInstaller.install()
            }
        case .notInstalled, .unknown:
            return setupRow(.pending, title: "Camera extension",
                            caption: nil,
                            buttonTitle: "Install") {
                state.extensionInstaller.install()
            }
        }
    }

    private var audioRow: some View {
        if state.setup.audioPlugInInstalled {
            return setupRow(.done, title: "Audio component",
                            caption: nil, buttonTitle: nil) {}
        }
        // §8.4 copy, verbatim.
        return setupRow(.pending, title: "Audio component",
                        caption: "Install the audio component to use PRISM Microphone",
                        buttonTitle: "Install audio component") {
            showingAudioWarning = true
        }
    }

    // MARK: - Row builder

    private enum RowState {
        case pending, done, problem
    }

    private func setupRow(_ rowState: RowState,
                          title: String,
                          caption: String?,
                          buttonTitle: String?,
                          action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.itemGap) {
            Image(systemName: icon(for: rowState))
                .foregroundStyle(color(for: rowState))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if rowState != .done, let buttonTitle {
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue(for: rowState))
    }

    private func icon(for rowState: RowState) -> String {
        switch rowState {
        case .pending: return "circle"
        case .done: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for rowState: RowState) -> AnyShapeStyle {
        switch rowState {
        case .pending: return AnyShapeStyle(.secondary)
        case .done: return AnyShapeStyle(Color.accentColor)
        case .problem: return AnyShapeStyle(.red)
        }
    }

    private func accessibilityValue(for rowState: RowState) -> String {
        switch rowState {
        case .pending: return "not done"
        case .done: return "done"
        case .problem: return "needs attention"
        }
    }

    // MARK: - Actions

    private func requestPermissions() {
        Task { @MainActor in
            _ = await state.permissions.requestCamera()
            _ = await state.permissions.requestMicrophone()
        }
    }

    private func openPrivacySettings() {
        // Land on the pane the user actually needs to fix: microphone when
        // only the microphone was denied, camera otherwise (§9: each setup
        // row has a working action).
        let target = (state.setup.camera != .denied && state.setup.microphone == .denied)
            ? "Privacy_Microphone"
            : "Privacy_Camera"
        let pane = "x-apple.systempreferences:com.apple.preference.security?\(target)"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the bundled or sibling PRISM-Audio.pkg; falls back to
    /// instructions when no installer can be found (§9).
    private func openAudioPackage() {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("PRISM-Audio.pkg"))
        }
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(bundleDir.appendingPathComponent("PRISM-Audio.pkg"))
        candidates.append(bundleDir.appendingPathComponent("dist/PRISM-Audio.pkg"))

        if let pkg = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(pkg)
        } else {
            showingAudioInstructions = true
        }
    }
}
