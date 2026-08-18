// ChainRegistrationTests.swift
// PRISMTests
//
// Adding a stage means touching six places that have no compiler relationship
// to one another: the StageID enum, its chainIndex, the pipeline's stage
// array, the GPU weight table, the configuration flags, and the degradation
// candidate set. Miss one and nothing fails to build — the stage simply never
// runs, or runs unweighted, or can never be reclaimed when the budget is
// blown, and the first report is a user saying the picture looks wrong in a
// way nobody can reproduce. These tests turn each of those into a loud
// failure at the moment the enum gains a case.
//
// Licensed under the Apache License, Version 2.0.

import Metal
import XCTest

final class ChainRegistrationTests: XCTestCase {

    /// Stages the user engages deliberately, which the budget may never
    /// reclaim: substituting a clip, replay or freeze back to the live camera
    /// behind the user's back is the one failure this app must never produce,
    /// bad connection is engaged intent rather than a look (§5.14), and
    /// output fit is structural. Everything else is a look, and §3.4 says a
    /// look is what gets sacrificed before a frame does.
    private static let intentOwned: Set<StageID> = [
        .clip, .replay, .freeze, .connection, .outputFit,
    ]

    private func makePipeline() throws -> VideoPipeline {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device on this host")
        }
        return try VideoPipeline(metal: try MetalContext())
    }

    /// The chain the pipeline actually runs must be the chain StageID
    /// describes — every case present, once, in chainIndex order.
    func testEveryStageIsRegisteredExactlyOnceInChainOrder() throws {
        let pipeline = try makePipeline()
        let registered = pipeline.stages.map(\.id)

        XCTAssertEqual(registered.count, StageID.allCases.count)
        XCTAssertEqual(Set(registered), Set(StageID.allCases),
                       "a StageID with no stage never runs")
        for id in StageID.allCases {
            XCTAssertEqual(registered.filter { $0 == id }.count, 1,
                           "\(id) is registered more than once")
        }
        XCTAssertEqual(registered, StageID.allCases.sorted(),
                       "the pipeline runs the stages in a different order than StageID declares")
    }

    /// chainIndex is the degradation tie-breaker and the sort key for the
    /// whole chain; a duplicate or a gap makes both silently wrong.
    func testChainIndicesAreContiguousFromZero() {
        let indices = StageID.allCases.map(\.chainIndex).sorted()
        XCTAssertEqual(indices, Array(0..<StageID.allCases.count))
    }

    /// A missing weight falls back to 1, which silently attributes a fraction
    /// of the frame's GPU time to a stage that may be the most expensive in
    /// the chain — and the degradation engine reads those numbers.
    func testEveryStageHasAGpuWeight() {
        for id in StageID.allCases {
            XCTAssertNotNil(VideoPipeline.stageWeights[id],
                            "\(id) has no GPU weight")
        }
        XCTAssertEqual(Set(VideoPipeline.stageWeights.keys), Set(StageID.allCases),
                       "the weight table names a stage that no longer exists")
    }

    /// Every look needs a flags entry (nothing can switch it on otherwise) and
    /// must be reclaimable when the budget is blown; every intent-owned stage
    /// needs neither and must have neither.
    func testUserFacingStagesHaveFlagsAndAreDegradable() {
        let config = PipelineConfiguration()
        for id in StageID.allCases {
            if Self.intentOwned.contains(id) {
                XCTAssertNil(config.flags[id],
                             "\(id) is engaged by intent; it has no look switch")
                XCTAssertFalse(LatencyMonitor.disableCandidates.contains(id),
                               "\(id) carries user intent and must never be auto-disabled")
            } else {
                XCTAssertNotNil(config.flags[id],
                                "\(id) has no flags default, so no preset can switch it on")
                XCTAssertTrue(LatencyMonitor.disableCandidates.contains(id),
                              "\(id) is a look the budget could never reclaim")
            }
        }
    }

    /// "Last resort" is a rank, not a flag: two of them would leave the
    /// engine with no defined order between the stages it gives up last.
    func testExactlyOneStageIsLastResort() {
        let lastResort = StageID.allCases.filter(\.isLastResort)
        XCTAssertEqual(lastResort, [.background])
    }
}
