// ConnectionStage.swift
// PRISM
//
// Simulated bad connection (§5.14, .cheap): one prism_connection pass that
// pixelates the finished frame into codec-style macroblocks, posterises its
// colour, adds per-block shimmer, and refreshes only a fraction of blocks
// against the previous degraded frame (the packet-loss smear). Refresh
// timing is irregular — jittered intervals with occasional stalls — and the
// effective severity wanders slowly, the way adaptive bitrate breathes.
// Engaged by AppState like freeze, never by a preset: behaviour, not look.
// The optional delay is the §5.12 lag switch's machinery, orchestrated by
// AppState, not this stage.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal
import QuartzCore

/// Decides when the held frame refreshes. Pure arithmetic, separated from the
/// stage so the throttle's behaviour (first frame, a clock stepping
/// backwards, the jitter distribution) is testable without a Metal device.
///
/// Intervals are deliberately irregular: a metronomic refresh reads as a
/// strobe, not a network. Each refresh draws the next interval as a multiple
/// of the mean — usually a little under it, occasionally (about one draw in
/// ten) a stall of several intervals, which is what a burst of packet loss
/// looks like. The generator is a seeded xorshift, so a given seed produces
/// one deterministic, testable cadence.
public struct ConnectionFrameGate {
    private var lastRefreshAt: Double?
    private var intervalFactor: Double = 1
    private var rng: UInt64

    public init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        rng = seed == 0 ? 1 : seed
    }

    /// True when a fresh frame should be taken at `now` for the target mean
    /// rate. The first call always refreshes — a throttle that opens with a
    /// stale or missing frame would flash garbage on engage.
    public mutating func shouldRefresh(at now: Double, fps: Double) -> Bool {
        guard fps > 0 else { return true }
        guard let last = lastRefreshAt, now >= last else {
            // First frame, or the reference clock stepped backwards (sleep /
            // clock adjustment): re-anchor rather than stalling until the
            // clock catches up to a future timestamp.
            refresh(at: now)
            return true
        }
        guard now - last >= intervalFactor / fps else { return false }
        refresh(at: now)
        return true
    }

    public mutating func reset() {
        lastRefreshAt = nil
    }

    private mutating func refresh(at now: Double) {
        lastRefreshAt = now
        // Mean ≈ 1.1× the nominal interval: 0.9 × 0.7 (ordinary jitter)
        // + 0.1 × 5 (stalls), so the configured fps stays an honest mean.
        if nextUnit() < 0.1 {
            intervalFactor = 3 + 4 * nextUnit()        // stall: 3–7 intervals
        } else {
            intervalFactor = 0.35 + 0.7 * nextUnit()   // ordinary jitter
        }
    }

    /// xorshift64* — deterministic, allocation-free, uniform in [0, 1).
    private mutating func nextUnit() -> Double {
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        return Double((rng &* 2_685_821_657_736_338_717) >> 11)
            / Double(UInt64(1) << 53)
    }
}

public final class ConnectionStage: EffectStage {
    public let id: StageID = .connection
    public let cost: StageCost = .cheap
    /// Set via setEngaged from AppState (§5.14 intent), never by a preset —
    /// switching from Meeting to Studio must not silently fix your network.
    public var isEnabled: Bool = false
    /// Written by applyStudio on the main thread, read on the frame path —
    /// the same tearing-tolerant pattern every other stage's settings use.
    public var settings = ConnectionSettings()

    private let metal: MetalContext
    private let connectionPipeline: MTLComputePipelineState
    private let copyPipeline: MTLComputePipelineState

    // Frame-path confined (encode runs under the pipeline's frameQueue).
    private var heldFrame: MTLTexture?
    private var gate = ConnectionFrameGate()
    /// Reseeds the per-block lottery and shimmer on every refresh so held
    /// frames boil between refreshes rather than freezing their noise, and
    /// so a different subset of blocks goes stale each time. Small LCG — no
    /// entropy needed, only "different from last time".
    private var seed: Float = 0.137
    /// Slow multiplicative wander on the effective severity — adaptive
    /// bitrate breathes, collapsing and part-recovering; a constant quality
    /// level is the tell of a filter. Random-target smoothing, stepped once
    /// per refresh so quality changes land with the frame bursts.
    private var wander: Double = 1
    private var wanderRng: UInt64 = 0x2545_F491_4F6C_DD1D

    public init(metal: MetalContext) throws {
        self.metal = metal
        connectionPipeline = try metal.computePipeline(function: "prism_connection")
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    /// Engage/release, from AppState. Releasing drops the held frame and the
    /// throttle anchor so a re-engage starts from live, not from whatever was
    /// on air last time.
    public func setEngaged(_ engaged: Bool) {
        isEnabled = engaged
        if !engaged {
            heldFrame = nil
            gate.reset()
            wander = 1
        }
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        let refresh = !settings.dropsFrames
            || gate.shouldRefresh(at: CACurrentMediaTime(), fps: settings.throttledFps)

        if !refresh, let held = heldFrame,
           held.width == output.width, held.height == output.height {
            // Between refreshes the last degraded frame is what is on air.
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw PipelineError.encodingFailed("ConnectionStage: no compute encoder")
            }
            encoder.label = "ConnectionStage.hold"
            encoder.setComputePipelineState(copyPipeline)
            encoder.setTexture(held, index: 0)
            encoder.setTexture(output, index: 1)
            dispatchOver(output, pipeline: copyPipeline, encoder: encoder)
            encoder.endEncoding()
            return
        }

        seed = (seed * 16_807).truncatingRemainder(dividingBy: 1_000) + 0.113
        stepWander()

        // Breathe the look, not the public knob: severity wanders ±30%
        // around what the user set, clamped to the settings' own range so
        // every derived value stays within its documented bounds.
        var effective = settings
        effective.severity = min(max(settings.clampedSeverity * wander, 0.1), 1)

        // Stale blocks only make sense against a previous degraded frame of
        // the same size; the first frame after engage (or a format change)
        // refreshes everything.
        let prev = heldFrame
        let hasPrev = settings.dropsFrames
            && prev?.width == output.width && prev?.height == output.height

        var params = PRISMConnectionParams()
        params.blockSize = Float(effective.blockSize(forHeight: output.height))
        params.levels = Float(effective.posterizeLevels)
        params.noise = Float(effective.artifactAmount)
        params.seed = seed
        params.updateFraction = Float(effective.updateFraction)
        params.hasPrev = hasPrev ? 1 : 0

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("ConnectionStage: no compute encoder")
        }
        encoder.label = "ConnectionStage.degrade"
        encoder.setComputePipelineState(connectionPipeline)
        encoder.setTexture(input, index: 0)
        // Metal wants every slot bound; without a previous frame the kernel
        // never reads slot 1, so input stands in.
        encoder.setTexture(hasPrev ? prev : input, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<PRISMConnectionParams>.stride,
                         index: 0)
        dispatchOver(output, pipeline: connectionPipeline, encoder: encoder)
        encoder.endEncoding()

        if settings.dropsFrames {
            try retainRefreshedFrame(commandBuffer: commandBuffer, output: output)
        } else {
            heldFrame = nil
        }
    }

    /// Copies the freshly degraded output into a privately owned texture on
    /// the same command buffer, so the hold path never reads a ping-pong
    /// intermediate the next frame is about to overwrite.
    private func retainRefreshedFrame(commandBuffer: MTLCommandBuffer,
                                      output: MTLTexture) throws {
        let held: MTLTexture
        if let existing = heldFrame,
           existing.width == output.width, existing.height == output.height {
            held = existing
        } else {
            held = try metal.makeIntermediate(width: output.width, height: output.height)
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw PipelineError.encodingFailed("ConnectionStage: no blit encoder")
        }
        blit.label = "ConnectionStage.retain"
        blit.copy(from: output, to: held)
        blit.endEncoding()
        heldFrame = held
    }

    /// One wander step: chase a fresh random target in 0.7…1.3, a third of
    /// the remaining distance per refresh — fast enough to visibly pulse,
    /// slow enough never to pop.
    private func stepWander() {
        wanderRng ^= wanderRng >> 12
        wanderRng ^= wanderRng << 25
        wanderRng ^= wanderRng >> 27
        let unit = Double((wanderRng &* 2_685_821_657_736_338_717) >> 11)
            / Double(UInt64(1) << 53)
        let target = 0.7 + 0.6 * unit
        wander += (target - wander) / 3
    }
}

/// Dispatch a full-texture compute pass; kernels guard out-of-bounds gid.
private func dispatchOver(_ target: MTLTexture,
                          pipeline: MTLComputePipelineState,
                          encoder: MTLComputeCommandEncoder) {
    let w = pipeline.threadExecutionWidth
    let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
    let group = MTLSize(width: w, height: h, depth: 1)
    let grid = MTLSize(width: (target.width + w - 1) / w,
                       height: (target.height + h - 1) / h,
                       depth: 1)
    encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
}
