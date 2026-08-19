// CMIOSink.swift
// PRISM
//
// CoreMediaIO C-API client. Finds the PRISM Camera extension device, copies
// the sink stream's buffer queue, and pushes processed frames into it
// (SPEC §3.2). Also speaks the custom-property control channel ('pfmt',
// 'clnt', 'hoff', 'afmt', 'polc', 'blkd') defined in CONTRACTS.md, and polls
// it at 1 Hz while connected.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

public final class CMIOSink {

    /// Custom-property failures against a live extension are contract bugs
    /// and must be visible: `log stream --predicate 'subsystem == "horse.prism.PRISM"'`.
    private static let log = Logger(subsystem: "horse.prism.PRISM", category: "CMIOSink")

    // MARK: - Public surface (CONTRACTS.md)

    /// True once the sink stream's buffer queue has been copied and the
    /// stream started. Cleared on `disconnect()` or when the device vanishes.
    public private(set) var isConnected: Bool = false

    /// Streaming clients decoded from 'clnt', each carrying both the signing
    /// ID the extension reported (what §5.18 rules match on) and the name a
    /// human is shown (what §8.4 copy shows). Fired on the main thread
    /// whenever the set changes.
    public var onClientsChanged: (([CameraClient]) -> Void)?

    /// Clients the extension refused under the §5.18 policy in the last
    /// 30 s, decoded from 'blkd'. Fired on the main thread on change.
    public var onBlockedClientsChanged: (([CameraClient]) -> Void)?

    /// Frames dropped because the sink queue was full (§3.2: drop + count).
    public private(set) var droppedFrames: Int = 0

    /// True while the published §5.18 policy could refuse someone. Gates the
    /// 1 Hz 'blkd' read: an extension holding no policy always answers "[]",
    /// and paying a round trip per second for that answer is waste on the
    /// overwhelmingly common path where the feature is off.
    public var isPolicyEnforcing: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return policyEnforcing
        }
        set {
            stateLock.lock()
            policyEnforcing = newValue
            stateLock.unlock()
        }
    }

    public init() {}

    deinit {
        retryTimer?.cancel()
        pollTimer?.cancel()
        if isConnected, deviceID != 0, sinkStreamID != 0 {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
    }

    /// Finds the PRISM Camera device + sink stream via the CMIO C API,
    /// copies the buffer queue, starts the stream. Retries internally at a
    /// 1 s cadence until the device appears (the extension may not be
    /// approved yet).
    public func connect() {
        controlQueue.async { [weak self] in
            guard let self, !self.connectRequested else { return }
            self.connectRequested = true
            self.startRetryTimer()
        }
    }

    public func disconnect() {
        controlQueue.async { [weak self] in
            self?.teardown()
        }
    }

    /// Tears down the current connection and immediately re-resolves the
    /// device and sink stream. Required after a 'pfmt' republish: the
    /// extension destroys and recreates both streams (§3.2), so a previously
    /// copied buffer queue is orphaned — frames pushed into it would never
    /// reach the extension's consume loop.
    public func reconnect() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            self.connectRequested = true
            self.startRetryTimer()
        }
    }

    /// Real-time path: wraps the pixel buffer in a CMSampleBuffer and
    /// enqueues it into the sink stream's queue. Drops (and counts) when the
    /// queue is full. Safe to call from any queue.
    public func send(_ buffer: CVPixelBuffer, at time: CMTime) {
        stateLock.lock()
        guard isConnected, let queue = sinkQueue else {
            stateLock.unlock()
            return
        }
        // Format description cached per dimensions (recreated only when the
        // output size changes, e.g. a format renegotiation).
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if formatDescription == nil || formatWidth != width || formatHeight != height {
            var desc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &desc)
            formatDescription = desc
            formatWidth = width
            formatHeight = height
        }
        guard let desc = formatDescription else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            stateLock.lock()
            droppedFrames += 1
            stateLock.unlock()
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard status == 0, let sample = sampleBuffer else { return }

        // The queue takes ownership of a +1 reference; the extension's
        // consumeSampleBuffer balances it.
        let enqueueStatus = CMSimpleQueueEnqueue(
            queue, element: Unmanaged.passRetained(sample).toOpaque())
        if enqueueStatus != 0 {
            Unmanaged.passUnretained(sample).release()
            stateLock.lock()
            droppedFrames += 1
            stateLock.unlock()
        }
    }

    // MARK: Custom-property helpers ('pfmt' / 'clnt' / 'hoff')
    //
    // Marshalling contract, established empirically against the live
    // extension (macOS 26): the DAL adapter bridges CMIOExtension custom
    // properties as RAW BYTES — the contents of the NSData the extension
    // serves — never as a CFData object reference. GetPropertyDataSize
    // reports the byte length (2 for "[]", 8 for a Float64); a get must
    // supply a buffer of exactly that size, and a set passes the payload
    // bytes directly with dataSize = count. Passing a CFDataRef instead
    // fails reads with '!siz' and hands the extension 8 bytes of pointer
    // garbage on writes (its JSON decode then throws EINVAL, which is the
    // OSStatus 22 the app sees).

    /// Reads a custom property's raw bytes; nil when absent, empty, or
    /// oversized (the control channel carries short JSON/scalars only).
    private func readRawProperty(_ selector: UInt32, on device: CMIOObjectID,
                                 label: StaticString) -> Data? {
        var address = Self.globalAddress(selector)
        var dataSize: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize)
        guard sizeStatus == 0 else {
            Self.log.error("'\(label, privacy: .public)' size query failed: OSStatus \(sizeStatus) (device \(device))")
            return nil
        }
        guard dataSize > 0, dataSize <= 1_048_576 else { return nil }
        var buffer = Data(count: Int(dataSize))
        var dataUsed: UInt32 = 0
        let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
            CMIOObjectGetPropertyData(device, &address, 0, nil,
                                      dataSize, &dataUsed, raw.baseAddress!)
        }
        guard status == 0 else {
            Self.log.error("'\(label, privacy: .public)' read failed: OSStatus \(status) (device \(device), size \(dataSize))")
            return nil
        }
        guard dataUsed > 0 else { return nil }
        return buffer.prefix(Int(dataUsed))
    }

    /// app → extension: publish the format set as UTF-8 JSON.
    public func writeFormatList(_ json: Data) -> Bool {
        let device = currentDeviceID()
        guard device != 0, !json.isEmpty else { return false }
        var address = Self.globalAddress(Self.selectorPFMT)
        let status = json.withUnsafeBytes { raw -> OSStatus in
            CMIOObjectSetPropertyData(
                device, &address, 0, nil,
                UInt32(json.count), raw.baseAddress!)
        }
        if status != 0 {
            Self.log.error("'pfmt' write failed: OSStatus \(status) (device \(device))")
        }
        return status == 0
    }

    /// extension → app: rolling mean sink-receive → source-emit, in ms
    /// (8 raw bytes of Float64).
    public func readHandoffMs() -> Double? {
        let device = currentDeviceID()
        guard device != 0 else { return nil }
        guard let data = readRawProperty(Self.selectorHOFF, on: device, label: "hoff"),
              data.count == MemoryLayout<Float64>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Float64.self) }
    }

    /// extension → app: the format a client most recently negotiated on the
    /// source stream ('afmt', UTF-8 JSON of one format entry). nil until a
    /// client has negotiated (the extension serves empty data before then).
    public func readActiveFormat() -> VideoFormat? {
        let device = currentDeviceID()
        guard device != 0 else { return nil }
        guard let data = readRawProperty(Self.selectorAFMT, on: device, label: "afmt") else { return nil }
        return try? JSONDecoder().decode(VideoFormat.self, from: data)
    }

    /// extension → app: streaming client signing IDs as UTF-8 JSON array.
    public func readClients() -> [String]? {
        let device = currentDeviceID()
        guard device != 0 else { return nil }
        guard let data = readRawProperty(Self.selectorCLNT, on: device, label: "clnt") else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// app → extension: publish the §5.18 access policy as UTF-8 JSON.
    ///
    /// Returns false when the device is absent or the write is refused — the
    /// caller must treat that as "the extension is still enforcing whatever
    /// it had", because it is.
    public func writeAccessPolicy(_ json: Data) -> Bool {
        let device = currentDeviceID()
        guard device != 0, !json.isEmpty else { return false }
        var address = Self.globalAddress(Self.selectorPOLC)
        let status = json.withUnsafeBytes { raw -> OSStatus in
            CMIOObjectSetPropertyData(
                device, &address, 0, nil,
                UInt32(json.count), raw.baseAddress!)
        }
        if status != 0 {
            Self.log.error("'polc' write failed: OSStatus \(status) (device \(device))")
        }
        return status == 0
    }

    /// extension → app: signing IDs refused by policy recently. Empty rather
    /// than nil when the extension answers with an empty list.
    public func readBlockedClients() -> [String]? {
        let device = currentDeviceID()
        guard device != 0 else { return nil }
        guard let data = readRawProperty(Self.selectorBLKD, on: device, label: "blkd") else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Maps signing IDs to friendly names ("us.zoom.xos" → "Zoom").
    public static func displayName(forSigningID signingID: String) -> String {
        switch signingID {
        case "us.zoom.xos": return "Zoom"
        case "com.apple.FaceTime": return "FaceTime"
        case "com.apple.PhotoBooth": return "Photo Booth"
        case "com.apple.QuickTimePlayerX": return "QuickTime Player"
        case "com.google.Chrome": return "Chrome"
        case "com.apple.Safari": return "Safari"
        case "com.microsoft.teams2": return "Teams"
        case "com.hnc.Discord": return "Discord"
        case "com.tinyspeck.slackmacgap": return "Slack"
        default:
            let last = signingID.split(separator: ".").last.map(String.init) ?? signingID
            guard let first = last.first else { return signingID }
            return String(first).uppercased() + last.dropFirst()
        }
    }

    // MARK: - Private state

    private static let prismDeviceUID = "horse.prism.PRISM.camera.device"
    private static let retryInterval: TimeInterval = 1.0
    private static let pollInterval: TimeInterval = 1.0
    /// Consecutive whole-poll failures before assuming the device is gone.
    private static let pollFailureLimit = 3

    private static func fourCC(_ code: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in code.utf8 { value = (value << 8) | UInt32(byte) }
        return value
    }

    private static let selectorPFMT = fourCC("pfmt")
    private static let selectorCLNT = fourCC("clnt")
    private static let selectorHOFF = fourCC("hoff")
    private static let selectorAFMT = fourCC("afmt")
    private static let selectorPOLC = fourCC("polc")
    private static let selectorBLKD = fourCC("blkd")

    /// Serialises connect/retry/poll bookkeeping. Timer state, retry flags,
    /// and the last-seen client list are confined to this queue.
    private let controlQueue = DispatchQueue(
        label: "horse.prism.PRISM.cmiosink", qos: .utility)

    /// Guards state shared between the control queue and the real-time
    /// `send(_:at:)` path.
    private let stateLock = NSLock()

    // Guarded by stateLock:
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?
    private var formatWidth = 0
    private var formatHeight = 0
    private var lastHandoffMs: Double?
    private var policyEnforcing = false

    // Confined to controlQueue:
    private var connectRequested = false
    private var retryTimer: DispatchSourceTimer?
    private var pollTimer: DispatchSourceTimer?
    private var lastClientIDs: [String]?
    private var lastBlockedIDs: [String]?
    private var pollFailureCount = 0

    private func currentDeviceID() -> CMIOObjectID {
        stateLock.lock()
        defer { stateLock.unlock() }
        return deviceID
    }

    // MARK: Connection lifecycle (controlQueue)

    private func startRetryTimer() {
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now(), repeating: Self.retryInterval)
        timer.setEventHandler { [weak self] in self?.attemptConnect() }
        timer.resume()
        retryTimer = timer
    }

    private func stopRetryTimer() {
        retryTimer?.cancel()
        retryTimer = nil
    }

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.pollProperties() }
        timer.resume()
        pollTimer = timer
    }

    private func stopPollTimer() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func attemptConnect() {
        stateLock.lock()
        let alreadyConnected = isConnected
        stateLock.unlock()
        guard !alreadyConnected else {
            stopRetryTimer()
            return
        }

        guard let device = Self.findPRISMDevice() else { return }
        guard let (streamID, queue) = Self.resolveSinkStream(device: device) else { return }
        guard CMIODeviceStartStream(device, streamID) == 0 else { return }

        stateLock.lock()
        deviceID = device
        sinkStreamID = streamID
        sinkQueue = queue
        formatDescription = nil
        formatWidth = 0
        formatHeight = 0
        isConnected = true
        stateLock.unlock()

        pollFailureCount = 0
        lastClientIDs = nil
        lastBlockedIDs = nil
        stopRetryTimer()
        startPollTimer()
    }

    private func teardown() {
        // Whatever killed the connection (extension death, reconnect for a
        // format republish, plain disconnect) also disconnected every client.
        // Publish the empty list so AppState's clientsInUse converges to
        // reality — a stale non-empty list would hold captureDemand true and
        // keep the camera running for nobody.
        let hadClients = !(lastClientIDs ?? []).isEmpty
        // Same argument for refusals: without a device to ask, "Zoom is being
        // blocked right now" is a claim PRISM can no longer stand behind.
        let hadBlocked = !(lastBlockedIDs ?? []).isEmpty

        connectRequested = false
        stopRetryTimer()
        stopPollTimer()
        lastClientIDs = nil
        lastBlockedIDs = nil
        pollFailureCount = 0

        if hadClients {
            let callback = onClientsChanged
            DispatchQueue.main.async { callback?([]) }
        }
        if hadBlocked {
            let callback = onBlockedClientsChanged
            DispatchQueue.main.async { callback?([]) }
        }

        stateLock.lock()
        let device = deviceID
        let stream = sinkStreamID
        let wasConnected = isConnected
        deviceID = 0
        sinkStreamID = 0
        sinkQueue = nil
        formatDescription = nil
        formatWidth = 0
        formatHeight = 0
        isConnected = false
        stateLock.unlock()

        if wasConnected, device != 0, stream != 0 {
            CMIODeviceStopStream(device, stream)
        }
    }

    /// 1 Hz while connected: read 'clnt' and 'hoff'; fire `onClientsChanged`
    /// on change; fall back to reconnecting when the device stops answering.
    private func pollProperties() {
        stateLock.lock()
        let connected = isConnected
        stateLock.unlock()
        guard connected else { return }

        let clients = readClients()
        let handoff = readHandoffMs()

        if clients == nil && handoff == nil {
            pollFailureCount += 1
            if pollFailureCount >= Self.pollFailureLimit {
                // Extension likely restarted or was removed; go back to the
                // 1 s retry loop so we reconnect when it returns.
                teardown()
                connectRequested = true
                startRetryTimer()
            }
            return
        }
        pollFailureCount = 0

        if let handoff {
            stateLock.lock()
            lastHandoffMs = handoff
            stateLock.unlock()
        }

        if let clients, clients != lastClientIDs {
            lastClientIDs = clients
            let resolved = clients.map(CameraClient.init(signingID:))
            let callback = onClientsChanged
            DispatchQueue.main.async { callback?(resolved) }
        }

        // Only worth asking about while a policy could be refusing anything;
        // an extension with no policy always answers "[]" and the 1 Hz round
        // trip buys nothing.
        if isPolicyEnforcing {
            let blocked = readBlockedClients() ?? []
            if blocked != lastBlockedIDs {
                lastBlockedIDs = blocked
                let list = blocked.map(CameraClient.init(signingID:))
                let callback = onBlockedClientsChanged
                DispatchQueue.main.async { callback?(list) }
            }
        } else if lastBlockedIDs?.isEmpty == false {
            lastBlockedIDs = []
            let callback = onBlockedClientsChanged
            DispatchQueue.main.async { callback?([]) }
        }
    }

    // MARK: CMIO C-API helpers

    private static func globalAddress(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    /// Enumerates kCMIOHardwarePropertyDevices on the system object.
    private static func deviceList() -> [CMIOObjectID] {
        let systemID = CMIOObjectID(kCMIOObjectSystemObject)
        var address = globalAddress(UInt32(kCMIOHardwarePropertyDevices))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemID, &address, 0, nil, &dataSize) == 0,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            CMIOObjectGetPropertyData(
                systemID, &address, 0, nil, dataSize, &dataUsed, raw.baseAddress!)
        }
        guard status == 0 else { return [] }
        return ids
    }

    private static func deviceUID(_ device: CMIOObjectID) -> String? {
        var address = globalAddress(UInt32(kCMIODevicePropertyDeviceUID))
        var uidRef: Unmanaged<CFString>?
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &uidRef) { pointer -> OSStatus in
            CMIOObjectGetPropertyData(
                device, &address, 0, nil,
                UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &dataUsed, pointer)
        }
        guard status == 0, let uid = uidRef?.takeRetainedValue() else { return nil }
        return uid as String
    }

    private static func findPRISMDevice() -> CMIOObjectID? {
        for device in deviceList() where deviceUID(device) == prismDeviceUID {
            return device
        }
        return nil
    }

    private static func streamList(device: CMIOObjectID) -> [CMIOStreamID] {
        var address = globalAddress(UInt32(kCMIODevicePropertyStreams))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == 0,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        guard count > 0 else { return [] }
        var ids = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            CMIOObjectGetPropertyData(
                device, &address, 0, nil, dataSize, &dataUsed, raw.baseAddress!)
        }
        guard status == 0 else { return [] }
        return ids
    }

    private static func streamDirection(_ stream: CMIOStreamID) -> UInt32? {
        var address = globalAddress(UInt32(kCMIOStreamPropertyDirection))
        var direction: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &direction) { pointer -> OSStatus in
            CMIOObjectGetPropertyData(
                stream, &address, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &dataUsed, pointer)
        }
        guard status == 0 else { return nil }
        return direction
    }

    /// Identifies the sink stream. Per CMIOHardwareStream.h,
    /// kCMIOStreamPropertyDirection is 0 for an output stream and 1 for an
    /// input stream: the client-facing source/capture stream is the input
    /// stream (direction 1 — what AVCaptureSession reads), and the
    /// app-writable sink is the output stream (direction 0). If no stream
    /// reports direction 0, fall back to attempting the buffer-queue copy on
    /// the second stream first, then the rest. Among candidates, copy success
    /// is the tie-break.
    private static func resolveSinkStream(device: CMIOObjectID) -> (CMIOStreamID, CMSimpleQueue)? {
        let streams = streamList(device: device)
        guard !streams.isEmpty else { return nil }

        var candidates = streams.filter { streamDirection($0) == 0 }
        if candidates.isEmpty {
            var ordered = streams
            if ordered.count >= 2 { ordered.swapAt(0, 1) }
            candidates = ordered
        }

        for stream in candidates {
            var queueRef: Unmanaged<CMSimpleQueue>?
            let status = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queueRef)
            if status == 0, let queue = queueRef?.takeRetainedValue() {
                return (stream, queue)
            }
        }
        return nil
    }
}
