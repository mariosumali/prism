// GazeStageTests.swift
// PRISMTests
//
// The eye-contact correction's arithmetic (§5.6). The warp itself lives in
// Gaze.metal, but everything that decides how far to move the iris — and,
// more importantly, when to refuse to — is here.
//
// Licensed under the Apache License, Version 2.0.

import XCTest
import simd

final class GazeStageTests: XCTestCase {

    private static var sharedMetal: MetalContext?
    private static var metalError: Error?
    private static let metalOnce: Void = {
        do { sharedMetal = try MetalContext() } catch { metalError = error }
    }()

    private func makeStage() throws -> GazeStage {
        _ = Self.metalOnce
        guard let metal = Self.sharedMetal else {
            throw XCTSkip("Metal unavailable: \(String(describing: Self.metalError))")
        }
        return try GazeStage(metal: metal, faceTracker: FaceTracker(metal: metal))
    }

    /// An eye at the centre of the frame with the pupil offset by `drift`.
    private func eye(drift: SIMD2<Float>,
                     irisRadii: SIMD2<Float> = SIMD2<Float>(0.02, 0.035))
    -> GazeStage.EyeMeasurement {
        let lidCenter = SIMD2<Float>(0.4, 0.45)
        return GazeStage.EyeMeasurement(
            lidCenter: lidCenter,
            lidRadii: SIMD2<Float>(0.05, 0.03),
            irisCenter: lidCenter + drift,
            irisRadii: irisRadii)
    }

    private func settings(strength: Double = 1,
                          maxShift: Double = 1,
                          verticalBias: Double = 0) -> GazeSettings {
        var settings = GazeSettings()
        settings.strength = strength
        settings.maxShift = maxShift
        settings.verticalBias = verticalBias
        return settings
    }

    // MARK: - The core measurement

    /// A pupil already centred in its own eye opening is already looking at
    /// the lens; correcting it would aim the eyes somewhere else.
    func testCentredPupilProducesNoShift() {
        let shift = GazeStage.shift(for: eye(drift: SIMD2<Float>(0, 0)),
                                    settings: settings(),
                                    confidence: 1)
        XCTAssertEqual(shift.x, 0, accuracy: 1e-6)
        XCTAssertEqual(shift.y, 0, accuracy: 1e-6)
    }

    /// The correction removes the measured drift, so at full strength the
    /// shift is its exact negation — the iris lands back at centre.
    func testFullStrengthCancelsTheMeasuredDrift() {
        let drift = SIMD2<Float>(0.004, 0.008)
        let shift = GazeStage.shift(for: eye(drift: drift),
                                    settings: settings(),
                                    confidence: 1)
        XCTAssertEqual(shift.x, -drift.x, accuracy: 1e-6)
        XCTAssertEqual(shift.y, -drift.y, accuracy: 1e-6)
    }

    func testStrengthScalesTheCorrectionLinearly() {
        let drift = SIMD2<Float>(0.004, 0.006)
        let half = GazeStage.shift(for: eye(drift: drift),
                                   settings: settings(strength: 0.5),
                                   confidence: 1)
        let full = GazeStage.shift(for: eye(drift: drift),
                                   settings: settings(strength: 1),
                                   confidence: 1)
        XCTAssertEqual(half.x, full.x * 0.5, accuracy: 1e-6)
        XCTAssertEqual(half.y, full.y * 0.5, accuracy: 1e-6)
    }

    func testZeroStrengthIsIdentity() {
        let shift = GazeStage.shift(for: eye(drift: SIMD2<Float>(0.01, 0.01)),
                                    settings: settings(strength: 0),
                                    confidence: 1)
        XCTAssertEqual(shift.x, 0, accuracy: 1e-6)
        XCTAssertEqual(shift.y, 0, accuracy: 1e-6)
    }

    // MARK: - Clamping

    /// Past roughly half an iris width the sclera stretch shows. The clamp is
    /// a quality guarantee: a subtly-wrong eye beats an uncanny one.
    func testShiftIsClampedToMaxShiftIrisRadii() {
        let irisRadii = SIMD2<Float>(0.02, 0.035)
        // Drift far larger than the iris — an implausible measurement, or a
        // landmark glitch.
        let shift = GazeStage.shift(for: eye(drift: SIMD2<Float>(0.5, 0.5),
                                             irisRadii: irisRadii),
                                    settings: settings(maxShift: 0.5),
                                    confidence: 1)
        XCTAssertEqual(abs(shift.x), irisRadii.x * 0.5, accuracy: 1e-6)
        XCTAssertEqual(abs(shift.y), irisRadii.y * 0.5, accuracy: 1e-6)
    }

    func testMaxShiftZeroDisablesTheWarpEntirely() {
        let shift = GazeStage.shift(for: eye(drift: SIMD2<Float>(0.01, 0.01)),
                                    settings: settings(maxShift: 0),
                                    confidence: 1)
        XCTAssertEqual(shift.x, 0, accuracy: 1e-6)
        XCTAssertEqual(shift.y, 0, accuracy: 1e-6)
    }

    // MARK: - Camera height bias

    /// Positive bias means the camera sits above the screen, so the eyes need
    /// lifting — which is −y in a top-left-origin UV space.
    func testPositiveVerticalBiasLiftsTheGaze() {
        let shift = GazeStage.shift(for: eye(drift: SIMD2<Float>(0, 0)),
                                    settings: settings(verticalBias: 1),
                                    confidence: 1)
        XCTAssertLessThan(shift.y, 0)
        XCTAssertEqual(shift.x, 0, accuracy: 1e-6)
    }

    func testNegativeVerticalBiasLowersTheGaze() {
        let shift = GazeStage.shift(for: eye(drift: SIMD2<Float>(0, 0)),
                                    settings: settings(verticalBias: -1),
                                    confidence: 1)
        XCTAssertGreaterThan(shift.y, 0)
    }

    // MARK: - Confidence

    /// Detection flickers. A correction that pops on and off is more
    /// distracting than none, so both edges are faded by confidence.
    func testConfidenceScalesTheShift() {
        let drift = SIMD2<Float>(0.004, 0.004)
        let full = GazeStage.shift(for: eye(drift: drift),
                                   settings: settings(), confidence: 1)
        let half = GazeStage.shift(for: eye(drift: drift),
                                   settings: settings(), confidence: 0.5)
        XCTAssertEqual(half.x, full.x * 0.5, accuracy: 1e-6)
        XCTAssertEqual(half.y, full.y * 0.5, accuracy: 1e-6)
    }

    func testZeroConfidenceProducesNoShift() {
        let shift = GazeStage.shift(for: eye(drift: SIMD2<Float>(0.01, 0.01)),
                                    settings: settings(), confidence: 0)
        XCTAssertEqual(shift.x, 0, accuracy: 1e-6)
        XCTAssertEqual(shift.y, 0, accuracy: 1e-6)
    }

    // MARK: - Settings defaults

    func testDefaultsAreConservative() {
        let defaults = GazeSettings()
        XCTAssertLessThan(defaults.strength, 1, "a gaze nailed to the lens reads as a stare")
        XCTAssertLessThanOrEqual(defaults.maxShift, 0.5)
        XCTAssertGreaterThan(defaults.smoothing, 0.5, "iris jitter is visible")
        XCTAssertGreaterThan(defaults.verticalBias, 0, "laptops put the camera above the screen")
    }

    // MARK: - Scheduling

    /// The stage schedules its own landmark detection from encode(), so it
    /// has to ask for the pass *before* it is tracking anything. Declining
    /// until tracked is a deadlock: no pass, no detection, no tracking, so
    /// the correction never starts.
    func testWantsEncodeBeforeTrackingIsAcquired() throws {
        let stage = try makeStage()
        XCTAssertFalse(stage.wantsEncode(), "disabled by default")
        stage.isEnabled = true
        XCTAssertFalse(stage.isTracking, "nothing detected yet")
        XCTAssertTrue(stage.wantsEncode(), "the acquiring pass must still run")
        stage.settings.strength = 0
        XCTAssertFalse(stage.wantsEncode(), "zero strength is off")
    }
}
