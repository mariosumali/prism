// ScreenCapture.swift
// PRISM
//
// ScreenCaptureKit wrapper (§5.24): one display or one window as 32BGRA,
// IOSurface-backed, Metal-compatible CVPixelBuffers on a dedicated
// .userInteractive serial queue.
//
// The frames go into the *same* pipeline entry point the camera uses, so
// nothing downstream has to learn about screens: one command buffer per
// frame, the FrameRing, freeze, replay, the still ring and the latency
// attribution all keep working because none of them ever asked where the
// pixels came from.
//
// Two things about a screen are not true of a camera, and both are handled
// here rather than leaking into the pipeline:
//
//   A screen that is not changing produces no frames. ScreenCaptureKit
//   reports those as `.idle` rather than delivering pixels, which is correct
//   for a recorder and wrong for a live source — the virtual camera would
//   fall back to its placeholder over a perfectly good static slide (§3.2).
//   So the last delivered frame is re-submitted at the configured rate until
//   a new one arrives. A still screen is still a screen.
//
//   A window can close and a display can be unplugged mid-session. The
//   stream stops, and this reports it in a sentence naming the source; the
//   integration layer falls back to the camera. Nothing here ever emits a
//   black frame to fill the gap.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// A stop, in the two forms it has to exist in.
///
/// `message` is the sentence the user is shown verbatim, and it names the
/// source — "that window has closed" is only useful if you know which. But
/// the same sentence goes in the §5.21 session log, which is a plain-text
/// file people export and attach to a support thread, and a window's name is
/// its title: a document, a spreadsheet, a browser tab. So `logMessage`
/// carries the sentence with the title left out. The two are built together,
/// at the one place a stop is raised, because a redaction applied later by
/// whoever remembers is a redaction that stops being applied.
public struct ScreenCaptureStop: Equatable {
    public let message: String
    public let logMessage: String

    public init(message: String, logMessage: String? = nil) {
        self.message = message
        self.logMessage = logMessage ?? message
    }
}

/// Anything that can name the application behind it, and tell one running
/// copy from another. Exists so the display filter's exclusion rule can be
/// exercised without a live ScreenCaptureKit session: that rule is the whole
/// of PRISM's promise never to film itself, and it is the kind of promise
/// that is only ever checked by whoever notices it broke.
public protocol ScreenCaptureApplication {
    var bundleIdentifier: String { get }
    var processID: pid_t { get }
}

extension SCRunningApplication: ScreenCaptureApplication {}

public final class ScreenCapture: NSObject {

    // MARK: - Public surface (CONTRACTS.md)

    /// Called on the dedicated .userInteractive capture queue, exactly like
    /// `CameraCapture.onFrame`.
    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// The source went away, or the stream could not be built. Delivered on
    /// the main thread.
    public var onStopped: ((ScreenCaptureStop) -> Void)?

    /// Name of the display or window being captured; nil when stopped.
    public private(set) var currentSourceName: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _currentSourceName }
        set { stateLock.lock(); _currentSourceName = newValue; stateLock.unlock() }
    }

    /// The same source named the way the §5.21 session log may name it: a
    /// window's title is a document name, and the log is a file the user
    /// exports and sends to strangers. nil when stopped.
    public private(set) var currentSourceLogName: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _currentSourceLogName }
        set { stateLock.lock(); _currentSourceLogName = newValue; stateLock.unlock() }
    }

    /// True from start() until stop() or a stop the system reported. Flipped
    /// at the request edge, before the async work, for the same reason
    /// CameraCapture does it: reconciliation reads intent, never a
    /// mid-transition snapshot.
    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return _isRunning
    }

    /// What the selection resolves to right now, or nil if it no longer
    /// resolves to anything. Enumeration needs the Screen Recording grant;
    /// without it ScreenCaptureKit throws and this reports an empty list
    /// rather than prompting — the prompt belongs to an intent, not to a
    /// picker being drawn.
    public static func shareableSources() async -> [ScreenSourceInfo] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [] }
        let names = await MainActor.run { Self.displayNames() }
        var result: [ScreenSourceInfo] = content.displays.enumerated().map { index, display in
            ScreenSourceInfo(id: Self.sourceID(display: display.displayID),
                             kind: .display,
                             name: names[display.displayID] ?? "Display \(index + 1)")
        }
        let ownID = Bundle.main.bundleIdentifier
        let windows = content.windows.filter { window in
            guard window.isOnScreen else { return false }
            guard let title = window.title, !title.isEmpty else { return false }
            // PRISM's own windows are excluded for the same reason the
            // virtual camera is excluded from the camera list: capturing
            // your own preview is a feedback loop, not a source.
            guard window.owningApplication?.bundleIdentifier != ownID else { return false }
            // Menu bar items, notification badges and other chrome all
            // report as on-screen titled windows; nobody means those.
            return window.frame.width >= 80 && window.frame.height >= 80
        }
        result += windows
            .sorted {
                let left = $0.owningApplication?.applicationName ?? ""
                let right = $1.owningApplication?.applicationName ?? ""
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
                return ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
            }
            .map { window in
                ScreenSourceInfo(id: Self.sourceID(window: window.windowID),
                                 kind: .window,
                                 name: window.title ?? "Window",
                                 applicationName: window.owningApplication?.applicationName)
            }
        return result
    }

    /// Builds and starts the stream. A selection that no longer resolves —
    /// a closed window, an unplugged display — reports through `onStopped`
    /// rather than running with nothing on it.
    public func start(selection: VideoSourceSelection, outputFormat: VideoFormat) {
        stateLock.lock()
        _isRunning = true                  // request edge: intent is visible now
        requested = selection
        requestedOutputFormat = outputFormat
        generation &+= 1
        let gen = generation
        stateLock.unlock()
        Task { [weak self] in
            await self?.build(selection: selection, outputFormat: outputFormat,
                              generation: gen)
        }
    }

    public func stop() {
        stateLock.lock()
        _isRunning = false                 // before the async hop, as above
        generation &+= 1
        stateLock.unlock()
        currentSourceName = nil
        currentSourceLogName = nil
        let stream = takeStream()
        stopRepeatTimer()
        captureQueue.async { [weak self] in self?.lastBuffer = nil }
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
    }

    /// §7 sleep/wake: rebuild with the same selection. A no-op unless start()
    /// has run.
    public func restart() {
        stateLock.lock()
        let selection = requested
        let format = requestedOutputFormat
        stateLock.unlock()
        guard let selection, let format else { return }
        start(selection: selection, outputFormat: format)
    }

    // MARK: - Private state

    private let captureQueue = DispatchQueue(
        label: "horse.prism.PRISM.screen-capture",
        qos: .userInteractive)

    private let stateLock = NSLock()
    private var _isRunning = false
    private var _currentSourceName: String?
    private var _currentSourceLogName: String?

    /// Stream handle, guarded because start/stop run off any thread.
    private var streamLock = NSLock()
    private var stream: SCStream?

    // All three are stateLock-guarded: start() runs on the main thread and
    // build() on a Task's, so an unguarded counter would be exactly the race
    // it exists to close.
    private var requested: VideoSourceSelection?
    private var requestedOutputFormat: VideoFormat?
    /// Bumped on every start/stop; a build from an older generation abandons
    /// itself rather than installing a stream nobody asked for.
    private var generation: UInt64 = 0

    private func isCurrent(_ gen: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return gen == generation
    }

    // captureQueue-confined
    private var lastBuffer: CVPixelBuffer?
    private var lastDelivery: CFTimeInterval = 0
    private var repeatTimer: DispatchSourceTimer?

    /// Frames ScreenCaptureKit may hold for us. Three is its floor, and the
    /// floor is what PRISM wants: every slot is a full-size IOSurface against
    /// a ceiling ResourceGovernor is already rationing (§5.23), and a deeper
    /// queue buys latency, not smoothness.
    static let queueDepth = 3

    deinit {
        repeatTimer?.cancel()
    }

    // MARK: - Stream construction

    private func build(selection: VideoSourceSelection,
                       outputFormat: VideoFormat,
                       generation gen: UInt64) async {
        guard isCurrent(gen) else { return }
        guard CGPreflightScreenCaptureAccess() else {
            fail(gen: gen, "PRISM needs Screen Recording permission to share a screen.")
            return
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else {
            fail(gen: gen, "PRISM could not read the list of screens and windows.")
            return
        }
        guard isCurrent(gen) else { return }

        let filter: SCContentFilter
        let sourceSize: CGSize
        let name: String
        let logName: String
        switch selection.kind {
        case .camera:
            return                          // not this class's business
        case .display:
            guard let id = Self.displayID(from: selection.sourceID),
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                fail(gen: gen, "That screen is no longer available.")
                return
            }
            // Everything on the display except PRISM itself: a window showing
            // the preview of what is being captured is the one thing that
            // cannot be in the capture — and the prompter pane is a window
            // holding the script the user is reading from (§5.27).
            let ownApps = await ownApplications(in: content)
            guard !ownApps.isEmpty else {
                // Never guess. A display capture with no exclusion is one
                // that films the prompter the moment the user opens it, and
                // a share that does not start is recoverable in a way a
                // script read out to the call is not.
                fail(gen: gen, "PRISM could not confirm its own windows would be "
                     + "left out of the capture, so it did not start one.")
                return
            }
            filter = SCContentFilter(display: display,
                                     excludingApplications: ownApps,
                                     exceptingWindows: [])
            sourceSize = CGSize(width: display.width, height: display.height)
            name = await MainActor.run { Self.displayNames()[id] } ?? "Screen"
            logName = name              // a display's name is a device name
        case .window:
            guard let id = Self.windowID(from: selection.sourceID),
                  let window = content.windows.first(where: { $0.windowID == id }) else {
                fail(gen: gen, "That window has closed.")
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceSize = window.frame.size
            name = window.title ?? "Window"
            logName = ScreenSourceInfo.logName(
                kind: .window, name: name,
                applicationName: window.owningApplication?.applicationName)
        }

        let size = Self.captureSize(source: sourceSize, within: outputFormat)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = prismPixelFormat
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.queueDepth = Self.queueDepth
        configuration.minimumFrameInterval =
            CMTime(value: 1, timescale: CMTimeScale(max(1, outputFormat.frameRate)))

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
        } catch {
            fail(gen: gen, "PRISM could not capture \(name): \(error.localizedDescription)",
                 log: "PRISM could not capture \(logName): \(error.localizedDescription)")
            return
        }
        guard isCurrent(gen) else {
            try? await stream.stopCapture()
            return
        }
        // withLock rather than lock()/unlock(): this is an async context, and
        // a bare lock there is an error in the Swift 6 language mode.
        streamLock.withLock { self.stream = stream }
        currentSourceName = name
        currentSourceLogName = logName
        startRepeatTimer(frameRate: outputFormat.frameRate)
    }

    /// PRISM's own `SCRunningApplication`s, for the display filter.
    ///
    /// The on-screen snapshot lists an application only while it has a window
    /// on screen, and a menu bar app sharing a display from a chord — with
    /// its main window never opened and the menu bar itself hidden behind
    /// somebody else's full-screen window — can have none. That is exactly
    /// the launch this used to leak from, so the off-screen snapshot is the
    /// fallback: one extra round trip at stream build against the risk of
    /// compositing PRISM's own windows into the call.
    private func ownApplications(in content: SCShareableContent) async
        -> [SCRunningApplication] {
        let bundleID = Bundle.main.bundleIdentifier
        let own = Self.ownApplications(applications: content.applications,
                                       windowOwners: content.windows.map(\.owningApplication),
                                       bundleID: bundleID)
        guard own.isEmpty else { return own }
        guard let all = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else { return [] }
        return Self.ownApplications(applications: all.applications,
                                    windowOwners: all.windows.map(\.owningApplication),
                                    bundleID: bundleID)
    }

    /// The exclusion rule itself, as a function of bundle identifier.
    ///
    /// Excluding by *application* rather than by a list of windows is the
    /// whole of the guarantee. `SCShareableContent` is a snapshot taken when
    /// the stream is built, and PRISM's windows are made lazily — the main
    /// window on first open, the prompter pane inside it, the popover's
    /// window on demand — while the filter is never rebuilt (a selection or
    /// format change is what restarts the stream, not a window appearing).
    /// A filter built from that snapshot therefore composites every PRISM
    /// window opened afterwards into the outgoing camera, the pane holding
    /// the user's script included. An application exclusion covers windows
    /// that do not exist yet, which is the only version of this that is
    /// actually true.
    ///
    /// Window owners are folded in because a content snapshot may list only
    /// applications it already matched a window to; the two together mean
    /// the exclusion is never empty for a reason that is not "PRISM is not
    /// running".
    static func ownApplications<App: ScreenCaptureApplication>(
        applications: [App],
        windowOwners: [App?],
        bundleID: String?) -> [App] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        var seen = Set<pid_t>()
        var result: [App] = []
        for app in applications + windowOwners.compactMap({ $0 })
        where app.bundleIdentifier == bundleID && seen.insert(app.processID).inserted {
            result.append(app)
        }
        return result
    }

    private func takeStream() -> SCStream? {
        streamLock.lock()
        defer { streamLock.unlock() }
        let current = stream
        stream = nil
        return current
    }

    /// One exit for every way a stream can fail to be, or stop being, a
    /// source. Marks the request dead so reconciliation can start a fresh
    /// one, and hands the sentence up.
    private func fail(gen: UInt64, _ message: String, log: String? = nil) {
        guard isCurrent(gen) else { return }
        stateLock.lock()
        _isRunning = false
        stateLock.unlock()
        currentSourceName = nil
        currentSourceLogName = nil
        stopRepeatTimer()
        let stop = ScreenCaptureStop(message: message, logMessage: log)
        if let onStopped {
            DispatchQueue.main.async { onStopped(stop) }
        }
    }

    // MARK: - Frame delivery

    /// captureQueue only.
    private func deliver(_ buffer: CVPixelBuffer, at time: CMTime) {
        lastBuffer = buffer
        lastDelivery = CACurrentMediaTime()
        onFrame?(buffer, time)
    }

    /// A screen with nothing moving on it delivers no frames, and a virtual
    /// camera with no frames is a placeholder (§3.2). Re-submitting the last
    /// picture at the configured rate is what a camera pointed at a still
    /// scene would do, and it keeps every downstream clock — the ring, the
    /// replay buffer, the latency monitor — running on real frames.
    private func startRepeatTimer(frameRate: Int) {
        let interval = 1.0 / Double(max(1, frameRate))
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.repeatTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.captureQueue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self, let buffer = self.lastBuffer else { return }
                guard CACurrentMediaTime() - self.lastDelivery > interval * 1.5 else { return }
                self.deliver(buffer, at: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            timer.resume()
            self.repeatTimer = timer
        }
    }

    private func stopRepeatTimer() {
        captureQueue.async { [weak self] in
            self?.repeatTimer?.cancel()
            self?.repeatTimer = nil
        }
    }

    // MARK: - Source identifiers

    /// Displays and windows are numbered in separate namespaces by the window
    /// server, so the two can collide; the prefix is what makes one string
    /// enough to name either.
    public static func sourceID(display: CGDirectDisplayID) -> String {
        "display:\(display)"
    }

    public static func sourceID(window: CGWindowID) -> String {
        "window:\(window)"
    }

    public static func displayID(from sourceID: String?) -> CGDirectDisplayID? {
        guard let raw = sourceID, raw.hasPrefix("display:"),
              let value = UInt32(raw.dropFirst("display:".count)) else { return nil }
        return CGDirectDisplayID(value)
    }

    public static func windowID(from sourceID: String?) -> CGWindowID? {
        guard let raw = sourceID, raw.hasPrefix("window:"),
              let value = UInt32(raw.dropFirst("window:".count)) else { return nil }
        return CGWindowID(value)
    }

    // MARK: - Sizing

    /// The capture is scaled to fit the negotiated output format with its own
    /// aspect preserved.
    ///
    /// Capturing a 6K display at native size would cost 3 IOSurface slots of
    /// ~100 MB each against a 250 MB ceiling (§5.23) to produce pixels the
    /// output fit is about to throw away. Fitting rather than filling means
    /// the letterboxing is decided once, by OutputFitStage, in the same place
    /// it is decided for every other source — ScreenCaptureKit is never asked
    /// to pad, so it never pads with a colour PRISM did not choose.
    ///
    /// Dimensions are rounded to even numbers because odd-width BGRA surfaces
    /// are a per-driver lottery nobody needs to play.
    public static func captureSize(source: CGSize,
                                   within format: VideoFormat) -> (width: Int, height: Int) {
        let maxWidth = max(2, format.width)
        let maxHeight = max(2, format.height)
        guard source.width > 0, source.height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(Double(maxWidth) / Double(source.width),
                        Double(maxHeight) / Double(source.height),
                        1)
        let width = Int((Double(source.width) * scale).rounded())
        let height = Int((Double(source.height) * scale).rounded())
        return (max(2, width - width % 2), max(2, height - height % 2))
    }

    /// Display names, main-thread only (NSScreen is). Keyed by display ID so
    /// the enumeration above can name a display the window server only gives
    /// it a number for.
    @MainActor
    private static func displayNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return names
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension ScreenCapture: SCStreamOutput, SCStreamDelegate {

    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        // `.idle`, `.blank` and `.suspended` frames carry no new pixels — and
        // often no image buffer at all. Skipping them hands the job to the
        // repeat timer, which re-sends the last real picture.
        guard Self.isComplete(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver(buffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamLock.lock()
        let isCurrent = self.stream === stream
        if isCurrent { self.stream = nil }
        streamLock.unlock()
        guard isCurrent else { return }
        stateLock.lock()
        let gen = generation
        stateLock.unlock()
        let name = currentSourceName ?? "That screen"
        let logName = currentSourceLogName ?? "That screen"
        fail(gen: gen, "\(name) stopped sharing: \(error.localizedDescription)",
             log: "\(logName) stopped sharing: \(error.localizedDescription)")
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            // No status attachment at all: trust the pixels. An older or
            // stricter OS that stops annotating frames must not silently
            // stop the picture.
            return true
        }
        return status == .complete
    }
}
