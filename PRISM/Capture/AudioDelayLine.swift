// AudioDelayLine.swift
// PRISM
//
// The §5.12 deliberate delay line: a plain circular PCM buffer the RT
// capture callback pushes every slice into, emitting the slice that was
// pushed `delayFrames` ago.
//
// It is its own type for the same reason VoiceChanger and VoiceCleanup are:
// it holds up to ten seconds of the user's voice that has *not gone out
// yet*, so there has to be one place that can be told to forget it. Mute is
// that instruction. Muting mid-sentence to say something private and then
// unmuting must never put the seconds before the mute on air — the line was
// still holding them, and without `reset()` the next slice reads straight
// out of the middle of that speech. Releasing the switch is the same
// instruction for the same reason: the frames left in the line belong to a
// session that has ended, and a later engage must start empty rather than
// open with something said minutes ago.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// Interleaved stereo delay line, RT-safe throughout: every method is
/// bounded pointer arithmetic and memcpy over memory allocated once by
/// `allocate(maxDelayFrames:headroomFrames:)`, called from the setup queue
/// while the unit is stopped. Reachable from the RT callback through a
/// `let` reference, the same argument AudioCapture makes for the voice
/// chains: a constant reference the owner holds for its whole lifetime
/// costs no ARC traffic.
final class AudioDelayLine {

    /// What one pushed slice should put on air.
    ///
    /// Split rather than copied out, so the caller can hand the frames
    /// straight to the ring without an intermediate buffer — the same
    /// zero-copy write the line replaced.
    struct Window: Equatable {
        /// Frames of silence to send before the run, because the line has
        /// not filled to the requested depth yet. This is the stall at the
        /// start of a delay, and silence is the honest thing to send.
        var silenceFrames: Int
        /// Frame index into the line of the run that follows, and how many
        /// frames it is. The run wraps at `capacityFrames`.
        var start: Int
        var frames: Int
    }

    /// Frames the buffer holds, delay depth plus one slice of headroom.
    private(set) var capacityFrames = 0
    /// Deepest delay the line will honour — the capacity less the headroom,
    /// so the window being read can never overlap the frames being written.
    private(set) var maxDelayFrames = 0

    /// Frames pushed since the last `reset()`, monotonic, wrapped on use.
    /// Nothing below this cursor is ever read, which is what makes `reset()`
    /// a complete forgetting without touching the samples themselves.
    private(set) var writtenFrames: UInt64 = 0

    private var data: UnsafeMutablePointer<Float>?

    deinit { deallocate() }

    /// Setup queue only, with the RT unit stopped.
    func allocate(maxDelayFrames: Int, headroomFrames: Int) {
        deallocate()
        guard maxDelayFrames > 0, headroomFrames > 0 else { return }
        self.maxDelayFrames = maxDelayFrames
        capacityFrames = maxDelayFrames + headroomFrames
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * 2)
        buffer.initialize(repeating: 0, count: capacityFrames * 2)
        data = buffer
        writtenFrames = 0
    }

    /// Setup queue only, with the RT unit stopped.
    func deallocate() {
        data?.deallocate()
        data = nil
        capacityFrames = 0
        maxDelayFrames = 0
        writtenFrames = 0
    }

    /// Forgets everything the line is holding. RT-safe: one store.
    ///
    /// The samples are left where they are on purpose — a memset of four
    /// megabytes is not something an IO callback may do, and it is not
    /// needed: `push` never reads below the cursor, so frames written before
    /// a reset are unreachable rather than merely stale.
    func reset() {
        writtenFrames = 0
    }

    /// The requested depth, clamped to what this line can actually honour.
    func clampedDelayFrames(_ requested: Int) -> Int {
        min(max(requested, 0), maxDelayFrames)
    }

    /// Whether a slice of this size may be pushed at all.
    func canHold(frameCount: Int) -> Bool {
        data != nil && frameCount > 0 && frameCount <= capacityFrames
    }

    /// Appends one slice and returns the window that is now due on air.
    /// RT-safe: two bounded memcpys and integer arithmetic.
    func push(_ samples: UnsafePointer<Float>,
              frameCount: Int,
              delayFrames: Int) -> Window {
        guard let data, canHold(frameCount: frameCount) else {
            return Window(silenceFrames: 0, start: 0, frames: 0)
        }
        var cursor = Int(writtenFrames % UInt64(capacityFrames))
        var remaining = frameCount
        var source = samples
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - cursor)
            memcpy(data + cursor * 2, source, chunk * 2 * MemoryLayout<Float>.size)
            cursor = (cursor + chunk) % capacityFrames
            source += chunk * 2
            remaining -= chunk
        }
        writtenFrames &+= UInt64(frameCount)

        let start = Int64(writtenFrames) - Int64(delayFrames) - Int64(frameCount)
        guard start >= 0 else {
            // Not filled yet: send silence for the part of the window that
            // predates the reset, then whatever of it the line does hold.
            let missing = min(frameCount, Int(-start))
            return Window(silenceFrames: missing, start: 0, frames: frameCount - missing)
        }
        return Window(silenceFrames: 0,
                      start: Int(start % Int64(capacityFrames)),
                      frames: frameCount)
    }

    /// Frames at `index`, readable up to the wrap at `capacityFrames`.
    /// nil before `allocate`.
    func base(at index: Int) -> UnsafePointer<Float>? {
        guard let data, index >= 0, index < capacityFrames else { return nil }
        return UnsafePointer(data + index * 2)
    }
}
