// BlurStage.swift
// PRISM
//
// Background blur (§5.4, .expensive). The visual pass is a separable
// Gaussian at half resolution (prism_blur H → V) followed by one
// prism_composite against the person mask. Until the first mask arrives the
// stage passes the frame through — a blur that guesses at the subject looks
// far worse than one that waits a frame.
//
// Segmentation itself lives in PersonSegmenter, shared with the virtual
// background, behind-the-subject overlay layers, and auto-framing. This
// stage owns only the blur.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal
import simd

public final class BlurStage: EffectStage {
    public let id: StageID = .blur
    public let cost: StageCost = .expensive
    public var isEnabled: Bool = false

    public var settings = BlurSettings()

    /// Shared mask provider, injected by the pipeline. The stage never runs
    /// Vision itself.
    public let segmenter: PersonSegmenter

    /// Convenience for auto-framing, which historically read the box off this
    /// stage. Forwards to the shared segmenter.
    public var latestSubjectBox: CGRect? { segmenter.latestSubjectBox }

    private let metal: MetalContext
    private let copyPipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState

    // Half-resolution blur scratch (frame queue only).
    private var scratchA: MTLTexture?
    private var scratchB: MTLTexture?

    public init(metal: MetalContext, segmenter: PersonSegmenter) throws {
        self.metal = metal
        self.segmenter = segmenter
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        blurPipeline = try metal.computePipeline(function: "prism_blur")
        compositePipeline = try metal.computePipeline(function: "prism_composite")
    }

    public func wantsEncode() -> Bool { isEnabled }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        guard let mask = segmenter.latestMask else {
            // Mask not yet available: pass through rather than blur blindly.
            try encodeCopy(commandBuffer: commandBuffer, source: input,
                           destination: output, label: "BlurStage.passThrough")
            return
        }
        try encodeBlur(commandBuffer: commandBuffer, input: input,
                       output: output, mask: mask)
    }

    // MARK: - Blur encoding

    private func encodeBlur(commandBuffer: MTLCommandBuffer,
                            input: MTLTexture,
                            output: MTLTexture,
                            mask: MTLTexture) throws {
        let halfW = max(1, input.width / 2)
        let halfH = max(1, input.height / 2)
        if scratchA == nil || scratchA?.width != halfW || scratchA?.height != halfH {
            scratchA = try metal.makeIntermediate(width: halfW, height: halfH)
            scratchB = try metal.makeIntermediate(width: halfW, height: halfH)
        }
        guard let scratchA, let scratchB else {
            throw PipelineError.textureAllocationFailed
        }

        // Downsample to half resolution — the Gaussian runs there for speed
        // and the composite samples the blurred background back up.
        try encodeCopy(commandBuffer: commandBuffer, source: input,
                       destination: scratchA, label: "BlurStage.downsample")

        // §5.4: radius is specified in pixels at 1080p, scaled by height;
        // halved again because the blur runs at half resolution.
        let fullRadius = max(1.0, settings.radius * Double(input.height) / 1080.0)
        let halfRadius = Float(max(0.5, fullRadius * 0.5))

        try encodeBlurPass(commandBuffer: commandBuffer, source: scratchA,
                           destination: scratchB,
                           direction: SIMD2<Float>(1, 0), radius: halfRadius,
                           label: "BlurStage.gaussianH")
        try encodeBlurPass(commandBuffer: commandBuffer, source: scratchB,
                           destination: scratchA,
                           direction: SIMD2<Float>(0, 1), radius: halfRadius,
                           label: "BlurStage.gaussianV")

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("BlurStage: no composite encoder")
        }
        var params = PRISMCompositeParams()
        params.maskContrast = 1
        encoder.label = "BlurStage.composite"
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(input, index: 0)      // sharp
        encoder.setTexture(scratchA, index: 1)   // blurred
        encoder.setTexture(mask, index: 2)       // person = 1
        encoder.setTexture(output, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<PRISMCompositeParams>.stride, index: 0)
        dispatchOver(output, pipeline: compositePipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func encodeBlurPass(commandBuffer: MTLCommandBuffer,
                                source: MTLTexture,
                                destination: MTLTexture,
                                direction: SIMD2<Float>,
                                radius: Float,
                                label: String) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("BlurStage: no blur encoder")
        }
        var params = PRISMBlurParams()
        params.direction = direction
        params.radius = radius
        encoder.label = label
        encoder.setComputePipelineState(blurPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<PRISMBlurParams>.stride, index: 0)
        dispatchOver(destination, pipeline: blurPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func encodeCopy(commandBuffer: MTLCommandBuffer,
                            source: MTLTexture,
                            destination: MTLTexture,
                            label: String) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("BlurStage: no copy encoder")
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
