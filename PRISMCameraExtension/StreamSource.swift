// StreamSource.swift
// PRISMCameraExtension — the two streams of "PRISM Camera" (SPEC §3.1–§3.2).
// PRISMStreamSource is the source stream client apps read from; it emits the
// placeholder card at 1 fps when the sink has been silent for more than
// 1000 ms, and enforces the §5.15 per-app access policy in
// authorizedToStartStream. PRISMSinkStreamSource is the sink stream
// PRISM.app writes into; it runs the consume loop, forwards every buffer to
// the source stream, and records the sink-receive → source-emit handoff time.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreMediaIO
import Foundation
import os.log

// MARK: - Source stream

final class PRISMStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private weak var deviceSource: PRISMDeviceSource?

    private let lock = NSLock()
    private var extFormats: [ExtFormat]
    private var streamFormats: [CMIOExtensionStreamFormat]
    private var activeIndex = 0
    private var streaming = false
    private var lastSinkFrameNs: UInt64 = 0

    private let renderer: PlaceholderRenderer
    private var placeholderTimer: DispatchSourceTimer?
    private let placeholderQueue = DispatchQueue(label: "horse.prism.PRISM.camera.placeholder",
                                                 qos: .userInteractive)

    init(deviceSource: PRISMDeviceSource, extFormats: [ExtFormat]) {
        self.deviceSource = deviceSource
        self.extFormats = extFormats
        self.streamFormats = makeStreamFormats(extFormats)
        let first = extFormats[0]
        self.renderer = PlaceholderRenderer(width: first.width, height: first.height)
        super.init()
        self.stream = CMIOExtensionStream(localizedName: PRISMIdentity.sourceStreamName,
                                          streamID: PRISMIdentity.sourceStreamID,
                                          direction: .source,
                                          clockType: .hostTime,
                                          source: self)
    }

    // MARK: Republish support (format-set change, SPEC §3.2)

    func prepareForRepublish() {
        lock.lock()
        streaming = false
        lock.unlock()
        stopPlaceholderTimer()
    }

    /// Swap the published format set and mint a fresh stream object (same
    /// stream ID) for re-addition to the device.
    func updateFormats(_ formats: [ExtFormat]) {
        lock.lock()
        extFormats = formats
        streamFormats = makeStreamFormats(formats)
        activeIndex = 0
        lock.unlock()
        renderer.setSize(width: formats[0].width, height: formats[0].height)
        stream = CMIOExtensionStream(localizedName: PRISMIdentity.sourceStreamName,
                                     streamID: PRISMIdentity.sourceStreamID,
                                     direction: .source,
                                     clockType: .hostTime,
                                     source: self)
    }

    // MARK: Relay entry point (called by the sink stream source)

    func forwardFromSink(_ sampleBuffer: CMSampleBuffer) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        lastSinkFrameNs = nowNs
        let isStreaming = streaming
        lock.unlock()
        guard isStreaming else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostNs: UInt64
        if pts.isValid, pts.seconds > 0 {
            hostNs = UInt64(pts.seconds * 1_000_000_000.0)
        } else {
            hostNs = nowNs
        }
        stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostNs)
    }

    // MARK: CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] {
        lock.lock()
        defer { lock.unlock() }
        return streamFormats
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        lock.lock()
        let index = activeIndex
        let duration = extFormats.indices.contains(index)
            ? extFormats[index].frameDuration
            : CMTime(value: 1, timescale: 30)
        lock.unlock()

        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = index
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = duration
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            setActiveFormatIndex(index)
        }
        // Frame-duration writes are accepted but derived state: every
        // published format carries exactly one rate, so rate selection is
        // format selection (SPEC §3.2).
    }

    private func setActiveFormatIndex(_ index: Int) {
        lock.lock()
        guard extFormats.indices.contains(index) else {
            lock.unlock()
            prismLog.error("source: rejected out-of-range activeFormatIndex \(index)")
            return
        }
        activeIndex = index
        let format = extFormats[index]
        lock.unlock()
        // Keep the placeholder card at the negotiated output size.
        renderer.setSize(width: format.width, height: format.height)
        // Surface the negotiation to the app via 'afmt' so the pipeline can
        // retarget its output to the client-negotiated format (§3.2, M4.5).
        deviceSource?.noteActiveFormat(format)
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // §5.15 policy hook. Refusing here is the only per-client decision
        // the extension gets: `stream.send` fans one picture out to every
        // consumer, so there is no way to show *this* client a card while
        // another sees video — a per-client placeholder would need a stream
        // per client, which CMIOExtension does not offer. Returning false
        // makes the client's AVCaptureSession fail to start, which is the
        // same shape as a TCC denial and is therefore a failure every video
        // app already knows how to draw.
        //
        // Fail open lives one level down, in PRISMAccessPolicy: no policy,
        // an unreadable one, or one this build cannot evaluate all say yes.
        // Written as "refuse only on an explicit no" rather than "allow only
        // on an explicit yes" so a missing deviceSource admits the client
        // instead of locking the camera on a released weak reference.
        if let policy = deviceSource?.accessPolicy,
           !policy.isAllowed(client.signingID) {
            deviceSource?.noteClientRefused(client)
            return false
        }
        // Every client that begins streaming passes through here; record it
        // for the 'clnt' property (removed on disconnect / full stop).
        deviceSource?.noteStreamingClient(client)
        return true
    }

    func startStream() throws {
        lock.lock()
        streaming = true
        lock.unlock()
        startPlaceholderTimer()
    }

    func stopStream() throws {
        lock.lock()
        streaming = false
        lock.unlock()
        stopPlaceholderTimer()
        deviceSource?.noteSourceStreamStopped()
    }

    // MARK: Placeholder (SPEC §3.2 — never a black frame)

    private func startPlaceholderTimer() {
        lock.lock()
        defer { lock.unlock() }
        placeholderTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: [], queue: placeholderQueue)
        // First tick almost immediately so a stream started while the app
        // is down shows the card at once (M0), then 1 fps thereafter.
        timer.schedule(deadline: .now() + .milliseconds(100),
                       repeating: .seconds(1),
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.placeholderTick()
        }
        timer.resume()
        placeholderTimer = timer
    }

    private func stopPlaceholderTimer() {
        lock.lock()
        defer { lock.unlock() }
        placeholderTimer?.cancel()
        placeholderTimer = nil
    }

    private func placeholderTick() {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let isStreaming = streaming
        let last = lastSinkFrameNs
        lock.unlock()
        guard isStreaming else { return }
        // Silent sink: no frame ever, or the last one is over 1000 ms old.
        guard last == 0 || nowNs &- last > 1_000_000_000 else { return }

        guard let frame = renderer.makeFrame() else {
            prismLog.error("placeholder render failed")
            return
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: frame.pixelBuffer,
                                                              formatDescription: frame.formatDescription,
                                                              sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            prismLog.error("placeholder sample buffer creation failed: \(status)")
            return
        }
        stream.send(sample, discontinuity: [], hostTimeInNanoseconds: nowNs)
    }
}

// MARK: - Sink stream

final class PRISMSinkStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private weak var deviceSource: PRISMDeviceSource?
    private weak var forwardTarget: PRISMStreamSource?

    private let lock = NSLock()
    private var extFormats: [ExtFormat]
    private var streamFormats: [CMIOExtensionStreamFormat]
    private var activeIndex = 0
    private var consuming = false
    private var client: CMIOExtensionClient?
    private let consumeQueue = DispatchQueue(label: "horse.prism.PRISM.camera.sink",
                                             qos: .userInteractive)

    init(deviceSource: PRISMDeviceSource, extFormats: [ExtFormat], forwardTo target: PRISMStreamSource) {
        self.deviceSource = deviceSource
        self.forwardTarget = target
        self.extFormats = extFormats
        self.streamFormats = makeStreamFormats(extFormats)
        super.init()
        self.stream = CMIOExtensionStream(localizedName: PRISMIdentity.sinkStreamName,
                                          streamID: PRISMIdentity.sinkStreamID,
                                          direction: .sink,
                                          clockType: .hostTime,
                                          source: self)
    }

    // MARK: Republish support

    func prepareForRepublish() {
        lock.lock()
        consuming = false
        client = nil
        lock.unlock()
    }

    func updateFormats(_ formats: [ExtFormat]) {
        lock.lock()
        extFormats = formats
        streamFormats = makeStreamFormats(formats)
        activeIndex = 0
        lock.unlock()
        stream = CMIOExtensionStream(localizedName: PRISMIdentity.sinkStreamName,
                                     streamID: PRISMIdentity.sinkStreamID,
                                     direction: .sink,
                                     clockType: .hostTime,
                                     source: self)
    }

    // MARK: CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] {
        lock.lock()
        defer { lock.unlock() }
        return streamFormats
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex,
         .streamFrameDuration,
         .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount,
         .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        lock.lock()
        let index = activeIndex
        let duration = extFormats.indices.contains(index)
            ? extFormats[index].frameDuration
            : CMTime(value: 1, timescale: 30)
        lock.unlock()

        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = index
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = duration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.setPropertyState(
                CMIOExtensionPropertyState(value: NSNumber(value: 8) as AnyObject),
                forProperty: .streamSinkBufferQueueSize)
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.setPropertyState(
                CMIOExtensionPropertyState(value: NSNumber(value: 1) as AnyObject),
                forProperty: .streamSinkBuffersRequiredForStartup)
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            streamProperties.setPropertyState(
                CMIOExtensionPropertyState(value: NSNumber(value: 0) as AnyObject),
                forProperty: .streamSinkBufferUnderrunCount)
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.setPropertyState(
                CMIOExtensionPropertyState(value: NSNumber(value: 0) as AnyObject),
                forProperty: .streamSinkEndOfData)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            lock.lock()
            if extFormats.indices.contains(index) {
                activeIndex = index
            } else {
                prismLog.error("sink: rejected out-of-range activeFormatIndex \(index)")
            }
            lock.unlock()
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // The sink's only expected client is PRISM.app; the CMIOExtension
        // mach service name's app-group prefix already gates access, so an
        // unexpected signing ID is logged rather than rejected.
        if let signingID = client.signingID, signingID != "horse.prism.PRISM" {
            prismLog.notice("sink client with unexpected signing ID: \(signingID, privacy: .public)")
        }
        lock.lock()
        self.client = client
        lock.unlock()
        return true
    }

    func startStream() throws {
        lock.lock()
        guard client != nil else {
            lock.unlock()
            throw NSError(domain: "horse.prism.PRISM.camera",
                          code: Int(EINVAL),
                          userInfo: [NSLocalizedDescriptionKey: "sink started with no client"])
        }
        consuming = true
        lock.unlock()
        consumeQueue.async { [weak self] in
            self?.consumeNext()
        }
    }

    func stopStream() throws {
        lock.lock()
        consuming = false
        lock.unlock()
    }

    // MARK: Consume loop (sink → source relay, ≤ 3 ms handoff budget)

    private func consumeNext() {
        lock.lock()
        guard consuming, let client else {
            lock.unlock()
            return
        }
        lock.unlock()
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            self?.handleConsumed(sampleBuffer, sequenceNumber: sequenceNumber, error: error)
        }
    }

    private func handleConsumed(_ sampleBuffer: CMSampleBuffer?, sequenceNumber: UInt64, error: Error?) {
        let receiveNs = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let active = consuming
        lock.unlock()
        guard active else { return }

        if let sampleBuffer {
            forwardTarget?.forwardFromSink(sampleBuffer)
            let emitNs = DispatchTime.now().uptimeNanoseconds
            deviceSource?.recordHandoffMs(Double(emitNs &- receiveNs) / 1_000_000.0)
            // Tell the producing app the buffer left the queue so its push
            // pacing stays honest.
            stream.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                             hostTimeInNanoseconds: emitNs))
            // Trampoline through the queue: keeps the loop iterative even if
            // the framework delivers queued buffers synchronously.
            consumeQueue.async { [weak self] in
                self?.consumeNext()
            }
        } else {
            if let error {
                prismLog.error("sink consume error: \(String(describing: error), privacy: .public)")
            }
            // No buffer: back off briefly so a persistent error cannot spin.
            consumeQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.consumeNext()
            }
        }
    }
}

// MARK: - Shared format construction

/// Build the CMIOExtensionStreamFormat array for a published set. Both
/// streams advertise identical sets at all times (SPEC §3.2).
func makeStreamFormats(_ formats: [ExtFormat]) -> [CMIOExtensionStreamFormat] {
    formats.compactMap { format in
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    codecType: kCVPixelFormatType_32BGRA,
                                                    width: Int32(format.width),
                                                    height: Int32(format.height),
                                                    extensions: nil,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else {
            prismLog.error("format description failed for \(format.width)x\(format.height)")
            return nil
        }
        let duration = format.frameDuration
        return CMIOExtensionStreamFormat(formatDescription: description,
                                         maxFrameDuration: duration,
                                         minFrameDuration: duration,
                                         validFrameDurations: nil)
    }
}
