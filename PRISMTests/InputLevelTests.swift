// InputLevelTests.swift
// PRISMTests
//
// The always-on input meter (§5.17): the RT→main level mailbox's packing and
// window cadence, and the muted-and-talking watch's debounce — which is
// mostly a test that it does NOT fire, since the whole design problem is
// nagging.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class InputLevelTests: XCTestCase {

    // MARK: - Mailbox

    func testMailboxRoundTripsAValueAndItsSequence() {
        let mailbox = InputLevelMailbox()
        XCTAssertEqual(mailbox.reading.sequence, 0, "nothing published yet")
        mailbox.publish(rms: 0.25)
        var reading = mailbox.reading
        XCTAssertEqual(reading.rms, 0.25, accuracy: 1e-6)
        XCTAssertEqual(reading.sequence, 1)
        mailbox.publish(rms: 0.5)
        reading = mailbox.reading
        XCTAssertEqual(reading.rms, 0.5, accuracy: 1e-6)
        XCTAssertEqual(reading.sequence, 2, "the counter is how a reader "
                       + "tells a fresh window from a stale one")
    }

    /// The value and the counter share one atomic word precisely so a reader
    /// can never pair a new counter with an old level.
    func testMailboxPublishesOncePerFullWindow() {
        let mailbox = InputLevelMailbox()
        let half = [Float](repeating: 0.5, count: InputLevelMailbox.windowFrames / 2)
        half.withUnsafeBufferPointer {
            mailbox.accumulate($0.baseAddress!, frameCount: $0.count, channels: 1)
        }
        XCTAssertEqual(mailbox.reading.sequence, 0, "a part-filled window says nothing")
        half.withUnsafeBufferPointer {
            mailbox.accumulate($0.baseAddress!, frameCount: $0.count, channels: 1)
        }
        let reading = mailbox.reading
        XCTAssertEqual(reading.sequence, 1)
        XCTAssertEqual(reading.rms, 0.5, accuracy: 1e-4)
    }

    func testMailboxSpansManyWindowsInOneSlice() {
        let mailbox = InputLevelMailbox()
        let slice = [Float](repeating: 1, count: InputLevelMailbox.windowFrames * 3)
        slice.withUnsafeBufferPointer {
            mailbox.accumulate($0.baseAddress!, frameCount: $0.count, channels: 1)
        }
        XCTAssertEqual(mailbox.reading.sequence, 3)
        XCTAssertEqual(mailbox.reading.rms, 1, accuracy: 1e-4)
    }

    /// Interleaved stereo is averaged across channels, so a mono source
    /// duplicated to both reads the same as the mono source itself.
    func testMailboxAveragesAcrossChannels() {
        let mailbox = InputLevelMailbox()
        var stereo = [Float](repeating: 0, count: InputLevelMailbox.windowFrames * 2)
        for i in 0..<InputLevelMailbox.windowFrames {
            stereo[i * 2] = 0.4
            stereo[i * 2 + 1] = 0
        }
        stereo.withUnsafeBufferPointer {
            mailbox.accumulate($0.baseAddress!,
                               frameCount: InputLevelMailbox.windowFrames,
                               channels: 2)
        }
        // One channel at 0.4, one silent → mean energy 0.08 → RMS 0.283.
        XCTAssertEqual(mailbox.reading.rms, 0.2828, accuracy: 1e-3)
    }

    func testMailboxSwallowsNonFiniteSamples() {
        let mailbox = InputLevelMailbox()
        var slice = [Float](repeating: 0.2, count: InputLevelMailbox.windowFrames)
        slice[10] = .nan
        slice[20] = .infinity
        slice.withUnsafeBufferPointer {
            mailbox.accumulate($0.baseAddress!, frameCount: $0.count, channels: 1)
        }
        let reading = mailbox.reading
        XCTAssertTrue(reading.rms.isFinite,
                      "one bad sample must not poison every window after it")
        XCTAssertEqual(reading.rms, 0.2, accuracy: 0.01)
    }

    func testResetAccumulatorDropsAPartFilledWindow() {
        let mailbox = InputLevelMailbox()
        let loud = [Float](repeating: 1, count: InputLevelMailbox.windowFrames - 1)
        loud.withUnsafeBufferPointer {
            mailbox.accumulate($0.baseAddress!, frameCount: $0.count, channels: 1)
        }
        mailbox.resetAccumulator()
        let quiet = [Float](repeating: 0.1, count: InputLevelMailbox.windowFrames)
        quiet.withUnsafeBufferPointer {
            mailbox.accumulate($0.baseAddress!, frameCount: $0.count, channels: 1)
        }
        XCTAssertEqual(mailbox.reading.rms, 0.1, accuracy: 1e-3,
                       "the old device's energy leaked into the new one")
    }

    // MARK: - Meter scaling

    /// Both meters read the same signal the same way, or they are two
    /// meters telling one user two things.
    func testTheTwoMetersShareOneScaling() {
        let samples = [Float](repeating: 0.2, count: 480)
        let fromSlice = MicCheck.displayLevel(of: samples[...])
        let fromRMS = MicCheck.displayLevel(rms: 0.2)
        XCTAssertEqual(fromSlice, fromRMS, accuracy: 1e-6)
        XCTAssertEqual(MicCheck.displayLevel(rms: 0), 0)
        XCTAssertGreaterThan(MicCheck.meterDecay, 0)
        XCTAssertLessThan(MicCheck.meterDecay, 1)
    }

    // MARK: - MicWatch

    /// Drives the watch at the meter's own 10 Hz cadence.
    private func run(_ watch: MicWatch, rms: Double, offAir: Bool,
                     seconds: Double, from start: Date) -> Date {
        var now = start
        var elapsed = 0.0
        while elapsed < seconds - 1e-9 {
            now = now.addingTimeInterval(0.1)
            elapsed += 0.1
            watch.update(rms: rms, offAir: offAir, at: now)
        }
        return now
    }

    func testTalkingWhileOnAirNeverFires() {
        let watch = MicWatch()
        _ = run(watch, rms: 0.2, offAir: false, seconds: 30, from: Date())
        XCTAssertFalse(watch.isTalking)
    }

    /// The one thing it must never do: fire on a cough.
    func testACoughDoesNotFire() {
        let watch = MicWatch()
        var now = Date()
        for _ in 0..<6 {
            now = run(watch, rms: 0.4, offAir: true, seconds: 0.2, from: now)
            now = run(watch, rms: 0.001, offAir: true, seconds: 3, from: now)
            XCTAssertFalse(watch.isTalking, "a 200 ms bark is not a sentence")
        }
    }

    func testSustainedSpeechIntoAMutedMicFires() {
        let watch = MicWatch()
        _ = run(watch, rms: 0.15, offAir: true, seconds: 2, from: Date())
        XCTAssertTrue(watch.isTalking)
    }

    /// Breathing between words is still talking; the accumulator must not
    /// reset on every syllable gap.
    func testShortGapsInsideASentenceStillAccumulate() {
        let watch = MicWatch()
        var now = Date()
        for _ in 0..<5 {
            now = run(watch, rms: 0.15, offAir: true, seconds: 0.3, from: now)
            now = run(watch, rms: 0.001, offAir: true, seconds: 0.3, from: now)
        }
        XCTAssertTrue(watch.isTalking)
    }

    /// One alert per mute. Talking over a mute deliberately, for minutes,
    /// must produce exactly one — anything else is nagging.
    func testItFiresOnceAndThenLeavesYouAlone() {
        let watch = MicWatch()
        var now = Date()
        now = run(watch, rms: 0.15, offAir: true, seconds: 2, from: now)
        XCTAssertTrue(watch.isTalking)
        var fires = 1
        var wasTalking = true
        // Five minutes of talking with natural pauses, still muted.
        for _ in 0..<20 {
            now = run(watch, rms: 0.001, offAir: true, seconds: 8, from: now)
            now = run(watch, rms: 0.15, offAir: true, seconds: 7, from: now)
            if watch.isTalking, !wasTalking { fires += 1 }
            wasTalking = watch.isTalking
        }
        XCTAssertEqual(fires, 1, "it re-fired while someone talked over a mute")
    }

    /// The signal itself is not sticky: it clears when the talking stops, so
    /// the menu bar is not still pointing at a problem that went away.
    func testTheSignalClearsWhenTheTalkingStops() {
        let watch = MicWatch()
        var now = Date()
        now = run(watch, rms: 0.15, offAir: true, seconds: 2, from: now)
        XCTAssertTrue(watch.isTalking)
        _ = run(watch, rms: 0.001, offAir: true, seconds: 6, from: now)
        XCTAssertFalse(watch.isTalking)
    }

    func testGoingBackOnAirClearsItImmediately() {
        let watch = MicWatch()
        var now = Date()
        now = run(watch, rms: 0.15, offAir: true, seconds: 2, from: now)
        XCTAssertTrue(watch.isTalking)
        now = now.addingTimeInterval(0.1)
        watch.update(rms: 0.15, offAir: false, at: now)
        XCTAssertFalse(watch.isTalking, "unmuting resolves it, by definition")
    }

    /// Unmuting re-arms — a second mute is a second mistake — but the
    /// holdoff still stops mute-key mashing from turning into a stutter.
    func testANewMuteCanFireAgainOnceTheHoldoffHasPassed() {
        let watch = MicWatch()
        var now = Date()
        now = run(watch, rms: 0.15, offAir: true, seconds: 2, from: now)
        XCTAssertTrue(watch.isTalking)
        now = run(watch, rms: 0.15, offAir: false, seconds: 2, from: now)
        XCTAssertFalse(watch.isTalking)

        // Immediately re-muted and talking: inside the holdoff, so silent.
        now = run(watch, rms: 0.15, offAir: true, seconds: 3, from: now)
        XCTAssertFalse(watch.isTalking, "the holdoff let a stutter through")

        // Well past it, still muted and still talking: now it speaks up.
        now = run(watch, rms: 0.15, offAir: false, seconds: 1, from: now)
        now = run(watch, rms: 0.001, offAir: true, seconds: 25, from: now)
        _ = run(watch, rms: 0.15, offAir: true, seconds: 2, from: now)
        XCTAssertTrue(watch.isTalking)
    }

    /// Room noise below the speech threshold is not speech, however long it
    /// goes on for.
    func testQuietRoomNoiseNeverFires() {
        let watch = MicWatch()
        _ = run(watch, rms: 0.01, offAir: true, seconds: 120, from: Date())
        XCTAssertFalse(watch.isTalking)
    }

    /// A gap in the samples — the meter disarmed, the machine asleep — is
    /// the absence of evidence, not five minutes of proven silence, and must
    /// not be charged against the accumulator either way.
    func testALongGapBetweenSamplesIsNotEvidence() {
        let watch = MicWatch()
        var now = Date()
        now = run(watch, rms: 0.15, offAir: true, seconds: 1, from: now)
        XCTAssertFalse(watch.isTalking, "not sustained yet")
        now = now.addingTimeInterval(600)
        _ = run(watch, rms: 0.15, offAir: true, seconds: 0.5, from: now)
        XCTAssertTrue(watch.isTalking,
                      "the gap should count as one step, not ten minutes")
    }

    func testResetClearsEverything() {
        let watch = MicWatch()
        _ = run(watch, rms: 0.15, offAir: true, seconds: 2, from: Date())
        XCTAssertTrue(watch.isTalking)
        watch.reset()
        XCTAssertFalse(watch.isTalking)
    }
}
