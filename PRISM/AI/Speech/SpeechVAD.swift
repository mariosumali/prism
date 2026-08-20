// SpeechVAD.swift
// PRISM
//
// The gate in front of the recogniser (§5.32): which spans of 16 kHz mono
// audio hold speech, and which are room tone nobody should pay to decode.
//
// Whisper was trained on speech and will produce speech for whatever it is
// handed. Thirty seconds of an empty room comes back as "Thank you." or
// "Subtitles by the Amara.org community" — the training corpus's own
// boilerplate, emitted with high confidence, because the decoder has no
// token for "there was nothing here". Every mitigation that lives
// downstream of the decode — no-speech probability, average logprob
// thresholds, blocklists of the famous phrases — is an argument with a
// model that has already run and already cost its inference. Not calling it
// is cheaper than all of them combined, and it is the only one that also
// saves the battery.
//
// The detector is the energy VAD, reimplemented rather than imported.
// Ported from WhisperKit's `Sources/WhisperKit/Core/Audio/EnergyVAD.swift`
// and the `AudioProcessor.calculateVoiceActivity` it delegates to (MIT,
// Argmax Inc.). PRISM does not link WhisperKit: the recogniser sits behind
// a seam and is expected to be swapped, and a gate that only exists when
// one particular package is present is a gate that silently stops being
// tested the day the package moves. This is forty lines of arithmetic —
// carrying it is cheaper than carrying the dependency, and it means the
// tests below exercise the code that actually ships.
//
// Energy rather than a neural VAD is a deliberate ceiling. A Silero-class
// model is genuinely better at telling a sentence from a slammed door, and
// it costs a second model to ship, a CoreML load at launch, and an
// inference per frame on a machine already running a camera pipeline. The
// failure modes here are not symmetric: a false positive costs one wasted
// decode, a false negative costs a sentence that never appears in the
// transcript. So the threshold sits low, doors get through, and the
// recogniser's own output is filtered further downstream.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Detector

public struct SpeechVAD {

    /// Everything reaching the recogniser is 16 kHz mono; the resampler
    /// upstream guarantees it. The constant lives here so callers turning
    /// milliseconds into sample counts do not each pick their own rate.
    public static let sampleRate = 16_000

    /// 100 ms at 16 kHz. Short enough to find a word boundary, long enough
    /// that one plosive does not open the gate.
    public var frameLengthSamples: Int = 1_600

    /// WhisperKit's EnergyVAD default.
    public var energyThreshold: Float = 0.02

    public init(energyThreshold: Float = 0.02, frameLengthSamples: Int = 1_600) {
        self.energyThreshold = energyThreshold
        self.frameLengthSamples = frameLengthSamples
    }

    /// Never zero, however the property was set. Every loop below strides by
    /// it, and a stride of zero is a hang rather than a misconfiguration —
    /// the sort of thing that only shows up on the machine of the one user
    /// who edited a defaults key.
    private var frameLength: Int { max(1, frameLengthSamples) }

    /// Mean absolute amplitude over `start..<end`.
    ///
    /// Mean absolute, not RMS. That is what WhisperKit's EnergyVAD measures,
    /// and the 0.02 default is calibrated against it; switching to RMS moves
    /// the gate by a couple of dB on speech and considerably more on
    /// broadband noise, at which point the threshold no longer means what
    /// its source means. Nobody should "fix" this.
    private static func meanAbsolute(_ buffer: UnsafeBufferPointer<Float>,
                                     from start: Int, to end: Int) -> Float {
        guard end > start else { return 0 }
        var sum: Float = 0
        for index in start..<end {
            sum += abs(buffer[index])
        }
        return sum / Float(end - start)
    }

    // MARK: Per-frame

    /// Per-frame voiced/unvoiced.
    ///
    /// The trailing partial frame is included and measured over the samples
    /// it actually has, matching WhisperKit's round-up chunk count. Dropping
    /// it would silently discard up to 100 ms off the end of every buffer,
    /// which is exactly where the word a user is mid-way through saying
    /// lives.
    public func voiceActivity(in samples: [Float]) -> [Bool] {
        guard !samples.isEmpty else { return [] }
        let frameLength = self.frameLength
        let frameCount = (samples.count + frameLength - 1) / frameLength
        var flags = [Bool](repeating: false, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                let start = frame * frameLength
                let end = min(start + frameLength, buffer.count)
                flags[frame] = Self.meanAbsolute(buffer, from: start, to: end) > energyThreshold
            }
        }
        return flags
    }

    /// Whether any frame is voiced.
    ///
    /// The hot path — asked of every rolling buffer before a decode is
    /// scheduled — so it stops at the first voiced frame instead of
    /// materialising the whole flag array.
    public func containsSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let frameLength = self.frameLength
        return samples.withUnsafeBufferPointer { buffer -> Bool in
            var start = 0
            while start < buffer.count {
                let end = min(start + frameLength, buffer.count)
                if Self.meanAbsolute(buffer, from: start, to: end) > energyThreshold {
                    return true
                }
                start = end
            }
            return false
        }
    }

    /// Fraction of frames that are voiced, 0…1.
    ///
    /// Not a confidence. It is the number the caller uses to decide a chunk
    /// is mostly silence with a cough in it and not worth a decode.
    public func speechFraction(_ samples: [Float]) -> Double {
        let flags = voiceActivity(in: samples)
        guard !flags.isEmpty else { return 0 }
        var voiced = 0
        for flag in flags where flag { voiced += 1 }
        return Double(voiced) / Double(flags.count)
    }

    // MARK: Spans

    /// Contiguous voiced spans as half-open sample index ranges, merged
    /// across gaps shorter than `mergeGapSamples` and padded by
    /// `padSamples` on each side (clamped to the buffer).
    ///
    /// The merge is the point. Frame-accurate spans of a sentence are a
    /// dozen fragments, because ordinary speech is full of 150 ms stops
    /// between words and a plosive's silent closure; feeding those to a
    /// recogniser one at a time gets a dozen decodes, no context across word
    /// boundaries, and worse text than a single call. 300 ms of default gap
    /// swallows the within-sentence pauses and leaves the between-turn ones.
    ///
    /// The padding is the other half: the energy gate opens a frame late and
    /// closes a frame early on the quiet consonants that start and end
    /// words, so a span cut exactly at the flags loses the "s" off the front
    /// and the "t" off the back.
    public func speechRanges(in samples: [Float],
                             mergeGapSamples: Int = 4_800,
                             padSamples: Int = 1_600) -> [Range<Int>] {
        let flags = voiceActivity(in: samples)
        guard !flags.isEmpty else { return [] }
        let frameLength = self.frameLength
        let limit = samples.count

        var runs: [Range<Int>] = []
        var runStart: Int?
        for (index, voiced) in flags.enumerated() {
            if voiced {
                if runStart == nil { runStart = index * frameLength }
            } else if let start = runStart {
                runs.append(start..<min(index * frameLength, limit))
                runStart = nil
            }
        }
        if let start = runStart {
            runs.append(start..<limit)
        }
        guard let first = runs.first else { return [] }

        let gap = max(0, mergeGapSamples)
        var merged: [Range<Int>] = [first]
        for run in runs.dropFirst() {
            let last = merged[merged.count - 1]
            if run.lowerBound - last.upperBound < gap {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, run.upperBound)
            } else {
                merged.append(run)
            }
        }

        let pad = max(0, padSamples)
        var padded: [Range<Int>] = []
        for run in merged {
            let lower = max(0, run.lowerBound - pad)
            let upper = min(limit, run.upperBound + pad)
            guard lower < upper else { continue }
            if let last = padded.last, lower <= last.upperBound {
                // Padding can close a gap that was wide enough to survive the
                // merge above, and two ranges that overlap mean the caller
                // decodes the same audio twice and then has to reconcile two
                // sets of words for one sentence. Cheaper to not emit them.
                padded[padded.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                padded.append(lower..<upper)
            }
        }
        return padded
    }

    /// Index of the last sample of the final voiced frame, or nil. Used to
    /// trim a rolling buffer back to the end of speech so a decode is not
    /// paid for on trailing room tone.
    ///
    /// A sample index rather than a frame index because the caller is
    /// slicing an audio buffer, and every conversion between the two is a
    /// chance to be one frame — 100 ms, most of a syllable — out.
    public func lastVoicedSampleIndex(in samples: [Float]) -> Int? {
        let flags = voiceActivity(in: samples)
        guard let last = flags.lastIndex(of: true) else { return nil }
        return min((last + 1) * frameLength, samples.count) - 1
    }
}

// MARK: - Chunking policy

/// When a run of speech has gone on long enough to cut, and how much silence
/// it takes to cut it (§5.32).
///
/// Ported from hyprnote/anarlog's `crates/audio-chunking/src/vad/session.rs`
/// (MIT). The constants are theirs and are not arbitrary — they are what a
/// shipped meeting recorder converged on — so they are reproduced rather
/// than re-derived.
///
/// The thresholds read as probabilities because hyprnote's detector is a
/// neural VAD that emits one per frame. `SpeechVAD` emits a boolean, which
/// is the degenerate case and needs no special handling: a voiced frame
/// clears every positive threshold, an unvoiced frame falls under every
/// negative one. Keeping the policy in probability space is what lets a
/// better detector drop in later without renegotiating any of these
/// numbers.
public struct SpeechChunkPolicy {

    /// A frame at or above this is speech, and opens a chunk.
    public var positiveSpeechThreshold: Float = 0.5
    /// A frame below this is silence, and starts the redemption countdown.
    /// The floor of the sliding threshold below.
    public var negativeSpeechThreshold: Float = 0.35
    /// The ceiling of the sliding threshold: how eager a young chunk is to
    /// treat a frame as silence.
    public var maxNegativeThreshold: Float = 0.80
    /// How long silence must persist before a chunk actually closes. Speech
    /// is full of gaps this long, and a chunker without redemption cuts in
    /// the middle of every second sentence.
    public var redemptionMs: Int = 600
    /// Audio kept from before the first voiced frame. The gate opens late on
    /// a soft onset; this is what gets the first word back.
    public var preSpeechPadMs: Int = 600
    /// Shorter than this is a click, a keystroke or a chair, not a word.
    public var minSpeechMs: Int = 90
    /// Below this a chunk is not worth a decode on its own.
    public var minChunkSeconds: Double = 3
    /// What a chunk is aiming for. Whisper's context is 30 s; 20 leaves room
    /// for the padding and the tail without ever truncating.
    public var targetChunkSeconds: Double = 20
    /// The hard stop. Someone who does not pause for 25 seconds gets cut
    /// mid-sentence, and that is the correct trade against never emitting
    /// anything at all.
    public var maxChunkSeconds: Double = 25

    public init() {}

    /// The part everyone omits: the silence threshold that closes a chunk
    /// slides from maxNegativeThreshold down to negativeSpeechThreshold as
    /// the chunk grows from minChunkSeconds to targetChunkSeconds, so short
    /// chunks close eagerly and long ones resist splitting mid-sentence.
    /// Linear interpolation, clamped at both ends.
    ///
    /// A fixed threshold has to choose which failure to have. Set it high
    /// and every breath ends a chunk, producing two-second fragments the
    /// recogniser has no context for. Set it low and a chunk runs to the
    /// hard cap and gets cut in the middle of a word. Sliding it makes the
    /// chunker's willingness to cut a function of how much it already has,
    /// which is the actual question.
    public func negativeThreshold(forSpeechSeconds seconds: Double) -> Float {
        let span = targetChunkSeconds - minChunkSeconds
        // A policy edited into target ≤ min has no ramp to interpolate over.
        // Returning the floor keeps it usable rather than NaN.
        guard span > 0 else { return negativeSpeechThreshold }
        let progress = min(1, max(0, (seconds - minChunkSeconds) / span))
        return maxNegativeThreshold
            + Float(progress) * (negativeSpeechThreshold - maxNegativeThreshold)
    }
}
