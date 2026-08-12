// AudioSink.swift
// PRISM
//
// Thin real-time-safe wrapper over the shared-memory audio ring (SPEC §4.3).
// PRISM.app is the producer; the AudioServerPlugIn inside coreaudiod is the
// consumer. `write` and `writeSilence` only call the wait-free C ring API and
// are safe on the audio render thread.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public final class AudioSink {

    /// Mapped shared-memory ring; nil after `close()`.
    private var ring: UnsafeMutablePointer<PRISMRingBuffer>?

    /// Preallocated zero block so `writeSilence` never allocates on the
    /// render thread.
    private let silence: UnsafeMutablePointer<Float>
    private static let silenceChunkFrames = 4096

    /// Fails when the shared region cannot be created or mapped.
    public init?() {
        let sampleCount = Self.silenceChunkFrames * Int(PRISM_CHANNELS)
        let zeroBlock = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        zeroBlock.initialize(repeating: 0, count: sampleCount)
        silence = zeroBlock

        guard let mapped = PRISMRingBufferCreateProducer() else {
            // deinit does not run for a failed class init; release manually.
            zeroBlock.deallocate()
            return nil
        }
        ring = mapped
    }

    deinit {
        close()
        silence.deallocate()
    }

    /// Interleaved stereo 48 kHz floats. RT-safe: calls the C ring API only.
    public func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0, let ring else { return }
        PRISMRingBufferWrite(ring, samples, UInt32(frameCount))
    }

    /// Writes zeros (mic muted ≠ ring stalled). RT-safe; chunked through the
    /// preallocated silence block.
    public func writeSilence(frameCount: Int) {
        guard frameCount > 0, let ring else { return }
        var remaining = frameCount
        while remaining > 0 {
            let chunk = min(remaining, Self.silenceChunkFrames)
            PRISMRingBufferWrite(ring, silence, UInt32(chunk))
            remaining -= chunk
        }
    }

    /// Times the consumer outran the producer (§4.3). Monitoring only.
    /// `_Atomic` fields are invisible to Swift, so the counters are read
    /// through the C shims rather than by offset into the mapped struct.
    public var underruns: UInt32 {
        guard let ring else { return 0 }
        return PRISMRingBufferUnderrunCount(ring)
    }

    /// Times the producer outran the consumer and oldest frames were dropped.
    public var overruns: UInt32 {
        guard let ring else { return 0 }
        return PRISMRingBufferOverrunCount(ring)
    }

    /// Whether the HAL plug-in is installed (§9: onboarding step 3).
    public static var isPlugInInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/PRISM.driver")
    }

    /// Raw ring pointer for real-time consumers that must not touch managed
    /// references (SPEC §4.3: no Swift ARC traffic inside IO callbacks).
    /// Valid until `close()`; the owner must stop any RT user first.
    public var ringPointer: UnsafeMutablePointer<PRISMRingBuffer>? { ring }

    /// Preallocated zero block (4096 frames of interleaved stereo) for RT
    /// silence writes without allocation.
    public var silencePointer: UnsafePointer<Float> { UnsafePointer(silence) }
    public static var silenceBlockFrames: Int { silenceChunkFrames }

    /// Clears producerAlive and unmaps. Call after audio capture has stopped;
    /// not safe concurrently with `write`/`writeSilence`. Idempotent.
    public func close() {
        guard let mapped = ring else { return }
        ring = nil
        PRISMRingBufferCloseProducer(mapped)
    }
}
