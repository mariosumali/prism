// VoiceChangerTests.swift
// PRISMTests
//
// The voice changer (§5.13): the effect table's sanity, the pitch detector
// and chromatic snap, the DSP chain end to end on synthetic signals, and the
// forward-compatibility contract VoiceSettings inherits from every other
// persisted struct in this app.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class VoiceChangerTests: XCTestCase {

    // MARK: - Helpers

    private func sine(frequency: Double, seconds: Double,
                      sampleRate: Double = VoiceChanger.sampleRate,
                      amplitude: Float = 0.5) -> [Float] {
        let count = Int(seconds * sampleRate)
        let step: Double = 2 * Double.pi * frequency / sampleRate
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let phase: Double = step * Double(i)
            samples[i] = amplitude * Float(sin(phase))
        }
        return samples
    }

    /// Runs samples through a fresh VoiceChanger in RT-sized slices and
    /// returns the processed signal.
    private func process(_ samples: [Float], effect: VoiceEffect,
                         amount: Double = 1) -> [Float] {
        let changer = VoiceChanger()
        var settings = VoiceSettings()
        settings.effect = effect
        settings.amount = amount
        changer.apply(settings)
        var output = samples
        let slice = 512
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let frames = min(slice, buffer.count - offset)
                changer.processMono(base + offset, frameCount: frames)
                offset += frames
            }
        }
        return output
    }

    /// Detected fundamental of the tail of a 48 kHz signal, via the same
    /// detector the autotune path trusts (on a ×4-decimated window).
    private func dominantFrequency(of samples: [Float]) -> Double {
        var decimated: [Float] = []
        decimated.reserveCapacity(samples.count / 4)
        var i = 0
        while i + 3 < samples.count {
            let sum: Float = samples[i] + samples[i + 1] + samples[i + 2] + samples[i + 3]
            decimated.append(sum * 0.25)
            i += 4
        }
        let window = 512
        guard decimated.count >= window else { return 0 }
        let tail = Array(decimated.suffix(window))
        var scratch = [Float](repeating: 0,
                              count: VoiceChanger.maxLagFrames
                                  - VoiceChanger.minLagFrames + 1)
        return tail.withUnsafeBufferPointer { samplesPtr in
            scratch.withUnsafeMutableBufferPointer { scratchPtr in
                VoiceChanger.detectFrequency(in: samplesPtr.baseAddress!,
                                             count: window,
                                             sampleRate: VoiceChanger.detectSampleRate,
                                             scratch: scratchPtr.baseAddress!)
            }
        }
    }

    // MARK: - Effect table

    func testThereIsAProperBunchOfEffects() {
        XCTAssertGreaterThanOrEqual(VoiceEffect.allCases.count, 11,
                                    "off plus at least ten voices")
        XCTAssertTrue(VoiceEffect.allCases.contains(.off))
    }

    func testEveryEffectHasDistinctCopy() {
        let names = VoiceEffect.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        for effect in VoiceEffect.allCases {
            XCTAssertFalse(effect.displayName.isEmpty)
            XCTAssertFalse(effect.blurb.isEmpty)
        }
    }

    func testOffIsIdentityAndEverythingElseIsNot() {
        XCTAssertFalse(VoiceChanger.program(for: .off, amount: 1).active)
        for effect in VoiceEffect.allCases where effect != .off {
            XCTAssertTrue(VoiceChanger.program(for: effect, amount: 1).active,
                          "\(effect) must do something")
        }
    }

    /// The grain shifter degrades fast outside these ratios, and the autotune
    /// clamp assumes them.
    func testPitchRatiosStayInsideTheShiftersComfortZone() {
        for effect in VoiceEffect.allCases {
            let program = VoiceChanger.program(for: effect, amount: 1)
            XCTAssertGreaterThanOrEqual(program.pitchRatio, 0.5)
            XCTAssertLessThanOrEqual(program.pitchRatio, 2.0)
        }
    }

    /// Feedback at or above 1 is a self-oscillating echo — a ring shared
    /// with coreaudiod is the wrong place to discover that.
    func testEchoFeedbackIsAlwaysStable() {
        for effect in VoiceEffect.allCases {
            let program = VoiceChanger.program(for: effect, amount: 1)
            XCTAssertLessThan(abs(program.echoFeedback), 0.9)
        }
    }

    func testRobotIsAFixedNoteAndAutotuneIsChromatic() {
        let robot = VoiceChanger.program(for: .robot, amount: 1)
        XCTAssertEqual(robot.autotune, .fixedNote)
        XCTAssertGreaterThan(robot.autotuneTargetHz, 0)
        XCTAssertTrue(robot.usesPitch)
        let autotune = VoiceChanger.program(for: .autotune, amount: 1)
        XCTAssertEqual(autotune.autotune, .chromatic)
        XCTAssertTrue(autotune.usesPitch)
    }

    /// Amount pulls the effect toward identity rather than toward silence.
    func testAmountScalesPitchTowardIdentity() {
        let full = VoiceChanger.program(for: .chipmunk, amount: 1)
        let quarter = VoiceChanger.program(for: .chipmunk, amount: 0.25)
        XCTAssertGreaterThan(full.pitchRatio, quarter.pitchRatio)
        XCTAssertGreaterThan(quarter.pitchRatio, 1)
    }

    /// Filter-only effects must not pay the pitch grains' ~21 ms.
    func testOnlyPitchedEffectsReportGrainLatency() {
        let changer = VoiceChanger()
        var settings = VoiceSettings()

        settings.effect = .chipmunk
        changer.apply(settings)
        XCTAssertEqual(changer.reportedLatencyMs, 2048.0 / 2 / 48_000 * 1000,
                       accuracy: 1e-9)

        settings.effect = .telephone
        changer.apply(settings)
        XCTAssertEqual(changer.reportedLatencyMs, 0)

        settings.effect = .off
        changer.apply(settings)
        XCTAssertEqual(changer.reportedLatencyMs, 0)
    }

    // MARK: - Pitch detection

    func testDetectorFindsASine() {
        let tone = sine(frequency: 220, seconds: 0.5,
                        sampleRate: VoiceChanger.detectSampleRate)
        var scratch = [Float](repeating: 0, count: 200)
        let detected = tone.withUnsafeBufferPointer { ptr in
            scratch.withUnsafeMutableBufferPointer { s in
                VoiceChanger.detectFrequency(in: ptr.baseAddress!,
                                             count: 512,
                                             sampleRate: VoiceChanger.detectSampleRate,
                                             scratch: s.baseAddress!)
            }
        }
        XCTAssertEqual(detected, 220, accuracy: 4)
    }

    func testDetectorReportsSilenceAsUnvoiced() {
        let silence = [Float](repeating: 0, count: 512)
        var scratch = [Float](repeating: 0, count: 200)
        let detected = silence.withUnsafeBufferPointer { ptr in
            scratch.withUnsafeMutableBufferPointer { s in
                VoiceChanger.detectFrequency(in: ptr.baseAddress!,
                                             count: 512,
                                             sampleRate: VoiceChanger.detectSampleRate,
                                             scratch: s.baseAddress!)
            }
        }
        XCTAssertEqual(detected, 0, "breath and silence must not autotune")
    }

    func testChromaticTargetSnapsToTheNearestSemitone() {
        // 225 Hz sits between A3 (220) and A♯3 (233.08); A3 is nearer.
        XCTAssertEqual(VoiceChanger.chromaticTarget(225), 220, accuracy: 0.01)
        // Exactly on a note stays put.
        XCTAssertEqual(VoiceChanger.chromaticTarget(440), 440, accuracy: 1e-9)
        XCTAssertEqual(VoiceChanger.chromaticTarget(0), 0)
    }

    // MARK: - The chain, end to end

    func testOffPassesSamplesThroughUntouched() {
        let tone = sine(frequency: 220, seconds: 0.1)
        XCTAssertEqual(process(tone, effect: .off), tone,
                       "off must be bit-exact pass-through")
    }

    func testChipmunkShiftsPitchUpByItsRatio() {
        let tone = sine(frequency: 220, seconds: 0.6)
        let shifted = process(tone, effect: .chipmunk)
        let expected = 220 * Double(VoiceChanger.program(for: .chipmunk,
                                                         amount: 1).pitchRatio)
        let detected = dominantFrequency(of: Array(shifted.suffix(14_400)))
        XCTAssertEqual(detected, expected, accuracy: expected * 0.05)
    }

    func testDeepShiftsPitchDown() {
        let tone = sine(frequency: 220, seconds: 0.6)
        let shifted = process(tone, effect: .deep)
        let expected = 220 * Double(VoiceChanger.program(for: .deep,
                                                         amount: 1).pitchRatio)
        let detected = dominantFrequency(of: Array(shifted.suffix(14_400)))
        XCTAssertEqual(detected, expected, accuracy: expected * 0.05)
    }

    /// 225 Hz is a flat A3; hard-snap autotune must land it on 220.
    func testAutotunePullsAFlatNoteOntoTheScale() {
        let tone = sine(frequency: 225, seconds: 1.2)
        let tuned = process(tone, effect: .autotune)
        let detected = dominantFrequency(of: Array(tuned.suffix(14_400)))
        XCTAssertEqual(detected, 220, accuracy: 220 * 0.03)
    }

    func testCaveEchoesAnImpulseAtItsProgrammedDelay() {
        let program = VoiceChanger.program(for: .cave, amount: 1)
        var impulse = [Float](repeating: 0, count: program.echoDelayFrames + 1000)
        impulse[0] = 0.8
        let output = process(impulse, effect: .cave)
        // The dry impulse is attenuated by (1 − mix) and the output gain…
        XCTAssertEqual(output[0],
                       0.8 * (1 - program.echoMix) * program.outputGain,
                       accuracy: 0.01)
        // …and its first repeat arrives exactly one delay later, at mix gain.
        XCTAssertEqual(output[program.echoDelayFrames],
                       0.8 * program.echoMix * program.outputGain,
                       accuracy: 0.02)
    }

    func testUnderwaterDrownsTheTreble() {
        let low = sine(frequency: 220, seconds: 0.5)
        let high = sine(frequency: 4000, seconds: 0.5)
        func rms(_ samples: ArraySlice<Float>) -> Float {
            sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        }
        let lowOut = rms(process(low, effect: .underwater).suffix(12_000))
        let highOut = rms(process(high, effect: .underwater).suffix(12_000))
        let inRMS = rms(low.suffix(12_000))
        XCTAssertGreaterThan(lowOut, inRMS * 0.4, "voice band survives")
        XCTAssertLessThan(highOut, inRMS * 0.1, "treble does not")
    }

    func testEveryEffectStaysBoundedOnALoudInput() {
        let loud = sine(frequency: 180, seconds: 0.4, amplitude: 0.99)
        for effect in VoiceEffect.allCases {
            let output = process(loud, effect: effect)
            XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 },
                          "\(effect) must never emit a runaway sample")
        }
    }

    /// The chain ends in a hard safety clamp for runaway samples; no program
    /// may *rely* on it, or hot input turns into flat-topped distortion.
    /// Worst-case steady-state gain of the undriven programs is
    /// outputGain × ((1 − mix) + mix / (1 − feedback)); the tanh-driven ones
    /// are bounded to |x| ≤ 1 before their gain by construction.
    func testNoProgramReliesOnTheSafetyClampForHeadroom() {
        for effect in VoiceEffect.allCases where effect != .off {
            let p = VoiceChanger.program(for: effect, amount: 1)
            guard p.drive == 0 else {
                XCTAssertLessThanOrEqual(p.outputGain, 1,
                                         "\(effect): tanh bounds to 1; gain must not undo that")
                continue
            }
            let echoGain = p.echoMix > 0
                ? (1 - p.echoMix) + p.echoMix / (1 - p.echoFeedback)
                : 1
            XCTAssertLessThanOrEqual(Double(p.outputGain * echoGain), 1 + 1e-6,
                                     "\(effect) can drive hot input into the clamp")
        }
    }

    /// Switching an effect on must not open with the echo tail of whatever
    /// was processed before it was switched off — off → on is an acoustic
    /// boundary and the RT path clears its state there.
    func testReenablingAnEffectDoesNotReplayTheOldTail() {
        let changer = VoiceChanger()
        var settings = VoiceSettings()
        settings.effect = .cave
        changer.apply(settings)
        var impulse = [Float](repeating: 0, count: 4096)
        impulse[0] = 1
        impulse.withUnsafeMutableBufferPointer {
            changer.processMono($0.baseAddress!, frameCount: $0.count)
        }
        settings.effect = .off
        changer.apply(settings)
        var bypassed = [Float](repeating: 0, count: 512)
        bypassed.withUnsafeMutableBufferPointer {
            changer.processMono($0.baseAddress!, frameCount: $0.count)
        }
        settings.effect = .cave
        changer.apply(settings)
        var silence = [Float](repeating: 0, count: 24_000)
        silence.withUnsafeMutableBufferPointer {
            changer.processMono($0.baseAddress!, frameCount: $0.count)
        }
        XCTAssertTrue(silence.allSatisfy { $0 == 0 },
                      "the old room must not echo into the re-enabled effect")
    }

    func testResetSilencesEveryTail() {
        let changer = VoiceChanger()
        var settings = VoiceSettings()
        settings.effect = .cave
        changer.apply(settings)
        var impulse = [Float](repeating: 0, count: 4096)
        impulse[0] = 1
        impulse.withUnsafeMutableBufferPointer {
            changer.processMono($0.baseAddress!, frameCount: $0.count)
        }
        changer.reset()
        var silence = [Float](repeating: 0, count: 24_000)
        silence.withUnsafeMutableBufferPointer {
            changer.processMono($0.baseAddress!, frameCount: $0.count)
        }
        XCTAssertTrue(silence.allSatisfy { $0 == 0 },
                      "a reset delay line must not replay the old room")
    }

    // MARK: - Settings

    func testVoiceIsOffByDefault() {
        XCTAssertEqual(VoiceSettings().effect, .off)
        XCTAssertFalse(VoiceSettings().isActive)
    }

    func testAmountClampsAwayFromTheInertZero() {
        var voice = VoiceSettings()
        voice.amount = 0
        XCTAssertEqual(voice.clampedAmount, 0.25)
        voice.amount = 7
        XCTAssertEqual(voice.clampedAmount, 1)
    }

    /// The ⌥⌘V toggle recalls the last voice; recalling "off" would be a
    /// switch wired to nothing.
    func testRecallEffectIsNeverOff() {
        var voice = VoiceSettings()
        XCTAssertNotEqual(voice.recallEffect, .off)
        voice.lastUsedEffect = .off        // hostile persisted state
        XCTAssertNotEqual(voice.recallEffect, .off)
        voice.lastUsedEffect = .alien
        XCTAssertEqual(voice.recallEffect, .alien)
    }

    // MARK: - Forward compatibility

    func testVoiceSettingsRoundTripThroughJSON() throws {
        var settings = StudioSettings()
        settings.voice.effect = .alien
        settings.voice.lastUsedEffect = .alien
        settings.voice.amount = 0.5
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    /// A studio file written before the voice changer existed.
    func testStudioSettingsFromBeforeTheVoiceChangerStillDecodes() throws {
        let json = Data(#"{"replay":{"isArmed":true},"lag":{"delayMs":1500}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertTrue(decoded.replay.isArmed)
        XCTAssertEqual(decoded.lag.delayMs, 1500)
        XCTAssertEqual(decoded.voice, VoiceSettings(),
                       "the new section takes its defaults")
    }

    func testPartialVoiceObjectKeepsTheFieldsItHas() throws {
        let json = Data(#"{"voice":{"effect":"alien"}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertEqual(decoded.voice.effect, .alien)
        XCTAssertEqual(decoded.voice.amount, 1, "absent field takes its default")
    }

    /// An effect name from a future build (or a rename) must not take the
    /// user's whole voice configuration with it.
    func testUnknownEffectNameFallsBackWithoutDiscardingTheRest() throws {
        let json = Data(#"{"voice":{"effect":"kazoo","amount":0.5}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertEqual(decoded.voice.effect, .off)
        XCTAssertEqual(decoded.voice.amount, 0.5)
    }
}
