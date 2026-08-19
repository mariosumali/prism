// PersonSegmenter.swift
// PRISM
//
// One person mask, four consumers: background blur, virtual background,
// overlay layers placed behind the subject, and auto-framing's subject box
// (§5.4, §5.7, §5.8). Segmentation is the single most expensive thing in the
// pipeline, so running it once per frame and sharing the result is the
// difference between "background blur costs 6 ms" and "background blur plus
// a virtual background costs 12 ms for the same information".
//
// Extracted from BlurStage, which used to own this outright. The mechanics
// are unchanged: VNGeneratePersonSegmentationRequest on a serial background
// queue, request input capped at 720p (and quality forced to .fast on Intel
// per SPEC §5.4).
//
// When it runs is VisionCoordinator's decision, not this file's. The
// segmenter asks for every 2nd frame and takes what it is given.
//
// Threading. `update` is called from the pipeline's frame queue at the blur
// stage's position in the chain — post-geometry, so the mask is aligned with
// everything that consumes it, and so AutoFramer stays the closed-loop servo
// it is documented to be. The Vision request runs on `segQueue`; a slot is
// written by the GPU only while neither pending nor busy holds it. Mask
// textures rotate through a pool so a texture is never rewritten while an
// in-flight frame may still be sampling it.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Vision

public final class PersonSegmenter {

    // MARK: - Public surface

    /// Quality tier, mapped straight onto Vision's (§5.4). Set from the blur
    /// settings; it is the only knob any consumer exposes.
    public var quality: BlurQuality = .balanced

    /// Latest mask, single channel, person = 1. Thread-safe.
    public var latestMask: MTLTexture? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return maskTexture
    }

    /// Latest subject bounding box, normalized with top-left origin (y down),
    /// nil when no subject is present. Thread-safe.
    public var latestSubjectBox: CGRect? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return subjectBox
    }

    /// Whether anything currently wants a mask. Recomputed by the pipeline
    /// each frame from live stage state, so the degradation engine turning
    /// blur off does not silently strand auto-framing — and, conversely,
    /// nothing runs Vision when no consumer is left.
    public var isDemanded: Bool = false

    public init(metal: MetalContext) throws {
        self.metal = metal
        self.device = metal.device
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        // Normalize the mask to 8-bit regardless of quality tier; the float
        // path in ingest(maskBuffer:) stays as a fallback.
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// One segmentation step for the frame. Dispatches the frame captured
    /// into an EARLIER command buffer (at least a frame interval has elapsed,
    /// so its GPU work is done) and captures this one for the next dispatch
    /// when the coordinator says this is segmentation's frame. Call at most
    /// once per frame, on the frame queue.
    public func update(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                       capture: Bool) {
        dispatchPending()
        if capture {
            captureFrame(commandBuffer: commandBuffer, input: input)
        }
    }

    /// Drops the mask so a consumer re-enabled later never composites against
    /// a stale subject from minutes ago. Called when demand goes to zero.
    public func invalidate() {
        stateLock.lock()
        maskTexture = nil
        subjectBox = nil
        stateLock.unlock()
    }

    // MARK: - Private state

    private let metal: MetalContext
    private let device: MTLDevice
    private let copyPipeline: MTLComputePipelineState

    private let segQueue = DispatchQueue(label: "horse.prism.segmentation",
                                         qos: .userInitiated)
    private let request = VNGeneratePersonSegmentationRequest()
    private let stateLock = NSLock()

    private struct SegSlot {
        let pixelBuffer: CVPixelBuffer
        let texture: MTLTexture
    }

    private var segSlots: [SegSlot] = []
    private var segSize: (width: Int, height: Int) = (0, 0)
    /// Slot downsampled into last frame's command buffer, awaiting dispatch.
    private var pendingSlot: Int?
    /// Slot currently being read by Vision on segQueue.
    private var busySlot: Int?

    private var maskTexture: MTLTexture?
    private var subjectBox: CGRect?
    private var maskPool: [MTLTexture] = []
    private var maskPoolIndex = 0

    private static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }()

    // MARK: - Scheduling

    private func dispatchPending() {
        stateLock.lock()
        guard busySlot == nil, let slot = pendingSlot, slot < segSlots.count else {
            stateLock.unlock()
            return
        }
        pendingSlot = nil
        busySlot = slot
        let buffer = segSlots[slot].pixelBuffer
        stateLock.unlock()

        let quality = effectiveQuality()
        segQueue.async { [weak self] in
            self?.perform(on: buffer, quality: quality)
        }
    }

    private func captureFrame(commandBuffer: MTLCommandBuffer, input: MTLTexture) {
        let target = cappedSize(width: input.width, height: input.height)

        stateLock.lock()
        if segSlots.isEmpty || segSize != target {
            // Rebuild only while no slot is pending or under Vision.
            guard pendingSlot == nil, busySlot == nil else {
                stateLock.unlock()
                return
            }
            segSlots = makeSlots(width: target.width, height: target.height)
            segSize = target
        }
        guard !segSlots.isEmpty else {
            stateLock.unlock()
            return
        }
        let slot: Int
        if let busy = busySlot {
            slot = busy == 0 ? 1 : 0
        } else if let pending = pendingSlot {
            slot = pending                       // refresh with a newer frame
        } else {
            slot = 0
        }
        let texture = segSlots[slot].texture
        stateLock.unlock()

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "PersonSegmenter.downsample"
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(texture, index: 1)
        dispatchOver(texture, pipeline: copyPipeline, encoder: encoder)
        encoder.endEncoding()

        stateLock.lock()
        pendingSlot = slot
        stateLock.unlock()
    }

    /// Request input capped at 720p (§5.4) — everywhere, and mandatorily so
    /// on Intel, where quality is also forced to .fast.
    private func cappedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, 1280.0 / Double(max(1, width)), 720.0 / Double(max(1, height)))
        let w = max(64, Int((Double(width) * scale).rounded()) & ~1)
        let h = max(64, Int((Double(height) * scale).rounded()) & ~1)
        return (w, h)
    }

    private func makeSlots(width: Int, height: Int) -> [SegSlot] {
        var slots: [SegSlot] = []
        for _ in 0..<2 {
            var created: CVPixelBuffer?
            let attributes = prismPixelBufferAttributes(width: width, height: height)
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                             prismPixelFormat,
                                             attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let buffer = created,
                  let texture = try? metal.makeTexture(from: buffer) else {
                return []
            }
            slots.append(SegSlot(pixelBuffer: buffer, texture: texture))
        }
        return slots
    }

    private func effectiveQuality() -> VNGeneratePersonSegmentationRequest.QualityLevel {
        guard Self.isAppleSilicon else { return .fast }   // §5.4: Intel → fast
        switch quality {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }

    // MARK: - Vision (segQueue)

    private func perform(on pixelBuffer: CVPixelBuffer,
                         quality: VNGeneratePersonSegmentationRequest.QualityLevel) {
        request.qualityLevel = quality
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        var maskBuffer: CVPixelBuffer?
        do {
            try handler.perform([request])
            maskBuffer = request.results?.first?.pixelBuffer
        } catch {
            maskBuffer = nil
        }
        if let maskBuffer {
            ingest(maskBuffer: maskBuffer)
        }
        stateLock.lock()
        busySlot = nil
        stateLock.unlock()
    }

    private func ingest(maskBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(maskBuffer) else { return }

        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        let format = CVPixelBufferGetPixelFormatType(maskBuffer)

        let textureFormat: MTLPixelFormat
        switch format {
        case kCVPixelFormatType_OneComponent8: textureFormat = .r8Unorm
        case kCVPixelFormatType_OneComponent32Float: textureFormat = .r32Float
        default: return
        }

        guard width > 0, height > 0,
              let texture = nextMaskTexture(width: width, height: height,
                                            format: textureFormat) else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)

        let box = Self.subjectBoundingBox(base: base, width: width, height: height,
                                          bytesPerRow: bytesPerRow, format: format)

        stateLock.lock()
        maskTexture = texture
        subjectBox = box
        stateLock.unlock()
    }

    private func nextMaskTexture(width: Int, height: Int,
                                 format: MTLPixelFormat) -> MTLTexture? {
        if maskPool.isEmpty
            || maskPool[0].width != width
            || maskPool[0].height != height
            || maskPool[0].pixelFormat != format {
            var pool: [MTLTexture] = []
            for _ in 0..<3 {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: width, height: height,
                    mipmapped: false)
                descriptor.usage = [.shaderRead]
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    return nil
                }
                pool.append(texture)
            }
            maskPool = pool
            maskPoolIndex = 0
        }
        let texture = maskPool[maskPoolIndex]
        maskPoolIndex = (maskPoolIndex + 1) % maskPool.count
        return texture
    }

    /// CPU reduction of the small mask buffer (§5.4 auto-framing): rows are
    /// scanned for person pixels (mask ≥ 0.5) to produce a normalized
    /// top-left-origin bounding box. Runs on segQueue; mask resolutions are
    /// small so a full scan is cheap.
    static func subjectBoundingBox(base: UnsafeRawPointer, width: Int, height: Int,
                                   bytesPerRow: Int, format: OSType) -> CGRect? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        var count = 0
        if format == kCVPixelFormatType_OneComponent8 {
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width where row[x] >= 128 {
                    count += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        } else {
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow)
                    .assumingMemoryBound(to: Float.self)
                for x in 0..<width where row[x] >= 0.5 {
                    count += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        // Below ~0.25% coverage is noise, not a subject.
        let minimumCount = max(16, (width * height) / 400)
        guard count >= minimumCount, maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: Double(minX) / Double(width),
                      y: Double(minY) / Double(height),
                      width: Double(maxX - minX + 1) / Double(width),
                      height: Double(maxY - minY + 1) / Double(height))
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
