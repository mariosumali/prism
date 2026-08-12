// FrameRing.swift
// PRISM
//
// 500ms sharpest-frame buffer (§5.2): preallocated IOSurface-backed slots
// sized to half a second at the active frame rate (15 at 30fps, 30 at
// 60fps). record() blits the incoming frame into the next slot inside the
// frame's command buffer; the pipeline writes each slot's Laplacian-variance
// sharpness score into `sharpnessBuffer` via prism_sharpness and publishes
// the slot after committing the buffer. On freeze, the sharpest frame within
// the preceding window is read back CPU-side.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreVideo
import Foundation
import Metal

public final class FrameRing {
    /// ~500ms of frames at the active rate: ceil(0.5 × fps), floor 15 (§5.2).
    public private(set) var capacity: Int
    /// One Float per slot; prism_sharpness writes result[slot] on the GPU,
    /// sharpestFrame reads it on the CPU (storageModeShared). Sized for
    /// `maxCapacity` so capacity changes never reallocate it.
    public let sharpnessBuffer: MTLBuffer

    /// Upper bound on slots (0.5s at 128fps — far above the §3.2 format set).
    private static let maxCapacity = 64

    private static func capacity(forFrameRate frameRate: Int) -> Int {
        min(maxCapacity, max(15, Int((Double(max(1, frameRate)) * 0.5).rounded(.up))))
    }

    private struct Slot {
        var pixelBuffer: CVPixelBuffer
        var texture: MTLTexture
        var time: CMTime
        var valid: Bool
    }

    private let metal: MetalContext
    private let lock = NSLock()
    private var slots: [Slot] = []
    private var pool: CVPixelBufferPool?
    private var cursor = 0
    private var width = 0
    private var height = 0

    public init(metal: MetalContext, width: Int, height: Int,
                frameRate: Int = 30) throws {
        self.metal = metal
        self.capacity = Self.capacity(forFrameRate: frameRate)
        guard let buffer = metal.device.makeBuffer(
            length: Self.maxCapacity * MemoryLayout<Float>.stride,
            options: .storageModeShared) else {
            throw PipelineError.textureAllocationFailed
        }
        self.sharpnessBuffer = buffer
        lock.lock()
        defer { lock.unlock() }
        try reallocateLocked(width: width, height: height)
    }

    /// Copy (GPU blit, IOSurface pool) the frame into the ring; returns the
    /// slot index, or -1 if the frame could not be recorded. The blit is
    /// encoded into the frame's own command buffer — never a separate pass.
    /// The slot stays invalid until the caller commits that command buffer
    /// and calls `publish(slot:)`; publishing at encode time would let a
    /// concurrent freeze pick snapshot the slot's previous (stale) occupant
    /// under the new timestamp.
    public func record(_ buffer: CVPixelBuffer, at time: CMTime,
                       encoder commandBuffer: MTLCommandBuffer) -> Int {
        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)

        lock.lock()
        if bufferWidth != width || bufferHeight != height {
            // Defensive: the pipeline reconfigures on format change before
            // recording; if a stray frame arrives at the wrong size, resize.
            do {
                try reallocateLocked(width: bufferWidth, height: bufferHeight)
            } catch {
                lock.unlock()
                return -1
            }
        }
        let slot = cursor % capacity
        cursor += 1
        slots[slot].valid = false                 // in flight until blit encoded
        let destination = slots[slot].texture
        lock.unlock()

        guard let source = try? metal.makeTexture(from: buffer),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return -1
        }
        blit.copy(from: source, to: destination)
        blit.endEncoding()

        lock.lock()
        slots[slot].time = time
        lock.unlock()
        return slot
    }

    /// Marks a recorded slot selectable, after the frame's command buffer has
    /// been committed (queue order then guarantees any later snapshot blit
    /// sees the slot's new contents).
    public func publish(slot: Int) {
        lock.lock()
        if slots.indices.contains(slot), slots[slot].time.isValid {
            slots[slot].valid = true
        }
        lock.unlock()
    }

    /// Sharpest stored frame within [now − windowMs, now] (§5.2: windowMs
    /// 300). Reads sharpnessBuffer CPU-side. The most recent slot's score may
    /// still be pending GPU write and read one frame stale — a benign
    /// approximation over a 300ms window.
    public func sharpestFrame(nowTime: CMTime, windowMs: Double) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let scores = sharpnessBuffer.contents().bindMemory(to: Float.self, capacity: capacity)
        var best: (score: Float, buffer: CVPixelBuffer)?
        for (index, slot) in slots.enumerated() where slot.valid && slot.time.isValid {
            let ageMs = CMTimeGetSeconds(CMTimeSubtract(nowTime, slot.time)) * 1000
            guard ageMs >= -0.5, ageMs <= windowMs else { continue }
            let score = scores[index]
            if best == nil || score > best!.score {
                best = (score, slot.pixelBuffer)
            }
        }
        return best?.buffer
    }

    public func reconfigure(width: Int, height: Int, frameRate: Int = 30) throws {
        lock.lock()
        defer { lock.unlock() }
        let newCapacity = Self.capacity(forFrameRate: frameRate)
        guard width != self.width || height != self.height
            || newCapacity != capacity else { return }
        capacity = newCapacity
        try reallocateLocked(width: width, height: height)
    }

    // MARK: Private

    /// Preallocates all slots (buffer + stable texture wrapper) so record()
    /// never allocates on the frame path. Caller holds `lock`.
    private func reallocateLocked(width: Int, height: Int) throws {
        let bufferAttrs = prismPixelBufferAttributes(width: width, height: height)
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: capacity,
        ]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                      poolAttrs as CFDictionary,
                                      bufferAttrs as CFDictionary,
                                      &newPool) == kCVReturnSuccess,
              let createdPool = newPool else {
            throw PipelineError.textureAllocationFailed
        }
        var newSlots: [Slot] = []
        newSlots.reserveCapacity(capacity)
        for _ in 0..<capacity {
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                     createdPool,
                                                     &pixelBuffer) == kCVReturnSuccess,
                  let created = pixelBuffer else {
                throw PipelineError.textureAllocationFailed
            }
            let texture = try metal.makeTexture(from: created)
            newSlots.append(Slot(pixelBuffer: created, texture: texture,
                                 time: .invalid, valid: false))
        }
        pool = createdPool
        slots = newSlots
        self.width = width
        self.height = height
        cursor = 0
        let scores = sharpnessBuffer.contents().bindMemory(to: Float.self, capacity: capacity)
        for index in 0..<capacity { scores[index] = 0 }
    }
}
