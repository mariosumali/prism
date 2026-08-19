// RetouchStage.swift
// PRISM
//
// Skin retouch (§5.22, .expensive): a skin-gated edge-preserving smooth
// sitting between Geometry and the colour stages, so the gate is measured on
// the camera's own colour rather than on an exposure- or temperature-edited
// one.
//
// Four passes: a half-resolution downsample, two directions of a separable
// bilateral blur, and one full-resolution combine that mixes the result back
// under the gate and hands the fine texture it removed back. Half resolution
// is what makes the pass affordable at 1080p60 (§3.4) — and it costs nothing
// visually, because the frequencies the downsample throws away are exactly
// the ones the combine restores from the full-resolution source.
//
// What this is. It smooths the skin you have. There is no face model, no
// synthesis, and nothing invented: the smoothing is a weighted average of
// the pixels already in the frame, the bilateral weight steps around every
// edge it meets, and the detail pass puts the texture back. Eye contact
// (§5.6) is documented the same way and for the same reason — do not
// describe this to users in terms that imply a rendered face.
//
// The person mask is read opportunistically and never demanded. Retouch is
// not in the pipeline's mask-consumer set: turning it on must not buy a
// Vision segmentation request, so it gates on skin chroma, which needs
// nothing but the frame. When a mask does exist — someone has blur, a
// virtual background, or a layer behind them — it narrows the gate to the
// subject. That can only change the picture *outside* the person, never on
// the face, which is why an opportunistic input is honest here.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal

public final class RetouchStage: EffectStage {
    public let id: StageID = .retouch
    /// Two bilateral passes plus a downsample and a combine, all but one at
    /// half resolution — the same class as Background blur and, per the
    /// weight table, about half its price.
    public let cost: StageCost = .expensive
    public var isEnabled: Bool = false

    public var settings = RetouchSettings()

    /// Shared mask provider, injected by the pipeline. Read only if a mask
    /// happens to be there; this stage never asks for one.
    public let segmenter: PersonSegmenter

    private let metal: MetalContext
    private let copyPipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState
    private let combinePipeline: MTLComputePipelineState

    // Half-resolution scratch (frame queue only).
    private var scratchA: MTLTexture?
    private var scratchB: MTLTexture?

    public init(metal: MetalContext, segmenter: PersonSegmenter) throws {
        self.metal = metal
        self.segmenter = segmenter
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        blurPipeline = try metal.computePipeline(function: "prism_retouch_blur")
        combinePipeline = try metal.computePipeline(function: "prism_retouch_combine")
    }

    /// An amount of zero is off, not a switch that runs four passes to write
    /// the frame back unchanged — the pipeline skips the stage entirely and
    /// every surface reads the same answer off `RetouchSettings.isInert`.
    public func wantsEncode() -> Bool {
        isEnabled && !settings.isInert
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        let halfW = max(1, input.width / 2)
        let halfH = max(1, input.height / 2)
        if scratchA == nil || scratchA?.width != halfW || scratchA?.height != halfH {
            scratchA = try metal.makeIntermediate(width: halfW, height: halfH)
            scratchB = try metal.makeIntermediate(width: halfW, height: halfH)
        }
        guard let scratchA, let scratchB else {
            throw PipelineError.textureAllocationFailed
        }

        try encodeCopy(commandBuffer: commandBuffer, source: input,
                       destination: scratchA, label: "RetouchStage.downsample")

        // The sigma is specified against 1080p and scaled by height. The
        // kernel reads radius = 2σ, and σ measured in half-resolution pixels
        // is half the full-resolution one — the two factors of two cancel, so
        // the radius passed down is the full-resolution sigma itself.
        let fullSigma = settings.spatialSigma(forHeight: input.height)
        let halfRadius = Float(max(0.5, fullSigma))
        let rangeSigma = Float(settings.rangeSigma)

        try encodeBlurPass(commandBuffer: commandBuffer, source: scratchA,
                           destination: scratchB,
                           direction: SIMD2<Float>(1, 0),
                           radius: halfRadius, rangeSigma: rangeSigma,
                           label: "RetouchStage.bilateralH")
        try encodeBlurPass(commandBuffer: commandBuffer, source: scratchB,
                           destination: scratchA,
                           direction: SIMD2<Float>(0, 1),
                           radius: halfRadius, rangeSigma: rangeSigma,
                           label: "RetouchStage.bilateralV")

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("RetouchStage: no combine encoder")
        }
        let mask = segmenter.latestMask
        var params = PRISMRetouchParams()
        params.amount = Float(settings.blend)
        params.detail = Float(settings.clampedDetail)
        params.useMask = mask == nil ? 0 : 1
        encoder.label = "RetouchStage.combine"
        encoder.setComputePipelineState(combinePipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(scratchA, index: 1)
        // Only read when useMask is set; bind the source as a filler
        // otherwise so the binding is always populated.
        encoder.setTexture(mask ?? input, index: 2)
        encoder.setTexture(output, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<PRISMRetouchParams>.stride, index: 0)
        dispatchOver(output, pipeline: combinePipeline, encoder: encoder)
        encoder.endEncoding()
    }

    // MARK: - Encoding

    private func encodeBlurPass(commandBuffer: MTLCommandBuffer,
                                source: MTLTexture,
                                destination: MTLTexture,
                                direction: SIMD2<Float>,
                                radius: Float,
                                rangeSigma: Float,
                                label: String) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("RetouchStage: no blur encoder")
        }
        var params = PRISMRetouchBlurParams()
        params.direction = direction
        params.radius = radius
        params.rangeSigma = rangeSigma
        encoder.label = label
        encoder.setComputePipelineState(blurPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<PRISMRetouchBlurParams>.stride, index: 0)
        dispatchOver(destination, pipeline: blurPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func encodeCopy(commandBuffer: MTLCommandBuffer,
                            source: MTLTexture,
                            destination: MTLTexture,
                            label: String) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("RetouchStage: no copy encoder")
        }
        encoder.label = label
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
