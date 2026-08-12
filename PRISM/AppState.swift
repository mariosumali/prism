// AppState.swift
// PRISM
//
// Single source of truth. Owns every component, wires the frame path
// (camera → pipeline → CMIO sink), the audio path (capture/clip → SHM ring),
// the latency monitor's degradation engine, presets, hotkeys, onboarding,
// and all user intents from the UI.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import AVFoundation
import Combine
import CoreMedia
import Metal
import SwiftUI
import UserNotifications

/// Cross-thread mailbox for the latest preview texture. onOutput fires on
/// Metal's completion thread; the preview reads from the UI. A lock-guarded
/// box avoids a per-frame main-actor hop and lets teardown drop the
/// reference immediately (§8.3: closed popover retains zero textures).
///
/// The enabled bit closes the teardown race: the completion thread's
/// `previewEnabled` check is unsynchronized, so a store can land after the
/// main thread cleared the box — with no later frame to overwrite it, that
/// texture would be retained for as long as PRISM idles. Disabling under
/// the same lock makes the late store a drop instead.
final class PreviewTextureBox {
    private let lock = NSLock()
    private var texture: MTLTexture?
    private var enabled = true

    func store(_ t: MTLTexture?) {
        lock.lock()
        texture = enabled ? t : nil
        lock.unlock()
    }

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on {
            texture = nil
        }
        lock.unlock()
    }

    func take() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return texture
    }
}

@MainActor
public final class AppState: ObservableObject {

    // MARK: - Published surface (CONTRACTS.md)

    // Status
    @Published public var latency = LatencyReport()
    @Published public var clientsInUse: [String] = []
    @Published public var warning: WarningMessage?
    @Published public var menuBarState: MenuBarState = .idle
    @Published public var setup = SetupStatus()
    // Controls
    @Published public var isFrozen = false
    @Published public var isMuted = false
    // Clip
    @Published public var clipState: ClipState = .none
    @Published public var clipDuration: Double = 0
    @Published public var clipPosition: Double = 0
    @Published public var clipLoops = true {
        didSet { clipPlayer?.loops = clipLoops }
    }
    @Published public var clipUsesClipAudio = true {
        didSet {
            // Ordering keeps the ring single-producer (§4.3) in both
            // directions: suppress the mic before the clip pump may start
            // writing (the pump additionally waits for the RT ack), and stop
            // the pump before the mic resumes.
            if clipUsesClipAudio {
                updateAudioRouting()
                clipPlayer?.useClipAudio = true
            } else {
                clipPlayer?.useClipAudio = false
                updateAudioRouting()
            }
        }
    }
    // Pipeline / format
    @Published public var config = PipelineConfiguration()
    @Published public var stageStatus: [StageID: StageStatus] = [:]
    @Published public var publishedFormats: [VideoFormat] = VideoFormat.defaultSet
    // Devices
    @Published public var cameras: [CameraDeviceInfo] = []
    @Published public var microphones: [AudioDeviceInfo] = []
    // Presets
    @Published public var presets: [Preset] = []
    @Published public var activePresetID: UUID?
    // Sections
    @Published public var expandedSections: Set<PopoverSection> = [] {
        didSet { persistExpandedSections() }
    }
    /// Which modules the menu bar dropdown shows, in order — edited from the
    /// main window's Menu Bar pane.
    @Published public var popoverLayout: [PopoverModuleItem] = PopoverModuleItem.defaultLayout {
        didSet { persistPopoverLayout() }
    }
    /// Non-nil while "preview edits before applying" is on: the pending
    /// look, rendered privately by DraftRenderer and pushed to the live
    /// pipeline only by applyDraft(). The draft owns the *visual*
    /// configuration — geometry/adjust/LUT/blur and their flags; format,
    /// latency policy, and device picks always edit live and are carried
    /// over from the live config at apply time. Every editing surface
    /// (popover, main window, Settings) goes through updateEditing, so all
    /// of them show and edit the same pending draft — no surface can write
    /// around another.
    @Published public var draftConfig: PipelineConfiguration?
    /// §8.6: incremented when the latency meter is clicked so FormatSection
    /// can move keyboard/VoiceOver focus to the Latency policy control.
    @Published public var latencyPolicyFocusRequest = 0
    // Popover / preview
    @Published public var popoverOpen = false {
        didSet { previewConsumersChanged() }
    }
    /// The main PRISM window counts as a preview consumer exactly like the
    /// popover: its Studio preview drives capture demand and pipeline preview.
    @Published public var mainWindowOpen = false {
        didSet { previewConsumersChanged() }
    }

    /// True while any surface (popover or main window) is showing the preview.
    public var previewActive: Bool { popoverOpen || mainWindowOpen }

    /// Installed by the app delegate at launch; AppState cannot reference the
    /// window controller directly (the UI layer is excluded from PRISMTests).
    public var openMainWindowHandler: (() -> Void)?

    public var previewTextureProvider: (() -> MTLTexture?) = { nil }
    public var draftPreviewTextureProvider: (() -> MTLTexture?) = { nil }

    // MARK: - Sub-objects the UI observes directly

    public let permissions = Permissions()
    public let extensionInstaller = ExtensionInstaller()
    public let presetStore = PresetStore()

    // MARK: - Components

    private var metal: MetalContext?
    private var pipeline: VideoPipeline?
    private let cameraCapture = CameraCapture()
    private let audioCapture = AudioCapture()
    private let deviceMonitor = DeviceMonitor()
    private let cmioSink = CMIOSink()
    private var audioSink: AudioSink?
    /// nil only when Metal is unavailable (the §8.2 error state).
    private var clipPlayer: ClipPlayer?
    private let monitor = LatencyMonitor()
    private let formatManager = FormatManager()
    private let hotkeys = Hotkeys()
    private let autoFramer = AutoFramer()

    private let previewBox = PreviewTextureBox()
    /// Draft preview path: the renderer lives only while the main window is
    /// open with a draft pending; the box outlives it (same shape as the
    /// live previewBox).
    private let draftRendererBox = DraftRendererBox()
    private let draftPreviewBox = PreviewTextureBox()
    private var cancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?
    private var autoFrameTimer: Timer?
    private var noCameraTimer: Timer?
    private var lastCameraFrameAt = Date.distantPast
    private let lastFrameLock = NSLock()
    private var formatsPublishedToExtension = false
    /// One-shot: the automatic extension activation request for this launch.
    private var autoRequestedExtension = false
    /// Last client-negotiated format observed via 'afmt'; only *changes* are
    /// applied so a stale extension value never fights the user's selection.
    private var lastNegotiatedFormat: VideoFormat?
    private var lastSinkDroppedFrames = 0
    private var started = false

    private enum DefaultsKey {
        static let configuration = "PRISM.configuration"
        static let camera = "PRISM.selectedCamera"
        static let microphone = "PRISM.selectedMicrophone"
        static let sections = "PRISM.expandedSections"
        static let popoverLayout = "PRISM.popoverLayout"
    }

    // MARK: - Init

    public init() {
        // Metal is required for everything downstream; a Mac without Metal
        // cannot run the pipeline at all, so surface that as the error state.
        do {
            let metal = try MetalContext()
            self.metal = metal
            let pipeline = try VideoPipeline(metal: metal)
            self.pipeline = pipeline
            self.clipPlayer = ClipPlayer(metal: metal)
        } catch {
            // No Metal device: surface the error state and run without the
            // pipeline/clip player rather than crashing on exactly the
            // hardware this branch exists to handle.
            self.clipPlayer = nil
            warning = WarningMessage(text: "PRISM needs a Metal-capable GPU to run.")
            menuBarState = .error
        }

        audioSink = AudioSink()
        audioCapture.sink = audioSink
        clipPlayer?.audioSink = audioSink
        // Ring ownership handshake (§4.3 SPSC): clip audio may write only
        // once live capture is not running or has acknowledged suppression.
        clipPlayer?.audioWriteAllowed = { [audioCapture] in
            !audioCapture.isCapturing || audioCapture.suppressionEngaged
        }
        pipeline?.clipStage.player = clipPlayer

        loadPersistedState()
        wireFramePath()
        wireLatencyMonitor()
        wireClipPlayer()
        wireDeviceMonitor()
        wireSink()
        wireHotkeys()
        wireSetupObservers()

        previewTextureProvider = { [previewBox] in previewBox.take() }
        draftPreviewTextureProvider = { [draftPreviewBox] in draftPreviewBox.take() }
        presets = presetStore.presets
        presetStore.$presets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                self?.presets = list
                self?.pushPresetHotkeyBindings(list)
            }
            .store(in: &cancellables)
    }

    /// Called once from the app delegate after launch.
    public func start() {
        guard !started else { return }
        started = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        LoginItem.registerIfFirstLaunch()
        extensionInstaller.checkStatus()
        cmioSink.connect()
        hotkeys.start()
        deviceMonitor.start()

        pipeline?.previewEnabled = previewActive
        pipeline?.configure(outputFormat: formatManager.activeFormat)
        pipeline?.apply(config)
        monitor.setPolicy(config.latencyPolicy,
                          frameIntervalMs: formatManager.activeFormat.frameIntervalMs)

        Task { [weak self] in
            guard let self else { return }
            // Prompt at launch (onboarding needs the grants), but do NOT
            // start capturing: capture follows demand, not permission.
            _ = await self.permissions.requestCamera()
            _ = await self.permissions.requestMicrophone()
            self.reconcileCaptures()
            self.refreshSetupStatus()
        }

        startPolling()
        refreshDeviceLists()
        refreshSetupStatus()
        updateMenuBarState()
    }

    // MARK: - Wiring

    private func wireFramePath() {
        guard let pipeline else { return }

        cameraCapture.onFrame = { [weak self, weak pipeline, draftRendererBox] buffer, time in
            guard let self, let pipeline else { return }
            self.lastFrameLock.lock()
            self.lastCameraFrameAt = Date()
            self.lastFrameLock.unlock()
            pipeline.submitCameraFrame(buffer, at: time)
            // Draft preview rides the same frames; submit() drops when busy.
            draftRendererBox.get()?.submit(buffer)
        }
        cameraCapture.onRuntimeError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.warning = WarningMessage(text: message)
                self.updateMenuBarState()
                // A fatal error cleared cameraCapture.isRunning; while demand
                // holds, reconciliation restarts the camera (fresh ladder).
                self.reconcileCaptures()
            }
        }

        pipeline.onOutput = { [weak self, weak pipeline] buffer, time, texture in
            guard let self, let pipeline else { return }
            self.cmioSink.send(buffer, at: time)
            if pipeline.previewEnabled {
                self.previewBox.store(texture)
            }
        }
        pipeline.onTimings = { [weak self] timings in
            self?.monitor.record(timings)
        }
    }

    private func wireLatencyMonitor() {
        monitor.stageQuery = { [weak self] in
            guard let self, let pipeline = self.pipeline else { return [] }
            return pipeline.stages.map { stage in
                (id: stage.id, cost: stage.cost, enabled: stage.isEnabled,
                 pinned: self.config.flags(for: stage.id).pinned)
            }
        }
        monitor.onAutoDisable = { [weak self] id in
            guard let self else { return }
            self.stage(id)?.isEnabled = false
            self.reconcileBlurMaskRouting()
            var status = self.stageStatus[id] ?? StageStatus()
            status.autoDisabled = true
            self.stageStatus[id] = status
            self.warning = WarningMessage(
                text: "\(id.displayName) turned off to keep video smooth")
            self.updateMenuBarState()
        }
        monitor.onAutoReenable = { [weak self] id in
            guard let self else { return }
            // Restore only what the user's configuration still wants on.
            if self.config.flags(for: id).enabled {
                self.stage(id)?.isEnabled = true
            }
            self.reconcileBlurMaskRouting()
            var status = self.stageStatus[id] ?? StageStatus()
            status.autoDisabled = false
            self.stageStatus[id] = status
            if self.warning?.text.hasSuffix("to keep video smooth") == true {
                self.warning = nil
            }
            self.updateMenuBarState()
        }
        monitor.onPolicyPressure = { [weak self] in
            self?.warning = WarningMessage(
                text: "Effects are exceeding your latency budget",
                action: .raiseBudget)
        }
        monitor.$report
            .receive(on: DispatchQueue.main)
            .sink { [weak self] report in
                guard let self else { return }
                self.latency = report
                for id in StageID.allCases {
                    var status = self.stageStatus[id] ?? StageStatus()
                    status.measuredMs = report.stages[id] ?? 0
                    self.stageStatus[id] = status
                }
            }
            .store(in: &cancellables)
    }

    private func wireClipPlayer() {
        guard let clipPlayer else { return }
        clipPlayer.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.clipState = state
                self?.updateAudioRouting()
                self?.updateMenuBarState()
            }
            .store(in: &cancellables)
        clipPlayer.$durationSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.clipDuration = $0 }
            .store(in: &cancellables)
        clipPlayer.$positionSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.clipPosition = $0 }
            .store(in: &cancellables)
        clipPlayer.onEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // §5.2: if output is frozen, re-arm the freeze frame before
                // the clip unloads, so live video cannot silently resume.
                if self.isFrozen {
                    self.pipeline?.refreezeFromCurrentOutput()
                }
                // §5.3: loop off + clip end → 200ms crossfade back to live.
                self.pipeline?.beginCrossfade(durationMs: 200)
                self.clipPlayer?.stop()
                self.updateAudioRouting()
            }
        }
    }

    private func wireDeviceMonitor() {
        deviceMonitor.onCamerasChanged = { [weak self] list in
            guard let self else { return }
            self.cameras = list
            self.handleSelectedDeviceRemoval(cameraList: list, micList: nil)
            // Arrival is a reconciliation trigger too: a capture whose retry
            // ladder exhausted while the device was absent restarts here.
            self.reconcileCaptures()
        }
        deviceMonitor.onMicrophonesChanged = { [weak self] list in
            guard let self else { return }
            self.microphones = list
            self.handleSelectedDeviceRemoval(cameraList: nil, micList: list)
            self.reconcileCaptures()
        }
        deviceMonitor.onWake = { [weak self] in
            guard let self else { return }
            // §7: both capture paths reestablish after wake; each class
            // runs the 0.5/1/2/4s retry ladder internally. Only while
            // something is consuming frames — a wake with the popover closed
            // and no clients must not turn the camera on.
            guard self.captureDemand else { return }
            self.cameraCapture.restart()
            self.audioCapture.restart()
        }
    }

    private func wireSink() {
        cmioSink.onClientsChanged = { [weak self] names in
            guard let self else { return }
            self.clientsInUse = names
            self.updateMenuBarState()
            self.reconcileCaptures()       // a first client starts capture
        }
    }

    private func wireHotkeys() {
        hotkeys.onFreeze = { [weak self] in self?.toggleFreeze() }
        hotkeys.onMute = { [weak self] in self?.toggleMute() }
        hotkeys.onFreezeAndMute = { [weak self] in self?.freezeAndMute() }
        hotkeys.onPreset = { [weak self] id in self?.selectPreset(id) }
        pushPresetHotkeyBindings(presetStore.presets)
    }

    private func pushPresetHotkeyBindings(_ list: [Preset]) {
        hotkeys.setPresetBindings(list.compactMap { preset in
            preset.hotkey.map { (preset.id, $0) }
        })
    }

    private func wireSetupObservers() {
        permissions.$camera
            .combineLatest(permissions.$microphone)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] camera, microphone in
                self?.setup.camera = camera
                self?.setup.microphone = microphone
            }
            .store(in: &cancellables)
        extensionInstaller.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.setup.cameraExtension = status
                if case .needsApproval = status {
                    self.warning = WarningMessage(
                        text: "Approve PRISM Camera in System Settings to continue")
                }
                // §9 grant #2, driven automatically: when the status poll says
                // the extension simply isn't installed, submit the activation
                // request without waiting for a banner click. macOS still owns
                // the approval; the banner's button remains as the retry path.
                // Once per launch — a denied/failed request must not loop.
                if case .notInstalled = status, !self.autoRequestedExtension {
                    self.autoRequestedExtension = true
                    self.extensionInstaller.install()
                }
                self.updateMenuBarState()
            }
            .store(in: &cancellables)
    }

    // MARK: - Timers

    private func startPolling() {
        // 1Hz: sink handoff, audio latency, plug-in presence, deferred
        // format publication, sink drop accounting, placeholder ticking.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // The no-camera tick timer is owned by reconcileCaptures(): it runs
        // only while capture demand exists, so an idle PRISM ticks nothing.
    }

    private func pollTick() {
        if let handoff = cmioSink.readHandoffMs() {
            monitor.recordHandoffMs(handoff)
        }
        monitor.setAudioAddedMs(audioCapture.addedLatencyMs)

        let dropped = cmioSink.droppedFrames
        if dropped > lastSinkDroppedFrames {
            for _ in 0..<(dropped - lastSinkDroppedFrames) {
                monitor.noteDroppedFrame()
            }
            lastSinkDroppedFrames = dropped
        }

        // §3.2: the published set reaches the extension via 'pfmt'; the
        // extension may not be connectable at launch, so publish once the
        // sink is up. `formatsPublishedToExtension` doubles as a dirty flag:
        // a publish that failed to reach the extension leaves it false and is
        // retried here on the next tick the sink is connected.
        if !formatsPublishedToExtension, cmioSink.isConnected {
            formatsPublishedToExtension =
                formatManager.publish(formatManager.publishedFormats, via: cmioSink)
        }

        // §3.2 "ordinary client negotiation": when a client negotiates a
        // different published format on the source stream, retarget the
        // pipeline (and physical capture pick) to it. Only *changes* are
        // applied, so a stale extension value never overrides the user.
        if let negotiated = cmioSink.readActiveFormat(),
           negotiated != lastNegotiatedFormat {
            lastNegotiatedFormat = negotiated
            if publishedFormats.contains(negotiated),
               negotiated != formatManager.activeFormat {
                setActiveFormat(negotiated)
            }
        }

        if setup.audioPlugInInstalled != AudioSink.isPlugInInstalled {
            setup.audioPlugInInstalled = AudioSink.isPlugInInstalled
        }

        // Belt: CMIOSink's teardown publishes an empty client list, but if
        // that message is ever lost, a stale clientsInUse would hold
        // captureDemand true — camera on for nobody — indefinitely. 1 Hz
        // reconciliation against the connection state caps that at a second.
        if !cmioSink.isConnected, !clientsInUse.isEmpty {
            clientsInUse = []
            updateMenuBarState()
            reconcileCaptures()
        }
    }

    /// Drives the pipeline when the camera is not delivering (clip playback
    /// or freeze with no camera): §5.3/§5.2 must keep producing frames.
    private func restartNoCameraTimer() {
        noCameraTimer?.invalidate()
        let interval = 1.0 / Double(formatManager.activeFormat.frameRate)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lastFrameLock.lock()
            let sinceCamera = Date().timeIntervalSince(self.lastCameraFrameAt)
            self.lastFrameLock.unlock()
            guard sinceCamera > interval * 2.5 else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let substituting = self.clipState != .none || self.isFrozen
                guard substituting else { return }   // otherwise the extension's placeholder is correct
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                self.pipeline?.tickWithoutCamera(at: now)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        noCameraTimer = timer
    }

    private func restartAutoFrameTimerIfNeeded() {
        autoFrameTimer?.invalidate()
        autoFrameTimer = nil
        guard config.geometry.autoFrame, let pipeline else {
            autoFramer.reset()
            self.pipeline?.geometryStage.autoFrameOffset = (1, 0, 0)
            self.draftRendererBox.get()?.setAutoFrameOffset((1, 0, 0))
            return
        }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak pipeline] _ in
            guard let self, let pipeline else { return }
            let box = pipeline.blurStage.latestSubjectBox
            let offset = self.autoFramer.update(subjectBox: box, dt: 1.0 / 30.0)
            pipeline.geometryStage.autoFrameOffset = offset
            // The draft previews the same auto-framing motion (it runs no
            // segmentation of its own — see DraftRenderer).
            self.draftRendererBox.get()?.setAutoFrameOffset(offset)
        }
        RunLoop.main.add(timer, forMode: .common)
        autoFrameTimer = timer
        _ = pipeline // silence unused in release
    }

    // MARK: - Capture control

    private var selectedCameraID: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKey.camera) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.camera) }
    }

    private var selectedMicrophoneID: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKey.microphone) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.microphone) }
    }

    // MARK: - Demand-driven capture

    /// The camera and microphone are live only while something consumes
    /// their frames: the popover's or main window's preview, or a client app
    /// streaming from the extension. Otherwise both stay off — a resident
    /// agent must not hold the camera (and the OS camera indicator) around
    /// the clock.
    private var captureDemand: Bool {
        previewActive || !clientsInUse.isEmpty
    }

    /// Shared didSet body for `popoverOpen` and `mainWindowOpen`: the preview
    /// path runs while either surface shows it, and tears down fully (§8.3:
    /// zero retained textures) only when both are closed.
    private func previewConsumersChanged() {
        pipeline?.previewEnabled = previewActive
        // setEnabled (not store(nil)) so a completion-thread store racing
        // this teardown is dropped rather than retained (§8.3).
        previewBox.setEnabled(previewActive)
        if previewActive {
            refreshSetupStatus()
        }
        // The draft renderer costs GPU per frame, so it exists only while
        // some surface can show it. The draft itself survives both surfaces
        // closing — the next open re-arms the renderer with the pending
        // config.
        if previewActive {
            if let draft = draftConfig {
                ensureDraftRenderer()?.apply(draft)
            }
        } else {
            teardownDraftRenderer()
        }
        reconcileCaptures()
    }

    /// Single reconciliation point between `captureDemand` and the capture
    /// hardware. Call whenever an input to the demand expression changes.
    /// Idempotent; start/stop on an already-started/stopped capture no-ops.
    private func reconcileCaptures() {
        guard started else { return }
        if captureDemand {
            if !cameraCapture.isRunning, permissions.camera == .granted {
                startCamera()
            }
            if !audioCapture.isCapturing, permissions.microphone == .granted {
                startAudio()
            }
            clipPlayer?.setDemandActive(true)
            restartNoCameraTimer()
        } else {
            cameraCapture.stop()
            audioCapture.stop()
            // Suspend the clip clock too: otherwise an idle PRISM keeps
            // decoding, and the next demand fast-forwards through the gap.
            clipPlayer?.setDemandActive(false)
            // No consumers → nothing to tick placeholder frames for.
            noCameraTimer?.invalidate()
            noCameraTimer = nil
        }
    }

    private func startCamera() {
        cameraCapture.start(deviceID: selectedCameraID,
                            outputFormat: formatManager.activeFormat)
    }

    private func startAudio() {
        audioCapture.start(deviceUID: selectedMicrophoneID)
        updateAudioRouting()
    }

    /// §5.3: clip audio replaces the live mic while playing (and while
    /// paused mid-clip the mic stays live), independently overridable.
    /// Reconciliation only — the play paths engage suppression synchronously
    /// from intent BEFORE starting playback, because `clipState` mirrors the
    /// player's published state one main-queue hop late (§4.3 SPSC).
    private func updateAudioRouting() {
        let clipOwnsAudio = (clipState == .playing) && clipUsesClipAudio
        audioCapture.isSuppressed = clipOwnsAudio
    }

    /// Keeps segmentation alive for auto-framing when blur's enable state
    /// changes outside apply() (degradation engine): mask-only mode costs no
    /// GPU blur passes but keeps latestSubjectBox fresh (§5.4).
    private func reconcileBlurMaskRouting() {
        guard let pipeline else { return }
        pipeline.blurStage.maskOnlyMode =
            config.geometry.autoFrame && !pipeline.blurStage.isEnabled
    }

    private func handleSelectedDeviceRemoval(cameraList: [CameraDeviceInfo]?,
                                             micList: [AudioDeviceInfo]?) {
        if let cameraList {
            if let selected = selectedCameraID,
               !cameraList.contains(where: { $0.id == selected }) {
                let name = cameraCapture.currentDeviceName ?? "Camera"
                selectedCameraID = nil
                if cameraCapture.isRunning {
                    startCamera()          // fall over to the built-in now
                }
                let text = "\(name) disconnected. Using built-in camera."
                warning = WarningMessage(text: text)
                postNotification(body: text)
            } else if captureDemand, cameraCapture.isRunning,
                      let bound = cameraCapture.currentDeviceID,
                      !cameraList.contains(where: { $0.id == bound }) {
                // The *default-resolved* device (nil selection) was unplugged.
                // The session is a zombie: no frames, isRunning still true, so
                // plain reconciliation would never touch it. Restart re-resolves
                // to the new default; the retry ladder covers replug.
                cameraCapture.restart()
            }
        }
        if let micList {
            if let selected = selectedMicrophoneID,
               !micList.contains(where: { $0.id == selected }) {
                selectedMicrophoneID = nil
                if audioCapture.isCapturing {
                    audioCapture.restart()
                }
                let text = "Microphone disconnected. Using default microphone."
                warning = WarningMessage(text: text)
                postNotification(body: text)
            } else if captureDemand, audioCapture.isCapturing,
                      let bound = audioCapture.currentDeviceUID,
                      !micList.contains(where: { $0.id == bound }) {
                // Default mic unplugged: the HAL unit stays silently bound to
                // the dead AudioDeviceID. Same zombie shape as the camera.
                audioCapture.restart()
            }
        }
    }

    // MARK: - Intents: freeze / mute

    public func toggleFreeze() {
        guard let pipeline else { return }
        isFrozen.toggle()
        pipeline.setFrozen(isFrozen)
        // §5.3: freezing during clip playback pauses the clip on its frame.
        if clipState != .none {
            clipPlayer?.holdCurrentFrame(isFrozen)
        }
        updateMenuBarState()
    }

    public func toggleMute() {
        isMuted.toggle()
        audioCapture.isMuted = isMuted
        updateMenuBarState()
    }

    public func freezeAndMute() {
        // ⌥⌘⇧F freezes and mutes together (§5.2); acts as a paired toggle.
        let engage = !(isFrozen && isMuted)
        if isFrozen != engage { toggleFreeze() }
        if isMuted != engage { toggleMute() }
    }

    // MARK: - Intents: clip

    public func loadClip(url: URL) {
        guard let clipPlayer else { return }
        do {
            try clipPlayer.load(url: url)
            clipPlayer.loops = clipLoops
            clipPlayer.useClipAudio = clipUsesClipAudio
            // Engage mic suppression from intent, BEFORE playback starts:
            // clipState mirrors the player's published state a main-queue hop
            // late, so updateAudioRouting() alone would leave a window with
            // two ring producers (§4.3 SPSC). The clip pump additionally
            // waits for the RT callback's acknowledgment.
            audioCapture.isSuppressed = clipUsesClipAudio
            clipPlayer.play()
            updateAudioRouting()
        } catch {
            warning = WarningMessage(
                text: "Couldn't open that clip. PRISM plays H.264, HEVC, and ProRes in MP4 or MOV.")
        }
        updateMenuBarState()
    }

    public func toggleClipPlayback() {
        switch clipState {
        case .none:
            break
        case .playing:
            clipPlayer?.pause()
            // Suppression stays engaged until the .paused state publishes
            // (updateAudioRouting reconciles) — the safe direction: the mic
            // resumes only after the clip pump has stopped writing.
        case .paused:
            // Same intent-first ordering as loadClip (§4.3 SPSC).
            audioCapture.isSuppressed = clipUsesClipAudio
            clipPlayer?.play()
        }
    }

    public func stopClip() {
        // §5.2: stopping a clip while frozen must not silently resume live
        // output — the freeze frame is re-armed from the current output
        // before the clip (whose held frame was doing the freezing) unloads.
        if isFrozen {
            pipeline?.refreezeFromCurrentOutput()
        }
        pipeline?.beginCrossfade(durationMs: 200)
        clipPlayer?.stop()
        updateAudioRouting()
        updateMenuBarState()
    }

    public func scrubClip(to seconds: Double) {
        clipPlayer?.seek(toSeconds: seconds)
    }

    // MARK: - Intents: stages / config

    private func stage(_ id: StageID) -> EffectStage? {
        pipeline?.stages.first { $0.id == id }
    }

    public func setStageEnabled(_ id: StageID, _ enabled: Bool) {
        updateEditing { cfg in
            var flags = cfg.flags(for: id)
            flags.enabled = enabled
            cfg.flags[id] = flags
        }
        // Clearing a manual LIVE toggle also clears any auto-disable latch;
        // a drafted toggle leaves the live chain (and its latch) alone —
        // applyDraft clears latches for the stages it actually changes.
        if draftConfig == nil {
            var status = stageStatus[id] ?? StageStatus()
            status.autoDisabled = false
            stageStatus[id] = status
        }
    }

    public func setStagePinned(_ id: StageID, _ pinned: Bool) {
        updateEditing { cfg in
            var flags = cfg.flags(for: id)
            flags.pinned = pinned
            cfg.flags[id] = flags
        }
    }

    public func updateConfig(_ mutate: (inout PipelineConfiguration) -> Void) {
        var next = config
        mutate(&next)
        let policyChanged = next.latencyPolicy != config.latencyPolicy
        let autoFrameChanged = next.geometry.autoFrame != config.geometry.autoFrame
        config = next
        pipeline?.apply(next)
        if policyChanged {
            monitor.setPolicy(next.latencyPolicy,
                              frameIntervalMs: formatManager.activeFormat.frameIntervalMs)
        }
        if autoFrameChanged {
            restartAutoFrameTimerIfNeeded()
        }
        persistConfig()
        updateMenuBarState()
    }

    // MARK: - Intents: draft editing

    /// What every editing surface reads: the draft when one is pending, the
    /// live configuration otherwise. Rendering all surfaces from this one
    /// value is what keeps them in real-time agreement.
    public var editingConfig: PipelineConfiguration {
        draftConfig ?? config
    }

    /// Single write path for visual-configuration edits from any surface:
    /// staged into the pending draft when one exists, applied live (and
    /// mirrored everywhere instantly) otherwise.
    public func updateEditing(_ mutate: (inout PipelineConfiguration) -> Void) {
        if draftConfig != nil {
            updateDraft(mutate)
        } else {
            updateConfig(mutate)
        }
    }

    /// Turns on preview-before-apply: edits from every surface stage into
    /// the draft until applyDraft() or discardDraft().
    public func beginDraft() {
        guard draftConfig == nil else { return }
        draftConfig = config
        ensureDraftRenderer()?.apply(config)
    }

    /// Stages an edit. The first call seeds the draft from the live config;
    /// nothing reaches the live pipeline until applyDraft().
    public func updateDraft(_ mutate: (inout PipelineConfiguration) -> Void) {
        var next = draftConfig ?? config
        mutate(&next)
        draftConfig = next
        ensureDraftRenderer()?.apply(next)
    }

    /// Pushes the draft's visual configuration to the live pipeline. Format,
    /// latency policy, and device picks are carried over from live — no
    /// draft surface edits them, and apply must never trigger a format
    /// renegotiation (§3.2) as a side effect.
    public func applyDraft() {
        guard var draft = draftConfig else { return }
        let previous = config
        draft.format = previous.format
        draft.latencyPolicy = previous.latencyPolicy
        draft.cameraID = previous.cameraID
        draft.microphoneID = previous.microphoneID
        pipeline?.beginCrossfade(durationMs: 200)   // preset-style switch (§5.5)
        updateConfig { $0 = draft }
        // pipeline.apply just reset every stage's isEnabled from the applied
        // flags, superseding any degradation decision — clear ALL latches to
        // match (an off-and-back-on staged toggle ends flag-equal, so a
        // changed-flags check would miss it). The monitor re-disables and
        // re-latches whatever is still over budget.
        for id in StageID.allCases {
            var status = stageStatus[id] ?? StageStatus()
            status.autoDisabled = false
            stageStatus[id] = status
        }
        discardDraft()
    }

    public func discardDraft() {
        draftConfig = nil
        teardownDraftRenderer()
    }

    @discardableResult
    private func ensureDraftRenderer() -> DraftRenderer? {
        if let existing = draftRendererBox.get() { return existing }
        // Any preview surface (popover or main window) can show the draft.
        guard previewActive, let metal,
              let renderer = try? DraftRenderer(metal: metal,
                                                outputFormat: formatManager.activeFormat)
        else { return nil }
        renderer.onOutput = { [draftPreviewBox] texture in
            draftPreviewBox.store(texture)
        }
        renderer.setAutoFrameOffset(
            pipeline?.geometryStage.autoFrameOffset ?? (1, 0, 0))
        draftPreviewBox.setEnabled(true)
        // Seed with the latest live frame so the preview never flashes black
        // while the first draft frame renders (draft == live at begin).
        draftPreviewBox.store(previewBox.take())
        draftRendererBox.set(renderer)
        return renderer
    }

    private func teardownDraftRenderer() {
        draftRendererBox.set(nil)
        // Disable (not just clear): a completed draft frame landing after
        // this teardown must be dropped, not retained.
        draftPreviewBox.setEnabled(false)
    }

    // MARK: - Intents: format (§3.2)

    public func setActiveFormat(_ format: VideoFormat) {
        guard publishedFormats.contains(format) else {
            // Outside the published set → reconnect boundary for the set.
            requestPublishedFormatsChange(publishedFormats + [format])
            return
        }
        formatManager.activeFormat = format
        config.format = format
        pipeline?.configure(outputFormat: format)
        draftRendererBox.get()?.configure(outputFormat: format)
        monitor.setPolicy(config.latencyPolicy, frameIntervalMs: format.frameIntervalMs)
        // Gate on demand, not on the isRunning snapshot: mid-spin-up the
        // snapshot is transitional, and start() supersedes any in-flight
        // build via its generation bump, so this is safe to call during one.
        if captureDemand, permissions.camera == .granted {
            startCamera()                 // re-pick the physical format (§3.2)
            restartNoCameraTimer()        // tick interval tracks the frame rate
        }
        // While idle the camera stays off; the next demand-driven start
        // reads formatManager.activeFormat and picks the format up then.
        formatManager.persist()
        persistConfig()
    }

    public func requestPublishedFormatsChange(_ formats: [VideoFormat]) {
        let sorted = formats.sorted()
        guard sorted != publishedFormats else { return }

        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            // A write that misses the extension (not yet approved/connected)
            // leaves the dirty flag false; pollTick re-pushes on connect.
            self.formatsPublishedToExtension =
                self.formatManager.publish(sorted, via: self.cmioSink)
            self.publishedFormats = sorted
            self.formatManager.persist()
            if !self.clientsInUse.isEmpty {
                let first = self.clientsInUse.first ?? "your video app"
                self.postNotification(
                    body: "Reselect PRISM Camera in \(first) to use the new format")
            }
            // The active format must stay inside the published set.
            if !sorted.contains(self.formatManager.activeFormat),
               let fallback = sorted.first {
                self.setActiveFormat(fallback)
            }
        }

        if clientsInUse.isEmpty {
            apply()                        // free while nobody is streaming
            return
        }

        // §3.2: never republish silently while clients stream.
        let names = clientsInUse.joined(separator: " and ")
        let alert = NSAlert()
        alert.messageText = "\(names) will need to reselect PRISM Camera. Change anyway?"
        alert.informativeText = "Changing the published formats disconnects apps that are using PRISM Camera."
        alert.addButton(withTitle: "Change")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            apply()
        }
    }

    public func setLatencyPolicy(_ policy: LatencyPolicy) {
        updateConfig { $0.latencyPolicy = policy }
    }

    public func raiseBudgetOneStep() {
        switch config.latencyPolicy {
        case .lowest: setLatencyPolicy(.balanced)
        case .balanced: setLatencyPolicy(.quality)
        case .quality: break
        }
        if warning?.action == .raiseBudget {
            warning = nil
        }
    }

    // MARK: - Intents: devices

    public func selectCamera(_ id: String?) {
        selectedCameraID = id
        // Demand-gated (not isRunning-gated): a pick made mid-spin-up must
        // supersede the in-flight build, and a pick made while idle defers to
        // the next demand-driven start (which reads selectedCameraID).
        if captureDemand, permissions.camera == .granted {
            startCamera()                  // reconfigure onto the new device
        }
        config.cameraID = id
        persistConfig()
    }

    public func selectMicrophone(_ id: String?) {
        selectedMicrophoneID = id
        if captureDemand, permissions.microphone == .granted {
            startAudio()                   // start() supersedes internally
        }
        config.microphoneID = id
        persistConfig()
    }

    // MARK: - Intents: presets (§5.5)

    public func selectPreset(_ id: UUID) {
        guard let preset = presetStore.presets.first(where: { $0.id == id }) else { return }
        activePresetID = id
        // A preset is an explicit "switch the whole look" — a stale draft
        // must not sit above it waiting to clobber it on apply.
        discardDraft()

        var incoming = preset.configuration
        let wantedFormat = incoming.format
        let formatAvailable = publishedFormats.contains(wantedFormat)

        // §5.5: switching presets never causes a renegotiation. Apply
        // everything except an out-of-set format; offer that separately.
        if !formatAvailable {
            incoming.format = formatManager.activeFormat
        }

        pipeline?.beginCrossfade(durationMs: 200)
        let keepCamera = config.cameraID
        let keepMic = config.microphoneID
        updateConfig { cfg in
            cfg = incoming
            // Device selections only move when the preset pins them.
            if incoming.cameraID == nil { cfg.cameraID = keepCamera }
            if incoming.microphoneID == nil { cfg.microphoneID = keepMic }
        }
        if let cameraID = incoming.cameraID { selectCamera(cameraID) }
        if let micID = incoming.microphoneID { selectMicrophone(micID) }

        if formatAvailable, wantedFormat != formatManager.activeFormat {
            setActiveFormat(wantedFormat)   // in-set switch, no reconnect
        } else if !formatAvailable {
            requestPublishedFormatsChange(publishedFormats + [wantedFormat])
            // §5.5: on confirm (runModal is synchronous) the preset's format
            // is now in the published set — make it active. On cancel the
            // set is unchanged and the current active format stands.
            if publishedFormats.contains(wantedFormat) {
                setActiveFormat(wantedFormat)
            }
        }
    }

    public func saveCurrentAsPreset(named name: String) {
        // Mid-draft, "current" is the look the user is previewing — saving
        // the live config would silently omit every staged edit.
        var cfg = editingConfig
        cfg.format = formatManager.activeFormat
        let preset = Preset(name: name, configuration: cfg)
        presetStore.add(preset)
        activePresetID = preset.id
    }

    // MARK: - Intents: misc

    public func importLUT(from url: URL) {
        do {
            let name = try LUTStore.shared.importLUT(from: url)
            // Mid-draft, an import stages like any other edit — otherwise it
            // would flash the new LUT to clients and be reverted on apply.
            updateEditing { cfg in
                cfg.lut.lutName = name
                var flags = cfg.flags(for: .lut)
                flags.enabled = true
                cfg.flags[.lut] = flags
            }
        } catch {
            warning = WarningMessage(text: "Couldn't read that LUT. PRISM imports .cube files.")
        }
    }

    public func toggleSection(_ section: PopoverSection) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
        }
    }

    // MARK: - Intents: menu bar dropdown layout

    public var visiblePopoverModules: [PopoverModule] {
        popoverLayout.filter(\.visible).map(\.module)
    }

    public func setPopoverModule(_ module: PopoverModule, visible: Bool) {
        guard let index = popoverLayout.firstIndex(where: { $0.module == module })
        else { return }
        popoverLayout[index].visible = visible
    }

    /// SwiftUI `onMove` semantics, same as PresetStore.move.
    public func movePopoverModules(fromOffsets: IndexSet, toOffset: Int) {
        popoverLayout.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    public func resetPopoverLayout() {
        popoverLayout = PopoverModuleItem.defaultLayout
    }

    // MARK: - Intents: main window

    /// Opens (or raises) the main PRISM window. The handler is installed by
    /// the app delegate, which owns the window controller.
    public func showMainWindow() {
        openMainWindowHandler?()
    }

    public func quit() {
        audioCapture.stop()
        clipPlayer?.stop()
        cameraCapture.stop()
        cmioSink.disconnect()
        audioSink?.close()      // marks producerAlive = 0 → plug-in emits silence
        NSApp.terminate(nil)
    }

    // MARK: - Derived state

    private func updateMenuBarState() {
        // §8.2 precedence: error > frozen > muted > effects > live > idle.
        let newState: MenuBarState
        if case .failed = setup.cameraExtension {
            newState = .error
        } else if isFrozen {
            newState = .frozen
        } else if isMuted {
            newState = .muted
        } else if hasActiveEffects {
            newState = .effects
        } else if !clientsInUse.isEmpty {
            newState = .live
        } else {
            newState = .idle
        }
        if newState != menuBarState {
            menuBarState = newState
        }
    }

    private var hasActiveEffects: Bool {
        if clipState != .none { return true }
        for id: StageID in [.adjust, .lut, .blur] where config.flags(for: id).enabled {
            if !(stageStatus[id]?.autoDisabled ?? false) { return true }
        }
        if config.flags(for: .geometry).enabled && !config.geometry.isIdentity { return true }
        return false
    }

    private func refreshSetupStatus() {
        permissions.refresh()
        extensionInstaller.checkStatus()
        setup.audioPlugInInstalled = AudioSink.isPlugInInstalled
    }

    private func refreshDeviceLists() {
        cameras = DeviceMonitor.cameras()
        microphones = DeviceMonitor.microphones()
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.configuration),
           let decoded = try? JSONDecoder().decode(PipelineConfiguration.self, from: data) {
            config = decoded
        }
        config.format = formatManager.activeFormat
        publishedFormats = formatManager.publishedFormats
        if let raw = UserDefaults.standard.array(forKey: DefaultsKey.sections) as? [String] {
            expandedSections = Set(raw.compactMap(PopoverSection.init(rawValue:)))
        }
        // An entry with an unknown module (downgrade) fails decoding as a
        // whole; falling back to the default layout is the right recovery.
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.popoverLayout),
           let decoded = try? JSONDecoder().decode([PopoverModuleItem].self, from: data) {
            popoverLayout = PopoverModuleItem.sanitized(decoded)
        }
        // §8.3 default: Framing, Effects, Format collapsed on first launch —
        // an empty set is exactly that, so no seeding is needed.
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.configuration)
        }
    }

    private func persistExpandedSections() {
        UserDefaults.standard.set(expandedSections.map(\.rawValue),
                                  forKey: DefaultsKey.sections)
    }

    private func persistPopoverLayout() {
        if let data = try? JSONEncoder().encode(popoverLayout) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.popoverLayout)
        }
    }

    private func postNotification(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "PRISM"
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
