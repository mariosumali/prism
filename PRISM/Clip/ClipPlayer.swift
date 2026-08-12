// ClipPlayer.swift
// PRISM
//
// AVAssetReader-based clip decode (SPEC §5.3). Keeps a 30-frame decode-ahead
// FIFO on a dedicated decode queue, retimes to the output cadence by frame
// repetition or drop against item timestamps, loops seamlessly by recreating
// the reader at EOF while ~1 s of frames is still buffered, and routes clip
// audio (48 kHz stereo float) into the shared ring via AudioSink, paced
// ~100 ms ahead of real time.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import AudioToolbox
import Combine
import CoreMedia
import CoreVideo
import Foundation
import Metal

public enum ClipFillMode: String, Codable, CaseIterable { case letterbox, fill }

public enum ClipPlayerError: Error {
    case noVideoTrack
    case invalidDuration
    case readerCreationFailed(String)
}

public final class ClipPlayer: ObservableObject {

    // MARK: - Public surface (CONTRACTS.md)

    @Published public private(set) var state: ClipState = .none
    @Published public private(set) var durationSeconds: Double = 0
    @Published public private(set) var positionSeconds: Double = 0

    /// Loop defaults to on (§5.3).
    public var loops: Bool = true
    /// Clip audio replaces the live mic by default; independently overridable
    /// so clip video + live audio stays selectable (§5.3).
    public var useClipAudio: Bool = true
    /// Aspect mismatch handling for OutputFit: letterbox default, never stretch.
    public var fillMode: ClipFillMode = .letterbox
    public var audioSink: AudioSink?
    /// Gate consulted before every clip-audio ring write. The ring is
    /// single-producer (§4.3): AppState wires this to the live capture's
    /// suppression acknowledgment so the pump never writes while the RT
    /// capture callback may still be producing. Called on the decode queue.
    public var audioWriteAllowed: (() -> Bool)?
    /// Loop-off end-of-clip: AppState begins the 200 ms crossfade to live.
    public var onEnded: (() -> Void)?

    public init(metal: MetalContext) {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metal.device, nil, &cache)
        // Creation only fails under memory exhaustion; a player that can
        // never produce a texture is useless, so treat it as fatal.
        precondition(cache != nil, "CVMetalTextureCacheCreate failed")
        textureCache = cache!
    }

    deinit {
        stopTimers()
        videoReader?.cancelReading()
        audioReader?.cancelReading()
        audioScratch?.deallocate()
    }

    /// Loads a clip and primes the 30-frame decode-ahead FIFO so the first
    /// frame is available immediately. Leaves the player paused at 0.
    public func load(url: URL) throws {
        teardown(publishState: false)

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        // `load()` is synchronous by contract; the deprecated synchronous
        // track/duration accessors are the intended tool here.
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw ClipPlayerError.noVideoTrack
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else {
            throw ClipPlayerError.invalidDuration
        }

        // Build the initial readers up front so load() can throw on bad
        // media; they are handed to the decode queue and only used there.
        let (videoReader, videoOutput) = try Self.makeVideoReader(
            asset: asset, track: videoTrack, startingAt: 0)
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack,
           let (reader, output) = try? Self.makeAudioReader(
               asset: asset, track: audioTrack, startingAt: 0) {
            audioReader = reader
            audioOutput = output
        }

        lock.lock()
        generation &+= 1
        let gen = generation
        loaded = true
        playing = false
        holding = false
        endedFired = false
        videoEOF = false
        fillScheduled = false
        fifo.removeAll()
        lastDelivered = nil
        elapsedAtPause = 0
        playHostStart = nil
        assetDuration = duration
        audioTimelinePos = 0
        lastTimelineSeconds = 0
        lock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.asset = asset
            self.videoTrack = videoTrack
            self.audioTrack = audioTrack
            self.videoReader = videoReader
            self.videoOutput = videoOutput
            self.audioReader = audioReader
            self.audioOutput = audioOutput
            self.videoLoopBase = 0
            self.fillFIFO(generation: gen)
        }
        startTimers()

        publishOnMain { [weak self] in
            guard let self else { return }
            self.durationSeconds = duration
            self.positionSeconds = 0
            self.state = .paused
        }
    }

    public func play() {
        lock.lock()
        guard loaded, !playing else {
            lock.unlock()
            return
        }
        let atEnd = !loops && videoEOF && fifo.isEmpty
            && lastTimelineSeconds > 0 && elapsedAtPause >= lastTimelineSeconds
        lock.unlock()

        if atEnd { seek(toSeconds: 0) }

        lock.lock()
        guard loaded, !playing else {
            lock.unlock()
            return
        }
        playing = true
        endedFired = false
        if !holding && !demandHeld {
            playHostStart = CMClockGetTime(CMClockGetHostTimeClock())
        }
        lock.unlock()
        publishOnMain { [weak self] in self?.state = .playing }
    }

    public func pause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock()
        guard loaded, playing else {
            lock.unlock()
            return
        }
        if let start = playHostStart {
            elapsedAtPause += max(0, CMTimeSubtract(now, start).seconds)
            playHostStart = nil
        }
        playing = false
        lock.unlock()
        publishOnMain { [weak self] in self?.state = .paused }
    }

    /// Unloads the clip entirely.
    public func stop() {
        teardown(publishState: true)
    }

    /// Scrub: recreate both readers at the target time. The FIFO is cleared
    /// immediately; the previously delivered frame remains on screen until
    /// the first frame at the new position decodes (milliseconds).
    public func seek(toSeconds seconds: Double) {
        lock.lock()
        guard loaded else {
            lock.unlock()
            return
        }
        let target = min(max(0, seconds), assetDuration)
        generation &+= 1
        let gen = generation
        fifo.removeAll()
        lastDelivered = nil
        videoEOF = false
        endedFired = false
        fillScheduled = false
        elapsedAtPause = target
        if playing && !holding && !demandHeld {
            playHostStart = CMClockGetTime(CMClockGetHostTimeClock())
        }
        audioTimelinePos = target
        lastTimelineSeconds = target
        lock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.videoLoopBase = 0
            self.rebuildVideoReader(at: target)
            self.rebuildAudioReader(at: target)
            self.fillFIFO(generation: gen)
        }
        publishOnMain { [weak self] in self?.positionSeconds = target }
    }

    /// Whether a clip frame is available for substitution. Unlike
    /// currentTexture this touches no capture-queue-confined texture state,
    /// so it is safe from any thread (used by VideoPipeline.setFrozen).
    public var hasFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded && (lastDelivered != nil || !fifo.isEmpty)
    }

    /// Freeze-while-clip pauses the clip on its current frame (§5.3): the
    /// clock stops advancing (video and audio) but the published state is
    /// untouched — freeze is AppState's concern, not a transport change.
    public func holdCurrentFrame(_ hold: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock()
        guard loaded, hold != holding else {
            lock.unlock()
            return
        }
        holding = hold
        if playing {
            if hold {
                if let start = playHostStart {
                    elapsedAtPause += max(0, CMTimeSubtract(now, start).seconds)
                    playHostStart = nil
                }
            } else if !demandHeld {
                // Unfreeze while demand is still zero must not restart the
                // clock; setDemandActive(true) owns that resume.
                playHostStart = now
            }
        }
        lock.unlock()
    }

    /// Demand gate (AppState §demand-driven capture): while the pipeline has
    /// no consumers the clip clock stops, exactly like holdCurrentFrame but
    /// on an independent flag so it can never fight freeze's hold ownership.
    /// Without this an idle PRISM keeps decoding, and on the next demand the
    /// video fast-forwards through the whole idle gap.
    public func setDemandActive(_ active: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock()
        let suspend = !active
        guard suspend != demandHeld else {
            lock.unlock()
            return
        }
        demandHeld = suspend
        if loaded, playing, !holding {   // holding already stopped the clock
            if suspend {
                if let start = playHostStart {
                    elapsedAtPause += max(0, CMTimeSubtract(now, start).seconds)
                    playHostStart = nil
                }
            } else {
                playHostStart = now
            }
        }
        lock.unlock()
    }

    /// Latest decoded frame retimed to the output cadence: returns the frame
    /// whose timeline presentation time best matches the elapsed clip clock,
    /// repeating the last frame when the next is still in the future and
    /// dropping intermediates when the clock has run ahead (§5.3). Called on
    /// the capture queue by ClipStage — single consumer.
    public func currentTexture(at hostTime: CMTime) -> MTLTexture? {
        lock.lock()
        guard loaded else {
            lock.unlock()
            return nil
        }
        if playing && !holding && !demandHeld {
            let target = elapsedLocked(atHost: hostTime)
            while let first = fifo.first, first.timelineSeconds <= target {
                lastDelivered = first
                fifo.removeFirst()
            }
        }
        // First delivery after load/seek (also the paused case).
        if lastDelivered == nil, !fifo.isEmpty {
            lastDelivered = fifo.removeFirst()
        }
        let entry = lastDelivered
        let gen = generation
        var scheduleRefill = false
        if fifo.count < Self.decodeAhead, !fillScheduled {
            fillScheduled = true
            scheduleRefill = true
        }
        lock.unlock()

        if scheduleRefill {
            decodeQueue.async { [weak self] in self?.fillFIFO(generation: gen) }
        }
        guard let entry else { return nil }
        return texture(for: entry.buffer)
    }

    // MARK: - Private state

    private struct FrameEntry {
        let buffer: CVPixelBuffer
        /// Presentation time within the asset (drives the position readout).
        let assetSeconds: Double
        /// Monotonic presentation time across loop iterations:
        /// loopIndex × duration + assetSeconds. The clip clock runs on this.
        let timelineSeconds: Double
    }

    private static let decodeAhead = 30
    private static let audioLeadSeconds = 0.1
    /// Largest audio gap decoded in one pump tick. A stale audio position
    /// (clip audio toggled on mid-playback, or a long stall) is clamped by
    /// jumping the reader forward instead of synchronously decoding the whole
    /// gap — which would block the shared decode queue (freezing clip video)
    /// and mass-overrun the ~683 ms ring.
    private static let maxAudioCatchUpSeconds = 0.5
    private static let sampleRate = 48000.0
    private static let channels = 2
    private static let decodeTickInterval = 0.025
    private static let positionPublishInterval = 0.25   // 4 Hz

    private let decodeQueue = DispatchQueue(
        label: "horse.prism.PRISM.clip.decode", qos: .userInitiated)
    private let lock = NSLock()
    /// Dedicated cache (separate from MetalContext's) so clip textures never
    /// contend with the live-capture wrap path.
    private let textureCache: CVMetalTextureCache

    // Guarded by `lock`:
    private var loaded = false
    private var playing = false
    private var holding = false
    /// AppState's demand gate; independent of `holding` (freeze ownership).
    /// Survives load() — it mirrors the last reconcile, not clip transport.
    private var demandHeld = false
    private var endedFired = false
    private var videoEOF = false
    private var fillScheduled = false
    private var fifo: [FrameEntry] = []
    private var lastDelivered: FrameEntry?
    private var elapsedAtPause: Double = 0
    private var playHostStart: CMTime?
    private var generation: UInt64 = 0
    private var assetDuration: Double = 0
    /// Timeline position (seconds) of the next audio frame to be written.
    private var audioTimelinePos: Double = 0
    /// Highest timeline presentation time decoded so far (end detection).
    private var lastTimelineSeconds: Double = 0
    private var pumpTimer: DispatchSourceTimer?
    private var positionTimer: DispatchSourceTimer?

    // Confined to decodeQueue (created in load(), used/rebuilt on the queue):
    private var asset: AVAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var videoReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioReader: AVAssetReader?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var videoLoopBase: Double = 0
    private var audioScratch: UnsafeMutableRawPointer?
    private var audioScratchBytes = 0

    // Confined to the capture queue (single caller of currentTexture):
    private var cachedTextureBuffer: CVPixelBuffer?
    private var cachedCVTexture: CVMetalTexture?
    private var cachedTexture: MTLTexture?

    // MARK: Clock

    /// Elapsed clip-timeline seconds. Caller holds `lock`.
    private func elapsedLocked(atHost host: CMTime) -> Double {
        if let start = playHostStart {
            return elapsedAtPause + max(0, CMTimeSubtract(host, start).seconds)
        }
        return elapsedAtPause
    }

    // MARK: Teardown

    private func teardown(publishState: Bool) {
        lock.lock()
        generation &+= 1
        loaded = false
        playing = false
        holding = false
        endedFired = false
        videoEOF = false
        fillScheduled = false
        fifo.removeAll()
        lastDelivered = nil
        elapsedAtPause = 0
        playHostStart = nil
        assetDuration = 0
        audioTimelinePos = 0
        lastTimelineSeconds = 0
        lock.unlock()

        stopTimers()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.videoReader?.cancelReading()
            self.audioReader?.cancelReading()
            self.videoReader = nil
            self.videoOutput = nil
            self.audioReader = nil
            self.audioOutput = nil
            self.asset = nil
            self.videoTrack = nil
            self.audioTrack = nil
            self.videoLoopBase = 0
        }

        if publishState {
            publishOnMain { [weak self] in
                guard let self else { return }
                self.state = .none
                self.durationSeconds = 0
                self.positionSeconds = 0
            }
        }
    }

    // MARK: Timers

    private func startTimers() {
        stopTimers()

        let pump = DispatchSource.makeTimerSource(queue: decodeQueue)
        pump.schedule(deadline: .now() + Self.decodeTickInterval,
                      repeating: Self.decodeTickInterval)
        pump.setEventHandler { [weak self] in self?.decodeTick() }
        pump.resume()

        let position = DispatchSource.makeTimerSource(queue: decodeQueue)
        position.schedule(deadline: .now() + Self.positionPublishInterval,
                          repeating: Self.positionPublishInterval)
        position.setEventHandler { [weak self] in self?.publishPosition() }
        position.resume()

        lock.lock()
        pumpTimer = pump
        positionTimer = position
        lock.unlock()
    }

    private func stopTimers() {
        lock.lock()
        let pump = pumpTimer
        let position = positionTimer
        pumpTimer = nil
        positionTimer = nil
        lock.unlock()
        pump?.cancel()
        position?.cancel()
    }

    /// 40 Hz housekeeping on the decode queue: keep the FIFO topped up (the
    /// loop-restart path needs ticks even when the consumer stalls), pace
    /// clip audio, and detect loop-off end of clip.
    private func decodeTick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock()
        let gen = generation
        let isLoaded = loaded
        lock.unlock()
        guard isLoaded else { return }
        fillFIFO(generation: gen)
        pumpAudio(now: now)
        checkEnded(now: now)
    }

    // MARK: Video decode (decodeQueue)

    private func fillFIFO(generation gen: UInt64) {
        lock.lock()
        fillScheduled = false
        lock.unlock()

        while true {
            lock.lock()
            guard gen == generation, loaded, !videoEOF else {
                lock.unlock()
                return
            }
            let need = Self.decodeAhead - fifo.count
            lock.unlock()
            guard need > 0 else { return }
            guard let output = videoOutput, let reader = videoReader else { return }

            if let sample = output.copyNextSampleBuffer() {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let assetSeconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let entry = FrameEntry(
                    buffer: pixelBuffer,
                    assetSeconds: assetSeconds,
                    timelineSeconds: videoLoopBase + assetSeconds)
                lock.lock()
                if gen == generation, loaded {
                    fifo.append(entry)
                    lastTimelineSeconds = max(lastTimelineSeconds, entry.timelineSeconds)
                }
                lock.unlock()
            } else {
                if reader.status == .failed {
                    lock.lock()
                    videoEOF = true
                    lock.unlock()
                    return
                }
                // .completed → end of the current pass.
                lock.lock()
                let shouldLoop = loops && gen == generation && loaded
                if !shouldLoop { videoEOF = true }
                let duration = assetDuration
                lock.unlock()
                guard shouldLoop else { return }

                // Preroll the next pass now, while up to ~1 s of frames is
                // still buffered, so the loop seam never starves the output.
                videoLoopBase += duration
                guard rebuildVideoReader(at: 0) else {
                    lock.lock()
                    videoEOF = true
                    lock.unlock()
                    return
                }
            }
        }
    }

    @discardableResult
    private func rebuildVideoReader(at seconds: Double) -> Bool {
        videoReader?.cancelReading()
        videoReader = nil
        videoOutput = nil
        guard let asset, let videoTrack,
              let (reader, output) = try? Self.makeVideoReader(
                  asset: asset, track: videoTrack, startingAt: seconds) else {
            return false
        }
        videoReader = reader
        videoOutput = output
        return true
    }

    @discardableResult
    private func rebuildAudioReader(at seconds: Double) -> Bool {
        audioReader?.cancelReading()
        audioReader = nil
        audioOutput = nil
        guard let asset, let audioTrack,
              let (reader, output) = try? Self.makeAudioReader(
                  asset: asset, track: audioTrack, startingAt: seconds) else {
            return false
        }
        audioReader = reader
        audioOutput = output
        return true
    }

    // MARK: Audio pump (decodeQueue)

    /// Decodes and writes clip audio into the ring, staying ~100 ms ahead of
    /// the clip clock. Stops naturally while paused, held, or muted off via
    /// `useClipAudio`.
    private func pumpAudio(now: CMTime) {
        guard useClipAudio, let sink = audioSink, audioOutput != nil else { return }
        // Ring ownership handshake (§4.3 SPSC): do not write until live
        // capture has acknowledged suppression.
        if let allowed = audioWriteAllowed, !allowed() { return }

        lock.lock()
        guard loaded, playing, !holding, !demandHeld, playHostStart != nil else {
            lock.unlock()
            return
        }
        let target = elapsedLocked(atHost: now) + Self.audioLeadSeconds
        var position = audioTimelinePos
        let gen = generation
        let duration = assetDuration
        lock.unlock()

        // Clamp catch-up: resume from the current clip position rather than
        // decoding an unbounded backlog in one tick.
        if target - position > Self.maxAudioCatchUpSeconds {
            let resumeAt = max(0, target - Self.audioLeadSeconds)
            let assetPos = duration > 0
                ? resumeAt.truncatingRemainder(dividingBy: duration)
                : 0
            guard rebuildAudioReader(at: assetPos) else { return }
            lock.lock()
            if gen == generation, loaded {
                audioTimelinePos = resumeAt
            }
            lock.unlock()
            position = resumeAt
        }

        while position < target {
            lock.lock()
            let stillValid = gen == generation && loaded && playing
                && !holding && !demandHeld
            lock.unlock()
            guard stillValid, useClipAudio,
                  let output = audioOutput, let reader = audioReader else { return }

            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .completed, loops {
                    guard rebuildAudioReader(at: 0) else { return }
                    continue
                }
                return
            }
            let frames = writeAudio(sample, to: sink)
            guard frames > 0 else { return }
            position += Double(frames) / Self.sampleRate
            lock.lock()
            audioTimelinePos = position
            lock.unlock()
        }
    }

    /// Copies one PCM sample buffer (interleaved stereo float, 48 kHz) into
    /// the scratch block and writes it to the ring. Returns frames written.
    private func writeAudio(_ sample: CMSampleBuffer, to sink: AudioSink) -> Int {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return 0 }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return 0 }

        if audioScratchBytes < length {
            audioScratch?.deallocate()
            audioScratch = UnsafeMutableRawPointer.allocate(
                byteCount: length, alignment: MemoryLayout<Float>.alignment)
            audioScratchBytes = length
        }
        guard let scratch = audioScratch else { return 0 }
        guard CMBlockBufferCopyDataBytes(
            block, atOffset: 0, dataLength: length, destination: scratch) == kCMBlockBufferNoErr
        else { return 0 }

        let bytesPerFrame = Self.channels * MemoryLayout<Float>.size
        let frames = min(CMSampleBufferGetNumSamples(sample), length / bytesPerFrame)
        guard frames > 0 else { return 0 }
        sink.write(scratch.assumingMemoryBound(to: Float.self), frameCount: frames)
        return frames
    }

    // MARK: End-of-clip detection (decodeQueue)

    private func checkEnded(now: CMTime) {
        var fire = false
        lock.lock()
        if loaded, playing, !loops, videoEOF, !endedFired,
           fifo.isEmpty, elapsedLocked(atHost: now) >= lastTimelineSeconds {
            endedFired = true
            playing = false
            elapsedAtPause = lastTimelineSeconds
            playHostStart = nil
            fire = true
        }
        lock.unlock()
        guard fire else { return }

        publishOnMain { [weak self] in
            guard let self else { return }
            self.state = .paused
            self.positionSeconds = self.durationSeconds
            self.onEnded?()
        }
    }

    // MARK: Position publishing (decodeQueue → main, 4 Hz)

    private func publishPosition() {
        lock.lock()
        guard loaded else {
            lock.unlock()
            return
        }
        let position: Double
        if let entry = lastDelivered {
            position = min(max(0, entry.assetSeconds), assetDuration)
        } else {
            position = min(max(0, elapsedAtPause), assetDuration)
        }
        lock.unlock()
        publishOnMain { [weak self] in self?.positionSeconds = position }
    }

    // MARK: Texture wrapping (capture queue)

    private func texture(for buffer: CVPixelBuffer) -> MTLTexture? {
        if cachedTextureBuffer === buffer, let texture = cachedTexture {
            return texture
        }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        // Keep the CVMetalTexture (and thereby the IOSurface) alive while the
        // texture is the current frame.
        cachedTextureBuffer = buffer
        cachedCVTexture = cvTexture
        cachedTexture = texture
        return texture
    }

    // MARK: Reader factories

    private static func makeVideoReader(
        asset: AVAsset, track: AVAssetTrack, startingAt seconds: Double
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ClipPlayerError.readerCreationFailed(error.localizedDescription)
        }
        // 32BGRA, IOSurface-backed, Metal-compatible: stays on the GPU path
        // end to end (§5.3, §3.3).
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: prismPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ClipPlayerError.readerCreationFailed("cannot attach video output")
        }
        reader.add(output)
        if seconds > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: seconds, preferredTimescale: 600),
                duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            throw ClipPlayerError.readerCreationFailed(
                reader.error?.localizedDescription ?? "startReading failed")
        }
        return (reader, output)
    }

    private static func makeAudioReader(
        asset: AVAsset, track: AVAssetTrack, startingAt seconds: Double
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ClipPlayerError.readerCreationFailed(error.localizedDescription)
        }
        // PCM float 48 kHz stereo interleaved — the ring's native format.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ClipPlayerError.readerCreationFailed("cannot attach audio output")
        }
        reader.add(output)
        if seconds > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: seconds, preferredTimescale: 600),
                duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            throw ClipPlayerError.readerCreationFailed(
                reader.error?.localizedDescription ?? "startReading failed")
        }
        return (reader, output)
    }

    // MARK: Main-thread publishing

    private func publishOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
