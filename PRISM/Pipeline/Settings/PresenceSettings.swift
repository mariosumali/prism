// PresenceSettings.swift
// PRISM
//
// What happens when you leave the frame, and what happens when you come back.
// Built on primitives PRISM already has — the away loop (§5.10) and freeze
// (§5.2) — driven by a coordinated human-rectangle request (§5.28) that is
// demanded only while one of the switches below is on.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public enum PresenceAction: String, Codable, CaseIterable {
    /// Nothing happens, and the default. An app that starts hiding the room
    /// the moment you stand up — without being asked — is doing something the
    /// user did not choose to the picture other people are watching.
    case none
    /// Play the away loop (§5.10), which needs the rolling buffer armed.
    case loop
    /// Hold the last frame you were in (§5.2).
    case freeze

    public var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .loop: return "Play the away loop"
        case .freeze: return "Freeze the last frame"
        }
    }
}

public struct PresenceSettings: Codable, Equatable {
    public var action: PresenceAction = .none
    /// How long the frame must be empty before acting. Generous: leaning out
    /// of shot to pick something up is not leaving, and an action that fires
    /// on a two-second absence would fire several times a meeting.
    public var awaySeconds: Double = 6          // 2…60
    /// How long you must be back before it releases. Shorter than the away
    /// delay — coming back should feel immediate — but not instant, because a
    /// single false-positive detection frame would otherwise flap the state.
    public var returnSeconds: Double = 1.0      // 0.2…10
    /// Fraction of the frame the detected person has to span to count as
    /// "present". Low enough that sitting well back still counts, high enough
    /// that somebody crossing the far end of the room does not.
    public var coverage: Double = 0.04          // 0.005…0.5
    /// Say so in Notification Centre when the frame empties, whatever the
    /// action is. This is the "you left your camera on" nudge, and it is the
    /// one presence behaviour that changes nothing on air — which is exactly
    /// why it can be useful on its own, with the action left at `.none`.
    /// Off by default like everything else here.
    public var notifiesWhenAway: Bool = false
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = c.tolerant(.action, PresenceAction.none)
        awaySeconds = c.tolerant(.awaySeconds, 6)
        returnSeconds = c.tolerant(.returnSeconds, 1.0)
        coverage = c.tolerant(.coverage, 0.04)
        notifiesWhenAway = c.tolerant(.notifiesWhenAway, false)
    }

    public var clampedAwaySeconds: Double { min(max(awaySeconds, 2), 60) }
    public var clampedReturnSeconds: Double { min(max(returnSeconds, 0.2), 10) }
    public var clampedCoverage: Double { min(max(coverage, 0.005), 0.5) }

    /// Whether anything is asking for presence detection at all. This is the
    /// demand gate for the Vision request behind it (§5.28): with both
    /// switches off nothing registers a consumer, so the detector never runs
    /// and the feature costs exactly nothing.
    public var isActive: Bool { action != .none || notifiesWhenAway }
}
