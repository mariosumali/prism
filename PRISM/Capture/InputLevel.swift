// InputLevel.swift
// PRISM
//
// "Is the microphone hearing me" — the one audio question PRISM could not
// answer until a mic check was running (SPEC §5.15). Two pieces, both
// deliberately small: InputLevelMailbox, the lock-free scalar the RT capture
// callback publishes an RMS into, and MicWatch, the main-thread debounce
// that turns a stream of those levels into "you are talking and nobody can
// hear you".
//
// The mailbox is a mailbox, not a ring: a meter only ever wants the newest
// value, and a ring would hand the reader a backlog it would immediately
// throw away. One release-store per window, one acquire-load per UI tick,
// through the same C atomic shims MicTapRing uses (§4.3).
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - InputLevelMailbox

/// Single-writer/single-reader level mailbox. The RT callback accumulates
/// energy over a fixed window and publishes one packed word; the main thread
/// samples it on a timer.
///
/// RMS, not peak. Both the meter and the muted-and-talking watch are asking
/// how much *voice* is arriving, and a peak meter answers a different
/// question — a keyboard click and a spoken word peak alike, which is
/// exactly the confusion that would make the watch nag.
///
/// The publish counter shares the word with the value so a single atomic
/// store carries both: a reader that sees the counter unchanged knows no
/// audio arrived since it last looked (capture stopped, device gone, the
/// meter disarmed) and can decay rather than hold a stale reading forever.
final class InputLevelMailbox {

    /// Window length in frames. ~21 ms at 48 kHz, so the meter updates about
    /// 47×/s while the UI samples at 10 Hz — fast enough that a tick never
    /// straddles a window boundary it cares about, cheap enough to be free.
    static let windowFrames = 1024

    /// Packed as (sequence << 32) | rms.bitPattern. Heap-allocated so the C
    /// atomic shims can address it.
    private let cell: UnsafeMutablePointer<UInt64>

    // RT-private accumulator state; only the capture callback touches these.
    private var energy: Float = 0
    private var accumulated = 0
    private var sequence: UInt32 = 0

    init() {
        cell = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        cell.initialize(to: 0)
    }

    deinit {
        cell.deinitialize(count: 1)
        cell.deallocate()
    }

    // MARK: RT side

    /// Accumulates one interleaved slice and publishes whenever a window
    /// fills. RT-safe: a multiply-add per sample and, once per window, one
    /// sqrt and one release-store. No allocation, no locks, no branches on
    /// managed state.
    func accumulate(_ samples: UnsafePointer<Float>, frameCount: Int,
                    channels: Int) {
        guard frameCount > 0, channels > 0 else { return }
        let inverseChannels = 1 / Float(channels)
        var index = 0
        var remaining = frameCount
        while remaining > 0 {
            let chunk = min(remaining, Self.windowFrames - accumulated)
            for frame in 0..<chunk {
                var frameEnergy: Float = 0
                for channel in 0..<channels {
                    let sample = samples[(index + frame) * channels + channel]
                    // A NaN from a misbehaving device would poison the
                    // accumulator for every window after it.
                    frameEnergy += sample.isFinite ? sample * sample : 0
                }
                energy += frameEnergy * inverseChannels
            }
            accumulated += chunk
            index += chunk
            remaining -= chunk
            if accumulated >= Self.windowFrames {
                publish(rms: sqrtf(energy / Float(Self.windowFrames)))
                energy = 0
                accumulated = 0
            }
        }
    }

    /// Publishes a value directly. RT-safe; separated so the accumulator can
    /// be exercised without a slice.
    func publish(rms: Float) {
        sequence &+= 1
        let word = UInt64(sequence) << 32 | UInt64(rms.bitPattern)
        PRISMAtomicU64StoreRelease(cell, word)
    }

    /// Discards a part-filled window. Producer-side; call only while the RT
    /// unit is stopped, so a device swap cannot smear the old room's energy
    /// into the first window of the new one.
    func resetAccumulator() {
        energy = 0
        accumulated = 0
    }

    // MARK: Main-thread side

    /// The newest published window, with the counter that identifies it. A
    /// caller that sees the same counter twice has seen no new audio.
    var reading: (rms: Double, sequence: UInt32) {
        let word = PRISMAtomicU64LoadAcquire(cell)
        let rms = Float(bitPattern: UInt32(truncatingIfNeeded: word))
        return (rms.isFinite ? Double(rms) : 0, UInt32(truncatingIfNeeded: word >> 32))
    }
}

// MARK: - MicWatch

/// "You're muted but talking" (§5.15), as pure logic so the debounce can be
/// tested against a clock instead of a microphone.
///
/// The entire design problem here is nagging. A cough must never fire it,
/// and someone deliberately talking over a mute — presenting to the room,
/// answering the door, arguing with a colleague — must be told once and then
/// left alone. So the rules are:
///
/// - Speech has to be *sustained*: level above the speech threshold for
///   `sustainSeconds` of accumulated talking, where a gap shorter than
///   `gapSeconds` does not reset the accumulator (breathing between words is
///   still talking) and anything longer does. A cough is 150 ms and never
///   gets close.
/// - One alert per mute. Once it has fired, it will not fire again until the
///   microphone goes back on air — which is the user acting on it. Talking
///   through a ten-minute mute produces exactly one alert, not thirteen.
/// - Plus a floor on the interval between alerts, so mashing the mute key
///   cannot turn "once per mute" into a stutter.
///
/// The signal itself clears when the talking stops, so the menu bar stops
/// pointing at a problem that has gone away.
final class MicWatch {

    struct Tuning {
        /// RMS that counts as speech. Comfortable speech sits around
        /// 0.05–0.2 RMS; the threshold is well under that so a soft talker
        /// is still caught, and well over a quiet room so the fan is not.
        var speechRMS: Double = 0.03
        /// Accumulated speech before the alert fires.
        var sustainSeconds: Double = 1.2
        /// Quiet longer than this resets the accumulator.
        var gapSeconds: Double = 0.5
        /// Quiet longer than this clears an alert that already fired.
        var clearSeconds: Double = 4
        /// Floor on the interval between alerts, across mutes.
        var holdoffSeconds: Double = 20
    }

    /// The published signal: talking, right now, into a microphone nobody is
    /// hearing.
    private(set) var isTalking = false

    private let tuning: Tuning
    private var talkingSeconds: Double = 0
    private var quietSeconds: Double = 0
    /// Already alerted for the current off-air stretch; cleared when the
    /// microphone comes back on air.
    private var firedThisMute = false
    private var lastFiredAt: Date?
    private var lastUpdateAt: Date?

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Feeds one level sample. `offAir` is true when the microphone is not
    /// reaching the call — muted, or standing down while clip audio owns the
    /// ring (§5.3). Returns the current signal.
    @discardableResult
    func update(rms: Double, offAir: Bool, at now: Date) -> Bool {
        // A gap in the samples (the meter was disarmed, the app was asleep)
        // is not evidence of anything; treat the first tick after one as the
        // start of a fresh observation rather than a long silence.
        let elapsed = lastUpdateAt.map { now.timeIntervalSince($0) } ?? 0
        lastUpdateAt = now
        let step = min(max(elapsed, 0), 1)

        guard offAir else {
            // Back on air: the user can be heard again, so whatever we were
            // saying is moot and the next mute starts with a clean slate.
            reset(keepingHistory: true)
            return false
        }

        if rms >= tuning.speechRMS {
            // Capped: the accumulator is a threshold test, and letting it
            // run away would make a long monologue's tail behave differently
            // from its opening.
            talkingSeconds = min(talkingSeconds + step, tuning.sustainSeconds)
            quietSeconds = 0
        } else {
            quietSeconds += step
            if quietSeconds >= tuning.gapSeconds {
                talkingSeconds = 0
            }
            if isTalking, quietSeconds >= tuning.clearSeconds {
                isTalking = false
            }
        }

        if !isTalking, !firedThisMute, talkingSeconds >= tuning.sustainSeconds {
            let sinceLast = lastFiredAt.map { now.timeIntervalSince($0) }
            if sinceLast == nil || sinceLast! >= tuning.holdoffSeconds {
                isTalking = true
                firedThisMute = true
                lastFiredAt = now
            }
        }
        return isTalking
    }

    /// Clears the signal. `keepingHistory` retains the holdoff clock, so
    /// returning to air does not license an immediate second alert.
    func reset(keepingHistory: Bool = false) {
        isTalking = false
        talkingSeconds = 0
        quietSeconds = 0
        firedThisMute = false
        if !keepingHistory {
            lastFiredAt = nil
            lastUpdateAt = nil
        }
    }
}
