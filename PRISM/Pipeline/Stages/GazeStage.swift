// GazeStage.swift
// PRISM
//
// Eye-contact correction (§5.6, .expensive). Sits before Geometry so the
// warp happens in the same space Vision measured the landmarks in — putting
// it after zoom/rotation would mean transforming every landmark through the
// geometry matrix to stay aligned, for no benefit.
//
// How the correction is derived. VNDetectFaceLandmarksRequest (76-point
// constellation) gives the eye contour and the pupil centre for each eye.
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
// Threading matches PersonSegmenter: detection on a private serial queue
// every other frame, results published under a lock, and the temporal
// smoothing applied at encode time on the frame queue so the motion is
// resolved at full frame rate rather than at detection rate.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Vision
import simd

public final class GazeStage: EffectStage {
    public let id: StageID = .gaze
    public let cost: StageCost = .expensive
    public var isEnabled: Bool = false

    public var settings = GazeSettings()

    /// True while a face with usable eye landmarks is being tracked. Drives
    /// the UI's "looking for your eyes…" state — a correction that silently
    /// does nothing is indistinguishable from one that is broken.
    public var isTracking: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return measurement != nil
    }

    // MARK: - Measurement types

    /// One eye as Vision saw it, in input UV (top-left origin, y down).
    struct EyeMeasurement: Equatable {
        var lidCenter: SIMD2<Float>
        var lidRadii: SIMD2<Float>
        var irisCenter: SIMD2<Float>
        var irisRadii: SIMD2<Float>
    }

    struct FaceMeasurement: Equatable {
        var left: EyeMeasurement?
        var right: EyeMeasurement?
    }

    // MARK: - Private state

    private let metal: MetalContext
    private let gazePipeline: MTLComputePipelineState
    private let copyPipeline: MTLComputePipelineState

    private let visionQueue = DispatchQueue(label: "horse.prism.gaze.landmarks",
                                            qos: .userInitiated)
    private let request: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        // Pupils only exist in the 76-point constellation; without them there
        // is nothing to measure the drift against.
        request.constellation = .constellation76Points
        return request
    }()
    private let stateLock = NSLock()

    private struct DetectSlot {
        let pixelBuffer: CVPixelBuffer
        let texture: MTLTexture
    }

    private var slots: [DetectSlot] = []
    private var slotSize: (width: Int, height: Int) = (0, 0)
    private var pendingSlot: Int?
    private var busySlot: Int?
    private var frameIndex: UInt64 = 0

    /// Latest raw measurement, written on visionQueue.
    private var measurement: FaceMeasurement?

    // Frame-queue-confined smoothing state.
    private var smoothedLeft: EyeMeasurement?
    private var smoothedRight: EyeMeasurement?
    private var confidenceLeft: Float = 0
    private var confidenceRight: Float = 0

    /// Confidence ramp: ~0.25 s at 30 fps in each direction. A correction
    /// that pops on and off as detection flickers is more distracting than
    /// no correction, so both edges are faded.
    private static let confidenceStep: Float = 0.13

    public init(metal: MetalContext) throws {
        self.metal = metal
        gazePipeline = try metal.computePipeline(function: "prism_gaze")
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    // MARK: - EffectStage

    /// Enabled is the whole condition, deliberately: detection is scheduled
    /// from inside `encode()`, so gating this on "are we tracking?" would
    /// mean the pass that acquires tracking never runs and the correction
    /// could never start — the stage would sit at "looking for your eyes…"
    /// forever. While no eye is valid `encode()` takes the copy path, which
    /// costs one blit and keeps the search alive.
    public func wantsEncode() -> Bool {
        isEnabled && settings.strength > 0
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        frameIndex &+= 1
        // Offset by one from PersonSegmenter's even-frame cadence so the two
        // Vision requests do not land on the same frame.
        dispatchPending()
        captureIfDue(commandBuffer: commandBuffer, input: input)

        stateLock.lock()
        let latest = measurement
        stateLock.unlock()

        let alpha = smoothingAlpha()
        smoothedLeft = blend(smoothedLeft, toward: latest?.left, alpha: alpha)
        smoothedRight = blend(smoothedRight, toward: latest?.right, alpha: alpha)
        confidenceLeft = ramp(confidenceLeft, present: latest?.left != nil)
        confidenceRight = ramp(confidenceRight, present: latest?.right != nil)

        var params = PRISMGazeParams()
        params.feather = Float(min(max(settings.feather, 0.05), 1))
        params.left = eyeParams(smoothedLeft, confidence: confidenceLeft)
        params.right = eyeParams(smoothedRight, confidence: confidenceRight)

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
        stateLock.lock()
        measurement = nil
        stateLock.unlock()
        smoothedLeft = nil
        smoothedRight = nil
        confidenceLeft = 0
        confidenceRight = 0
    }

    // MARK: - Warp construction (frame queue)

    /// Per-frame smoothing coefficient. `settings.smoothing` is expressed as
    /// "how much history to keep", so it maps to 1 − α.
    private func smoothingAlpha() -> Float {
        Float(1.0 - min(max(settings.smoothing, 0), 0.98))
    }

    private func blend(_ current: EyeMeasurement?,
                       toward target: EyeMeasurement?,
                       alpha: Float) -> EyeMeasurement? {
        guard let target else { return current }        // hold on dropout
        guard let current else { return target }        // snap on acquisition
        func mix(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            a + (b - a) * alpha
        }
        return EyeMeasurement(
            lidCenter: mix(current.lidCenter, target.lidCenter),
            lidRadii: mix(current.lidRadii, target.lidRadii),
            irisCenter: mix(current.irisCenter, target.irisCenter),
            irisRadii: mix(current.irisRadii, target.irisRadii))
    }

    private func ramp(_ value: Float, present: Bool) -> Float {
        let next = present ? value + Self.confidenceStep : value - Self.confidenceStep
        return min(max(next, 0), 1)
    }

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

    // MARK: - Detection scheduling (frame queue)

    private func dispatchPending() {
        stateLock.lock()
        guard busySlot == nil, let slot = pendingSlot, slot < slots.count else {
            stateLock.unlock()
            return
        }
        pendingSlot = nil
        busySlot = slot
        let buffer = slots[slot].pixelBuffer
        stateLock.unlock()

        visionQueue.async { [weak self] in
            self?.detect(in: buffer)
        }
    }

    private func captureIfDue(commandBuffer: MTLCommandBuffer, input: MTLTexture) {
        guard frameIndex % 2 == 1 else { return }
        let target = cappedSize(width: input.width, height: input.height)

        stateLock.lock()
        if slots.isEmpty || slotSize != target {
            guard pendingSlot == nil, busySlot == nil else {
                stateLock.unlock()
                return
            }
            slots = makeSlots(width: target.width, height: target.height)
            slotSize = target
        }
        guard !slots.isEmpty else {
            stateLock.unlock()
            return
        }
        let slot: Int
        if let busy = busySlot {
            slot = busy == 0 ? 1 : 0
        } else {
            slot = pendingSlot ?? 0
        }
        let texture = slots[slot].texture
        stateLock.unlock()

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "GazeStage.downsample"
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(texture, index: 1)
        dispatchOver(texture, pipeline: copyPipeline, encoder: encoder)
        encoder.endEncoding()

        stateLock.lock()
        pendingSlot = slot
        stateLock.unlock()
    }

    /// 720p cap, same reasoning as segmentation — but no lower: the pupil
    /// landmark's absolute precision is what sets how steady the warp looks,
    /// and it degrades with resolution faster than a silhouette does.
    private func cappedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, 1280.0 / Double(max(1, width)), 720.0 / Double(max(1, height)))
        let w = max(64, Int((Double(width) * scale).rounded()) & ~1)
        let h = max(64, Int((Double(height) * scale).rounded()) & ~1)
        return (w, h)
    }

    private func makeSlots(width: Int, height: Int) -> [DetectSlot] {
        var made: [DetectSlot] = []
        for _ in 0..<2 {
            var created: CVPixelBuffer?
            let attributes = prismPixelBufferAttributes(width: width, height: height)
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      prismPixelFormat,
                                      attributes as CFDictionary,
                                      &created) == kCVReturnSuccess,
                  let buffer = created,
                  let texture = try? metal.makeTexture(from: buffer) else {
                return []
            }
            made.append(DetectSlot(pixelBuffer: buffer, texture: texture))
        }
        return made
    }

    // MARK: - Vision (visionQueue)

    private func detect(in pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        var result: FaceMeasurement?
        do {
            try handler.perform([request])
            // Largest face wins: in a two-person frame the one filling more
            // of it is the one on this side of the camera.
            let faces = request.results ?? []
            if let face = faces.max(by: {
                $0.boundingBox.width * $0.boundingBox.height
                    < $1.boundingBox.width * $1.boundingBox.height
            }) {
                result = Self.measure(face: face,
                                      imageSize: CGSize(width: width, height: height))
            }
        } catch {
            result = nil
        }

        stateLock.lock()
        measurement = result
        busySlot = nil
        stateLock.unlock()
    }

    /// Converts one face observation into per-eye UV geometry.
    static func measure(face: VNFaceObservation, imageSize: CGSize) -> FaceMeasurement? {
        guard imageSize.width > 0, imageSize.height > 0,
              let landmarks = face.landmarks else { return nil }
        let left = eye(contour: landmarks.leftEye, pupil: landmarks.leftPupil,
                       imageSize: imageSize)
        let right = eye(contour: landmarks.rightEye, pupil: landmarks.rightPupil,
                        imageSize: imageSize)
        guard left != nil || right != nil else { return nil }
        return FaceMeasurement(left: left, right: right)
    }

    private static func eye(contour: VNFaceLandmarkRegion2D?,
                            pupil: VNFaceLandmarkRegion2D?,
                            imageSize: CGSize) -> EyeMeasurement? {
        guard let contour, contour.pointCount >= 4 else { return nil }
        let points = contour.pointsInImage(imageSize: imageSize)

        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let widthPx = maxX - minX
        let heightPx = maxY - minY
        guard widthPx > 1, heightPx > 0.5 else { return nil }

        // Vision is bottom-left origin; UV here is top-left. Flip y once,
        // at the boundary, so nothing downstream has to think about it.
        func toUV(x: Double, y: Double) -> SIMD2<Float> {
            SIMD2<Float>(Float(x / imageSize.width),
                         Float(1.0 - y / imageSize.height))
        }

        let lidCenter = toUV(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        // The falloff boundary sits just outside the visible opening so the
        // warp has reached zero by the time it meets the lid itself. The
        // vertical floor matters for narrowed eyes: a squint measures only a
        // few pixels tall, and a falloff that thin pinches the iris.
        let lidHalfW = widthPx * 0.62
        let lidHalfH = max(heightPx * 0.85, widthPx * 0.22)
        let lidRadii = SIMD2<Float>(Float(lidHalfW / imageSize.width),
                                    Float(lidHalfH / imageSize.height))

        // Vision does not report iris size. Anatomically the iris spans
        // roughly 45% of the palpebral fissure width, and it is circular in
        // *pixels* — hence one radius in px projected onto both UV axes.
        let irisRadiusPx = widthPx * 0.225
        let irisRadii = SIMD2<Float>(Float(irisRadiusPx / imageSize.width),
                                     Float(irisRadiusPx / imageSize.height))

        var irisCenter = lidCenter
        if let pupil, pupil.pointCount > 0 {
            let point = pupil.pointsInImage(imageSize: imageSize)[0]
            irisCenter = toUV(x: Double(point.x), y: Double(point.y))
        }

        return EyeMeasurement(lidCenter: lidCenter,
                              lidRadii: lidRadii,
                              irisCenter: irisCenter,
                              irisRadii: irisRadii)
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
