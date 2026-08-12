// FreezeStage.swift
// PRISM
//
// Freeze frame (§5.2, .cheap): holds a privately-owned copy of the frame the
// pipeline selected from FrameRing (the sharpest within the trailing window).
// FrameRing slots are pooled, so freeze(texture:) COPIES the frame into an
// owned private texture via a blit on its own tiny command buffer — retaining
// the pooled texture would let the pool overwrite it. While frozen, encode()
// replaces the frame with prism_copy of the held texture.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal

public final class FreezeStage: EffectStage {
    public let id: StageID = .freeze
    public let cost: StageCost = .cheap
    public var isEnabled: Bool = true

    public private(set) var isFrozen: Bool = false

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let copyPipeline: MTLComputePipelineState
    private var heldTexture: MTLTexture?

    public init(metal: MetalContext) throws {
        device = metal.device
        commandQueue = metal.commandQueue
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    /// Called on the capture queue by VideoPipeline.setFrozen with the
    /// FrameRing pick. The copy is committed immediately on its own command
    /// buffer; hazard tracking orders it ahead of subsequent frame encodes on
    /// the same queue, so the frozen image is visible within one frame.
    public func freeze(texture: MTLTexture) {
        let held: MTLTexture
        if let existing = heldTexture,
           existing.width == texture.width,
           existing.height == texture.height,
           existing.pixelFormat == texture.pixelFormat {
            held = existing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat,
                width: texture.width,
                height: texture.height,
                mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .private
            guard let fresh = device.makeTexture(descriptor: descriptor) else { return }
            held = fresh
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        commandBuffer.label = "FreezeStage.captureCopy"
        blit.copy(from: texture, to: held)
        blit.endEncoding()
        commandBuffer.commit()
        heldTexture = held
        isFrozen = true
    }

    public func unfreeze() {
        isFrozen = false
        heldTexture = nil
    }

    public func wantsEncode() -> Bool {
        isEnabled && isFrozen && heldTexture != nil
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        let source = heldTexture ?? input   // defensive: pass through if unheld
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("FreezeStage: no compute encoder")
        }
        encoder.label = "FreezeStage.copy"
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
