// PrismIntents.swift
// PRISM
//
// The local external control surface (§5.20): App Intents, so a Stream Deck,
// a Shortcuts automation, or a Focus filter can hit freeze or panic without
// PRISM growing a server.
//
// The obvious alternative was a URL scheme, and it is rejected on purpose.
// `open prism://panic` from any process on the machine — any script, any
// browser page that can talk a user into clicking a link — is an
// unauthenticated RPC endpoint into somebody's camera. For an app whose
// whole trust argument is that it phones nobody, an unauthenticated local
// endpoint is worse than a telemetry ping. App Intents run through the
// system's own permission and attribution machinery, and the user opts in
// once with the master switch below, which is off until they do.
//
// Nor are there Siri phrases (no AppShortcutsProvider): "Hey Siri, panic" is
// exactly the phrase a meeting will say out loud.
//
// What is deliberately NOT exposed matters as much as what is:
//   · nothing that reads video, audio, frames, the replay buffer, or the
//     session log — an intent returns confirmation, never content;
//   · no clip, LUT, background or overlay loading, which would turn an
//     automation into a file-read primitive pointed at an arbitrary path;
//   · no camera or microphone selection — "switch to the other camera" is a
//     surveillance verb, not a convenience one;
//   · no published-format change, which is a reconnect boundary that would
//     drop every client mid-call (§3.2);
//   · no quit, which would take the virtual camera down under a live call;
//   · and nothing that edits the shortcut table or this master switch, so an
//     automation can never widen its own surface.
//
// Licensed under the Apache License, Version 2.0.

import AppIntents
import Foundation

// MARK: - Shared plumbing

enum PrismIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case externalControlOff
    case unknownPreset(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning:
            return "PRISM isn't running."
        case .externalControlOff:
            return "Turn on “Allow control from Shortcuts” in PRISM's Shortcuts settings first."
        case .unknownPreset(let name):
            return "PRISM has no preset named “\(name)”."
        }
    }
}

/// Resolves the running app, refusing every call while the master switch is
/// off. Checked per invocation rather than at registration time: the intents
/// stay listed in the Shortcuts app so a user can build an automation and
/// then be told, once, what to turn on.
@MainActor
private func controlledState() throws -> AppState {
    guard let state = AppState.current else { throw PrismIntentError.notRunning }
    guard state.externalControlEnabled else { throw PrismIntentError.externalControlOff }
    return state
}

/// on / off / toggle, shared by every switch-shaped intent.
///
/// A Stream Deck wants one button that does both directions, and an
/// automation ("when the meeting starts, mute") wants an absolute. Offering
/// both in one parameter is one control answering one question (§8.7), which
/// is better than shipping twenty intents in on/off pairs.
enum PrismSwitchAction: String, AppEnum {
    case on, off, toggle

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Action" }

    static var caseDisplayRepresentations: [PrismSwitchAction: DisplayRepresentation] {
        [.on: "Turn on", .off: "Turn off", .toggle: "Toggle"]
    }

    /// Whether an action that currently reads `isOn` needs to be flipped.
    func changes(from isOn: Bool) -> Bool {
        switch self {
        case .on: return !isOn
        case .off: return isOn
        case .toggle: return true
        }
    }
}

// MARK: - Controls

struct FreezeIntent: AppIntent {
    static var title: LocalizedStringResource = "Freeze PRISM Camera"
    static var description = IntentDescription(
        "Holds the last sharp frame for everyone watching. Audio keeps running.")
    static var openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PrismSwitchAction

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        if action.changes(from: state.isFrozen) { state.toggleFreeze() }
        return .result()
    }
}

struct MuteIntent: AppIntent {
    static var title: LocalizedStringResource = "Mute PRISM Microphone"
    static var description = IntentDescription(
        "Silences PRISM's virtual microphone. Video keeps running.")
    static var openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PrismSwitchAction

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        if action.changes(from: state.isMuted) { state.toggleMute() }
        return .result()
    }
}

struct PanicIntent: AppIntent {
    static var title: LocalizedStringResource = "PRISM Panic"
    static var description = IntentDescription(
        "Covers the camera and mutes the microphone in one move.")
    static var openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PrismSwitchAction

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        if action.changes(from: state.isPanicked) { state.togglePanic() }
        return .result()
    }
}

struct AwayLoopIntent: AppIntent {
    static var title: LocalizedStringResource = "PRISM Away Loop"
    static var description = IntentDescription(
        "Puts a loop of you sitting still on air while you step away.")
    static var openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PrismSwitchAction

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        if action.changes(from: state.isAway) { state.toggleAway() }
        return .result()
    }
}

struct InstantReplayIntent: AppIntent {
    static var title: LocalizedStringResource = "PRISM Instant Replay"
    static var description = IntentDescription(
        "Plays the last few seconds back to everyone watching, then returns to live.")
    static var openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PrismSwitchAction

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        if action.changes(from: state.replayMode == .replay) { state.toggleReplay() }
        return .result()
    }
}

struct EyeContactIntent: AppIntent {
    static var title: LocalizedStringResource = "PRISM Eye Contact"
    static var description = IntentDescription(
        "Turns the eye-contact correction on or off.")
    static var openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PrismSwitchAction

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        if action.changes(from: state.config.flags(for: .gaze).enabled) {
            state.toggleEyeContact()
        }
        return .result()
    }
}

struct VoiceChangerIntent: AppIntent {
    static var title: LocalizedStringResource = "PRISM Voice Changer"
    static var description = IntentDescription(
        "Turns the last used voice effect on or off. Choosing an effect stays in PRISM.")
    static var openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PrismSwitchAction

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        if action.changes(from: state.isVoiceActive) { state.toggleVoice() }
        return .result()
    }
}

struct BackgroundBlurIntent: AppIntent {
    static var title: LocalizedStringResource = "PRISM Background Blur"
    static var description = IntentDescription(
        "Blurs what is behind you, or clears it. Image and video backdrops stay in PRISM.")
    static var openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PrismSwitchAction

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        let isBlurred = state.backgroundMode == .blur
        if action.changes(from: isBlurred) {
            state.setBackgroundMode(isBlurred ? .off : .blur)
        }
        return .result()
    }
}

// MARK: - Presets

/// Presets are addressed by name, not by UUID: the name is what a user sees
/// in the Shortcuts editor, and a shortcut built around a UUID would break
/// silently the moment the preset was re-imported.
struct PresetNameOptions: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        AppState.current?.presets.map(\.name) ?? []
    }
}

struct ApplyPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply PRISM Preset"
    static var description = IntentDescription(
        "Switches PRISM to a saved look.")
    static var openAppWhenRun = false

    @Parameter(title: "Preset", optionsProvider: PresetNameOptions())
    var preset: String

    static var parameterSummary: some ParameterSummary {
        Summary("Apply PRISM preset \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try controlledState()
        let wanted = preset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = state.presets.first(where: {
            $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) else {
            throw PrismIntentError.unknownPreset(preset)
        }
        state.selectPreset(match.id)
        return .result()
    }
}
