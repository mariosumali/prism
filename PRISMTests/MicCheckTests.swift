// MicCheckTests.swift
// PRISMTests
//
// The §5.13 mic check: the SPSC tap ring's cursor arithmetic, the
// record-then-play-back state machine (driven through injected fakes, no
// audio hardware), the silence diagnosis, and the meter scaling.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

// MARK: - Fakes

/// Captures playback requests; completion is fired by the test, so the
/// machine's playing → idle transition is exercised deterministically.
private final class FakePlayer: MicCheckPlaying {
    var played: [[Float]] = []
    var completion: (() -> Void)?
    var stopped = 0
    var refuses = false

    func play(_ samples: [Float], sampleRate: Double,
              completion: @escaping () -> Void) -> Bool {
        if refuses { return false }
        played.append(samples)
        self.completion = completion
        return true
    }

    func stop() {
        stopped += 1
    }
}

/// A scripted tap: hands out queued sample chunks through the same
/// (cursor, buffer, maxFrames) contract the real ring implements.
private final class FakeTap {
    private(set) var armed = false
    private(set) var armCalls: [Bool] = []
    private var pending: [Float] = []
    private var cursor: UInt64 = 0

    func feed(_ samples: [Float]) {
        pending.append(contentsOf: samples)
    }

    func arm(_ on: Bool) {
        armed = on
        armCalls.append(on)
    }

    func currentCursor() -> UInt64 { cursor }

    func read(from: UInt64, into buffer: UnsafeMutablePointer<Float>,
              maxFrames: Int) -> (UInt64, Int) {
        let count = min(pending.count, maxFrames)
        guard count > 0 else { return (cursor, 0) }
        pending.withUnsafeBufferPointer { source in
            buffer.update(from: source.baseAddress!, count: count)
        }
        pending.removeFirst(count)
        cursor &+= UInt64(count)
        return (cursor, count)
    }
}

@MainActor
private func makeCheck(tap: FakeTap, player: FakePlayer) -> MicCheck {
    MicCheck(armTap: { tap.arm($0) },
             tapCursor: { tap.currentCursor() },
             readTap: { tap.read(from: $0, into: $1, maxFrames: $2) },
             player: player)
}

final class MicCheckTests: XCTestCase {

    // MARK: - Tap ring

    func testTapRingRoundTripsSamplesInOrder() {
        let ring = MicTapRing(capacityFrames: 1 << 12)
        let ramp = (0..<512).map { Float($0) / 512 }
        ramp.withUnsafeBufferPointer { ring.writeMono($0.baseAddress!, frameCount: $0.count) }

        var out = [Float](repeating: 0, count: 4096)
        let (next, frames) = out.withUnsafeMutableBufferPointer {
            ring.read(from: 0, into: $0.baseAddress!, maxFrames: 4096)
        }
        XCTAssertEqual(frames, 512, "everything below the head is readable")
        XCTAssertEqual(next, 512)
        XCTAssertEqual(Array(out.prefix(512)), ramp)
    }

    /// The head is the release/acquire handoff point: it tracks writes
    /// exactly, and a cursor at or past it reads nothing and stays put —
    /// that is what makes a head snapshot a correct start-of-take marker.
    func testTapRingHeadTracksWritesAndNeverRewindsACursor() {
        let ring = MicTapRing(capacityFrames: 1 << 12)
        let samples = [Float](repeating: 1, count: 300)
        samples.withUnsafeBufferPointer { ring.writeMono($0.baseAddress!, frameCount: $0.count) }
        XCTAssertEqual(ring.head, 300)

        var out = [Float](repeating: 0, count: 64)
        // A cursor at the head: nothing yet, cursor unchanged.
        var result = out.withUnsafeMutableBufferPointer {
            ring.read(from: 300, into: $0.baseAddress!, maxFrames: 64)
        }
        XCTAssertEqual(result.frames, 0)
        XCTAssertEqual(result.cursor, 300)
        // Even a cursor beyond the head must not be rewound into old data.
        result = out.withUnsafeMutableBufferPointer {
            ring.read(from: 999, into: $0.baseAddress!, maxFrames: 64)
        }
        XCTAssertEqual(result.frames, 0)
        XCTAssertEqual(result.cursor, 999)
    }

    func testTapRingWrapsAcrossItsCapacity() {
        let capacity = 1 << 12
        let ring = MicTapRing(capacityFrames: capacity)
        var cursor: UInt64 = 0
        var received: [Float] = []
        var scratch = [Float](repeating: 0, count: capacity)
        // Stream three capacities of a ramp through the ring in chunks,
        // draining as we go — the reader must see a perfectly contiguous
        // sequence across every wrap.
        let total = capacity * 3
        var written = 0
        while written < total {
            let chunk = (0..<640).map { Float(written + $0) }
            chunk.withUnsafeBufferPointer { ring.writeMono($0.baseAddress!, frameCount: $0.count) }
            written += chunk.count
            let (next, frames) = scratch.withUnsafeMutableBufferPointer {
                ring.read(from: cursor, into: $0.baseAddress!, maxFrames: capacity)
            }
            cursor = next
            received.append(contentsOf: scratch.prefix(frames))
        }
        XCTAssertFalse(received.isEmpty)
        for (offset, value) in received.enumerated() {
            XCTAssertEqual(value, Float(offset), "gap or reorder at frame \(offset)")
            if value != Float(offset) { break }
        }
    }

    /// A reader that stalls while the writer laps the ring must skip forward
    /// to still-valid data instead of reading a torn mix of old and new.
    func testTapRingSkipsALappedBacklog() {
        let capacity = 1 << 12
        let ring = MicTapRing(capacityFrames: capacity)
        let total = capacity * 4
        var written = 0
        while written < total {
            let chunk = (0..<1024).map { Float(written + $0) }
            chunk.withUnsafeBufferPointer { ring.writeMono($0.baseAddress!, frameCount: $0.count) }
            written += chunk.count
        }
        var scratch = [Float](repeating: 0, count: capacity)
        let (next, frames) = scratch.withUnsafeMutableBufferPointer {
            ring.read(from: 0, into: $0.baseAddress!, maxFrames: capacity)
        }
        XCTAssertGreaterThan(frames, 0)
        XCTAssertEqual(next, ring.head, "a full drain lands at the head")
        // The oldest frame handed out must still have been valid (within one
        // capacity of the write head) when it was copied.
        let first = Int(scratch[0])
        XCTAssertGreaterThanOrEqual(first, total - capacity,
                                    "read reached back into overwritten frames")
        // And the run must be contiguous.
        for i in 0..<frames {
            XCTAssertEqual(scratch[i], Float(first + i))
            if scratch[i] != Float(first + i) { break }
        }
    }

    func testTapRingStereoMixdownAverages() {
        let ring = MicTapRing(capacityFrames: 1 << 12)
        let stereo: [Float] = [1, 0, 0.5, 0.5, -1, 1]     // L R L R L R
        stereo.withUnsafeBufferPointer { ring.writeStereoMixdown($0.baseAddress!, frameCount: 3) }
        var out = [Float](repeating: 9, count: 8)
        let (_, frames) = out.withUnsafeMutableBufferPointer {
            ring.read(from: 0, into: $0.baseAddress!, maxFrames: 3)
        }
        XCTAssertEqual(frames, 3)
        XCTAssertEqual(out[0], 0.5)
        XCTAssertEqual(out[1], 0.5)
        XCTAssertEqual(out[2], 0)
    }

    // MARK: - State machine

    @MainActor
    func testToggleRecordsThenPlaysBackTheTake() {
        let tap = FakeTap()
        let player = FakePlayer()
        let check = makeCheck(tap: tap, player: player)

        check.toggle()
        XCTAssertEqual(check.phase, .recording)
        XCTAssertTrue(tap.armed, "recording arms the tap")

        tap.feed([Float](repeating: 0.4, count: 4800))
        check.pollOnce()
        XCTAssertEqual(check.recordedSeconds, 0.1, accuracy: 1e-9)
        XCTAssertGreaterThan(check.level, 0.3, "the meter moves while you speak")

        check.toggle()                                   // stop and play
        XCTAssertEqual(check.phase, .playing)
        XCTAssertFalse(tap.armed, "stopping disarms the tap")
        XCTAssertEqual(player.played.count, 1)
        XCTAssertEqual(player.played[0].count, 4800)

        player.completion?()                             // playback finishes
        XCTAssertEqual(check.phase, .idle)
        XCTAssertTrue(check.hasTake, "the take survives for replay")
        XCTAssertFalse(check.heardNothing)
    }

    @MainActor
    func testRecordingAutoStopsAtTheMaximumLength() {
        let tap = FakeTap()
        let player = FakePlayer()
        let check = makeCheck(tap: tap, player: player)

        check.toggle()
        tap.feed([Float](repeating: 0.2,
                         count: Int(MicCheck.maxSeconds * 48_000) + 9600))
        check.pollOnce()
        XCTAssertEqual(check.phase, .playing, "hitting the cap plays back")
        XCTAssertEqual(player.played[0].count, Int(MicCheck.maxSeconds * 48_000),
                       "the take never exceeds the cap")
    }

    @MainActor
    func testSilentTakeIsDiagnosedNotPlayed() {
        let tap = FakeTap()
        let player = FakePlayer()
        let check = makeCheck(tap: tap, player: player)

        check.toggle()
        tap.feed([Float](repeating: 0.001, count: 9600))  // below the floor
        check.pollOnce()
        check.toggle()
        XCTAssertEqual(check.phase, .idle)
        XCTAssertTrue(check.heardNothing)
        XCTAssertTrue(player.played.isEmpty, "playing back silence proves nothing")
        XCTAssertFalse(check.hasTake)
    }

    @MainActor
    func testReplayReplaysTheLastTakeWithoutRerecording() {
        let tap = FakeTap()
        let player = FakePlayer()
        let check = makeCheck(tap: tap, player: player)

        check.toggle()
        tap.feed([Float](repeating: 0.4, count: 4800))
        check.pollOnce()
        check.toggle()
        player.completion?()

        check.replay()
        XCTAssertEqual(check.phase, .playing)
        XCTAssertEqual(player.played.count, 2)
        XCTAssertEqual(player.played[1], player.played[0])
        XCTAssertTrue(tap.armCalls.suffix(1) == [false], "replay never re-arms the tap")
    }

    @MainActor
    func testStopDuringPlaybackReturnsToIdleAndIgnoresLateCompletion() {
        let tap = FakeTap()
        let player = FakePlayer()
        let check = makeCheck(tap: tap, player: player)

        check.toggle()
        tap.feed([Float](repeating: 0.4, count: 4800))
        check.pollOnce()
        check.toggle()
        let stale = player.completion
        check.toggle()                                   // stop playback
        XCTAssertEqual(check.phase, .idle)

        check.toggle()                                   // start a new recording
        stale?()                                         // late completion fires
        XCTAssertEqual(check.phase, .recording,
                       "a stale playback completion must not yank the machine to idle")
        check.cancel()
    }

    @MainActor
    func testPlaybackRefusalLandsBackAtIdle() {
        let tap = FakeTap()
        let player = FakePlayer()
        player.refuses = true
        let check = makeCheck(tap: tap, player: player)

        check.toggle()
        tap.feed([Float](repeating: 0.4, count: 4800))
        check.pollOnce()
        check.toggle()
        XCTAssertEqual(check.phase, .idle,
                       "no output device is a shrug, not a stuck state")
    }

    @MainActor
    func testCancelDisarmsAndStopsEverything() {
        let tap = FakeTap()
        let player = FakePlayer()
        let check = makeCheck(tap: tap, player: player)

        check.toggle()
        XCTAssertTrue(tap.armed)
        check.cancel()
        XCTAssertEqual(check.phase, .idle)
        XCTAssertFalse(tap.armed)
        XCTAssertGreaterThan(player.stopped, 0)
    }

    /// Regression for the review's stale-tail finding: through a REAL tap
    /// ring, a silent second take after a loud first one must be diagnosed
    /// as silence — not padded with the previous take's tail until it clears
    /// the silence gate and plays back seconds of nothing.
    @MainActor
    func testSecondTakeNeverInheritsTheFirstTakesTail() {
        let ring = MicTapRing(capacityFrames: 1 << 12)
        var armed = false
        let player = FakePlayer()
        let check = MicCheck(
            armTap: { armed = $0 },
            tapCursor: { ring.head },
            readTap: { ring.read(from: $0, into: $1, maxFrames: $2) },
            player: player)

        func rtWrite(_ value: Float, frames: Int) {
            guard armed else { return }
            let chunk = [Float](repeating: value, count: frames)
            chunk.withUnsafeBufferPointer { ring.writeMono($0.baseAddress!, frameCount: frames) }
        }

        check.toggle()                       // take 1: loud
        rtWrite(0.5, frames: 2048)
        check.pollOnce()
        check.toggle()
        XCTAssertEqual(player.played.count, 1)
        player.completion?()

        check.toggle()                       // take 2: digital silence
        rtWrite(0, frames: 2048)
        check.pollOnce()
        check.toggle()
        XCTAssertTrue(check.heardNothing,
                      "a silent device must be diagnosed, not masked by stale audio")
        XCTAssertEqual(player.played.count, 1, "silence is never played back")
    }

    /// Regression for the starved-recording finding: when the tap feed dies
    /// (device gone, capture torn down) the recording still terminates on
    /// wall clock instead of holding .recording forever.
    @MainActor
    func testStarvedRecordingEndsOnTheWallClockDeadline() {
        let tap = FakeTap()
        let player = FakePlayer()
        let check = makeCheck(tap: tap, player: player)
        var fakeNow = Date()
        check.now = { fakeNow }

        check.toggle()
        check.pollOnce()                     // nothing arrives
        XCTAssertEqual(check.phase, .recording)

        fakeNow = fakeNow.addingTimeInterval(MicCheck.maxSeconds + 2)
        check.pollOnce()
        XCTAssertEqual(check.phase, .idle, "a starved take must not record forever")
        XCTAssertFalse(tap.armed, "the tap is disarmed on the way out")
        XCTAssertTrue(check.heardNothing, "an empty take is diagnosed as silence")
        XCTAssertTrue(player.played.isEmpty)
    }

    // MARK: - Meter

    func testDisplayLevelIsZeroForSilenceAndNearOneForLoudSpeech() {
        let silence = [Float](repeating: 0, count: 480)
        XCTAssertEqual(MicCheck.displayLevel(of: silence[...]), 0)
        let loud = [Float](repeating: 0.5, count: 480)
        XCTAssertGreaterThan(MicCheck.displayLevel(of: loud[...]), 0.9)
    }

    func testDisplayLevelIsMonotonicInLoudness() {
        let quiet = [Float](repeating: 0.02, count: 480)
        let mid = [Float](repeating: 0.1, count: 480)
        XCTAssertLessThan(MicCheck.displayLevel(of: quiet[...]),
                          MicCheck.displayLevel(of: mid[...]))
        XCTAssertLessThanOrEqual(MicCheck.displayLevel(of: mid[...]), 1)
    }
}
