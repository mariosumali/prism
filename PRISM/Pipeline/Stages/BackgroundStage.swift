// BackgroundStage.swift
// PRISM
//
// Virtual background (§5.7, .expensive). Replaces everything behind the
// person mask with a still, a looping video, or a flat colour — the same
// mask background blur uses, from the shared PersonSegmenter, so running
// both costs one segmentation rather than two.
//
// Fail-safe direction. This stage exists partly for privacy: someone turns
// it on because they do not want the room behind them on camera. So every
// degraded path errs toward covering the background, never toward revealing
// it. No mask yet → composite against an all-zero mask, which shows the
// backdrop across the whole frame for the frame or two segmentation takes to
// warm up. Asset missing or still opening → the flat colour. The one thing
// this stage will not do is pass the camera through.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreMedia
import Foundation
import Metal
import simd

public final class BackgroundStage: EffectStage {
    public let id: StageID = .background
    public let cost: StageCost = .expensive
    public var isEnabled: Bool = false

    public var settings = BackgroundSettings() {
        didSet {
            guard settings.assetPath != oldValue.assetPath
                || settings.kind != oldValue.kind else { return }
            reloadSource()
        }
    }

    public let segmenter: PersonSegmenter

    private let metal: MetalContext
    private let replacePipeline: MTLComputePipelineState
    private let source: LayerSource
    /// 1×1 r8Unorm zero mask: "no subject known yet", which composites as
    /// all-background. Allocated once, never rewritten.
    private let emptyMask: MTLTexture
    /// Solid 1×1 stand-in bound when the kernel is in flat-colour mode; Metal
    /// still requires a texture at that binding point.
    private let placeholderTexture: MTLTexture

    /// Texture resolved in wantsEncode() and consumed by the encode() that
    /// follows for the same frame, matching ClipStage's contract.
    private var pendingTexture: MTLTexture?

    public init(metal: MetalContext, segmenter: PersonSegmenter) throws {
        self.metal = metal
        self.segmenter = segmenter
        replacePipeline = try metal.computePipeline(function: "prism_background_replace")
        source = LayerSource(metal: metal, label: "background")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let mask = metal.device.makeTexture(descriptor: descriptor) else {
            throw PipelineError.textureAllocationFailed
        }
        var zero: UInt8 = 0
        mask.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                     withBytes: &zero, bytesPerRow: 1)
        emptyMask = mask
        placeholderTexture = try metal.makeIntermediate(width: 1, height: 1)
    }

    /// True when the stage needs the shared person mask this frame.
    public var needsPersonMask: Bool { isEnabled }

    public func setDemandActive(_ active: Bool) {
        source.setDemandActive(active)
    }

    public func wantsEncode() -> Bool {
        pendingTexture = nil
        guard isEnabled else { return false }
        if settings.resolvedKind != .color {
            pendingTexture = source.currentTexture(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        return true
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        let background = pendingTexture
        pendingTexture = nil

        var params = PRISMBackgroundParams()
        params.maskContrast = Float(min(max(settings.maskContrast, 1), 4))
        params.edgeSoftness = Float(min(max(settings.edgeSoftness, 0), 1))
        params.lightWrap = Float(min(max(settings.lightWrap, 0), 1))
        params.flatColor = SIMD4<Float>(Float(settings.color.red),
                                        Float(settings.color.green),
                                        Float(settings.color.blue), 1)

        if let background {
            params.useTexture = 1
            let (scale, offset) = Self.fit(
                contentSize: CGSize(width: background.width, height: background.height),
                outputSize: CGSize(width: output.width, height: output.height),
                mode: settings.fillMode)
            params.bgScale = scale
            params.bgOffset = offset
        } else {
            params.useTexture = 0
            params.bgScale = SIMD2<Float>(1, 1)
            params.bgOffset = SIMD2<Float>(0, 0)
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("BackgroundStage: no compute encoder")
        }
        encoder.label = "BackgroundStage"
        encoder.setComputePipelineState(replacePipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(background ?? placeholderTexture, index: 1)
        encoder.setTexture(segmenter.latestMask ?? emptyMask, index: 2)
        encoder.setTexture(output, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<PRISMBackgroundParams>.stride, index: 0)
        dispatchOver(output, pipeline: replacePipeline, encoder: encoder)
        encoder.endEncoding()
    }

    // MARK: - Placement

    /// Content extent and top-left corner of the backdrop within the output,
    /// in UV. Aspect is always preserved: `fill` covers and crops, `letterbox`
    /// fits and leaves the flat colour showing through the bars. Backdrops
    /// default to fill because a letterboxed backdrop reads as a bug.
    static func fit(contentSize: CGSize,
                    outputSize: CGSize,
                    mode: ClipFillMode) -> (scale: SIMD2<Float>, offset: SIMD2<Float>) {
        guard contentSize.width > 0, contentSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            return (SIMD2<Float>(1, 1), SIMD2<Float>(0, 0))
        }
        let contentAspect = contentSize.width / contentSize.height
        let outputAspect = outputSize.width / outputSize.height
        let ratio = contentAspect / outputAspect

        let scale: SIMD2<Float>
        switch mode {
        case .letterbox:
            scale = ratio >= 1
                ? SIMD2<Float>(1, Float(1 / ratio))
                : SIMD2<Float>(Float(ratio), 1)
        case .fill:
            scale = ratio >= 1
                ? SIMD2<Float>(Float(ratio), 1)
                : SIMD2<Float>(1, Float(1 / ratio))
        }
        return (scale, (SIMD2<Float>(1, 1) - scale) * 0.5)
    }

    private func reloadSource() {
        let kind: LayerSourceKind = settings.kind == .video ? .video : .image
        source.configure(url: settings.resolvedKind == .color ? nil : settings.assetURL,
                         kind: kind)
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
