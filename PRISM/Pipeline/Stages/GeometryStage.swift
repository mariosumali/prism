// GeometryStage.swift
// PRISM
//
// Geometry (§5.4, .cheap): crop-aspect crop, zoom (1…4×), pan (fraction of
// the croppable margin), fine rotation (−15…+15°), orientation (0/90/180/
// 270°), and mirror, composed into a single 3×3 matrix mapping output UV to
// input UV — one pass regardless of how many controls are active. Sampling
// is bilinear below 2× zoom and Lanczos-2 at or above it (useLanczos).
// Auto-framing deltas are folded into zoom/pan before the matrix is built.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import Foundation
import Metal
import simd

public final class GeometryStage: EffectStage {
    public let id: StageID = .geometry
    public let cost: StageCost = .cheap
    public var isEnabled: Bool = true

    public var settings = GeometrySettings()

    /// Auto-framing (§5.4): smoothed deltas from AutoFramer, consumed here.
    /// `zoom` is a multiplier onto the user zoom (1 = none); `panX`/`panY`
    /// are additive pan deltas in croppable-margin fractions.
    /// Identity = (1, 0, 0); the pipeline resets to identity when auto-frame
    /// is off.
    public var autoFrameOffset: (zoom: Double, panX: Double, panY: Double) = (1, 0, 0)

    private let geometryPipeline: MTLComputePipelineState

    public init(metal: MetalContext) throws {
        geometryPipeline = try metal.computePipeline(function: "prism_geometry")
    }

    public func wantsEncode() -> Bool {
        guard isEnabled else { return false }
        if !settings.isIdentity { return true }
        return !autoFrameIsIdentity
    }

    private var autoFrameIsIdentity: Bool {
        abs(autoFrameOffset.zoom - 1) < 1e-4
            && abs(autoFrameOffset.panX) < 1e-4
            && abs(autoFrameOffset.panY) < 1e-4
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        var params = PRISMGeometryParams()
        params.uvTransform = buildUVTransform(
            inputSize: CGSize(width: input.width, height: input.height))
        params.useLanczos = effectiveValues().zoom >= 2 ? 1 : 0

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("GeometryStage: no compute encoder")
        }
        encoder.label = "GeometryStage"
        encoder.setComputePipelineState(geometryPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<PRISMGeometryParams>.stride, index: 0)
        dispatchOver(output, pipeline: geometryPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    // MARK: - Transform construction (public for tests)

    /// Builds the 3×3 output-UV → input-UV matrix (bottom row 0 0 1).
    ///
    /// Forward chain (input → output): crop window (crop aspect + zoom + pan)
    /// → fine rotation → orientation (with aspect-preserving fit for quarter
    /// turns) → mirror. This returns its inverse, composed right-to-left:
    /// center output UV → aspect space (so rotation does not shear) →
    /// mirror⁻¹ → orientation⁻¹ (incl. 1/fit) → rotation⁻¹ → back to UV →
    /// map the centered unit square onto the crop window. Out-of-range UVs
    /// render as opaque black in the kernel.
    public func buildUVTransform(inputSize: CGSize) -> simd_float3x3 {
        guard inputSize.width > 0, inputSize.height > 0 else {
            return matrix_identity_float3x3
        }
        let aspect = Float(inputSize.width / inputSize.height)
        let eff = effectiveValues()

        // Crop window in input UV: the largest centered region matching the
        // crop aspect, shrunk by zoom, panned within the croppable margin.
        var baseW = 1.0
        var baseH = 1.0
        if let targetRatio = settings.cropAspect.ratio {
            let inputRatio = Double(aspect)
            if targetRatio >= inputRatio {
                baseH = inputRatio / targetRatio
            } else {
                baseW = targetRatio / inputRatio
            }
        }
        let cropW = baseW / eff.zoom
        let cropH = baseH / eff.zoom
        let centerX = 0.5 + eff.panX * (1 - cropW) / 2
        let centerY = 0.5 + eff.panY * (1 - cropH) / 2

        let mirrorX: Float = (settings.mirror == .horizontal || settings.mirror == .both) ? -1 : 1
        let mirrorY: Float = (settings.mirror == .vertical || settings.mirror == .both) ? -1 : 1

        // Quarter turns get a uniform fit scale so rotated content is
        // letterboxed, never stretched (§5.3 ethos: never stretch).
        let quarterTurn = settings.orientation == .deg90 || settings.orientation == .deg270
        let fitScale: Float = quarterTurn ? min(aspect, 1 / aspect) : 1

        let fineRotation = Float(clampValue(settings.rotationDegrees, -15, 15)) * .pi / 180
        let orientationRotation = Float(settings.orientation.rawValue) * .pi / 180
        // Positive angles appear clockwise on screen (UV space is y-down).
        let totalRotation = fineRotation + orientationRotation

        var m = translationMatrix(-0.5, -0.5)
        m = scaleMatrix(aspect, 1) * m
        m = scaleMatrix(mirrorX, mirrorY) * m
        m = scaleMatrix(1 / fitScale, 1 / fitScale) * m
        m = rotationMatrix(-totalRotation) * m
        m = scaleMatrix(1 / aspect, 1) * m
        m = (translationMatrix(Float(centerX), Float(centerY))
            * scaleMatrix(Float(cropW), Float(cropH))) * m
        return m
    }

    /// Folds autoFrameOffset into the user zoom/pan (§5.4) before the matrix
    /// is built. Effective zoom stays within the stage's 1…4 range.
    private func effectiveValues() -> (zoom: Double, panX: Double, panY: Double) {
        let autoZoom = clampValue(autoFrameOffset.zoom, 1, 2.5)
        let zoom = clampValue(clampValue(settings.zoom, 1, 4) * autoZoom, 1, 4)
        let panX = clampValue(clampValue(settings.panX, -1, 1) + autoFrameOffset.panX, -1, 1)
        let panY = clampValue(clampValue(settings.panY, -1, 1) + autoFrameOffset.panY, -1, 1)
        return (zoom, panX, panY)
    }
}

// MARK: - Matrix helpers (column-major homogeneous 2D transforms)

private func translationMatrix(_ tx: Float, _ ty: Float) -> simd_float3x3 {
    simd_float3x3(columns: (SIMD3<Float>(1, 0, 0),
                            SIMD3<Float>(0, 1, 0),
                            SIMD3<Float>(tx, ty, 1)))
}

private func scaleMatrix(_ sx: Float, _ sy: Float) -> simd_float3x3 {
    simd_float3x3(columns: (SIMD3<Float>(sx, 0, 0),
                            SIMD3<Float>(0, sy, 0),
                            SIMD3<Float>(0, 0, 1)))
}

private func rotationMatrix(_ radians: Float) -> simd_float3x3 {
    let c = cos(radians)
    let s = sin(radians)
    return simd_float3x3(columns: (SIMD3<Float>(c, s, 0),
                                   SIMD3<Float>(-s, c, 0),
                                   SIMD3<Float>(0, 0, 1)))
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
