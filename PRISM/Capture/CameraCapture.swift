// CameraCapture.swift
// PRISM
//
// AVCaptureSession wrapper (SPEC §3.3, §5.1, §7). Captures 32BGRA,
// IOSurface-backed, Metal-compatible frames from the selected physical
// camera on a dedicated .userInteractive serial queue and hands them to the
// pipeline. Excludes PRISM's own virtual camera from default/fallback
// resolution, and rebuilds the session on sleep/wake with a retry schedule.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public final class CameraCapture: NSObject {

    // MARK: - Public surface (CONTRACTS.md)

    /// Called on the dedicated .userInteractive capture queue.
    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    public var onRuntimeError: ((String) -> Void)?

    /// Name of the device currently capturing; nil when stopped. Written on
    /// the session queue, readable from any thread.
    public private(set) var currentDeviceName: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _currentDeviceName }
        set { stateLock.lock(); _currentDeviceName = newValue; stateLock.unlock() }
    }

    /// uniqueID of the device the running session is bound to; nil when
    /// stopped. Lets AppState detect that the *default-resolved* device (a
    /// nil selection) was unplugged — `requestedDeviceID` cannot tell it that.
    public private(set) var currentDeviceID: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _currentDeviceID }
        set { stateLock.lock(); _currentDeviceID = newValue; stateLock.unlock() }
    }

    /// True from start()/restart() until stop() or a *known* failure (retry
    /// ladder exhausted, fatal runtime error). Flipped synchronously at the
    /// request edge — start() marks it true and stop() false before their
    /// sessionQueue hop — so AppState's reconciliation reads intent, never a
    /// mid-transition snapshot: no double-start while a build is in flight,
    /// and no start slipping in after demand has ceased. Deliberately not
    /// queue-synced: buildAndRun hops sessionQueue → main for FormatManager,
    /// so a sessionQueue.sync here from the main thread could deadlock.
    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return _isRunning
    }

    // MARK: - Private state

    /// Delegate queue for AVCaptureVideoDataOutput — dedicated serial queue
    /// at .userInteractive QoS per §3.3.
    private let captureQueue = DispatchQueue(
        label: "horse.prism.PRISM.camera-capture",
        qos: .userInteractive)

    /// Session work (configuration, startRunning, teardown) happens off the
    /// main thread on this queue so start()/restart() never block the UI.
    private let sessionQueue = DispatchQueue(
        label: "horse.prism.PRISM.camera-session",
        qos: .userInitiated)

    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var runtimeErrorObserver: NSObjectProtocol?

    /// Guards the cross-thread-readable snapshot (_isRunning,
    /// _currentDeviceName). Everything else is sessionQueue-confined.
    private let stateLock = NSLock()
    private var _isRunning = false
    private var _currentDeviceName: String?
    private var _currentDeviceID: String?

    /// Last-requested selection, kept so restart() can rebuild identically.
    private var requestedDeviceID: String?
    private var requestedOutputFormat: VideoFormat?

    /// Monotonically bumped on every start/stop/restart; pending retry
    /// attempts from an older generation abandon themselves.
    private var generation: UInt64 = 0

    /// §7 sleep/wake retry schedule, seconds.
    private static let retryDelays: [Double] = [0.5, 1.0, 2.0, 4.0]

    public override init() {
        super.init()
    }

    deinit {
        tearDownLocked()
    }

    // MARK: - Lifecycle

    /// Selects the device (nil = default), picks the physical format via
    /// FormatManager.physicalFormat (§3.2: smallest native ≥ output in both
    /// dimensions), configures per §3.3, and starts the session.
    public func start(deviceID: String?, outputFormat: VideoFormat) {
        stateLock.lock()
        _isRunning = true              // request edge: intent is visible now
        stateLock.unlock()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.requestedDeviceID = deviceID
            self.requestedOutputFormat = outputFormat
            self.tearDownLocked()
            self.buildAndRun(deviceID: deviceID,
                             outputFormat: outputFormat,
                             generation: self.generation,
                             attempt: 0)
        }
    }

    public func stop() {
        stateLock.lock()
        _isRunning = false             // request edge, before the queue hop:
        stateLock.unlock()             // no restart-if-running path may fire
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.tearDownLocked()
        }
    }

    /// §7 sleep/wake: tear down and rebuild the session with the same
    /// selection, retrying at 0.5s / 1s / 2s / 4s until the device is back.
    /// A no-op unless start() has run (requestedOutputFormat set).
    public func restart() {
        sessionQueue.async { [weak self] in
            guard let self, let format = self.requestedOutputFormat else { return }
            self.stateLock.lock()
            self._isRunning = true
            self.stateLock.unlock()
            self.generation &+= 1
            let deviceID = self.requestedDeviceID
            self.tearDownLocked()
            self.buildAndRun(deviceID: deviceID,
                             outputFormat: format,
                             generation: self.generation,
                             attempt: 0)
        }
    }

    // MARK: - Session construction (sessionQueue only)

    private func buildAndRun(deviceID: String?,
                             outputFormat: VideoFormat,
                             generation gen: UInt64,
                             attempt: Int) {
        guard gen == generation else { return }   // superseded

        guard let device = CameraCapture.resolveDevice(deviceID: deviceID) else {
            scheduleRetry(deviceID: deviceID, outputFormat: outputFormat,
                          generation: gen, attempt: attempt,
                          reason: "No camera available")
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        // Physical format is chosen explicitly below via device.activeFormat;
        // on macOS the session honors it without a preset (.inputPriority is
        // an iOS-only concept).

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            scheduleRetry(deviceID: deviceID, outputFormat: outputFormat,
                          generation: gen, attempt: attempt,
                          reason: "Cannot open \(device.localizedName): \(error.localizedDescription)")
            return
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            scheduleRetry(deviceID: deviceID, outputFormat: outputFormat,
                          generation: gen, attempt: attempt,
                          reason: "Cannot attach \(device.localizedName)")
            return
        }
        session.addInput(input)

        // §3.3 output configuration.
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: prismPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            scheduleRetry(deviceID: deviceID, outputFormat: outputFormat,
                          generation: gen, attempt: attempt,
                          reason: "Cannot add video output for \(device.localizedName)")
            return
        }
        session.addOutput(output)

        // Capture the scene as it actually is. AVFoundation leaves
        // automaticallyAdjustsVideoMirroring on by default, which mirrors
        // front-position devices — the built-in FaceTime camera and
        // Continuity Camera both report .front — so frames would arrive
        // pre-flipped and every consumer downstream would inherit it: the
        // preview, the virtual camera, replay, clips, moments. §5.4 makes
        // Mirror a user control defaulting to none, and §8.3 makes the
        // preview show exactly what clients see; both only hold if the feed
        // entering the pipeline is unmirrored. Pin it explicitly rather than
        // trusting a default that varies by device position and OS version.
        // Order matters: isVideoMirrored throws while the automatic flag is
        // still set, and both are only settable when mirroring is supported.
        if let connection = output.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        // §3.2: physical capture format — smallest native ≥ negotiated
        // output in both dimensions. Implemented by the pipeline component;
        // FormatManager is @MainActor so hop when needed.
        let physical = CameraCapture.physicalFormat(for: device, output: outputFormat)
        do {
            try device.lockForConfiguration()
            if let physical {
                device.activeFormat = physical
            }
            // Min/max frame duration = output fps, when the active format
            // supports that rate.
            let fps = Double(outputFormat.frameRate)
            let supported = device.activeFormat.videoSupportedFrameRateRanges
                .contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
            if supported {
                let duration = CMTime(value: 1, timescale: CMTimeScale(outputFormat.frameRate))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            // Format lock failure is non-fatal: capture proceeds at the
            // device's current format and the pipeline's output fit rescales.
            reportError("Could not configure \(device.localizedName): \(error.localizedDescription)")
        }

        session.commitConfiguration()

        self.session = session
        self.videoOutput = output
        self.currentDeviceName = device.localizedName
        self.currentDeviceID = device.uniqueID
        observeRuntimeErrors(of: session)

        session.startRunning()

        if !session.isRunning {
            tearDownLocked()
            scheduleRetry(deviceID: deviceID, outputFormat: outputFormat,
                          generation: gen, attempt: attempt,
                          reason: "\(device.localizedName) failed to start")
        }
    }

    private func scheduleRetry(deviceID: String?, outputFormat: VideoFormat,
                               generation gen: UInt64, attempt: Int,
                               reason: String) {
        guard attempt < CameraCapture.retryDelays.count else {
            // Ladder exhausted: this request is dead. Make isRunning say so,
            // so a later device arrival can reconcile a fresh start.
            stateLock.lock()
            _isRunning = false
            stateLock.unlock()
            reportError(reason)
            return
        }
        let delay = CameraCapture.retryDelays[attempt]
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.buildAndRun(deviceID: deviceID, outputFormat: outputFormat,
                             generation: gen, attempt: attempt + 1)
        }
    }

    private func tearDownLocked() {
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }
        if let session {
            if session.isRunning { session.stopRunning() }
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
        }
        session = nil
        videoOutput = nil
        currentDeviceName = nil
        currentDeviceID = nil
        // _isRunning is deliberately NOT cleared here: the flag tracks the
        // requested state and is owned by start()/stop() plus the two known
        // failure edges (retry exhaustion, fatal runtime error). Teardown
        // also runs mid-rebuild, where clearing it would open a window for a
        // concurrent reconcile to double-start the session.
    }

    private func observeRuntimeErrors(of session: AVCaptureSession) {
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] note in
            let message: String
            if let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                message = error.localizedDescription
            } else {
                message = "Capture session runtime error"
            }
            guard let self else { return }
            // Re-derive liveness on the session queue: a fatal error leaves
            // the session stopped, and a stale isRunning == true would make
            // AppState's reconciliation refuse to ever heal the capture.
            // Transient errors (session still running) stay warning-only.
            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                if let current = self.session, !current.isRunning {
                    self.tearDownLocked()      // release the wedged device
                    self.stateLock.lock()
                    self._isRunning = false
                    self.stateLock.unlock()
                }
                self.reportError(message)
            }
        }
    }

    private func reportError(_ message: String) {
        if let onRuntimeError {
            DispatchQueue.main.async { onRuntimeError(message) }
        }
    }

    // MARK: - Device resolution

    /// PRISM's own virtual camera must never be captured from (§3.3) —
    /// doing so would feed the output back into itself.
    static func isPrismVirtualCamera(_ device: AVCaptureDevice) -> Bool {
        device.localizedName == "PRISM Camera"
            || device.uniqueID.contains("horse.prism.PRISM.camera")
    }

    private static func discoveredCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified)
        return discovery.devices
    }

    /// deviceID = nil → system default video device; a default or fallback
    /// that resolves to the PRISM virtual camera is skipped in favor of the
    /// first physical camera.
    private static func resolveDevice(deviceID: String?) -> AVCaptureDevice? {
        let cameras = discoveredCameras().filter { !isPrismVirtualCamera($0) }
        if let deviceID {
            if let match = cameras.first(where: { $0.uniqueID == deviceID }) {
                return match
            }
            // Selected device vanished — fall through to default (§5.1).
        }
        if let def = AVCaptureDevice.default(for: .video), !isPrismVirtualCamera(def) {
            return def
        }
        return cameras.first
    }

    /// FormatManager is @MainActor; the session queue hops to main for the
    /// (pure, fast) format computation.
    private static func physicalFormat(for device: AVCaptureDevice,
                                       output: VideoFormat) -> AVCaptureDevice.Format? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                FormatManager.physicalFormat(for: device, output: output)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                FormatManager.physicalFormat(for: device, output: output)
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let onFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame(pixelBuffer, time)
    }
}
