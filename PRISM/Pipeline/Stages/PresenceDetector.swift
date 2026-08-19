// PresenceDetector.swift
// PRISM
//
// Is there a person in front of this camera (§5.28). One `VNDetectHuman-
// RectanglesRequest`, upper body only, on a coordinated modality with a slow
// cadence, demanded only while presence automation is switched on.
//
// Why this request and not one of the two obvious alternatives:
//
//   - Not the person mask. It is already there, and reading it would look
//     free — but it is only there while somebody else wants it, and presence
//     watching is on for the whole meeting. Demanding `.person` for it would
//     pin the single most expensive request in the pipeline on permanently,
//     for a question that never needed a per-pixel silhouette. Segmentation
//     exists to composite a background; asking it whether a chair is occupied
//     is paying six milliseconds a frame for one bit a second.
//   - Not frame differencing. It is nearly free and it answers the wrong
//     question: it measures motion, not presence. The person it would declare
//     absent first is the one sitting still and reading, which is both the
//     commonest way to be present and the worst possible false trigger. It
//     also moves with the camera's own gain and noise, so the threshold that
//     works in daylight is the one that fires at dusk.
//
// A human-rectangle request is the cheapest thing that actually answers the
// question asked. It runs on a 360-line downsample — presence is a question
// about whether a person-shaped thing occupies a few percent of the frame,
// which survives losing three quarters of the pixels the segmenter is given —
// and at a cadence of 15 it competes for roughly one frame a second, which is
// two orders of magnitude more often than a feature measured in seconds
// needs.
//
// Threading follows PersonSegmenter and FaceTracker exactly: `update` is
// called from the pipeline's frame queue, the request runs on a private
// serial queue, and a slot is written by the GPU only while neither pending
// nor busy holds it. Samples are published under the lock and handed on
// through `onSample`, which fires on the Vision queue — the consumer hops.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Vision

public final class PresenceDetector {

    /// One measurement. The sequence number exists because the consumer polls
    /// as well as listens, and integrating the same observation twice would
    /// double the rate the away clock advances at.
    public struct Sample: Equatable {
        public var coverage: Double
        public var date: Date
        public var sequence: UInt64

        public init(coverage: Double, date: Date, sequence: UInt64) {
            self.coverage = coverage
            self.date = date
            self.sequence = sequence
        }
    }

    /// Whether anything currently wants presence measured. Recomputed by the
    /// pipeline each frame from the coordinator's decision, exactly like the
    /// segmenter's and the tracker's.
    public var isDemanded: Bool = false

    /// Fires once per completed detection, on the Vision queue. Never on the
    /// frame path, and never while holding anything the frame path takes.
    public var onSample: ((Sample) -> Void)?

    /// Latest measurement. Thread-safe.
    public var latestSample: Sample? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sample
    }

    public init(metal: MetalContext) throws {
        self.metal = metal
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    /// One presence step for the frame: dispatches the frame captured into an
    /// EARLIER command buffer (at least a frame interval has elapsed, so its
    /// GPU work is done) and captures this one when the coordinator says this
    /// is presence's frame. Call at most once per frame, on the frame queue.
    public func update(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                       capture: Bool) {
        dispatchPending()
        if capture {
            captureFrame(commandBuffer: commandBuffer, input: input)
        }
    }

    /// Drops the measurement when demand goes to zero, so watching that
    /// resumes in ten minutes' time starts from no evidence rather than from
    /// whoever was last in the room.
    public func invalidate() {
        stateLock.lock()
        sample = nil
        stateLock.unlock()
    }

    // MARK: - Private state

    private let metal: MetalContext
    private let copyPipeline: MTLComputePipelineState

    private let visionQueue = DispatchQueue(label: "horse.prism.presence",
                                            qos: .utility)
    private let request: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        // Upper body only. A seated person's legs are under the desk, so the
        // full-body detector is looking for evidence the shot does not
        // contain — and the torso is what leaves the frame when they stand up.
        request.upperBodyOnly = true
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

    private var sample: Sample?
    private var sequence: UInt64 = 0

    /// Below this a detection is a guess, and a guess in either direction is
    /// worse than no observation: a false positive keeps the away loop from
    /// ever starting, a false negative starts it while somebody is sitting
    /// there. Vision's own scores for a person at desk distance sit well
    /// above it.
    static let minimumConfidence: Float = 0.35

    // MARK: - Scheduling (frame queue)

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
        encoder.label = "PresenceDetector.downsample"
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(texture, index: 1)
        dispatchOver(texture, pipeline: copyPipeline, encoder: encoder)
        encoder.endEncoding()

        stateLock.lock()
        pendingSlot = slot
        stateLock.unlock()
    }

    /// 360 lines rather than the 720 segmentation and landmarks are capped at.
    /// Neither the threshold nor the hysteresis can tell the difference — the
    /// answer is a box area compared against a few percent — and a quarter of
    /// the pixels is a quarter of the work on the one modality that runs for
    /// the whole meeting.
    private func cappedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, 640.0 / Double(max(1, width)), 360.0 / Double(max(1, height)))
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
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        var coverage: Double = 0
        do {
            try handler.perform([request])
            coverage = Self.coverage(of: request.results ?? [])
        } catch {
            // A request that threw measured nothing. Reporting zero would be
            // reporting an empty room, which is a claim this failure cannot
            // support — so it publishes nothing and the clock does not move.
            stateLock.lock()
            busySlot = nil
            stateLock.unlock()
            return
        }

        stateLock.lock()
        sequence &+= 1
        let published = Sample(coverage: coverage, date: Date(), sequence: sequence)
        sample = published
        busySlot = nil
        stateLock.unlock()
        onSample?(published)
    }

    /// The largest detected person, as a fraction of the frame. Largest wins
    /// for the same reason it does for faces: in a room with somebody walking
    /// past behind, the one filling more of the shot is the one on this side
    /// of the camera. Summing them instead would let a corridor of passers-by
    /// hold the frame "occupied" while the user was in the kitchen.
    static func coverage(of observations: [VNHumanObservation]) -> Double {
        var best: Double = 0
        for observation in observations
        where observation.confidence >= minimumConfidence {
            let box = observation.boundingBox
            best = max(best, Double(box.width * box.height))
        }
        return min(max(best, 0), 1)
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
