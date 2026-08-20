// SpeechVADTests.swift
// PRISMTests
//
// The gate that keeps the recogniser away from silence (§5.32).
//
// The bug class this file exists to catch is the one that costs nothing at
// the time and everything afterwards: a VAD that is quietly always-on, or
// quietly always-off. Neither crashes. An always-on gate shows up weeks
// later as "Thank you." arriving in the transcript during the ten minutes
// nobody was talking, and as a battery complaint; an always-off gate shows
// up as a transcript that is simply missing sentences, which nobody can
// even report properly. So the first two tests pin the two ends — digital
// silence is never speech, a full-scale tone always is — and everything
// after them is about the arithmetic in between.
//
// The rest defends the span logic, which is where the real mistakes live.
// Off-by-one in a half-open range slices a buffer one frame short and eats
// a syllable. Merging that runs before padding rather than after leaves
// overlapping ranges, and the caller decodes the same audio twice and gets
// two sets of words for one sentence. Padding that is not clamped indexes
// past the end of the buffer, which is a crash in a release build and a
// trap in a debug one. None of that is visible by reading the output.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class SpeechVADTests: XCTestCase {

    // MARK: - Helpers

    /// One VAD frame: 100 ms at 16 kHz. The fixtures are built in whole
    /// frames so a test that fails is failing about the logic and not about
    /// which side of a frame boundary a burst happened to land on.
    private let frame = 1_600

    private func silence(frames: Int) -> [Float] {
        [Float](repeating: 0, count: frames * frame)
    }

    private func tone(frames: Int, amplitude: Float = 0.8,
                      frequency: Double = 1_000) -> [Float] {
        let count = frames * frame
        let step = 2 * Double.pi * frequency / Double(SpeechVAD.sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] = amplitude * Float(sin(step * Double(index)))
        }
        return samples
    }

    // MARK: - The two ends

    func testDigitalSilenceIsNeverSpeech() {
        let vad = SpeechVAD()
        let quiet = silence(frames: 20)
        XCTAssertFalse(vad.containsSpeech(quiet))
        XCTAssertEqual(vad.speechFraction(quiet), 0, accuracy: 1e-12)
        XCTAssertEqual(vad.voiceActivity(in: quiet), [Bool](repeating: false, count: 20))
        XCTAssertTrue(vad.speechRanges(in: quiet).isEmpty)
        XCTAssertNil(vad.lastVoicedSampleIndex(in: quiet))
    }

    func testAFullScaleToneIsSpeechInEveryFrame() {
        let vad = SpeechVAD()
        let loud = tone(frames: 20, amplitude: 1)
        XCTAssertTrue(vad.containsSpeech(loud))
        XCTAssertEqual(vad.speechFraction(loud), 1, accuracy: 1e-12)
        XCTAssertEqual(vad.voiceActivity(in: loud).count, 20)
        XCTAssertFalse(vad.voiceActivity(in: loud).contains(false))
    }

    func testAnEmptyBufferIsNeitherSpeechNorACrash() {
        let vad = SpeechVAD()
        XCTAssertFalse(vad.containsSpeech([]))
        XCTAssertEqual(vad.speechFraction([]), 0, accuracy: 1e-12)
        XCTAssertTrue(vad.voiceActivity(in: []).isEmpty)
        XCTAssertTrue(vad.speechRanges(in: []).isEmpty)
        XCTAssertNil(vad.lastVoicedSampleIndex(in: []))
    }

    /// A rolling buffer is never a whole number of frames, and the tail is
    /// exactly where the word currently being said lives.
    func testATrailingPartialFrameIsStillMeasured() {
        let vad = SpeechVAD()
        var loud = tone(frames: 2)
        loud.append(contentsOf: tone(frames: 1).prefix(800))   // 2.5 frames
        XCTAssertEqual(vad.voiceActivity(in: loud), [true, true, true])
        XCTAssertEqual(vad.lastVoicedSampleIndex(in: loud), loud.count - 1)
    }

    // MARK: - Spans

    func testSilenceThenToneThenSilenceIsOneRange() {
        let vad = SpeechVAD()
        let samples = silence(frames: 10) + tone(frames: 10) + silence(frames: 10)
        let ranges = vad.speechRanges(in: samples)
        // Not three ranges, and not one range covering the whole buffer:
        // the tone, plus a frame of padding on each side.
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.lowerBound, 10 * frame - 1_600)
        XCTAssertEqual(ranges.first?.upperBound, 20 * frame + 1_600)
    }

    func testBurstsCloserThanTheMergeGapBecomeOneRange() {
        let vad = SpeechVAD()
        // 200 ms of silence between the bursts, against a 300 ms merge gap:
        // this is an ordinary pause between words, not the end of a turn.
        let samples = silence(frames: 5) + tone(frames: 5) + silence(frames: 2)
            + tone(frames: 5) + silence(frames: 5)
        let ranges = vad.speechRanges(in: samples, mergeGapSamples: 4_800,
                                      padSamples: 1_600)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.lowerBound, 5 * frame - 1_600)
        XCTAssertEqual(ranges.first?.upperBound, 17 * frame + 1_600)
    }

    func testBurstsFartherApartThanTheMergeGapStaySeparate() {
        let vad = SpeechVAD()
        // 600 ms of silence: long enough to be somebody finishing.
        let samples = silence(frames: 5) + tone(frames: 5) + silence(frames: 6)
            + tone(frames: 5) + silence(frames: 5)
        let ranges = vad.speechRanges(in: samples, mergeGapSamples: 4_800,
                                      padSamples: 1_600)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.first?.lowerBound, 5 * frame - 1_600)
        XCTAssertEqual(ranges.first?.upperBound, 10 * frame + 1_600)
        XCTAssertEqual(ranges.last?.lowerBound, 16 * frame - 1_600)
        XCTAssertEqual(ranges.last?.upperBound, 21 * frame + 1_600)
    }

    /// Ranges are handed straight to a slice of the buffer they came from.
    /// Anything outside its bounds is a trap, not a wrong transcript.
    func testRangesNeverLeaveTheBuffer() {
        let vad = SpeechVAD()
        let fixtures: [[Float]] = [
            tone(frames: 3),                                   // speech at both edges
            tone(frames: 1),                                   // shorter than the padding
            silence(frames: 1) + tone(frames: 1),
            tone(frames: 1) + silence(frames: 1),
            silence(frames: 4) + tone(frames: 2) + silence(frames: 4),
            Array(tone(frames: 1).prefix(37)),                 // a fragment of a frame
        ]
        let settings: [(merge: Int, pad: Int)] = [
            (4_800, 1_600), (0, 0), (0, 100_000), (100_000, 100_000), (-5, -5),
        ]
        for samples in fixtures {
            for setting in settings {
                let ranges = vad.speechRanges(in: samples,
                                              mergeGapSamples: setting.merge,
                                              padSamples: setting.pad)
                var previousUpper = 0
                for range in ranges {
                    XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
                    XCTAssertLessThanOrEqual(range.upperBound, samples.count)
                    XCTAssertLessThan(range.lowerBound, range.upperBound)
                    // Ordered and disjoint, so a caller can concatenate the
                    // slices without decoding any sample twice.
                    XCTAssertGreaterThan(range.lowerBound, previousUpper - 1)
                    previousUpper = range.upperBound
                }
            }
        }
    }

    func testGenerousPaddingCollapsesIntoASingleRangeRatherThanOverlappingOnes() {
        let vad = SpeechVAD()
        let samples = silence(frames: 4) + tone(frames: 2) + silence(frames: 6)
            + tone(frames: 2) + silence(frames: 4)
        // The gap survives the merge (600 ms against a 300 ms gap) but the
        // padding is wide enough to close it afterwards.
        let ranges = vad.speechRanges(in: samples, mergeGapSamples: 4_800,
                                      padSamples: 8_000)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.first?.upperBound, samples.count)
    }

    // MARK: - Trimming the tail

    func testLastVoicedSampleIndexIsNilForSilence() {
        XCTAssertNil(SpeechVAD().lastVoicedSampleIndex(in: silence(frames: 30)))
    }

    func testLastVoicedSampleIndexLandsInsideTheFinalBurst() {
        let vad = SpeechVAD()
        let samples = tone(frames: 3) + silence(frames: 5) + tone(frames: 2)
            + silence(frames: 10)
        guard let index = vad.lastVoicedSampleIndex(in: samples) else {
            return XCTFail("expected a voiced frame")
        }
        // The second burst, not the first, and not somewhere in the ten
        // frames of room tone the caller is trying to throw away.
        XCTAssertGreaterThanOrEqual(index, 8 * frame)
        XCTAssertLessThan(index, 10 * frame)
    }

    // MARK: - Chunk policy

    func testShortChunksCloseOnTheEagerThreshold() {
        let policy = SpeechChunkPolicy()
        XCTAssertEqual(policy.negativeThreshold(forSpeechSeconds: 0), 0.80, accuracy: 1e-6)
        XCTAssertEqual(policy.negativeThreshold(forSpeechSeconds: 1.5), 0.80, accuracy: 1e-6)
        XCTAssertEqual(policy.negativeThreshold(forSpeechSeconds: 3), 0.80, accuracy: 1e-6)
    }

    func testLongChunksCloseOnTheReluctantThreshold() {
        let policy = SpeechChunkPolicy()
        XCTAssertEqual(policy.negativeThreshold(forSpeechSeconds: 20), 0.35, accuracy: 1e-6)
        XCTAssertEqual(policy.negativeThreshold(forSpeechSeconds: 25), 0.35, accuracy: 1e-6)
        XCTAssertEqual(policy.negativeThreshold(forSpeechSeconds: 600), 0.35, accuracy: 1e-6)
    }

    func testTheClosingThresholdSlidesLinearlyBetweenTheTwo() {
        let policy = SpeechChunkPolicy()
        let midpoint = policy.negativeThreshold(forSpeechSeconds: 11.5)
        XCTAssertGreaterThan(midpoint, policy.negativeSpeechThreshold)
        XCTAssertLessThan(midpoint, policy.maxNegativeThreshold)
        XCTAssertEqual(midpoint, 0.575, accuracy: 1e-6)
    }

    func testTheClosingThresholdNeverRisesAsAChunkGrows() {
        let policy = SpeechChunkPolicy()
        // Strictly decreasing across the ramp: a flat stretch in here means
        // the interpolation collapsed to a step and short chunks stopped
        // being eager.
        var previous = policy.negativeThreshold(forSpeechSeconds: policy.minChunkSeconds)
        for step in 1...68 {
            let seconds = policy.minChunkSeconds + Double(step) * 0.25
            let value = policy.negativeThreshold(forSpeechSeconds: seconds)
            XCTAssertLessThan(value, previous)
            previous = value
        }
        XCTAssertEqual(previous, policy.negativeSpeechThreshold, accuracy: 1e-6)

        // And never rising anywhere, including the clamped ends.
        var last = Float.greatestFiniteMagnitude
        for step in 0...120 {
            let value = policy.negativeThreshold(forSpeechSeconds: Double(step) * 0.25)
            XCTAssertLessThanOrEqual(value, last)
            last = value
        }
    }

    func testADegeneratePolicyStillReturnsAUsableThreshold() {
        // Nothing stops a caller from editing the window shut; the ramp has
        // no span to interpolate over and must not divide by zero.
        var policy = SpeechChunkPolicy()
        policy.targetChunkSeconds = policy.minChunkSeconds
        for seconds in [0.0, 3.0, 20.0, 600.0] {
            let value = policy.negativeThreshold(forSpeechSeconds: seconds)
            XCTAssertEqual(value, policy.negativeSpeechThreshold, accuracy: 1e-6)
            XCTAssertFalse(value.isNaN)
        }
    }
}
