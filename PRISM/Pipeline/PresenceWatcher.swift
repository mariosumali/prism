// PresenceWatcher.swift
// PRISM
//
// "Nobody has been in frame for a while" (§5.28), as pure logic, so the
// hysteresis can be tested against a clock instead of against a room.
//
// The whole design problem here is the false positive. A late trigger costs
// nothing — the loop starts a second after you walked out and nobody was
// watching anyway. A false trigger costs the thing this app exists to
// protect: it puts a recording of you on air while you are sitting right
// there talking, and you find out when somebody says "you've frozen". So
// every rule below is asymmetric in the same direction:
//
//   - Leaving is slow (seconds, configurable, six by default) and coming back
//     is fast (one second). Reaching out of shot for a coffee does not empty
//     the frame for six seconds; going to answer the door does.
//   - The two coverage thresholds are not the same number. Dropping below
//     three quarters of the threshold counts as gone; getting back above the
//     threshold itself counts as back; in between, nothing is decided. A
//     subject sitting exactly on one number would otherwise flap across it
//     with the shot noise and never accumulate either way.
//   - Time only advances on observations, and one observation can only ever
//     advance it by so much. A gap in the samples — the detector stood down,
//     the camera went away, the Mac slept — is not evidence that the room
//     emptied. Integrating a ten-minute gap the moment the camera came back
//     would fire the away loop at precisely the wrong moment.
//
// `unknown` is a real third state and not a synonym for `absent`, for the
// same reason: before anything has been measured there is no evidence either
// way, and acting on no evidence is the failure.
//
// Nothing here touches Vision, the frame path or AppState. It takes a
// coverage number and a date and answers with an edge.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public final class PresenceWatcher {

    /// What just changed. Deliberately edges rather than levels: the actions
    /// this drives (start a loop, hold a frame) are one-shot, and firing them
    /// once per departure rather than once per absent observation is what
    /// makes a manual escape stick — the user turning it off by hand is not
    /// overridden a second later, because there is no second edge until they
    /// have been seen back in frame and left again.
    public enum Transition: Equatable {
        case none
        case left
        case returned
    }

    public private(set) var state: PresenceState = .unknown

    public init() {}

    /// Feeds one observation: how much of the frame the subject spans, 0 when
    /// the detector ran and found nobody. Call only for real measurements —
    /// "the detector did not run" is not an observation of an empty room, and
    /// passing 0 for it is the bug this comment exists to prevent.
    @discardableResult
    public func observe(coverage: Double, settings: PresenceSettings,
                        at now: Date) -> Transition {
        let elapsed = lastObservedAt.map { now.timeIntervalSince($0) } ?? 0
        lastObservedAt = now
        let step = min(max(elapsed, 0), Self.maximumStepSeconds)

        let present = settings.clampedCoverage
        let gone = present * Self.releaseRatio

        if coverage >= present {
            presentSeconds += step
            absentSeconds = 0
        } else if coverage < gone {
            absentSeconds += step
            presentSeconds = 0
        } else {
            // The dead band. Neither accumulator moves, so a subject hovering
            // on the threshold holds whatever state they were already in.
            return .none
        }

        switch state {
        case .unknown:
            // The first sighting settles the state without announcing
            // anything: there is nothing to undo, and nothing was on air.
            if coverage >= present {
                state = .present
                absentSeconds = 0
            } else if absentSeconds >= settings.clampedAwaySeconds {
                state = .absent
                return .left
            }
        case .present:
            if absentSeconds >= settings.clampedAwaySeconds {
                state = .absent
                presentSeconds = 0
                return .left
            }
        case .absent:
            if presentSeconds >= settings.clampedReturnSeconds {
                state = .present
                absentSeconds = 0
                return .returned
            }
        }
        return .none
    }

    /// Forgets everything. Used when the detector stands down — a feature
    /// switched off, a screen taking over as the source — so the next stretch
    /// of watching starts from no evidence rather than from minutes ago.
    public func reset() {
        state = .unknown
        absentSeconds = 0
        presentSeconds = 0
        lastObservedAt = nil
    }

    // MARK: - Tuning

    /// How much one observation may advance the clock. The detector runs at
    /// roughly 1 Hz even under full Vision contention (§5.28), so a two-second
    /// ceiling never truncates a healthy stream and turns every unhealthy one
    /// into a delay rather than a misfire.
    static let maximumStepSeconds: Double = 2

    /// The lower of the two coverage thresholds, as a fraction of the upper.
    /// Wide enough to swallow the frame-to-frame wobble of a detector box,
    /// narrow enough that leaning back is not mistaken for leaving.
    static let releaseRatio: Double = 0.75

    // MARK: - Private state

    private var absentSeconds: Double = 0
    private var presentSeconds: Double = 0
    private var lastObservedAt: Date?
}
