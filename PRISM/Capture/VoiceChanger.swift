// VoiceChanger.swift
// PRISM
//
// Real-time voice effects for the microphone path (SPEC §5.13). The chain is
// deliberately time-domain DSP — a dual-grain delay-line pitch shifter, an
// autocorrelation pitch detector for the autotune modes, ring modulation,
// biquad filters, soft-clip drive, tremolo and a feedback echo — because
// time-domain stages have fixed, tiny per-sample cost and no lookahead
// beyond the pitch grains, which keeps the whole thing inside the §6 audio
// processing budget on the HAL's real-time IO thread.
//
// RT discipline (§4.3/§4.4): every buffer is preallocated, the process
// functions never allocate, never lock (the parameter handoff is a single
// trylock that falls back to the previous program), never log, and touch no
// managed references beyond `self`. Parameters are set from the main thread
// via `apply`; a torn slice is impossible because the RT side copies the
// pending program only when it wins the trylock.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import os

// MARK: - Effects

/// The user-facing effect list (§5.13). Raw values are persisted in
/// StudioSettings, so renaming a case is a forward-compatibility event —
/// the tolerant decoder falls back to `.off` for a name it does not know.
public enum VoiceEffect: String, Codable, CaseIterable, Identifiable {
    case off
    case chipmunk
    case helium
    case deep
    case giant
    case alien
    case robot
    case autotune
    case telephone
    case cave
    case underwater

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .chipmunk: return "Chipmunk"
        case .helium: return "Helium"
        case .deep: return "Deep"
        case .giant: return "Giant"
        case .alien: return "Alien"
        case .robot: return "Robot"
        case .autotune: return "Autotune"
        case .telephone: return "Telephone"
        case .cave: return "Cave"
        case .underwater: return "Underwater"
        }
    }

    /// One line of what the effect does, in §8.4 voice. Shown under the
    /// pickers so nobody has to try an effect mid-call to learn what it is.
    public var blurb: String {
        switch self {
        case .off: return "Straight through."
        case .chipmunk: return "Seven semitones up. Serious news, delivered badly."
        case .helium: return "A party balloon's worth of lift."
        case .deep: return "Four semitones down. Instant late-night radio."
        case .giant: return "Nearly an octave down, with a room to boom in."
        case .alien: return "Pitched up and ring-modulated until slightly off-world."
        case .robot: return "Locked to one metallic note."
        case .autotune: return "Every note snapped to the nearest semitone, pop-star hard."
        case .telephone: return "Squeezed through a 3 kHz landline."
        case .cave: return "Hello… hello… hello…"
        case .underwater: return "Muffled, wobbly, five metres down."
        }
    }
}

// MARK: - DSP program

/// RBJ biquad coefficients, normalised (a0 = 1). Value type only — copied
/// into the RT program without ARC traffic.
struct BiquadCoefficients {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0

    static func lowPass(_ hz: Double, q: Double,
                        sampleRate: Double = VoiceChanger.sampleRate) -> BiquadCoefficients {
        let w0 = 2 * Double.pi * hz / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        return BiquadCoefficients(
            b0: Float(((1 - cosw) / 2) / a0),
            b1: Float((1 - cosw) / a0),
            b2: Float(((1 - cosw) / 2) / a0),
            a1: Float((-2 * cosw) / a0),
            a2: Float((1 - alpha) / a0))
    }

    static func highPass(_ hz: Double, q: Double,
                         sampleRate: Double = VoiceChanger.sampleRate) -> BiquadCoefficients {
        let w0 = 2 * Double.pi * hz / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        return BiquadCoefficients(
            b0: Float(((1 + cosw) / 2) / a0),
            b1: Float((-(1 + cosw)) / a0),
            b2: Float(((1 + cosw) / 2) / a0),
            a1: Float((-2 * cosw) / a0),
            a2: Float((1 - alpha) / a0))
    }

    /// Bell around `hz`, for corrective cuts (§5.17).
    static func peaking(_ hz: Double, q: Double, gainDb: Double,
                        sampleRate: Double = VoiceChanger.sampleRate) -> BiquadCoefficients {
        let amplitude = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * hz / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / amplitude
        return BiquadCoefficients(
            b0: Float((1 + alpha * amplitude) / a0),
            b1: Float((-2 * cosw) / a0),
            b2: Float((1 - alpha * amplitude) / a0),
            a1: Float((-2 * cosw) / a0),
            a2: Float((1 - alpha / amplitude) / a0))
    }

    /// Shelf above `hz`, slope 1 (the RBJ S = 1 case).
    static func highShelf(_ hz: Double, gainDb: Double,
                          sampleRate: Double = VoiceChanger.sampleRate) -> BiquadCoefficients {
        let amplitude = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * hz / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / 2 * sqrt(2)
        let twoRootA = 2 * sqrt(amplitude) * alpha
        let a0 = (amplitude + 1) - (amplitude - 1) * cosw + twoRootA
        return BiquadCoefficients(
            b0: Float((amplitude * ((amplitude + 1) + (amplitude - 1) * cosw + twoRootA)) / a0),
            b1: Float((-2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosw)) / a0),
            b2: Float((amplitude * ((amplitude + 1) + (amplitude - 1) * cosw - twoRootA)) / a0),
            a1: Float((2 * ((amplitude - 1) - (amplitude + 1) * cosw)) / a0),
            a2: Float(((amplitude + 1) - (amplitude - 1) * cosw - twoRootA) / a0))
    }

    /// Flush-to-zero for recursive state. Anything below −400 dB is silence,
    /// and letting filter/envelope/echo state decay into the subnormal range
    /// makes every multiply on it ~100× slower on the Intel slice — a cost
    /// spike on the RT thread, paid exactly when the input goes digitally
    /// silent. It lives here because every recursive stage in this app is
    /// either a biquad or sits beside one.
    @inline(__always)
    static func flushDenormal(_ value: Float) -> Float {
        abs(value) < 1e-20 ? 0 : value
    }
}

enum AutotuneMode: Int32 {
    case none = 0
    /// Snap the detected fundamental to the nearest semitone of A440.
    case chromatic = 1
    /// Drag every note toward one fixed frequency — the robot monotone.
    case fixedNote = 2
}

/// Everything the RT path needs to render one effect, as plain value fields
/// so the whole struct copies without ARC. Built by `program(for:amount:)`
/// on the main thread; identity fields mean "skip that stage".
struct VoiceProgram {
    var active = false
    /// The grain shifter runs only when true; filter-only effects skip it and
    /// its ~21 ms of grain latency entirely.
    var usesPitch = false
    var pitchRatio: Float = 1
    /// Per-sample one-pole coefficient toward the target ratio. Fast for the
    /// autotune modes — the hard snap IS the sound people mean.
    var pitchGlide: Float = 0.002
    var autotune: AutotuneMode = .none
    var autotuneTargetHz: Float = 0
    /// Correction strength exponent, 0…1: the detected→target ratio is raised
    /// to this power, so partial amounts pull rather than snap.
    var autotuneAmount: Float = 1
    var ringModHz: Float = 0
    var ringModMix: Float = 0
    var filter1On = false
    var filter1 = BiquadCoefficients()
    var filter2On = false
    var filter2 = BiquadCoefficients()
    /// 0 = clean; otherwise tanh soft clip with pre-gain 1 + drive × 4.
    var drive: Float = 0
    var tremoloHz: Float = 0
    var tremoloDepth: Float = 0
    var echoDelayFrames: Int = 0
    var echoFeedback: Float = 0
    var echoMix: Float = 0
    /// One-pole lowpass coefficient inside the feedback loop, so repeats
    /// darken the way real reflections do.
    var echoDamp: Float = 0
    var outputGain: Float = 1
}

// MARK: - VoiceChanger

public final class VoiceChanger {

    public static let sampleRate: Double = 48_000

    /// Grain span of the pitch shifter, frames. The two crossfaded read taps
    /// average half a window behind the write head, so this is also the
    /// latency price of any pitched effect: 2048 / 48 kHz / 2 ≈ 21 ms —
    /// reported, never hidden (§5.13).
    static let grainFrames = 2048
    /// Pitch history ring; power of two for mask indexing. Only needs to
    /// exceed grainFrames + 1, generously.
    private static let pitchCapacity = 8192
    /// Echo ring; power of two, 683 ms at 48 kHz — comfortably above the
    /// longest programmed delay.
    private static let echoCapacity = 32_768

    // Pitch detection runs on a ×4-decimated signal: voice fundamentals live
    // below 500 Hz, and a 12 kHz detector is 16× cheaper than a 48 kHz one.
    private static let decimation = 4
    static let detectSampleRate = 12_000.0
    private static let detectWindow = 512      // 42.7 ms of decimated signal
    private static let detectHop = 128         // detect every ~10.7 ms
    /// Correlation window and lag range (500 Hz … 60 Hz at 12 kHz).
    static let correlationWindow = 256
    static let minLagFrames = 24
    static let maxLagFrames = 200

    // MARK: Public surface (main thread)

    /// Audio latency the current effect costs, for AudioCapture's
    /// addedLatencyMs. Written by apply(); a stale read is one slice old.
    public private(set) var reportedLatencyMs: Double = 0

    public init() {
        paramLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        paramLock.initialize(to: os_unfair_lock_s())
        pitchBuf = Self.zeroedBuffer(Self.pitchCapacity)
        echoBuf = Self.zeroedBuffer(Self.echoCapacity)
        detectBuf = Self.zeroedBuffer(Self.detectWindow)
        corrScratch = Self.zeroedBuffer(Self.maxLagFrames - Self.minLagFrames + 1)
        prepare(maxFrames: 4096)
    }

    deinit {
        pitchBuf.deallocate()
        echoBuf.deallocate()
        detectBuf.deallocate()
        corrScratch.deallocate()
        monoScratch?.deallocate()
        paramLock.deinitialize(count: 1)
        paramLock.deallocate()
    }

    /// Builds the DSP program for the settings and hands it to the RT path.
    /// Main thread; never blocks the RT callback (it copies the program only
    /// when its trylock wins).
    public func apply(_ settings: VoiceSettings) {
        let program = Self.program(for: settings.effect,
                                   amount: settings.clampedAmount)
        os_unfair_lock_lock(paramLock)
        pendingProgram = program
        pendingGeneration &+= 1
        os_unfair_lock_unlock(paramLock)
        reportedLatencyMs = program.usesPitch
            ? Double(Self.grainFrames) / 2 / Self.sampleRate * 1000
            : 0
    }

    /// Sizes the stereo mixdown scratch and clears all DSP state. Call from
    /// the capture setup path only, with the RT unit stopped — it reallocates
    /// and zeroes buffers the RT path indexes.
    public func prepare(maxFrames: Int) {
        if maxFrames > monoScratchFrames {
            monoScratch?.deallocate()
            monoScratch = Self.zeroedBuffer(maxFrames)
            monoScratchFrames = maxFrames
        }
        reset()
    }

    /// Clears delay lines, filters and detector state. Same threading rule
    /// as `prepare`.
    public func reset() {
        clearDSPState()
    }

    /// The state-clearing core behind `reset()`, RT-safe by construction:
    /// bounded memsets of preallocated buffers plus scalar stores, no
    /// allocation, no locks. The RT path calls this itself at an acoustic
    /// boundary — resuming from mute or clip suppression, or a program
    /// going inactive → active — because a delay line that froze across the
    /// gap would otherwise replay pre-mute audio on resume (§5.13: a mute
    /// must be acoustically clean in both directions).
    func clearDSPState() {
        pitchBuf.update(repeating: 0, count: Self.pitchCapacity)
        echoBuf.update(repeating: 0, count: Self.echoCapacity)
        detectBuf.update(repeating: 0, count: Self.detectWindow)
        // Write cursors start one full capacity in, so "cursor − delay" is
        // never negative and early reads land in the zeroed region.
        pitchWrite = Self.pitchCapacity
        echoWrite = Self.echoCapacity
        grainPhase = 0
        // Land on the program's ratio directly: gliding up from 1 after a
        // clear would chirp the first syllable of every unmute.
        currentRatio = rtProgram.pitchRatio
        rtTargetRatio = rtProgram.pitchRatio
        ringPhase = 0
        tremoloPhase = 0
        echoDampState = 0
        f1z1 = 0; f1z2 = 0; f2z1 = 0; f2z2 = 0
        decimSum = 0
        decimCount = 0
        detectFill = 0
    }

    // MARK: RT entry points

    /// In-place 48 kHz mono processing. RT-safe; a bypassed program costs one
    /// trylock and one comparison.
    func processMono(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        refreshProgram()
        guard rtProgram.active, frameCount > 0 else { return }
        processBlock(samples, frameCount)
    }

    /// In-place 48 kHz interleaved-stereo processing. The channels are mixed
    /// to mono first — a voice is mono, and every effect here deliberately is.
    func processStereoInterleaved(_ samples: UnsafeMutablePointer<Float>,
                                  frameCount: Int) {
        refreshProgram()
        guard rtProgram.active, frameCount > 0,
              let monoScratch, frameCount <= monoScratchFrames else { return }
        for i in 0..<frameCount {
            monoScratch[i] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5
        }
        processBlock(monoScratch, frameCount)
        for i in 0..<frameCount {
            samples[i * 2] = monoScratch[i]
            samples[i * 2 + 1] = monoScratch[i]
        }
    }

    // MARK: Private state

    private let paramLock: UnsafeMutablePointer<os_unfair_lock_s>
    /// Written under paramLock by apply(); read under trylock by the RT path.
    private var pendingProgram = VoiceProgram()
    private var pendingGeneration: UInt64 = 0
    /// RT-private copies; only the RT thread touches these after start.
    private var rtProgram = VoiceProgram()
    private var rtGeneration: UInt64 = 0

    // Pitch shifter
    private let pitchBuf: UnsafeMutablePointer<Float>
    private var pitchWrite = pitchCapacity
    private var grainPhase: Float = 0
    private var currentRatio: Float = 1
    private var rtTargetRatio: Float = 1

    // Oscillators
    private var ringPhase: Float = 0
    private var tremoloPhase: Float = 0

    // Filters (transposed direct form II state)
    private var f1z1: Float = 0, f1z2: Float = 0
    private var f2z1: Float = 0, f2z2: Float = 0

    // Echo
    private let echoBuf: UnsafeMutablePointer<Float>
    private var echoWrite = echoCapacity
    private var echoDampState: Float = 0

    // Pitch detector
    private let detectBuf: UnsafeMutablePointer<Float>
    private let corrScratch: UnsafeMutablePointer<Float>
    private var decimSum: Float = 0
    private var decimCount = 0
    private var detectFill = 0

    // Stereo mixdown scratch, sized by prepare().
    private var monoScratch: UnsafeMutablePointer<Float>?
    private var monoScratchFrames = 0

    private static func zeroedBuffer(_ count: Int) -> UnsafeMutablePointer<Float> {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        return buffer
    }

    /// Picks up a new program when the main thread has published one. A lost
    /// trylock means the setter held the lock this instant; the RT path keeps
    /// the previous program for one more slice, which is inaudible.
    private func refreshProgram() {
        guard os_unfair_lock_trylock(paramLock) else { return }
        var becameActive = false
        if rtGeneration != pendingGeneration {
            becameActive = pendingProgram.active && !rtProgram.active
            rtGeneration = pendingGeneration
            rtProgram = pendingProgram
            // The detector re-derives its correction on the next hop; until
            // then the base ratio is the honest target.
            rtTargetRatio = rtProgram.pitchRatio
        }
        os_unfair_lock_unlock(paramLock)
        // Off → on is an acoustic boundary: while bypassed the delay lines
        // sat frozen on whatever was last processed, and an effect switched
        // on must not open with an arbitrarily old echo tail.
        if becameActive {
            clearDSPState()
        }
    }

    // MARK: The chain

    private func processBlock(_ samples: UnsafeMutablePointer<Float>,
                              _ frameCount: Int) {
        let p = rtProgram
        let grainSpan = Float(Self.grainFrames)
        let pitchMask = Self.pitchCapacity - 1
        let echoMask = Self.echoCapacity - 1
        let echoDelay = min(max(p.echoDelayFrames, 1), Self.echoCapacity - 1)
        let ringInc = 2 * Float.pi * p.ringModHz / Float(Self.sampleRate)
        let tremoloInc = 2 * Float.pi * p.tremoloHz / Float(Self.sampleRate)
        let driveGain = 1 + p.drive * 4
        let twoPi = 2 * Float.pi

        for i in 0..<frameCount {
            var x = samples[i]

            // Silently swallow non-finite input rather than letting a NaN
            // colonise every delay line downstream.
            if !x.isFinite { x = 0 }

            // 1. Pitch detection (autotune modes) — fed the pre-shift signal,
            // on a ×4-decimated ring, every detectHop decimated samples.
            if p.autotune != .none {
                decimSum += x
                decimCount += 1
                if decimCount == Self.decimation {
                    detectBuf[detectFill] = decimSum * 0.25
                    detectFill += 1
                    decimSum = 0
                    decimCount = 0
                    if detectFill == Self.detectWindow {
                        updateAutotuneTarget()
                        // Slide the window by one hop; memmove is RT-safe.
                        memmove(detectBuf, detectBuf + Self.detectHop,
                                (Self.detectWindow - Self.detectHop)
                                    * MemoryLayout<Float>.size)
                        detectFill = Self.detectWindow - Self.detectHop
                    }
                }
            }

            // 2. Dual-grain pitch shift. Two read taps sweep a delay of
            // 0…grainSpan at rate (1 − ratio), half a cycle apart, each under
            // a sin² window — the windows sum to exactly 1, and each tap is
            // silent at the instant its delay wraps.
            if p.usesPitch {
                currentRatio += (rtTargetRatio - currentRatio) * p.pitchGlide
                pitchBuf[pitchWrite & pitchMask] = x
                grainPhase -= (currentRatio - 1) / grainSpan
                grainPhase -= floorf(grainPhase)          // wrap to [0, 1)
                let d1 = grainPhase * grainSpan
                var phase2 = grainPhase + 0.5
                if phase2 >= 1 { phase2 -= 1 }
                let d2 = phase2 * grainSpan
                let s1 = sinf(.pi * grainPhase)
                let s2 = sinf(.pi * phase2)
                x = grainRead(d1, mask: pitchMask) * (s1 * s1)
                    + grainRead(d2, mask: pitchMask) * (s2 * s2)
                pitchWrite += 1
            }

            // 3. Ring modulation.
            if p.ringModMix > 0 {
                x *= (1 - p.ringModMix) + p.ringModMix * sinf(ringPhase)
                ringPhase += ringInc
                if ringPhase > twoPi { ringPhase -= twoPi }
            }

            // 4. Filters (transposed direct form II, states flushed so a
            // silent stretch cannot decay them into subnormals).
            if p.filter1On {
                let y = p.filter1.b0 * x + f1z1
                f1z1 = BiquadCoefficients.flushDenormal(p.filter1.b1 * x - p.filter1.a1 * y + f1z2)
                f1z2 = BiquadCoefficients.flushDenormal(p.filter1.b2 * x - p.filter1.a2 * y)
                x = y
            }
            if p.filter2On {
                let y = p.filter2.b0 * x + f2z1
                f2z1 = BiquadCoefficients.flushDenormal(p.filter2.b1 * x - p.filter2.a1 * y + f2z2)
                f2z2 = BiquadCoefficients.flushDenormal(p.filter2.b2 * x - p.filter2.a2 * y)
                x = y
            }

            // 5. Soft-clip drive.
            if p.drive > 0 {
                x = tanhf(x * driveGain)
            }

            // 6. Tremolo.
            if p.tremoloDepth > 0 {
                x *= 1 - p.tremoloDepth * (0.5 + 0.5 * sinf(tremoloPhase))
                tremoloPhase += tremoloInc
                if tremoloPhase > twoPi { tremoloPhase -= twoPi }
            }

            // 7. Echo, with a damped feedback loop so repeats darken. Both
            // the wet tap and the damp state are flushed: the tail decays by
            // ×feedback per round trip forever, and without a floor it would
            // spend seconds circulating subnormals after the room goes quiet.
            if p.echoMix > 0 {
                let wet = BiquadCoefficients.flushDenormal(echoBuf[(echoWrite - echoDelay) & echoMask])
                echoDampState = BiquadCoefficients.flushDenormal(
                    echoDampState + (wet - echoDampState) * (1 - p.echoDamp))
                echoBuf[echoWrite & echoMask] = x + echoDampState * p.echoFeedback
                echoWrite += 1
                x = x * (1 - p.echoMix) + wet * p.echoMix
            }

            // 8. Gain, and a hard safety clamp: every stage above is bounded,
            // but the ring is shared with coreaudiod and a runaway sample must
            // never leave this function.
            x *= p.outputGain
            samples[i] = min(max(x, -1), 1)
        }
    }

    /// Linear-interpolated read `delay` frames behind the sample just
    /// written. delay ∈ [0, grainFrames] < pitchCapacity, and the write
    /// cursor starts a full capacity in, so indices are never negative.
    private func grainRead(_ delay: Float, mask: Int) -> Float {
        let whole = Int(delay)
        let frac = delay - Float(whole)
        let newest = pitchBuf[(pitchWrite - whole) & mask]
        let older = pitchBuf[(pitchWrite - whole - 1) & mask]
        return newest * (1 - frac) + older * frac
    }

    /// Runs the detector over the filled window and re-aims the shifter.
    private func updateAutotuneTarget() {
        let f0 = Self.detectFrequency(in: detectBuf,
                                      count: Self.detectWindow,
                                      sampleRate: Self.detectSampleRate,
                                      scratch: corrScratch)
        guard f0 > 0 else {
            // Unvoiced or silent: glide back to the base ratio rather than
            // holding the last correction into the next phrase.
            rtTargetRatio = rtProgram.pitchRatio
            return
        }
        let target: Double
        switch rtProgram.autotune {
        case .chromatic: target = Self.chromaticTarget(f0)
        case .fixedNote: target = Double(rtProgram.autotuneTargetHz)
        case .none: return
        }
        let correction = powf(Float(target / f0), rtProgram.autotuneAmount)
        rtTargetRatio = min(max(correction * rtProgram.pitchRatio, 0.5), 2.0)
    }

    // MARK: - Pure, testable pieces

    /// Normalised-autocorrelation pitch detector. `samples` is a
    /// chronological window; `scratch` must hold at least
    /// `maxLagFrames − minLagFrames + 1` floats (the per-lag correlations,
    /// kept for the octave check and the parabolic refinement). Returns the
    /// fundamental in Hz, or 0 when the window is silent or unvoiced.
    /// Allocation-free by construction so the RT path can call it directly.
    static func detectFrequency(in samples: UnsafePointer<Float>,
                                count: Int,
                                sampleRate: Double,
                                scratch: UnsafeMutablePointer<Float>) -> Double {
        let window = correlationWindow
        let minLag = minLagFrames
        let maxLag = maxLagFrames
        guard count >= window + maxLag else { return 0 }

        var energy0: Float = 0
        for i in 0..<window {
            energy0 += samples[i] * samples[i]
        }
        // Silence gate ≈ −48 dBFS RMS: breath noise must not autotune.
        guard energy0 > Float(window) * 0.004 * 0.004 else { return 0 }

        var bestLag = 0
        var bestR: Float = 0
        for lag in minLag...maxLag {
            var num: Float = 0
            var energyL: Float = 0
            for i in 0..<window {
                num += samples[i] * samples[i + lag]
                energyL += samples[i + lag] * samples[i + lag]
            }
            let r = num / (sqrtf(energy0 * energyL) + 1e-9)
            scratch[lag - minLag] = r
            if r > bestR {
                bestR = r
                bestLag = lag
            }
        }
        guard bestR > 0.5, bestLag > 0 else { return 0 }

        // Octave guard: autocorrelation peaks at every multiple of the true
        // period, and the double-period peak often edges out the real one.
        // When half the winning lag correlates nearly as well, it is the
        // fundamental.
        let half = bestLag / 2
        if half >= minLag, scratch[half - minLag] > 0.9 * bestR {
            bestLag = half
        }

        // Parabolic refinement between the neighbouring lags for sub-sample
        // period accuracy — a semitone at 200 Hz is only ~3 samples of lag.
        var tau = Double(bestLag)
        let index = bestLag - minLag
        if index > 0, index < maxLag - minLag {
            let left = Double(scratch[index - 1])
            let center = Double(scratch[index])
            let right = Double(scratch[index + 1])
            let denom = left - 2 * center + right
            if abs(denom) > 1e-12 {
                let delta = 0.5 * (left - right) / denom
                if abs(delta) < 1 { tau += delta }
            }
        }
        return sampleRate / tau
    }

    /// Nearest note of the A440 chromatic scale.
    static func chromaticTarget(_ hz: Double) -> Double {
        guard hz > 0 else { return 0 }
        let midi = (69 + 12 * log2(hz / 440)).rounded()
        return 440 * pow(2, (midi - 69) / 12)
    }

    /// The effect table (§5.13). `amount` scales pitch offsets geometrically
    /// and mixes/drive linearly, so a quarter-strength chipmunk is a subtle
    /// lift rather than a quieter squeak.
    static func program(for effect: VoiceEffect, amount: Double) -> VoiceProgram {
        var p = VoiceProgram()
        guard effect != .off else { return p }
        p.active = true
        let a = Float(min(max(amount, 0.25), 1))
        func ratio(_ semitones: Double) -> Float {
            Float(pow(2, semitones * Double(a) / 12))
        }

        switch effect {
        case .off:
            break
        case .chipmunk:
            p.usesPitch = true
            p.pitchRatio = ratio(7)
        case .helium:
            p.usesPitch = true
            p.pitchRatio = ratio(4)
        case .deep:
            p.usesPitch = true
            p.pitchRatio = ratio(-4)
        case .giant:
            p.usesPitch = true
            p.pitchRatio = ratio(-8)
            p.echoDelayFrames = 4320          // 90 ms of room
            p.echoFeedback = 0.25
            p.echoMix = 0.22 * a
            p.echoDamp = 0.35
            p.outputGain = 0.93               // wet sum peaks at ×1.07
        case .alien:
            p.usesPitch = true
            p.pitchRatio = ratio(3)
            p.ringModHz = 40
            p.ringModMix = 0.6 * a
            p.echoDelayFrames = 5760          // 120 ms
            p.echoFeedback = 0.2
            p.echoMix = 0.15 * a
            p.echoDamp = 0.3
            p.outputGain = 0.96               // wet sum peaks at ×1.04
        case .robot:
            p.usesPitch = true
            p.autotune = .fixedNote
            p.autotuneTargetHz = 130.8        // C3 — reachable from most
            p.autotuneAmount = a              // voices within the ratio clamp
            p.pitchGlide = 0.02               // monotone snaps, it never glides
            p.ringModHz = 60
            p.ringModMix = 0.45 * a
            p.drive = 0.35 * a
            p.outputGain = 0.8
        case .autotune:
            p.usesPitch = true
            p.autotune = .chromatic
            p.autotuneAmount = a
            p.pitchGlide = 0.02               // the hard snap IS the effect
        case .telephone:
            p.filter1On = true
            p.filter1 = .highPass(300, q: 0.707)
            p.filter2On = true
            p.filter2 = .lowPass(3400, q: 0.707)
            p.drive = 0.5 * a
            p.outputGain = 0.85
        case .cave:
            p.echoDelayFrames = 11_520        // 240 ms
            p.echoFeedback = 0.45
            p.echoMix = 0.5 * a
            p.echoDamp = 0.4
            // Delay-aligned material sums to ×1.41 at steady state
            // ((1 − mix) + mix / (1 − feedback)); the gain buys that
            // headroom back so a loud room never rides the safety clamp.
            p.outputGain = 0.7
        case .underwater:
            p.filter1On = true
            p.filter1 = .lowPass(500, q: 0.707)
            p.tremoloHz = 0.8
            p.tremoloDepth = 0.6 * a
            // No makeup gain: the tremolo still touches unity once per
            // cycle, so anything above 1 would hard-clip hot input on
            // every crest. Muffled is allowed to also be a little quiet.
        }
        return p
    }
}
