// SceneSection.swift
// PRISM
//
// The popover's Scene section (§8.3): the one "what is behind me" control
// plus the eye-contact toggle. Deeper scene editing — overlay layers, key
// tuning, edge softness — lives in the main window's Scene pane, per the
// progressive-disclosure rule: a user who wants a blurred background never
// sees a chroma-key slider.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SceneSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                backgroundRow
                if state.backgroundMode.needsAsset {
                    assetRow
                }
                Divider()
                eyeContactRow
                if state.editingConfig.flags(for: .overlay).enabled,
                   !state.editingConfig.overlay.renderableLayers.isEmpty {
                    overlayRow
                }
            }
            .prismCard()
        } label: {
            Text("Scene")
                .font(.headline)
        }
    }

    // MARK: - Background

    private var backgroundRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Text("Background")
                .font(.body)
            Spacer(minLength: 0)
            Picker("Background", selection: backgroundModeBinding) {
                ForEach(BackgroundMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Background")
            costLabel(for: state.backgroundMode == .blur ? .blur : .background)
        }
    }

    private var assetRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Text(assetName ?? "No file chosen")
                .font(.caption)
                .foregroundStyle(assetName == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Choose…") { chooseBackground() }
                .controlSize(.small)
        }
    }

    private var assetName: String? {
        state.editingConfig.background.assetURL?
            .deletingPathExtension().lastPathComponent
    }

    // MARK: - Eye contact

    private var eyeContactRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Metrics.itemGap) {
                Text("Eye contact")
                    .font(.body)
                Spacer(minLength: 0)
                Toggle("Eye contact", isOn: eyeContactBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("Eye contact")
                    .accessibilityValue(state.editingConfig.flags(for: .gaze).enabled
                                        ? "on" : "off")
                costLabel(for: .gaze)
            }
            if state.editingConfig.flags(for: .gaze).enabled {
                Text(state.eyeContactTracking
                     ? "Tracking your eyes"
                     : "Looking for your eyes…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var overlayRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Text("Overlay")
                .font(.body)
            Spacer(minLength: 0)
            Text(layerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Overlay", isOn: overlayBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Overlay layers")
            costLabel(for: .overlay)
        }
    }

    private var layerSummary: String {
        let count = state.editingConfig.overlay.renderableLayers.count
        return count == 1 ? "1 layer" : "\(count) layers"
    }

    // MARK: - Shared

    @ViewBuilder
    private func costLabel(for id: StageID) -> some View {
        let measured = (state.stageStatus[id] ?? StageStatus()).measuredMs
        if measured > 0 {
            // §8.6 — per-stage cost inline, .caption2 .secondary.
            Text(String(format: "%.1f ms", measured))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = state.backgroundMode == .video
            ? [.movie, .mpeg4Movie, .quickTimeMovie]
            : [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                state.setBackgroundAsset(url)
            }
        }
    }

    // MARK: - Bindings

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { state.expandedSections.contains(.scene) },
            set: { newValue in
                if newValue != state.expandedSections.contains(.scene) {
                    state.toggleSection(.scene)
                }
            })
    }

    private var backgroundModeBinding: Binding<BackgroundMode> {
        Binding(
            get: { state.backgroundMode },
            set: { state.setBackgroundMode($0) })
    }

    private var eyeContactBinding: Binding<Bool> {
        Binding(
            get: { state.editingConfig.flags(for: .gaze).enabled },
            set: { state.setStageEnabled(.gaze, $0) })
    }

    private var overlayBinding: Binding<Bool> {
        Binding(
            get: { state.editingConfig.flags(for: .overlay).enabled },
            set: { state.setStageEnabled(.overlay, $0) })
    }
}
