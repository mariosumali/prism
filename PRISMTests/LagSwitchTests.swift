// LagSwitchTests.swift
// PRISMTests
//
// The deliberate delay line (§5.12): its settings arithmetic, the
// forward-compatibility contract it inherits, and the reporting rule that
// keeps the latency meter honest while several seconds of requested delay
// are in flight.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class LagSwitchTests: XCTestCase {

    // MARK: - Defaults

    /// A switch you hold is what the name describes, and it cannot be left on
    /// by accident.
    func testHoldToLagIsTheDefault() {
        XCTAssertTrue(LagSettings().holdToLag)
    }

    /// Video three seconds behind live audio does not read as a bad
    /// connection, it reads as broken software.
    func testAudioIsDelayedByDefault() {
        XCTAssertTrue(LagSettings().delaysAudio)
    }

    /// Snap-back is what a recovering connection actually does, and it is the
    /// one release with no audio/video skew during the recovery.
    func testSnapBackIsTheDefaultRelease() {
        XCTAssertEqual(LagSettings().release, .snapBack)
    }

    // MARK: - Clamping

    func testDelayClampsToTheSupportedRange() {
        var lag = LagSettings()
        lag.delayMs = 0
        XCTAssertEqual(lag.clampedDelayMs, 200)
        lag.delayMs = 999_999
        XCTAssertEqual(lag.clampedDelayMs, 10_000)
        lag.delayMs = 2500
        XCTAssertEqual(lag.clampedDelayMs, 2500)
        XCTAssertEqual(lag.delaySeconds, 2.5, accuracy: 1e-9)
    }

    /// A catch-up at 1× would never catch up.
    func testCatchUpRateIsAlwaysFasterThanRealTime() {
        var lag = LagSettings()
        lag.catchUpRate = 0.5
        XCTAssertGreaterThan(lag.clampedCatchUpRate, 1)
        lag.catchUpRate = 100
        XCTAssertEqual(lag.clampedCatchUpRate, 4)
    }

    /// The delay is held in the rolling buffer, so the whole feature is
    /// bounded by it — the audio line is sized to match.
    func testMaximumDelayFitsTheBufferAndTheAudioLine() {
        XCTAssertLessThanOrEqual(LagSettings().clampedDelayMs / 1000,
                                 ReplaySettings().clampedBufferSeconds)
        var lag = LagSettings()
        lag.delayMs = 10_000
        XCTAssertLessThanOrEqual(lag.delaySeconds, AudioCapture.maxDelaySeconds)
    }

    // MARK: - Honest reporting (§6)

    /// The meter measures what PRISM costs you involuntarily. Folding a
    /// requested three-second delay into it would peg it permanently and
    /// destroy the one number this app exists to keep honest — so the delay
    /// is reported beside it, and only the combined figure includes both.
    func testDeliberateDelayIsReportedSeparatelyFromMeasuredCost() {
        let report = LatencyReport(totalAddedMs: 7.2,
                                   budgetMs: 13.3,
                                   deliberateDelayMs: 3000)
        XCTAssertEqual(report.totalAddedMs, 7.2, accuracy: 1e-9)
        XCTAssertLessThan(report.totalAddedMs, report.budgetMs,
                          "a deliberate delay must not push the meter over budget")
        XCTAssertEqual(report.endToEndMs, 3007.2, accuracy: 1e-9)
    }

    func testNoDelayLeavesEndToEndEqualToMeasuredCost() {
        let report = LatencyReport(totalAddedMs: 7.2)
        XCTAssertEqual(report.endToEndMs, report.totalAddedMs, accuracy: 1e-9)
        XCTAssertEqual(report.deliberateDelayMs, 0)
    }

    /// A report written before the field existed must still decode — the same
    /// rule every persisted type here follows.
    func testLatencyReportDefaultsToNoDeliberateDelay() {
        XCTAssertEqual(LatencyReport().deliberateDelayMs, 0)
    }

    // MARK: - Round trips

    func testLagSettingsRoundTripsThroughJSON() throws {
        var settings = StudioSettings()
        settings.lag.delayMs = 4500
        settings.lag.delaysAudio = false
        settings.lag.release = .catchUp
        settings.lag.catchUpRate = 3
        settings.lag.holdToLag = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    /// A studio file written before the lag switch existed.
    func testStudioSettingsFromBeforeTheLagSwitchStillDecodes() throws {
        let json = Data(#"{"replay":{"isArmed":true},"away":{"loopSeconds":6}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertTrue(decoded.replay.isArmed)
        XCTAssertEqual(decoded.away.loopSeconds, 6)
        XCTAssertEqual(decoded.lag, LagSettings(), "the new section takes its defaults")
    }

    func testPartialLagObjectKeepsTheFieldsItHas() throws {
        let json = Data(#"{"lag":{"delayMs":1500}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertEqual(decoded.lag.delayMs, 1500)
        XCTAssertTrue(decoded.lag.delaysAudio, "absent field takes its default")
        XCTAssertEqual(decoded.lag.release, .snapBack)
    }

    // MARK: - Live retargeting (§5.12)

    /// Deepening an engaged delay must never rewind: the base stays on the
    /// frame currently on air and the difference becomes a fresh hold.
    func testDeepeningHoldsInPlaceInsteadOfRewinding() throws {
        // On air: base 100, elapsed 5 → frame at 105; live edge 108 → 3 s
        // behind. Retarget to 5 s.
        let rebased = try XCTUnwrap(ReplayPlayer.retarget(
            base: 100, elapsed: 5, newest: 108, target: 5))
        XCTAssertEqual(rebased.base, 105, accuracy: 1e-9,
                       "position is continuous — no jump backwards")
        XCTAssertEqual(rebased.lag, 2, accuracy: 1e-9,
                       "only the difference is held, not the whole delay")
    }

    /// Shortening drops exactly the difference in backlog — a partial
    /// snap-back — and leaves nothing to absorb.
    func testShorteningDropsExactlyTheDifference() throws {
        // 3 s behind (as above); retarget to 1 s.
        let rebased = try XCTUnwrap(ReplayPlayer.retarget(
            base: 100, elapsed: 5, newest: 108, target: 1))
        XCTAssertEqual(rebased.base, 107, accuracy: 1e-9,
                       "jumps forward by the 2 s of dropped backlog")
        XCTAssertEqual(rebased.lag, 0, accuracy: 1e-9)
    }

    /// Float noise is not intent: sub-10 ms changes do nothing, so a finger
    /// resting on the slider cannot make the clock churn.
    func testTinyChangesAreIgnored() {
        XCTAssertNil(ReplayPlayer.retarget(base: 100, elapsed: 5,
                                           newest: 108, target: 3.005))
    }

    /// The threshold sits below one slider step (50 ms) and far below
    /// anything typed, so every deliberate millisecond figure is applied —
    /// a field that reports a delay it did not apply would be lying about
    /// what is on air.
    func testTypedMillisecondChangesAreApplied() throws {
        // One 50 ms slider step down from 3 s behind.
        let step = try XCTUnwrap(ReplayPlayer.retarget(
            base: 100, elapsed: 5, newest: 108, target: 2.95))
        XCTAssertEqual(step.base, 105.05, accuracy: 1e-9)

        // A typed 3040 ms, 40 ms deeper than the 3 s on air.
        let typed = try XCTUnwrap(ReplayPlayer.retarget(
            base: 100, elapsed: 5, newest: 108, target: 3.04))
        XCTAssertEqual(typed.lag, 0.04, accuracy: 1e-9)
    }

    /// A shorten past live clamps to live rather than into the future.
    func testShorteningPastLiveClampsToLive() throws {
        let rebased = try XCTUnwrap(ReplayPlayer.retarget(
            base: 100, elapsed: 5, newest: 108, target: -4))
        XCTAssertEqual(rebased.base, 108, accuracy: 1e-9,
                       "never ahead of the newest buffered frame")
        XCTAssertEqual(rebased.lag, 0, accuracy: 1e-9)
    }

    // MARK: - Transport exclusivity

    /// Lag is a distinct on-air state, not a flavour of replay: the menu bar
    /// has to be able to say which one you are in.
    func testLagIsItsOwnReplayMode() {
        XCTAssertNotEqual(ReplayMode.lag, .replay)
        XCTAssertNotEqual(ReplayMode.lag, .away)
        XCTAssertNotEqual(ReplayMode.lag, .idle)
    }

    /// Every state where the picture on air is not live gets its own glyph,
    /// because forgetting you are in one is the damaging failure.
    func testEverySubstitutionStateHasADistinctMenuBarState() {
        let states: [MenuBarState] = [.replaying, .away, .lagging, .frozen, .panicked]
        XCTAssertEqual(Set(states.map(String.init(describing:))).count, states.count)
    }
}
