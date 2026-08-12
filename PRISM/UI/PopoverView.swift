// PopoverView.swift
// PRISM
//
// The full popover (§8.3). The setup banner, warning row, and bottom bar
// always show; everything between renders from AppState.popoverLayout — the
// user picks which modules appear and their order in the main window's Menu
// Bar pane. The §8.3 default order is PopoverModuleItem.defaultLayout.
// Dropping a .cube file anywhere on the popover imports it as a LUT.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PopoverView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let visibleModules = state.popoverLayout.filter(\.visible)
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            if !state.setup.isComplete {
                OnboardingView()
            }
            if let warning = state.warning {
                warningRow(warning)
            }
            if state.draftConfig != nil {
                draftBanner
            }
            ForEach(visibleModules) { item in
                moduleView(item.module)
            }
            if visibleModules.isEmpty {
                allHiddenHint
            }
            bottomBar
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.gutter)
        .frame(width: Metrics.popoverWidth)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Modules

    @ViewBuilder
    private func moduleView(_ module: PopoverModule) -> some View {
        switch module {
        case .preview:
            // usesDraft: while preview-before-apply is on, this popover
            // shows and edits the same pending look as the main window —
            // the surfaces never disagree.
            PreviewView(usesDraft: true)
                .frame(width: 288, height: 162)   // 16:9, §8.3
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius,
                                            style: .continuous))
                .accessibilityLabel(state.draftConfig == nil
                                    ? "Output preview"
                                    : "Draft preview of unapplied changes")
        case .status:
            Text(statusLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .latencyMeter:
            LatencyMeter(onTap: {
                // §8.6 affordance — but the Format module may be hidden by
                // the user's dropdown layout; the setting then lives in the
                // main window, so lead there instead of tapping into nothing.
                if state.visiblePopoverModules.contains(.format) {
                    if !state.expandedSections.contains(.format) {
                        state.toggleSection(.format)
                    }
                    state.latencyPolicyFocusRequest += 1
                } else {
                    state.showMainWindow()
                }
            }, tapHint: "Opens the Format section")
        case .inUse:
            Text(inUseLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .controls:
            tiles
            if state.clipState != .none {
                scrubRow
            }
        case .presets:
            PresetBar()
        case .framing:
            FramingSection()
        case .effects:
            EffectsSection()
        case .format:
            FormatSection()
        case .devices:
            devicePickers
        }
    }

    /// Shown while preview-before-apply (main window toggle) has edits
    /// pending: this popover is previewing them too, and the camera keeps
    /// the applied look until Apply.
    private var draftBanner: some View {
        HStack(spacing: Metrics.itemGap) {
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
            Text("Previewing edits")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Discard") { state.discardDraft() }
                .controlSize(.small)
            Button("Apply") { state.applyDraft() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    private var allHiddenHint: some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            Text("Everything here is hidden.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Customize in the PRISM window…") {
                state.showMainWindow()
            }
            .controlSize(.small)
        }
    }

    /// "1080p · 30 fps · +7.2 ms"
    private var statusLine: String {
        let format = state.config.format
        let added = String(format: "%+.1f", state.latency.totalAddedMs)
        return "\(format.resolutionLabel) · \(format.frameRate) fps · \(added) ms"
    }

    /// §8.4 — "In use by Zoom, FaceTime" / "Not in use".
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
            case .openSettings:
                Button("Open Settings") { openSettingsWindow() }
                    .controlSize(.small)
            case .none:
                EmptyView()
            }
        }
    }

    // MARK: - Control tiles

    private var tiles: some View {
        HStack(spacing: Metrics.itemGap) {
            ControlTile(title: "Freeze",
                        symbol: "pause.fill",
                        isActive: state.isFrozen) {
                state.toggleFreeze()
            }
            ControlTile(title: "Mute",
                        symbol: "mic.slash.fill",
                        isActive: state.isMuted) {
                state.toggleMute()
            }
            clipTile
        }
    }

    private var clipTile: some View {
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
        .contextMenu {
            if state.clipState != .none {
                Toggle("Loop", isOn: Binding(
                    get: { state.clipLoops },
                    set: { state.clipLoops = $0 }))
                Toggle("Use clip audio", isOn: Binding(
                    get: { state.clipUsesClipAudio },
                    set: { state.clipUsesClipAudio = $0 }))
                Divider()
                Button("Stop") { state.stopClip() }
            }
        }
    }

    private var clipAccessibilityValue: String {
        switch state.clipState {
        case .none: return "no clip loaded"
        case .playing: return "playing"
        case .paused: return "paused"
        }
    }

    private var scrubRow: some View {
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

    // MARK: - Device pickers

    private var devicePickers: some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            devicePickerRow(label: "Camera") {
                Picker("Camera", selection: cameraBinding) {
                    Text("System default").tag(String?.none)
                    ForEach(state.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
            }
            devicePickerRow(label: "Microphone") {
                Picker("Microphone", selection: microphoneBinding) {
                    Text("System default").tag(String?.none)
                    ForEach(state.microphones) { microphone in
                        Text(microphone.name).tag(Optional(microphone.id))
                    }
                }
            }
        }
    }

    private func devicePickerRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Metrics.itemGap) {
            Text(label)
                .font(.body)
            Spacer(minLength: 0)
            content()
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(label)
        }
    }

    private var cameraBinding: Binding<String?> {
        Binding(
            get: { state.config.cameraID },
            set: { state.selectCamera($0) })
    }

    private var microphoneBinding: Binding<String?> {
        Binding(
            get: { state.config.microphoneID },
            set: { state.selectMicrophone($0) })
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Button {
                state.showMainWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Open PRISM window")
            .help("Open the PRISM window")
            settingsButton
            Spacer()
            Button {
                state.quit()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Quit PRISM")
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Settings")
        } else {
            Button {
                openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Settings")
        }
    }

    private func openSettingsWindow() {
        // macOS 13 selector; older name kept as a fallback.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - LUT drag-and-drop (§5.4)

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                              options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                }
                guard let fileURL = url,
                      fileURL.pathExtension.lowercased() == "cube" else { return }
                DispatchQueue.main.async {
                    state.importLUT(from: fileURL)
                }
            }
        }
        return accepted
    }
}
