// DesignSystem.swift
// PRISM
//
// Design tokens (§8.1), motion constants gated on Reduce Motion, and the
// shared card treatment. Semantic system colors only — the latency meter's
// green/yellow/red threshold colors are the one exception and live in
// LatencyMeter.swift.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

// §8.1 — exact values; do not tune.
enum Metrics {
    static let popoverWidth: CGFloat  = 320
    static let gutter: CGFloat        = 16   // popover horizontal inset
    static let sectionGap: CGFloat    = 16
    static let itemGap: CGFloat       = 8
    static let cardRadius: CGFloat    = 10
    static let tileRadius: CGFloat    = 10
    static let controlRadius: CGFloat = 6
    static let tileHeight: CGFloat    = 64
}

/// §8.1 Motion — `.easeOut` 0.2s for state changes, spring for the popover.
/// Everything is gated behind Reduce Motion: pass the environment value in,
/// or use `.prismAnimation(_:value:)` which reads it for you.
enum Motion {
    static let stateChange: Animation = .easeOut(duration: 0.2)
    static let popoverSpring: Animation = .spring(response: 0.3, dampingFraction: 0.85)

    /// Returns nil (no animation) when Reduce Motion is enabled.
    static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct PrismAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Card treatment for popover sections: `.quaternary` fill at `cardRadius`.
/// Swaps to opaque window background when Reduce Transparency is on (§8.5).
private struct PrismCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(Metrics.itemGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(reduceTransparency
                          ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                          : AnyShapeStyle(.quaternary))
            )
    }
}

extension View {
    /// Section card per §8.3: `.quaternary` background at `cardRadius`.
    func prismCard() -> some View {
        modifier(PrismCardModifier())
    }

    /// `.animation(_:value:)` that respects Reduce Motion (§8.5).
    func prismAnimation<Value: Equatable>(_ animation: Animation = Motion.stateChange,
                                          value: Value) -> some View {
        modifier(PrismAnimationModifier(animation: animation, value: value))
    }
}
