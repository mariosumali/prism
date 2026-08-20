// SpeechResampler.swift
// PRISM
//
// 48 kHz mono Float32 down to the 16 kHz mono Float32 every Whisper model
// insists on (§5.32), plus the block-RMS helper the VAD and the session
// gate share.
//
// 48000 / 16000 is exactly 3, so the temptation is one line: keep every
// third sample and move on. That line is wrong in a way that does not show
// up in a waveform view. Decimating by 3 folds everything between 8 kHz and
// 24 kHz back down into 0…8 kHz, and PRISM's microphone path is full of
// content up there — sibilance, key clicks, fan noise, and whatever the
// voice changer's ring modulator and soft clipper have just manufactured.
// Folded down, that lands directly on top of the speech the recogniser is
// trying to read. A human hears it as a metallic buzz; the model reads it as
// phonemes it did not receive, and the word error rate measurably suffers.
// So: anti-alias first, then decimate. The filter is two cascaded RBJ
// biquads forming a 4th-order Butterworth low-pass at 7200 Hz, which is 0.9
// of the output rate's 8 kHz Nyquist — high enough to leave the fricatives
// alone, low enough that the corner is not sitting on the fold point. The
// coefficient formulas are Robert Bristow-Johnson's Audio EQ Cookbook
// (public domain, republished in the W3C Web Audio API specification) by way
// of this repo's own `BiquadCoefficients.lowPass`; the two Q values are the
// Butterworth pole angles, 1/(2·cos 22.5°) and 1/(2·cos 67.5°).
//
// It is worth stating what that filter does not do, because someone will
// eventually measure it and think it is broken. At 12 kHz it gives 23.4 dB,
// not the 40 dB you might hope for — 10·log10(1 + (tan(π·12000/48000) /
// tan(π·7200/48000))^8). Reaching 40 dB at 12 kHz needs a 7th-order filter
// or a cutoff near 4.7 kHz, and the 4.7 kHz version would throw away the top
// third of the band Whisper was trained on to fix an alias that lands, at
// worst, 23 dB under the speech. Above about 15.5 kHz — where the fold lands
// on the low vowels rather than the high consonants, and where the voice
// changer's junk actually lives — the same filter is past 40 dB and climbing
// fast. That is the trade, and it is the right one.
//
// Not `AVAudioConverter`, which would have been the obvious answer. It
// allocates, it is not real-time safe, its rate-conversion quality is a
// property you set rather than a response you can measure, and it exists to
// solve the hard case — arbitrary non-integer ratios, format conversion,
// channel mapping — none of which is this. An exact 3:1 integer decimation
// with a filter whose stopband you can write down in a comment is fifty
// lines that never surprise anyone.
//
// This runs on the consumer side: the ~10 Hz main-thread drain that pulls
// captured audio out of the tap ring and hands it to the recogniser. It is
// deliberately not on the HAL's render thread, so the §4.3 rules do not
// strictly bind it. It obeys most of them anyway — no locks, no logging, no
// allocation per call beyond whatever growth the caller's `out` array needs,
// which is why the API appends into a buffer the caller owns and reuses
// rather than returning a fresh array every 100 ms.
//
// The filter state and the decimation phase counter live in the instance and
// survive across calls, which is the only genuinely subtle thing here. Reset
// either one at a chunk boundary and every boundary becomes a step
// discontinuity: a click at 10 Hz, forever. Whisper transcribes clicks. It
// transcribes them as words, confidently, and they end up in the user's
// notes.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public final class SpeechResampler {

    public static let inputRate: Double = 48_000
    public static let outputRate: Double = 16_000

    /// Exactly 3. Named rather than inlined so the one place that would have
    /// to change if either rate ever moved is impossible to miss.
    public static let decimation = 3

    /// 0.9 × the 8 kHz Nyquist of the output rate.
    public static let cutoffHz: Double = 7_200

    /// The Butterworth pole Qs for a 4th-order cascade: 1/(2·cos 22.5°) and
    /// 1/(2·cos 67.5°). Together the two sections are exactly −3 dB at the
    /// cutoff — 0.5412 × 1.3066 = 0.7071 — which is the cheapest way to check
    /// that nobody has edited one of them in isolation.
    static let sectionQ: (Double, Double) = (0.5412, 1.3066)

    private let section1: BiquadCoefficients
    private let section2: BiquadCoefficients

    // Transposed Direct Form II, two state registers per section rather than
    // DF1's four. TDF2 is the right form for float biquads: its state holds
    // quantities on the order of the signal itself, so the rounding error
    // stays proportional to the sample rather than to some internal
    // accumulator, and it needs half the memory traffic. DF1's advantage is
    // that its internal sum cannot overflow between the feedforward and
    // feedback halves, which matters in fixed point and is meaningless here.
    private var s1z1: Float = 0, s1z2: Float = 0
    private var s2z1: Float = 0, s2z2: Float = 0

    /// Which of the three input samples we are on. Persists across calls;
    /// see the header for what happens when it does not.
    private var phase = 0

    public init() {
        section1 = .lowPass(Self.cutoffHz, q: Self.sectionQ.0,
                            sampleRate: Self.inputRate)
        section2 = .lowPass(Self.cutoffHz, q: Self.sectionQ.1,
                            sampleRate: Self.inputRate)
    }

    /// Returns the instance to the state a freshly constructed one is in.
    /// Call it between takes, never between chunks of one take.
    public func reset() {
        s1z1 = 0; s1z2 = 0
        s2z1 = 0; s2z2 = 0
        phase = 0
    }

    /// Appends resampled samples to `out`. Returns how many were appended.
    ///
    /// Output sample *m* is input sample *3m*: the phase is chosen so the
    /// first sample of a take emerges as the first sample of the output,
    /// which keeps the input-frame-to-output-frame mapping a multiplication.
    /// Word timestamps are computed from that mapping, and an off-by-one
    /// phase would smear every one of them by 62.5 µs in a direction that
    /// depends on where the chunk boundaries happened to fall.
    @discardableResult
    public func append(_ input: UnsafePointer<Float>, frameCount: Int,
                       into out: inout [Float]) -> Int {
        guard frameCount > 0 else { return 0 }

        // One growth, at most, per call. The caller reuses `out`, so after
        // the first few chunks of a session this reserves nothing at all.
        let expected = (frameCount + Self.decimation - 1) / Self.decimation
        out.reserveCapacity(out.count + expected)

        // Hoisted into locals so the inner loop is arithmetic on registers
        // rather than repeated reads through `self`.
        let f1 = section1
        let f2 = section2
        var z11 = s1z1, z12 = s1z2
        var z21 = s2z1, z22 = s2z2
        var p = phase
        var emitted = 0

        for i in 0..<frameCount {
            let x = input[i]

            let y1 = f1.b0 * x + z11
            z11 = BiquadCoefficients.flushDenormal(f1.b1 * x - f1.a1 * y1 + z12)
            z12 = BiquadCoefficients.flushDenormal(f1.b2 * x - f1.a2 * y1)

            let y2 = f2.b0 * y1 + z21
            z21 = BiquadCoefficients.flushDenormal(f2.b1 * y1 - f2.a1 * y2 + z22)
            z22 = BiquadCoefficients.flushDenormal(f2.b2 * y1 - f2.a2 * y2)

            if p == 0 {
                out.append(y2)
                emitted += 1
            }
            p += 1
            if p == Self.decimation { p = 0 }
        }

        s1z1 = z11; s1z2 = z12
        s2z1 = z21; s2z2 = z22
        phase = p
        return emitted
    }

    /// Convenience for tests and for array-shaped callers.
    @discardableResult
    public func append(_ input: [Float], into out: inout [Float]) -> Int {
        input.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return append(base, frameCount: buffer.count, into: &out)
        }
    }
}

/// Level measurement for the speech path.
///
/// Separate from `MicCheck.displayLevel`, which answers a different question:
/// that one lifts RMS with a square root so a meter looks right to a human,
/// and a gate built on a perceptually warped number is a gate whose threshold
/// means nothing. This one is the plain physical quantity.
public enum SpeechLevel {

    /// Root mean square of a block. The gate that keeps a recogniser from
    /// hallucinating on silence.
    ///
    /// Silence is the failure mode worth spending a gate on: given a block of
    /// near-nothing, an autoregressive speech model does not return an empty
    /// string, it returns whatever its training data contained most of — a
    /// caption sting, a subscribe reminder, a line of somebody else's film.
    /// The cheapest defence is to never hand it the block.
    public static func rms(_ samples: [Float]) -> Double {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return rms(base, count: buffer.count)
        }
    }

    public static func rms(_ samples: UnsafePointer<Float>, count: Int) -> Double {
        guard count > 0 else { return 0 }
        // Accumulated in Double, not Float. A gate block is tens of thousands
        // of samples and the values being summed are squares — a Float
        // accumulator loses the quiet tail of a block to the loud head, which
        // biases the measurement upward exactly on the marginal blocks where
        // the threshold decision is actually being made.
        var energy = 0.0
        for i in 0..<count {
            let value = Double(samples[i])
            energy += value * value
        }
        return (energy / Double(count)).squareRoot()
    }
}
