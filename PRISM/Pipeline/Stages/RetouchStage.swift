// RetouchStage.swift
// PRISM
//
// Skin retouch (§5.4, .expensive): a skin-chroma-gated smoothing pass sitting
// between Geometry and the colour stages, so the gate is measured on the
// camera's own colour rather than on an exposure- or temperature-edited one.
//
// The stage is registered in the chain from today, with no body: wantsEncode()
// declines unconditionally, so the pipeline skips the pass and the picture is
// bit-identical to a build without it. It exists now because registration is
// the part that has to be in lockstep everywhere (chain order, stage weights,
// draft renderer, degradation candidates, configuration flags) — landing that
// with the kernel would mean landing five silent failure modes at once. The
// kernel itself arrives with the retouch feature.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal

public final class RetouchStage: EffectStage {
    public let id: StageID = .retouch
    /// A separable edge-aware blur plus a mask pass, in the same class as
    /// Background blur. Weighted honestly from the start so the degradation
    /// engine never sees this stage appear and get cheaper.
    public let cost: StageCost = .expensive
    public var isEnabled: Bool = false

    /// Carried from the configuration so the wiring is in place before the
    /// kernel is; nothing reads it while wantsEncode() declines. Landing the
    /// kernel against a stage whose settings were never forwarded is the
    /// silent failure this exists to prevent.
    public var settings = RetouchSettings()

    /// Held for the face gate the smoothing kernel will need; nothing reads it
    /// yet. Taken in the initialiser because the tracker is constructed once
    /// by the pipeline and shared — a stage that reached for it later would
    /// have to make one of its own, which is the second full-frame Vision
    /// request the shared tracker exists to prevent.
    public let faceTracker: FaceTracker

    private let copyPipeline: MTLComputePipelineState

    public init(metal: MetalContext, faceTracker: FaceTracker) throws {
        self.faceTracker = faceTracker
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    public func wantsEncode() -> Bool { false }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("RetouchStage: no compute encoder")
        }
        defer { encoder.endEncoding() }
        // Nothing calls this while wantsEncode() is false, but a stage that
        // is asked to encode and writes nothing hands the next stage an
        // uninitialised intermediate — a garbage frame, not a skipped effect.
        encoder.label = "RetouchStage.passThrough"
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        let w = copyPipeline.threadExecutionWidth
        let h = max(1, copyPipeline.maxTotalThreadsPerThreadgroup / w)
        let grid = MTLSize(width: (output.width + w - 1) / w,
                           height: (output.height + h - 1) / h,
                           depth: 1)
        encoder.dispatchThreadgroups(grid,
                                     threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}
