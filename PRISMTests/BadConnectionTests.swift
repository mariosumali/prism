// BadConnectionTests.swift
// PRISMTests
//
// The simulated bad connection (§5.14): its severity arithmetic, the
// frame-rate gate, the forward-compatibility contract every persisted type
// here follows, and its place in the chain and the menu bar.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class BadConnectionTests: XCTestCase {

    // MARK: - Defaults

    /// A feed that pixelates but answers instantly reads as a filter, not a
    /// network — so the delay and the choppiness both default on.
    func testDelayAndFrameDropsAreTheDefault() {
        XCTAssertTrue(ConnectionSettings().addsLag)
        XCTAssertTrue(ConnectionSettings().dropsFrames)
    }

    /// A struggling connection is behind, not absent: the default delay is
    /// well under the lag switch's three seconds.
    func testDefaultDelayIsShorterThanTheLagSwitchDefault() {
        XCTAssertLessThan(ConnectionSettings().clampedLagMs,
                          LagSettings().clampedDelayMs)
    }

    // MARK: - Clamping

    /// A severity of zero would be an "on" switch that changes nothing — the
    /// §8.7 inert-toggle problem — so the clamp floors above it.
    func testSeverityClampsAboveZero() {
        var connection = ConnectionSettings()
        connection.severity = 0
        XCTAssertGreaterThan(connection.clampedSeverity, 0)
        connection.severity = -3
        XCTAssertGreaterThan(connection.clampedSeverity, 0)
        connection.severity = 99
        XCTAssertEqual(connection.clampedSeverity, 1)
    }

    func testDelayClampsToTheLagSwitchRange() {
        var connection = ConnectionSettings()
        connection.lagMs = 0
        XCTAssertEqual(connection.clampedLagMs, 200)
        connection.lagMs = 999_999
        XCTAssertEqual(connection.clampedLagMs, 10_000)
        XCTAssertEqual(connection.lagSeconds, 10, accuracy: 1e-9)
    }

    /// The delay rides the §5.12 transport, so it is bounded by the same
    /// rolling buffer and audio delay line.
    func testDelayFitsTheBufferAndTheAudioLine() {
        XCTAssertLessThanOrEqual(ConnectionSettings().lagSeconds,
                                 ReplaySettings().clampedBufferSeconds)
        var connection = ConnectionSettings()
        connection.lagMs = 10_000
        XCTAssertLessThanOrEqual(connection.lagSeconds, AudioCapture.maxDelaySeconds)
    }

    // MARK: - Severity mappings

    /// One knob drives all three degradations in the same direction; a
    /// severity that made the picture blockier but smoother would be a
    /// failure mode no network produces.
    func testHigherSeverityIsWorseInEveryDimension() {
        var mild = ConnectionSettings()
        mild.severity = 0.2
        var harsh = ConnectionSettings()
        harsh.severity = 0.9

        XCTAssertGreaterThan(harsh.blockSize(forHeight: 1080),
                             mild.blockSize(forHeight: 1080))
        XCTAssertLessThan(harsh.posterizeLevels, mild.posterizeLevels)
        XCTAssertLessThan(harsh.throttledFps, mild.throttledFps)
        XCTAssertGreaterThan(harsh.artifactAmount, mild.artifactAmount)
        XCTAssertLessThan(harsh.updateFraction, mild.updateFraction,
                          "worse connections refresh fewer blocks per frame")
    }

    /// The degraded picture must stay a picture: blocks at least visible but
    /// finite, at least two colour steps, and a frame rate that never reaches
    /// zero — a frozen frame is the §5.2 freeze, not a bad connection.
    func testMappingsStayInRenderableBounds() {
        for severity in stride(from: -1.0, through: 2.0, by: 0.1) {
            var connection = ConnectionSettings()
            connection.severity = severity
            XCTAssertGreaterThanOrEqual(connection.blockSize(forHeight: 1080), 2)
            XCTAssertLessThanOrEqual(connection.blockSize(forHeight: 1080), 64)
            XCTAssertGreaterThanOrEqual(connection.posterizeLevels, 2)
            XCTAssertGreaterThan(connection.throttledFps, 0)
            // Some blocks must always refresh (or the picture freezes, which
            // is §5.2's job) and the fraction is a fraction.
            XCTAssertGreaterThan(connection.updateFraction, 0)
            XCTAssertLessThanOrEqual(connection.updateFraction, 1)
        }
    }

    /// Block size is stated in destination pixels, so the same severity must
    /// look the same at 720p and 1080p — it scales with frame height.
    func testBlockSizeScalesWithFrameHeight() {
        let connection = ConnectionSettings()
        XCTAssertEqual(connection.blockSize(forHeight: 540),
                       connection.blockSize(forHeight: 1080) / 2,
                       accuracy: 1e-9)
    }

    // MARK: - Frame gate

    func testGateRefreshesImmediatelyOnFirstFrame() {
        var gate = ConnectionFrameGate()
        XCTAssertTrue(gate.shouldRefresh(at: 100, fps: 10))
    }

    /// Intervals are jittered, but never shorter than 0.35× the nominal one
    /// — so right after a refresh the gate always holds, and it always
    /// reopens eventually.
    func testGateHoldsRightAfterARefreshAndAlwaysReopens() {
        var gate = ConnectionFrameGate()
        XCTAssertTrue(gate.shouldRefresh(at: 100, fps: 4))          // anchor
        XCTAssertFalse(gate.shouldRefresh(at: 100.05, fps: 4))      // < 0.35 × 250 ms
        var t = 100.05
        var reopened = false
        while t < 102 {                                              // ≤ 7 intervals away
            t += 0.005
            if gate.shouldRefresh(at: t, fps: 4) {
                reopened = true
                break
            }
        }
        XCTAssertTrue(reopened, "even a stall is bounded at 7 nominal intervals")
    }

    /// A metronomic refresh is a strobe, not a network: over a simulated
    /// minute the cadence must vary, include at least one multi-interval
    /// stall, and still average out near the nominal rate.
    func testGateCadenceIsIrregularButHonestOnAverage() {
        var gate = ConnectionFrameGate()
        let fps = 10.0
        var refreshTimes: [Double] = []
        var t = 0.0
        while t < 60 {                       // 5 ms scan, ~30 fps camera is coarser
            if gate.shouldRefresh(at: t, fps: fps) { refreshTimes.append(t) }
            t += 0.005
        }
        let intervals = zip(refreshTimes.dropFirst(), refreshTimes).map(-)
        XCTAssertGreaterThan(Set(intervals.map { ($0 * 1000).rounded() }).count, 3,
                             "intervals must vary, not tick")
        XCTAssertGreaterThanOrEqual(intervals.max() ?? 0, 0.25,
                                    "a burst of loss stalls for several intervals")
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        XCTAssertGreaterThan(mean, 0.5 / fps)
        XCTAssertLessThan(mean, 2.5 / fps,
                          "the configured rate stays an honest mean")
    }

    /// A clock stepping backwards (sleep, adjustment) re-anchors rather than
    /// stalling until it catches back up to a future timestamp.
    func testGateRecoversFromABackwardsClock() {
        var gate = ConnectionFrameGate()
        XCTAssertTrue(gate.shouldRefresh(at: 100, fps: 10))
        XCTAssertTrue(gate.shouldRefresh(at: 50, fps: 10))
        // 20 ms is under the smallest possible jittered interval (35 ms), so
        // this holds regardless of what the generator drew.
        XCTAssertFalse(gate.shouldRefresh(at: 50.02, fps: 10))
    }

    func testGateResetRefreshesImmediately() {
        var gate = ConnectionFrameGate()
        XCTAssertTrue(gate.shouldRefresh(at: 100, fps: 10))
        gate.reset()
        XCTAssertTrue(gate.shouldRefresh(at: 100.01, fps: 10))
    }

    /// Same seed, same cadence: the jitter must be reproducible, or a flaky
    /// visual bug could never be replayed.
    func testGateCadenceIsDeterministicForASeed() {
        var a = ConnectionFrameGate(seed: 42)
        var b = ConnectionFrameGate(seed: 42)
        var t = 0.0
        while t < 10 {
            XCTAssertEqual(a.shouldRefresh(at: t, fps: 10),
                           b.shouldRefresh(at: t, fps: 10))
            t += 0.01
        }
    }

    // MARK: - Round trips

    func testConnectionSettingsRoundTripThroughJSON() throws {
        var settings = StudioSettings()
        settings.connection.severity = 0.85
        settings.connection.dropsFrames = false
        settings.connection.addsLag = false
        settings.connection.lagMs = 2500

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    /// A studio file written before the bad connection existed.
    func testStudioSettingsFromBeforeTheFeatureStillDecode() throws {
        let json = Data(#"{"replay":{"isArmed":true},"lag":{"delayMs":1500}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertTrue(decoded.replay.isArmed)
        XCTAssertEqual(decoded.lag.delayMs, 1500)
        XCTAssertEqual(decoded.connection, ConnectionSettings(),
                       "the new section takes its defaults")
    }

    func testPartialConnectionObjectKeepsTheFieldsItHas() throws {
        let json = Data(#"{"connection":{"severity":0.9}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertEqual(decoded.connection.severity, 0.9)
        XCTAssertTrue(decoded.connection.addsLag, "absent field takes its default")
        XCTAssertTrue(decoded.connection.dropsFrames)
    }

    // MARK: - Chain position and status surfaces

    /// The degrade runs after everything the user composes and before the
    /// always-on output fit: a crisp overlay on a pixelated face would give
    /// the game away instantly.
    func testConnectionIsTheLastUserStageBeforeOutputFit() {
        XCTAssertGreaterThan(StageID.connection, .overlay)
        XCTAssertLessThan(StageID.connection, .outputFit)
        XCTAssertEqual(StageID.allCases.max(), .outputFit)
    }

    /// Severity is floored above zero, so an engaged stage always changes
    /// the picture — it can never be inert.
    func testAnEngagedConnectionIsNeverInert() {
        var config = PipelineConfiguration()
        config.flags[.connection] = StageFlags(enabled: true)
        XCTAssertFalse(config.isInert(.connection))
        XCTAssertNil(config.inertReason(.connection))
    }

    /// Every state where the picture on air is not the live camera gets its
    /// own glyph, because forgetting you are in one is the damaging failure.
    func testBadConnectionHasADistinctMenuBarState() {
        let states: [MenuBarState] = [.replaying, .away, .lagging, .frozen,
                                      .panicked, .badConnection]
        XCTAssertEqual(Set(states.map(String.init(describing:))).count, states.count)
    }
}
