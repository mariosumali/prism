// ReplayBufferTests.swift
// PRISMTests
//
// The away loop's cut-point search (§5.10) and the rolling buffer's sizing
// arithmetic (§5.9). The search is the interesting part: it is the whole
// reason the buffer keeps a thumbnail per frame, and its output is what
// decides whether an auto-generated idle loop reads as "still here" or as a
// stuttering GIF.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class ReplayBufferTests: XCTestCase {

    private let width = ReplayBuffer.thumbnailWidth
    private let height = ReplayBuffer.thumbnailHeight
    private var pixels: Int { width * height }

    /// A thumbnail of uniform luma — enough to make frames comparable
    /// without pretending to be an image.
    private func flat(_ value: Float) -> [Float] {
        [Float](repeating: value, count: pixels)
    }

    /// 30 fps timestamps starting at zero.
    private func times(_ count: Int, fps: Double = 30) -> [Double] {
        (0..<count).map { Double($0) / fps }
    }

    // MARK: - Difference metric

    func testMeanAbsoluteDifferenceOfIdenticalFramesIsZero() {
        XCTAssertEqual(ReplayBuffer.meanAbsoluteDifference(flat(0.5), flat(0.5)),
                       0, accuracy: 1e-9)
    }

    func testMeanAbsoluteDifferenceScalesWithSeparation() {
        let small = ReplayBuffer.meanAbsoluteDifference(flat(0.5), flat(0.55))
        let large = ReplayBuffer.meanAbsoluteDifference(flat(0.5), flat(0.9))
        XCTAssertEqual(small, 0.05, accuracy: 1e-6)
        XCTAssertLessThan(small, large)
    }

    func testMeanAbsoluteDifferenceOfEmptyIsMaximal() {
        // An absent thumbnail must never look like a perfect match, or the
        // seam search would happily cut on missing data.
        XCTAssertEqual(ReplayBuffer.meanAbsoluteDifference([], flat(0.5)),
                       .greatestFiniteMagnitude)
    }

    // MARK: - Loop selection

    func testSelectLoopRejectsTooFewFrames() {
        XCTAssertNil(ReplayBuffer.selectLoop(thumbnails: [flat(0.5)],
                                             times: [0],
                                             loopSeconds: 4))
    }

    func testSelectLoopPrefersTheStillestMatchingSegment() {
        // 300 frames (10 s at 30 fps). Frames 30–120 are dead still; the rest
        // ramp steadily, so both their motion and their seam cost are high.
        let count = 300
        var thumbnails: [[Float]] = []
        for index in 0..<count {
            if (30...120).contains(index) {
                thumbnails.append(flat(0.5))
            } else {
                thumbnails.append(flat(Float(index) * 0.002))
            }
        }
        let selection = ReplayBuffer.selectLoop(thumbnails: thumbnails,
                                                times: times(count),
                                                loopSeconds: 2)
        let range = try? XCTUnwrap(selection)
        guard let range else { return XCTFail("no loop selected") }
        // A 2 s loop at 30 fps is ~60 frames, which fits inside the still run.
        XCTAssertGreaterThanOrEqual(range.start, 30)
        XCTAssertLessThanOrEqual(range.end, 120)
    }

    func testSelectLoopHonoursTheRequestedLength() {
        let count = 300
        let thumbnails = (0..<count).map { _ in flat(0.5) }
        let stamps = times(count)
        for requested in [2.0, 4.0, 6.0] {
            guard let range = ReplayBuffer.selectLoop(thumbnails: thumbnails,
                                                      times: stamps,
                                                      loopSeconds: requested) else {
                return XCTFail("no loop selected for \(requested)s")
            }
            let length = stamps[range.end] - stamps[range.start]
            XCTAssertLessThanOrEqual(length, requested + 1e-9)
            // The search takes the longest segment that still fits, so it
            // should land within a frame of the request.
            XCTAssertGreaterThan(length, requested - 2.0 / 30.0)
        }
    }

    /// The away loop is triggered as someone gets up, so the newest second is
    /// the one with a hand reaching off-screen in it. It must be excluded
    /// even when it scores well.
    func testSelectLoopExcludesTheMostRecentSecond() {
        let count = 300
        let stamps = times(count)
        // Everything ramps (so nothing is a trivially perfect match) except a
        // dead-still run at the very end, which would otherwise win outright.
        var thumbnails: [[Float]] = []
        for index in 0..<count {
            thumbnails.append(index >= 250 ? flat(0.5) : flat(Float(index) * 0.003))
        }
        guard let range = ReplayBuffer.selectLoop(thumbnails: thumbnails,
                                                  times: stamps,
                                                  loopSeconds: 2) else {
            return XCTFail("no loop selected")
        }
        // Last usable frame is the newest one at least 1 s old.
        let newest = stamps[count - 1]
        XCTAssertLessThan(stamps[range.end], newest - 1.0 + 1e-9)
    }

    func testSelectLoopReturnsAnOrderedRange() {
        let count = 200
        let thumbnails = (0..<count).map { index in flat(Float(index % 7) * 0.1) }
        guard let range = ReplayBuffer.selectLoop(thumbnails: thumbnails,
                                                  times: times(count),
                                                  loopSeconds: 3) else {
            return XCTFail("no loop selected")
        }
        XCTAssertLessThan(range.start, range.end)
        XCTAssertGreaterThanOrEqual(range.start, 0)
        XCTAssertLessThan(range.end, count)
    }

    // MARK: - Encoder sizing

    func testBitRateScalesWithPixelsAndClamps() {
        let hd = ReplayBuffer.bitRate(width: 1920, height: 1080)
        XCTAssertEqual(hd, 8_000_000)

        // Quarter the pixels → quarter the rate, until the floor bites.
        let small = ReplayBuffer.bitRate(width: 960, height: 540)
        XCTAssertEqual(small, 2_000_000)

        // Well past 1080p must not run away.
        let uhd = ReplayBuffer.bitRate(width: 3840, height: 2160)
        XCTAssertEqual(uhd, 12_000_000)
    }

    // MARK: - Ten seconds must fit the memory budget (§7)

    /// The entire reason this buffer compresses rather than storing frames.
    /// Raw 1080p30 for ten seconds is an order of magnitude past the app's
    /// whole budget; the encoded stream is a rounding error against it.
    func testEncodedTenSecondsIsOrdersOfMagnitudeSmallerThanRaw() {
        let rawBytes = 1920 * 1080 * 4 * 30 * 10
        let encodedBytes = ReplayBuffer.bitRate(width: 1920, height: 1080) / 8 * 10
        XCTAssertGreaterThan(rawBytes, 2_000_000_000)
        XCTAssertLessThan(encodedBytes, 25_000_000)
    }
}
