// GestureWatch.swift
// PRISM
//
// Hand gestures as a second hotkey surface (§5.31), as pure logic — no
// Vision, no frame path, no AppState. Two pieces: the shape classifier, which
// turns a set of hand joints into one of three named poses or into nothing,
// and the watch, which turns a stream of those into at most one action.
//
// The whole feature lives or dies on false positives, and the failure is not
// symmetric. A gesture that does not fire costs a raised hand and a second
// try. A gesture that fires by itself mutes a call nobody asked to mute, or —
// if panic were ever bound by default, which it is not — blanks the camera
// mid-sentence. People talk with their hands: an open palm is what you make
// while explaining something, a fist is what a hand resting on a mouse looks
// like from a webcam, and both of those happen while the user is saying
// words they expect to be heard. So four independent rules have to agree
// before anything happens, and each of them is asymmetric in the same
// direction:
//
//   - A CONFIDENCE FLOOR, high (0.85 by default). Vision scores a clean,
//     deliberate pose well above it and a hand caught mid-gesticulation well
//     below. Everything under the floor is not "probably nothing", it is no
//     observation at all.
//   - A DWELL. The pose has to be held, across consecutive observations, for
//     `holdSeconds` — 0.8 s by default, and 1.5 s for panic. Talking hands
//     are never still that long; a hand raised to do something is.
//   - A DEBOUNCE. One held pose is one action. After firing, the recogniser
//     latches until it has actually seen the pose end, so a palm held for
//     four seconds is one mute, not forty.
//   - A COOLDOWN. A refractory period across every pose, so a gesture cannot
//     be followed instantly by another one — including the one that would
//     undo it, which is how a flickering recogniser turns into a strobing
//     mute.
//
// And the clock only advances on observations, capped per observation, for
// the reason PresenceWatcher's does: a gap in the stream is not evidence that
// a hand was held through it.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import Foundation

// MARK: - Hand shape

/// The joints the classifier reads, named independently of Vision so the
/// geometry can be tested without a camera or a `VNRecognizedPoint` — which
/// cannot be constructed outside the framework.
///
/// Only the tip and the middle joint of each finger, plus the wrist. The
/// distal joints add nothing the ratio below does not already see, and every
/// extra required point is another chance for one low-confidence landmark to
/// throw away an otherwise clean reading.
public enum HandJoint: String, CaseIterable, Hashable {
    case wrist
    case indexTip, indexPIP
    case middleTip, middlePIP
    case ringTip, ringPIP
    case littleTip, littlePIP
}

public enum HandPoseClassifier {

    /// A finger is extended when its tip is this much further from the wrist
    /// than its middle joint is.
    ///
    /// Distance from the wrist rather than a joint angle, because the one
    /// thing a webcam guarantees is that the hand will be at an arbitrary
    /// roll: an angle test needs a hand-local frame to be meaningful and a
    /// radial one does not. The margin is what keeps a half-curled finger out
    /// of both answers — see `foldRatio`.
    static let extensionRatio: CGFloat = 1.15

    /// …and folded when the tip has come back *inside* the middle joint.
    /// Between the two ratios a finger is simply not read, which is what
    /// stops a hand in transit from resolving into a pose on its way past.
    static let foldRatio: CGFloat = 0.95

    /// One of the three poses, or nil for "this is not a gesture". Nil is by
    /// far the commonest answer and is the whole point: a classifier that
    /// always names its closest match turns every gesticulation into an
    /// input.
    ///
    /// The thumb is deliberately not read. It sits almost as far from the
    /// wrist folded as extended, so the radial test that works for four
    /// fingers is noise on the fifth — and none of the three poses needs it
    /// to be distinguishable.
    public static func classify(joints: [HandJoint: CGPoint]) -> HandPose? {
        guard let wrist = joints[.wrist] else { return nil }
        var extended = 0
        var folded = 0
        var reading: [Bool] = []
        for (tip, pip) in [(HandJoint.indexTip, HandJoint.indexPIP),
                           (.middleTip, .middlePIP),
                           (.ringTip, .ringPIP),
                           (.littleTip, .littlePIP)] {
            guard let tipPoint = joints[tip], let pipPoint = joints[pip] else {
                // A partly seen hand is not a pose. Guessing the missing
                // finger is exactly how a wave becomes a Victory.
                return nil
            }
            let reach = distance(tipPoint, wrist)
            let knuckle = distance(pipPoint, wrist)
            guard knuckle > 0 else { return nil }
            if reach > knuckle * extensionRatio {
                extended += 1
                reading.append(true)
            } else if reach < knuckle * foldRatio {
                folded += 1
                reading.append(false)
            } else {
                // In the dead band, so the hand is between shapes.
                return nil
            }
        }
        guard extended + folded == 4 else { return nil }
        if extended == 4 { return .palm }
        if folded == 4 { return .fist }
        // Victory is the only mixed shape in the catalogue, and it has to be
        // the exact mix: index and middle out, ring and little in. Two
        // extended fingers that are not those two is a shape nobody meant.
        if reading == [true, true, false, false] { return .victory }
        return nil
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - GestureWatch

public final class GestureWatch {

    /// The pose currently accumulating dwell, for a surface that wants to
    /// show a gesture being recognised before it fires. nil most of the time.
    public private(set) var holding: HandPose?

    public init() {}

    /// Feeds one observation and answers with the pose that just fired, or
    /// nil — which is the answer nearly every time.
    ///
    /// `pose` is nil when the detector ran and saw no hand, or saw one whose
    /// shape is not in the catalogue. Call only for real observations: "the
    /// request did not run this frame" is not a sighting of an empty desk,
    /// and feeding it as one would reset a dwell the user is halfway through.
    @discardableResult
    public func observe(pose: HandPose?, confidence: Double,
                        settings: GestureSettings, at now: Date) -> HandPose? {
        let elapsed = lastObservedAt.map { now.timeIntervalSince($0) } ?? 0
        lastObservedAt = now
        let step = min(max(elapsed, 0), Self.maximumStepSeconds)

        // Below the floor is not a weak sighting of a pose, it is no sighting.
        let accepted = (confidence >= settings.clampedConfidence) ? pose : nil

        // The debounce: the latch is only released by actually seeing the
        // pose stop. Anything else — a different pose, no hand, a reading
        // that fell under the floor — is the end of the hold.
        if accepted != latched { latched = nil }

        if let accepted, accepted == holding {
            heldSeconds += step
        } else {
            holding = accepted
            heldSeconds = 0
        }

        guard let candidate = holding, latched == nil else { return nil }
        // The cooldown is checked before the dwell rather than after, so a
        // pose held straight through it does not fire the instant it lapses.
        if let firedAt, now.timeIntervalSince(firedAt) < settings.clampedCooldownSeconds {
            return nil
        }
        let action = settings.action(for: candidate)
        guard action != .none else { return nil }
        guard heldSeconds >= settings.dwellSeconds(for: action) else { return nil }

        latched = candidate
        firedAt = now
        heldSeconds = 0
        return candidate
    }

    /// Forgets everything. Used when the recogniser stands down — the switch
    /// went off, a screen took over as the source — so a pose half-held when
    /// it stopped watching cannot complete minutes later.
    public func reset() {
        holding = nil
        heldSeconds = 0
        latched = nil
        firedAt = nil
        lastObservedAt = nil
    }

    // MARK: - Tuning

    /// How much one observation may advance the dwell. The recogniser runs at
    /// roughly 10 Hz unopposed and 6 Hz under full Vision contention (§5.23),
    /// so a quarter second never truncates a healthy stream — and it means a
    /// stalled one has to produce four separate sightings of the same pose
    /// before the default hold is satisfied, rather than one after a nap.
    static let maximumStepSeconds: Double = 0.25

    // MARK: - Private state

    private var heldSeconds: Double = 0
    /// Fired and not yet seen to end; see the debounce rule above.
    private var latched: HandPose?
    private var firedAt: Date?
    private var lastObservedAt: Date?
}
