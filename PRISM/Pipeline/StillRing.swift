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
// Why it holds so few. Each slot is a full output frame: ~8 MB at 1080p,
// and the app's whole resident budget is 250 MB (§7). Six slots is a fifth
// of a second at 30 fps — long enough to step over a blink, which is the
// entire job — and it is only paid for while the "sharpest frame" setting
// is on. Disarmed, the ring holds nothing and costs nothing.
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

    /// Six output frames. See the file header for why this is not larger.
    public static let capacity = 6

    /// One Float per slot; prism_sharpness writes result[slot] on the GPU,
    /// `sharpest` reads it on the CPU (storageModeShared).
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
    private var width = 0
    private var height = 0

    public init(metal: MetalContext) throws {
        guard let buffer = metal.device.makeBuffer(
            length: Self.capacity * MemoryLayout<Float>.stride,
            options: .storageModeShared) else {
            throw PipelineError.textureAllocationFailed
        }
        sharpnessBuffer = buffer
        slots = [Slot?](repeating: nil, count: Self.capacity)
    }

    public var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed
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

    /// Takes a reference to the finished frame and returns the slot whose
    /// sharpness the caller should encode, or -1 when there is nothing to do.
    ///
    /// The slot is not selectable until `publish` — the frame's own command
    /// buffer has not run yet, so the pixels are not final and the score has
    /// not been written.
    public func record(_ buffer: CVPixelBuffer, at hostSeconds: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return -1 }

        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        if bufferWidth != width || bufferHeight != height {
            // A format change makes every held frame the wrong size, and a
            // still saved at yesterday's resolution is a bug report.
            clearLocked()
            width = bufferWidth
            height = bufferHeight
        }

        let slot = cursor % Self.capacity
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
        guard armed else { return nil }
        let scores = sharpnessBuffer.contents().bindMemory(to: Float.self,
                                                           capacity: Self.capacity)
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
                                                           capacity: Self.capacity)
        for index in 0..<Self.capacity { scores[index] = 0 }
    }
}
