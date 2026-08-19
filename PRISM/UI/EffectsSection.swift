// EffectsSection.swift
// PRISM
//
// Collapsible Effects section (§8.3): Adjust, Skin, LUT, Style, and Blur rows with
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
                effectRow(.retouch, title: "Skin") {
                    EmptyView()
                }
                effectRow(.lut, title: "LUT") {
                    lutPicker
                }
                effectRow(.style, title: "Style") {
                    stylePicker
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

    /// The cost column is reserved for the whole section as soon as any one
    /// stage reports a number, so the switches hold a single vertical line
    /// instead of jogging sideways as stages are turned on and off.
    private var showsCostColumn: Bool {
        [StageID.adjust, .retouch, .lut, .style, .blur].contains {
            (state.stageStatus[$0] ?? StageStatus()).measuredMs > 0
        }
    }

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
                if showsCostColumn {
                    // §8.6 — per-stage cost inline, .caption2 .secondary.
                    Text(status.measuredMs > 0
                         ? String(format: "%.1f ms", status.measuredMs) : "")
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
    /// here can otherwise look permanently broken (§8.4). Style's intensity
    /// slider lives there too, so an intensity of 0 is the same trap: picking
    /// looks here changes nothing until the main window fixes the slider, and
    /// Skin's one knob is the same again.
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
            } else if id == .style, state.editingConfig.style.intensity <= 0 {
                Button("Set intensity…") { state.showMainWindow() }
                    .buttonStyle(.link)
                    .font(.caption2)
            } else if id == .retouch {
                Button("Set amount…") { state.showMainWindow() }
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

    private var stylePicker: some View {
        Picker("Style", selection: styleEffectBinding) {
            Text(StyleEffect.normal.displayName).tag(StyleEffect.normal)
            Section("Distortions") {
                ForEach(StyleEffect.distortions) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
            Section("Motion") {
                ForEach(StyleEffect.motion) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
            Section("Looks") {
                ForEach(StyleEffect.looks) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Style")
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

    private var styleEffectBinding: Binding<StyleEffect> {
        Binding(
            get: { state.editingConfig.style.effect },
            set: { state.setStyleEffect($0) })
    }

    private var blurQualityBinding: Binding<BlurQuality> {
        Binding(
            get: { state.editingConfig.blur.quality },
            set: { quality in
                state.updateEditing { $0.blur.quality = quality }
            })
    }
}
