// ClipPlanTests.swift
// PRISMTests
//
// The planning half of saving the last seconds (§5.15).
//
// This is the part that can be wrong in ways nobody notices until a file
// will not open. The rolling buffer's samples carry `.invalid` durations, so
// the durations in the file are synthesised here from the gaps between
// presentation times; a clip that starts before a keyframe cannot decode,
// and one that keeps its host-clock timestamps is legal and unplayable in
// half the tools that will open it.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class ClipPlanTests: XCTestCase {

    /// A 30 fps run of timestamps starting somewhere plausible on the host
    /// clock, not at zero — rebasing is one of the things under test.
    private func times(_ count: Int, from start: Double = 41_293.5,
                       fps: Double = 30) -> [Double] {
        (0..<count).map { start + Double($0) / fps }
    }

    private func keyframes(_ count: Int, at indices: Set<Int>) -> [Bool] {
        (0..<count).map { indices.contains($0) }
    }

    // MARK: - Refusals

    func testPlanNeedsMoreThanOneFrame() {
        XCTAssertNil(ClipPlanner.plan(times: [1], keyframes: [true]))
        XCTAssertNil(ClipPlanner.plan(times: [], keyframes: []))
    }

    func testPlanRefusesWhenNothingIsAKeyframe() {
        // Every frame references pictures the file would not contain.
        XCTAssertNil(ClipPlanner.plan(times: times(30),
                                      keyframes: keyframes(30, at: [])))
    }

    func testPlanRefusesWhenOnlyTheLastFrameIsAKeyframe() {
        // Trimming to it leaves a single sample, which is not a clip.
        XCTAssertNil(ClipPlanner.plan(times: times(30),
                                      keyframes: keyframes(30, at: [29])))
    }

    // MARK: - Trimming

    func testPlanTrimsToTheFirstKeyframe() {
        let plan = ClipPlanner.plan(times: times(30),
                                    keyframes: keyframes(30, at: [7, 22]))
        XCTAssertEqual(plan?.frames.first?.index, 7)
        XCTAssertEqual(plan?.frames.count, 23)
    }

    // MARK: - Rebasing

    func testPlanRebasesToZero() {
        let plan = ClipPlanner.plan(times: times(20),
                                    keyframes: keyframes(20, at: [4]))
        XCTAssertEqual(plan?.frames.first?.presentationSeconds ?? -1, 0, accuracy: 1e-9)
        // The fourth kept frame is three frame intervals in, regardless of
        // where on the host clock the recording happened to be.
        XCTAssertEqual(plan?.frames[3].presentationSeconds ?? -1, 3.0 / 30, accuracy: 1e-9)
    }

    func testPlanPresentationTimesStrictlyIncrease() {
        guard let plan = ClipPlanner.plan(times: times(30),
                                          keyframes: keyframes(30, at: [0])) else {
            return XCTFail("expected a plan")
        }
        for (previous, next) in zip(plan.frames, plan.frames.dropFirst()) {
            XCTAssertGreaterThan(next.presentationSeconds, previous.presentationSeconds)
        }
    }

    // MARK: - Synthesised durations

    func testPlanSynthesisesDurationsFromTheNextFramesGap() {
        guard let plan = ClipPlanner.plan(times: times(10),
                                          keyframes: keyframes(10, at: [0])) else {
            return XCTFail("expected a plan")
        }
        for frame in plan.frames {
            XCTAssertEqual(frame.durationSeconds, 1.0 / 30, accuracy: 1e-9)
        }
    }

    func testLastFrameInheritsThePrecedingGap() {
        // Nothing follows the final sample to measure against, and the rate
        // the recording was running at is the only estimate that cannot
        // stretch the clip.
        var stamps = times(9)
        stamps.append(stamps[8] + 0.25)          // one long frame at the end
        guard let plan = ClipPlanner.plan(times: stamps,
                                          keyframes: keyframes(10, at: [0])) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.frames[8].durationSeconds, 0.25, accuracy: 1e-9)
        XCTAssertEqual(plan.frames[9].durationSeconds, 0.25, accuracy: 1e-9)
    }

    func testDurationsAreCappedSoAStallDoesNotHangTheClip() {
        var stamps = times(5)
        stamps.append(stamps[4] + 11)            // camera went away for 11 s
        stamps.append(stamps[5] + 1.0 / 30)
        guard let plan = ClipPlanner.plan(times: stamps,
                                          keyframes: keyframes(7, at: [0])) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.frames[4].durationSeconds,
                       ClipPlanner.maximumFrameSeconds, accuracy: 1e-9)
    }

    func testDuplicateTimestampsAreDropped() {
        // Two samples at one instant cannot both be written; the sample
        // table is ordered by presentation time.
        var stamps = times(6)
        stamps[3] = stamps[2]
        guard let plan = ClipPlanner.plan(times: stamps,
                                          keyframes: keyframes(6, at: [0])) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.frames.map(\.index), [0, 1, 2, 4, 5])
    }

    func testNonMonotonicTimestampsAreDropped() {
        var stamps = times(6)
        stamps[4] = stamps[1]                    // a stamp that goes backwards
        guard let plan = ClipPlanner.plan(times: stamps,
                                          keyframes: keyframes(6, at: [0])) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.frames.map(\.index), [0, 1, 2, 3, 5])
    }

    // MARK: - Duration

    func testClipDurationCoversEveryFrame() {
        guard let plan = ClipPlanner.plan(times: times(300),
                                          keyframes: keyframes(300, at: [0, 30, 60])) else {
            return XCTFail("expected a plan")
        }
        // 300 frames at 30 fps is ten seconds, including the last one.
        XCTAssertEqual(plan.durationSeconds, 10, accuracy: 1e-6)
    }
}
