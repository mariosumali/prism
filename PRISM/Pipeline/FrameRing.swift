// FrameRing.swift
// PRISM
//
// Sharpest-frame buffer (§5.2): preallocated private Metal slots holding
// as much of the recent past as ResourceGovernor can afford at the negotiated
// format — half a second where there is room for it, never less than 200ms.
// record() blits the incoming frame into the next slot inside the frame's
// command buffer; the pipeline writes each slot's Laplacian-variance
// sharpness score into `sharpnessBuffer` via prism_sharpness and publishes
// the slot after committing the buffer. On freeze, the sharpest frame within
// the preceding window is read back CPU-side.
//
// The depth is a parameter rather than a rule of this file's own because it
// was a rule of this file's own — half a second at the frame rate — and half
// a second of raw 1080p60 measured 238 MB against a 250 MB ceiling (§7). The
// ring cannot decide that on its own: it does not know what else is holding
// frames.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import Foundation
import Metal

public final class FrameRing {
    /// Slots currently held, as granted by ResourceGovernor.
    public private(set) var capacity: Int
    /// One Float per slot; prism_sharpness writes result[slot] on the GPU,
    /// sharpestTexture reads it on the CPU (storageModeShared). Sized for
    /// `maxCapacity` so capacity changes never reallocate it.
    public let sharpnessBuffer: MTLBuffer

    /// Upper bound on slots (0.5s at 128fps — far above the §3.2 format set).
    private static let maxCapacity = ResourceGovernor.maximumFreezeDepth

    /// Clamped rather than trusted: a depth below the governor's own floor
    /// would leave freeze picking from a ring with nothing in it to choose
    /// between, which is the one thing the depth is allowed to cost.
    private static func clamp(_ depth: Int) -> Int {
        min(maxCapacity, max(ResourceGovernor.minimumFreezeDepth, depth))
    }

    private struct Slot {
        var texture: MTLTexture
        var time: CMTime
        var valid: Bool
    }

    private let metal: MetalContext
    private let lock = NSLock()
    private var slots: [Slot] = []
    private var cursor = 0
    private var width = 0
    private var height = 0

    public init(metal: MetalContext, width: Int, height: Int,
                depth: Int) throws {
        self.metal = metal
        self.capacity = Self.clamp(depth)
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

    /// Copy (GPU blit, private texture pool) the frame into the ring; returns the
    /// slot index, or -1 if the frame could not be recorded. The blit is
    /// encoded into the frame's own command buffer — never a separate pass.
    /// The slot stays invalid until the caller commits that command buffer
    /// and calls `publish(slot:)`; publishing at encode time would let a
    /// concurrent freeze pick snapshot the slot's previous (stale) occupant
    /// under the new timestamp.
    public func record(_ source: MTLTexture, at time: CMTime,
                       encoder commandBuffer: MTLCommandBuffer) -> Int {
        let bufferWidth = source.width
        let bufferHeight = source.height

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
        slots[slot].time = time
        let destination = slots[slot].texture
        lock.unlock()

        // VideoPipeline already wrapped the camera buffer to produce
        // `source`. Re-wrapping the same IOSurface here created a second
        // MTLTexture object on every sampled frame for no additional safety.
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            return -1
        }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
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
    public func sharpestTexture(nowTime: CMTime, windowMs: Double) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        let scores = sharpnessBuffer.contents().bindMemory(to: Float.self, capacity: capacity)
        var best: (score: Float, texture: MTLTexture)?
        for (index, slot) in slots.enumerated() where slot.valid && slot.time.isValid {
            let ageMs = CMTimeGetSeconds(CMTimeSubtract(nowTime, slot.time)) * 1000
            guard ageMs >= -0.5, ageMs <= windowMs else { continue }
            let score = scores[index]
            if best == nil || score > best!.score {
                best = (score, slot.texture)
            }
        }
        return best?.texture
    }

    public func reconfigure(width: Int, height: Int, depth: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        let newCapacity = Self.clamp(depth)
        guard width != self.width || height != self.height
            || newCapacity != capacity else { return }
        capacity = newCapacity
        try reallocateLocked(width: width, height: height)
    }

    // MARK: Private

    /// Preallocates private GPU textures so record() never allocates on the
    /// frame path. The ring is internal to the Metal pipeline; IOSurfaces are
    /// useful for frames that cross an API/process boundary, but made these
    /// slots permanently CPU-visible for no benefit. Private textures retain
    /// the exact pixels while allowing native tiled/compressed GPU storage.
    /// Caller holds `lock`.
    private func reallocateLocked(width: Int, height: Int) throws {
        var newSlots: [Slot] = []
        newSlots.reserveCapacity(capacity)
        for _ in 0..<capacity {
            let texture = try metal.makeIntermediate(width: width, height: height)
            newSlots.append(Slot(texture: texture,
                                 time: .invalid, valid: false))
        }
        slots = newSlots
        self.width = width
        self.height = height
        cursor = 0
        let scores = sharpnessBuffer.contents().bindMemory(to: Float.self, capacity: capacity)
        for index in 0..<capacity { scores[index] = 0 }
    }
}
