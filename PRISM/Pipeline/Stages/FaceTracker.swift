// FaceTracker.swift
// PRISM
//
// One face measurement, several consumers: the eye-contact warp (§5.6), and
// the skin retouch and face-anchored overlay layers that read it next. Same
// argument as PersonSegmenter, and the same shape — a 76-point landmark
// request is the second most expensive thing in the pipeline, so two stages
// each running their own would cost twice as much for identical numbers.
//
// Extracted from GazeStage, which used to own this outright and threw away
// everything except the two eyes. The mechanics are unchanged: a
// VNDetectFaceLandmarksRequest on a private serial queue, request input
// capped at 720p, largest face wins.
//
// When it runs is not this file's decision. VisionCoordinator owns the duty
// cycle — this tracker asks for every other frame and takes what it is given,
// because a third modality competing for the same frames has to slow
// everything proportionally rather than quietly displace one of them.
//
// Threading. `update` is called from the pipeline's frame queue at the eye
// contact stage's position in the chain — pre-geometry, so the measurements
// are in the space Vision saw them in and the warp needs no transform back.
// Vision runs on `visionQueue`; a slot is written by the GPU only while
// neither pending nor busy holds it. The raw sample is published under the
// lock on completion, while the temporal smoothing and the confidence ramps
// run in `update` on the frame queue — so the motion resolves at full frame
// rate rather than at detection rate.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Vision
import simd

public final class FaceTracker {

    // MARK: - Measurement types

    /// One eye as Vision saw it, in input UV (top-left origin, y down).
    public struct EyeMeasurement: Equatable {
        public var lidCenter: SIMD2<Float>
        public var lidRadii: SIMD2<Float>
        public var irisCenter: SIMD2<Float>
        public var irisRadii: SIMD2<Float>
    }

    /// One face in the same top-left-origin normalized space the eyes use, so
    /// nothing downstream has to know which convention Vision reports in.
    public struct FaceSample: Equatable {
        public var box: CGRect
        /// In-plane head tilt, radians, 0 when Vision does not report one.
        public var roll: Float
        public var left: EyeMeasurement?
        public var right: EyeMeasurement?

        /// A face can be tracked without either eye being measurable — a
        /// profile turn, or a squint the landmark model gives up on — and the
        /// eye-driven features have to decline in that case rather than warp
        /// against the last eyes they saw.
        public var hasEyes: Bool { left != nil || right != nil }
    }

    /// Acquisition/loss ramps. Per eye as well as per face because each eye is
    /// corrected on its own evidence: a head turn loses one long before the
    /// other, and a correction that pops on and off as detection flickers is
    /// more distracting than no correction, so every edge is faded.
    public struct Confidence: Equatable {
        public var face: Float = 0
        public var left: Float = 0
        public var right: Float = 0
    }

    // MARK: - Public surface

    /// How much history the per-frame smoothing keeps. Pushed from the gaze
    /// settings by the pipeline; it is the only knob any consumer exposes,
    /// exactly like PersonSegmenter.quality.
    public var smoothing: Double = GazeSettings().smoothing

    /// Whether anything currently wants a face. Recomputed by the pipeline
    /// each frame from live stage state, so nothing runs Vision once the last
    /// consumer is switched off.
    public var isDemanded: Bool = false

    /// Latest raw sample, exactly as measured. Thread-safe.
    public var latestFace: FaceSample? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return faceSample
    }

    /// Latest smoothed sample — what consumers should drive geometry from.
    /// Thread-safe.
    public var smoothedFace: FaceSample? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return smoothedSample
    }

    /// Thread-safe.
    public var confidence: Confidence {
        stateLock.lock()
        defer { stateLock.unlock() }
        return confidenceRamps
    }

    /// True while a face is being measured at all.
    public var isTracking: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return faceSample != nil
    }

    /// True while that face carries usable eye landmarks. Drives the UI's
    /// "looking for your eyes…" state — a correction that silently does
    /// nothing is indistinguishable from one that is broken.
    public var hasEyes: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return faceSample?.hasEyes ?? false
    }

    public init(metal: MetalContext) throws {
        self.metal = metal
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    /// One tracking step for the frame: dispatches the frame captured into an
    /// EARLIER command buffer (at least a frame interval has elapsed, so its
    /// GPU work is done), captures this one for the next dispatch when the
    /// coordinator says this is the tracker's frame, and advances the
    /// smoothing and the ramps. Call at most once per frame, on the frame
    /// queue.
    ///
    /// The smoothing runs whether or not this frame carries a capture: the
    /// motion has to resolve at frame rate, not at detection rate, and that
    /// is the whole reason eye contact survives being measured every other
    /// frame — or, once a third modality is competing, rather less often.
    public func update(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                       capture: Bool) {
        dispatchPending()
        if capture {
            captureFrame(commandBuffer: commandBuffer, input: input)
        }

        stateLock.lock()
        let latest = faceSample
        let previous = smoothedSample
        var ramps = confidenceRamps
        stateLock.unlock()

        let next = Self.blend(previous, toward: latest, alpha: smoothingAlpha())
        ramps.face = Self.ramp(ramps.face, present: latest != nil)
        ramps.left = Self.ramp(ramps.left, present: latest?.left != nil)
        ramps.right = Self.ramp(ramps.right, present: latest?.right != nil)

        stateLock.lock()
        smoothedSample = next
        confidenceRamps = ramps
        stateLock.unlock()
    }

    /// Drops the face so a consumer re-enabled later never anchors to where
    /// the head was minutes ago. Called when demand goes to zero.
    public func invalidate() {
        stateLock.lock()
        faceSample = nil
        smoothedSample = nil
        stateLock.unlock()
    }

    /// invalidate() plus the ramps, so a re-enabled consumer fades in from
    /// nothing exactly as it does on first acquisition.
    public func reset() {
        stateLock.lock()
        faceSample = nil
        smoothedSample = nil
        confidenceRamps = Confidence()
        stateLock.unlock()
    }

    // MARK: - Private state

    private let metal: MetalContext
    private let copyPipeline: MTLComputePipelineState

    private let visionQueue = DispatchQueue(label: "horse.prism.face.landmarks",
                                            qos: .userInitiated)
    private let request: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        // Pupils only exist in the 76-point constellation; without them there
        // is nothing to measure the gaze drift against.
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

    /// Written on visionQueue.
    private var faceSample: FaceSample?
    private var smoothedSample: FaceSample?
    private var confidenceRamps = Confidence()

    /// Confidence ramp: ~0.25 s at 30 fps in each direction.
    private static let confidenceStep: Float = 0.13

    // MARK: - Smoothing (frame queue)

    /// Per-frame smoothing coefficient. `smoothing` is expressed as "how much
    /// history to keep", so it maps to 1 − α.
    private func smoothingAlpha() -> Float {
        Float(1.0 - min(max(smoothing, 0), 0.98))
    }

    private static func blend(_ current: FaceSample?,
                              toward target: FaceSample?,
                              alpha: Float) -> FaceSample? {
        guard let target else { return current }        // hold on dropout
        guard let current else { return target }        // snap on acquisition
        let box = CGRect(
            x: mix(current.box.minX, target.box.minX, alpha),
            y: mix(current.box.minY, target.box.minY, alpha),
            width: mix(current.box.width, target.box.width, alpha),
            height: mix(current.box.height, target.box.height, alpha))
        return FaceSample(box: box,
                          roll: current.roll + (target.roll - current.roll) * alpha,
                          left: blend(current.left, toward: target.left, alpha: alpha),
                          right: blend(current.right, toward: target.right, alpha: alpha))
    }

    private static func blend(_ current: EyeMeasurement?,
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

    private static func mix(_ a: CGFloat, _ b: CGFloat, _ alpha: Float) -> CGFloat {
        a + (b - a) * CGFloat(alpha)
    }

    private static func ramp(_ value: Float, present: Bool) -> Float {
        let next = present ? value + confidenceStep : value - confidenceStep
        return min(max(next, 0), 1)
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

    private func captureFrame(commandBuffer: MTLCommandBuffer, input: MTLTexture) {
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
        encoder.label = "FaceTracker.downsample"
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

        var result: FaceSample?
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
        faceSample = result
        busySlot = nil
        stateLock.unlock()
    }

    /// Converts one face observation into the shared measurement.
    static func measure(face: VNFaceObservation, imageSize: CGSize) -> FaceSample? {
        guard imageSize.width > 0, imageSize.height > 0,
              let landmarks = face.landmarks else { return nil }
        // Vision is bottom-left origin; the flip happens once here, for the
        // box exactly as for the landmark points.
        let box = CGRect(x: face.boundingBox.minX,
                         y: 1.0 - face.boundingBox.maxY,
                         width: face.boundingBox.width,
                         height: face.boundingBox.height)
        return FaceSample(box: box,
                          roll: face.roll?.floatValue ?? 0,
                          left: eye(contour: landmarks.leftEye, pupil: landmarks.leftPupil,
                                    imageSize: imageSize),
                          right: eye(contour: landmarks.rightEye, pupil: landmarks.rightPupil,
                                     imageSize: imageSize))
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
