// LatencyMeter.swift
// PRISM
//
// The always-visible latency bar (§8.6): 4pt bar, fill = totalAddedMs /
// budgetMs, green/yellow/red thresholds (the one sanctioned exception to
// semantic-colors-only), 1s exponential smoothing, hover breakdown popover,
// click expands the Format section.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct LatencyMeter: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Tap affordance, surface-specific: the popover expands its Format
    /// section (§8.6), the Studio pane navigates to Format & Latency, and a
    /// meter sitting next to the policy control (FormatPane) passes nil for
    /// a plain read-only meter — no button traits, no dead tap.
    var onTap: (() -> Void)?
    var tapHint: String?

    @State private var displayedMs: Double = 0
    @State private var lastUpdate: Date?
    @State private var showBreakdown = false

    /// §8.6 — 1 second smoothing time constant.
    private static let smoothingSeconds: Double = 1.0

    var body: some View {
        let report = state.latency
        let budget = max(report.budgetMs, 0.001)
        let fraction = max(displayedMs / budget, 0)

        HStack(spacing: Metrics.itemGap) {
            bar(fraction: fraction)
                .frame(height: 4)
            Text(trailingLabel(fraction: fraction, budget: budget))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            showBreakdown = hovering
        }
        .popover(isPresented: $showBreakdown, arrowEdge: .bottom) {
            breakdown(report)
        }
        .onTapGesture {
            // §8.6 — the meter is the affordance that leads to the setting.
            onTap?()
        }
        .onAppear {
            displayedMs = report.totalAddedMs
            lastUpdate = Date()
        }
        .onChange(of: report.totalAddedMs) { newValue in
            let now = Date()
            let dt = lastUpdate.map { now.timeIntervalSince($0) } ?? 0.25
            lastUpdate = now
            let alpha = 1 - exp(-dt / Self.smoothingSeconds)
            displayedMs += (newValue - displayedMs) * alpha
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Added latency")
        .accessibilityValue(String(format: "%.1f of %.1f milliseconds",
                                   displayedMs, budget))
        .accessibilityHint(onTap == nil ? "" : (tapHint ?? ""))
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }

    // MARK: - Bar

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            // When over budget the scale stretches so the budget line stays
            // meaningful; otherwise full width == budget.
            let scaleMax = max(fraction, 1)
            let fillWidth = geo.size.width * CGFloat(min(fraction / scaleMax, 1))
            let budgetX = geo.size.width * CGFloat(min(1 / scaleMax, 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 6)
                    .fill(fillColor(fraction: fraction))
                    .frame(width: max(fillWidth, 0))
                if differentiateWithoutColor {
                    // §8.6 — threshold tick mark at the budget line.
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 1, height: 8)
                        .offset(x: max(budgetX - 1, 0), y: -2)
                }
            }
        }
    }

    /// §8.6 fill thresholds — the one justified exception to accent-only color.
    private func fillColor(fraction: Double) -> Color {
        if fraction < 0.7 { return .green }
        if fraction <= 1.0 { return .yellow }
        return .red
    }

    private func trailingLabel(fraction: Double, budget: Double) -> String {
        var label = String(format: "%.1f/%.1f", displayedMs, budget)
        if differentiateWithoutColor && fraction > 1 {
            label += " over budget"
        }
        return label
    }

    // MARK: - Hover breakdown (§8.6)

    private func breakdown(_ report: LatencyReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latency breakdown")
                .font(.headline)
                .padding(.bottom, 2)
            breakdownRow("Capture", ms: report.captureMs)
            ForEach(report.stages.keys.sorted(), id: \.self) { id in
                breakdownRow(id.displayName, ms: report.stages[id] ?? 0)
            }
            breakdownRow("Handoff", ms: report.handoffMs)
            Divider()
            breakdownRow("Video total", ms: report.totalAddedMs)
            breakdownRow("Audio", ms: report.audioAddedMs)
            breakdownRow("A/V skew", ms: report.syncSkewMs)
            HStack {
                Text("Dropped frames")
                Spacer(minLength: Metrics.sectionGap)
                Text("\(report.droppedFrames)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(Metrics.gutter)
        .frame(minWidth: 180)
    }

    private func breakdownRow(_ label: String, ms: Double) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: Metrics.sectionGap)
            Text(String(format: "%.1f ms", ms))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
