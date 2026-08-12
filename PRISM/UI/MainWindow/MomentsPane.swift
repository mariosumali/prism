// MomentsPane.swift
// PRISM
//
// Instant replay, the away loop, and the panic chord (§5.9–§5.11) — the
// three features that change what is on air in time rather than in space.
//
// All three are behaviour rather than look, so they edit AppState.studio
// directly and never touch the draft: there is nothing to preview about
// "how many seconds do you keep" and nothing a preset should carry.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MomentsPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            bufferSection
            replaySection
            awaySection
            panicSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Rolling buffer

    private var bufferSection: some View {
        Section("Rolling buffer") {
            Toggle("Keep the last few seconds", isOn: armedBinding)
            PrismSliderRow(label: "Buffer length",
                           value: bufferSecondsBinding,
                           range: 4...30,
                           defaultValue: 10,
                           fractionDigits: 0)
                .disabled(!state.studio.replay.isArmed)
            Picker("Recording quality", selection: maxHeightBinding) {
                Text("540p").tag(540)
                Text("720p").tag(720)
                Text("1080p").tag(1080)
            }
            .pickerStyle(.segmented)
            .disabled(!state.studio.replay.isArmed)

            if state.studio.replay.isArmed {
                LabeledContent("Buffered",
                               value: String(format: "%.0f s", state.bufferedSeconds))
            }
            Text("Both instant replay and the away loop read from this one buffer. Frames go through the hardware video encoder rather than being kept as-is, so ten seconds costs about ten megabytes instead of two and a half gigabytes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("It only records while something is actually using PRISM — a preview open, or an app on the camera. Off by default, because a feature you are not using should cost nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Replay

    private var replaySection: some View {
        Section("Instant replay") {
            HStack {
                Button(state.replayMode == .replay ? "Stop replay" : "Replay now") {
                    state.toggleReplay()
                }
                .disabled(!state.studio.replay.isArmed && state.replayMode != .replay)
                Spacer()
                Text("⌥⌘R")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PrismSliderRow(label: "Playback speed",
                           value: playbackRateBinding,
                           range: 0.25...4,
                           defaultValue: 1.5,
                           fractionDigits: 2)
            Toggle("Return to live at the end", isOn: returnToLiveBinding)
            Text("Above 1× the replay catches back up to live on its own, which is usually what you want — you are showing someone the thing they missed, not screening a rerun.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("A replay runs through your current effects, because it buffers the camera rather than the finished picture. Change your look mid-replay and the replay changes with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Away

    private var awaySection: some View {
        Section("Away loop") {
            HStack {
                Button(state.isAway ? "Come back" : "Step away") {
                    state.toggleAway()
                }
                Spacer()
                Text("⌥⌘A")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PrismSliderRow(label: "Loop length",
                           value: loopSecondsBinding,
                           range: 2...10,
                           defaultValue: 4,
                           fractionDigits: 0)
            PrismSliderRow(label: "Seam crossfade",
                           value: crossfadeBinding,
                           range: 0...1500,
                           defaultValue: 400,
                           fractionDigits: 0)
            Toggle("Mute while away", isOn: awayMuteBinding)
            Toggle("Turn the buffer on the first time I use this",
                   isOn: armsOnFirstUseBinding)
            Text("PRISM searches the buffer for the stillest stretch whose first and last frames match, so the cut is as close to invisible as the recording allows, then crossfades the tail back into the start to hide what is left of it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("A frozen frame tells everyone you left. A loop that breathes does not — which is the point, and also worth being deliberate about.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Panic

    private var panicSection: some View {
        Section("Panic") {
            HStack {
                Button(state.isPanicked ? "Stand down" : "Panic now",
                       role: state.isPanicked ? nil : .destructive) {
                    state.togglePanic()
                }
                Spacer()
                Text("⌥⌘P")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Freeze the picture", isOn: panicBinding(\.freezes))
            Toggle("Mute the microphone", isOn: panicBinding(\.mutes))
            Toggle("Swap in a backdrop", isOn: panicBinding(\.swapsBackdrop))
            if state.studio.panic.swapsBackdrop {
                HStack(spacing: Metrics.itemGap) {
                    Text(backdropName ?? "Flat colour")
                        .foregroundStyle(backdropName == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseBackdrop() }
                    if backdropName != nil {
                        Button("Clear") { state.studio.panic.backdropPath = nil }
                    }
                }
                ColorPicker("Backdrop colour", selection: backdropColorBinding,
                            supportsOpacity: false)
            }
            Text("One chord, built from things PRISM already does. Pressing it again puts everything back exactly as it was — including a freeze or a mute you had engaged yourself beforehand.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Deliberately un-shifted: a panic key you have to reach for is not one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var backdropName: String? {
        state.studio.panic.backdropURL?.lastPathComponent
    }

    private func chooseBackdrop() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                state.studio.panic.backdropPath = url.path
            }
        }
    }

    // MARK: - Bindings

    private var armedBinding: Binding<Bool> {
        Binding(get: { state.studio.replay.isArmed },
                set: { state.setBufferArmed($0) })
    }

    private var bufferSecondsBinding: Binding<Double> {
        Binding(get: { state.studio.replay.bufferSeconds },
                set: { state.studio.replay.bufferSeconds = $0 })
    }

    private var maxHeightBinding: Binding<Int> {
        Binding(get: { state.studio.replay.maxHeight },
                set: { state.studio.replay.maxHeight = $0 })
    }

    private var playbackRateBinding: Binding<Double> {
        Binding(get: { state.studio.replay.playbackRate },
                set: { state.studio.replay.playbackRate = $0 })
    }

    private var returnToLiveBinding: Binding<Bool> {
        Binding(get: { state.studio.replay.returnToLiveAtEnd },
                set: { state.studio.replay.returnToLiveAtEnd = $0 })
    }

    private var loopSecondsBinding: Binding<Double> {
        Binding(get: { state.studio.away.loopSeconds },
                set: { state.studio.away.loopSeconds = $0 })
    }

    private var crossfadeBinding: Binding<Double> {
        Binding(get: { state.studio.away.crossfadeMs },
                set: { state.studio.away.crossfadeMs = $0 })
    }

    private var awayMuteBinding: Binding<Bool> {
        Binding(get: { state.studio.away.mutesAudio },
                set: { state.studio.away.mutesAudio = $0 })
    }

    private var armsOnFirstUseBinding: Binding<Bool> {
        Binding(get: { state.studio.away.armsBufferOnFirstUse },
                set: { state.studio.away.armsBufferOnFirstUse = $0 })
    }

    private func panicBinding(
        _ keyPath: WritableKeyPath<PanicSettings, Bool>
    ) -> Binding<Bool> {
        Binding(get: { state.studio.panic[keyPath: keyPath] },
                set: { state.studio.panic[keyPath: keyPath] = $0 })
    }

    private var backdropColorBinding: Binding<Color> {
        Binding(
            get: {
                let rgb = state.studio.panic.backdropColor
                return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                let components = NSColor(color).usingColorSpace(.sRGB)
                state.studio.panic.backdropColor = RGBColor(
                    red: Double(components?.redComponent ?? 0.1),
                    green: Double(components?.greenComponent ?? 0.11),
                    blue: Double(components?.blueComponent ?? 0.13))
            })
    }
}
