// ScenePane.swift
// PRISM
//
// Everything that changes what is in frame besides you: the background
// (§5.4 blur / §5.7 replacement), overlay layers with chroma and luma keying
// and frame- or face-anchored placement (§5.8), and eye-contact correction
// (§5.6). Edits stage into the draft like every other editing surface, so the
// Apply bar previews them privately before any client app sees them.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScenePane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PanePreview()
                .padding([.top, .horizontal], Metrics.gutter)
            form
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            SceneDropImporter.handle(providers, state: state)
        }
    }

    private var form: some View {
        Form {
            backgroundSection
            eyeContactSection
            overlaySection
        }
        .formStyle(.grouped)
    }

    // MARK: - Background

    private var backgroundSection: some View {
        Section("Background") {
            Picker("Behind me", selection: backgroundModeBinding) {
                ForEach(BackgroundMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch state.backgroundMode {
            case .off:
                Text("Your real background, untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .blur:
                Picker("Quality", selection: blurQualityBinding) {
                    ForEach(BlurQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                PrismSliderRow(label: "Radius",
                               value: blurRadiusBinding,
                               range: 2...48,
                               defaultValue: 18,
                               fractionDigits: 0)
            case .color:
                ColorPicker("Colour", selection: backgroundColorBinding, supportsOpacity: false)
                edgeControls
            case .image, .video:
                assetRow
                Picker("Fit", selection: fillModeBinding) {
                    Text("Fill").tag(ClipFillMode.fill)
                    Text("Letterbox").tag(ClipFillMode.letterbox)
                }
                .pickerStyle(.segmented)
                edgeControls
            }

            if state.backgroundMode != .off, state.backgroundMode != .blur {
                Text("A replaced background never falls back to your real room: if the file is still opening, PRISM shows the colour instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var edgeControls: some View {
        PrismSliderRow(label: "Edge sharpness",
                       value: backgroundBinding(\.maskContrast),
                       range: 1...4,
                       defaultValue: 1.4,
                       fractionDigits: 2)
        PrismSliderRow(label: "Edge softness",
                       value: backgroundBinding(\.edgeSoftness),
                       range: 0...1,
                       defaultValue: 0.3,
                       fractionDigits: 2)
        PrismSliderRow(label: "Light wrap",
                       value: backgroundBinding(\.lightWrap),
                       range: 0...1,
                       defaultValue: 0.25,
                       fractionDigits: 2)
        Text("Light wrap bleeds the new background into your outline. A little of it is the difference between a composite and a sticker.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var assetRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Text(backgroundAssetName ?? "No file chosen")
                .foregroundStyle(backgroundAssetName == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") { chooseBackground() }
            if backgroundAssetName != nil {
                Button("Clear") { state.setBackgroundAsset(nil) }
            }
        }
    }

    private var backgroundAssetName: String? {
        state.editingConfig.background.assetURL?.lastPathComponent
    }

    // MARK: - Eye contact

    private var eyeContactSection: some View {
        Section("Eye contact") {
            HStack(spacing: Metrics.sectionGap) {
                Toggle("Enabled", isOn: enabledBinding(.gaze))
                Toggle("Required", isOn: pinnedBinding(.gaze))
                    .help("Never auto-disabled to meet the latency budget (§3.4)")
                Spacer()
                Text(state.editingConfig.flags(for: .gaze).enabled
                     ? (state.eyeContactTracking ? "Tracking" : "Looking for your eyes…")
                     : "Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PrismSliderRow(label: "Strength",
                           value: gazeBinding(\.strength),
                           range: 0...1,
                           defaultValue: 0.75,
                           fractionDigits: 2)
            PrismSliderRow(label: "Camera height",
                           value: gazeBinding(\.verticalBias),
                           range: -1...1,
                           defaultValue: 1,
                           fractionDigits: 2)
            PrismSliderRow(label: "Maximum shift",
                           value: gazeBinding(\.maxShift),
                           range: 0...1,
                           defaultValue: 0.5,
                           fractionDigits: 2)
            PrismSliderRow(label: "Steadiness",
                           value: gazeBinding(\.smoothing),
                           range: 0...0.98,
                           defaultValue: 0.8,
                           fractionDigits: 2)
            Text("PRISM measures how far your pupils have drifted from the centre of your own eyes and pulls part of that back, so it works out where your camera is by itself. Raise Camera height if your webcam sits well above the screen you actually look at.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This moves the eyes you have; it does not invent new ones. Past about half an iris width the effect starts to show, which is what Maximum shift is holding back.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Overlay layers

    private var overlaySection: some View {
        Section("Overlay layers") {
            HStack(spacing: Metrics.sectionGap) {
                Toggle("Enabled", isOn: enabledBinding(.overlay))
                Toggle("Required", isOn: pinnedBinding(.overlay))
                Spacer()
                // One action, not a choice: the only picture-in-picture
                // worth having is of the feed that is not already the
                // picture, so the button names what you will get (§8.7).
                Button(state.isSharingScreen ? "Add me" : "Add my screen") {
                    state.addPictureInPicture()
                }
                .disabled(state.editingConfig.overlay.layers.count
                          >= OverlaySettings.maxLayers)
                Button("Add layer…") { chooseLayer() }
                    .disabled(state.editingConfig.overlay.layers.count
                              >= OverlaySettings.maxLayers)
            }

            if state.editingConfig.overlay.layers.isEmpty {
                Text("Drop an image or video anywhere on this pane, or use Add layer. A PNG with alpha composites as-is; a green-screen clip gets keyed. Put a layer behind you and you are standing in front of it, or pin it to your face and it rides along — a hat above your head, glasses on the eye line, a moustache under your nose. The other button puts whichever feed is not on air into the corner of the one that is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.editingConfig.overlay.layers) { layer in
                    LayerEditor(layer: layer)
                }
                Text("Layers composite bottom-up, up to \(OverlaySettings.maxLayers). Each one is a compute pass and, for video, its own decoder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.editingConfig.overlay.needsFaceTracker {
                    Text(state.faceAnchorTracking
                         ? "Tracking your face."
                         : "Looking for your face… a layer pinned to it stays hidden until one is found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - File pickers

    private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = state.backgroundMode == .video
            ? [.movie, .mpeg4Movie, .quickTimeMovie]
            : [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { state.setBackgroundAsset(url) }
        }
    }

    private func chooseLayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { state.addOverlayLayer(url: url) }
        }
    }

    // MARK: - Bindings

    private var backgroundModeBinding: Binding<BackgroundMode> {
        Binding(get: { state.backgroundMode }, set: { state.setBackgroundMode($0) })
    }

    private func backgroundBinding(
        _ keyPath: WritableKeyPath<BackgroundSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { state.editingConfig.background[keyPath: keyPath] },
            set: { value in state.updateEditing { $0.background[keyPath: keyPath] = value } })
    }

    private func gazeBinding(
        _ keyPath: WritableKeyPath<GazeSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { state.editingConfig.gaze[keyPath: keyPath] },
            set: { value in state.updateEditing { $0.gaze[keyPath: keyPath] = value } })
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: {
                let rgb = state.editingConfig.background.color
                return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                let components = NSColor(color).usingColorSpace(.sRGB)
                state.updateEditing {
                    $0.background.color = RGBColor(
                        red: Double(components?.redComponent ?? 0.1),
                        green: Double(components?.greenComponent ?? 0.1),
                        blue: Double(components?.blueComponent ?? 0.1))
                }
            })
    }

    private var fillModeBinding: Binding<ClipFillMode> {
        Binding(
            get: { state.editingConfig.background.fillMode },
            set: { mode in state.updateEditing { $0.background.fillMode = mode } })
    }

    private var blurQualityBinding: Binding<BlurQuality> {
        Binding(
            get: { state.editingConfig.blur.quality },
            set: { quality in state.updateEditing { $0.blur.quality = quality } })
    }

    private var blurRadiusBinding: Binding<Double> {
        Binding(
            get: { state.editingConfig.blur.radius },
            set: { radius in state.updateEditing { $0.blur.radius = radius } })
    }

    private func enabledBinding(_ id: StageID) -> Binding<Bool> {
        Binding(
            get: { state.editingConfig.flags(for: id).enabled },
            set: { state.setStageEnabled(id, $0) })
    }

    private func pinnedBinding(_ id: StageID) -> Binding<Bool> {
        Binding(
            get: { state.editingConfig.flags(for: id).pinned },
            set: { state.setStagePinned(id, $0) })
    }
}

// MARK: - One layer's controls

private struct LayerEditor: View {
    @EnvironmentObject var state: AppState
    let layer: OverlayLayer

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                if layer.sourceKind == .live {
                    liveFeedControls
                }
                Picker("Placement", selection: binding(\.placement)) {
                    ForEach(LayerPlacement.allCases, id: \.self) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Key", selection: binding(\.keyMode)) {
                    ForEach(KeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch layer.keyMode {
                case .none:
                    Text("Composited using the file's own alpha channel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .chroma:
                    ColorPicker("Key colour", selection: keyColorBinding, supportsOpacity: false)
                    PrismSliderRow(label: "Similarity", value: binding(\.similarity),
                                   range: 0...1, defaultValue: 0.2, fractionDigits: 2)
                    PrismSliderRow(label: "Softness", value: binding(\.smoothness),
                                   range: 0.001...1, defaultValue: 0.1, fractionDigits: 2)
                    PrismSliderRow(label: "Despill", value: binding(\.spill),
                                   range: 0...1, defaultValue: 0.5, fractionDigits: 2)
                    Text("Despill pulls what is left of the key colour out of the edges, so a green screen stops tinting your hair.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .luma:
                    PrismSliderRow(label: "Black point", value: binding(\.lumaLow),
                                   range: 0...1, defaultValue: 0.05, fractionDigits: 2)
                    PrismSliderRow(label: "White point", value: binding(\.lumaHigh),
                                   range: 0.001...1, defaultValue: 0.25, fractionDigits: 2)
                }

                Divider()
                Picker("Pinned to", selection: binding(\.anchor)) {
                    ForEach(LayerAnchor.allCases, id: \.self) { anchor in
                        Text(anchor.displayName).tag(anchor)
                    }
                }
                .pickerStyle(.segmented)

                if layer.anchor == .face {
                    Picker("Sits on", selection: binding(\.facePoint)) {
                        ForEach(FaceAnchorPoint.allCases, id: \.self) { point in
                            Text(point.displayName).tag(point)
                        }
                    }
                    Toggle("Tilt with my head", isOn: binding(\.followsRoll))
                    Text("Size is measured against your face, not the frame: at 1 the layer is exactly as wide as you are, so a prop keeps its proportion as you lean in and back out. Horizontal and Vertical move it in face widths.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("If PRISM loses your face the layer fades out and waits, rather than hanging in the air where your head used to be. It fades back the moment you are found again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PrismSliderRow(label: "Size", value: binding(\.scale),
                               range: 0.05...4, defaultValue: 1, fractionDigits: 2)
                PrismSliderRow(label: "Horizontal", value: binding(\.offsetX),
                               range: -1...1, defaultValue: 0, fractionDigits: 2)
                PrismSliderRow(label: "Vertical", value: binding(\.offsetY),
                               range: -1...1, defaultValue: 0, fractionDigits: 2)
                PrismSliderRow(label: "Rotation", value: binding(\.rotationDegrees),
                               range: -180...180, defaultValue: 0, fractionDigits: 0,
                               unit: "°")
                PrismSliderRow(label: "Opacity", value: binding(\.opacity),
                               range: 0...1, defaultValue: 1, fractionDigits: 2)
                Toggle("Flip horizontally", isOn: binding(\.mirrored))

                HStack {
                    Spacer()
                    Button("Remove layer", role: .destructive) {
                        state.removeOverlayLayer(layer.id)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: Metrics.itemGap) {
                Toggle("", isOn: binding(\.isEnabled))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("\(layer.name) enabled")
                Image(systemName: Self.symbol(for: layer.sourceKind))
                    .foregroundStyle(.secondary)
                Text(layer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(layer.anchor == .face
                     ? layer.facePoint.displayName
                     : layer.placement.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func symbol(for kind: LayerSourceKind) -> String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .text: return "textformat"
        case .live: return "pip"
        }
    }

    /// §5.25 — what a live layer is looking at, and which screen that means.
    /// The feed picker is here rather than beside the source picker because
    /// it is a property of this layer; the screen picker below it is the same
    /// control as the source's, so the two can never disagree about which
    /// screen PRISM is capturing.
    @ViewBuilder
    private var liveFeedControls: some View {
        Picker("Showing", selection: feedBinding) {
            ForEach(LiveLayerFeed.allCases, id: \.self) { feed in
                Text(feed.displayName).tag(Optional(feed))
            }
        }
        .pickerStyle(.segmented)

        if layer.liveFeed == .screen, !state.isSharingScreen {
            Picker("Screen", selection: screenBinding) {
                ForEach(state.screenSources) { source in
                    Text(source.displayName)
                        .tag(VideoSourceSelection(kind: source.kind, sourceID: source.id))
                }
            }
        }
        if let reason = unavailableReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("A live layer holds still whenever the picture does — freeze, replay, away or panic — so nothing in the corner can keep moving under a frozen frame.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The one state a live layer can be in that looks broken and is not.
    private var unavailableReason: String? {
        switch layer.liveFeed {
        case .camera where !state.isSharingScreen:
            return "The camera is already the picture, so this draws nothing. Share a screen and it becomes you, in the corner."
        case .screen where state.isSharingScreen:
            return "The screen is already the picture, so this draws nothing."
        case .screen where state.setup.screenRecording != .granted:
            return "Screens need Screen Recording permission."
        default:
            return nil
        }
    }

    private var feedBinding: Binding<LiveLayerFeed?> {
        Binding(
            get: {
                state.editingConfig.overlay.layers
                    .first { $0.id == layer.id }?.liveFeed ?? layer.liveFeed
            },
            set: { value in
                state.updateOverlayLayer(layer.id) { $0.liveFeed = value }
            })
    }

    private var screenBinding: Binding<VideoSourceSelection> {
        Binding(
            get: { state.screenFeed },
            set: { state.selectScreenFeed($0) })
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<OverlayLayer, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                state.editingConfig.overlay.layers
                    .first { $0.id == layer.id }?[keyPath: keyPath]
                    ?? layer[keyPath: keyPath]
            },
            set: { value in
                state.updateOverlayLayer(layer.id) { $0[keyPath: keyPath] = value }
            })
    }

    private var keyColorBinding: Binding<Color> {
        Binding(
            get: {
                let rgb = state.editingConfig.overlay.layers
                    .first { $0.id == layer.id }?.keyColor ?? layer.keyColor
                return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                let components = NSColor(color).usingColorSpace(.sRGB)
                state.updateOverlayLayer(layer.id) {
                    $0.keyColor = RGBColor(
                        red: Double(components?.redComponent ?? 0),
                        green: Double(components?.greenComponent ?? 0.7),
                        blue: Double(components?.blueComponent ?? 0.1))
                }
            })
    }
}

// MARK: - Drag and drop

/// Dropping an image or video onto the Scene pane adds it as a layer — the
/// same affordance as dropping a .cube to import a LUT.
@MainActor
enum SceneDropImporter {
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
                guard let fileURL = url else { return }
                let ext = fileURL.pathExtension.lowercased()
                guard ext != "cube" else {
                    DispatchQueue.main.async { state.importLUT(from: fileURL) }
                    return
                }
                guard let type = UTType(filenameExtension: ext),
                      type.conforms(to: .image) || type.conforms(to: .movie) else { return }
                DispatchQueue.main.async { state.addOverlayLayer(url: fileURL) }
            }
        }
        return accepted
    }
}
