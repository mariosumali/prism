// StillRing.swift
// PRISM
//
// A few of the most recent *finished* frames, scored for sharpness, so a
// still is the best of the last moment rather than whatever happened to be
// on screen when the key went down (§5.16).
//
// Why not FrameRing. FrameRing holds the camera, upstream of every effect —
// that is what freeze needs, and it is the wrong picture entirely for a
// still: nobody wants a photo of the room they spent the call hiding, or of
// their unretouched face when the call saw the retouched one. This ring
// holds the output, which is the picture people actually saw.
//
// Why it holds so few. Each slot is a full output frame: measured 7.9 MB at
// 1080p and 31.7 MB at 4K, against a whole resident budget of 250 MB (§7).
// Six slots is a fifth of a second at 30 fps — long enough to step over a
// blink, which is the entire job — and it is only paid for while the
// "sharpest frame" setting is on. Disarmed, the ring holds nothing and costs
// nothing.
//
// How few is ResourceGovernor's call, between `minimumDepth` and
// `maximumDepth`. Four slots still clears a blink; below that the ring is
// paying full-frame prices for no real choice, so the governor gives it
// nothing and `sharpest` returns nil — which the pipeline already handles by
// saving the last frame, the honest answer to "save what I am looking at".
//
// Nothing is copied. The pipeline's output buffers come from a pool, and
// holding a reference is what keeps one out of the free list; the pool
// simply allocates a few more. A blit would cost the same memory and a GPU
// pass on every frame for an identical result.
//
// Licensed under the Apache License, Version 2.0.

import CoreVideo
import Foundation
import Metal

public final class StillRing {

    /// Six output frames — a fifth of a second at 30 fps. See the file header
    /// for why this is not larger.
    public static let maximumDepth = 6
    /// Four is 133 ms at 30 fps: still wider than a blink, so there is still
    /// something to choose between. See the file header for what happens
    /// below it.
    public static let minimumDepth = 4

    /// One Float per slot; prism_sharpness writes result[slot] on the GPU,
    /// `sharpest` reads it on the CPU (storageModeShared). Sized for
    /// `maximumDepth` so a depth change never reallocates it.
    public let sharpnessBuffer: MTLBuffer

    private struct Slot {
        var buffer: CVPixelBuffer
        var hostSeconds: Double
        var valid: Bool
    }

    private let lock = NSLock()
    private var slots: [Slot?]
    private var cursor = 0
    private var armed = false
    private var depth = StillRing.maximumDepth
    private var width = 0
    private var height = 0

    public init(metal: MetalContext) throws {
        guard let buffer = metal.device.makeBuffer(
            length: Self.maximumDepth * MemoryLayout<Float>.stride,
            options: .storageModeShared) else {
            throw PipelineError.textureAllocationFailed
        }
        sharpnessBuffer = buffer
        slots = [Slot?](repeating: nil, count: Self.maximumDepth)
    }

    public var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed && depth > 0
    }

    /// Disarming releases every held frame immediately: a feature nobody has
    /// switched on must not hold 50 MB of somebody's face.
    public func setArmed(_ armed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard armed != self.armed else { return }
        self.armed = armed
        if !armed {
            clearLocked()
        }
    }

    /// How many frames ResourceGovernor can afford here. Zero disables the
    /// ring without disarming the setting: the user's preference is still
    /// recorded, this format simply cannot pay for it.
    public func setDepth(_ depth: Int) {
        lock.lock()
        defer { lock.unlock() }
        let clamped = depth <= 0 ? 0 : min(Self.maximumDepth, max(1, depth))
        guard clamped != self.depth else { return }
        self.depth = clamped
        // Shrinking would otherwise leave frames parked in slots the cursor
        // no longer reaches, held for the life of the process.
        clearLocked()
    }

    /// Takes a reference to the finished frame and returns the slot whose
    /// sharpness the caller should encode, or -1 when there is nothing to do.
    ///
    /// The slot is not selectable until `publish` — the frame's own command
    /// buffer has not run yet, so the pixels are not final and the score has
    /// not been written.
    public func record(_ buffer: CVPixelBuffer, at hostSeconds: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard armed, depth > 0 else { return -1 }

        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        if bufferWidth != width || bufferHeight != height {
            // A format change makes every held frame the wrong size, and a
            // still saved at yesterday's resolution is a bug report.
            clearLocked()
            width = bufferWidth
            height = bufferHeight
        }

        let slot = cursor % depth
        cursor += 1
        slots[slot] = Slot(buffer: buffer, hostSeconds: hostSeconds, valid: false)
        return slot
    }

    /// Marks a recorded slot selectable, from the frame's completed handler.
    public func publish(slot: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(slot) else { return }
        slots[slot]?.valid = true
    }

    /// Sharpest held frame no older than `windowSeconds`, or nil when the
    /// ring is disarmed, empty, or everything in it has aged out.
    public func sharpest(now: Double, windowSeconds: Double) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard armed, depth > 0 else { return nil }
        let scores = sharpnessBuffer.contents().bindMemory(to: Float.self,
                                                           capacity: Self.maximumDepth)
        var best: (score: Float, buffer: CVPixelBuffer)?
        for (index, slot) in slots.enumerated() {
            guard let slot, slot.valid else { continue }
            let age = now - slot.hostSeconds
            guard age >= -0.001, age <= windowSeconds else { continue }
            let score = scores[index]
            if best == nil || score > best!.score {
                best = (score, slot.buffer)
            }
        }
        return best?.buffer
    }

    /// Caller holds `lock`.
    private func clearLocked() {
        for index in slots.indices { slots[index] = nil }
        cursor = 0
        let scores = sharpnessBuffer.contents().bindMemory(to: Float.self,
                                                           capacity: Self.maximumDepth)
        for index in 0..<Self.maximumDepth { scores[index] = 0 }
    }
}
