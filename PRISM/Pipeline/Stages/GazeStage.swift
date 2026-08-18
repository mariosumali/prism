// GazeStage.swift
// PRISM
//
// Eye-contact correction (§5.6, .expensive). Sits before Geometry so the
// warp happens in the same space Vision measured the landmarks in — putting
// it after zoom/rotation would mean transforming every landmark through the
// geometry matrix to stay aligned, for no benefit.
//
// How the correction is derived. The shared FaceTracker's 76-point
// constellation gives the eye contour and the pupil centre for each eye.
// When someone looks into the lens, the pupil sits near the centre of the
// palpebral fissure; when they look at the screen instead, it sits off
// centre — down for the usual camera-above-display laptop, sideways for a
// monitor beside the webcam. So the correction needs no knowledge of where
// the camera is mounted: it measures how far the pupil has drifted from the
// centre of its own eye opening and pulls back a `strength` fraction of it.
// A setup where centred is not the truth (an oddly mounted external camera)
// is handled by `verticalBias` on top.
//
// What this is and is not. The redirection itself is a geometric warp
// (Gaze.metal), driven by an on-device ML landmark model. It is not a
// learned image-to-image gaze synthesiser — it moves the iris you have
// rather than generating the one you would have had. That is the honest
// trade at this latency budget, and it is why `maxShift` clamps rather than
// extrapolates: past roughly half an iris width the sclera stretch becomes
// visible, and a subtly-wrong eye is far better than an uncanny one.
//
// The measurement itself is not owned here: the tracker is driven once per
// frame by the pipeline, at this stage's position in the chain, and shared
// with every other face-anchored feature. This stage only reads it.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal
import simd

public final class GazeStage: EffectStage {
    public let id: StageID = .gaze
    public let cost: StageCost = .expensive
    public var isEnabled: Bool = false

    public var settings = GazeSettings()

    /// True while a face with usable eye landmarks is being tracked. Drives
    /// the UI's "looking for your eyes…" state — a correction that silently
    /// does nothing is indistinguishable from one that is broken.
    public var isTracking: Bool { faceTracker.hasEyes }

    /// The measurement types live on the tracker now; the correction is still
    /// expressed in terms of one eye, so the name stays here.
    public typealias EyeMeasurement = FaceTracker.EyeMeasurement

    // MARK: - Private state

    private let faceTracker: FaceTracker
    private let gazePipeline: MTLComputePipelineState
    private let copyPipeline: MTLComputePipelineState

    public init(metal: MetalContext, faceTracker: FaceTracker) throws {
        self.faceTracker = faceTracker
        gazePipeline = try metal.computePipeline(function: "prism_gaze")
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    // MARK: - EffectStage

    /// Enabled is the whole condition, deliberately: this is also the gate the
    /// pipeline drives face tracking from, so gating it on "are we tracking?"
    /// would mean the pass that acquires tracking never runs and the
    /// correction could never start — the stage would sit at "looking for your
    /// eyes…" forever. While no eye is valid `encode()` takes the copy path,
    /// which costs one blit and keeps the search alive.
    public func wantsEncode() -> Bool {
        isEnabled && settings.strength > 0
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        let face = faceTracker.smoothedFace
        let confidence = faceTracker.confidence

        var params = PRISMGazeParams()
        params.feather = Float(min(max(settings.feather, 0.05), 1))
        params.left = eyeParams(face?.left, confidence: confidence.left)
        params.right = eyeParams(face?.right, confidence: confidence.right)

        let pipeline = (params.left.valid > 0 || params.right.valid > 0)
            ? gazePipeline : copyPipeline

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("GazeStage: no compute encoder")
        }
        encoder.label = "GazeStage"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        if pipeline === gazePipeline {
            encoder.setBytes(&params, length: MemoryLayout<PRISMGazeParams>.stride, index: 0)
        }
        dispatchOver(output, pipeline: pipeline, encoder: encoder)
        encoder.endEncoding()
    }

    /// Clears tracking state so a stage re-enabled later does not warp using
    /// where the eyes were before it was switched off.
    public func reset() {
        faceTracker.reset()
    }

    // MARK: - Warp construction (frame queue)

    private func eyeParams(_ eye: EyeMeasurement?, confidence: Float) -> PRISMGazeEye {
        var params = PRISMGazeEye()
        guard let eye, confidence > 0.001 else {
            params.valid = 0
            return params
        }
        params.valid = 1
        params.lidCenter = eye.lidCenter
        params.lidRadii = eye.lidRadii
        params.irisCenter = eye.irisCenter
        params.irisRadii = eye.irisRadii
        params.shift = Self.shift(for: eye,
                                  settings: settings,
                                  confidence: confidence)
        return params
    }

    /// The whole correction, in one place and free of Metal/Vision types so
    /// it can be reasoned about (and tested) directly.
    ///
    /// The drift of the pupil from the centre of its own eye opening is the
    /// measured gaze error; removing `strength` of it aims the eyes back at
    /// the lens. `verticalBias` adds a fixed nudge for mounts where centred
    /// is not the truth. The result is clamped to `maxShift` iris radii,
    /// then scaled by the tracking confidence so acquisition and loss fade.
    static func shift(for eye: EyeMeasurement,
                      settings: GazeSettings,
                      confidence: Float) -> SIMD2<Float> {
        let drift = eye.irisCenter - eye.lidCenter
        var shift = -drift * Float(min(max(settings.strength, 0), 1))

        // Positive bias = camera above the screen, so the eyes need lifting,
        // which is −y in a top-left-origin UV space.
        shift.y -= Float(min(max(settings.verticalBias, -1), 1))
            * eye.irisRadii.y * 0.25

        let limit = eye.irisRadii * Float(min(max(settings.maxShift, 0), 1))
        shift.x = min(max(shift.x, -limit.x), limit.x)
        shift.y = min(max(shift.y, -limit.y), limit.y)
        return shift * min(max(confidence, 0), 1)
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
