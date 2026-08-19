// VisionCoordinator.swift
// PRISM
//
// One place that decides which Vision request runs on this frame.
//
// There were two requests, and they stayed out of each other's way by each
// hard-coding a parity: segmentation on even frames, landmarks on odd. That
// works exactly as long as there are two of them. A third modality cannot
// pick a third parity out of two, so it would have landed on top of one of
// the existing ones — silently, on some frames, on a background queue, and
// the symptom would have been eye contact going soft when gestures were
// switched on, with nothing in the code saying why.
//
// So the alternation becomes a schedule instead of a coincidence. Every
// modality declares the duty cycle it wants; every consumer declares whether
// it currently wants that modality at all; and once per frame the coordinator
// picks at most one modality to run — the one that has waited longest
// relative to its own cadence, ties going to the modality declared first.
//
// Two properties fall out of that, and both are the point:
//
//   - With face and person demanded at cadence 2, the pick alternates exactly
//     as the hard-coded parities did. Nothing about eye contact changes until
//     a third modality is actually demanded, which is what keeps this a
//     refactor rather than a regression.
//   - When there are more modalities than frames to give them, every one of
//     them slips proportionally instead of one of them starving. A recogniser
//     running at two-thirds rate is a slightly slower gesture; a recogniser
//     that never runs is a feature that does not work.
//
// Demand is a set of closures rather than a flag anybody has to remember to
// clear. Stages are switched on and off from six places — presets, per-app
// rules, the degradation engine, hotkeys, gestures, panic — and a flag that
// has to be updated at each of them is a flag that will be stale at one of
// them. Asking is cheap; remembering is not.
//
// Threading: every entry point is frame-queue-confined, exactly like the
// trackers it schedules. No locks, because there is nothing to race with.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public final class VisionCoordinator {

    /// The kinds of thing Vision is asked to find. Declaration order is the
    /// tie-break: face first, because the eye-contact warp is the only
    /// consumer whose output is a geometric correction applied every frame —
    /// it degrades visibly, and sooner, than a silhouette or a gesture does.
    /// Presence last, because it is the only one whose consumer is measured
    /// in seconds: losing a tie costs it a thirtieth of a second out of six,
    /// and losing the same tie costs the warp a visible slip.
    public enum Modality: Int, CaseIterable, Comparable {
        case face
        case person
        case hands
        case presence

        public static func < (lhs: Modality, rhs: Modality) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// What this frame is for. `ended` carries the modalities whose last
    /// consumer just went away, so their owner can drop the measurement
    /// rather than leave a stale face or mask for something re-enabled in ten
    /// minutes' time to anchor itself to.
    public struct Decision: Equatable {
        public var demanded: Set<Modality> = []
        public var running: Modality?
        public var ended: Set<Modality> = []

        public init(demanded: Set<Modality> = [], running: Modality? = nil,
                    ended: Set<Modality> = []) {
            self.demanded = demanded
            self.running = running
            self.ended = ended
        }
    }

    public init() {}

    // MARK: - Registration

    /// A modality's owner registers it once, with the duty cycle it wants:
    /// `cadence` frames between requests when nothing else is competing.
    /// An unregistered modality never runs however loudly it is demanded,
    /// which is the seam a new recogniser arrives through — it exists as a
    /// case here long before anything registers it.
    public func register(_ modality: Modality, cadence: Int) {
        cadences[modality] = max(1, cadence)
    }

    /// One standing demand, evaluated once per frame. Several consumers may
    /// register for the same modality; the request runs if any of them wants
    /// it, which is the whole reason the mask survives the degradation engine
    /// switching background blur off underneath auto-framing.
    public func addConsumer(of modality: Modality, demand: @escaping () -> Bool) {
        consumers.append((modality, demand))
    }

    // MARK: - Per-frame decision

    /// Call once at the top of every frame, before anything reads the result.
    public func beginFrame() -> Decision {
        frameIndex &+= 1

        var demanded: Set<Modality> = []
        for (modality, demand) in consumers
        where cadences[modality] != nil && !demanded.contains(modality) {
            if demand() { demanded.insert(modality) }
        }

        let ended = previouslyDemanded.subtracting(demanded)
        previouslyDemanded = demanded
        // A modality that stopped being wanted forgets when it last ran, so
        // coming back does not make it look infinitely overdue and let it
        // shoulder the others off the next few frames.
        for modality in ended { lastRun.removeValue(forKey: modality) }
        // A modality seen for the first time is due now, and starts ageing
        // from now. Leaving it unseeded pins its staleness at exactly 1
        // forever, so it loses every tie it ever enters — which is a
        // recogniser that is demanded, scheduled, and never runs.
        for modality in demanded where lastRun[modality] == nil {
            lastRun[modality] = frameIndex - (cadences[modality] ?? 1)
        }

        let running = Self.pick(frame: frameIndex, demanded: demanded,
                                cadences: cadences, lastRun: lastRun)
        if let running { lastRun[running] = frameIndex }
        return Decision(demanded: demanded, running: running, ended: ended)
    }

    /// Forgets the schedule. Used when the frame source changes underneath —
    /// a resumed camera should not inherit the cadence of the one before it.
    public func reset() {
        frameIndex = 0
        lastRun.removeAll()
        previouslyDemanded.removeAll()
    }

    // MARK: - The policy, pure

    /// At most one modality per frame: the one furthest past its own cadence,
    /// ties to the earlier-declared modality. Staleness is measured against
    /// the modality's own cadence rather than in frames, so a request that
    /// wants every third frame and one that wants every second frame are
    /// compared on how overdue they are rather than on how patient they were
    /// asked to be.
    ///
    /// Internal rather than private so VisionCoordinatorTests can hold the
    /// schedule to the properties the comment above claims for it.
    static func pick(frame: Int, demanded: Set<Modality>,
                     cadences: [Modality: Int],
                     lastRun: [Modality: Int]) -> Modality? {
        var best: (modality: Modality, staleness: Double)?
        for modality in Modality.allCases where demanded.contains(modality) {
            guard let cadence = cadences[modality], cadence > 0 else { continue }
            let waited = lastRun[modality].map { frame - $0 } ?? cadence
            let staleness = Double(waited) / Double(cadence)
            guard staleness >= 1 else { continue }
            if best == nil || staleness > best!.staleness {
                best = (modality, staleness)
            }
        }
        return best?.modality
    }

    // MARK: - Private state (frame queue)

    private var cadences: [Modality: Int] = [:]
    private var consumers: [(modality: Modality, demand: () -> Bool)] = []
    private var lastRun: [Modality: Int] = [:]
    private var previouslyDemanded: Set<Modality> = []
    private var frameIndex = 0
}
