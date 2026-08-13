// ReplayPlayer.swift
// PRISM
//
// Playback for the rolling buffer: instant replay (§5.9) and the away loop
// (§5.10). Both are the same machinery pointed at different ranges of the
// same recording, which is why they are one class.
//
//   Replay — starts at the oldest buffered frame and runs forward at
//       `rate`. Above 1× it catches back up to live, which is the entire
//       point: you are showing someone the thing they missed, not screening
//       a rerun, and you want to rejoin the conversation.
//   Away —  loops a chosen range indefinitely. ReplayBuffer picks the range
//       by seam cost; this class hides what is left of the seam by
//       crossfading the loop's tail into its own held first frame, then
//       restarting on that exact frame.
//
// Why a held frame rather than a second decode stream. Crossfading two
// arbitrary points of a compressed stream means decoding two positions at
// once — two decompression sessions, two frame FIFOs. The loop only ever
// fades toward one specific frame, its own start, so holding that single
// frame costs one texture (~8 MB) instead of a second decoder, and the fade
// is identical.
//
// Decode backpressure. VideoToolbox may decode asynchronously, so "keep
// feeding until the FIFO is full" would race its own callbacks and feed the
// entire loop before the first frame came back — 120 decoded 1080p frames is
// a gigabyte. Frames fed and not yet returned are therefore counted, and the
// feed stops on fifo + inFlight, never on fifo alone.
//
// Threading follows ClipPlayer: transport from the main thread,
// `currentFrame(at:)` from the frame queue only, decode on a private serial
// queue, callbacks on VideoToolbox's threads.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

public enum ReplayMode: Equatable {
    case idle
    case replay
    case away
    /// Deliberate delay line (§5.12): trails live by a fixed offset,
    /// indefinitely, re-reading the buffer as it grows.
    case lag
}

public final class ReplayPlayer {

    // MARK: - Public surface

    /// What the stage draws this frame: one texture, or two mid-crossfade.
    public struct Frame {
        public let texture: MTLTexture
        public let blendTexture: MTLTexture?
        public let mix: Float          // 0 = texture, 1 = blendTexture
    }

    public var mode: ReplayMode {
        lock.lock()
        defer { lock.unlock() }
        return modeStorage
    }

    public var isActive: Bool { mode != .idle }

    /// Fires when a replay reaches the live edge. Main thread.
    public var onReplayFinished: (() -> Void)?

    /// Position within the replay and its total length, for the scrub row.
    public var positionSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return min(elapsedLocked(atHost: CMClockGetTime(CMClockGetHostTimeClock())),
                   loopLength)
    }

    public var durationSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return loopLength
    }

    public init(metal: MetalContext, buffer: ReplayBuffer) {
        self.metal = metal
        self.buffer = buffer
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metal.device, nil, &cache)
        precondition(cache != nil, "CVMetalTextureCacheCreate failed")
        textureCache = cache!
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    // MARK: - Transport

    /// Rewinds to the oldest buffered frame and plays forward at `rate`.
    /// Returns false when there is nothing buffered to replay.
    @discardableResult
    public func startReplay(rate: Double) -> Bool {
        let entries = buffer.snapshot()
        guard entries.count > 2,
              let description = buffer.sampleFormatDescription else { return false }
        guard entries[entries.count - 1].seconds - entries[0].seconds > 0.2 else { return false }

        begin(entries: entries, description: description,
              range: (0, entries.count - 1), mode: .replay,
              rate: min(max(rate, 0.25), 4), crossfadeSeconds: 0)
        return true
    }

    /// Generates and starts the away loop. Returns false when the buffer has
    /// no usable segment yet.
    @discardableResult
    public func startAway(loopSeconds: Double, crossfadeMs: Double) -> Bool {
        let entries = buffer.snapshot()
        guard let description = buffer.sampleFormatDescription,
              let range = buffer.selectAwayRange(loopSeconds: loopSeconds),
              range.end < entries.count else { return false }
        let length = entries[range.end].seconds - entries[range.start].seconds
        guard length > 0.5 else { return false }

        begin(entries: entries, description: description,
              range: (range.start, range.end), mode: .away, rate: 1,
              crossfadeSeconds: min(max(crossfadeMs, 0) / 1000, length * 0.5))
        return true
    }

    /// Engages the deliberate delay line (§5.12): output holds the current
    /// live frame for `delaySeconds`, then resumes at 1× permanently that far
    /// behind live.
    ///
    /// Holding first is what makes this a delay rather than a rewind. Jumping
    /// straight back would replay the last few seconds — viewers would watch
    /// you say the same thing twice. Stalling and then resuming behind is
    /// what a real transport hiccup does, and it is what "add latency"
    /// actually means.
    ///
    /// Returns false when nothing is buffered to trail.
    @discardableResult
    public func startLag(delaySeconds: Double) -> Bool {
        let entries = buffer.snapshot()
        guard let description = buffer.sampleFormatDescription,
              let newest = entries.last else { return false }

        begin(entries: entries, description: description,
              range: (entries.count - 1, entries.count - 1), mode: .lag,
              rate: 1, crossfadeSeconds: 0,
              base: newest.seconds, lag: max(0, delaySeconds))
        return true
    }

    /// Consumes the accumulated backlog at `rate` until the output reaches
    /// live, then fires `onReplayFinished`. `stop()` remains the snap-back
    /// path — cut straight to live and never send the backlog at all.
    public func beginCatchUp(rate: Double) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock()
        guard modeStorage == .lag else {
            lock.unlock()
            return
        }
        // Re-anchor so the output position is continuous across the rate
        // change: whatever elapsed time the delay had produced becomes the
        // new starting offset, and the lag is now zero because it is already
        // baked into it.
        elapsedAtPause = elapsedLocked(atHost: now)
        lagSeconds = 0
        playStart = now
        playbackRate = min(max(rate, 1.01), 4)
        finishedFired = false
        lock.unlock()
    }

    /// Delay currently being applied to the output, in seconds. Reported to
    /// the latency monitor so the deliberate cost is visible (§6).
    ///
    /// Measured against the buffer's live edge rather than against elapsed
    /// wall time. A catch-up re-anchors the clock, so "time since engage"
    /// stops meaning anything the moment the release begins — and that is
    /// exactly the window where the number matters most, because it is the
    /// one shrinking back to zero.
    ///
    /// Lock order is player → buffer throughout this class; never the
    /// reverse.
    public var appliedDelaySeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard modeStorage == .lag, let newest = buffer.span?.end else { return 0 }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return max(0, newest - (baseSeconds + elapsedLocked(atHost: now)))
    }

    public func stop() {
        lock.lock()
        generation &+= 1
        modeStorage = .idle
        entries = []
        fifo.removeAll()
        lastDelivered = nil
        heldFrame = nil
        holdPending = false
        inFlight = 0
        rangeStart = 0
        rangeEnd = 0
        baseSeconds = 0
        loopLength = 0
        crossfade = 0
        lagSeconds = 0
        playbackRate = 1
        playStart = nil
        elapsedAtPause = 0
        finishedFired = false
        lock.unlock()

        decodeQueue.async { [weak self] in self?.teardownSession() }
    }

    /// Scrub within a replay, in seconds from its start. Meaningless while
    /// lagging — the offset from live is the control there, not a position.
    public func seek(toSeconds seconds: Double) {
        lock.lock()
        guard modeStorage == .replay || modeStorage == .away, !entries.isEmpty else {
            lock.unlock()
            return
        }
        let target = min(max(0, seconds), max(loopLength, 0.001))
        generation &+= 1
        let gen = generation
        fifo.removeAll()
        lastDelivered = nil
        inFlight = 0
        elapsedAtPause = target
        finishedFired = false
        if playStart != nil {
            playStart = CMClockGetTime(CMClockGetHostTimeClock())
        }
        let snapshot = entries
        let start = rangeStart
        let base = baseSeconds
        lock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.feedIndex = Self.decodeStart(in: snapshot, at: start,
                                              targetSeconds: base + target)
            self.lastFedSeconds = -.greatestFiniteMagnitude
            self.pump(generation: gen)
        }
    }

    // MARK: - Frame delivery (frame queue)

    public func currentFrame(at hostTime: CMTime) -> Frame? {
        lock.lock()
        guard modeStorage != .idle, !entries.isEmpty else {
            lock.unlock()
            return nil
        }
        var elapsed = elapsedLocked(atHost: hostTime)
        var wrapped = false
        var reachedEnd = false

        if modeStorage == .away, loopLength > 0, elapsed >= loopLength {
            // Wrap: rebase the clock instead of accumulating drift, and drop
            // the tail frames so the loop restarts on its own first frame —
            // which is exactly the frame the crossfade just landed on.
            elapsedAtPause = 0
            playStart = hostTime
            elapsed = 0
            fifo.removeAll()
            lastDelivered = nil
            inFlight = 0
            wrapped = true
        } else if modeStorage == .replay, loopLength > 0, elapsed >= loopLength {
            elapsed = loopLength
            reachedEnd = !finishedFired
            finishedFired = true
        } else if modeStorage == .lag, playbackRate > 1, !finishedFired {
            // Catching up: done once the output reaches the live edge. The
            // buffer's own span is the authority on where that is, and this
            // only runs while a catch-up is in flight.
            if let newest = buffer.span?.end, baseSeconds + elapsed >= newest {
                reachedEnd = true
                finishedFired = true
            }
        }

        let target = baseSeconds + elapsed
        while let first = fifo.first, first.seconds <= target {
            lastDelivered = first
            fifo.removeFirst()
        }
        if lastDelivered == nil, !fifo.isEmpty {
            lastDelivered = fifo.removeFirst()
        }

        let entry = lastDelivered
        let held = heldFrame
        let gen = generation
        let needsPump = !pumpScheduled && (fifo.count + inFlight) < Self.decodeAhead
        if needsPump { pumpScheduled = true }

        // Crossfade the loop's tail into its own first frame.
        var mix: Float = 0
        if modeStorage == .away, crossfade > 0, loopLength > crossfade {
            let fadeStart = loopLength - crossfade
            if elapsed > fadeStart {
                mix = Float(min(1, (elapsed - fadeStart) / crossfade))
            }
        }
        lock.unlock()

        if wrapped {
            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.feedIndex = self.loopFeedStart
                self.pump(generation: gen)
            }
        } else if needsPump {
            decodeQueue.async { [weak self] in self?.pump(generation: gen) }
        }
        if reachedEnd {
            DispatchQueue.main.async { [weak self] in self?.onReplayFinished?() }
        }

        // Immediately after a wrap the FIFO is empty for a few milliseconds.
        // The held first frame covers that gap — and it is the correct
        // picture, not a stall, because the loop begins on it.
        guard let entry, let texture = texture(for: entry.buffer) else {
            return held.map { Frame(texture: $0, blendTexture: nil, mix: 0) }
        }
        if mix > 0, let held {
            return Frame(texture: texture, blendTexture: held, mix: mix)
        }
        return Frame(texture: texture, blendTexture: nil, mix: 0)
    }

    // MARK: - Private state

    private struct DecodedFrame {
        let buffer: CVPixelBuffer
        let seconds: Double
    }

    private static let decodeAhead = 6

    private let metal: MetalContext
    private let buffer: ReplayBuffer
    private let textureCache: CVMetalTextureCache
    private let decodeQueue = DispatchQueue(label: "horse.prism.PRISM.replay.decode",
                                            qos: .userInitiated)
    private let lock = NSLock()

    // lock-guarded
    private var modeStorage: ReplayMode = .idle
    private var entries: [ReplayBuffer.RecordedFrame] = []
    private var fifo: [DecodedFrame] = []
    private var lastDelivered: DecodedFrame?
    private var heldFrame: MTLTexture?
    private var holdPending = false
    private var inFlight = 0
    private var rangeStart = 0
    private var rangeEnd = 0
    /// Absolute host-clock time of the played range's first frame. Stored
    /// rather than derived from `entries[rangeStart]` because the rolling
    /// buffer trims from the front, so indices are not stable across the
    /// re-snapshots lag mode performs.
    private var baseSeconds: Double = 0
    private var loopLength: Double = 0
    private var crossfade: Double = 0
    /// Lag mode's trailing offset. Folded into the clock rather than the
    /// range, so the output holds the engage frame for `lagSeconds` and only
    /// then starts moving — a delay line, not a rewind.
    private var lagSeconds: Double = 0
    private var playStart: CMTime?
    private var elapsedAtPause: Double = 0
    private var generation: UInt64 = 0
    private var pumpScheduled = false
    private var finishedFired = false
    private var playbackRate: Double = 1

    // decodeQueue-confined
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private var feedIndex = 0
    /// Where a loop wrap resumes feeding: the newest keyframe at or before
    /// the range start, so the decoder always restarts from a decodable point.
    private var loopFeedStart = 0
    /// Presentation time of the last frame fed to the decoder. Lag mode
    /// resolves its feed position by time rather than index for the same
    /// trimming reason as `baseSeconds`.
    private var lastFedSeconds: Double = -.greatestFiniteMagnitude

    // Frame-queue-confined texture wrapper cache.
    private var cachedBuffer: CVPixelBuffer?
    private var cachedCVTexture: CVMetalTexture?
    private var cachedTexture: MTLTexture?

    // MARK: - Setup

    private func begin(entries snapshot: [ReplayBuffer.RecordedFrame],
                       description: CMFormatDescription,
                       range: (start: Int, end: Int),
                       mode newMode: ReplayMode,
                       rate: Double,
                       crossfadeSeconds: Double,
                       base: Double? = nil,
                       lag: Double = 0) {
        let start = base ?? snapshot[range.start].seconds
        // Lag never ends: it trails live for as long as it is engaged.
        let length = newMode == .lag
            ? Double.greatestFiniteMagnitude
            : snapshot[range.end].seconds - start

        lock.lock()
        generation &+= 1
        let gen = generation
        entries = snapshot
        rangeStart = range.start
        rangeEnd = range.end
        baseSeconds = start
        loopLength = length
        crossfade = crossfadeSeconds
        lagSeconds = lag
        playbackRate = rate
        modeStorage = newMode
        fifo.removeAll()
        lastDelivered = nil
        heldFrame = nil
        holdPending = newMode == .away
        inFlight = 0
        elapsedAtPause = 0
        finishedFired = false
        pumpScheduled = false
        playStart = CMClockGetTime(CMClockGetHostTimeClock())
        lock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(for: description)
            let feed = Self.decodeStart(in: snapshot, at: range.start,
                                        targetSeconds: start)
            self.loopFeedStart = feed
            self.feedIndex = feed
            self.lastFedSeconds = -.greatestFiniteMagnitude
            self.pump(generation: gen)
        }
    }

    /// Caller holds `lock`. Elapsed seconds from `baseSeconds`, scaled by
    /// playback rate and offset by the lag. Clamped at zero, which is what
    /// makes lag hold the engage frame until the delay has been absorbed.
    private func elapsedLocked(atHost host: CMTime) -> Double {
        guard let start = playStart else { return max(0, elapsedAtPause - lagSeconds) }
        let advanced = elapsedAtPause
            + max(0, CMTimeSubtract(host, start).seconds) * playbackRate
        return max(0, advanced - lagSeconds)
    }

    /// Index to start feeding the decoder from: the newest keyframe at or
    /// before the target. Everything between it and the target decodes and is
    /// discarded — at most one GOP, which is one second by construction.
    static func decodeStart(in entries: [ReplayBuffer.RecordedFrame],
                            at rangeStart: Int,
                            targetSeconds: Double) -> Int {
        guard !entries.isEmpty else { return 0 }
        let clamped = min(max(rangeStart, 0), entries.count - 1)
        for candidate in stride(from: clamped, through: 0, by: -1)
        where entries[candidate].isKeyframe && entries[candidate].seconds <= targetSeconds {
            return candidate
        }
        // The ring always begins on a keyframe (ReplayBuffer.append drops
        // anything before the first), so index 0 is always decodable.
        return 0
    }

    // MARK: - Decode (decodeQueue)

    private func configureSession(for description: CMFormatDescription) {
        if let session, let sessionFormat,
           CMFormatDescriptionEqual(sessionFormat, otherFormatDescription: description),
           VTDecompressionSessionCanAcceptFormatDescription(
               session, formatDescription: description) {
            return
        }
        teardownSession()

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: prismPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: replayDecompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created)
        guard status == noErr, let created else { return }
        session = created
        sessionFormat = description
    }

    private func teardownSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        sessionFormat = nil
    }

    /// Decodes forward until the FIFO (plus what is still in the decoder) is
    /// topped up, or the range runs out.
    private func pump(generation gen: UInt64) {
        lock.lock()
        pumpScheduled = false
        guard gen == generation, modeStorage != .idle, !entries.isEmpty else {
            lock.unlock()
            return
        }
        var snapshot = entries
        var end = rangeEnd
        let looping = modeStorage == .away
        let isLag = modeStorage == .lag
        let base = baseSeconds
        lock.unlock()

        guard let session else { return }

        if isLag {
            // Trailing live: re-read the ring, which has both grown at the
            // back and possibly trimmed at the front since the last pump, so
            // the feed position has to be resolved by time rather than by a
            // carried index.
            snapshot = buffer.snapshot()
            guard !snapshot.isEmpty else { return }
            end = snapshot.count - 1
            feedIndex = Self.resumeIndex(in: snapshot,
                                         afterSeconds: lastFedSeconds,
                                         base: base)
            lock.lock()
            if gen == generation {
                entries = snapshot
                rangeEnd = end
            }
            lock.unlock()
        }

        while true {
            lock.lock()
            guard gen == generation, modeStorage != .idle else {
                lock.unlock()
                return
            }
            let queued = fifo.count + inFlight
            lock.unlock()
            guard queued < Self.decodeAhead else { return }

            guard feedIndex <= end, feedIndex < snapshot.count else {
                // Lag has simply outrun the recorder for the moment; the next
                // frame arrives on its own and the next pump picks it up.
                guard looping else { return }
                feedIndex = loopFeedStart
                continue
            }

            let entry = snapshot[feedIndex]
            feedIndex += 1
            lastFedSeconds = entry.seconds
            // Frames before the range start are reference frames only:
            // decode them so the range's first frame is correct, but do not
            // queue them and do not count them against the backlog.
            let keep = entry.seconds >= base
            if keep {
                lock.lock()
                inFlight += 1
                lock.unlock()
            }
            decode(entry, session: session, generation: gen, keep: keep)
        }
    }

    /// Where lag mode resumes feeding in a freshly re-read ring: the first
    /// frame after the last one fed, or — on the very first pump — the newest
    /// keyframe at or before the engage point.
    static func resumeIndex(in entries: [ReplayBuffer.RecordedFrame],
                            afterSeconds: Double,
                            base: Double) -> Int {
        guard !entries.isEmpty else { return 0 }
        if afterSeconds == -.greatestFiniteMagnitude {
            let anchor = entries.lastIndex { $0.seconds <= base } ?? (entries.count - 1)
            return decodeStart(in: entries, at: anchor, targetSeconds: base)
        }
        return entries.firstIndex { $0.seconds > afterSeconds } ?? entries.count
    }

    private func decode(_ entry: ReplayBuffer.RecordedFrame,
                        session: VTDecompressionSession,
                        generation gen: UInt64,
                        keep: Bool) {
        let context = Unmanaged.passRetained(
            DecodeContext(seconds: entry.seconds, generation: gen, keep: keep)
        ).toOpaque()
        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: entry.sample,
            flags: [],
            frameRefcon: context,
            infoFlagsOut: &flagsOut)
        if status != noErr {
            Unmanaged<DecodeContext>.fromOpaque(context).release()
            if keep {
                lock.lock()
                inFlight = max(0, inFlight - 1)
                lock.unlock()
            }
        }
    }

    fileprivate func deliver(buffer decoded: CVPixelBuffer?, context: DecodeContext) {
        guard context.keep else { return }
        lock.lock()
        inFlight = max(0, inFlight - 1)
        guard let decoded, context.generation == generation, modeStorage != .idle else {
            lock.unlock()
            return
        }
        fifo.append(DecodedFrame(buffer: decoded, seconds: context.seconds))
        // Frame reordering is disabled at encode time, so callbacks arrive in
        // order — but a sort on a six-element FIFO costs nothing and removes
        // the assumption entirely.
        fifo.sort { $0.seconds < $1.seconds }
        let shouldHold = holdPending
        if shouldHold { holdPending = false }
        lock.unlock()

        if shouldHold {
            captureHeldFrame(decoded)
        }
    }

    /// Copies the loop's first frame into a private texture for the wrap
    /// crossfade to land on. Pool buffers get recycled; a retained reference
    /// would eventually be rewritten underneath the fade.
    private func captureHeldFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let source = try? metal.makeTexture(from: pixelBuffer),
              let copy = try? metal.makeIntermediate(width: source.width,
                                                     height: source.height),
              let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        commandBuffer.label = "ReplayPlayer.holdLoopStart"
        blit.copy(from: source, to: copy)
        blit.endEncoding()
        commandBuffer.commit()

        lock.lock()
        heldFrame = copy
        lock.unlock()
    }

    // MARK: - Texture wrapping (frame queue)

    private func texture(for pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        if cachedBuffer === pixelBuffer, let cachedTexture { return cachedTexture }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        cachedBuffer = pixelBuffer
        cachedCVTexture = cvTexture
        cachedTexture = texture
        return texture
    }
}

/// Per-frame side channel through VideoToolbox's opaque refcon.
private final class DecodeContext {
    let seconds: Double
    let generation: UInt64
    let keep: Bool
    init(seconds: Double, generation: UInt64, keep: Bool) {
        self.seconds = seconds
        self.generation = generation
        self.keep = keep
    }
}

private let replayDecompressionCallback: VTDecompressionOutputCallback = {
    outputRefcon, frameRefcon, status, _, imageBuffer, _, _ in
    guard let frameRefcon else { return }
    let context = Unmanaged<DecodeContext>.fromOpaque(frameRefcon).takeRetainedValue()
    guard let outputRefcon else { return }
    let player = Unmanaged<ReplayPlayer>.fromOpaque(outputRefcon).takeUnretainedValue()
    // Deliver even on failure so the in-flight count is always balanced —
    // a dropped decode that leaked a slot would stall the pump permanently.
    player.deliver(buffer: status == noErr ? imageBuffer : nil, context: context)
}
