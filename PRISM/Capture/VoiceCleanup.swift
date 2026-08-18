// VoiceCleanup.swift
// PRISM
//
// Microphone cleanup on the capture path (SPEC §5.15): one picker over a
// fixed chain — high-pass, two-band noise expander, compressor, and, in
// Studio, a light corrective EQ. Independent of the §5.13 voice effects and
// always ahead of them, because cleanup exists to hand the effects a clean
// signal: the autotune detector and the grain shifter both degrade on a
// noisy input, and expanding a deliberately ring-modulated or echoed signal
// afterwards would chew the effect's own tail.
//
// Nothing here looks ahead, and that is a budget decision rather than a
// stylistic one. §6 allows 12 ms of added audio latency; the HAL buffer and
// the ring traversal already spend 10.7 ms of it. A spectral denoiser would
// need a window of delay before it did anything useful and would blow the
// budget on its own, so the whole chain is recursive filters and
// instantaneous gains: zero samples of lookahead, zero added latency, and
// no FFT to justify.
//
// RT discipline (§4.3/§4.4): every buffer is preallocated, the process
// functions never allocate, never lock (the same trylock program mailbox
// VoiceChanger uses), never log, and touch no managed references beyond
// `self`.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import os

// MARK: - Modes

/// The user-facing cleanup choice (§5.15). One picker, three answers —
/// "how much should PRISM tidy the microphone" is one question (§8.7), and
/// a rack of thresholds and ratios is a question nobody on a call wants.
/// Raw values are persisted in StudioSettings, so a rename falls back to
/// `.off` through the tolerant decoder.
public enum VoiceCleanupMode: String, Codable, CaseIterable, Identifiable {
    case off
    case cleanUp
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

// MARK: - DSP program

/// Everything the RT path needs to render one cleanup mode, as plain value
/// fields so the whole struct copies without ARC. Built by `program(for:)`
/// on the main thread.
struct CleanupProgram {
    var active = false

    /// Rumble, handling noise and desk thump, all below the voice.
    var highPass = BiquadCoefficients()
    /// The band split is complementary — high is `x − low` — so the two
    /// bands reconstruct the input exactly. A chain that decides to expand
    /// nothing therefore colours nothing.
    var splitLowPass = BiquadCoefficients()

    // Envelope follower, per band.
    var envAttack: Float = 0
    var envRelease: Float = 0
    /// Noise-floor tracker: the floor is the *minimum* the envelope reached
    /// over the last window, eased toward rather than snapped to. Tracking
    /// the minimum instead of the average is what lets it sit under a voice
    /// without being dragged up by one — speech dips between syllables and
    /// noise does not.
    var floorWindow: Int = 1
    var floorRise: Float = 0
    var floorFall: Float = 0
    // Band gain smoothing: opens fast enough not to clip a word's first
    // consonant, closes slowly enough not to chatter between syllables.
    var gainOpen: Float = 0
    var gainClose: Float = 0

    /// Envelope-over-floor ratio at which the band is fully open; below it
    /// the gain slides toward `floorGain` on a smoothstep.
    var lowOpenRatio: Float = 1
    var lowFloorGain: Float = 1
    var highOpenRatio: Float = 1
    var highFloorGain: Float = 1

    // Compressor, linked across channels (a voice is one source; gain-riding
    // the channels independently would wander the image).
    var compAttack: Float = 0
    var compRelease: Float = 0
    /// Reciprocal of the threshold in linear amplitude, so the detector's
    /// "how far over" is a multiply.
    var compInvThreshold: Float = 0
    /// 1/ratio − 1: the exponent that turns over-threshold into gain.
    var compExponent: Float = 0
    /// Width of the knee as a linear ratio above threshold.
    var compKneeSpan: Float = 1
    var makeupGain: Float = 1

    var eqOn = false
    var eq1 = BiquadCoefficients()
    var eq2 = BiquadCoefficients()
}

// MARK: - VoiceCleanup

public final class VoiceCleanup {

    public static let sampleRate: Double = 48_000

    /// Cleanup costs no latency at all — see the file header. Reported like
    /// every other audio cost so the meter never has to be believed on
    /// faith, and so a future stage that *does* buy lookahead cannot be
    /// added without the number moving.
    public let reportedLatencyMs: Double = 0

    public init() {
        paramLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        paramLock.initialize(to: os_unfair_lock_s())
        state = UnsafeMutablePointer<Float>.allocate(
            capacity: Self.maxChannels * Self.slotsPerChannel)
        state.initialize(repeating: 0,
                         count: Self.maxChannels * Self.slotsPerChannel)
        bands = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxChannels * 2)
        bands.initialize(repeating: 0, count: Self.maxChannels * 2)
        reset()
    }

    deinit {
        state.deallocate()
        bands.deallocate()
        paramLock.deinitialize(count: 1)
        paramLock.deallocate()
    }

    /// Builds the chain for the settings and hands it to the RT path. Main
    /// thread; never blocks the RT callback, which copies the pending
    /// program only when it wins the trylock.
    public func apply(_ settings: VoiceCleanupSettings) {
        let program = Self.program(for: settings.mode)
        os_unfair_lock_lock(paramLock)
        pendingProgram = program
        pendingGeneration &+= 1
        os_unfair_lock_unlock(paramLock)
    }

    /// Clears filters, envelopes and the learned noise floor. Safe from the
    /// RT path (bounded stores of preallocated memory) and from the capture
    /// setup path with the unit stopped.
    public func reset() {
        clearDSPState()
    }

    /// The state-clearing core, RT-safe by construction. The RT path runs it
    /// at the same acoustic boundaries the voice changer uses — resuming
    /// from mute or clip suppression, and off → on — because a floor learned
    /// before a mute describes a room that may no longer be there, and an
    /// envelope frozen mid-word would open the gate onto silence.
    func clearDSPState() {
        state.update(repeating: 0, count: Self.maxChannels * Self.slotsPerChannel)
        bands.update(repeating: 0, count: Self.maxChannels * 2)
        lowEnv = 0
        highEnv = 0
        compEnv = 0
        // −60 dBFS is a plausible quiet room, and the tracker converges on
        // the real one from either side within a couple of windows.
        lowFloor = 1e-3
        highFloor = 1e-3
        // The running minima start at full scale so the first window's
        // minimum is whatever actually arrived, not a leftover.
        lowCandidate = 1
        highCandidate = 1
        floorCounter = 0
        // Open, not closed: an unmute must not swallow the first word while
        // the gate works out where the floor is.
        lowGain = 1
        highGain = 1
    }

    // MARK: RT entry points

    /// In-place 48 kHz mono processing. RT-safe; an inactive program costs
    /// one trylock and one comparison.
    func processMono(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        refreshProgram()
        guard rtProgram.active, frameCount > 0 else { return }
        processBlock(samples, frameCount: frameCount, channels: 1)
    }

    /// In-place 48 kHz interleaved-stereo processing. The filters run per
    /// channel; the dynamics are detected on the channel mean and applied to
    /// both, so a stereo microphone keeps its image instead of being folded
    /// to mono the way the voice effects deliberately do.
    func processStereoInterleaved(_ samples: UnsafeMutablePointer<Float>,
                                  frameCount: Int) {
        refreshProgram()
        guard rtProgram.active, frameCount > 0 else { return }
        processBlock(samples, frameCount: frameCount, channels: 2)
    }

    // MARK: Private state

    private let paramLock: UnsafeMutablePointer<os_unfair_lock_s>
    private var pendingProgram = CleanupProgram()
    private var pendingGeneration: UInt64 = 0
    /// RT-private copies; only the RT thread touches these after start.
    private var rtProgram = CleanupProgram()
    private var rtGeneration: UInt64 = 0

    /// Biquad state, `slotsPerChannel` floats per channel: high-pass (0,1),
    /// band split (2,3), EQ 1 (4,5), EQ 2 (6,7). One flat buffer so the RT
    /// path indexes rather than reaching through a managed collection.
    private let state: UnsafeMutablePointer<Float>
    /// Per-channel band scratch for one sample: lows first, then highs.
    private let bands: UnsafeMutablePointer<Float>
    private static let maxChannels = 2
    private static let slotsPerChannel = 8

    // Detector state, shared across channels (linked dynamics).
    private var lowEnv: Float = 0
    private var highEnv: Float = 0
    private var lowFloor: Float = 1e-3
    private var highFloor: Float = 1e-3
    /// Running minimum of each band's envelope within the current window.
    private var lowCandidate: Float = 1
    private var highCandidate: Float = 1
    /// Shared, so both bands measure the same stretch of time.
    private var floorCounter = 0
    private var lowGain: Float = 1
    private var highGain: Float = 1
    private var compEnv: Float = 0

    /// Nothing plausibly called a noise floor sits above −34 dBFS. Without
    /// the ceiling, a sustained loud input — a test tone, a fan directly on
    /// the mic — would train the tracker up into speech level and the
    /// expander would start gating the voice it exists to protect.
    private static let floorCeiling: Float = 0.02
    private static let floorMinimum: Float = 1e-6

    /// Picks up a new program when the main thread has published one. A lost
    /// trylock means the setter holds the lock this instant; the RT path
    /// keeps the previous program for one more slice, which is inaudible.
    private func refreshProgram() {
        guard os_unfair_lock_trylock(paramLock) else { return }
        var becameActive = false
        if rtGeneration != pendingGeneration {
            becameActive = pendingProgram.active && !rtProgram.active
            rtGeneration = pendingGeneration
            rtProgram = pendingProgram
        }
        os_unfair_lock_unlock(paramLock)
        // Off → on is an acoustic boundary: while bypassed the followers sat
        // frozen on whatever was last processed, and the chain must not open
        // by gating against a floor learned minutes ago.
        if becameActive {
            clearDSPState()
        }
    }

    // MARK: The chain

    /// Order, and it is deliberate: high-pass → two-band expander →
    /// compressor → EQ. Filtering first means the expander's envelope is not
    /// fooled by rumble the listener will never hear; expanding before
    /// compression means the compressor is not busy making the room noise
    /// louder in the gaps; EQ last shapes what actually survives.
    private func processBlock(_ samples: UnsafeMutablePointer<Float>,
                              frameCount: Int, channels: Int) {
        let p = rtProgram
        let inverseChannels = 1 / Float(channels)

        for i in 0..<frameCount {
            var lowSum: Float = 0
            var highSum: Float = 0

            for ch in 0..<channels {
                var x = samples[i * channels + ch]
                // Swallow non-finite input rather than letting a NaN
                // colonise every follower downstream.
                if !x.isFinite { x = 0 }
                let slot = state + ch * Self.slotsPerChannel
                x = Self.biquad(x, p.highPass, slot)
                let low = Self.biquad(x, p.splitLowPass, slot + 2)
                bands[ch] = low
                bands[Self.maxChannels + ch] = x - low
                lowSum += abs(low)
                highSum += abs(x - low)
            }

            floorCounter += 1
            let closeWindow = floorCounter >= p.floorWindow
            if closeWindow { floorCounter = 0 }

            lowGain = expanderGain(magnitude: lowSum * inverseChannels,
                                   env: &lowEnv, floor: &lowFloor,
                                   candidate: &lowCandidate,
                                   closeWindow: closeWindow,
                                   gain: lowGain,
                                   openRatio: p.lowOpenRatio,
                                   floorGain: p.lowFloorGain)
            highGain = expanderGain(magnitude: highSum * inverseChannels,
                                    env: &highEnv, floor: &highFloor,
                                    candidate: &highCandidate,
                                    closeWindow: closeWindow,
                                    gain: highGain,
                                    openRatio: p.highOpenRatio,
                                    floorGain: p.highFloorGain)

            // Recombine, then detect the compressor's envelope on what the
            // expander actually let through — compressing the pre-gate level
            // would ride the gain against noise that is no longer there.
            var linked: Float = 0
            for ch in 0..<channels {
                let y = bands[ch] * lowGain + bands[Self.maxChannels + ch] * highGain
                bands[ch] = y
                linked += abs(y)
            }
            let compGain = compressorGain(magnitude: linked * inverseChannels)

            for ch in 0..<channels {
                var y = bands[ch] * compGain
                if p.eqOn {
                    let slot = state + ch * Self.slotsPerChannel
                    y = Self.biquad(y, p.eq1, slot + 4)
                    y = Self.biquad(y, p.eq2, slot + 6)
                }
                // Every stage above is bounded by construction, but the ring
                // is shared with coreaudiod and a runaway sample must never
                // leave this function.
                samples[i * channels + ch] = min(max(y, -1), 1)
            }
        }
    }

    /// One band of the downward expander.
    ///
    /// The floor is the minimum the envelope reached over the last window,
    /// eased toward rather than jumped to. Minimum-tracking is the whole
    /// trick: a voice spends most of a window well above its own troughs, so
    /// a long sentence does not drag the floor up behind it, while steady
    /// room noise has no troughs and is learned exactly. It also converges
    /// from below, which a proximity-gated tracker cannot — one that only
    /// learns while the signal is already near the floor can never find a
    /// floor it started underneath.
    @inline(__always)
    private func expanderGain(magnitude: Float,
                              env: inout Float, floor: inout Float,
                              candidate: inout Float, closeWindow: Bool,
                              gain: Float,
                              openRatio: Float, floorGain: Float) -> Float {
        // Timing is read field by field off the RT-private program rather
        // than passed in: the struct is ~30 words, and handing a copy of it
        // to a per-sample helper would be the one gratuitous cost on this
        // path.
        let p = rtProgram
        let attack = magnitude > env ? p.envAttack : p.envRelease
        env = BiquadCoefficients.flushDenormal(env + (magnitude - env) * attack)

        candidate = min(candidate, env)
        if closeWindow {
            let rate = candidate > floor ? p.floorRise : p.floorFall
            floor = min(max(floor + (candidate - floor) * rate,
                            Self.floorMinimum), Self.floorCeiling)
            candidate = env
        }

        // Smoothstep between "at the floor" (floorGain) and "clearly above
        // it" (unity), in the linear ratio — a log would buy nothing here
        // and costs a transcendental per sample per band.
        let ratio = env / floor
        let t = min(max((ratio - 1) / (openRatio - 1), 0), 1)
        let target = floorGain + (1 - floorGain) * (t * t * (3 - 2 * t))
        let rate = target > gain ? p.gainOpen : p.gainClose
        return BiquadCoefficients.flushDenormal(gain + (target - gain) * rate)
    }

    /// Feed-forward compressor with a smoothed knee. The gain is clamped at
    /// unity before the knee blend so the knee only ever softens the onset —
    /// a textbook quadratic knee would boost slightly below threshold here,
    /// which is not what "gentle compression" is supposed to mean.
    @inline(__always)
    private func compressorGain(magnitude: Float) -> Float {
        let p = rtProgram
        let attack = magnitude > compEnv ? p.compAttack : p.compRelease
        compEnv = BiquadCoefficients.flushDenormal(
            compEnv + (magnitude - compEnv) * attack)
        let over = compEnv * p.compInvThreshold
        guard over > 1 else { return p.makeupGain }
        let hard = min(powf(over, p.compExponent), 1)
        let t = min(max((over - 1) / (p.compKneeSpan - 1), 0), 1)
        return (1 + (hard - 1) * (t * t * (3 - 2 * t))) * p.makeupGain
    }

    /// Transposed direct form II, state flushed so a silent stretch cannot
    /// decay it into subnormals.
    @inline(__always)
    private static func biquad(_ x: Float, _ c: BiquadCoefficients,
                               _ z: UnsafeMutablePointer<Float>) -> Float {
        let y = c.b0 * x + z[0]
        z[0] = BiquadCoefficients.flushDenormal(c.b1 * x - c.a1 * y + z[1])
        z[1] = BiquadCoefficients.flushDenormal(c.b2 * x - c.a2 * y)
        return y
    }

    // MARK: - Pure, testable pieces

    /// One-pole coefficient for a time constant in milliseconds.
    static func rate(ms: Double) -> Float {
        Float(1 - exp(-1.0 / (ms / 1000 * sampleRate)))
    }

    /// Linear amplitude ratio for a level in dB.
    static func linear(db: Double) -> Float {
        Float(pow(10, db / 20))
    }

    /// The mode table (§5.15). Studio is not "Clean up, more": it expands
    /// harder *and* adds the EQ, which is exactly where tidying a microphone
    /// turns into changing what someone sounds like. Keeping that behind its
    /// own name is the honest split.
    static func program(for mode: VoiceCleanupMode) -> CleanupProgram {
        var p = CleanupProgram()
        guard mode != .off else { return p }
        p.active = true
        let studio = mode == .studio

        p.highPass = .highPass(80, q: 0.707, sampleRate: sampleRate)
        p.splitLowPass = .lowPass(1200, q: 0.707, sampleRate: sampleRate)

        p.envAttack = rate(ms: 3)
        p.envRelease = rate(ms: 60)
        // 750 ms is long enough to contain a pause between words and short
        // enough that walking into a noisier room is handled inside a
        // sentence. Rising is eased harder than falling: over-estimating the
        // floor gates the voice, under-estimating it merely leaves some
        // room in, and only one of those is worth being wrong about.
        p.floorWindow = Int(0.75 * sampleRate)
        p.floorRise = 0.3
        p.floorFall = 0.6
        p.gainOpen = rate(ms: 2)
        p.gainClose = rate(ms: 150)

        // The high band carries hiss and fan whine, so it may be pulled down
        // further than the low band before the result sounds hollow.
        p.lowOpenRatio = linear(db: studio ? 14 : 11)
        p.lowFloorGain = studio ? 0.03 : 0.10
        p.highOpenRatio = linear(db: studio ? 16 : 12)
        p.highFloorGain = studio ? 0.02 : 0.08

        p.compAttack = rate(ms: 10)
        p.compRelease = rate(ms: 120)
        p.compInvThreshold = 1 / linear(db: studio ? -20 : -24)
        p.compExponent = 1 / (studio ? 3.5 : 2.0) - 1
        p.compKneeSpan = linear(db: 8)
        // Makeup is deliberately less than the compression it replaces:
        // a chain that returns hot input to where it started would leave a
        // loud talker riding the safety clamp.
        p.makeupGain = linear(db: studio ? 5 : 3)

        if studio {
            p.eqOn = true
            // Boxiness lives around 350 Hz in almost every untreated room,
            // and presence is what a laptop microphone is missing.
            p.eq1 = .peaking(350, q: 1.0, gainDb: -2.5, sampleRate: sampleRate)
            p.eq2 = .highShelf(4500, gainDb: 3, sampleRate: sampleRate)
        }
        return p
    }

    /// Worst-case output amplitude for a full-scale input, used by the tests
    /// to prove no mode relies on the safety clamp for headroom. The
    /// expander only ever attenuates, so the bound is the compressor's
    /// steady-state gain at 0 dBFS times any EQ boost.
    static func peakGainAtFullScale(_ mode: VoiceCleanupMode) -> Double {
        let p = program(for: mode)
        guard p.active else { return 1 }
        let over = Double(p.compInvThreshold)
        let compressed = pow(over, Double(p.compExponent)) * Double(p.makeupGain)
        // The Studio shelf can add its full boost on top of the compressor.
        return compressed * (p.eqOn ? pow(10, 3.0 / 20) : 1)
    }
}
