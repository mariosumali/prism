// VoiceSection.swift
// PRISM
//
// The popover's Voice section (§5.13, §5.17): the live input meter, one
// picker over the microphone voice effects and one over cleanup, nothing
// more — strength, per-effect blurbs, the honesty copy and the mic check's
// full surface live in the main window's Voice pane, per the
// progressive-disclosure rule. The collapsed label names what is on air so
// the section never hides an active voice.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct VoiceSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                InputLevelMeter(level: state.inputLevel, muted: state.isMuted)
                voiceRow
                cleanupRow
                MicCheckControls(check: state.micCheck,
                                 inhibition: state.micCheckInhibition,
                                 compact: true)
            }
            .prismCard()
        } label: {
            HStack(spacing: Metrics.itemGap) {
                Text("Voice")
                    .font(.headline)
                if let summary = collapsedSummary {
                    // A collapsed section must not hide what is on air.
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Effect first, cleanup second: an alien voice is the more surprising
    /// thing to have forgotten.
    private var collapsedSummary: String? {
        var parts: [String] = []
        if state.isVoiceActive { parts.append(state.studio.voice.effect.displayName) }
        if state.isVoiceCleanupActive {
            parts.append(state.studio.cleanup.mode.displayName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var voiceRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Text("Effect")
                .font(.body)
            Spacer(minLength: 0)
            Picker("Voice effect", selection: effectBinding) {
                ForEach(VoiceEffect.allCases) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Voice effect")
            .accessibilityValue(state.studio.voice.effect.displayName)
        }
        .help("Change what the microphone sounds like\(state.shortcutSuffix(.voice))")
    }

    /// §5.17 — the whole feature, as one picker.
    private var cleanupRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Text("Cleanup")
                .font(.body)
            Spacer(minLength: 0)
            Picker("Microphone cleanup", selection: cleanupBinding) {
                ForEach(VoiceCleanupMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Microphone cleanup")
            .accessibilityValue(state.studio.cleanup.mode.displayName)
        }
        .help("Take the room out of your microphone")
    }

    // MARK: - Bindings

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { state.expandedSections.contains(.voice) },
            set: { newValue in
                if newValue != state.expandedSections.contains(.voice) {
                    state.toggleSection(.voice)
                }
            })
    }

    private var effectBinding: Binding<VoiceEffect> {
        Binding(
            get: { state.studio.voice.effect },
            set: { state.setVoiceEffect($0) })
    }

    private var cleanupBinding: Binding<VoiceCleanupMode> {
        Binding(
            get: { state.studio.cleanup.mode },
            set: { state.setVoiceCleanupMode($0) })
    }
}

// MARK: - Input level meter

/// The always-on microphone meter (§5.17), shared by the popover's Voice
/// section and the main window's Voice pane so the two can never disagree
/// about how loud you are. Same §8.6 vocabulary as the mic check's bar —
/// same scaling and same decay underneath — with one difference that has to
/// be visible: while muted the bar still moves, because the level is read
/// ahead of the mute and "PRISM can hear you, the call cannot" is exactly
/// the thing worth showing.
struct InputLevelMeter: View {
    let level: Double
    let muted: Bool
    var showsCaption = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Metrics.itemGap) {
                Image(systemName: muted ? "mic.slash" : "mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                bar
            }
            if showsCaption {
                Text(muted
                     ? "Muted — this is what PRISM hears, not what the call does."
                     : "What your microphone is picking up right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(muted ? Color.orange : Color.green)
                    .frame(width: max(proxy.size.width * level, 4))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent\(muted ? ", muted" : "")")
    }
}

// MARK: - Mic check controls

/// The §5.13 mic check, shared by the popover (compact) and the main
/// window's Voice pane (full). Its own view because MicCheck is a separate
/// ObservableObject — observing it here keeps the record/playback state
/// live without routing every tick through AppState.
struct MicCheckControls: View {
    @ObservedObject var check: MicCheck
    let inhibition: String?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : Metrics.itemGap) {
            HStack(spacing: Metrics.itemGap) {
                Button(buttonTitle) { check.toggle() }
                    .controlSize(compact ? .small : .regular)
                    .disabled(check.phase == .idle && inhibition != nil)
                    .accessibilityLabel("Mic check")
                    .accessibilityValue(accessibilityPhase)
                if check.phase == .recording {
                    levelBar
                    Text(String(format: "%.0f s", MicCheck.maxSeconds - check.recordedSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Spacer(minLength: 0)
                    if check.phase == .idle, check.hasTake, !compact {
                        Button("Play again") { check.replay() }
                            .controlSize(.small)
                    }
                }
            }
            if let caption = statusCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttonTitle: String {
        switch check.phase {
        case .idle: return compact ? "Mic check" : "Test my voice"
        case .recording: return "Stop and play"
        case .playing: return "Stop"
        }
    }

    private var accessibilityPhase: String {
        switch check.phase {
        case .idle: return check.hasTake ? "ready, take recorded" : "ready"
        case .recording: return "recording"
        case .playing: return "playing back"
        }
    }

    /// §8.4: one line, only when there is something to say.
    private var statusCaption: String? {
        switch check.phase {
        case .recording:
            return "Say something…"
        case .playing:
            return "This is what everyone else hears."
        case .idle:
            // A live inhibition outranks the silence diagnosis: "unmute to
            // test" is the true explanation for a starved take, and pointing
            // at the microphone picker instead would send the user chasing
            // the wrong control.
            if let inhibition {
                return inhibition
            }
            if check.heardNothing {
                return "PRISM didn't hear anything. Check the microphone picker."
            }
            return nil
        }
    }

    /// Input level, §8.6 vocabulary: 4pt bar, quaternary track, green fill.
    private var levelBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green)
                    .frame(width: max(proxy.size.width * check.level, 4))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(check.level * 100)) percent")
    }
}
