// PresenceWatcherTests.swift
// PRISMTests
//
// The §5.28 hysteresis, against a clock instead of a room.
//
// Every test below is really the same test asked from a different angle: does
// this fire when somebody genuinely left, and does it stay silent for all the
// ordinary things that empty a frame for a moment. The asymmetry is the
// feature — a late trigger costs nothing, a false one puts a recording of the
// user on air while they are sitting there talking — so the cases that must
// NOT fire outnumber the ones that must.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class PresenceWatcherTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func settings(away: Double = 6, back: Double = 1,
                          coverage: Double = 0.04) -> PresenceSettings {
        var settings = PresenceSettings()
        settings.awaySeconds = away
        settings.returnSeconds = back
        settings.coverage = coverage
        return settings
    }

    /// Feeds one observation a second for `seconds`, returning every edge.
    @discardableResult
    private func feed(_ watcher: PresenceWatcher, coverage: Double,
                      seconds: Int, from offset: Double,
                      settings: PresenceSettings) -> [PresenceWatcher.Transition] {
        (0..<seconds).map { step in
            watcher.observe(coverage: coverage, settings: settings,
                            at: start.addingTimeInterval(offset + Double(step)))
        }
    }

    // MARK: - Nothing to go on

    /// Before anything has been measured there is no evidence either way, and
    /// `unknown` is what says so. A watcher nobody has fed must not read as
    /// an empty room.
    func testAFreshWatcherKnowsNothing() {
        XCTAssertEqual(PresenceWatcher().state, .unknown)
    }

    /// The first sighting settles the state and announces nothing: there is
    /// nothing on air to undo.
    func testTheFirstSightingIsNotAReturn() {
        let watcher = PresenceWatcher()
        let edges = feed(watcher, coverage: 0.2, seconds: 5, from: 0,
                         settings: settings())
        XCTAssertEqual(watcher.state, .present)
        XCTAssertTrue(edges.allSatisfy { $0 == .none })
    }

    // MARK: - Leaving

    func testLeavingFiresOnceTheThresholdIsPast() {
        let watcher = PresenceWatcher()
        let config = settings()
        feed(watcher, coverage: 0.2, seconds: 3, from: 0, settings: config)
        let edges = feed(watcher, coverage: 0, seconds: 10, from: 3,
                         settings: config)
        XCTAssertEqual(edges.filter { $0 == .left }.count, 1,
                       "leaving is an edge, not a level")
        XCTAssertEqual(watcher.state, .absent)
    }

    /// The threshold is a duration, not a count of observations: five seconds
    /// of absence with a six-second threshold is somebody reaching for a mug.
    func testAShortAbsenceNeverFires() {
        let watcher = PresenceWatcher()
        let config = settings()
        feed(watcher, coverage: 0.2, seconds: 3, from: 0, settings: config)
        let edges = feed(watcher, coverage: 0, seconds: 5, from: 3,
                         settings: config)
        XCTAssertTrue(edges.allSatisfy { $0 == .none })
        XCTAssertEqual(watcher.state, .present)
    }

    /// Leaning out of shot and back does not accumulate: the clock restarts
    /// on the first frame the user is in again, so four seconds out, one
    /// second in, and four seconds out is not eight seconds away.
    func testAbsenceDoesNotAccumulateAcrossASighting() {
        let watcher = PresenceWatcher()
        let config = settings()
        feed(watcher, coverage: 0.2, seconds: 2, from: 0, settings: config)
        feed(watcher, coverage: 0, seconds: 4, from: 2, settings: config)
        feed(watcher, coverage: 0.2, seconds: 1, from: 6, settings: config)
        let edges = feed(watcher, coverage: 0, seconds: 4, from: 7,
                         settings: config)
        XCTAssertTrue(edges.allSatisfy { $0 == .none })
        XCTAssertEqual(watcher.state, .present)
    }

    /// Enabled while the chair is already empty, the feature still works —
    /// that is literally what it is for — but it takes the full threshold to
    /// get there rather than firing on the first observation.
    func testWatchingAnAlreadyEmptyFrameFiresOnlyAfterTheThreshold() {
        let watcher = PresenceWatcher()
        let config = settings()
        let edges = feed(watcher, coverage: 0, seconds: 10, from: 0,
                         settings: config)
        XCTAssertEqual(edges.prefix(6).filter { $0 == .left }.count, 0)
        XCTAssertEqual(edges.filter { $0 == .left }.count, 1)
    }

    // MARK: - Coming back

    func testComingBackIsFasterThanLeaving() {
        let watcher = PresenceWatcher()
        let config = settings(away: 6, back: 1)
        feed(watcher, coverage: 0.2, seconds: 2, from: 0, settings: config)
        feed(watcher, coverage: 0, seconds: 8, from: 2, settings: config)
        XCTAssertEqual(watcher.state, .absent)

        let back = watcher.observe(coverage: 0.2, settings: config,
                                   at: start.addingTimeInterval(11))
        XCTAssertEqual(back, .returned, "one second back is back")
        XCTAssertEqual(watcher.state, .present)
    }

    /// A single stray detection in an empty room must not release whatever is
    /// on air; the return threshold is a duration too.
    func testOneStrayDetectionDoesNotEndTheAbsence() {
        let watcher = PresenceWatcher()
        let config = settings(away: 6, back: 3)
        feed(watcher, coverage: 0.2, seconds: 2, from: 0, settings: config)
        feed(watcher, coverage: 0, seconds: 8, from: 2, settings: config)

        let stray = watcher.observe(coverage: 0.2, settings: config,
                                    at: start.addingTimeInterval(11))
        XCTAssertEqual(stray, .none)
        XCTAssertEqual(watcher.state, .absent)
    }

    // MARK: - The dead band

    /// A subject sitting exactly on the coverage threshold flaps across it
    /// with the detector's own wobble. Between the two thresholds nothing is
    /// decided, so neither clock runs and the state holds.
    func testASubjectOnTheThresholdHoldsItsState() {
        let watcher = PresenceWatcher()
        let config = settings(coverage: 0.04)
        feed(watcher, coverage: 0.2, seconds: 2, from: 0, settings: config)
        // 0.035 is under the present threshold and over the release one.
        let edges = feed(watcher, coverage: 0.035, seconds: 30, from: 2,
                         settings: config)
        XCTAssertTrue(edges.allSatisfy { $0 == .none })
        XCTAssertEqual(watcher.state, .present, "the dead band decides nothing")
    }

    // MARK: - Gaps in the evidence

    /// The failure this cap exists for: the Mac sleeps, the camera comes
    /// back, and the first observation carries ten minutes of elapsed time
    /// with it. Integrating that gap would fire the away loop at the exact
    /// moment the user sat down.
    func testALongGapCannotFireOnASingleObservation() {
        let watcher = PresenceWatcher()
        let config = settings()
        feed(watcher, coverage: 0.2, seconds: 2, from: 0, settings: config)
        let edge = watcher.observe(coverage: 0, settings: config,
                                   at: start.addingTimeInterval(600))
        XCTAssertEqual(edge, .none)
        XCTAssertEqual(watcher.state, .present)
    }

    /// Nor can a run of them. Two observations a minute apart are two minutes
    /// of wall clock and four seconds of evidence, because each is capped —
    /// which turns a starved detector into a delayed trigger rather than a
    /// false one, and that is the whole trade.
    func testSparseObservationsCountAsTheCappedStepRatherThanTheGap() {
        let watcher = PresenceWatcher()
        let config = settings(away: 6)
        feed(watcher, coverage: 0.2, seconds: 1, from: 0, settings: config)
        var edges: [PresenceWatcher.Transition] = []
        for step in 1...2 {
            edges.append(watcher.observe(coverage: 0, settings: config,
                                         at: start.addingTimeInterval(60 * Double(step))))
        }
        XCTAssertTrue(edges.allSatisfy { $0 == .none })
        XCTAssertEqual(watcher.state, .present)
    }

    // MARK: - Reset

    func testResetForgetsEverything() {
        let watcher = PresenceWatcher()
        let config = settings()
        feed(watcher, coverage: 0.2, seconds: 2, from: 0, settings: config)
        feed(watcher, coverage: 0, seconds: 8, from: 2, settings: config)
        XCTAssertEqual(watcher.state, .absent)

        watcher.reset()
        XCTAssertEqual(watcher.state, .unknown)
        // And the absence clock with it: five seconds of empty frame after a
        // reset is not the tail of the eight before it.
        let edges = feed(watcher, coverage: 0, seconds: 5, from: 20,
                         settings: config)
        XCTAssertTrue(edges.allSatisfy { $0 == .none })
    }

    // MARK: - Settings

    /// Both thresholds are read per observation, so dragging a slider while
    /// the watcher is running takes effect on the next sample rather than at
    /// the next departure.
    func testClampsAreHonouredRatherThanRawValues() {
        let watcher = PresenceWatcher()
        var config = settings()
        config.awaySeconds = -100          // clamps to 2
        feed(watcher, coverage: 0.2, seconds: 2, from: 0, settings: config)
        let edges = feed(watcher, coverage: 0, seconds: 4, from: 2,
                         settings: config)
        XCTAssertEqual(edges.filter { $0 == .left }.count, 1)
    }

    /// Ships off, and off means the detector is never even demanded.
    func testPresenceIsInertByDefault() {
        XCTAssertEqual(PresenceSettings().action, .none)
        XCTAssertFalse(PresenceSettings().notifiesWhenAway)
        XCTAssertFalse(PresenceSettings().isActive)
    }

    /// The nudge is a reason to watch all by itself — it is the one presence
    /// behaviour that changes nothing on air.
    func testTheNudgeAloneArmsTheDetector() {
        var settings = PresenceSettings()
        settings.notifiesWhenAway = true
        XCTAssertTrue(settings.isActive)
        XCTAssertEqual(settings.action, .none)
    }
}
