// VoiceCleanupTests.swift
// PRISMTests
//
// Microphone cleanup (§5.15): the promise that Off is bit-exact
// pass-through, the latency budget, each stage of the chain on synthetic
// signals, headroom, and the forward-compatibility contract the settings
// inherit from every other persisted struct in this app.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class VoiceCleanupTests: XCTestCase {

    // MARK: - Helpers

    private func sine(frequency: Double, seconds: Double,
                      amplitude: Float = 0.3) -> [Float] {
        let count = Int(seconds * VoiceCleanup.sampleRate)
        let step: Double = 2 * Double.pi * frequency / VoiceCleanup.sampleRate
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = amplitude * Float(sin(step * Double(i)))
        }
        return samples
    }

    /// Deterministic pseudo-noise; a fixed LCG so a failure is reproducible.
    private func noise(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * VoiceCleanup.sampleRate)
        var seed: UInt64 = 0x5EED_1234
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(Double(seed >> 40) / Double(1 << 24)) * 2 - 1
            samples[i] = unit * amplitude
        }
        return samples
    }

    /// Runs samples through a fresh chain in RT-sized slices.
    private func process(_ samples: [Float], mode: VoiceCleanupMode,
                         channels: Int = 1) -> [Float] {
        let cleanup = VoiceCleanup()
        var settings = VoiceCleanupSettings()
        settings.mode = mode
        cleanup.apply(settings)
        var output = samples
        let sliceFrames = 256
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            let totalFrames = buffer.count / channels
            while offset < totalFrames {
                let frames = min(sliceFrames, totalFrames - offset)
                if channels == 1 {
                    cleanup.processMono(base + offset, frameCount: frames)
                } else {
                    cleanup.processStereoInterleaved(base + offset * channels,
                                                     frameCount: frames)
                }
                offset += frames
            }
        }
        return output
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    // MARK: - Off is off

    /// The load-bearing promise: PRISM owns the microphone whether or not
    /// you asked it to process anything, so the default must not touch a
    /// single sample.
    func testOffIsBitExactPassThrough() {
        let tone = sine(frequency: 220, seconds: 0.2)
        XCTAssertEqual(process(tone, mode: .off), tone)
    }

    func testOffIsBitExactPassThroughInStereo() {
        var stereo = [Float](repeating: 0, count: 9600 * 2)
        for i in 0..<9600 {
            stereo[i * 2] = Float(sin(Double(i) * 0.01)) * 0.4
            stereo[i * 2 + 1] = Float(sin(Double(i) * 0.013)) * 0.2
        }
        XCTAssertEqual(process(stereo, mode: .off, channels: 2), stereo)
    }

    func testDefaultModeIsOff() {
        XCTAssertEqual(VoiceCleanupSettings().mode, .off)
        XCTAssertFalse(VoiceCleanupSettings().isActive)
        XCTAssertFalse(VoiceCleanup.program(for: .off).active)
    }

    func testEveryOtherModeActuallyDoesSomething() {
        for mode in VoiceCleanupMode.allCases where mode != .off {
            XCTAssertTrue(VoiceCleanup.program(for: mode).active,
                          "\(mode) must do something")
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.blurb.isEmpty)
        }
        let names = VoiceCleanupMode.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    // MARK: - Latency

    /// §6 allows 12 ms of added audio and the HAL buffer plus the ring
    /// already spend ~10.7 ms of it. There is no room for lookahead, so
    /// there must not be any.
    func testCleanupCostsNoLatencyInAnyMode() {
        let cleanup = VoiceCleanup()
        for mode in VoiceCleanupMode.allCases {
            var settings = VoiceCleanupSettings()
            settings.mode = mode
            cleanup.apply(settings)
            XCTAssertEqual(cleanup.reportedLatencyMs, 0,
                           "\(mode) must not buy latency")
        }
    }

    // MARK: - The chain

    /// Two tones of identical level, one under the voice and one in it. The
    /// comparison is between them rather than against the input, because the
    /// compressor deliberately moves loud and quiet material by different
    /// amounts and would muddy an absolute figure.
    func testRumbleIsRemovedAndTheVoiceBandIsNot() {
        let rumble = sine(frequency: 35, seconds: 3, amplitude: 0.15)
        let voice = sine(frequency: 220, seconds: 3, amplitude: 0.15)
        let rumbleOut = rms(process(rumble, mode: .cleanUp).suffix(24_000))
        let voiceOut = rms(process(voice, mode: .cleanUp).suffix(24_000))
        XCTAssertLessThan(rumbleOut, voiceOut * 0.25, "35 Hz is not a voice")
        XCTAssertGreaterThan(voiceOut, rms(voice.suffix(24_000)) * 0.5, "220 Hz is")
    }

    /// Steady low-level noise is what the floor tracker exists to learn;
    /// after a few seconds of it the expander should have pulled it down.
    func testSteadyRoomNoiseIsExpandedAway() {
        let hiss = noise(seconds: 8, amplitude: 0.004)
        for mode: VoiceCleanupMode in [.cleanUp, .studio] {
            let out = process(hiss, mode: mode)
            let before = rms(hiss.prefix(24_000))
            let after = rms(out.suffix(24_000))
            XCTAssertLessThan(after, before * 0.5,
                              "\(mode) left the room noise where it was")
        }
    }

    /// …and speech over the same floor must survive it. A denoiser that
    /// also removes the voice is a mute with extra steps.
    func testSpeechLevelSignalSurvivesTheExpander() {
        var signal = noise(seconds: 8, amplitude: 0.004)
        let voice = sine(frequency: 220, seconds: 4, amplitude: 0.12)
        // Four seconds of room, then talking over it.
        for i in 0..<voice.count {
            signal[192_000 + i] += voice[i]
        }
        let out = process(signal, mode: .studio)
        XCTAssertGreaterThan(rms(out.suffix(48_000)),
                             rms(signal.suffix(48_000)) * 0.5,
                             "the expander closed on a talking voice")
    }

    /// Gentle compression means the loud passages move less than the quiet
    /// ones — that is the entire claim, and it is testable without ears.
    func testCompressionNarrowsTheDynamicRange() {
        let quiet = sine(frequency: 220, seconds: 2, amplitude: 0.05)
        let loud = sine(frequency: 220, seconds: 2, amplitude: 0.5)
        let inputRatio = Double(rms(loud.suffix(24_000)) / rms(quiet.suffix(24_000)))
        for mode: VoiceCleanupMode in [.cleanUp, .studio] {
            let quietOut = rms(process(quiet, mode: mode).suffix(24_000))
            let loudOut = rms(process(loud, mode: mode).suffix(24_000))
            let outputRatio = Double(loudOut / quietOut)
            XCTAssertLessThan(outputRatio, inputRatio * 0.9,
                              "\(mode) is not compressing")
            XCTAssertGreaterThan(outputRatio, 1,
                                 "\(mode) inverted the dynamics")
        }
    }

    /// Studio is the mode that admits to changing what you sound like; Clean
    /// up is the mode that promises not to.
    func testOnlyStudioAddsEQ() {
        XCTAssertFalse(VoiceCleanup.program(for: .cleanUp).eqOn)
        XCTAssertTrue(VoiceCleanup.program(for: .studio).eqOn)
    }

    func testStudioLiftsPresenceRelativeToCleanUp() {
        let presence = sine(frequency: 6000, seconds: 2, amplitude: 0.2)
        let clean = rms(process(presence, mode: .cleanUp).suffix(24_000))
        let studio = rms(process(presence, mode: .studio).suffix(24_000))
        XCTAssertGreaterThan(studio, clean, "the shelf is not doing anything")
    }

    // MARK: - Safety

    func testEveryModeStaysBoundedOnALoudInput() {
        let loud = sine(frequency: 180, seconds: 1, amplitude: 0.99)
        for mode in VoiceCleanupMode.allCases {
            let out = process(loud, mode: mode)
            XCTAssertTrue(out.allSatisfy { $0.isFinite && abs($0) <= 1 },
                          "\(mode) must never emit a runaway sample")
        }
    }

    /// The chain ends in a hard clamp for runaway samples; no mode may
    /// *rely* on it, or a loud talker turns into flat-topped distortion.
    func testNoModeReliesOnTheSafetyClampForHeadroom() {
        for mode in VoiceCleanupMode.allCases {
            XCTAssertLessThanOrEqual(VoiceCleanup.peakGainAtFullScale(mode), 1,
                                     "\(mode) can drive full-scale input into the clamp")
        }
    }

    func testNonFiniteInputIsSwallowedRatherThanPropagated() {
        var samples = [Float](repeating: 0.2, count: 4096)
        samples[100] = .nan
        samples[200] = .infinity
        let out = process(samples, mode: .studio)
        XCTAssertTrue(out.allSatisfy { $0.isFinite },
                      "a NaN must not colonise the followers")
    }

    /// Resuming from a mute must not gate against a floor learned in a room
    /// that may no longer be there, nor open onto a frozen envelope.
    func testResetReopensTheChain() {
        let cleanup = VoiceCleanup()
        var settings = VoiceCleanupSettings()
        settings.mode = .studio
        cleanup.apply(settings)
        var hiss = noise(seconds: 6, amplitude: 0.004)
        hiss.withUnsafeMutableBufferPointer {
            cleanup.processMono($0.baseAddress!, frameCount: $0.count)
        }
        cleanup.reset()
        // Straight into speech: with the gate reset open, the first word
        // arrives rather than being learned about.
        var voice = sine(frequency: 220, seconds: 0.05, amplitude: 0.15)
        voice.withUnsafeMutableBufferPointer {
            cleanup.processMono($0.baseAddress!, frameCount: $0.count)
        }
        XCTAssertGreaterThan(rms(voice[480..<voice.count]), 0.05,
                             "a reset chain swallowed the first word")
    }

    // MARK: - Settings and forward compatibility

    func testCleanupSettingsRoundTripThroughJSON() throws {
        var settings = StudioSettings()
        settings.cleanup.mode = .studio
        settings.micWatch.showsBanner = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(StudioSettings.self, from: data),
                       settings)
    }

    /// A studio file written before cleanup existed.
    func testStudioSettingsFromBeforeCleanupStillDecodes() throws {
        let json = Data(#"{"voice":{"effect":"alien"},"lag":{"delayMs":1500}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertEqual(decoded.voice.effect, .alien)
        XCTAssertEqual(decoded.lag.delayMs, 1500)
        XCTAssertEqual(decoded.cleanup, VoiceCleanupSettings(),
                       "the new section takes its defaults")
        XCTAssertEqual(decoded.micWatch, MicWatchSettings())
    }

    /// A mode name from a future build must not take the rest of the user's
    /// studio file with it — and must land on Off, never on something that
    /// silently starts processing.
    func testUnknownCleanupModeFallsBackToOffWithoutDiscardingTheRest() throws {
        let json = Data(#"{"cleanup":{"mode":"neuralmagic"},"micWatch":{"showsBanner":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertEqual(decoded.cleanup.mode, .off)
        XCTAssertTrue(decoded.micWatch.showsBanner)
    }

    func testPartialCleanupObjectKeepsTheFieldsItHas() throws {
        let json = Data(#"{"cleanup":{},"micWatch":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertEqual(decoded.cleanup.mode, .off)
        XCTAssertFalse(decoded.micWatch.showsBanner,
                       "the banner is opt-in, absent means off")
    }
}
