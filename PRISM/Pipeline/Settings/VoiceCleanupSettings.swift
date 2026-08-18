// VoiceCleanupSettings.swift
// PRISM
//
// Microphone cleanup — noise suppression and room tone — and the
// muted-but-talking detector (§5.17). Both hang off StudioSettings rather
// than a preset for the same reason the voice changer (§5.13) does: how you
// sound is behaviour, and switching from Meeting to Studio must never
// quietly start gating your room.
//
// The DSP that these settings describe is in PRISM/Capture/VoiceCleanup.swift
// and PRISM/Capture/InputLevel.swift; nothing here knows about samples.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// How hard to work on the microphone signal. Three named steps rather than a
/// slider because the honest description of the middle setting is "removes
/// the fan" and of the last one is "removes the room" — a percentage would
/// suggest a continuum the processing does not actually have.
public enum VoiceCleanupMode: String, Codable, CaseIterable, Identifiable {
    /// Honest pass-through, and the default: cleanup is signal processing on
    /// every buffer, and a resident agent must cost nothing for a feature
    /// nobody switched on. `.off` is bit-exact — VoiceCleanup returns before
    /// touching a sample — which is asserted by test.
    case off
    /// Steady broadband noise only — fans, air conditioning, hiss.
    case cleanUp
    /// Also suppresses reverb and transient room noise. Costs more, and
    /// pushed far enough it starts eating consonants, which is why it is a
    /// deliberate choice rather than the default.
    case studio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .cleanUp: return "Clean up"
        case .studio: return "Studio"
        }
    }

    /// One line of what it does, in §8.4 voice.
    public var blurb: String {
        switch self {
        case .off: return "Your microphone, exactly as it arrives."
        case .cleanUp: return "Rumble and room noise out, levels evened up. Still sounds like you."
        case .studio: return "Harder on the room, with a little presence added. Radio voice."
        }
    }
}

public struct VoiceCleanupSettings: Codable, Equatable {
    public var mode: VoiceCleanupMode = .off
    /// How much of the estimated noise to remove, 0.2…1. Floored for the same
    /// reason ConnectionSettings.severity is: a mode that is on and removes
    /// nothing is indistinguishable from a broken one (§8.7).
    public var amount: Double = 0.7
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.tolerant(.mode, .off)
        amount = c.tolerant(.amount, 0.7)
    }

    public var clampedAmount: Double { min(max(amount, 0.2), 1) }
    public var isActive: Bool { mode != .off }
}

// MARK: - Muted-but-talking

/// Watches the input level while PRISM's own mute is engaged and says so.
/// PRISM can only ever answer for its own mute — the conferencing app's mute
/// button is invisible to us — so the detector is honest about which mute it
/// is talking about, and stays off until the user asks for it.
public struct MicWatchSettings: Codable, Equatable {
    public var isEnabled: Bool = false
    /// Level, in dBFS, above which the input counts as speech rather than
    /// room tone. Well above a quiet room and well below a speaking voice.
    public var thresholdDB: Double = -34        // −60…−10
    /// How long the level must stay above the threshold before saying
    /// anything. Long enough that a cough or a chair does not trigger it,
    /// short enough to interrupt you inside the first sentence.
    public var sustainSeconds: Double = 1.2     // 0.3…5
    /// Minimum gap between reminders, so a whole muted meeting produces
    /// occasional nudges rather than a stream of them.
    public var reminderIntervalSeconds: Double = 20
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.tolerant(.isEnabled, false)
        thresholdDB = c.tolerant(.thresholdDB, -34)
        sustainSeconds = c.tolerant(.sustainSeconds, 1.2)
        reminderIntervalSeconds = c.tolerant(.reminderIntervalSeconds, 20)
    }

    public var clampedThresholdDB: Double { min(max(thresholdDB, -60), -10) }
    public var clampedSustainSeconds: Double { min(max(sustainSeconds, 0.3), 5) }
    public var clampedReminderIntervalSeconds: Double {
        min(max(reminderIntervalSeconds, 5), 300)
    }
}
