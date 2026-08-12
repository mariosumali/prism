// AdjustStage.swift
// PRISM
//
// Adjust (§5.4, .cheap): exposure, contrast, saturation, temperature, and
// vignette in one prism_adjust pass. Declines to encode at identity settings
// so the pipeline can skip the pass entirely.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal

public final class AdjustStage: EffectStage {
    public let id: StageID = .adjust
    public let cost: StageCost = .cheap
    public var isEnabled: Bool = false

    public var settings = AdjustSettings()

    private let adjustPipeline: MTLComputePipelineState

    public init(metal: MetalContext) throws {
        adjustPipeline = try metal.computePipeline(function: "prism_adjust")
    }

    public func wantsEncode() -> Bool {
        isEnabled && !settings.isIdentity
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        var params = PRISMAdjustParams()
        params.exposureEV = Float(clampValue(settings.exposureEV, -2, 2))
        params.contrast = Float(clampValue(settings.contrast, 0, 2))
        params.saturation = Float(clampValue(settings.saturation, 0, 2))
        params.temperature = Float(clampValue(settings.temperature, -100, 100))
        params.vignette = Float(clampValue(settings.vignette, 0, 1))

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("AdjustStage: no compute encoder")
        }
        encoder.label = "AdjustStage"
        encoder.setComputePipelineState(adjustPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<PRISMAdjustParams>.stride, index: 0)
        dispatchOver(output, pipeline: adjustPipeline, encoder: encoder)
        encoder.endEncoding()
    }
}

private func clampValue<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
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
