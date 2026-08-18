// DeviceSource.swift
// PRISMCameraExtension — the "PRISM Camera" device. Owns the source and sink
// streams, declares and serves the pfmt/clnt/hoff/afmt/polc/blkd custom
// properties (docs/CONTRACTS.md "CMIO custom properties"), and persists the
// published format list and the per-app access policy inside the extension's
// sandbox container.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreMediaIO
import Foundation
import os.log

/// kIOAudioDeviceTransportTypeVirtual ('virt') from IOKit/audio/IOAudioTypes.h,
/// declared locally because the IOKit.audio submodule is not importable from
/// a standalone CMIO extension target.
let prismTransportTypeVirtual = 0x76697274 // 'virt'

let prismLog = Logger(subsystem: "horse.prism.PRISM.camera", category: "extension")

// MARK: - Fixed identity (docs/CONTRACTS.md "Fixed identifiers")

enum PRISMIdentity {
    static let deviceName = "PRISM Camera"
    static let deviceUID = "horse.prism.PRISM.camera.device"
    static let modelUID = "PRISM Virtual Camera"
    static let sourceStreamName = "PRISM Camera Source"
    static let sinkStreamName = "PRISM Camera Sink"

    // CMIOExtension identifies devices and streams by UUID; these are fixed
    // so the published objects keep stable identities across relaunches.
    // The contract's C-API string UIDs map as follows:
    //   - device UID: `legacyDeviceID` (deviceUID above), visible to
    //     CMIOObjectGetPropertyData as kCMIODevicePropertyDeviceUID.
    //   - stream UIDs: CMIOExtensionStream has no legacy string UID, so the
    //     C API sees the UUID strings below. The app locates the sink stream
    //     by direction on the device found via deviceUID.
    static let deviceID = UUID(uuidString: "29C2D33A-6F87-4A5C-9E2B-BD10C1A730F1")!
    static let sourceStreamID = UUID(uuidString: "29C2D33A-6F87-4A5C-9E2B-BD10C1A730F2")!
    static let sinkStreamID = UUID(uuidString: "29C2D33A-6F87-4A5C-9E2B-BD10C1A730F3")!
}

// MARK: - Custom properties ('pfmt' / 'clnt' / 'hoff')

// Naming pattern "4cc_<selector>_glob_0000": FourCC selector, global scope,
// main element — how CMIOExtension surfaces custom properties to the CMIO
// C API on the app side.
enum PRISMDeviceProperty {
    /// App → extension. UTF-8 JSON array of format entries.
    static let formatList = CMIOExtensionProperty(rawValue: "4cc_pfmt_glob_0000")
    /// Extension → app. UTF-8 JSON array of streaming client signing IDs.
    static let clients = CMIOExtensionProperty(rawValue: "4cc_clnt_glob_0000")
    /// Extension → app. Float64 (8 bytes), rolling mean handoff milliseconds.
    static let handoffMs = CMIOExtensionProperty(rawValue: "4cc_hoff_glob_0000")
    /// Extension → app. UTF-8 JSON of the single format a client most
    /// recently negotiated on the source stream; empty until a client has
    /// negotiated. Lets the app retarget its pipeline to the negotiated
    /// output (SPEC §3.2 "ordinary client negotiation").
    static let activeFormat = CMIOExtensionProperty(rawValue: "4cc_afmt_glob_0000")
    /// App → extension. UTF-8 JSON of the per-app access policy (§5.15).
    static let accessPolicy = CMIOExtensionProperty(rawValue: "4cc_polc_glob_0000")
    /// Extension → app. UTF-8 JSON array of signing IDs refused recently, so
    /// the app can say *why* an app's video is dark.
    static let blockedClients = CMIOExtensionProperty(rawValue: "4cc_blkd_glob_0000")
}

// MARK: - ExtFormat

/// Local Codable mirror of the app's `VideoFormat` — the extension must not
/// link app sources (SPEC §3.1). JSON keys must match `VideoFormat`'s:
/// `width`, `height`, `frameRate`.
struct ExtFormat: Codable, Equatable {
    var width: Int
    var height: Int
    var frameRate: Int

    var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
    }
}

// MARK: - ExtAccessPolicy (§5.15)

/// Local Codable mirror of the app's `AccessPolicy`. Key names are the
/// contract; the extension must not link app sources (SPEC §3.1).
///
/// Every field is optional and every decode failure is survivable, because
/// this is the one payload in PRISM whose failure mode is a camera that
/// does not work. See `PRISMAccessPolicy.isAllowed` for the fail-open rules.
struct ExtAccessPolicy: Codable {
    var version: Int?
    var defaultAccess: String?
    var blocked: [String]?
    var allowed: [String]?
}

/// The extension's answer to "may this client start streaming".
///
/// **Fail open, always.** The app runs as the user and may be quit, crashed,
/// or never installed; the extension runs as root and outlives all of that.
/// So: no policy, an unreadable policy, a policy from a future version, or a
/// missing signing ID all resolve to *allow*. The only way to be refused is
/// an intact policy that names you, or an intact policy that says allow-list
/// and does not.
///
/// The policy is persisted next to formats.json rather than kept in memory.
/// CMIO extensions are launched on demand and torn down when idle, so an
/// in-memory policy would be cleared by quitting and reopening the very app
/// the user blocked — a block anyone can bypass by accident is not a block.
final class PRISMAccessPolicy {

    /// PRISM.app itself writes the sink stream and is never policed.
    static let selfSigningID = "horse.prism.PRISM"
    /// Highest wire version this build understands.
    private static let supportedVersion = 1

    private let lock = NSLock()
    private var policy: ExtAccessPolicy?
    /// Signing IDs refused recently, newest last, with the host time of the
    /// refusal. Bounded — this is a UI hint, not an audit log.
    private var refusals: [(signingID: String, atNs: UInt64)] = []
    private static let refusalWindowNs: UInt64 = 30_000_000_000
    private static let refusalLimit = 8

    init() {
        policy = Self.loadPersisted()
    }

    /// Returns true when the client may stream. Anything unclear is a yes.
    func isAllowed(_ signingID: String?) -> Bool {
        guard let signingID, signingID != Self.selfSigningID else { return true }
        lock.lock()
        let current = policy
        lock.unlock()
        guard let current else { return true }
        // A payload written by a newer PRISM may mean something this build
        // cannot evaluate; guessing at it is how you refuse a client you were
        // supposed to admit.
        guard (current.version ?? Self.supportedVersion) <= Self.supportedVersion else {
            return true
        }
        if current.allowed?.contains(signingID) == true { return true }
        if current.blocked?.contains(signingID) == true { return false }
        return current.defaultAccess != "block"
    }

    func noteRefused(_ signingID: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        refusals.removeAll { $0.signingID == signingID }
        refusals.append((signingID: signingID, atNs: now))
        if refusals.count > Self.refusalLimit {
            refusals.removeFirst(refusals.count - Self.refusalLimit)
        }
        lock.unlock()
    }

    /// Refusals inside the last 30 s. Blocked apps retry, so this stays
    /// populated while the user is actually looking at a dark tile and
    /// empties out once they stop.
    func recentRefusals() -> [String] {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        return refusals
            .filter { now &- $0.atNs < Self.refusalWindowNs }
            .map(\.signingID)
    }

    /// Replaces the policy from a 'polc' write. Throws only on payloads that
    /// are not JSON at all — the app must hear that its write did nothing.
    func apply(_ data: Data) throws {
        let decoded = try JSONDecoder().decode(ExtAccessPolicy.self, from: data)
        lock.lock()
        policy = decoded
        lock.unlock()
        Self.persist(data)
        prismLog.notice("access policy updated: default \(decoded.defaultAccess ?? "allow", privacy: .public), \(decoded.blocked?.count ?? 0) blocked")
    }

    // MARK: Persistence

    private static var policyFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("PRISM", isDirectory: true)
            .appendingPathComponent("policy.json", isDirectory: false)
    }

    private static func loadPersisted() -> ExtAccessPolicy? {
        guard let data = try? Data(contentsOf: policyFileURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ExtAccessPolicy.self, from: data) else {
            // A corrupt file must not outlive this launch: leaving it on disk
            // would fail open forever without ever saying why.
            prismLog.error("ignoring unreadable access policy; allowing every client")
            try? FileManager.default.removeItem(at: policyFileURL)
            return nil
        }
        return decoded
    }

    private static func persist(_ data: Data) {
        do {
            let url = policyFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            prismLog.error("failed to persist access policy: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Rolling mean (handoff milliseconds)

/// Fixed-window rolling mean; thread-safe. 60 samples ≈ 1–2 s of frames.
final class RollingMean {
    private let window: Int
    private var samples: [Double]
    private var nextIndex = 0
    private var count = 0
    private var sum = 0.0
    private let lock = NSLock()

    init(window: Int) {
        self.window = max(1, window)
        self.samples = [Double](repeating: 0, count: self.window)
    }

    func add(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        if count == window {
            sum -= samples[nextIndex]
        } else {
            count += 1
        }
        samples[nextIndex] = value
        sum += value
        nextIndex = (nextIndex + 1) % window
    }

    var mean: Double {
        lock.lock()
        defer { lock.unlock() }
        return count == 0 ? 0 : sum / Double(count)
    }
}

// MARK: - Device source

final class PRISMDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private(set) var sourceStreamSource: PRISMStreamSource!
    private(set) var sinkStreamSource: PRISMSinkStreamSource!

    private let stateLock = NSLock()
    private var extFormats: [ExtFormat]
    private var streamingClients: [(clientID: UUID, signingID: String)] = []
    private let handoff = RollingMean(window: 60)
    /// §5.15 — owns its own locking; deliberately not behind `stateLock`, so
    /// an authorization check never waits on a format republish.
    let accessPolicy = PRISMAccessPolicy()
    /// Format most recently negotiated by a client on the source stream;
    /// nil until a client negotiates (and cleared on republish).
    private var negotiatedFormat: ExtFormat?

    override init() {
        extFormats = Self.loadPersistedFormats() ?? PlaceholderRenderer.defaultFormats
        super.init()
        device = CMIOExtensionDevice(localizedName: PRISMIdentity.deviceName,
                                     deviceID: PRISMIdentity.deviceID,
                                     legacyDeviceID: PRISMIdentity.deviceUID,
                                     source: self)
        sourceStreamSource = PRISMStreamSource(deviceSource: self, extFormats: extFormats)
        sinkStreamSource = PRISMSinkStreamSource(deviceSource: self,
                                                 extFormats: extFormats,
                                                 forwardTo: sourceStreamSource)
        do {
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            fatalError("PRISM camera extension: failed to publish streams: \(error)")
        }
    }

    // MARK: CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType,
         .deviceModel,
         PRISMDeviceProperty.formatList,
         PRISMDeviceProperty.clients,
         PRISMDeviceProperty.handoffMs,
         PRISMDeviceProperty.activeFormat,
         PRISMDeviceProperty.accessPolicy,
         PRISMDeviceProperty.blockedClients]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = prismTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = PRISMIdentity.modelUID
        }
        if properties.contains(PRISMDeviceProperty.formatList) {
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: formatListJSON() as NSData as AnyObject),
                forProperty: PRISMDeviceProperty.formatList)
        }
        if properties.contains(PRISMDeviceProperty.clients) {
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: clientListJSON() as NSData as AnyObject),
                forProperty: PRISMDeviceProperty.clients)
        }
        if properties.contains(PRISMDeviceProperty.handoffMs) {
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: handoffData() as NSData as AnyObject),
                forProperty: PRISMDeviceProperty.handoffMs)
        }
        if properties.contains(PRISMDeviceProperty.activeFormat) {
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: activeFormatJSON() as NSData as AnyObject),
                forProperty: PRISMDeviceProperty.activeFormat)
        }
        if properties.contains(PRISMDeviceProperty.accessPolicy) {
            // Write-only in practice: the app is the author of the policy and
            // has no use for a copy of what it just sent. Served as empty
            // data so the property is still a legal read.
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: Data() as NSData as AnyObject),
                forProperty: PRISMDeviceProperty.accessPolicy)
        }
        if properties.contains(PRISMDeviceProperty.blockedClients) {
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: blockedClientsJSON() as NSData as AnyObject),
                forProperty: PRISMDeviceProperty.blockedClients)
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // 'pfmt' and 'polc' are the settable properties; 'clnt', 'hoff',
        // 'afmt' and 'blkd' are extension → app and writes to them are
        // ignored.
        if let state = deviceProperties.propertiesDictionary[PRISMDeviceProperty.accessPolicy] {
            guard let data = state.value as? Data else {
                throw Self.propertyError("'polc' value must be UTF-8 JSON data")
            }
            do {
                try accessPolicy.apply(data)
            } catch {
                throw Self.propertyError("'polc' JSON did not decode: \(error.localizedDescription)")
            }
        }
        guard let state = deviceProperties.propertiesDictionary[PRISMDeviceProperty.formatList] else {
            return
        }
        guard let data = state.value as? Data else {
            throw Self.propertyError("'pfmt' value must be UTF-8 JSON data")
        }
        let decoded: [ExtFormat]
        do {
            decoded = try JSONDecoder().decode([ExtFormat].self, from: data)
        } catch {
            throw Self.propertyError("'pfmt' JSON did not decode: \(error.localizedDescription)")
        }
        guard Self.isValidFormatList(decoded) else {
            throw Self.propertyError("'pfmt' format list failed validation")
        }
        try applyFormatList(decoded)
    }

    // MARK: Format list republish (SPEC §3.2 — reconnect boundary)

    private func applyFormatList(_ newFormats: [ExtFormat]) throws {
        stateLock.lock()
        let unchanged = newFormats == extFormats
        stateLock.unlock()
        if unchanged { return }

        Self.persistFormats(newFormats)
        stateLock.lock()
        extFormats = newFormats
        // Streams are recreated with activeIndex 0 and every client must
        // reselect, so any previous negotiation is void.
        negotiatedFormat = nil
        stateLock.unlock()

        // Republishing is deliberate and never silent from the user's point
        // of view — the app has already shown the reconnect confirmation
        // when clients were streaming. Tear both streams down, swap the
        // format arrays, and publish fresh stream objects under the same
        // stream IDs.
        sourceStreamSource.prepareForRepublish()
        sinkStreamSource.prepareForRepublish()
        try? device.removeStream(sinkStreamSource.stream)
        try? device.removeStream(sourceStreamSource.stream)
        clearStreamingClients()

        sourceStreamSource.updateFormats(newFormats)
        sinkStreamSource.updateFormats(newFormats)
        do {
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            prismLog.error("failed to republish streams: \(String(describing: error), privacy: .public)")
            throw error
        }

        device.notifyPropertiesChanged([
            PRISMDeviceProperty.formatList:
                CMIOExtensionPropertyState(value: formatListJSON() as NSData as AnyObject),
        ])
        prismLog.info("republished \(newFormats.count) formats")
    }

    // MARK: Streaming-client tracking ('clnt')

    // authorizedToStartStream(for:) is the only per-client callback tied to
    // streaming, so clients are added there and removed on provider
    // disconnect or when the source stream stops entirely (start/stop of
    // the extension-side stream is refcounted by the framework).

    func noteStreamingClient(_ client: CMIOExtensionClient) {
        let signingID = client.signingID ?? "unknown"
        stateLock.lock()
        var changed = false
        if !streamingClients.contains(where: { $0.clientID == client.clientID }) {
            streamingClients.append((clientID: client.clientID, signingID: signingID))
            changed = true
        }
        stateLock.unlock()
        if changed { notifyClientsChanged() }
    }

    /// §5.15 — the source stream refused this client. Recorded and published
    /// on 'blkd' so PRISM can explain a dark tile the user is staring at.
    func noteClientRefused(_ client: CMIOExtensionClient) {
        let signingID = client.signingID ?? "unknown"
        accessPolicy.noteRefused(signingID)
        prismLog.notice("refused client by policy: \(signingID, privacy: .public)")
        guard let device else { return }
        device.notifyPropertiesChanged([
            PRISMDeviceProperty.blockedClients:
                CMIOExtensionPropertyState(value: blockedClientsJSON() as NSData as AnyObject),
        ])
    }

    func noteClientDisconnected(_ client: CMIOExtensionClient) {
        stateLock.lock()
        let before = streamingClients.count
        streamingClients.removeAll { $0.clientID == client.clientID }
        let changed = streamingClients.count != before
        stateLock.unlock()
        if changed { notifyClientsChanged() }
    }

    func noteSourceStreamStopped() {
        clearStreamingClients()
    }

    private func clearStreamingClients() {
        stateLock.lock()
        let changed = !streamingClients.isEmpty
        streamingClients.removeAll()
        stateLock.unlock()
        if changed { notifyClientsChanged() }
    }

    private func notifyClientsChanged() {
        guard let device else { return }
        device.notifyPropertiesChanged([
            PRISMDeviceProperty.clients:
                CMIOExtensionPropertyState(value: clientListJSON() as NSData as AnyObject),
        ])
    }

    // MARK: Handoff ('hoff')

    func recordHandoffMs(_ ms: Double) {
        handoff.add(ms)
    }

    // MARK: Negotiated format ('afmt')

    /// Called by the source stream when a client sets activeFormatIndex.
    func noteActiveFormat(_ format: ExtFormat) {
        stateLock.lock()
        let changed = negotiatedFormat != format
        negotiatedFormat = format
        stateLock.unlock()
        guard changed, let device else { return }
        device.notifyPropertiesChanged([
            PRISMDeviceProperty.activeFormat:
                CMIOExtensionPropertyState(value: activeFormatJSON() as NSData as AnyObject),
        ])
    }

    // MARK: Property payloads

    private func formatListJSON() -> Data {
        stateLock.lock()
        let formats = extFormats
        stateLock.unlock()
        return (try? JSONEncoder().encode(formats)) ?? Data("[]".utf8)
    }

    private func clientListJSON() -> Data {
        stateLock.lock()
        let clients = streamingClients
        stateLock.unlock()
        var seen = Set<String>()
        var ids: [String] = []
        for entry in clients where !seen.contains(entry.signingID) {
            seen.insert(entry.signingID)
            ids.append(entry.signingID)
        }
        return (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8)
    }

    private func blockedClientsJSON() -> Data {
        (try? JSONEncoder().encode(accessPolicy.recentRefusals())) ?? Data("[]".utf8)
    }

    private func handoffData() -> Data {
        var value = Float64(handoff.mean)
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    /// Empty data until a client has negotiated a format.
    private func activeFormatJSON() -> Data {
        stateLock.lock()
        let format = negotiatedFormat
        stateLock.unlock()
        guard let format else { return Data() }
        return (try? JSONEncoder().encode(format)) ?? Data()
    }

    // MARK: Persistence
    // Inside the sandboxed extension container this resolves to
    // <container>/Library/Application Support/PRISM/formats.json.

    private static var formatsFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("PRISM", isDirectory: true)
            .appendingPathComponent("formats.json", isDirectory: false)
    }

    static func loadPersistedFormats() -> [ExtFormat]? {
        guard let data = try? Data(contentsOf: formatsFileURL) else { return nil }
        guard let formats = try? JSONDecoder().decode([ExtFormat].self, from: data),
              isValidFormatList(formats) else {
            prismLog.error("ignoring invalid persisted format list")
            return nil
        }
        return formats
    }

    static func persistFormats(_ formats: [ExtFormat]) {
        do {
            let url = formatsFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(formats).write(to: url, options: .atomic)
        } catch {
            prismLog.error("failed to persist format list: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Validation

    static func isValidFormatList(_ formats: [ExtFormat]) -> Bool {
        guard !formats.isEmpty, formats.count <= 64 else { return false }
        return formats.allSatisfy { format in
            (2...8192).contains(format.width)
                && (2...8192).contains(format.height)
                && (1...240).contains(format.frameRate)
        }
    }

    private static func propertyError(_ message: String) -> Error {
        NSError(domain: "horse.prism.PRISM.camera",
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
