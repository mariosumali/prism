// StudioPane.swift
// PRISM
//
// The main window's landing pane: a large preview (the draft render while
// edits are staged elsewhere in the window, with the Apply / Discard bar)
// over the same status/latency/warning readouts as the popover, the
// Freeze / Mute / Clip tiles with their hotkeys spelled out, clip
// transport, and the preset bar. Opening this window is a preview consumer
// exactly like opening the popover (AppState.mainWindowOpen).
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

struct StudioPane: View {
    @EnvironmentObject var state: AppState

    /// Installed by MainWindowView; the latency meter navigates to the
    /// Format & Latency pane, where the policy control lives.
    var navigateToFormat: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                if !state.setup.isComplete {
                    OnboardingView()
                }
                PanePreview()
                HStack {
                    Text(statusLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Metrics.sectionGap)
                    Text(inUseLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LatencyMeter(onTap: navigateToFormat,
                             tapHint: "Opens Format & Latency")
                if let warning = state.warning {
                    warningRow(warning)
                }
                tiles
                if state.clipState != .none {
                    clipTransport
                }
                Text("Moments")
                    .font(.headline)
                MomentsSection()
                Text("Presets")
                    .font(.headline)
                PresetBar()
            }
            .padding(Metrics.gutter)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Status

    /// "1080p · 30 fps · +7.2 ms", same composition as the popover, including
    /// the deliberate delay when one is engaged (§5.12).
    private var statusLine: String {
        let format = state.config.format
        let added = String(format: "%+.1f", state.latency.totalAddedMs)
        var line = "\(format.resolutionLabel) · \(format.frameRate) fps · \(added) ms"
        if state.latency.deliberateDelayMs >= 50 {
            line += String(format: " · +%.1f s lag", state.latency.deliberateDelayMs / 1000)
        }
        return line
    }

    private var inUseLine: String {
        state.clientsInUse.isEmpty
            ? "Not in use"
            : "In use by \(state.clientsInUse.joined(separator: ", "))"
    }

    private func warningRow(_ warning: WarningMessage) -> some View {
        HStack(spacing: Metrics.itemGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(warning.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            switch warning.action {
            case .raiseBudget:
                Button("Raise budget") { state.raiseBudgetOneStep() }
                    .controlSize(.small)
            case .armBuffer:
                Button("Turn on") { state.setBufferArmed(true) }
                    .controlSize(.small)
            case .openScreenRecordingSettings:
                Button("Open Settings") { openScreenRecordingSettings() }
                    .controlSize(.small)
            // The capture folder and the app rules both live in this window,
            // so from here the warning row has nowhere to send anyone.
            case .chooseCaptureFolder, .openAppRules, .openSettings, .none:
                EmptyView()
            }
        }
    }

    /// Screen Recording is its own grant, and unlike camera and microphone
    /// PRISM cannot prompt for it — the only working action is landing the
    /// user on the pane (§9: every setup row has one).
    private func openScreenRecordingSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Control tiles

    private var tiles: some View {
        HStack(alignment: .top, spacing: Metrics.itemGap) {
            tileWithHint(hint: "⌥⌘F") {
                ControlTile(title: "Freeze",
                            symbol: "pause.fill",
                            isActive: state.isFrozen) {
                    state.toggleFreeze()
                }
            }
            tileWithHint(hint: "⌥⌘M") {
                ControlTile(title: "Mute",
                            symbol: "mic.slash.fill",
                            isActive: state.isMuted) {
                    state.toggleMute()
                }
            }
            tileWithHint(hint: clipHint) {
                ControlTile(title: "Clip",
                            symbol: "film",
                            isActive: state.clipState == .playing,
                            accessibilityValue: clipAccessibilityValue) {
                    if state.clipState == .none {
                        chooseClip()
                    } else {
                        state.toggleClipPlayback()
                    }
                }
            }
        }
        .frame(maxWidth: 420)
    }

    private func tileWithHint<Tile: View>(
        hint: String,
        @ViewBuilder tile: () -> Tile
    ) -> some View {
        VStack(spacing: 4) {
            tile()
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var clipHint: String {
        switch state.clipState {
        case .none: return "Choose a video…"
        case .playing: return "Click to pause"
        case .paused: return "Click to play"
        }
    }

    private var clipAccessibilityValue: String {
        switch state.clipState {
        case .none: return "no clip loaded"
        case .playing: return "playing"
        case .paused: return "paused"
        }
    }

    // MARK: - Clip transport

    private var clipTransport: some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            HStack(spacing: Metrics.itemGap) {
                Text(timeString(state.clipPosition))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { state.clipPosition },
                    set: { state.scrubClip(to: $0) }),
                       in: 0...max(state.clipDuration, 0.01))
                    .controlSize(.small)
                    .accessibilityLabel("Clip position")
                    .accessibilityValue(timeString(state.clipPosition))
                Text(timeString(state.clipDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Metrics.sectionGap) {
                Toggle("Loop", isOn: Binding(
                    get: { state.clipLoops },
                    set: { state.clipLoops = $0 }))
                Toggle("Use clip audio", isOn: Binding(
                    get: { state.clipUsesClipAudio },
                    set: { state.clipUsesClipAudio = $0 }))
                Spacer()
                Button("Stop clip") { state.stopClip() }
                    .controlSize(.small)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .prismCard()
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func chooseClip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                state.loadClip(url: url)
            }
        }
    }
}
