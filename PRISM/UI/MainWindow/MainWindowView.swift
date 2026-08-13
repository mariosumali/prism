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
    case studio, scene, moments, framing, effects, format, devices, presets,
         menuBar, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .studio: return "Studio"
        case .scene: return "Scene"
        case .moments: return "Moments"
        case .framing: return "Framing"
        case .effects: return "Effects"
        case .format: return "Format & Latency"
        case .devices: return "Devices"
        case .presets: return "Presets"
        case .menuBar: return "Menu Bar"
        case .general: return "General"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .studio: return "video"
        case .scene: return "theatermasks"
        case .moments: return "backward.end.alt.fill"
        case .framing: return "crop.rotate"
        case .effects: return "wand.and.stars"
        case .format: return "rectangle.on.rectangle"
        case .devices: return "camera"
        case .presets: return "square.stack"
        case .menuBar: return "menubar.arrow.up.rectangle"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedPane: MainPane? = .studio
    @State private var lastPane: MainPane = .studio

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPane) {
                ForEach(MainPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
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
        case .framing: FramingPane()
        case .effects: EffectsPane()
        case .format: FormatPane()
        case .devices: DevicesPane()
        case .presets: PresetsPane()
        case .menuBar: MenuBarLayoutPane()
        case .general: GeneralPane()
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
            Section("Keyboard shortcuts") {
                LabeledContent("Freeze", value: "⌥⌘F")
                LabeledContent("Mute", value: "⌥⌘M")
                LabeledContent("Freeze and mute", value: "⌥⌘⇧F")
                LabeledContent("Instant replay", value: "⌥⌘R")
                LabeledContent("Away loop", value: "⌥⌘A")
                LabeledContent("Panic", value: "⌥⌘P")
                LabeledContent("Eye contact", value: "⌥⌘E")
                LabeledContent("Lag switch", value: "⌥⌘L")
                ForEach(state.presets.filter { $0.hotkey != nil }) { preset in
                    LabeledContent(preset.name,
                                   value: preset.hotkey?.displayString ?? "")
                }
                Text("Assign preset hotkeys in the Presets pane.")
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
            MenuBarIcon(state: .live)
                .font(.largeTitle)
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
