// GesturesPane.swift
// PRISM
//
// The main window's Gestures pane — hand poses as a second hotkey surface
// (§5.31), and the bindings from pose to intent. Behaviour rather than look,
// like Moments, so it edits AppState.studio directly and never touches the
// draft: there is nothing to preview about "what does a fist do".
//
// The pane is organised around the thing that decides whether the feature is
// usable at all, which is not the bindings — it is the false positive. So the
// master switch comes first, the bindings second, and the four numbers that
// stop a gesticulation firing anything come last, each with the sentence that
// says what it is defending against. Gestures misfire; the pane that turns
// them off has to be findable before the recogniser does.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct GesturesPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            switchSection
            bindingsSection
            thresholdsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - The master switch

    private var switchSection: some View {
        Section("Hand gestures") {
            Toggle("Watch for hand gestures", isOn: enabledBinding)
            Text("PRISM looks for three shapes — an open palm, a Victory, a fist — and does what you bind them to. Off by default: on means the camera can act on what it sees you do.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.studio.gestures.isEnabled, !state.studio.gestures.isActive {
                // The §8.7 case: a switch that is on and wired to nothing.
                // Said here rather than left for the user to notice, because
                // "on" and "on and doing nothing" look identical.
                Text("On, but no pose is bound to anything yet, so nothing is watching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let last = state.lastGesture {
                LabeledContent("Last gesture",
                               value: "\(last.pose.displayName) → \(last.action.displayName)")
            }
        }
    }

    // MARK: - Bindings

    private var bindingsSection: some View {
        Section("What each pose does") {
            ForEach(HandPose.allCases, id: \.self) { pose in
                Picker(pose.displayName, selection: actionBinding(pose)) {
                    ForEach(GestureAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                if let caption = state.studio.gestures.action(for: pose).caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Every action here is reversible and obvious the moment it fires — a gesture is the least deliberate input PRISM has.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Panic's warning is printed whether or not anybody has picked it
            // yet. The point of the sentence is to make somebody think twice,
            // and one that only appears after the binding is made is a
            // sentence nobody reads in time.
            if let panic = GestureAction.panic.caption {
                Text(panic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The false-positive budget

    private var thresholdsSection: some View {
        Section("Before anything fires") {
            PrismSliderRow(label: "Hold for",
                           value: holdBinding,
                           range: 0.3...3,
                           defaultValue: 0.8,
                           fractionDigits: 2,
                           unit: " s")
            Text("How long the pose has to be held. People talk with their hands — an open palm is what you make while explaining something — and talking hands are never still this long.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrismSliderRow(label: "Then wait",
                           value: cooldownBinding,
                           range: 0.5...10,
                           defaultValue: 2,
                           fractionDigits: 1,
                           unit: " s")
            Text("Nothing else fires for this long afterwards, and one held pose is one action however long you hold it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrismSliderRow(label: "Certainty",
                           value: confidenceBinding,
                           range: 0.5...1,
                           defaultValue: 0.85,
                           fractionDigits: 2)
            Text("How sure PRISM has to be about the shape. High by default: a mistake here mutes a call nobody asked to mute.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "Panic is held for %.1f s whatever this says — it is the one action that takes the picture away.",
                        GestureSettings.panicHoldFloorSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.studio.gestures.isEnabled },
            set: { state.setGesturesEnabled($0) })
    }

    private func actionBinding(_ pose: HandPose) -> Binding<GestureAction> {
        Binding(
            get: {
                let binding = state.studio.gestures.bindings.first { $0.pose == pose }
                guard let binding, binding.isEnabled else { return .none }
                return binding.action
            },
            set: { state.setGestureAction($0, for: pose) })
    }

    private var holdBinding: Binding<Double> {
        Binding(
            get: { state.studio.gestures.holdSeconds },
            set: { state.setGestureHoldSeconds($0) })
    }

    private var cooldownBinding: Binding<Double> {
        Binding(
            get: { state.studio.gestures.cooldownSeconds },
            set: { state.setGestureCooldownSeconds($0) })
    }

    private var confidenceBinding: Binding<Double> {
        Binding(
            get: { state.studio.gestures.confidence },
            set: { state.setGestureConfidence($0) })
    }
}
