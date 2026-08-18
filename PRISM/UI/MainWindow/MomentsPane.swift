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
            lagSection
            connectionSection
            panicSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Lag switch

    private var lagSection: some View {
        Section("Lag switch") {
            HStack {
                Button(state.isLagging ? "Back to live" : "Lag now") {
                    state.toggleLag()
                }
                .disabled(!state.studio.replay.isArmed && !state.isLagging)
                Spacer()
                Text(state.studio.lag.holdToLag
                     ? "hold \(state.shortcutLabel(.lag))"
                     : state.shortcutLabel(.lag))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PrismSliderRow(label: "Delay",
                           value: lagDelayBinding,
                           range: 200...maxLagMs,
                           defaultValue: 3000,
                           fractionDigits: 0,
                           unit: " ms",
                           snap: 50)
            Text("Drag for 50 ms steps, hold ⌥ to drag finer, or type an exact value in the field — \(exactDelayHint).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Delay the microphone too", isOn: lagAudioBinding)
            Toggle("Hold the key rather than toggling", isOn: holdToLagBinding)
            Picker("On release", selection: lagReleaseBinding) {
                ForEach(LagRelease.allCases, id: \.self) { release in
                    Text(release.displayName).tag(release)
                }
            }
            .pickerStyle(.segmented)
            if state.studio.lag.release == .catchUp {
                PrismSliderRow(label: "Catch-up speed",
                               value: catchUpRateBinding,
                               range: 1.25...4,
                               defaultValue: 2,
                               fractionDigits: 2)
                Text("Video plays the backlog out at this speed until it reaches live. The microphone returns to live immediately either way — speeding up an audio delay means resampling or dropping samples, and both sound worse than the skew.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.isLagging || state.isCatchingUp {
                LabeledContent("Currently",
                               value: String(format: "%.1f s behind live",
                                             state.latency.deliberateDelayMs / 1000))
            }
            Text("Engaging holds the picture where it is and only then resumes, that far behind — a stall, not a rewind. Jumping straight back would make you say the same thing twice.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Dragging the delay while engaged applies immediately: deeper holds again for the difference, shallower drops that much backlog and never replays anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The delayed video lives in the same rolling buffer replay and away use, so the delay cannot exceed the buffer length, and delayed video passes through its encoder. The latency meter keeps measuring what PRISM costs you involuntarily; this delay is reported next to it, never folded into it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The delay is held in the rolling buffer, so it cannot outrun it — and
    /// never exceeds the 10 s the settings themselves clamp to, so the
    /// control cannot offer a value that would be silently reduced in use.
    private var maxLagMs: Double {
        min(10_000, max(400, (state.studio.replay.clampedBufferSeconds - 0.5) * 1000))
    }

    /// States the exact figure that is (or would be) on air, in both units —
    /// the field speaks milliseconds, the rest of the UI speaks seconds.
    private var exactDelayHint: String {
        let ms = min(state.studio.lag.clampedDelayMs, maxLagMs)
        return String(format: "%.0f ms is %.2f s", ms, ms / 1000)
    }

    // MARK: - Bad connection

    private var connectionSection: some View {
        Section("Bad connection") {
            HStack {
                Button(state.isBadConnection ? "Recover" : "Degrade now") {
                    state.toggleBadConnection()
                }
                Spacer()
                Text(state.shortcutLabel(.badConnection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PrismSliderRow(label: "Severity",
                           value: severityBinding,
                           range: 0.1...1,
                           defaultValue: 0.6,
                           fractionDigits: 2)
            // One knob, so the readout says what it buys — nobody should
            // have to engage the stunt to learn what 0.6 means.
            LabeledContent("Looks like", value: connectionPreviewLine)
            Toggle("Refresh in irregular bursts, a few frames per second",
                   isOn: connectionBinding(\.dropsFrames))
            Toggle("Fall behind live too", isOn: connectionBinding(\.addsLag))
            if state.studio.connection.addsLag {
                PrismSliderRow(label: "Delay",
                               value: connectionLagBinding,
                               range: 200...min(4000, maxLagMs),
                               defaultValue: 1200,
                               fractionDigits: 0,
                               unit: " ms",
                               snap: 50)
                Text("The delay rides the same rolling-buffer transport as the lag switch, so it needs the buffer on and cannot exceed its length. The microphone is delayed to match — a picture behind live audio reads as broken software, not a bad connection. Releasing snaps straight back to live, which is what a recovering connection does with its backlog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Everything on air degrades together — backdrop, overlays and effects included — because a real connection never pixelates just your face. The numbers above are averages: timing stutters and stalls in bursts, only some blocks refresh each frame (moving things smear), and quality drifts the way a struggling call's does. Underneath, PRISM keeps running your full chain untouched, so recovery is instant.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionPreviewLine: String {
        let connection = state.studio.connection
        var parts = [
            String(format: "%.0f px blocks", connection.blockSize(forHeight: 1080)),
            String(format: "%.0f colour steps", connection.posterizeLevels),
        ]
        if connection.dropsFrames {
            parts.append(String(format: "≈%.0f fps", connection.throttledFps))
        }
        return parts.joined(separator: " · ")
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
                Text(state.shortcutLabel(.replay))
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
                Text(state.shortcutLabel(.away))
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
                Text(state.shortcutLabel(.panic))
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

    private var lagDelayBinding: Binding<Double> {
        Binding(get: { min(state.studio.lag.delayMs, maxLagMs) },
                set: { state.studio.lag.delayMs = $0 })
    }

    private var lagAudioBinding: Binding<Bool> {
        Binding(get: { state.studio.lag.delaysAudio },
                set: { state.studio.lag.delaysAudio = $0 })
    }

    private var holdToLagBinding: Binding<Bool> {
        Binding(get: { state.studio.lag.holdToLag },
                set: { state.studio.lag.holdToLag = $0 })
    }

    private var lagReleaseBinding: Binding<LagRelease> {
        Binding(get: { state.studio.lag.release },
                set: { state.studio.lag.release = $0 })
    }

    private var catchUpRateBinding: Binding<Double> {
        Binding(get: { state.studio.lag.catchUpRate },
                set: { state.studio.lag.catchUpRate = $0 })
    }

    private var severityBinding: Binding<Double> {
        Binding(get: { state.studio.connection.severity },
                set: { state.studio.connection.severity = $0 })
    }

    private var connectionLagBinding: Binding<Double> {
        Binding(get: { min(state.studio.connection.lagMs, maxLagMs) },
                set: { state.studio.connection.lagMs = $0 })
    }

    private func connectionBinding(
        _ keyPath: WritableKeyPath<ConnectionSettings, Bool>
    ) -> Binding<Bool> {
        Binding(get: { state.studio.connection[keyPath: keyPath] },
                set: { state.studio.connection[keyPath: keyPath] = $0 })
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
