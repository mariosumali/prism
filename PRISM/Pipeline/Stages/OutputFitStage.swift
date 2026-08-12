// OutputFitStage.swift
// PRISM
//
// Output fit (§3.3, .cheap, always enabled): the final scale/letterbox of the
// content into the negotiated output format. Letterbox by default, fill as an
// option, never stretch (§5.3). Bars are opaque black in the kernel.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import Foundation
import Metal
import simd

public final class OutputFitStage: EffectStage {
    public let id: StageID = .outputFit
    public let cost: StageCost = .cheap
    /// Not a user stage; the pipeline never disables it.
    public var isEnabled: Bool = true

    /// Advisory: the negotiated output size, kept in sync by the pipeline's
    /// configure(outputFormat:). encode() derives the fit from the actual
    /// texture dimensions, which the pipeline sizes from this value.
    public var outputSize: CGSize = .zero
    public var contentMode: ClipFillMode = .letterbox

    private let fitPipeline: MTLComputePipelineState

    public init(metal: MetalContext) throws {
        fitPipeline = try metal.computePipeline(function: "prism_output_fit")
    }

    /// Always runs — it is the pass that lands content in the negotiated
    /// output buffer, even when the aspect already matches.
    public func wantsEncode() -> Bool { true }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        let contentAspect = Double(input.width) / Double(max(1, input.height))
        let outputAspect = Double(output.width) / Double(max(1, output.height))
        let ratio = contentAspect / max(outputAspect, 1e-6)

        // scale is the content extent within the output in UV units:
        // letterbox fits (≤ 1 both axes, bars on the short axis); fill covers
        // (≥ 1 on one axis, cropping it). Aspect is preserved in both — the
        // content is never stretched.
        let scale: SIMD2<Float>
        switch contentMode {
        case .letterbox:
            scale = ratio >= 1
                ? SIMD2<Float>(1, Float(1 / ratio))
                : SIMD2<Float>(Float(ratio), 1)
        case .fill:
            scale = ratio >= 1
                ? SIMD2<Float>(Float(ratio), 1)
                : SIMD2<Float>(1, Float(1 / ratio))
        }
        let offset = (SIMD2<Float>(1, 1) - scale) * 0.5

        var params = PRISMFitParams()
        params.scale = scale
        params.offset = offset
        params.fillMode = contentMode == .fill ? 1 : 0

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("OutputFitStage: no compute encoder")
        }
        encoder.label = "OutputFitStage"
        encoder.setComputePipelineState(fitPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<PRISMFitParams>.stride, index: 0)
        dispatchOver(output, pipeline: fitPipeline, encoder: encoder)
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
