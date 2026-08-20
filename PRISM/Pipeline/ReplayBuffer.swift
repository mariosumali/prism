// ReplayBuffer.swift
// PRISM
//
// The rolling "last N seconds" store behind instant replay (§5.9) and the
// away loop (§5.10). One recorder serves both.
//
// Why this is not just a bigger FrameRing. FrameRing holds 500 ms of raw
// IOSurface-backed frames — 15 slots at 1080p is about 124 MB, and it earns
// that by being the thing freeze picks its sharpest frame from, where any
// compression artefact would be the point. Ten seconds of raw 1080p30 is
// 2.5 GB, an order of magnitude past the entire app's memory budget (§7:
// < 250 MB resident). So the rolling buffer runs frames through the
// hardware H.264 encoder instead: ten seconds costs roughly 10 MB, the
// encode happens on the media engine rather than the GPU or CPU, and the
// only real cost on the frame path is one downscale pass.
//
// Alongside the compressed ring it keeps a 32×18 luma thumbnail per frame.
// That is what lets the away loop pick its cut points: prism_sharpness
// yields one scalar per frame, which can rank frames but cannot answer "do
// these two frames match closely enough to loop between them?". Thumbnails
// can, and 576 floats per frame is nothing next to the frame itself.
//
// Threading. `prepare` runs on the pipeline's frame queue and only encodes
// GPU work; `commit` runs from the command buffer's completed handler, which
// is where the pixel buffer is actually finished and safe to hand to the
// encoder. Everything after that is on `encodeQueue`. Readers take a
// snapshot under the lock.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

public final class ReplayBuffer {

    // MARK: - Types

    /// One buffered frame: the compressed sample plus what the away loop
    /// needs to reason about it.
    public struct RecordedFrame {
        public let sample: CMSampleBuffer
        /// Host-clock seconds; monotonic, the timeline both features run on.
        public let seconds: Double
        public let isKeyframe: Bool
        public let thumbnailSlot: Int
    }

    /// Handed from `prepare` to `commit` across the command buffer boundary.
    /// Carries the record dimensions rather than having `commit` read them
    /// back off the frame-queue-confined fields — `commit` runs on the
    /// command buffer's completion thread, and a format change in between
    /// would otherwise be a data race on exactly the values the encoder
    /// session is keyed on.
    public struct PendingRecord {
        let buffer: CVPixelBuffer
        let seconds: Double
        let thumbnailSlot: Int
        let width: Int
        let height: Int
    }

    public static let thumbnailWidth = 32
    public static let thumbnailHeight = 18
    private static let thumbnailCount = thumbnailWidth * thumbnailHeight

    /// Slots the record pool is created with — enough to cover the frames the
    /// encoder holds in flight without the pool blocking the frame path.
    /// Named because §5.23 has to charge for them: six raw BGRA slots at
    /// 1080p is 47.5 MB that used to appear in no plan at all.
    static let recordPoolDepth = 6

    // MARK: - Public state

    /// Set by the pipeline from live configuration each frame.
    public private(set) var isArmed = false

    /// Host-clock span currently buffered, oldest to newest.
    public var span: (start: Double, end: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = frames.first, let last = frames.last else { return nil }
        return (first.seconds, last.seconds)
    }

    public var bufferedSeconds: Double {
        guard let span else { return 0 }
        return max(0, span.end - span.start)
    }

    public var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    // MARK: - Private state

    private let metal: MetalContext
    private let copyPipeline: MTLComputePipelineState
    private let thumbnailPipeline: MTLComputePipelineState

    private let lock = NSLock()
    private let encodeQueue = DispatchQueue(label: "horse.prism.PRISM.replay.encode",
                                            qos: .utility)

    // lock-guarded
    private var frames: [RecordedFrame] = []
    private var bufferSeconds: Double = 10
    private var formatDescription: CMFormatDescription?

    // Frame-queue-confined
    private var pool: CVPixelBufferPool?
    private var recordWidth = 0
    private var recordHeight = 0
    private var thumbnailCursor = 0
    private var thumbnailCapacity = 0
    private var maxHeight = 1080
    private var frameRate = 30

    /// 32×18 luma per slot, storageModeShared: the GPU writes, the away-loop
    /// search reads.
    private var thumbnailBuffer: MTLBuffer?

    // encodeQueue-confined
    private var session: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0

    public init(metal: MetalContext) throws {
        self.metal = metal
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        thumbnailPipeline = try metal.computePipeline(function: "prism_thumbnail")
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: - Configuration

    /// Main-thread configuration. Disarming releases everything: an unused
    /// rolling buffer must cost neither memory nor an encoder session.
    public func configure(armed: Bool, bufferSeconds: Double,
                          maxHeight: Int, frameRate: Int) {
        let wasArmed = isArmed
        isArmed = armed
        self.maxHeight = max(180, maxHeight)
        self.frameRate = max(1, frameRate)

        lock.lock()
        let durationChanged = abs(self.bufferSeconds - bufferSeconds) > 0.01
        self.bufferSeconds = bufferSeconds
        lock.unlock()

        if !armed {
            reset()
        } else if wasArmed && durationChanged {
            trim()
        }
    }

    /// Drops every buffered frame and tears the encoder down.
    public func reset() {
        lock.lock()
        frames.removeAll()
        formatDescription = nil
        lock.unlock()

        encodeQueue.async { [weak self] in
            guard let self, let session = self.session else { return }
            VTCompressionSessionInvalidate(session)
            self.session = nil
            self.sessionWidth = 0
            self.sessionHeight = 0
        }
    }

    // MARK: - Recording (frame queue)

    /// Encodes the downscale and thumbnail passes for this frame into the
    /// frame's own command buffer. Returns the token to hand to `commit`
    /// from the completed handler, or nil when there is nothing to record.
    public func prepare(commandBuffer: MTLCommandBuffer,
                        source: MTLTexture,
                        hostSeconds: Double) -> PendingRecord? {
        guard isArmed else { return nil }
        let target = recordSize(width: source.width, height: source.height)
        guard ensureResources(width: target.width, height: target.height) else { return nil }
        guard let pool, let thumbnailBuffer else { return nil }

        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool,
                                                 &created) == kCVReturnSuccess,
              let buffer = created,
              let destination = try? metal.makeTexture(from: buffer) else { return nil }

        guard let copyEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        copyEncoder.label = "ReplayBuffer.downscale"
        copyEncoder.setComputePipelineState(copyPipeline)
        copyEncoder.setTexture(source, index: 0)
        copyEncoder.setTexture(destination, index: 1)
        dispatchOver(destination, pipeline: copyPipeline, encoder: copyEncoder)
        copyEncoder.endEncoding()

        let slot = thumbnailCursor
        thumbnailCursor = (thumbnailCursor + 1) % max(1, thumbnailCapacity)

        if let thumbEncoder = commandBuffer.makeComputeCommandEncoder() {
            var params = PRISMThumbnailParams()
            params.slot = UInt32(slot)
            params.width = UInt32(Self.thumbnailWidth)
            params.height = UInt32(Self.thumbnailHeight)
            thumbEncoder.label = "ReplayBuffer.thumbnail"
            thumbEncoder.setComputePipelineState(thumbnailPipeline)
            thumbEncoder.setTexture(source, index: 0)
            thumbEncoder.setBuffer(thumbnailBuffer, offset: 0, index: 0)
            thumbEncoder.setBytes(&params,
                                  length: MemoryLayout<PRISMThumbnailParams>.stride, index: 1)
            let group = MTLSize(width: 8, height: 8, depth: 1)
            let grid = MTLSize(width: (Self.thumbnailWidth + 7) / 8,
                               height: (Self.thumbnailHeight + 7) / 8, depth: 1)
            thumbEncoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
            thumbEncoder.endEncoding()
        }

        return PendingRecord(buffer: buffer, seconds: hostSeconds,
                             thumbnailSlot: slot,
                             width: target.width, height: target.height)
    }

    /// Called from the frame's completed handler: the GPU is done with the
    /// buffer and its thumbnail, so both are safe to publish.
    public func commit(_ record: PendingRecord) {
        guard isArmed else { return }
        encodeQueue.async { [weak self] in
            self?.encode(record, width: record.width, height: record.height)
        }
    }

    // MARK: - Reading

    public var sampleFormatDescription: CMFormatDescription? {
        lock.lock()
        defer { lock.unlock() }
        return formatDescription
    }

    /// Snapshot of the ring, oldest first.
    public func snapshot() -> [RecordedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    /// The thumbnails for `entries`, in the same order. Copied out so the
    /// away-loop search never reads the shared buffer while the GPU writes.
    public func thumbnails(for entries: [RecordedFrame]) -> [[Float]] {
        guard let thumbnailBuffer, thumbnailCapacity > 0 else { return [] }
        let base = thumbnailBuffer.contents().bindMemory(
            to: Float.self, capacity: thumbnailCapacity * Self.thumbnailCount)
        return entries.map { entry in
            guard entry.thumbnailSlot >= 0, entry.thumbnailSlot < thumbnailCapacity else {
                return [Float](repeating: 0, count: Self.thumbnailCount)
            }
            let offset = entry.thumbnailSlot * Self.thumbnailCount
            return Array(UnsafeBufferPointer(start: base + offset,
                                             count: Self.thumbnailCount))
        }
    }

    // MARK: - Away-loop selection

    /// The frame range the away loop should play, as indices into
    /// `snapshot()`. nil when there is not enough buffered to make a loop.
    public func selectAwayRange(loopSeconds: Double) -> (start: Int, end: Int)? {
        let entries = snapshot()
        guard entries.count > 8 else { return nil }
        return Self.selectLoop(thumbnails: thumbnails(for: entries),
                               times: entries.map(\.seconds),
                               loopSeconds: loopSeconds)
    }

    /// Picks the least visible loop in the buffer.
    ///
    /// Two things make an auto-generated idle loop convincing, and they pull
    /// in different directions. The cut has to be invisible, which wants the
    /// first and last frames to match. And the loop has to look alive rather
    /// than like a stuck stream, which wants *some* motion. So the score is
    /// the seam difference (weighted heavily — a visible jump cut is what
    /// gives these away) plus the segment's mean frame-to-frame motion, and
    /// the minimum wins.
    ///
    /// The most recent second is excluded outright: the away loop is
    /// triggered as someone gets up, so the newest frames are exactly the
    /// ones with a hand reaching off-screen in them.
    ///
    /// Pure, and separated from all the Metal/VideoToolbox machinery, so the
    /// scoring can be reasoned about and tested directly.
    static func selectLoop(thumbnails: [[Float]],
                           times: [Double],
                           loopSeconds: Double) -> (start: Int, end: Int)? {
        let count = min(thumbnails.count, times.count)
        guard count > 8, loopSeconds > 0 else { return nil }

        // Motion between consecutive frames, as a prefix sum so scoring any
        // candidate segment is O(1) rather than O(length).
        var motionPrefix = [Double](repeating: 0, count: count)
        for index in 1..<count {
            motionPrefix[index] = motionPrefix[index - 1]
                + meanAbsoluteDifference(thumbnails[index - 1], thumbnails[index])
        }

        let newest = times[count - 1]
        // Drop the trailing second (the "getting up" frames), but never so
        // much that nothing is left to search.
        var lastUsable = count - 1
        while lastUsable > 0, newest - times[lastUsable] < 1.0 {
            lastUsable -= 1
        }
        if lastUsable < 8 { lastUsable = count - 1 }

        let minimumFrames = 4
        var best: (start: Int, end: Int)?
        var bestScore = Double.greatestFiniteMagnitude

        for start in 0...max(0, lastUsable - minimumFrames) {
            // Longest segment within the requested loop length.
            var end = start
            while end + 1 <= lastUsable, times[end + 1] - times[start] <= loopSeconds {
                end += 1
            }
            guard end - start >= minimumFrames else { continue }

            let seam = meanAbsoluteDifference(thumbnails[start], thumbnails[end])
            let motion = (motionPrefix[end] - motionPrefix[start]) / Double(end - start)
            // A seam is the one artefact a viewer will actually notice.
            let score = seam * 3.0 + motion
            if score < bestScore {
                bestScore = score
                best = (start, end)
            }
        }
        return best
    }

    static func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return .greatestFiniteMagnitude }
        var total = 0.0
        for index in 0..<count {
            total += Double(abs(a[index] - b[index]))
        }
        return total / Double(count)
    }

    // MARK: - Resources (frame queue)

    /// Record dimensions: aspect preserved, height capped, both even (the
    /// encoder requires it).
    private func recordSize(width: Int, height: Int) -> (width: Int, height: Int) {
        Self.recordSize(width: width, height: height, maxHeight: maxHeight)
    }

    /// The same rule as a pure function, so §5.23 can price an armed buffer
    /// without building one. A memory plan that guesses at the record size
    /// is a plan that is wrong by whatever the cap actually does.
    static func recordSize(width: Int, height: Int,
                           maxHeight: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (640, 360) }
        let scale = min(1.0, Double(max(180, maxHeight)) / Double(height))
        let w = max(16, Int((Double(width) * scale).rounded()) & ~1)
        let h = max(16, Int((Double(height) * scale).rounded()) & ~1)
        return (w, h)
    }

    private func ensureResources(width: Int, height: Int) -> Bool {
        lock.lock()
        let seconds = bufferSeconds
        lock.unlock()
        let wantCapacity = max(16, Int((seconds * Double(frameRate)).rounded(.up)) + 8)

        if width != recordWidth || height != recordHeight || pool == nil {
            var created: CVPixelBufferPool?
            let bufferAttrs = prismPixelBufferAttributes(width: width, height: height)
            // Enough slots to cover the frames the encoder holds in flight
            // without the pool blocking on the frame path.
            let poolAttrs: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: Self.recordPoolDepth,
            ]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                          poolAttrs as CFDictionary,
                                          bufferAttrs as CFDictionary,
                                          &created) == kCVReturnSuccess,
                  let newPool = created else { return false }
            pool = newPool
            recordWidth = width
            recordHeight = height
            // Dimensions changed: previously buffered frames no longer share
            // a format description with what comes next, so they cannot be
            // decoded as one stream.
            lock.lock()
            frames.removeAll()
            formatDescription = nil
            lock.unlock()
        }

        if thumbnailBuffer == nil || thumbnailCapacity != wantCapacity {
            guard let buffer = metal.device.makeBuffer(
                length: wantCapacity * Self.thumbnailCount * MemoryLayout<Float>.stride,
                options: .storageModeShared) else { return false }
            thumbnailBuffer = buffer
            thumbnailCapacity = wantCapacity
            thumbnailCursor = 0
            lock.lock()
            frames.removeAll()          // old slots no longer address anything
            lock.unlock()
        }
        return true
    }

    // MARK: - Encoding (encodeQueue)

    private func encode(_ record: PendingRecord, width: Int, height: Int) {
        guard ensureSession(width: width, height: height), let session else { return }
        let presentation = CMTime(seconds: record.seconds, preferredTimescale: 90_000)
        // The thumbnail slot has to survive into the output callback, and the
        // callback's per-frame refcon is the only channel VideoToolbox gives
        // us for it. Boxed, passed retained, consumed on the far side.
        let context = Unmanaged.passRetained(
            FrameContext(seconds: record.seconds, thumbnailSlot: record.thumbnailSlot)
        ).toOpaque()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: record.buffer,
            presentationTimeStamp: presentation,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: context,
            infoFlagsOut: nil)
        if status != noErr {
            Unmanaged<FrameContext>.fromOpaque(context).release()
        }
    }

    private func ensureSession(width: Int, height: Int) -> Bool {
        if session != nil, sessionWidth == width, sessionHeight == height {
            return true
        }
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: replayCompressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created)
        guard status == noErr, let session = created else { return false }

        // Real-time, no frame reordering: output order matches input order,
        // which is what lets playback treat the ring as a plain list.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        // A keyframe every second bounds how far playback has to decode
        // before it can show the frame the user actually asked for.
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: frameRate))
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 1.0))
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: frameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: Self.bitRate(width: width, height: height)))
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.session = session
        sessionWidth = width
        sessionHeight = height
        return true
    }

    /// ~8 Mbps at 1080p, scaled by pixel count and clamped. Replay quality
    /// only has to survive being looked at once.
    static func bitRate(width: Int, height: Int) -> Int {
        let pixels = Double(width * height)
        let reference = 1920.0 * 1080.0
        let scaled = 8_000_000.0 * (pixels / reference)
        return Int(min(max(scaled, 2_000_000), 12_000_000))
    }

    /// Called from the compression callback.
    fileprivate func append(sample: CMSampleBuffer, context: FrameContext) {
        let isKeyframe = Self.isKeyframe(sample)
        if formatDescription == nil,
           let description = CMSampleBufferGetFormatDescription(sample) {
            lock.lock()
            formatDescription = description
            lock.unlock()
        }
        // The ring must start at a keyframe or nothing in it can be decoded.
        lock.lock()
        if frames.isEmpty && !isKeyframe {
            lock.unlock()
            return
        }
        frames.append(RecordedFrame(sample: sample,
                                    seconds: context.seconds,
                                    isKeyframe: isKeyframe,
                                    thumbnailSlot: context.thumbnailSlot))
        lock.unlock()
        trim()
    }

    /// Drops frames older than the configured window, but only back to a
    /// keyframe: cutting mid-GOP would leave a prefix that cannot decode.
    private func trim() {
        lock.lock()
        defer { lock.unlock() }
        guard let newest = frames.last?.seconds else { return }
        let cutoff = newest - bufferSeconds
        guard let lastStale = frames.lastIndex(where: { $0.seconds < cutoff }) else { return }
        // Newest keyframe at or before the stale boundary becomes the new head.
        guard let head = frames[0...lastStale].lastIndex(where: { $0.isKeyframe }),
              head > 0 else { return }
        frames.removeFirst(head)
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false) as? [[CFString: Any]],
            let first = attachments.first else { return true }
        // Absent or false "depends on others" means this frame stands alone.
        let dependsOnOthers = first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool
        return !(dependsOnOthers ?? false)
    }
}

/// Per-frame side channel through VideoToolbox's opaque refcon.
private final class FrameContext {
    let seconds: Double
    let thumbnailSlot: Int
    init(seconds: Double, thumbnailSlot: Int) {
        self.seconds = seconds
        self.thumbnailSlot = thumbnailSlot
    }
}

private let replayCompressionCallback: VTCompressionOutputCallback = {
    outputRefcon, sourceFrameRefcon, status, _, sampleBuffer in
    guard let sourceFrameRefcon else { return }
    let context = Unmanaged<FrameContext>.fromOpaque(sourceFrameRefcon).takeRetainedValue()
    guard status == noErr,
          let outputRefcon,
          let sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer) else { return }
    let buffer = Unmanaged<ReplayBuffer>.fromOpaque(outputRefcon).takeUnretainedValue()
    buffer.append(sample: sampleBuffer, context: context)
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
