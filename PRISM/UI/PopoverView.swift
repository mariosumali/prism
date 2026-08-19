// PopoverView.swift
// PRISM
//
// The full popover (§8.3). The setup banner, warning row, and bottom bar
// always show; everything between renders from AppState.popoverLayout — the
// user picks which modules appear and their order in the main window's Menu
// Bar pane. The §8.3 default order is PopoverModuleItem.defaultLayout.
// Dropping a .cube file anywhere on the popover imports it as a LUT.
//
// The metadata modules — preview, status, meter, in-use — describe one
// thing, so they are spaced as one block (Metrics.metaGap) rather than as
// four sections, and the status line and meter share a row when they are
// adjacent. Content taller than the screen scrolls instead of running off
// the bottom.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PopoverView: View {
    @EnvironmentObject var state: AppState

    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: proxy.size.height)
                    })
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }
        // Fits content, and stops fitting once the popover would run past
        // the bottom of the screen — a dropdown you cannot see the end of
        // is worse than one that scrolls.
        .frame(width: Metrics.popoverWidth,
               height: contentHeight.map { min($0, maxHeight) })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var content: some View {
        let rows = moduleRows
        return VStack(alignment: .leading, spacing: 0) {
            if !state.setup.isComplete {
                OnboardingView()
                    .padding(.bottom, Metrics.sectionGap)
            }
            if let warning = state.warning {
                warningRow(warning)
                    .padding(.bottom, Metrics.sectionGap)
            }
            // Its own row, below the warning: a notice is something PRISM
            // noticed, not something that went wrong, and the two must be
            // able to show at once (§5.17).
            if let notice = state.notice {
                noticeRow(notice)
                    .padding(.bottom, Metrics.sectionGap)
            }
            if state.draftConfig != nil {
                draftBanner
                    .padding(.bottom, Metrics.sectionGap)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row)
                    .padding(.top, index == 0
                             ? 0
                             : gap(before: row, after: rows[index - 1]))
            }
            if rows.isEmpty {
                allHiddenHint
            }
            Divider()
                .padding(.top, Metrics.sectionGap)
                .padding(.bottom, Metrics.itemGap)
            bottomBar
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.gutter)
        .frame(width: Metrics.popoverWidth)
    }

    private var maxHeight: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? 720
        return max(available - Metrics.sectionGap * 2, 360)
    }

    // MARK: - Rows

    /// One line of the popover: usually a single module, but the status
    /// line and the latency meter share a row when they sit next to each
    /// other — the meter is the second half of that sentence, not a
    /// separate section.
    private struct ModuleRow: Identifiable {
        let modules: [PopoverModule]

        var id: String { modules.map(\.rawValue).joined(separator: "+") }

        /// Metadata about the output rather than a control over it.
        var isMeta: Bool {
            modules.allSatisfy { PopoverView.metaModules.contains($0) }
        }
    }

    private static let metaModules: Set<PopoverModule> = [.preview, .status,
                                                          .latencyMeter, .inUse]

    private var moduleRows: [ModuleRow] {
        let visible = state.visiblePopoverModules
        var rows: [ModuleRow] = []
        var index = 0
        while index < visible.count {
            if visible[index] == .status,
               index + 1 < visible.count,
               visible[index + 1] == .latencyMeter,
               !isLagging {
                rows.append(ModuleRow(modules: [.status, .latencyMeter]))
                index += 2
            } else {
                rows.append(ModuleRow(modules: [visible[index]]))
                index += 1
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: ModuleRow) -> some View {
        if row.modules == [.status, .latencyMeter] {
            HStack(spacing: Metrics.itemGap) {
                statusText
                    .fixedSize()
                latencyMeter
            }
        } else if let module = row.modules.first {
            moduleView(module)
        }
    }

    /// Metadata reads as one block; controls get section air around them.
    private func gap(before row: ModuleRow, after previous: ModuleRow) -> CGFloat {
        row.isMeta && previous.isMeta ? Metrics.metaGap : Metrics.sectionGap
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
            statusText
        case .latencyMeter:
            latencyMeter
        case .inUse:
            Text(inUseLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .controls:
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                tiles
                if state.clipState != .none {
                    scrubRow
                }
            }
        case .moments:
            MomentsSection()
        case .capture:
            CaptureSection()
        case .prompter:
            PrompterSection()
        case .presets:
            PresetBar()
        case .scene:
            SceneSection()
        case .voice:
            VoiceSection()
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

    private var statusText: some View {
        Text(statusLine)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var latencyMeter: some View {
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

    /// "1080p · 30 fps", plus the deliberate delay when one is engaged
    /// (§5.12) — three seconds of requested lag must never hide behind a
    /// reading of "+7.2 ms".
    ///
    /// Added latency is the meter's job and is printed here only when the
    /// meter is hidden: the same number twice, one line apart, is clutter
    /// rather than reassurance.
    private var statusLine: String {
        let format = state.config.format
        var line = "\(format.resolutionLabel) · \(format.frameRate) fps"
        if !state.visiblePopoverModules.contains(.latencyMeter) {
            line += String(format: " · %+.1f ms", state.latency.totalAddedMs)
        }
        if isLagging {
            line += String(format: " · +%.1f s lag", state.latency.deliberateDelayMs / 1000)
        }
        return line
    }

    /// A lag callout makes the status line too long to share a row with
    /// the meter, so the pair splits back into two lines while it shows.
    private var isLagging: Bool {
        state.latency.deliberateDelayMs >= 50
    }

    /// §8.4 — "In use by Zoom, FaceTime" / "Not in use", plus the §5.18
    /// refusal when one is biting. A blocked app cannot tell its user why its
    /// camera will not start, so this line is the only place that can.
    private var inUseLine: String {
        var line = state.clientsInUse.isEmpty
            ? "Not in use"
            : "In use by \(state.clientsInUse.joined(separator: ", "))"
        if !state.blockedClients.isEmpty {
            line += " · blocking \(state.blockedClients.map(\.displayName).joined(separator: ", "))"
        }
        return line
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
            case .clearBlocks:
                Button("Unblock all") { state.clearAllBlocks() }
                    .controlSize(.small)
            case .openSettings:
                Button("Open Settings") { openSettingsWindow() }
                    .controlSize(.small)
            // Settled in the main window — the capture folder is too large
            // a question to answer from a dropdown, so the button opens the
            // place that can answer it.
            case .chooseCaptureFolder:
                Button("Choose folder") { state.showMainWindow() }
                    .controlSize(.small)
            case .openScreenRecordingSettings:
                Button("Open Settings") { openScreenRecordingSettings() }
                    .controlSize(.small)
            case .none:
                EmptyView()
            }
        }
    }

    /// The mirror of the warning row: something that went right, and — when
    /// it produced a file — the one button that answers "where did it go?".
    /// A saved file the user cannot find is a file that was not saved.
    ///
    /// A notice carrying an action is not a confirmation, it is a standing
    /// condition asking to be fixed (§5.17), so it drops the green and takes
    /// the orange — still not the red, which §8.2 reserves for wrong.
    private func noticeRow(_ notice: NoticeMessage) -> some View {
        HStack(spacing: Metrics.itemGap) {
            Image(systemName: notice.symbolName)
                .foregroundStyle(notice.action == .none ? Color.green : Color.orange)
            Text(notice.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let url = notice.fileURL {
                Button("Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    state.dismissNotice()
                }
                .controlSize(.small)
            }
            switch notice.action {
            case .unmute:
                Button("Unmute") { state.toggleMute() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            case .comeBack:
                Button("I'm back") { state.comeBack() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
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
            devicePickerRow(label: "Source") {
                Picker("Source", selection: sourceBinding) {
                    Text("Camera").tag(VideoSourceSelection.camera)
                    // A source that has gone still names itself while it is
                    // selected; a picker showing a blank row is worse than
                    // one showing a window that has closed.
                    if state.videoSource.kind != .camera,
                       !state.screenSources.contains(where: { $0.id == state.videoSource.sourceID }) {
                        Text(state.videoSourceName).tag(state.videoSource)
                    }
                    ForEach(state.screenSources) { source in
                        Text(source.displayName)
                            .tag(VideoSourceSelection(kind: source.kind, sourceID: source.id))
                    }
                }
            }
            if state.setup.screenRecording != .granted {
                HStack(spacing: Metrics.itemGap) {
                    Text("Screens and windows need Screen Recording permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Allow…") { state.requestScreenRecordingAccess() }
                        .controlSize(.small)
                }
            }
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
        .onAppear { state.refreshScreenSources() }
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

    private var sourceBinding: Binding<VideoSourceSelection> {
        Binding(
            get: { state.videoSource },
            set: { state.selectVideoSource($0) })
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
            .help("Quit PRISM")
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

    /// Screen Recording is its own grant, and unlike camera and microphone
    /// PRISM cannot prompt for it — the only working action is landing the
    /// user on the pane (§9: every setup row has one).
    private func openScreenRecordingSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
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

/// Measures the popover's natural height so the frame can cap it at the
/// screen without ever being taller than its content.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
