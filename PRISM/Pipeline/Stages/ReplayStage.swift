// ReplayStage.swift
// PRISM
//
// Stage 1 of the chain (§3.3): replay and away-loop substitution. Sits
// between clip and freeze — a replay overrides a playing clip, and a freeze
// overrides a replay, matching how deliberate each act is.
//
// The stage draws whatever ReplayPlayer hands it: one texture normally, or
// two blended when the away loop is crossfading its tail into its own first
// frame at the wrap.
//
// Buffered frames are RAW CAMERA frames, recorded upstream of everything, so
// a replay runs through the live effects chain like any other source. That
// is the reason recording taps the camera rather than the finished output:
// replaying the output would double-apply every effect, and a replay that
// does not match your current look reads as a glitch rather than a rewind.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import Foundation
import Metal

public final class ReplayStage: EffectStage {
    public let id: StageID = .replay
    public let cost: StageCost = .cheap
    public var isEnabled: Bool = true

    /// Set by the pipeline. Substitutes whenever the player is active.
    public var player: ReplayPlayer?

    private let copyPipeline: MTLComputePipelineState
    private let crossfadePipeline: MTLComputePipelineState

    /// Frame resolved in wantsEncode() and consumed by the encode() that
    /// immediately follows for the same output frame (ClipStage's contract).
    private var pending: ReplayPlayer.Frame?

    public init(metal: MetalContext) throws {
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        crossfadePipeline = try metal.computePipeline(function: "prism_crossfade")
    }

    public func wantsEncode() -> Bool {
        pending = nil
        guard isEnabled, let player, player.isActive else { return false }
        pending = player.currentFrame(at: CMClockGetTime(CMClockGetHostTimeClock()))
        return pending != nil
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        let frame = pending
        pending = nil

        guard let frame else {
            // The replay ended between wantsEncode() and encode(): pass live
            // video through rather than dropping the frame.
            try encodeCopy(commandBuffer: commandBuffer, source: input, destination: output)
            return
        }

        if let blend = frame.blendTexture, frame.mix > 0 {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw PipelineError.encodingFailed("ReplayStage: no crossfade encoder")
            }
            var params = PRISMCrossfadeParams()
            params.mix = min(max(frame.mix, 0), 1)
            encoder.label = "ReplayStage.loopSeam"
            encoder.setComputePipelineState(crossfadePipeline)
            encoder.setTexture(frame.texture, index: 0)
            encoder.setTexture(blend, index: 1)
            encoder.setTexture(output, index: 2)
            encoder.setBytes(&params,
                             length: MemoryLayout<PRISMCrossfadeParams>.stride, index: 0)
            dispatchOver(output, pipeline: crossfadePipeline, encoder: encoder)
            encoder.endEncoding()
            return
        }

        try encodeCopy(commandBuffer: commandBuffer,
                       source: frame.texture, destination: output)
    }

    private func encodeCopy(commandBuffer: MTLCommandBuffer,
                            source: MTLTexture,
                            destination: MTLTexture) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("ReplayStage: no compute encoder")
        }
        encoder.label = "ReplayStage.copy"
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        dispatchOver(destination, pipeline: copyPipeline, encoder: encoder)
        encoder.endEncoding()
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
