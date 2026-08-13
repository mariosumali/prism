// SettingsView.swift
// PRISM
//
// The Settings window (§8.3 "deeper controls"): General (login item, hotkey
// reference), Framing (pan, crop aspect, orientation), Adjust (five sliders),
// Formats (published-set editor), LUTs (import + reveal), and About.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            FramingSettingsTab()
                .tabItem { Label("Framing", systemImage: "crop.rotate") }
            AdjustSettingsTab()
                .tabItem { Label("Adjust", systemImage: "slider.horizontal.3") }
            FormatsSettingsTab()
                .tabItem { Label("Formats", systemImage: "rectangle.on.rectangle") }
            LUTSettingsTab()
                .tabItem { Label("LUTs", systemImage: "camera.filters") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
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
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}

// MARK: - Framing

private struct FramingSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Position") {
                PrismSliderRow(label: "Pan X",
                               value: geometryBinding(\.panX),
                               range: -1...1,
                               defaultValue: 0,
                               fractionDigits: 2)
                PrismSliderRow(label: "Pan Y",
                               value: geometryBinding(\.panY),
                               range: -1...1,
                               defaultValue: 0,
                               fractionDigits: 2)
            }
            Section("Crop") {
                Picker("Crop aspect", selection: geometryBinding(\.cropAspect)) {
                    ForEach(CropAspect.allCases, id: \.self) { aspect in
                        Text(aspect.displayName).tag(aspect)
                    }
                }
                Picker("Orientation", selection: geometryBinding(\.orientation)) {
                    ForEach(Orientation.allCases, id: \.self) { orientation in
                        Text("\(orientation.rawValue)°").tag(orientation)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// editingConfig/updateEditing — same shared write path as the popover
    /// and the main window, so no surface can diverge from another.
    private func geometryBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<GeometrySettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { state.editingConfig.geometry[keyPath: keyPath] },
            set: { newValue in
                state.updateEditing { config in
                    config.geometry[keyPath: keyPath] = newValue
                    var flags = config.flags[.geometry] ?? StageFlags()
                    flags.enabled = !config.geometry.isIdentity
                    config.flags[.geometry] = flags
                }
            })
    }
}

// MARK: - Adjust

private struct AdjustSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                PrismSliderRow(label: "Exposure",
                               value: adjustBinding(\.exposureEV),
                               range: -2...2,
                               defaultValue: 0,
                               fractionDigits: 2)
                PrismSliderRow(label: "Contrast",
                               value: adjustBinding(\.contrast),
                               range: 0...2,
                               defaultValue: 1,
                               fractionDigits: 2)
                PrismSliderRow(label: "Saturation",
                               value: adjustBinding(\.saturation),
                               range: 0...2,
                               defaultValue: 1,
                               fractionDigits: 2)
                PrismSliderRow(label: "Temperature",
                               value: adjustBinding(\.temperature),
                               range: -100...100,
                               defaultValue: 0,
                               fractionDigits: 0)
                PrismSliderRow(label: "Vignette",
                               value: adjustBinding(\.vignette),
                               range: 0...1,
                               defaultValue: 0,
                               fractionDigits: 2)
            }
        }
        .formStyle(.grouped)
    }

    private func adjustBinding(
        _ keyPath: WritableKeyPath<AdjustSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { state.editingConfig.adjust[keyPath: keyPath] },
            set: { newValue in
                state.updateEditing { $0.adjust[keyPath: keyPath] = newValue }
            })
    }
}

// MARK: - Formats

private struct FormatsSettingsTab: View {
    @EnvironmentObject var state: AppState

    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var customFPS = ""

    var body: some View {
        Form {
            Section("Published formats") {
                ForEach(VideoFormat.defaultSet) { format in
                    Toggle(format.displayName, isOn: inclusionBinding(format))
                }
            }
            Section("Custom formats") {
                ForEach(customFormats) { format in
                    HStack {
                        Text(format.displayName)
                        Spacer()
                        Button {
                            remove(format)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(format.displayName)")
                    }
                }
                HStack(spacing: Metrics.itemGap) {
                    TextField("Width", text: $customWidth)
                        .frame(width: 60)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: $customHeight)
                        .frame(width: 60)
                    TextField("fps", text: $customFPS)
                        .frame(width: 44)
                    Button("Add") { addCustom() }
                        .disabled(parsedCustom == nil)
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
            }
            Section {
                // §3.2 — mutating the published set is a reconnect boundary.
                Text("Changing this list while apps are streaming makes them reselect PRISM Camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var customFormats: [VideoFormat] {
        state.publishedFormats
            .filter { !VideoFormat.defaultSet.contains($0) }
            .sorted()
    }

    private func inclusionBinding(_ format: VideoFormat) -> Binding<Bool> {
        Binding(
            get: { state.publishedFormats.contains(format) },
            set: { include in
                var formats = state.publishedFormats
                if include {
                    if !formats.contains(format) { formats.append(format) }
                } else {
                    formats.removeAll { $0 == format }
                }
                guard !formats.isEmpty else { return }   // never publish an empty set
                state.requestPublishedFormatsChange(formats.sorted())
            })
    }

    private var parsedCustom: VideoFormat? {
        guard let width = Int(customWidth), let height = Int(customHeight),
              let fps = Int(customFPS),
              (16...7680).contains(width), (16...4320).contains(height),
              (1...240).contains(fps)
        else { return nil }
        let format = VideoFormat(width: width, height: height, frameRate: fps)
        guard !state.publishedFormats.contains(format) else { return nil }
        return format
    }

    private func addCustom() {
        guard let format = parsedCustom else { return }
        var formats = state.publishedFormats
        formats.append(format)
        state.requestPublishedFormatsChange(formats.sorted())
        customWidth = ""
        customHeight = ""
        customFPS = ""
    }

    private func remove(_ format: VideoFormat) {
        var formats = state.publishedFormats
        formats.removeAll { $0 == format }
        guard !formats.isEmpty else { return }
        state.requestPublishedFormatsChange(formats.sorted())
    }
}

// MARK: - LUTs

private struct LUTSettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var luts: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            List(luts, id: \.self) { name in
                Text(name)
            }
            HStack(spacing: Metrics.itemGap) {
                Button("Import…") { importLUT() }
                Button("Reveal in Finder") { revealFolder() }
                Spacer()
            }
        }
        .padding(Metrics.gutter)
        .onAppear { refresh() }
    }

    private func refresh() {
        luts = LUTStore.shared.availableLUTs
    }

    private func importLUT() {
        let panel = NSOpenPanel()
        if let cube = UTType(filenameExtension: "cube") {
            panel.allowedContentTypes = [cube]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                state.importLUT(from: url)
                refresh()
            }
        }
    }

    private func revealFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
        guard let base else { return }
        let lutDir = base.appendingPathComponent("PRISM/LUTs", isDirectory: true)
        let target = FileManager.default.fileExists(atPath: lutDir.path)
            ? lutDir
            : base.appendingPathComponent("PRISM", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
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
        .frame(maxWidth: .infinity, minHeight: 200)
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
