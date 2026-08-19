// VisionCoordinatorTests.swift
// PRISMTests
//
// The Vision schedule, as pure logic. The properties below are the ones the
// old hard-coded parities gave for free with two modalities and could not
// give at all with three: one request per modality per frame, never two
// modalities on one frame, nothing running for a consumer that went away, and
// proportional slip rather than starvation when there is more demand than
// there are frames.
//
// The alternation test is the important one. Eye contact's smoothing is tuned
// against landmarks arriving every other frame, and this refactor is only
// safe if it still does when nothing new is demanded.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class VisionCoordinatorTests: XCTestCase {

    private typealias Modality = VisionCoordinator.Modality

    /// Runs the coordinator for `frames` frames with fixed demand, returning
    /// what ran on each one.
    private func run(frames: Int, demand: Set<Modality>,
                     cadences: [Modality: Int] = [.face: 2, .person: 2, .hands: 3])
    -> [Modality?] {
        let coordinator = VisionCoordinator()
        for (modality, cadence) in cadences {
            coordinator.register(modality, cadence: cadence)
        }
        for modality in Modality.allCases {
            coordinator.addConsumer(of: modality) { demand.contains(modality) }
        }
        return (0..<frames).map { _ in coordinator.beginFrame().running }
    }

    // MARK: - What the parities used to guarantee

    /// Face and person, both wanting every other frame, must still alternate
    /// exactly — the behaviour the hard-coded even/odd split produced, and
    /// the reason this is a refactor rather than a change to eye contact.
    func testTwoModalitiesAtTheSameCadenceStillAlternate() {
        let ran = run(frames: 20, demand: [.face, .person])
        XCTAssertEqual(ran.compactMap { $0 }.count, 20, "every frame runs something")
        for (index, modality) in ran.enumerated() where index > 0 {
            XCTAssertNotEqual(modality, ran[index - 1],
                              "frame \(index) repeated \(String(describing: modality))")
        }
        XCTAssertEqual(ran.filter { $0 == .face }.count, 10)
        XCTAssertEqual(ran.filter { $0 == .person }.count, 10)
    }

    /// The invariant a third modality would have broken by construction.
    func testAtMostOneModalityRunsPerFrame() {
        // `running` is a single optional, so the only way to violate this is
        // to hand the same frame to two owners — which is what the demanded
        // set would do if it were used as the run set.
        let coordinator = VisionCoordinator()
        coordinator.register(.face, cadence: 2)
        coordinator.register(.person, cadence: 2)
        coordinator.register(.hands, cadence: 3)
        for modality in Modality.allCases {
            coordinator.addConsumer(of: modality) { true }
        }
        for _ in 0..<60 {
            let decision = coordinator.beginFrame()
            XCTAssertEqual(decision.demanded.count, 3)
            XCTAssertNotNil(decision.running)
        }
    }

    // MARK: - Demand gating

    func testAModalityNobodyWantsNeverRuns() {
        let ran = run(frames: 40, demand: [.face])
        XCTAssertTrue(ran.allSatisfy { $0 == nil || $0 == .face })
        XCTAssertEqual(ran.compactMap { $0 }.count, 20, "face still gets its cadence")
    }

    func testNoConsumersMeansNoVisionAtAll() {
        XCTAssertEqual(run(frames: 30, demand: []).compactMap { $0 }, [])
    }

    /// Several consumers, one request: the mask must survive the degradation
    /// engine switching background blur off while auto-framing still wants it.
    func testAnySingleConsumerKeepsTheModalityAlive() {
        let coordinator = VisionCoordinator()
        coordinator.register(.person, cadence: 2)
        var blurEnabled = true
        var autoFrame = false
        coordinator.addConsumer(of: .person) { blurEnabled }
        coordinator.addConsumer(of: .person) { autoFrame }

        XCTAssertTrue(coordinator.beginFrame().demanded.contains(.person))
        autoFrame = true
        blurEnabled = false
        XCTAssertTrue(coordinator.beginFrame().demanded.contains(.person),
                      "auto-framing still wants the mask")
        autoFrame = false
        let decision = coordinator.beginFrame()
        XCTAssertFalse(decision.demanded.contains(.person))
        XCTAssertTrue(decision.ended.contains(.person), "the last consumer leaving is reported")
    }

    /// `ended` fires once, on the edge — an owner that invalidated its
    /// measurement every idle frame would do it forever.
    func testDemandEndingIsReportedExactlyOnce() {
        let coordinator = VisionCoordinator()
        coordinator.register(.face, cadence: 2)
        var wanted = true
        coordinator.addConsumer(of: .face) { wanted }

        _ = coordinator.beginFrame()
        wanted = false
        XCTAssertEqual(coordinator.beginFrame().ended, [.face])
        XCTAssertEqual(coordinator.beginFrame().ended, [])
        XCTAssertEqual(coordinator.beginFrame().ended, [])
    }

    // MARK: - The Wave 3 seam

    /// A modality with a case but no registration never runs, however loudly
    /// it is demanded. That is what makes the gesture recogniser's arrival a
    /// one-line change rather than a rewrite of the schedule.
    func testAnUnregisteredModalityIsInert() {
        let coordinator = VisionCoordinator()
        coordinator.register(.face, cadence: 2)
        coordinator.addConsumer(of: .face) { true }
        coordinator.addConsumer(of: .hands) { true }
        for _ in 0..<20 {
            let decision = coordinator.beginFrame()
            XCTAssertFalse(decision.demanded.contains(.hands))
            XCTAssertNotEqual(decision.running, .hands)
        }
    }

    /// With three modalities competing nobody starves, and nobody keeps its
    /// full rate — the slip is shared. A recogniser at two-thirds rate is a
    /// slightly slower gesture; one that never runs is a broken feature.
    func testContentionSlowsEveryoneRatherThanStarvingAnyone() {
        let ran = run(frames: 90, demand: [.face, .person, .hands])
        for modality in Modality.allCases {
            let count = ran.filter { $0 == modality }.count
            XCTAssertGreaterThan(count, 15,
                                 "\(modality) ran only \(count) times in 90 frames")
        }
        XCTAssertEqual(ran.compactMap { $0 }.count, 90, "no frame is wasted")
    }

    /// Eye contact is the consumer that degrades soonest and most visibly, so
    /// the face is never left waiting more than one frame beyond its cadence
    /// even at full contention.
    func testTheFaceIsNeverStarvedByTheOthers() {
        let ran = run(frames: 120, demand: [.face, .person, .hands])
        var gap = 0
        var worst = 0
        for modality in ran {
            gap += 1
            if modality == .face {
                worst = max(worst, gap)
                gap = 0
            }
        }
        XCTAssertLessThanOrEqual(worst, 3, "the face waited \(worst) frames")
    }

    // MARK: - Cadence

    /// Alone, a modality gets exactly the duty cycle it asked for.
    func testACadenceIsHonouredWhenNothingCompetes() {
        for cadence in 1...4 {
            let ran = run(frames: 40, demand: [.hands], cadences: [.hands: cadence])
            XCTAssertEqual(ran.compactMap { $0 }.count, (40 + cadence - 1) / cadence,
                           "cadence \(cadence)")
        }
    }

    /// A modality that goes away and comes back is due immediately, but never
    /// so overdue that it shoulders the others off the next several frames.
    func testReturningDemandDoesNotHoardFrames() {
        let coordinator = VisionCoordinator()
        coordinator.register(.face, cadence: 2)
        coordinator.register(.person, cadence: 2)
        var faceWanted = true
        coordinator.addConsumer(of: .face) { faceWanted }
        coordinator.addConsumer(of: .person) { true }

        faceWanted = false
        for _ in 0..<40 { _ = coordinator.beginFrame() }
        faceWanted = true
        let resumed = (0..<8).map { _ in coordinator.beginFrame().running }
        XCTAssertEqual(resumed.filter { $0 == .face }.count, 4)
        XCTAssertEqual(resumed.filter { $0 == .person }.count, 4)
    }

    func testResetForgetsTheSchedule() {
        let coordinator = VisionCoordinator()
        coordinator.register(.face, cadence: 2)
        coordinator.addConsumer(of: .face) { true }
        XCTAssertEqual(coordinator.beginFrame().running, .face)
        XCTAssertNil(coordinator.beginFrame().running)
        coordinator.reset()
        XCTAssertEqual(coordinator.beginFrame().running, .face)
    }
}
