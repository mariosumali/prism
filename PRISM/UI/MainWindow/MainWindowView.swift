// MainWindowView.swift
// PRISM
//
// The main window's navigation shell and its smaller panes (Devices,
// General, About). The heavier panes live in their own files: StudioPane,
// FramingPane, EffectsPane, FormatPane, PresetsPane, MenuBarLayoutPane.
// Everything here is a second, roomier surface over the same AppState
// intents the popover uses — no new pipeline behavior.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MainPane: String, CaseIterable, Identifiable {
    case studio, scene, moments, capture, voice, framing, effects, format,
         devices, presets, apps, menuBar, shortcuts, general, prompter,
         gestures, meeting, assistant, diagnostics, about

    var id: String { rawValue }

    /// The pane's one-line answer to "why would I open this?", shown as the
    /// sidebar row's tooltip. Twenty nouns cannot all be self-explanatory.
    var summary: String {
        switch self {
        case .studio: return "The live picture, the tiles, and what is on air right now"
        case .scene: return "Backgrounds, blur, and the keyed layers in front of and behind you"
        case .moments: return "Instant replay, the away loop, the lag switch, bad connection"
        case .capture: return "Save a still or the last few seconds to a file"
        case .voice: return "Microphone cleanup, the voice changer, and the level meter"
        case .framing: return "Zoom, pan, rotation, mirror, crop, auto-framing"
        case .effects: return "Adjust, skin, LUTs, styles, blur — the whole chain"
        case .format: return "Resolution, frame rate, latency policy, measured cost"
        case .devices: return "Which camera, which microphone, or a screen instead"
        case .presets: return "Saved looks, and the chords that recall them"
        case .apps: return "Per-app rules: what each app gets when it opens PRISM"
        case .menuBar: return "Which modules the menu bar dropdown shows, and in what order"
        case .shortcuts: return "Global chords, and control from the Shortcuts app"
        case .general: return "Launch at login, and quitting PRISM"
        case .prompter: return "The script only you can see"
        case .gestures: return "Drive PRISM with your hands instead of a chord"
        case .meeting: return "Transcribe the call on this Mac, and write it up afterwards"
        case .assistant: return "Answers only you can see, while you are still talking"
        case .diagnostics: return "What PRISM has done this session"
        case .about: return "Version and licence"
        }
    }

    var title: String {
        switch self {
        case .studio: return "Studio"
        case .scene: return "Scene"
        case .moments: return "Moments"
        case .capture: return "Capture"
        case .voice: return "Voice"
        case .framing: return "Framing"
        case .effects: return "Effects"
        case .format: return "Format & Latency"
        case .devices: return "Devices"
        case .presets: return "Presets"
        case .apps: return "Apps"
        case .menuBar: return "Menu Bar"
        case .shortcuts: return "Shortcuts"
        case .general: return "General"
        case .prompter: return "Prompter"
        case .gestures: return "Gestures"
        case .meeting: return "Meeting"
        case .assistant: return "Assistant"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .studio: return "video"
        case .scene: return "theatermasks"
        case .moments: return "backward.end.alt.fill"
        case .capture: return "square.and.arrow.down"
        case .voice: return "waveform.and.mic"
        case .framing: return "crop.rotate"
        case .effects: return "wand.and.stars"
        case .format: return "rectangle.on.rectangle"
        case .devices: return "camera"
        case .presets: return "square.stack"
        case .apps: return "app.badge.checkmark"
        case .menuBar: return "menubar.arrow.up.rectangle"
        case .shortcuts: return "keyboard"
        case .general: return "gearshape"
        case .prompter: return "doc.plaintext"
        case .gestures: return "hand.raised"
        case .meeting: return "text.bubble"
        case .assistant: return "sparkles"
        case .diagnostics: return "list.bullet.rectangle"
        case .about: return "info.circle"
        }
    }
}

/// The sidebar's five groups. Eighteen flat rows in one undifferentiated
/// list is a list you read top to bottom every time, and the flat order had
/// drifted into an arbitrary one — Prompter and Gestures sat below General,
/// which is where a reader stops looking. Grouped, you pick a section and
/// then a row inside it.
enum MainPaneGroup: String, CaseIterable, Identifiable {
    case onAir, recording, conversation, io, control, prism

    var id: String { rawValue }

    /// No header repeats a row inside it: a "Devices" section whose first
    /// row is "Devices" tells you nothing twice.
    var title: String {
        switch self {
        case .onAir: return "On air"
        case .recording: return "Recording"
        case .conversation: return "The conversation"
        case .io: return "Sources & output"
        case .control: return "Control"
        case .prism: return "PRISM"
        }
    }

    var panes: [MainPane] {
        switch self {
        // Everything that changes what other people see or hear.
        case .onAir: return [.studio, .scene, .framing, .effects, .voice, .prompter]
        // Both live off the rolling buffer: one plays it back, one saves it.
        case .recording: return [.moments, .capture]
        // §5.32/§5.33 — the only two panes about what was *said* rather
        // than about how it looks or sounds going out.
        case .conversation: return [.meeting, .assistant]
        case .io: return [.devices, .format]
        // Every way to drive PRISM without touching this window.
        case .control: return [.presets, .shortcuts, .gestures, .apps, .menuBar]
        case .prism: return [.general, .diagnostics, .about]
        }
    }

    /// Every pane, in sidebar order.
    static var allPanes: [MainPane] { allCases.flatMap(\.panes) }
}

struct MainWindowView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedPane: MainPane? = .studio
    @State private var lastPane: MainPane = .studio

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPane) {
                ForEach(MainPaneGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.panes) { pane in
                            Label(pane.title, systemImage: pane.symbol)
                                .tag(pane)
                                .help(pane.summary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            // A pane added without being filed in a group would simply vanish
            // from the sidebar, and nothing else would complain. Fail loudly
            // in Debug instead.
            .onAppear {
                assert(Set(MainPaneGroup.allPanes) == Set(MainPane.allCases)
                       && MainPaneGroup.allPanes.count == MainPane.allCases.count,
                       "every MainPane must appear in exactly one sidebar group")
            }
        } detail: {
            paneView(selectedPane ?? lastPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // ⌘-clicking the selected sidebar row deselects (Optional selection);
        // a pane must always be selected here, so restore the last one.
        .onChange(of: selectedPane) { newValue in
            if let newValue {
                lastPane = newValue
            } else {
                selectedPane = lastPane
            }
        }
        // Same affordance as the popover: dropping a .cube anywhere imports it.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            CubeDropImporter.handle(providers, state: state)
        }
    }

    @ViewBuilder
    private func paneView(_ pane: MainPane) -> some View {
        switch pane {
        case .studio: StudioPane(navigateToFormat: { selectedPane = .format })
        case .scene: ScenePane()
        case .moments: MomentsPane()
        case .capture: CapturePane()
        case .voice: VoicePane()
        case .framing: FramingPane()
        case .effects: EffectsPane()
        case .format: FormatPane()
        case .devices: DevicesPane()
        case .presets: PresetsPane()
        case .apps: AppsPane()
        case .menuBar: MenuBarLayoutPane()
        case .shortcuts: ShortcutsPane()
        case .general: GeneralPane()
        case .prompter: PrompterPane()
        case .gestures: GesturesPane()
        case .meeting: MeetingPane()
        case .assistant: AssistantPane()
        case .diagnostics: DiagnosticsPane()
        case .about: AboutPane()
        }
    }
}

/// Shared .cube drag-and-drop import (§5.4), used by the whole main window.
@MainActor
enum CubeDropImporter {
    static func handle(_ providers: [NSItemProvider], state: AppState) -> Bool {
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

// MARK: - Devices

private struct DevicesPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Source") {
                Picker("On air", selection: sourceBinding) {
                    Text("Camera").tag(VideoSourceSelection.camera)
                    // Keeps a source that has since gone away nameable while
                    // it is still selected.
                    if state.videoSource.kind != .camera,
                       !state.screenSources.contains(where: { $0.id == state.videoSource.sourceID }) {
                        Text(state.videoSourceName).tag(state.videoSource)
                    }
                    ForEach(state.screenSources) { source in
                        Text(source.displayName)
                            .tag(VideoSourceSelection(kind: source.kind, sourceID: source.id))
                    }
                }
                HStack {
                    Button("Refresh list") { state.refreshScreenSources() }
                    Spacer()
                    Text(state.isSharingScreen ? "Sharing a screen" : "Camera on air")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if state.setup.screenRecording != .granted {
                    HStack {
                        Text("Screens and windows need Screen Recording permission. macOS applies the grant when PRISM is next opened.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Allow…") { state.requestScreenRecordingAccess() }
                    }
                }
                Text("A screen goes through the same chain the camera does, so freeze, replay, the effects and every saved clip work on it unchanged. If the window closes or the display goes, PRISM falls back to the camera and says so — never to a black frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Camera") {
                Picker("Camera", selection: cameraBinding) {
                    Text("System default").tag(String?.none)
                    ForEach(state.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                Text("If the selected camera disconnects, PRISM falls back to the built-in camera and tells you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Picker("Microphone", selection: microphoneBinding) {
                    Text("System default").tag(String?.none)
                    ForEach(state.microphones) { microphone in
                        Text(microphone.name).tag(Optional(microphone.id))
                    }
                }
            }
            Section {
                Text("PRISM runs the camera and microphone only while a preview is open or an app is using PRISM Camera — never around the clock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshScreenSources() }
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
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.setEnabled($0) }
            }
            Section {
                // The list itself lives one row down the sidebar; repeating
                // it here would be two editors for one setting.
                Text("Keyboard shortcuts and control from other apps are in the Shortcuts pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Quit PRISM", role: .destructive) {
                    state.quit()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: Metrics.itemGap) {
            // The app icon, not the menu bar glyph: this pane is about the
            // application, and the glyph is a status indicator whose whole
            // job is to mean something other than "PRISM" most of the time.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("PRISM")
                .font(.headline)
            Text("Version \(versionString)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Licensed under the Apache License, Version 2.0.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("PRISM makes no network connections.")
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.gutter)
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String
        if let build, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
