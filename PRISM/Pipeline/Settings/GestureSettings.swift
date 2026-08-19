// GestureSettings.swift
// PRISM
//
// Hand gestures as a second hotkey surface, for the moments when the keyboard
// is not where your hands are. Recognition is a Vision hand-pose request; the
// bindings below are only the persisted mapping from pose to intent.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// The three poses worth spending a recogniser on: distinct from each other
/// at webcam distance, and distinct from the shapes hands make while typing,
/// gesturing or holding a cup — which is the whole problem with gesture
/// control and the reason this list is short.
public enum HandPose: String, Codable, CaseIterable {
    case palm
    case victory
    case fist

    public var displayName: String {
        switch self {
        case .palm: return "Open palm"
        case .victory: return "Victory"
        case .fist: return "Fist"
        }
    }
}

/// What a pose does. Only reversible, visible actions: a gesture is the least
/// deliberate input PRISM has, so nothing here can destroy anything, and
/// every one of them is obvious the instant it fires.
public enum GestureAction: String, Codable, CaseIterable {
    case none
    case toggleMute
    case toggleFreeze
    case takeStill
    case startReplay
    /// §5.11, and the one action here that takes the picture away entirely.
    /// Offered because a hand is exactly what is free at the moment panic is
    /// wanted, and shipped bound to nothing because a camera that blanks
    /// itself because somebody gestured while talking is the worst thing this
    /// app could do. It carries its own longer hold on top of every other
    /// rule — see `dwellSeconds(for:)`.
    case panic

    public var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .toggleMute: return "Mute or unmute"
        case .toggleFreeze: return "Freeze or unfreeze"
        case .takeStill: return "Take a still"
        case .startReplay: return "Play or stop the replay"
        case .panic: return "Panic"
        }
    }

    /// One line of consequence, for the surface that offers it. Nil where the
    /// name already says everything.
    public var caption: String? {
        switch self {
        case .panic:
            return "Blanks the camera and mutes the microphone. Held twice as long as the others, and still the one binding worth thinking twice about."
        case .toggleMute:
            return "The gesture works while you are already muted, which is the case it exists for."
        default:
            return nil
        }
    }
}

public struct GestureBinding: Codable, Equatable, Identifiable {
    public var pose: HandPose
    public var action: GestureAction
    public var isEnabled: Bool

    /// The pose is the identity: two bindings for the same pose would be a
    /// race decided by array order, so the model makes that unrepresentable.
    public var id: HandPose { pose }

    public init(pose: HandPose, action: GestureAction = .none, isEnabled: Bool = false) {
        self.pose = pose
        self.action = action
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pose = c.tolerant(.pose, .palm)
        action = c.tolerant(.action, GestureAction.none)
        isEnabled = c.tolerant(.isEnabled, false)
    }
}

public struct GestureSettings: Codable, Equatable {
    /// The master switch, off. On means a Vision hand-pose request on every
    /// frame, and it means the camera can act on what it sees you do — both
    /// are things to opt into, not out of.
    public var isEnabled: Bool = false
    public var bindings: [GestureBinding] = HandPose.allCases.map { GestureBinding(pose: $0) }
    /// How long the pose must be held before it fires. Long enough that a
    /// wave, a stretch or a hand resting on a chin cannot trigger anything.
    public var holdSeconds: Double = 0.8        // 0.3…3
    /// Refractory period after a gesture fires, so one held pose is one
    /// action rather than one per frame.
    public var cooldownSeconds: Double = 2.0    // 0.5…10
    /// Minimum recogniser confidence. High: a false positive here mutes a
    /// call nobody asked to mute.
    public var confidence: Double = 0.85        // 0.5…1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.tolerant(.isEnabled, false)
        bindings = c.tolerant(.bindings, HandPose.allCases.map { GestureBinding(pose: $0) })
        holdSeconds = c.tolerant(.holdSeconds, 0.8)
        cooldownSeconds = c.tolerant(.cooldownSeconds, 2.0)
        confidence = c.tolerant(.confidence, 0.85)
    }

    public var clampedHoldSeconds: Double { min(max(holdSeconds, 0.3), 3) }
    public var clampedCooldownSeconds: Double { min(max(cooldownSeconds, 0.5), 10) }
    public var clampedConfidence: Double { min(max(confidence, 0.5), 1) }

    /// The shortest hold panic will ever accept, whatever the user set the
    /// general one to. Panic is the only action here that takes the picture
    /// away, so it is the only one where a hold long enough to be tedious is
    /// cheaper than a hold short enough to be an accident — and 0.3 s, which
    /// the slider does allow, is inside the range a hand passing the lens
    /// occupies.
    public static let panicHoldFloorSeconds: Double = 1.5

    /// How long a pose must be held before it fires this action. One number
    /// for everything except panic, which takes the longer of the user's hold
    /// and its own floor. A second control for it would have been the
    /// obvious alternative and is the wrong shape (§8.7): nobody has an
    /// opinion about panic's dwell that is not already expressed by whether
    /// they bound it at all.
    public func dwellSeconds(for action: GestureAction) -> Double {
        action == .panic
            ? max(clampedHoldSeconds, Self.panicHoldFloorSeconds)
            : clampedHoldSeconds
    }

    /// The recogniser runs only when the switch is on AND some pose is
    /// actually bound to something — an enabled feature where every binding
    /// says "Nothing" is a switch wired to nothing (§8.7).
    public var isActive: Bool {
        isEnabled && bindings.contains { $0.isEnabled && $0.action != .none }
    }

    public func action(for pose: HandPose) -> GestureAction {
        guard isActive else { return .none }
        guard let binding = bindings.first(where: { $0.pose == pose }), binding.isEnabled else {
            return .none
        }
        return binding.action
    }
}
