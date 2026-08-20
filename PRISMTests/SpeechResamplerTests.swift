// SpeechResamplerTests.swift
// PRISMTests
//
// The 48 → 16 kHz front end that every recogniser call passes through
// (§5.32).
//
// This file exists because of one specific future edit. The ratio is exactly
// 3:1, the anti-alias filter is four lines of arithmetic that appear to do
// nothing, and someone profiling the transcript path will eventually notice
// that deleting those four lines makes the resampler three times faster and
// changes nothing they can hear. It does not change anything they can hear.
// It changes what the model reads: everything from 8 kHz to 24 kHz folds
// down onto the speech band, and the recogniser starts inventing words out
// of sibilance and fan noise. `testTwelveKilohertzIsCrushedBecauseOtherwise…`
// is the test that stops that edit, and it carries an unfiltered control so
// the number it asserts cannot be dismissed as arbitrary.
//
// The other class of bug here is per-call state. The resampler is fed ~100 ms
// at a time by a 10 Hz drain, so a filter or a phase counter that resets at a
// chunk boundary produces a step discontinuity ten times a second. That is
// inaudible in a waveform view, obvious in a spectrogram, and transcribed as
// words. Every count and continuity test below is really that one test.
//
// Measurements are RMS-based rather than peak-based wherever the aliased tone
// lands on a coarse sample grid: a 4 kHz tone at 16 kHz has four samples per
// cycle, so its peak *sample* depends on phase and can sit up to 3 dB under
// the true amplitude, while its RMS is exactly amplitude/√2 for any phase.
// Test lengths are whole numbers of cycles so that identity is exact.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class SpeechResamplerTests: XCTestCase {

    // MARK: - Fixtures

    private let inputRate = SpeechResampler.inputRate
    private let outputRate = SpeechResampler.outputRate

    /// One second of input, so every test frequency below divides into a
    /// whole number of cycles at both rates.
    private let oneSecond = 48_000
    /// 0.1 s of output discarded as filter warm-up. The 4th-order transient
    /// is gone within a few dozen samples; this is generous on purpose.
    private let warmUp = 1_600
    /// 0.9 s of output measured, which is a whole number of cycles for every
    /// tone used here and is divisible by four.
    private let window = 14_400

    private func sine(_ hz: Double, amplitude: Double = 0.5,
                      frames: Int, rate: Double? = nil) -> [Float] {
        let sampleRate = rate ?? inputRate
        return (0..<frames).map {
            Float(amplitude * sin(2 * Double.pi * hz * Double($0) / sampleRate))
        }
    }

    /// Amplitude of a single tone, recovered from its RMS. Phase-independent
    /// and exact for a whole number of cycles.
    private func amplitude(of samples: [Float], skipping skip: Int,
                           count: Int) -> Double {
        SpeechLevel.rms(Array(samples[skip..<(skip + count)])) * 2.0.squareRoot()
    }

    private func attenuationDb(input: Double, output: Double) -> Double {
        -20 * log10(max(output, 1e-30) / input)
    }

    /// What the naive implementation does: keep every third sample, no
    /// filter. Used as the control in the stopband test.
    private func naivelyDecimated(_ input: [Float]) -> [Float] {
        stride(from: 0, to: input.count, by: SpeechResampler.decimation).map { input[$0] }
    }

    // MARK: - Rate

    func testOutputIsOneThirdOfTheInputForEveryLength() {
        // Lengths that divide by three and lengths that do not; the ragged
        // ones are the realistic case, since a capture chunk is however many
        // frames the tap happened to hold.
        for frames in [0, 1, 2, 3, 4, 7, 100, 101, 999, 1000, 4_800, 48_000] {
            let resampler = SpeechResampler()
            var out: [Float] = []
            let returned = resampler.append([Float](repeating: 0, count: frames),
                                            into: &out)
            XCTAssertEqual(returned, out.count,
                           "return value must equal what was appended")
            let expected = Double(frames) / 3
            XCTAssertLessThanOrEqual(abs(Double(out.count) - expected), 2,
                                     "\(frames) frames produced \(out.count) samples")
        }
    }

    func testTheOutputRateIsExactlyAThirdOfTheInputRate() {
        // The whole design rests on this being an integer. If either constant
        // ever moves, the decimator is the wrong algorithm, not a tuning
        // problem.
        XCTAssertEqual(inputRate / outputRate, Double(SpeechResampler.decimation),
                       accuracy: 1e-12)
    }

    // MARK: - Continuity across calls

    func testSplittingTheInputAcrossCallsChangesNothing() {
        let first = sine(440, frames: 100)
        let second = sine(440, frames: 100)

        let split = SpeechResampler()
        var splitOut: [Float] = []
        split.append(first, into: &splitOut)
        split.append(second, into: &splitOut)

        let single = SpeechResampler()
        var singleOut: [Float] = []
        single.append(first + second, into: &singleOut)

        // Same count is the weak claim the phase counter defends...
        XCTAssertEqual(splitOut.count, singleOut.count)
        // ...and bit-identity is the strong one, which also covers the filter
        // state. Splitting the input changes nothing about the order of the
        // arithmetic, so anything less than equality is a reset somewhere.
        XCTAssertEqual(splitOut, singleOut)
    }

    func testRaggedChunkBoundariesAddNothingToTheSignal() {
        // Realistic chunk sizes: a capture drain hands over however many
        // frames the tap happened to hold, which is never a round number and
        // is occasionally one. Feed a loud tone and then silence, once in
        // ragged chunks and once whole. State that resets at a boundary makes
        // the two differ, and the difference is a step discontinuity ten
        // times a second.
        let leadIn = sine(1_000, amplitude: 0.9, frames: 4_800)
        let chunks = [37, 512, 1, 1_024, 100, 3]
        let total = chunks.reduce(0, +)

        let ragged = SpeechResampler()
        var raggedOut: [Float] = []
        ragged.append(leadIn, into: &raggedOut)
        raggedOut.removeAll()
        for chunk in chunks {
            ragged.append([Float](repeating: 0, count: chunk), into: &raggedOut)
        }

        let whole = SpeechResampler()
        var wholeOut: [Float] = []
        whole.append(leadIn, into: &wholeOut)
        wholeOut.removeAll()
        whole.append([Float](repeating: 0, count: total), into: &wholeOut)

        XCTAssertEqual(raggedOut, wholeOut)

        // The ring-down itself is not a defect and this test does not treat
        // it as one: the first output sample after the tone stops is still
        // 0.3, because a 4th-order filter carries energy. What matters is
        // that it decays to nothing instead of settling on an offset.
        for sample in raggedOut.suffix(200) {
            XCTAssertLessThan(abs(sample), 1e-6)
        }
    }

    func testAppendAddsToTheDestinationRatherThanReplacingIt() {
        // Callers reuse one buffer across a whole take; an implementation
        // that cleared it would silently transcribe only the last 100 ms.
        let resampler = SpeechResampler()
        var out: [Float] = [-1, -2, -3]
        let appended = resampler.append([Float](repeating: 0.25, count: 300),
                                        into: &out)
        XCTAssertEqual(out.count, 3 + appended)
        XCTAssertEqual(Array(out.prefix(3)), [-1, -2, -3])
    }

    func testThePointerAndArrayEntryPointsAgree() {
        let input = sine(2_000, frames: 3_000)

        let viaArray = SpeechResampler()
        var arrayOut: [Float] = []
        viaArray.append(input, into: &arrayOut)

        let viaPointer = SpeechResampler()
        var pointerOut: [Float] = []
        input.withUnsafeBufferPointer { buffer -> Void in
            viaPointer.append(buffer.baseAddress!, frameCount: buffer.count,
                              into: &pointerOut)
        }
        XCTAssertEqual(arrayOut, pointerOut)
    }

    // MARK: - Passband

    func testDirectCurrentPassesThroughUnchanged() {
        // The RBJ low-pass has unity DC gain by construction — its numerator
        // and denominator coefficients sum to the same value — so a constant
        // must come out as itself once the transient has settled. Anything
        // else means the coefficients have been normalised wrongly, which
        // would show up on speech as a level change nobody could explain.
        let resampler = SpeechResampler()
        var out: [Float] = []
        resampler.append([Float](repeating: 0.5, count: 4_800), into: &out)
        for sample in out.suffix(100) {
            XCTAssertEqual(Double(sample), 0.5, accuracy: 1e-4)
        }
    }

    func testOneKilohertzSurvivesTheFilterIntact() {
        // 1 kHz is where the voice is. A filter that costs anything
        // measurable here is a filter that has been mistuned down into the
        // band it exists to protect.
        let resampler = SpeechResampler()
        var out: [Float] = []
        resampler.append(sine(1_000, amplitude: 0.5, frames: oneSecond), into: &out)

        let peak = out[warmUp..<(warmUp + window)].reduce(Float(0)) { max($0, abs($1)) }
        let peakDb = 20 * log10(Double(peak) / 0.5)
        XCTAssertEqual(peakDb, 0, accuracy: 0.5)

        // The peak sample undershoots the true peak slightly because 16 kHz
        // gives only sixteen samples per cycle; the RMS estimate does not,
        // and it says the passband is flat to within a millionth of a dB.
        let recovered = amplitude(of: out, skipping: warmUp, count: window)
        XCTAssertEqual(20 * log10(recovered / 0.5), 0, accuracy: 0.05)
    }

    // MARK: - Stopband

    func testTwelveKilohertzIsCrushedBecauseOtherwiseItAliasesOntoSpeech() {
        // THIS IS THE LOAD-BEARING TEST. It is the reason the two biquads
        // exist, and the reason deleting them for speed is not a free win.
        //
        // 12 kHz cannot be represented at 16 kHz. Decimation folds it to
        // |12000 − 16000| = 4 kHz, which is on top of the consonants. The
        // control below shows what naive decimation does with it: nothing at
        // all — full amplitude, straight into the band.
        let input = sine(12_000, amplitude: 0.5, frames: oneSecond)

        let control = naivelyDecimated(input)
        let controlAmplitude = amplitude(of: control, skipping: warmUp, count: window)
        XCTAssertEqual(attenuationDb(input: 0.5, output: controlAmplitude), 0,
                       accuracy: 0.1,
                       "naive decimation passes 12 kHz at full amplitude")

        let resampler = SpeechResampler()
        var out: [Float] = []
        resampler.append(input, into: &out)
        let attenuation = attenuationDb(
            input: 0.5,
            output: amplitude(of: out, skipping: warmUp, count: window))

        // 23.4 dB, not the 40 dB that a first reading of the spec suggests.
        // A 4th-order Butterworth at 7200 Hz cannot deliver 40 dB here:
        // 10·log10(1 + (tan(π·12000/48000) / tan(π·7200/48000))^8) = 23.45,
        // and reaching 40 dB at 12 kHz would take a 7th-order filter or a
        // 4.7 kHz cutoff that throws away the top third of the band Whisper
        // was trained on. This test asserts the number the design actually
        // produces so that nobody has to re-derive it, and asserts it tightly
        // enough that changing the order, the cutoff or either Q will fail
        // here rather than quietly degrade transcription.
        XCTAssertGreaterThan(attenuation, 22)
        XCTAssertEqual(attenuation, 23.45, accuracy: 0.25)
    }

    func testTheUpperStopbandIsPastFortyDecibels() {
        // Above ~15.5 kHz the same filter is past 40 dB, and this is the part
        // of the spectrum that matters most: it folds onto the low vowels,
        // and it is where the voice changer's ring modulator and soft clipper
        // deposit their harmonics. 20 kHz folds to 4 kHz and arrives 69 dB
        // down — 10·log10(1 + (tan(π·20000/48000) / tan(π·7200/48000))^8).
        let resampler = SpeechResampler()
        var out: [Float] = []
        resampler.append(sine(20_000, amplitude: 0.5, frames: oneSecond), into: &out)
        let attenuation = attenuationDb(
            input: 0.5,
            output: amplitude(of: out, skipping: warmUp, count: window))
        XCTAssertGreaterThan(attenuation, 40)
    }

    func testTheTwoSectionsTogetherAreMinusThreeDecibelsAtCutoff() {
        // The Butterworth pole Qs multiply to 1/√2 at the corner. Editing one
        // Q without the other is the subtle version of removing the filter,
        // and it would pass every other test in this file.
        let product = SpeechResampler.sectionQ.0 * SpeechResampler.sectionQ.1
        XCTAssertEqual(20 * log10(product), -3.01, accuracy: 0.02)

        let resampler = SpeechResampler()
        var out: [Float] = []
        resampler.append(sine(SpeechResampler.cutoffHz, amplitude: 0.5,
                              frames: oneSecond), into: &out)
        let attenuation = attenuationDb(
            input: 0.5,
            output: amplitude(of: out, skipping: warmUp, count: window))
        XCTAssertEqual(attenuation, 3.01, accuracy: 0.2)
    }

    // MARK: - reset

    func testResetLeavesTheInstanceIndistinguishableFromANewOne() {
        let input = sine(700, amplitude: 0.8, frames: 1_500)

        let fresh = SpeechResampler()
        var freshOut: [Float] = []
        fresh.append(input, into: &freshOut)

        let reused = SpeechResampler()
        var scratch: [Float] = []
        // Something loud and at a different phase, so leftover state would be
        // obvious rather than marginal.
        reused.append(sine(3_100, amplitude: 1.0, frames: 2_003), into: &scratch)
        reused.reset()

        var reusedOut: [Float] = []
        reused.append(input, into: &reusedOut)
        XCTAssertEqual(reusedOut, freshOut)
    }

    // MARK: - SpeechLevel

    func testRmsOfSilenceIsZero() {
        XCTAssertEqual(SpeechLevel.rms([Float](repeating: 0, count: 4_800)), 0,
                       accuracy: 1e-12)
    }

    func testRmsOfNothingIsZeroRatherThanNotANumber() {
        // An empty block reaches this from a starved tap, and a NaN threshold
        // comparison is false in both directions — the gate would neither
        // open nor close.
        let empty = SpeechLevel.rms([])
        XCTAssertFalse(empty.isNaN)
        XCTAssertEqual(empty, 0)
    }

    func testRmsOfAFullScaleSquareWaveIsOne() {
        let square = (0..<4_800).map { Float($0 % 2 == 0 ? 1.0 : -1.0) }
        XCTAssertEqual(SpeechLevel.rms(square), 1.0, accuracy: 1e-6)
    }

    func testRmsOfASineIsItsAmplitudeOverRootTwo() {
        for amplitude in [0.1, 0.5, 1.0] {
            let wave = sine(1_000, amplitude: amplitude, frames: oneSecond)
            XCTAssertEqual(SpeechLevel.rms(wave), amplitude / 2.0.squareRoot(),
                           accuracy: 1e-6)
        }
    }

    func testRmsPointerAndArrayEntryPointsAgree() {
        let wave = sine(1_000, amplitude: 0.3, frames: 4_800)
        let viaArray = SpeechLevel.rms(wave)
        let viaPointer = wave.withUnsafeBufferPointer {
            SpeechLevel.rms($0.baseAddress!, count: $0.count)
        }
        XCTAssertEqual(viaArray, viaPointer, accuracy: 1e-15)
    }
}
