// HandTracker.swift
// PRISM
//
// What shape is the hand in front of this camera (§5.31). One
// `VNDetectHumanHandPoseRequest` on the coordinated `hands` modality, demanded
// only while gesture triggers are switched on and bound to something.
//
// The modality existed before this file did: `VisionCoordinator.Modality` has
// carried a `hands` case, deliberately unregistered, since the schedule
// replaced the two hard-coded parities — and VisionCoordinatorTests pins that
// an unregistered modality never runs however loudly it is demanded. So
// arriving here is a registration and a demand closure rather than a change to
// the schedule, which is what keeps eye contact's cadence exactly what it was.
//
// Cadence 3, not 2. A gesture is a thing held for the better part of a second
// and the recogniser only has to see it several times; the eye-contact warp is
// applied to every frame and slips visibly the moment its landmarks age. At
// cadence 3 the hands ask for one frame in three, get roughly one in five
// under full contention, and still produce six sightings inside the shortest
// hold the settings allow.
//
// Threading follows PersonSegmenter, FaceTracker and PresenceDetector
// exactly: `update` on the pipeline's frame queue, the request on a private
// serial queue, two rotating downsample slots, samples published under the
// lock and handed on through `onSample` from the Vision queue.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Vision

public final class HandTracker {

    /// One reading. `pose` is nil whenever the request ran and saw nothing it
    /// recognises, which is most of the time and is a real observation — the
    /// watch needs it to end a dwell. The sequence number exists because a
    /// consumer that integrated the same reading twice would satisfy a hold
    /// in half the time it asked for.
    public struct Sample: Equatable {
        public var pose: HandPose?
        public var confidence: Double
        public var date: Date
        public var sequence: UInt64

        public init(pose: HandPose?, confidence: Double, date: Date,
                    sequence: UInt64) {
            self.pose = pose
            self.confidence = confidence
            self.date = date
            self.sequence = sequence
        }
    }

    /// Whether anything currently wants hands measured. Recomputed by the
    /// pipeline each frame from the coordinator's decision, exactly like the
    /// segmenter's, the tracker's and the presence detector's.
    public var isDemanded: Bool = false

    /// Fires once per completed detection, on the Vision queue. Never on the
    /// frame path, and never while holding anything the frame path takes.
    public var onSample: ((Sample) -> Void)?

    public var latestSample: Sample? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sample
    }

    public init(metal: MetalContext) throws {
        self.metal = metal
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    /// One hand-pose step for the frame: dispatches the frame captured into an
    /// EARLIER command buffer (at least a frame interval has elapsed, so its
    /// GPU work is done) and captures this one when the coordinator says this
    /// is the hands' frame. Call at most once per frame, on the frame queue.
    public func update(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                       capture: Bool) {
        dispatchPending()
        if capture {
            captureFrame(commandBuffer: commandBuffer, input: input)
        }
    }

    /// Drops the reading when demand goes to zero, so a recogniser switched
    /// back on in ten minutes' time starts from no evidence rather than from
    /// whatever shape the user's hand was in when they turned it off.
    public func invalidate() {
        stateLock.lock()
        sample = nil
        stateLock.unlock()
    }

    // MARK: - Private state

    private let metal: MetalContext
    private let copyPipeline: MTLComputePipelineState

    private let visionQueue = DispatchQueue(label: "horse.prism.hands",
                                            qos: .utility)
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        // Both hands. One would be cheaper and is the wrong trade: with a cap
        // of one, Vision returns whichever hand it likes best, and the hand
        // resting on the mouse routinely wins over the one being held up —
        // which reads as the gesture failing rather than as a cap being hit.
        request.maximumHandCount = 2
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

    /// Per-landmark floor. Below this a joint's position is a guess, and one
    /// guessed fingertip is the difference between a fist and a Victory. This
    /// is not the user's confidence setting — that one is applied to the
    /// finished pose by GestureWatch; this one decides whether there is a
    /// pose to score at all.
    static let minimumJointConfidence: Float = 0.5

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
        encoder.label = "HandTracker.downsample"
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(texture, index: 1)
        dispatchOver(texture, pipeline: copyPipeline, encoder: encoder)
        encoder.endEncoding()

        stateLock.lock()
        pendingSlot = slot
        stateLock.unlock()
    }

    /// 540 lines: half again what presence gets and three quarters of what
    /// segmentation does. Presence compares a box area against a few percent
    /// and survives losing three quarters of the pixels; this has to separate
    /// a ring finger from a little finger, and a hand at desk distance is
    /// about a fifth of the frame height — 100-odd pixels here, and closer to
    /// 70 at presence's size, which is where the joints start reading as
    /// noise.
    private func cappedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, 960.0 / Double(max(1, width)), 540.0 / Double(max(1, height)))
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
        let reading: (pose: HandPose?, confidence: Double)
        do {
            try handler.perform([request])
            reading = Self.bestPose(in: request.results ?? [])
        } catch {
            // A request that threw observed nothing. Publishing "no pose"
            // would end a dwell the user is halfway through on the strength
            // of a failure, so it publishes nothing at all.
            stateLock.lock()
            busySlot = nil
            stateLock.unlock()
            return
        }

        stateLock.lock()
        sequence &+= 1
        let published = Sample(pose: reading.pose, confidence: reading.confidence,
                               date: Date(), sequence: sequence)
        sample = published
        busySlot = nil
        stateLock.unlock()
        onSample?(published)
    }

    /// The most confident recognised pose among the hands in shot, or nil
    /// with confidence 0 when none of them is making one.
    ///
    /// Most confident rather than first: with both hands visible, the one
    /// held up deliberately is the one whose joints Vision is sure about, and
    /// the one holding a coffee is not. Summing or preferring the larger hand
    /// would both pick the nearer one, which is the one on the desk.
    static func bestPose(in observations: [VNHumanHandPoseObservation])
    -> (pose: HandPose?, confidence: Double) {
        var best: (pose: HandPose, confidence: Double)?
        for observation in observations {
            guard let joints = jointPoints(of: observation) else { continue }
            guard let pose = HandPoseClassifier.classify(joints: joints.points) else { continue }
            if best == nil || joints.confidence > best!.confidence {
                best = (pose, joints.confidence)
            }
        }
        guard let best else { return (nil, 0) }
        return (best.pose, best.confidence)
    }

    /// The nine joints the classifier reads, in normalised image coordinates,
    /// plus the weakest landmark's confidence as the reading's own. Weakest
    /// rather than mean: the pose is only as trustworthy as the finger Vision
    /// was least sure of, and averaging lets three clean fingers carry one
    /// invented one over the floor.
    static func jointPoints(of observation: VNHumanHandPoseObservation)
    -> (points: [HandJoint: CGPoint], confidence: Double)? {
        let map: [(HandJoint, VNHumanHandPoseObservation.JointName)] = [
            (.wrist, .wrist),
            (.indexTip, .indexTip), (.indexPIP, .indexPIP),
            (.middleTip, .middleTip), (.middlePIP, .middlePIP),
            (.ringTip, .ringTip), (.ringPIP, .ringPIP),
            (.littleTip, .littleTip), (.littlePIP, .littlePIP),
        ]
        var points: [HandJoint: CGPoint] = [:]
        var weakest: Float = 1
        for (joint, name) in map {
            guard let point = try? observation.recognizedPoint(name),
                  point.confidence >= minimumJointConfidence else {
                return nil
            }
            points[joint] = point.location
            weakest = min(weakest, point.confidence)
        }
        return (points, Double(weakest))
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
