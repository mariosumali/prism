// AutoFramerTests.swift
// PRISMTests
//
// Verifies the auto-framing servo's critically damped motion (§5.4, 1.5s
// time constant). The controller is closed-loop — the subject box it sees is
// measured downstream of the geometry it drives — so the tests simulate that
// loop: a subject whose on-screen height is (unzoomed height × current
// zoom). That makes the implied target zoom a constant step, and the
// response must match the critically damped analytic curve:
// x(t) = 1 − (1 + t/τ)·e^(−t/τ), which passes ~26% at t = τ and reaches
// 63% only near t ≈ 2.15τ (second-order, not a first-order exponential).
// No overshoot, monotonic approach, instant reset, decay to identity on a
// lost subject.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import XCTest

final class AutoFramerTests: XCTestCase {

    private let dt = 1.0 / 30.0
    private let tau = 1.5

    /// Subject box centered in the frame with the given on-screen height.
    private func centeredBox(height: Double) -> CGRect {
        let width = height * 0.75
        return CGRect(x: 0.5 - width / 2, y: 0.5 - height / 2,
                      width: width, height: height)
    }

    /// Runs the closed loop for `frames` iterations against a subject whose
    /// unzoomed height fraction is `baseHeight`, returning the zoom history
    /// (index 0 = initial state probed via a dt-0 update).
    private func runClosedLoop(_ framer: AutoFramer,
                               baseHeight: Double,
                               frames: Int) -> [Double] {
        var zoom = framer.update(subjectBox: nil, dt: 0).zoom   // state probe
        var history = [zoom]
        for _ in 0..<frames {
            let box = centeredBox(height: baseHeight * zoom)
            zoom = framer.update(subjectBox: box, dt: dt).zoom
            history.append(zoom)
        }
        return history
    }

    // MARK: - Step response

    func testStepConvergesToTargetZoom() {
        let framer = AutoFramer()
        // Unzoomed subject height 0.4 → target zoom 0.6 / 0.4 = 1.5.
        let history = runClosedLoop(framer, baseHeight: 0.4, frames: 450) // 15s
        XCTAssertEqual(history.last!, 1.5, accuracy: 0.01,
                       "must settle on the 60%-height framing")
    }

    func testStepResponseIsMonotonicWithoutOvershoot() {
        let framer = AutoFramer()
        let target = 1.5
        let history = runClosedLoop(framer, baseHeight: 0.4, frames: 450)

        for i in 1..<history.count {
            XCTAssertGreaterThanOrEqual(history[i], history[i - 1] - 1e-9,
                                        "zoom must approach monotonically (frame \(i))")
        }
        // Critically damped ⇒ zero overshoot; allow ~2% numerical headroom.
        XCTAssertLessThanOrEqual(history.max()!, target * 1.02)
        XCTAssertLessThanOrEqual(history.max()!, target + 1e-3,
                                 "critically damped motion must not overshoot")
    }

    func testProgressMatchesCriticallyDampedCurve() throws {
        let framer = AutoFramer()
        let target = 1.5
        let history = runClosedLoop(framer, baseHeight: 0.4, frames: 200)
        func progress(_ index: Int) -> Double {
            (history[index] - 1.0) / (target - 1.0)
        }

        // At t = τ = 1.5s (45 frames): analytic 1 − 2e⁻¹ ≈ 26.4%
        // (simulated discrete value ≈ 27.1%).
        let atTau = progress(45)
        XCTAssertGreaterThan(atTau, 0.20)
        XCTAssertLessThan(atTau, 0.34)

        // 63% progress arrives near t ≈ 2.15τ ≈ 3.2s — the second-order
        // signature (a first-order lag would already be there at 1τ).
        let index63 = history.firstIndex { ($0 - 1.0) / (target - 1.0) >= 0.632 }
        let t63 = Double(try XCTUnwrap(index63)) * dt
        XCTAssertGreaterThan(t63, 2.7)
        XCTAssertLessThan(t63, 3.7)
    }

    func testCenteredSubjectNeverInducesPan() {
        let framer = AutoFramer()
        var zoom = 1.0
        for _ in 0..<300 {
            let out = framer.update(subjectBox: centeredBox(height: 0.4 * zoom),
                                    dt: dt)
            zoom = out.zoom
            XCTAssertEqual(out.panX, 0, accuracy: 1e-9)
            XCTAssertEqual(out.panY, 0, accuracy: 1e-9)
        }
    }

    func testZoomStaysWithinClampRange() {
        let framer = AutoFramer()
        // A tiny subject asks for far more than 2.5× — the clamp must hold.
        var zoom = 1.0
        for _ in 0..<600 {
            // On-screen height stays small regardless of zoom (subject far
            // away): implied target = 0.6/0.05 = 12×, clamped to 2.5.
            zoom = framer.update(subjectBox: centeredBox(height: 0.05), dt: dt).zoom
            XCTAssertLessThanOrEqual(zoom, 2.5 + 1e-9)
            XCTAssertGreaterThanOrEqual(zoom, 1.0 - 1e-9)
        }
        XCTAssertEqual(zoom, 2.5, accuracy: 0.02, "must settle at the zoom ceiling")
    }

    // MARK: - Subject lost → decay to identity

    func testNilSubjectDecaysZoomTowardIdentity() {
        let framer = AutoFramer()
        let history = runClosedLoop(framer, baseHeight: 0.4, frames: 300)
        XCTAssertGreaterThan(history.last!, 1.4, "precondition: converged near 1.5")

        var zoom = history.last!
        var decay: [Double] = []
        for _ in 0..<450 {                     // 15s of lost subject
            zoom = framer.update(subjectBox: nil, dt: dt).zoom
            decay.append(zoom)
        }
        for i in 1..<decay.count {
            XCTAssertLessThanOrEqual(decay[i], decay[i - 1] + 1e-9,
                                     "decay must be monotonic (frame \(i))")
        }
        XCTAssertEqual(decay.last!, 1.0, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(decay.min()!, 1.0 - 1e-9,
                                    "zoom never dips below identity")
    }

    func testNilSubjectDecaysPanTowardZero() {
        let framer = AutoFramer()
        // Build up zoom and pan with an off-center subject. The box stays
        // reported off-center, so pan keeps integrating toward the clamp —
        // all that matters here is that pan becomes decidedly non-zero.
        var zoom = 1.0
        var panX = 0.0
        for _ in 0..<300 {
            let height = 0.4 * zoom
            let box = CGRect(x: 0.62 - 0.15, y: 0.5 - height / 2,
                             width: 0.3, height: height)   // midX = 0.62
            let out = framer.update(subjectBox: box, dt: dt)
            zoom = out.zoom
            panX = out.panX
        }
        XCTAssertGreaterThan(panX, 0.05, "precondition: pan followed the subject")

        for _ in 0..<450 {
            let out = framer.update(subjectBox: nil, dt: dt)
            panX = out.panX
        }
        XCTAssertEqual(panX, 0, accuracy: 0.01, "pan eases back to center")
    }

    func testTinySubjectBoxIsIgnored() {
        // Boxes with height ≤ 0.01 are noise — treated as no subject.
        let framer = AutoFramer()
        var zoom = 1.0
        for _ in 0..<120 {
            zoom = framer.update(
                subjectBox: CGRect(x: 0.5, y: 0.5, width: 0.005, height: 0.005),
                dt: dt).zoom
        }
        XCTAssertEqual(zoom, 1.0, accuracy: 1e-6)
    }

    // MARK: - Reset

    func testResetReturnsToIdentityInstantly() {
        let framer = AutoFramer()
        let history = runClosedLoop(framer, baseHeight: 0.4, frames: 90)
        XCTAssertGreaterThan(history.last!, 1.1, "precondition: mid-flight")

        framer.reset()
        // dt-0 update returns state without stepping — a pure probe.
        let probe = framer.update(subjectBox: centeredBox(height: 0.2), dt: 0)
        XCTAssertEqual(probe.zoom, 1.0)
        XCTAssertEqual(probe.panX, 0.0)
        XCTAssertEqual(probe.panY, 0.0)
    }

    func testResetAlsoClearsVelocity() {
        let framer = AutoFramer()
        _ = runClosedLoop(framer, baseHeight: 0.4, frames: 45)   // moving fast
        framer.reset()
        // With zero velocity and an identity target, the very next steps stay
        // at identity — a surviving velocity would drag zoom upward.
        for _ in 0..<30 {
            let out = framer.update(subjectBox: nil, dt: dt)
            XCTAssertEqual(out.zoom, 1.0, accuracy: 1e-6)
        }
    }

    // MARK: - dt handling

    func testZeroAndNegativeDtLeaveStateUntouched() {
        let framer = AutoFramer()
        let before = framer.update(subjectBox: nil, dt: 0)
        XCTAssertEqual(before.zoom, 1.0)
        _ = runClosedLoop(framer, baseHeight: 0.4, frames: 60)
        let state = framer.update(subjectBox: nil, dt: 0)
        let after = framer.update(subjectBox: centeredBox(height: 0.1), dt: -5)
        XCTAssertEqual(after.zoom, state.zoom)
        XCTAssertEqual(after.panX, state.panX)
        XCTAssertEqual(after.panY, state.panY)
    }

    func testTimerStallsAreAbsorbed() {
        // dt is clamped to 100ms: one 10-second stall must not teleport the
        // framing (it advances at most one 100ms step).
        let stalled = AutoFramer()
        let smooth = AutoFramer()
        let stalledZoom = stalled.update(subjectBox: centeredBox(height: 0.4),
                                         dt: 10.0).zoom
        let smoothZoom = smooth.update(subjectBox: centeredBox(height: 0.4),
                                       dt: 0.1).zoom
        XCTAssertEqual(stalledZoom, smoothZoom, accuracy: 1e-9)
        XCTAssertLessThan(stalledZoom, 1.05, "one clamped step moves barely at all")
    }
}
