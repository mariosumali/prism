// MicCheck.swift
// PRISM
//
// The §5.13 mic check: record a few seconds of the microphone and play it
// back, the way Zoom's mic test does. The recording is tapped *after* the
// voice changer, so what plays back is exactly what the ring — and therefore
// everyone on the call — receives; it is the one way to actually hear your
// own effect, since PRISM publishes a microphone rather than monitoring one.
//
// Three pieces: MicTapRing (the RT-fed ring AudioCapture writes into while
// the check is armed), MicCheck (the main-thread state machine the UI
// observes), and MicCheckSpeaker (AVAudioEngine playback to the default
// output). The tap is passive — arming it never touches the on-air path.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import Foundation

// MARK: - MicTapRing

/// Single-producer/single-consumer tap ring: the RT callback writes the
/// post-effect mono signal, the main thread reads it out at its leisure.
/// The write side is RT-safe — memcpy into preallocated memory, then one
/// release-store of the monotonic head through the C shim (§4.3-grade
/// wait-free, the same discipline as the shared SHM ring). The reader's
/// acquire-load of the head therefore guarantees every sample below it is
/// fully visible: no safety lag, no torn reads, and a take can start at the
/// exact head observed when the tap was armed.
final class MicTapRing {

    let capacityFrames: Int
    private let mask: Int
    private let data: UnsafeMutablePointer<Float>
    /// Monotonic frames written. Heap-allocated so the C atomic shims can
    /// address it; the writer owns it (plain reads of its own last store),
    /// the reader only ever acquire-loads.
    private let written: UnsafeMutablePointer<UInt64>
    /// Largest single write the producer will make, used to size the margin
    /// kept between a lapped reader and the head. AudioCapture sets it from
    /// its worst post-conversion slice while the RT unit is stopped.
    private var maxWriteFrames = 4096

    /// Capacity must be a power of two (mask indexing). The default holds
    /// ~2.7 s — the reader polls ~10×/s, so the backlog stays tiny.
    init(capacityFrames: Int = 1 << 17) {
        precondition(capacityFrames > 0
                     && capacityFrames & (capacityFrames - 1) == 0,
                     "capacity must be a power of two")
        self.capacityFrames = capacityFrames
        mask = capacityFrames - 1
        data = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
        data.initialize(repeating: 0, count: capacityFrames)
        written = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        written.initialize(to: 0)
    }

    deinit {
        data.deallocate()
        written.deinitialize(count: 1)
        written.deallocate()
    }

    /// Producer-side configuration; call only while the RT unit is stopped.
    func setMaxWriteFrames(_ frames: Int) {
        maxWriteFrames = max(frames, 1)
    }

    // MARK: RT side

    /// Appends mono samples. RT-safe: no allocation, no locks; the head
    /// store is a single release instruction.
    func writeMono(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let head = written.pointee            // writer-private, plain read
        var cursor = Int(truncatingIfNeeded: head) & mask
        var remaining = frameCount
        var source = samples
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - cursor)
            memcpy(data + cursor, source, chunk * MemoryLayout<Float>.size)
            cursor = (cursor + chunk) & mask
            source += chunk
            remaining -= chunk
        }
        PRISMAtomicU64StoreRelease(written, head &+ UInt64(frameCount))
    }

    /// Appends interleaved stereo as a mono mixdown. RT-safe.
    func writeStereoMixdown(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let head = written.pointee
        var cursor = Int(truncatingIfNeeded: head) & mask
        for i in 0..<frameCount {
            data[cursor] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5
            cursor = (cursor + 1) & mask
        }
        PRISMAtomicU64StoreRelease(written, head &+ UInt64(frameCount))
    }

    // MARK: Main-thread side

    /// The write head. Everything below it is fully written and safe to
    /// read (acquire pairs with the writer's release). This is also the
    /// correct start-of-take marker: a recording begun at `head` contains
    /// only frames written after arming, never a previous take's tail.
    var head: UInt64 {
        PRISMAtomicU64LoadAcquire(written)
    }

    /// Copies frames written since `cursor` into `buffer`, up to `maxFrames`.
    /// A cursor ahead of the head (or exactly at it) reads nothing and is
    /// returned unchanged; a cursor the ring has already lapped is skipped
    /// forward to the oldest frame that cannot be overwritten mid-copy
    /// (one worst-case write of margin below the head). Returns the advanced
    /// cursor and the frame count actually copied.
    func read(from cursor: UInt64, into buffer: UnsafeMutablePointer<Float>,
              maxFrames: Int) -> (cursor: UInt64, frames: Int) {
        let end = head
        guard end > cursor else { return (cursor, 0) }
        var start = cursor
        // The margin never eats more than half the ring, so a deliberately
        // tiny test ring still has a readable window.
        let margin = min(maxWriteFrames, capacityFrames / 2)
        let keep = UInt64(capacityFrames - margin)
        if end - start > keep {
            start = end - keep
        }
        let count = min(Int(end - start), max(maxFrames, 0))
        guard count > 0 else { return (start, 0) }

        var index = Int(truncatingIfNeeded: start) & mask
        var destination = buffer
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - index)
            memcpy(destination, data + index, chunk * MemoryLayout<Float>.size)
            index = (index + chunk) & mask
            destination += chunk
            remaining -= chunk
        }
        return (start + UInt64(count), count)
    }
}

// MARK: - Playback

/// The playback seam, a protocol so tests can swap the speaker out.
protocol MicCheckPlaying: AnyObject {
    /// Plays mono samples to the default output. Returns false when playback
    /// cannot start; `completion` fires on the main thread when the take
    /// finishes on its own (not when stopped).
    @discardableResult
    func play(_ samples: [Float], sampleRate: Double,
              completion: @escaping () -> Void) -> Bool
    func stop()
}

/// AVAudioEngine playback to the system default output. Not on any RT path —
/// this is a user-initiated, seconds-long preview in PRISM's own process.
final class MicCheckSpeaker: MicCheckPlaying {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    @discardableResult
    func play(_ samples: [Float], sampleRate: Double,
              completion: @escaping () -> Void) -> Bool {
        stop()
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return false
        }
        // .dataPlayedBack, not the legacy consumed callback: the buffer is
        // "consumed" while its tail is still in flight through the mixer and
        // the output device, and stopping the engine there clips the end of
        // every playback.
        player.scheduleBuffer(buffer, at: nil, options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                // Stopped playback fires the callback too; only a take that
                // is still current reports completion.
                guard let self, self.player === player else { return }
                self.stop()
                completion()
            }
        }
        player.play()
        self.engine = engine
        self.player = player
        return true
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}

// MARK: - MicCheck

/// The record-then-play-back state machine (§5.13). Owned by AppState; the
/// UI observes it directly, the same pattern as Permissions and PresetStore.
@MainActor
public final class MicCheck: ObservableObject {

    public enum Phase: Equatable {
        case idle, recording, playing
    }

    @Published public private(set) var phase: Phase = .idle
    /// Input level while recording, 0…1, perceptually scaled for the meter.
    @Published public private(set) var level: Double = 0
    @Published public private(set) var recordedSeconds: Double = 0
    /// The last take contained nothing but silence — the one diagnosis worth
    /// naming, because it means the microphone picker points at the wrong
    /// device, not that the effect is broken.
    @Published public private(set) var heardNothing = false

    public var hasTake: Bool { !take.isEmpty }

    public static let maxSeconds: Double = 5
    static let sampleRate: Double = 48_000
    private static let maxTakeFrames = Int(maxSeconds * sampleRate)
    /// Peak below this is silence — the same gate the pitch detector uses.
    private static let silenceFloor: Float = 0.004

    private let armTap: (Bool) -> Void
    private let tapCursor: () -> UInt64
    private let readTap: (UInt64, UnsafeMutablePointer<Float>, Int) -> (UInt64, Int)
    private let player: MicCheckPlaying

    private var cursor: UInt64 = 0
    private var take: [Float] = []
    private var scratch: [Float]
    private var pollTimer: Timer?
    /// Bumped on every transition so a stale playback completion (or a
    /// stopped one) cannot yank a newer state back to idle.
    private var generation = 0
    /// Wall-clock backstop: the frame-count cap cannot fire when the tap
    /// starves (mute mid-take, capture torn down, device gone), so the
    /// recording also ends on elapsed time — the ≤ maxSeconds promise holds
    /// even when no audio is arriving. Injectable for tests.
    private var recordingStartedAt = Date.distantPast
    var now: () -> Date = Date.init

    init(armTap: @escaping (Bool) -> Void,
         tapCursor: @escaping () -> UInt64,
         readTap: @escaping (UInt64, UnsafeMutablePointer<Float>, Int) -> (UInt64, Int),
         player: MicCheckPlaying = MicCheckSpeaker()) {
        self.armTap = armTap
        self.tapCursor = tapCursor
        self.readTap = readTap
        self.player = player
        scratch = [Float](repeating: 0, count: 16_384)
        take.reserveCapacity(Self.maxTakeFrames)
    }

    convenience init(capture: AudioCapture) {
        self.init(
            armTap: { capture.setMicTapArmed($0) },
            tapCursor: { capture.micTapCursor },
            readTap: { capture.readMicTap(from: $0, into: $1, maxFrames: $2) })
    }

    // MARK: Intents

    /// One button, three phases: start recording, stop-and-play, stop.
    public func toggle() {
        switch phase {
        case .idle: beginRecording()
        case .recording: finishRecording()
        case .playing: stopPlayback()
        }
    }

    /// Replays the last take without recording a new one.
    public func replay() {
        guard phase == .idle, hasTake else { return }
        play()
    }

    /// Hard stop from any phase; used on quit and teardown.
    public func cancel() {
        pollTimer?.invalidate()
        pollTimer = nil
        armTap(false)
        player.stop()
        generation += 1
        phase = .idle
        level = 0
    }

    // MARK: Recording

    private func beginRecording() {
        heardNothing = false
        take.removeAll(keepingCapacity: true)
        recordedSeconds = 0
        level = 0
        armTap(true)
        cursor = tapCursor()
        generation += 1
        recordingStartedAt = now()
        phase = .recording
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Drains the tap into the take. Internal so tests can drive the clock.
    func pollOnce() {
        guard phase == .recording else { return }
        let drained = drainTap()
        if drained > 0 {
            level = Self.displayLevel(of: take.suffix(drained))
        } else {
            // Decay rather than freeze on a quiet gap.
            level *= Self.meterDecay
        }
        recordedSeconds = Double(take.count) / Self.sampleRate
        if take.count >= Self.maxTakeFrames {
            finishRecording()
        } else if now().timeIntervalSince(recordingStartedAt) > Self.maxSeconds + 1 {
            // One second of grace over the frame cap covers poll jitter;
            // past that the tap has starved and holding .recording forever
            // would strand the UI on a frozen countdown.
            finishRecording()
        }
    }

    /// Copies everything the tap has into `take`, capped at the max length.
    /// Returns the number of frames appended.
    private func drainTap() -> Int {
        var appended = 0
        while take.count < Self.maxTakeFrames {
            let room = min(scratch.count, Self.maxTakeFrames - take.count)
            var got = 0
            scratch.withUnsafeMutableBufferPointer { buffer in
                let (next, frames) = readTap(cursor, buffer.baseAddress!, room)
                cursor = next
                got = frames
            }
            guard got > 0 else { break }
            take.append(contentsOf: scratch.prefix(got))
            appended += got
        }
        return appended
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        armTap(false)
        _ = drainTap()
        recordedSeconds = Double(take.count) / Self.sampleRate
        level = 0
        let peak = take.reduce(Float(0)) { max($0, abs($1)) }
        if peak < Self.silenceFloor {
            // Playing back silence proves nothing; say what it means instead.
            take.removeAll(keepingCapacity: true)
            heardNothing = true
            generation += 1
            phase = .idle
            return
        }
        play()
    }

    // MARK: Playback

    private func play() {
        generation += 1
        let current = generation
        phase = .playing
        let started = player.play(take, sampleRate: Self.sampleRate) { [weak self] in
            guard let self, self.generation == current else { return }
            self.phase = .idle
        }
        if !started {
            phase = .idle
        }
    }

    private func stopPlayback() {
        player.stop()
        generation += 1
        phase = .idle
    }

    // MARK: Level

    /// How fast a meter falls when nothing new arrives. Shared with the
    /// always-on input meter (§5.15) so the two never disagree about how a
    /// pause looks — they are the same bar in two places.
    nonisolated static let meterDecay: Double = 0.7

    /// RMS mapped to a 0…1 meter with a square-root lift, because speech at a
    /// comfortable level has an RMS around 0.05–0.2 and a linear meter would
    /// sit apologetically near zero. Nonisolated: pure arithmetic, and the
    /// tests exercise it without an actor hop.
    nonisolated static func displayLevel(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        return min(1, sqrt(rms) * 1.6)
    }

    nonisolated static func displayLevel(of samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var energy: Float = 0
        for sample in samples {
            energy += sample * sample
        }
        return displayLevel(rms: Double(sqrtf(energy / Float(samples.count))))
    }
}
