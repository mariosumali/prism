// ControlTile.swift
// PRISM
//
// Control Center style toggle tile (§8.3/§8.5): SF Symbol above a label,
// accent fill when active, `.quaternary` when inactive, 0.96 press scale
// gated on Reduce Motion, full VoiceOver labeling.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct ControlTile: View {
    let title: String
    let symbol: String
    let isActive: Bool
    /// Override for the announced value; defaults to "on"/"off".
    var accessibilityValue: String?
    let action: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    init(title: String,
         symbol: String,
         isActive: Bool,
         accessibilityValue: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isActive = isActive
        self.accessibilityValue = accessibilityValue
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                    // §8.5 — active tiles gain a filled variant, not just a fill.
                    .symbolVariant(differentiateWithoutColor && isActive ? .fill : .none)
                Text(title)
                    .font(.body)
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.tileHeight)
            .background(
                RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous))
        }
        .buttonStyle(TilePressButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? (isActive ? "on" : "off"))
    }
}

/// Momentary press feedback at 0.96 scale (§8.3), disabled under Reduce Motion.
struct TilePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1.0)
            .animation(reduceMotion ? nil : Motion.stateChange, value: configuration.isPressed)
    }
}
