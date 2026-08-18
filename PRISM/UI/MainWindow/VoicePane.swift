// VoicePane.swift
// PRISM
//
// The main window's Voice pane (§5.13): the roomier surface over the same
// voice-changer intents the popover uses. Behaviour rather than look, so it
// edits AppState.studio directly and never touches the draft — the same
// rule as MomentsPane, and the same reason: a preset switch must not change
// what you sound like.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct VoicePane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            voiceSection
            micCheckSection
            castSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Mic check (§5.13)

    /// Record-then-play-back, the way Zoom's mic test works — and the only
    /// way to hear your own effect, since PRISM does not monitor the mic.
    private var micCheckSection: some View {
        Section("Mic check") {
            MicCheckControls(check: state.micCheck,
                             inhibition: state.micCheckInhibition)
            Text("Records up to \(Int(MicCheck.maxSeconds)) seconds of your microphone — after the voice effect — and plays it back, so what you hear is exactly what everyone else gets.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Playback is through your speakers. On a call without headphones, the room — and your mic — will hear it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var voiceSection: some View {
        Section("Voice changer") {
            HStack {
                Button(state.isVoiceActive ? "Turn off" : "Turn on") {
                    state.toggleVoice()
                }
                Spacer()
                Text(state.shortcutLabel(.voice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Effect", selection: effectBinding) {
                ForEach(VoiceEffect.allCases) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
            PrismSliderRow(label: "Strength",
                           value: amountBinding,
                           range: 0.25...1,
                           defaultValue: 1,
                           fractionDigits: 2)
                .disabled(!state.isVoiceActive)
            if state.isVoiceActive {
                LabeledContent("On air",
                               value: state.studio.voice.effect.displayName)
            }
            Text("Applies to the live microphone only — clip audio plays untouched. PRISM does not play the effect back to you, so everyone else hears it and you hear yourself unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Pitched effects buffer about 21 ms of audio to do their work. That cost shows up in the latency meter's audio figure like every other, and disappears the moment the effect is off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The cast

    /// Every effect with its one-line blurb, selectable in place — a picker
    /// you can browse without trying each voice on a live call.
    private var castSection: some View {
        Section("Effects") {
            ForEach(VoiceEffect.allCases.filter { $0 != .off }) { effect in
                Button {
                    state.setVoiceEffect(effect)
                } label: {
                    HStack(spacing: Metrics.itemGap) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effect.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(effect.blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if state.studio.voice.effect == effect {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(effect.displayName)
                .accessibilityValue(state.studio.voice.effect == effect
                                    ? "on air" : "off")
            }
        }
    }

    // MARK: - Bindings

    private var effectBinding: Binding<VoiceEffect> {
        Binding(
            get: { state.studio.voice.effect },
            set: { state.setVoiceEffect($0) })
    }

    private var amountBinding: Binding<Double> {
        Binding(
            get: { state.studio.voice.amount },
            set: { state.setVoiceAmount($0) })
    }
}
