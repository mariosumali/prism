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

    // MARK: - Everything is counted (§5.23)

    /// The sum has to contain every full-frame allocation the chain makes,
    /// itemised here with literal counts rather than by reading the
    /// governor's own constants back — a term dropped from both sides proves
    /// nothing. Overlay's layer ping-pong pair and Retouch's half-resolution
    /// pair were outside this sum while the plan reported that 1080p fitted.
    func testEveryFullFrameAllocationOfTheChainIsInTheSum() {
        let format = VideoFormat(width: 1920, height: 1080, frameRate: 30)
        let plan = ResourceGovernor.plan(for: ResourceDemand(format: format))
        let frame = ResourceGovernor.frameMB(for: format)
        // 4 output pool + 1 fit scratch + 2 intermediates + 2 style
        // + 2 overlay, then Retouch's two half-resolution scratches (a
        // quarter of a frame each), then the ring the plan just granted.
        let wholeFrames = 4 + 1 + 2 + 2 + 2 + plan.freezeDepth
        let expected = ResourceGovernor.reservedMB
            + ResourceGovernor.visionStagingMB
            + (Double(wholeFrames) + 0.5) * frame
        XCTAssertEqual(plan.plannedMB, expected, accuracy: 0.01,
                       "an allocation is missing from the plan")
    }

    /// §3.2 picks the smallest native camera format at least as large as the
    /// output in BOTH dimensions, so a 4:3 sensor serving a 16:9 call is
    /// strictly larger — a Continuity Camera hands over 1920×1440 for 1080p.
    /// FrameRing, the intermediates and every stage texture are allocated at
    /// that size, and pricing them at the output's understated the ring by a
    /// third while the plan reported that it fitted.
    func testTheWorkingSetIsPricedAtTheSourceResolutionNotTheOutputs() {
        let format = VideoFormat(width: 1920, height: 1080, frameRate: 30)
        let asOutput = ResourceGovernor.plan(for: ResourceDemand(format: format))
        let continuity = ResourceGovernor.plan(for: ResourceDemand(
            format: format, sourceWidth: 1920, sourceHeight: 1440))

        XCTAssertGreaterThan(continuity.plannedMB, asOutput.plannedMB,
                             "a 4:3 sensor costs more per slot than the call does")
        let slot = ResourceGovernor.workingFrameMB(
            for: ResourceDemand(format: format,
                                sourceWidth: 1920, sourceHeight: 1440))
        XCTAssertEqual(slot, Double(1920 * 1440 * 4) / (1024 * 1024), accuracy: 0.01)
        // 6.5 working textures plus the ring, all a third larger than the
        // plan used to think — enough that 1080p no longer fits, and the
        // plan has to say so rather than spend memory it does not have.
        XCTAssertEqual(continuity.tier, .exceeded)
        XCTAssertEqual(continuity.freezeDepth, ResourceGovernor.minimumFreezeDepth)
    }

    /// §5.9's rolling buffer is the largest thing one user switch allocates —
    /// a six-slot raw record pool, the compressed ring and its thumbnails —
    /// and none of it was in the plan. Arming it changed nothing the
    /// diagnostics pane showed while resident memory went up by a third.
    func testArmingTheRollingReplayBufferMovesThePlan() {
        let format = VideoFormat(width: 1280, height: 720, frameRate: 30)
        let idle = ResourceGovernor.plan(for: ResourceDemand(format: format))
        let armed = ResourceGovernor.plan(for: ResourceDemand(
            format: format, replayArmed: true, replaySeconds: 10,
            replayMaxHeight: 1080))

        let cost = ResourceGovernor.replayMB(for: ResourceDemand(
            format: format, replayArmed: true, replaySeconds: 10,
            replayMaxHeight: 1080))
        XCTAssertGreaterThan(cost, Double(ReplayBuffer.recordPoolDepth)
                                * ResourceGovernor.frameMB(for: format),
                             "the pool alone is six raw slots")
        XCTAssertEqual(armed.plannedMB, idle.plannedMB + cost, accuracy: 0.01)
        XCTAssertEqual(ResourceGovernor.replayMB(for: ResourceDemand(format: format)), 0,
                       "disarmed, it holds nothing and is charged nothing")

        // A longer window costs more compressed ring and more thumbnails.
        let longer = ResourceGovernor.replayMB(for: ResourceDemand(
            format: format, replayArmed: true, replaySeconds: 30,
            replayMaxHeight: 1080))
        XCTAssertGreaterThan(longer, cost)
    }

    /// At 1080p the buffer is recorded uncapped, and the plan that used to
    /// read the same with it on and off now goes over the ceiling and says so.
    func testArmingReplayAt1080pTakesThePlanOverTheCeilingOutLoud() {
        let format = VideoFormat(width: 1920, height: 1080, frameRate: 30)
        let armed = ResourceGovernor.plan(for: ResourceDemand(
            format: format, replayArmed: true, replaySeconds: 10,
            replayMaxHeight: 1080))
        XCTAssertEqual(armed.tier, .exceeded)
        XCTAssertGreaterThan(armed.plannedMB, ResourceGovernor.ceilingMB)
        XCTAssertEqual(armed.freezeDepth, ResourceGovernor.minimumFreezeDepth,
                       "freeze keeps its floor and takes nothing above it")
        XCTAssertTrue(armed.summary.contains("250"))
    }

    /// §5.5's draft preview runs a complete second chain — its own
    /// intermediates, stage scratch, output pool, segmenter and face tracker.
    /// Opening the settings pane to stage a look used to add all of it with
    /// `plannedMB`, `tier` and the diagnostics pane reporting exactly what
    /// they reported before.
    func testStagingADraftIsChargedForTheSecondChainItRuns() {
        let format = VideoFormat(width: 1280, height: 720, frameRate: 30)
        let alone = ResourceGovernor.plan(for: ResourceDemand(format: format))
        let staging = ResourceGovernor.plan(for: ResourceDemand(
            format: format, draftChainActive: true))

        let cost = ResourceGovernor.draftMB(for: ResourceDemand(
            format: format, draftChainActive: true))
        let frame = ResourceGovernor.frameMB(for: format)
        XCTAssertGreaterThan(cost, Double(DraftRenderer.outputPoolDepth) * frame
                                + ResourceGovernor.draftVisionMB,
                             "the second chain is more than its output pool")
        XCTAssertGreaterThan(staging.plannedMB, alone.plannedMB)
        XCTAssertLessThan(staging.freezeDepth, alone.freezeDepth,
                          "a second chain has to come out of something")
        XCTAssertGreaterThanOrEqual(staging.freezeDepth,
                                    ResourceGovernor.minimumFreezeDepth,
                                    "and never out of freeze's floor")
        XCTAssertEqual(ResourceGovernor.draftMB(for: ResourceDemand(format: format)), 0,
                       "no draft, no charge")
    }

    /// Whatever else moves, the floor does not — every demand this file knows
    /// about, all at once, and freeze still holds a choice.
    func testEverythingAtOnceStillLeavesFreezeItsFloor() {
        for format in VideoFormat.defaultSet {
            let plan = ResourceGovernor.plan(for: ResourceDemand(
                format: format, stillsWantSharpest: true,
                screenSourceActive: true,
                sourceWidth: 1920, sourceHeight: 1440,
                replayArmed: true, replaySeconds: 30, replayMaxHeight: 1080,
                draftChainActive: true))
            XCTAssertEqual(plan.freezeDepth, ResourceGovernor.minimumFreezeDepth,
                           format.displayName)
            XCTAssertEqual(plan.stillDepth, 0, format.displayName)
            XCTAssertEqual(plan.tier, .exceeded, format.displayName)
            XCTAssertGreaterThanOrEqual(plan.freezeSpanSeconds,
                                        ResourceGovernor.minimumFreezeSeconds - 1e-9,
                                        format.displayName)
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
