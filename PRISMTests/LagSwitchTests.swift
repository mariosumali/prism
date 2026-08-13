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
