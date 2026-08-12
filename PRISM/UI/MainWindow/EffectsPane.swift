// EffectsPane.swift
// PRISM
//
// The full effects chain over a live preview, one section per stage:
// enable + "require" (pin, §3.4 — exempt from automatic degradation) + live
// measured cost, then every parameter. Adjust's five sliders, LUT
// choice/strength/import, blur quality/radius. Edits stage into the draft
// (previewed privately, applied from the Apply bar). Radius and strength
// are clamped again by the stages, so the slider ranges here are UI
// ergonomics, not safety.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EffectsPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PanePreview()
                .padding([.top, .horizontal], Metrics.gutter)
            form
        }
    }

    private var form: some View {
        Form {
            Section("Adjust") {
                stageHeader(.adjust)
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
                Button("Reset adjustments") {
                    state.updateEditing { $0.adjust = AdjustSettings() }
                }
                .disabled(state.editingConfig.adjust.isIdentity)
            }
            Section("LUT") {
                stageHeader(.lut)
                Picker("LUT", selection: lutNameBinding) {
                    ForEach(LUTStore.shared.availableLUTs, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                PrismSliderRow(label: "Strength",
                               value: lutStrengthBinding,
                               range: 0...1,
                               defaultValue: 1,
                               fractionDigits: 2)
                HStack(spacing: Metrics.itemGap) {
                    Button("Import…") { importLUT() }
                    Button("Reveal in Finder") { revealLUTFolder() }
                }
                Text("PRISM imports .cube files — or drop one anywhere on this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Background") {
                // Blur is one answer to "what is behind me", and virtual
                // backgrounds are the others — they are mutually exclusive
                // and belong under one control, which lives in Scene.
                LabeledContent("Currently", value: state.backgroundMode.displayName)
                Text("Background blur and virtual backgrounds are the same choice, so they share one control in the Scene pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("A required effect is never turned off automatically when effects exceed the latency budget — the others degrade first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shared stage header row

    @ViewBuilder
    private func stageHeader(_ id: StageID) -> some View {
        let status = state.stageStatus[id] ?? StageStatus()
        HStack(spacing: Metrics.sectionGap) {
            Toggle("Enabled", isOn: enabledBinding(id))
            Toggle("Required", isOn: pinnedBinding(id))
                .help("Never auto-disabled to meet the latency budget (§3.4)")
            Spacer()
            if status.measuredMs > 0 {
                // Costs are measured on the live chain; mid-draft the
                // controls describe the staged look, so label the number.
                Text(String(format: state.draftConfig == nil ? "%.1f ms" : "%.1f ms live",
                            status.measuredMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("GPU cost measured on the live camera output")
            }
        }
        if status.autoDisabled {
            Text(state.draftConfig == nil
                 ? "Off to keep video smooth"
                 : "Off on the live camera to keep video smooth")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings (updateEditing: live by default, staged mid-draft)

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

    private func adjustBinding(
        _ keyPath: WritableKeyPath<AdjustSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { state.editingConfig.adjust[keyPath: keyPath] },
            set: { newValue in
                state.updateEditing { $0.adjust[keyPath: keyPath] = newValue }
            })
    }

    private var lutNameBinding: Binding<String> {
        Binding(
            get: { state.editingConfig.lut.lutName },
            set: { name in
                state.updateEditing { $0.lut.lutName = name }
            })
    }

    private var lutStrengthBinding: Binding<Double> {
        Binding(
            get: { state.editingConfig.lut.strength },
            set: { strength in
                state.updateEditing { $0.lut.strength = strength }
            })
    }

    // MARK: - LUT import

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
            }
        }
    }

    private func revealLUTFolder() {
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
