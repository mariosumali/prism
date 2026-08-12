// AutoFramer.swift
// PRISM
//
// Auto-framing controller (§5.4): drives GeometryStage.autoFrameOffset
// toward keeping the subject bounding box centered at ~60% of frame height.
// Motion is critically damped with a 1.5s time constant — a camera that
// snaps is worse than one that doesn't move. Zoom is clamped to 1…2.5×.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import Foundation

public final class AutoFramer {
    private let timeConstant = 1.5             // seconds, §5.4
    private let targetHeightFraction = 0.6
    private let minZoom = 1.0
    private let maxZoom = 2.5

    private var zoom = 1.0
    private var panX = 0.0
    private var panY = 0.0
    private var zoomVelocity = 0.0
    private var panXVelocity = 0.0
    private var panYVelocity = 0.0

    public init() {}

    /// Advances the smoothed framing state by `dt` seconds toward the
    /// subject and returns the current deltas for
    /// GeometryStage.autoFrameOffset: `zoom` is a multiplier onto the user
    /// zoom (1 = none), `panX`/`panY` are additive pan deltas in
    /// croppable-margin fractions.
    ///
    /// `subjectBox` is BlurStage.latestSubjectBox: normalized, top-left
    /// origin (y down), measured in the *framed* output — downstream of the
    /// geometry this controller feeds. The controller is therefore a
    /// closed-loop servo: each update derives an incremental target from the
    /// residual on-screen error and critically damps motion toward it. A nil
    /// box (subject lost) eases the framing back to identity.
    public func update(subjectBox: CGRect?,
                       dt: Double) -> (zoom: Double, panX: Double, panY: Double) {
        let dt = min(max(dt, 0), 0.1)          // absorb timer stalls
        guard dt > 0 else { return (zoom, panX, panY) }

        var targetZoom = minZoom
        var targetPanX = 0.0
        var targetPanY = 0.0

        if let box = subjectBox, box.height > 0.01 {
            // Zooming by k multiplies the on-screen box height by k, so the
            // factor that lands the box at 60% of frame height is 0.6/h.
            targetZoom = clampValue(
                zoom * targetHeightFraction / Double(box.height), minZoom, maxZoom)

            // Centering: the visible window spans 1/zoom of the frame, so an
            // on-screen error of e moves the crop center by e·(1/zoom) in
            // input UV — expressed here in croppable-margin fractions.
            let visibleFraction = 1.0 / max(zoom, 1.0)
            let margin = (1.0 - visibleFraction) / 2.0
            if margin > 1e-3 {
                let errorX = Double(box.midX) - 0.5
                let errorY = Double(box.midY) - 0.5
                targetPanX = clampValue(panX + errorX * visibleFraction / margin, -1, 1)
                targetPanY = clampValue(panY + errorY * visibleFraction / margin, -1, 1)
            }
        }

        step(&zoom, &zoomVelocity, toward: targetZoom, dt: dt)
        step(&panX, &panXVelocity, toward: targetPanX, dt: dt)
        step(&panY, &panYVelocity, toward: targetPanY, dt: dt)

        zoom = clampValue(zoom, minZoom, maxZoom)
        panX = clampValue(panX, -1, 1)
        panY = clampValue(panY, -1, 1)
        return (zoom, panX, panY)
    }

    /// Back to identity instantly — called when auto-framing is disabled.
    public func reset() {
        zoom = 1
        panX = 0
        panY = 0
        zoomVelocity = 0
        panXVelocity = 0
        panYVelocity = 0
    }

    /// Critically damped second-order step:
    /// x″ = ω²(target − x) − 2ωx′ with ω = 1/τ, integrated with
    /// semi-implicit Euler (stable for dt ≪ τ; capture cadence is ~33ms).
    private func step(_ x: inout Double, _ v: inout Double,
                      toward target: Double, dt: Double) {
        let omega = 1.0 / timeConstant
        let acceleration = omega * omega * (target - x) - 2 * omega * v
        v += acceleration * dt
        x += v * dt
    }
}

private func clampValue<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}
