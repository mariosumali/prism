// EffectsSection.swift
// PRISM
//
// Collapsible Effects section (§8.3): Adjust, LUT, and Blur rows with
// per-stage measured cost at .caption2 secondary, inline pickers, pin
// ("Require this effect") via context menu, and the auto-disabled caption.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct EffectsSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                effectRow(.adjust, title: "Adjust") {
                    EmptyView()
                }
                effectRow(.lut, title: "LUT") {
                    lutPicker
                }
                effectRow(.blur, title: "Blur") {
                    blurQualityPicker
                }
            }
            .prismCard()
        } label: {
            Text("Effects")
                .font(.headline)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func effectRow<Accessory: View>(
        _ id: StageID,
        title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        let status = state.stageStatus[id] ?? StageStatus()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Metrics.itemGap) {
                Text(title)
                    .font(.body)
                Spacer(minLength: 0)
                accessory()
                Toggle(title, isOn: enabledBinding(id))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel(title)
                    .accessibilityValue(state.editingConfig.flags(for: id).enabled ? "on" : "off")
                if status.measuredMs > 0 {
                    // §8.6 — per-stage cost inline, .caption2 .secondary.
                    Text(String(format: "%.1f ms", status.measuredMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            if status.autoDisabled {
                Text("Off to keep video smooth")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let reason = state.editingConfig.inertReason(id) {
                inertCaption(id, reason: reason)
            }
        }
        .contextMenu {
            // §3.4 — pinning exempts a stage from automatic degradation.
            Toggle("Require this effect", isOn: pinnedBinding(id))
        }
    }

    /// A switch that is on and changing nothing says so — and, where this
    /// popover holds no control that would fix it, points at the surface that
    /// does. Adjust's five parameters live only in the main window, so its row
    /// here can otherwise look permanently broken (§8.4).
    @ViewBuilder
    private func inertCaption(_ id: StageID, reason: String) -> some View {
        HStack(spacing: Metrics.itemGap) {
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if id == .adjust {
                Button("Set adjustments…") { state.showMainWindow() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
    }

    private var lutPicker: some View {
        Picker("LUT", selection: lutNameBinding) {
            ForEach(LUTStore.shared.availableLUTs, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("LUT")
    }

    private var blurQualityPicker: some View {
        Picker("Blur quality", selection: blurQualityBinding) {
            ForEach(BlurQuality.allCases, id: \.self) { quality in
                Text(quality.displayName).tag(quality)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Blur quality")
    }

    // MARK: - Bindings

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { state.expandedSections.contains(.effects) },
            set: { newValue in
                if newValue != state.expandedSections.contains(.effects) {
                    state.toggleSection(.effects)
                }
            })
    }

    // editingConfig/updateEditing keep these rows in lockstep with the main
    // window's Effects pane — live by default, staged while
    // preview-before-apply is on.

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

    private var lutNameBinding: Binding<String> {
        Binding(
            get: { state.editingConfig.lut.lutName },
            set: { name in state.setLUTName(name) })
    }

    private var blurQualityBinding: Binding<BlurQuality> {
        Binding(
            get: { state.editingConfig.blur.quality },
            set: { quality in
                state.updateEditing { $0.blur.quality = quality }
            })
    }
}
