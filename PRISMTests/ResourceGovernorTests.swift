// ResourceGovernorTests.swift
// PRISMTests
//
// The memory policy (§7), as pure arithmetic — no Metal, no allocation, no
// device. Two things are being defended here. One is the ceiling: the shipped
// depths did not fit inside it, and the whole point of putting the decision in
// one function is that the sum can be checked. The other is freeze's promise
// (§5.2), which is the thing a memory policy is most tempted to quietly spend.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class ResourceGovernorTests: XCTestCase {

    private func plan(_ width: Int, _ height: Int, _ fps: Int,
                      stills: Bool = false) -> ResourcePlan {
        ResourceGovernor.plan(for: ResourceDemand(
            format: VideoFormat(width: width, height: height, frameRate: fps),
            stillsWantSharpest: stills))
    }

    // MARK: - The ceiling

    /// The regression this whole mechanism exists for. Half a second of raw
    /// 1080p60 is 30 slots — measured at 237.9 MB against a 250 MB budget
    /// that also has to hold the output pool, the intermediates and the app.
    func testMainstreamFormatsFitInsideTheCeiling() {
        for format in VideoFormat.defaultSet where format.width <= 1920 {
            let plan = ResourceGovernor.plan(for: ResourceDemand(format: format))
            XCTAssertLessThanOrEqual(plan.plannedMB, ResourceGovernor.ceilingMB,
                                     "\(format.displayName) plans over the ceiling")
            XCTAssertNotEqual(plan.tier, .exceeded, format.displayName)
        }
    }

    /// …and with the still ring armed on top, which is the configuration the
    /// old fixed depths never accounted for at all.
    func testMainstreamFormatsFitWithStillsArmed() {
        for format in VideoFormat.defaultSet where format.width <= 1920 {
            let plan = ResourceGovernor.plan(for: ResourceDemand(
                format: format, stillsWantSharpest: true))
            XCTAssertLessThanOrEqual(plan.plannedMB, ResourceGovernor.ceilingMB,
                                     "\(format.displayName) plans over the ceiling")
        }
    }

    /// 4K cannot be made to fit — the output pool and the intermediates alone
    /// are over the ceiling at 31.7 MB a frame. The policy says so out loud
    /// rather than pretending, and still takes the least it can.
    func test4KReportsTheOverageRatherThanHidingIt() {
        let plan = plan(3840, 2160, 30)
        XCTAssertEqual(plan.tier, .exceeded)
        XCTAssertGreaterThan(plan.plannedMB, ResourceGovernor.ceilingMB)
        XCTAssertEqual(plan.freezeDepth, ResourceGovernor.minimumFreezeDepth,
                       "over the ceiling, the ring takes its floor and nothing more")
        XCTAssertEqual(plan.stillDepth, 0)
        XCTAssertTrue(plan.summary.contains("250"), "the sentence has to name the ceiling")
    }

    // MARK: - Freeze's guarantee (§5.2)

    /// The floor is the promise: never fewer slots than leave a choice, and
    /// never less wall time than clears a blink. Below either, freeze stops
    /// being "the sharpest frame of the recent past" and becomes "the frame
    /// at the moment you pressed it", which §5.2 says it is not.
    func testFreezeNeverFallsBelowItsFloorAtAnyFormat() {
        for format in VideoFormat.defaultSet {
            for stills in [false, true] {
                let plan = ResourceGovernor.plan(for: ResourceDemand(
                    format: format, stillsWantSharpest: stills))
                XCTAssertGreaterThanOrEqual(plan.freezeDepth,
                                            ResourceGovernor.minimumFreezeDepth,
                                            format.displayName)
                XCTAssertGreaterThanOrEqual(
                    plan.freezeSpanSeconds,
                    ResourceGovernor.minimumFreezeSeconds - 1e-9,
                    "\(format.displayName) reaches back less than a blink")
            }
        }
    }

    /// The window is never longer than §5.2 asks for: the memory saved by
    /// stopping at half a second is memory another feature can have.
    func testFreezeNeverExceedsTheHalfSecondItWasSpecified() {
        for format in VideoFormat.defaultSet {
            let plan = ResourceGovernor.plan(for: ResourceDemand(format: format))
            XCTAssertLessThanOrEqual(plan.freezeSpanSeconds,
                                     ResourceGovernor.preferredFreezeSeconds + 1e-9,
                                     format.displayName)
        }
    }

    /// Cheap formats should not be punished for the existence of expensive
    /// ones: where there is room, the window is the full half second, every
    /// frame of it.
    func testSmallFormatsKeepTheFullWindow() {
        for plan in [plan(1280, 720, 30), plan(1280, 720, 60), plan(640, 480, 30)] {
            XCTAssertEqual(plan.tier, .full, plan.format.displayName)
            XCTAssertEqual(plan.freezeStride, 1, plan.format.displayName)
        }
    }

    /// The stride is what keeps 200 ms affordable at 60 fps: sampling the
    /// window rather than halving it. It must never appear where it is not
    /// needed — a coarser choice for nothing is a pure loss.
    func testStrideOnlyAppearsWhereTheWindowCannotBeHeldOutright() {
        for format in VideoFormat.defaultSet {
            for stills in [false, true] {
                let plan = ResourceGovernor.plan(for: ResourceDemand(
                    format: format, stillsWantSharpest: stills))
                XCTAssertGreaterThanOrEqual(plan.freezeStride, 1)
                if plan.freezeStride > 1 {
                    XCTAssertLessThan(Double(plan.freezeDepth),
                                      ResourceGovernor.minimumFreezeSeconds
                                        * Double(format.frameRate),
                                      "\(format.displayName) strides with slots to spare")
                }
            }
        }
        XCTAssertEqual(plan(1920, 1080, 30).freezeStride, 1)
        XCTAssertEqual(plan(1920, 1080, 60, stills: true).freezeStride, 2,
                       "60 fps at the floor covers 200 ms by sampling it")
    }

    // MARK: - Order of service

    /// Freeze's floor is taken before the still ring, and the still ring
    /// before any widening of the freeze window. Arming stills must therefore
    /// never cost freeze a slot it already had at the floor.
    func testArmingStillsNeverEatsIntoFreezesFloor() {
        for format in VideoFormat.defaultSet {
            let bare = ResourceGovernor.plan(for: ResourceDemand(format: format))
            let armed = ResourceGovernor.plan(for: ResourceDemand(
                format: format, stillsWantSharpest: true))
            XCTAssertGreaterThanOrEqual(armed.freezeDepth,
                                        ResourceGovernor.minimumFreezeDepth,
                                        format.displayName)
            XCTAssertLessThanOrEqual(armed.freezeDepth, bare.freezeDepth,
                                     "stills may only spend the window's slack")
        }
    }

    /// A still ring too shallow to hold a choice is full-frame memory bought
    /// for nothing, so it is refused outright — and the pipeline's fallback
    /// (the last frame) is what a still becomes.
    func testStillRingIsGrantedWholeOrRefused() {
        for format in VideoFormat.defaultSet {
            let plan = ResourceGovernor.plan(for: ResourceDemand(
                format: format, stillsWantSharpest: true))
            XCTAssertTrue(plan.stillDepth == 0
                            || plan.stillDepth >= StillRing.minimumDepth,
                          "\(format.displayName) granted \(plan.stillDepth) still slots")
            XCTAssertLessThanOrEqual(plan.stillDepth, StillRing.maximumDepth)
        }
    }

    func testNothingIsHeldForStillsNobodyAskedFor() {
        for format in VideoFormat.defaultSet {
            XCTAssertEqual(ResourceGovernor.plan(for: ResourceDemand(format: format))
                            .stillDepth, 0, format.displayName)
            XCTAssertNil(ResourceGovernor.plan(for: ResourceDemand(format: format))
                            .stillsSummary)
        }
    }

    // MARK: - Predictability

    /// A policy whose answer depends on when you asked is one nobody can
    /// reason about after the fact — including whoever reads the session log.
    func testThePlanIsDeterministic() {
        let demand = ResourceDemand(
            format: VideoFormat(width: 1920, height: 1080, frameRate: 60),
            stillsWantSharpest: true)
        XCTAssertEqual(ResourceGovernor.plan(for: demand),
                       ResourceGovernor.plan(for: demand))
    }

    /// More pixels can never buy more slots. The ladder has to be monotonic
    /// or the degradation is not predictable, whatever the sentence says.
    func testDepthNeverGrowsWithFrameSize() {
        let rates = [24, 30, 60]
        for rate in rates {
            let small = plan(1280, 720, rate).freezeDepth
            let large = plan(1920, 1080, rate).freezeDepth
            XCTAssertGreaterThanOrEqual(small, large,
                                        "1080p\(rate) holds more slots than 720p\(rate)")
        }
    }

    /// The tier is a description of the depth, not an independent opinion —
    /// two surfaces reading it must not be able to disagree with the number
    /// sitting next to it.
    func testTierAgreesWithTheDepthItDescribes() {
        for format in VideoFormat.defaultSet {
            for stills in [false, true] {
                let plan = ResourceGovernor.plan(for: ResourceDemand(
                    format: format, stillsWantSharpest: stills))
                let floor = ResourceGovernor.minimumFreezeDepth
                let preferred = ResourceGovernor.preferredDepth(for: format)
                switch plan.tier {
                case .full: XCTAssertEqual(plan.freezeDepth, preferred)
                case .reduced:
                    XCTAssertGreaterThan(plan.freezeDepth, floor)
                    XCTAssertLessThan(plan.freezeDepth, preferred)
                case .minimum:
                    XCTAssertEqual(plan.freezeDepth, floor)
                    XCTAssertLessThanOrEqual(plan.plannedMB, ResourceGovernor.ceilingMB)
                case .exceeded:
                    XCTAssertGreaterThan(plan.plannedMB, ResourceGovernor.ceilingMB)
                }
            }
        }
    }
}
