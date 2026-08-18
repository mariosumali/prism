// StyleStage.swift
// PRISM
//
// Style (§5.4, .moderate): one preset visual effect over the finished,
// composed scene — warps, glitches, motion trails and a few gadget-camera
// looks. Each effect is its own prism_style_* kernel; picking one compiles
// (and caches) its pipeline here, off the frame path. The motion effects
// feed on their own output: the stage keeps a history texture holding the
// previous styled frame and blits each frame's result into it. "Normal" is
// the unstyled picture, so the stage declines to encode for it (or at zero
// intensity) — the pass would be a no-op.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal
import QuartzCore

public final class StyleStage: EffectStage {
    public let id: StageID = .style
    public let cost: StageCost = .moderate

    /// Turning the stage off drops the trail history (and its texture):
    /// ghosts recorded before a gap must never replay when the stage comes
    /// back, and a disabled stage should not hold a working-resolution
    /// texture resident.
    public var isEnabled: Bool = false {
        didSet { if !isEnabled { dropHistory() } }
    }

    /// Picking a new effect builds its compute pipeline in the setter, off
    /// the frame path (MetalContext caches compiled pipelines, so returning
    /// to an effect is free), and drops any trail history — a different
    /// effect must not inherit the previous one's trails. Dropping the
    /// intensity to zero parks the stage (wantsEncode false), which is a
    /// trail gap too, so the history goes with it.
    public var settings: StyleSettings {
        didSet {
            if oldValue.effect != settings.effect {
                reloadPipeline()
            } else if settings.intensity <= 0, oldValue.intensity > 0 {
                dropHistory()
            }
        }
    }

    private let metal: MetalContext
    private let copyPipeline: MTLComputePipelineState

    /// Guards (effectPipeline, effectIsTemporal, historyTexture,
    /// historyValid), which must change together: settings land from the
    /// main thread while encode() runs on the frame path, and a kernel
    /// dispatched with the other family's texture layout would write its
    /// output into the wrong texture. encode() takes one snapshot under the
    /// lock and re-validates against it before publishing the history —
    /// an invalidation that lands mid-encode wins over the completing frame.
    private let stateLock = NSLock()
    private var effectPipeline: MTLComputePipelineState?
    private var effectIsTemporal = false
    /// Previous styled output for the motion effects. Stage-owned so ring
    /// reuse of the pipeline's ping-pong intermediates cannot corrupt it;
    /// released whenever no motion effect could legitimately resume its
    /// trails.
    private var historyTexture: MTLTexture?
    private var historyValid = false

    /// Frame-path-confined. Trails age out across ANY encoding gap —
    /// zero-intensity parks, degradation disables, app naps — a ghost older
    /// than half a second reads as a glitch, not a trail. This closes every
    /// gap class the flag-based invalidation cannot see.
    private var lastEncodeTime: CFTimeInterval = -.infinity
    private static let maxTrailGapSeconds: CFTimeInterval = 0.5

    /// Time base for the animated looks: seconds since stage creation.
    private let timeBase = CACurrentMediaTime()

    public init(metal: MetalContext) throws {
        self.metal = metal
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        settings = StyleSettings()
    }

    public func wantsEncode() -> Bool {
        stateLock.lock()
        let hasPipeline = effectPipeline != nil
        stateLock.unlock()
        return isEnabled && !settings.isNormal && settings.intensity > 0
            && hasPipeline
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        // One consistent snapshot: the pipeline and its texture layout
        // belong to the same effect even if a switch lands mid-encode.
        stateLock.lock()
        let pipeline = effectPipeline
        let isTemporal = effectIsTemporal
        var history = historyTexture
        var seeded = historyValid
        stateLock.unlock()

        let now = CACurrentMediaTime()
        if now - lastEncodeTime > Self.maxTrailGapSeconds { seeded = false }
        lastEncodeTime = now

        guard let pipeline else {
            // Defensive pass-through if encode is called without a pipeline.
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw PipelineError.encodingFailed("StyleStage: no compute encoder")
            }
            encoder.label = "StyleStage.passThrough"
            encoder.setComputePipelineState(copyPipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            dispatchOver(output, pipeline: copyPipeline, encoder: encoder)
            encoder.endEncoding()
            return
        }

        // Any throwing allocation happens before an encoder is open — an
        // abandoned command buffer with a live encoder is a Metal assertion,
        // not a dropped frame.
        if isTemporal {
            if history == nil || history?.width != output.width
                || history?.height != output.height {
                let fresh = try metal.makeIntermediate(width: output.width,
                                                       height: output.height)
                history = fresh
                seeded = false
                stateLock.lock()
                historyTexture = fresh
                historyValid = false
                stateLock.unlock()
            }
        }

        var params = PRISMStyleParams()
        params.intensity = Float(min(max(settings.intensity, 0), 1))
        // Wrapped hourly before the Float32 narrowing: past ~a week of
        // uptime, Float ulp exceeds the VHS kernel's 1/24s reseed step and
        // its noise would hold-then-snap. The wrap is a fresh random seed
        // once an hour — indistinguishable inside noise reseeded at 24Hz.
        params.time = Float((now - timeBase).truncatingRemainder(dividingBy: 3600))
        params.aspect = Float(input.width) / Float(max(1, input.height))
        params.hasHistory = seeded ? 1 : 0

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("StyleStage: no compute encoder")
        }
        encoder.label = "StyleStage.\(settings.effect.rawValue)"
        encoder.setComputePipelineState(pipeline)

        if isTemporal, let history {
            // First frame after a seed loss: the kernel outputs the source
            // untouched and this frame's blit below seeds the feedback.
            encoder.setTexture(input, index: 0)
            encoder.setTexture(history, index: 1)
            encoder.setTexture(output, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<PRISMStyleParams>.stride, index: 0)
            dispatchOver(output, pipeline: pipeline, encoder: encoder)
            encoder.endEncoding()
            // Same command buffer, after the compute pass: next frame's
            // history is this frame's styled output.
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw PipelineError.encodingFailed("StyleStage: no blit encoder")
            }
            blit.copy(from: output, to: history)
            blit.endEncoding()
            // Publish only if no invalidation landed since the snapshot —
            // a seed-drop must never be overwritten by a completing frame.
            stateLock.lock()
            if historyTexture === history { historyValid = true }
            stateLock.unlock()
        } else {
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<PRISMStyleParams>.stride, index: 0)
            dispatchOver(output, pipeline: pipeline, encoder: encoder)
            encoder.endEncoding()
        }
    }

    // MARK: - Private

    private func reloadPipeline() {
        // A missing kernel leaves the stage inert (wantsEncode false) rather
        // than failing frames; StyleStageTests pins every catalogue case to
        // a compiling kernel so this can only happen to a corrupted build.
        let effect = settings.effect
        let pipeline = effect.kernelFunction.flatMap {
            try? metal.computePipeline(function: $0)
        }
        stateLock.lock()
        effectPipeline = pipeline
        effectIsTemporal = effect.isTemporal
        historyTexture = nil
        historyValid = false
        stateLock.unlock()
    }

    private func dropHistory() {
        stateLock.lock()
        historyTexture = nil
        historyValid = false
        stateLock.unlock()
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
