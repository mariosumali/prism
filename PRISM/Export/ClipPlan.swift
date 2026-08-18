// ClipPlan.swift
// PRISM
//
// The pure half of saving the last seconds (§5.15): deciding which buffered
// samples go into the file, when each one is shown, and how long it lasts.
//
// It is separated from the writer because it is the part that can be wrong
// in ways nobody notices until a file will not open. The rolling buffer's
// samples carry `.invalid` durations — VideoToolbox is handed `.invalid` on
// the way in and hands it straight back — and AVAssetWriter cannot build a
// sample table without them, so the durations have to be *synthesised* from
// the gaps between presentation times. Getting that wrong produces a .mov
// that writes without error and plays at the wrong speed, or not at all.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public struct ClipPlan: Equatable {

    /// One sample, as the writer will emit it.
    public struct Frame: Equatable {
        /// Index into the array the plan was built from.
        public let index: Int
        /// Rebased so the clip starts at zero. A file whose first sample is
        /// at host-clock 41 293 s is legal and unplayable in half the tools
        /// that will open it.
        public let presentationSeconds: Double
        public let durationSeconds: Double
    }

    public let frames: [Frame]

    public var durationSeconds: Double {
        guard let last = frames.last else { return 0 }
        return last.presentationSeconds + last.durationSeconds
    }
}

public enum ClipPlanner {

    /// Shortest and longest a synthesised duration may be.
    ///
    /// The floor rejects duplicate timestamps. The ceiling caps the frame
    /// that spans a camera stall: the recording really did pause, but a
    /// single sample held for eleven seconds reads as a hung file rather
    /// than as a gap, and a viewer scrubbing it cannot tell which.
    static let minimumFrameSeconds = 1.0 / 240
    static let maximumFrameSeconds = 1.0

    /// Plans a clip from the rolling buffer's timeline.
    ///
    /// Takes plain arrays rather than sample buffers so the decisions that
    /// matter — where the clip starts, what each frame's duration is — can be
    /// tested without a hardware encoder in the room.
    ///
    /// - Parameters:
    ///   - times: host-clock seconds per buffered sample, oldest first.
    ///   - keyframes: whether each sample stands alone.
    /// - Returns: nil when there is nothing decodable to write.
    public static func plan(times: [Double], keyframes: [Bool]) -> ClipPlan? {
        let count = min(times.count, keyframes.count)
        guard count > 1 else { return nil }

        // A clip that does not begin on a keyframe begins on frames that
        // reference pictures the file does not contain. The ring is already
        // trimmed to a keyframe boundary; this is the belt to that braces,
        // and it is also what makes the planner safe to hand an arbitrary
        // slice in a test.
        guard let start = (0..<count).first(where: { keyframes[$0] }) else { return nil }

        // Drop samples whose timestamp does not advance. A stalled or
        // repeated presentation time cannot be written — the sample table is
        // ordered by it — and dropping is the only repair that keeps every
        // remaining frame at its true moment.
        var kept: [Int] = []
        var previous = -Double.greatestFiniteMagnitude
        for index in start..<count where times[index] > previous {
            kept.append(index)
            previous = times[index]
        }
        guard kept.count > 1 else { return nil }

        let base = times[kept[0]]
        var frames: [ClipPlan.Frame] = []
        frames.reserveCapacity(kept.count)
        for (position, index) in kept.enumerated() {
            let duration: Double
            if position + 1 < kept.count {
                duration = times[kept[position + 1]] - times[index]
            } else {
                // The last sample has no successor to measure against, so it
                // inherits the gap before it. Repeating the previous delta is
                // the only estimate that cannot stretch the clip: it is the
                // rate the recording was actually running at.
                duration = times[index] - times[kept[position - 1]]
            }
            frames.append(ClipPlan.Frame(
                index: index,
                presentationSeconds: times[index] - base,
                durationSeconds: min(max(duration, minimumFrameSeconds),
                                     maximumFrameSeconds)))
        }
        return ClipPlan(frames: frames)
    }
}
