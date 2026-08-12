// LUTStage.swift
// PRISM
//
// LUT (§5.4, .moderate): trilinear sample of a 3D lookup texture loaded from
// a .cube file via LUTStore, blended by strength. "Neutral" is the identity
// LUT, so the stage declines to encode for it (or when no texture could be
// loaded, or at zero strength) — the pass would be a no-op.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal

public final class LUTStage: EffectStage {
    public let id: StageID = .lut
    public let cost: StageCost = .moderate
    public var isEnabled: Bool = false

    /// Setting a new lutName loads the 3D texture via LUTStore.
    public var settings: LUTSettings {
        didSet {
            if oldValue.lutName.caseInsensitiveCompare(settings.lutName) != .orderedSame {
                reloadTexture()
            }
        }
    }

    private let device: MTLDevice
    private let lutPipeline: MTLComputePipelineState
    private let copyPipeline: MTLComputePipelineState
    private var lutTexture: MTLTexture?

    public init(metal: MetalContext) throws {
        device = metal.device
        lutPipeline = try metal.computePipeline(function: "prism_lut")
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        settings = LUTSettings()
        reloadTexture()
    }

    public func wantsEncode() -> Bool {
        isEnabled && !isNeutral && settings.strength > 0 && lutTexture != nil
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("LUTStage: no compute encoder")
        }
        defer { encoder.endEncoding() }

        guard let lut = lutTexture else {
            // Defensive pass-through if encode is called without a texture.
            encoder.label = "LUTStage.passThrough"
            encoder.setComputePipelineState(copyPipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            dispatchOver(output, pipeline: copyPipeline, encoder: encoder)
            return
        }

        var params = PRISMLUTParams()
        params.strength = Float(min(max(settings.strength, 0), 1))

        encoder.label = "LUTStage.\(settings.lutName)"
        encoder.setComputePipelineState(lutPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<PRISMLUTParams>.stride, index: 0)
        dispatchOver(output, pipeline: lutPipeline, encoder: encoder)
    }

    // MARK: - Private

    /// "Neutral" IS the identity LUT (bundled or synthesized), so applying it
    /// at any strength has no visual effect.
    private var isNeutral: Bool {
        settings.lutName.caseInsensitiveCompare("Neutral") == .orderedSame
    }

    private func reloadTexture() {
        lutTexture = LUTStore.shared.texture(named: settings.lutName, device: device)
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
