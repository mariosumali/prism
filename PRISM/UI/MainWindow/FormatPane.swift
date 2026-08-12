// FormatPane.swift
// PRISM
//
// Active format and latency policy (free switches within the published set,
// §3.2), the live latency breakdown the popover shows only on hover, and
// the published-formats editor (a reconnect boundary, §3.2 — stated in
// place, and AppState confirms before republishing while clients stream).
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct FormatPane: View {
    @EnvironmentObject var state: AppState

    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var customFPS = ""

    private struct Resolution: Hashable, Identifiable {
        let width: Int
        let height: Int
        var id: String { "\(width)x\(height)" }
        var label: String { "\(width)×\(height)" }
    }

    var body: some View {
        Form {
            Section("Active format") {
                Picker("Resolution", selection: resolutionBinding) {
                    ForEach(resolutions) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                Picker("Frame rate", selection: frameRateBinding) {
                    ForEach(ratesAtActiveResolution, id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
                Text("Switching within the published set is free — apps renegotiate without reselecting PRISM Camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Latency") {
                Picker("Policy", selection: policyBinding) {
                    ForEach(LatencyPolicy.allCases, id: \.self) { policy in
                        Text(policyLabel(policy)).tag(policy)
                    }
                }
                // §6 — say the trade-off plainly rather than making users infer it.
                Text("Higher frame rates lower total latency but leave less time for effects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LatencyMeter()
            }
            Section("Live breakdown") {
                breakdownRow("Capture", ms: state.latency.captureMs)
                ForEach(state.latency.stages.keys.sorted(), id: \.self) { id in
                    breakdownRow(id.displayName, ms: state.latency.stages[id] ?? 0)
                }
                breakdownRow("Handoff", ms: state.latency.handoffMs)
                breakdownRow("Video total", ms: state.latency.totalAddedMs)
                breakdownRow("Audio", ms: state.latency.audioAddedMs)
                breakdownRow("A/V skew", ms: state.latency.syncSkewMs)
                LabeledContent("Dropped frames",
                               value: "\(state.latency.droppedFrames)")
            }
            Section("Published formats") {
                ForEach(VideoFormat.defaultSet) { format in
                    Toggle(format.displayName, isOn: inclusionBinding(format))
                }
                ForEach(customFormats) { format in
                    HStack {
                        Text(format.displayName)
                        Spacer()
                        Button {
                            remove(format)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(format.displayName)")
                    }
                }
                HStack(spacing: Metrics.itemGap) {
                    TextField("Width", text: $customWidth)
                        .frame(width: 60)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: $customHeight)
                        .frame(width: 60)
                    TextField("fps", text: $customFPS)
                        .frame(width: 44)
                    Button("Add") { addCustom() }
                        .disabled(parsedCustom == nil)
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                // §3.2 — mutating the published set is a reconnect boundary.
                Text("Changing this list while apps are streaming makes them reselect PRISM Camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func breakdownRow(_ label: String, ms: Double) -> some View {
        LabeledContent(label, value: String(format: "%.1f ms", ms))
            .font(.body.monospacedDigit())
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

    private var customFormats: [VideoFormat] {
        state.publishedFormats
            .filter { !VideoFormat.defaultSet.contains($0) }
            .sorted()
    }

    // MARK: - Bindings

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

    private func inclusionBinding(_ format: VideoFormat) -> Binding<Bool> {
        Binding(
            get: { state.publishedFormats.contains(format) },
            set: { include in
                var formats = state.publishedFormats
                if include {
                    if !formats.contains(format) { formats.append(format) }
                } else {
                    formats.removeAll { $0 == format }
                }
                guard !formats.isEmpty else { return }   // never publish an empty set
                state.requestPublishedFormatsChange(formats.sorted())
            })
    }

    // MARK: - Custom formats

    private var parsedCustom: VideoFormat? {
        guard let width = Int(customWidth), let height = Int(customHeight),
              let fps = Int(customFPS),
              (16...7680).contains(width), (16...4320).contains(height),
              (1...240).contains(fps)
        else { return nil }
        let format = VideoFormat(width: width, height: height, frameRate: fps)
        guard !state.publishedFormats.contains(format) else { return nil }
        return format
    }

    private func addCustom() {
        guard let format = parsedCustom else { return }
        var formats = state.publishedFormats
        formats.append(format)
        state.requestPublishedFormatsChange(formats.sorted())
        customWidth = ""
        customHeight = ""
        customFPS = ""
    }

    private func remove(_ format: VideoFormat) {
        var formats = state.publishedFormats
        formats.removeAll { $0 == format }
        guard !formats.isEmpty else { return }
        state.requestPublishedFormatsChange(formats.sorted())
    }
}
