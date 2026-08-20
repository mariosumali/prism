// FramingSection.swift
// PRISM
//
// Collapsible Framing section (§8.3): zoom and rotate sliders with numeric
// fields, the "Flip output" mirror toggle with its §5.4 caption, and the
// auto-frame toggle with its cost caption when blur is off. Also defines
// PrismSliderRow, the labelled slider every pane in the main window uses.
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
                               range: -180...180,
                               defaultValue: 0,
                               fractionDigits: 0,
                               unit: "°")
                Toggle("Flip output", isOn: flipBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityValue(state.editingConfig.geometry.mirror != .none ? "on" : "off")
                    // §5.4 — a mirror here flips what *others* see. The
                    // warning belongs to the flipped state; standing under
                    // an off switch it is just noise on every open.
                    .help("Others will see this flipped")
                if state.editingConfig.geometry.mirror != .none {
                    Text("Others will see this flipped")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Toggle("Auto-frame", isOn: geometryBinding(\.autoFrame))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityValue(state.editingConfig.geometry.autoFrame ? "on" : "off")
                    .help(autoFrameCostNote)
                if state.editingConfig.geometry.autoFrame,
                   !state.editingConfig.flags(for: .blur).enabled {
                    // §8.4 — auto-framing rides on the segmentation request,
                    // which is news once you have actually turned it on.
                    Text(autoFrameCostNote)
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

    private var autoFrameCostNote: String {
        "Auto-framing uses the same subject detection as background blur, so it costs about the same"
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
///
/// The field is the exact-entry path — type `1500` (or `1500 ms`) and press
/// Return — so it is sized to actually hold the widest value the range can
/// produce. A four-digit millisecond value in a field cut for `0.5` is a
/// control that displays the number it will not let you read.
struct PrismSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var fractionDigits: Int = 1
    /// Suffix carried inside the numeric field (`12°`). Empty for the bare
    /// 0…1 amounts, which have no unit to name.
    var unit: String = ""
    /// Drag increment, in the value's own units; 0 leaves the drag
    /// continuous. Wide ranges (200…9500 ms is ~46 ms per point of travel)
    /// set this so an ordinary drag lands on round numbers; Option-drag and
    /// the field both stay exact, so snapping never costs precision.
    var snap: Double = 0

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
                      format: PrismUnitFormat(fractionDigits: fractionDigits, unit: unit))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
                .accessibilityLabel("\(label) value")
        }
    }

    /// Wide enough for the longest value this range can show. Never narrower
    /// than the historical 48pt, so every existing row keeps its layout.
    private var fieldWidth: CGFloat {
        let format = PrismUnitFormat(fractionDigits: fractionDigits, unit: unit)
        let longest = [range.lowerBound, range.upperBound]
            .map { format.format($0).count }
            .max() ?? 4
        return max(48, CGFloat(longest) * 6.5 + 14)
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { value = clamped($0) })
    }

    /// Slider binding with §8.3 Option-drag fine adjustment: while ⌥ is held,
    /// each proposed change is applied at 1/10 gain relative to the current
    /// value, giving a fine effective drag around the point where ⌥ was
    /// pressed. Option-drag is also the exact path on a snapped row — the
    /// modifier already means "finer than the default gesture".
    private var sliderValue: Binding<Double> {
        Binding(
            get: { value },
            set: { proposed in
                if NSEvent.modifierFlags.contains(.option) {
                    value = clamped(value + (clamped(proposed) - value) * 0.1)
                } else {
                    value = clamped(snapped(clamped(proposed)))
                }
            })
    }

    private func clamped(_ proposed: Double) -> Double {
        min(max(proposed, range.lowerBound), range.upperBound)
    }

    private func snapped(_ proposed: Double) -> Double {
        guard snap > 0 else { return proposed }
        return (proposed / snap).rounded() * snap
    }

    private var formattedValue: String {
        String(format: "%.\(max(fractionDigits, 0))f", value) + unit
    }
}

/// Numeric-field format that keeps a unit inside the field (`12°`) instead of
/// spending a separate label on it, so §8.3's row widths hold. Typed input is
/// accepted with or without the suffix.
///
/// Grouping separators are off: these are fields you type exact values into,
/// and `3000 ms` is both shorter and more obviously a precise figure than
/// `3,000 ms`. Pasted separators still parse.
struct PrismUnitFormat: ParseableFormatStyle {
    var fractionDigits: Int
    var unit: String

    var parseStrategy: PrismUnitParseStrategy { PrismUnitParseStrategy(unit: unit) }

    func format(_ value: Double) -> String {
        let digits = max(fractionDigits, 0)
        return value.formatted(
            .number.precision(.fractionLength(0...digits)).grouping(.never)) + unit
    }
}

struct PrismUnitParseStrategy: ParseStrategy {
    var unit: String

    func parse(_ value: String) throws -> Double {
        var text = value.trimmingCharacters(in: .whitespaces)
        // The unit is a display affordance, so every way of typing it is
        // accepted — `1500`, `1500 ms`, `1500ms`, `1500 MS`. Matching only
        // the exact " ms" suffix would reject the spacing most people
        // actually type and silently revert the field to its old value.
        let bare = unit.trimmingCharacters(in: .whitespaces)
        if !bare.isEmpty,
           let found = text.range(of: bare, options: [.caseInsensitive, .backwards]) {
            text.removeSubrange(found)
        }
        return try FloatingPointFormatStyle<Double>()
            .parseStrategy
            .parse(text.trimmingCharacters(in: .whitespaces))
    }
}
