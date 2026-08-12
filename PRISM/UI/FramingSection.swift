// FramingSection.swift
// PRISM
//
// Collapsible Framing section (§8.3): zoom and rotate sliders with numeric
// fields, the "Flip output" mirror toggle with its §5.4 caption, and the
// auto-frame toggle with its cost caption when blur is off. Also defines
// PrismSliderRow, reused by the Settings tabs.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

struct FramingSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                PrismSliderRow(label: "Zoom",
                               value: geometryBinding(\.zoom),
                               range: 1...4,
                               defaultValue: 1,
                               fractionDigits: 1)
                PrismSliderRow(label: "Rotate",
                               value: geometryBinding(\.rotationDegrees),
                               range: -15...15,
                               defaultValue: 0,
                               fractionDigits: 0)
                Toggle("Flip output", isOn: flipBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityValue(state.editingConfig.geometry.mirror != .none ? "on" : "off")
                // §5.4 — a mirror here flips what *others* see.
                Text("Others will see this flipped")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("Auto-frame", isOn: geometryBinding(\.autoFrame))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityValue(state.editingConfig.geometry.autoFrame ? "on" : "off")
                if !state.editingConfig.flags(for: .blur).enabled {
                    // §8.4 — auto-framing rides on the segmentation request.
                    Text("Auto-framing uses the same subject detection as background blur, so it costs about the same")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .prismCard()
        } label: {
            Text("Framing")
                .font(.headline)
        }
    }

    // MARK: - Bindings

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { state.expandedSections.contains(.framing) },
            set: { newValue in
                if newValue != state.expandedSections.contains(.framing) {
                    state.toggleSection(.framing)
                }
            })
    }

    /// Geometry writes keep the stage's enabled flag in sync with identity:
    /// the Framing section has no separate enable switch. updateEditing
    /// keeps this section in lockstep with the main window's Framing pane —
    /// live by default, staged while preview-before-apply is on.
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

    private var flipBinding: Binding<Bool> {
        Binding(
            get: { state.editingConfig.geometry.mirror != .none },
            set: { flipped in
                state.updateEditing { config in
                    config.geometry.mirror = flipped ? .horizontal : .none
                    var flags = config.flags[.geometry] ?? StageFlags()
                    flags.enabled = !config.geometry.isIdentity
                    config.flags[.geometry] = flags
                }
            })
    }
}

// MARK: - Shared slider row

/// Slider + trailing numeric field (§8.3): every slider has a discrete
/// numeric field beside it; Option-drag gives fine adjustment (drag deltas
/// scaled to 1/10 around the current value); double-click resets to the
/// default value.
struct PrismSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var fractionDigits: Int = 1

    var body: some View {
        HStack(spacing: Metrics.itemGap) {
            Text(label)
                .font(.body)
                .frame(width: 64, alignment: .leading)
            Slider(value: sliderValue, in: range)
                .controlSize(.small)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    value = defaultValue
                })
                .accessibilityLabel(label)
                .accessibilityValue(formattedValue)
            TextField("", value: clampedValue,
                      format: .number.precision(.fractionLength(0...max(fractionDigits, 0))))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .accessibilityLabel("\(label) value")
        }
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }

    /// Slider binding with §8.3 Option-drag fine adjustment: while ⌥ is held,
    /// each proposed change is applied at 1/10 gain relative to the current
    /// value, giving a fine effective drag around the point where ⌥ was
    /// pressed.
    private var sliderValue: Binding<Double> {
        Binding(
            get: { value },
            set: { proposed in
                let clamped = min(max(proposed, range.lowerBound), range.upperBound)
                if NSEvent.modifierFlags.contains(.option) {
                    let fine = value + (clamped - value) * 0.1
                    value = min(max(fine, range.lowerBound), range.upperBound)
                } else {
                    value = clamped
                }
            })
    }

    private var formattedValue: String {
        String(format: "%.\(max(fractionDigits, 0))f", value)
    }
}
