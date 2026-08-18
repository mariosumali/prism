// FormatSection.swift
// PRISM
//
// Collapsible Format section (§8.3): resolution and frame-rate pickers over
// the published set, latency policy with its per-policy budget, and the §6
// trade-off stated plainly. Switching within the published set is free —
// ordinary client negotiation, no reconnect.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct FormatSection: View {
    @EnvironmentObject var state: AppState

    /// §8.6 — clicking the latency meter opens this section and moves
    /// keyboard/VoiceOver focus to the Latency policy control.
    @FocusState private var latencyPolicyFocused: Bool
    @AccessibilityFocusState private var latencyPolicyA11yFocused: Bool

    private struct Resolution: Hashable, Identifiable {
        let width: Int
        let height: Int
        var id: String { "\(width)x\(height)" }
        var label: String { "\(width)×\(height)" }
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                row("Resolution") {
                    Picker("Resolution", selection: resolutionBinding) {
                        ForEach(resolutions) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }
                }
                row("Frame rate") {
                    Picker("Frame rate", selection: frameRateBinding) {
                        ForEach(ratesAtActiveResolution, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                }
                // §6 — the trade-off, on the control it belongs to. It is
                // spelled out in full in the main window's Format pane; two
                // wrapped lines of standing text at the bottom of the
                // popover is where a dropdown stops being scannable.
                .help("Higher frame rates lower total latency but leave less time for effects")
                row("Latency") {
                    Picker("Latency", selection: policyBinding) {
                        ForEach(LatencyPolicy.allCases, id: \.self) { policy in
                            Text(policyLabel(policy)).tag(policy)
                        }
                    }
                    .focused($latencyPolicyFocused)
                    .accessibilityFocused($latencyPolicyA11yFocused)
                }
            }
            .prismCard()
        } label: {
            Text("Format")
                .font(.headline)
        }
        .onChange(of: state.latencyPolicyFocusRequest) { _ in
            // Defer one runloop turn so the just-expanded section's controls
            // exist before focus moves (§8.6).
            DispatchQueue.main.async {
                latencyPolicyFocused = true
                latencyPolicyA11yFocused = true
            }
        }
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Metrics.itemGap) {
            Text(label)
                .font(.body)
            Spacer(minLength: 0)
            content()
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(label)
        }
    }

    private func policyLabel(_ policy: LatencyPolicy) -> String {
        let budget = policy.budgetMs(frameIntervalMs: activeFormat.frameIntervalMs)
        return "\(policy.displayName) · \(String(format: "%.1f", budget)) ms"
    }

    // MARK: - Data

    private var activeFormat: VideoFormat { state.config.format }

    private var resolutions: [Resolution] {
        var seen = Set<Resolution>()
        var out: [Resolution] = []
        for format in state.publishedFormats.sorted() {
            let resolution = Resolution(width: format.width, height: format.height)
            if seen.insert(resolution).inserted {
                out.append(resolution)
            }
        }
        return out
    }

    private var ratesAtActiveResolution: [Int] {
        state.publishedFormats
            .filter { $0.width == activeFormat.width && $0.height == activeFormat.height }
            .map(\.frameRate)
            .sorted()
    }

    // MARK: - Bindings

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { state.expandedSections.contains(.format) },
            set: { newValue in
                if newValue != state.expandedSections.contains(.format) {
                    state.toggleSection(.format)
                }
            })
    }

    private var resolutionBinding: Binding<Resolution> {
        Binding(
            get: { Resolution(width: activeFormat.width, height: activeFormat.height) },
            set: { resolution in
                let candidates = state.publishedFormats.filter {
                    $0.width == resolution.width && $0.height == resolution.height
                }
                guard !candidates.isEmpty else { return }
                // Keep the frame rate when available, else the nearest.
                let current = activeFormat.frameRate
                let best = candidates.min {
                    abs($0.frameRate - current) < abs($1.frameRate - current)
                }
                if let best { state.setActiveFormat(best) }
            })
    }

    private var frameRateBinding: Binding<Int> {
        Binding(
            get: { activeFormat.frameRate },
            set: { rate in
                let match = state.publishedFormats.first {
                    $0.width == activeFormat.width
                        && $0.height == activeFormat.height
                        && $0.frameRate == rate
                }
                if let match { state.setActiveFormat(match) }
            })
    }

    private var policyBinding: Binding<LatencyPolicy> {
        Binding(
            get: { state.config.latencyPolicy },
            set: { state.setLatencyPolicy($0) })
    }
}
