// BlurStage.swift
// PRISM
//
// Background blur (§5.4, .expensive). Person segmentation runs through
// VNGeneratePersonSegmentationRequest on a serial background queue, every
// 2nd frame, with the request input capped at 720p (and quality forced to
// .fast on Intel per SPEC). The visual pass is a separable Gaussian at half
// resolution (prism_blur H → V) followed by one prism_composite. Until the
// first mask arrives the stage passes the frame through. maskOnlyMode keeps
// segmentation running with no blur encode so auto-framing can consume
// latestSubjectBox, which is reduced CPU-side from the small mask buffer.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Vision
import simd

public final class BlurStage: EffectStage {
    public let id: StageID = .blur
    public let cost: StageCost = .expensive
    public var isEnabled: Bool = false

    public var settings = BlurSettings()

    /// Segmentation runs when blur is enabled OR auto-framing needs the mask.
    /// In mask-only mode encode() passes the frame through (one cheap copy)
    /// while still feeding Vision.
    public var maskOnlyMode: Bool = false

    /// Latest subject bounding box, normalized with top-left origin (y down),
    /// derived from the segmentation mask; nil when no subject is present.
    /// Thread-safe; written on the segmentation queue.
    public var latestSubjectBox: CGRect? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return subjectBox
    }

    // MARK: - Private state

    private let metal: MetalContext
    private let device: MTLDevice
    private let copyPipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState

    // Half-resolution blur scratch (capture queue only).
    private var scratchA: MTLTexture?
    private var scratchB: MTLTexture?

    // Segmentation plumbing. `stateLock` guards the slot indices, the mask
    // texture pointer, and the subject box; the slots' contents are protected
    // by the pending/busy protocol (a slot is written by the GPU only while
    // neither pending nor busy holds it for Vision).
    private let segQueue = DispatchQueue(label: "horse.prism.blur.segmentation",
                                         qos: .userInitiated)
    private let request = VNGeneratePersonSegmentationRequest()
    private let stateLock = NSLock()
    private var frameIndex: UInt64 = 0

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

    // Mask output. The pool rotates (segQueue only) so a texture is never
    // rewritten while in-flight GPU frames may still sample it; publication
    // of the latest texture/box happens under stateLock.
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

    public init(metal: MetalContext) throws {
        self.metal = metal
        self.device = metal.device
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        blurPipeline = try metal.computePipeline(function: "prism_blur")
        compositePipeline = try metal.computePipeline(function: "prism_composite")
        // Normalize the mask to 8-bit regardless of quality tier; the float
        // path in ingest(maskBuffer:) stays as a fallback.
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    public func wantsEncode() -> Bool {
        isEnabled || maskOnlyMode
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        frameIndex &+= 1

        // Kick Vision for the frame downsampled into LAST frame's command
        // buffer — one frame interval has elapsed, so its GPU work is done.
        dispatchPendingSegmentation()
        captureSegmentationFrameIfDue(commandBuffer: commandBuffer, input: input)

        stateLock.lock()
        let mask = maskTexture
        stateLock.unlock()

        if isEnabled, let mask {
            try encodeBlur(commandBuffer: commandBuffer, input: input,
                           output: output, mask: mask)
        } else {
            // Mask not yet available, or mask-only mode: pass through.
            try encodeCopy(commandBuffer: commandBuffer, source: input,
                           destination: output, label: "BlurStage.passThrough")
        }
    }

    // MARK: - Blur encoding

    private func encodeBlur(commandBuffer: MTLCommandBuffer,
                            input: MTLTexture,
                            output: MTLTexture,
                            mask: MTLTexture) throws {
        let halfW = max(1, input.width / 2)
        let halfH = max(1, input.height / 2)
        if scratchA == nil || scratchA?.width != halfW || scratchA?.height != halfH {
            scratchA = try metal.makeIntermediate(width: halfW, height: halfH)
            scratchB = try metal.makeIntermediate(width: halfW, height: halfH)
        }
        guard let scratchA, let scratchB else {
            throw PipelineError.textureAllocationFailed
        }

        // Downsample to half resolution — the Gaussian runs there for speed
        // and the composite samples the blurred background back up.
        try encodeCopy(commandBuffer: commandBuffer, source: input,
                       destination: scratchA, label: "BlurStage.downsample")

        // §5.4: radius is specified in pixels at 1080p, scaled by height;
        // halved again because the blur runs at half resolution.
        let fullRadius = max(1.0, settings.radius * Double(input.height) / 1080.0)
        let halfRadius = Float(max(0.5, fullRadius * 0.5))

        try encodeBlurPass(commandBuffer: commandBuffer, source: scratchA,
                           destination: scratchB,
                           direction: SIMD2<Float>(1, 0), radius: halfRadius,
                           label: "BlurStage.gaussianH")
        try encodeBlurPass(commandBuffer: commandBuffer, source: scratchB,
                           destination: scratchA,
                           direction: SIMD2<Float>(0, 1), radius: halfRadius,
                           label: "BlurStage.gaussianV")

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("BlurStage: no composite encoder")
        }
        var params = PRISMCompositeParams()
        params.maskContrast = 1
        encoder.label = "BlurStage.composite"
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(input, index: 0)      // sharp
        encoder.setTexture(scratchA, index: 1)   // blurred
        encoder.setTexture(mask, index: 2)       // person = 1
        encoder.setTexture(output, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<PRISMCompositeParams>.stride, index: 0)
        dispatchOver(output, pipeline: compositePipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func encodeBlurPass(commandBuffer: MTLCommandBuffer,
                                source: MTLTexture,
                                destination: MTLTexture,
                                direction: SIMD2<Float>,
                                radius: Float,
                                label: String) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("BlurStage: no blur encoder")
        }
        var params = PRISMBlurParams()
        params.direction = direction
        params.radius = radius
        encoder.label = label
        encoder.setComputePipelineState(blurPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<PRISMBlurParams>.stride, index: 0)
        dispatchOver(destination, pipeline: blurPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func encodeCopy(commandBuffer: MTLCommandBuffer,
                            source: MTLTexture,
                            destination: MTLTexture,
                            label: String) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("BlurStage: no copy encoder")
        }
        encoder.label = label
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        dispatchOver(destination, pipeline: copyPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    // MARK: - Segmentation scheduling

    private func dispatchPendingSegmentation() {
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
            self?.performSegmentation(on: buffer, quality: quality)
        }
    }

    private func captureSegmentationFrameIfDue(commandBuffer: MTLCommandBuffer,
                                               input: MTLTexture) {
        guard frameIndex % 2 == 0 else { return }   // every 2nd frame (§5.4)
        let target = cappedSegmentationSize(width: input.width, height: input.height)

        stateLock.lock()
        if segSlots.isEmpty || segSize != target {
            // Rebuild only while no slot is pending or under Vision.
            guard pendingSlot == nil, busySlot == nil else {
                stateLock.unlock()
                return
            }
            segSlots = makeSegmentationSlots(width: target.width, height: target.height)
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

        do {
            try encodeCopy(commandBuffer: commandBuffer, source: input,
                           destination: texture, label: "BlurStage.segDownsample")
            stateLock.lock()
            pendingSlot = slot
            stateLock.unlock()
        } catch {
            // No encoder this frame — skip this capture.
        }
    }

    /// Request input capped at 720p (§5.4) — everywhere, and mandatorily so
    /// on Intel, where quality is also forced to .fast.
    private func cappedSegmentationSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, 1280.0 / Double(max(1, width)), 720.0 / Double(max(1, height)))
        let w = max(64, Int((Double(width) * scale).rounded()) & ~1)
        let h = max(64, Int((Double(height) * scale).rounded()) & ~1)
        return (w, h)
    }

    private func makeSegmentationSlots(width: Int, height: Int) -> [SegSlot] {
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
        switch settings.quality {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }

    // MARK: - Segmentation (segQueue)

    private func performSegmentation(on pixelBuffer: CVPixelBuffer,
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

        let box = subjectBoundingBox(base: base, width: width, height: height,
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
    private func subjectBoundingBox(base: UnsafeRawPointer, width: Int, height: Int,
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
