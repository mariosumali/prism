// ClipStage.swift
// PRISM
//
// Stage 0 of the chain (§3.3, §5.3): clip substitution. When the ClipPlayer
// has a current frame, the stage replaces the live frame wholesale by
// encoding prism_copy of the clip texture into the output. Otherwise it
// declines to encode (wantsEncode false) and the pipeline passes the live
// frame through untouched.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import Foundation
import Metal

public final class ClipStage: EffectStage {
    public let id: StageID = .clip
    public let cost: StageCost = .cheap
    public var isEnabled: Bool = true

    /// Substitutes when playing / paused-with-frame. Set by the integration
    /// layer on the main thread; read on the capture queue.
    public var player: ClipPlayer?

    private let copyPipeline: MTLComputePipelineState

    /// Frame fetched in wantsEncode() and consumed by the encode() that
    /// immediately follows on the capture queue for the same output frame.
    private var pendingTexture: MTLTexture?

    public init(metal: MetalContext) throws {
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    public func wantsEncode() -> Bool {
        pendingTexture = nil
        guard isEnabled, let player else { return false }
        pendingTexture = player.currentTexture(at: CMClockGetTime(CMClockGetHostTimeClock()))
        return pendingTexture != nil
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        defer { pendingTexture = nil }
        // Fall back to pass-through if the clip frame evaporated between
        // wantsEncode() and encode() (e.g. stop() raced this frame).
        let source = pendingTexture
            ?? player?.currentTexture(at: CMClockGetTime(CMClockGetHostTimeClock()))
            ?? input
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("ClipStage: no compute encoder")
        }
        encoder.label = "ClipStage.copy"
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 1)
        dispatchOver(output, pipeline: copyPipeline, encoder: encoder)
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
