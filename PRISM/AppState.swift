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
    /// §5.15 — informational, and deliberately not the warning slot: there
    /// is only one warning, and evicting a device-disconnect message to say
    /// "you're muted" would trade a fact for a hint.
    @Published public var notice: NoticeMessage?
    @Published public var menuBarState: MenuBarState = .idle
    @Published public var setup = SetupStatus()
    // Controls
    @Published public var isFrozen = false
    @Published public var isMuted = false
    /// §5.15 — live microphone level, 0…1, perceptually scaled by the same
    /// mapping the mic check uses so the two meters read alike. Zero unless
    /// something is watching (see inputLevelDemand).
    @Published public private(set) var inputLevel: Double = 0
    /// §5.15 — sustained speech into a microphone nobody is hearing.
    @Published public private(set) var mutedTalking = false
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
    // Studio behaviour: replay / away / panic (§5.9–§5.11). Deliberately not
    // part of `config` — a preset captures a look, not whether a hardware
    // encoder is running.
    @Published public var studio = StudioSettings() {
        didSet {
            guard studio != oldValue else { return }
            pipeline?.applyStudio(studio)
            if studio.voice != oldValue.voice {
                // §5.13: the voice changer lives on the audio capture path;
                // the menu bar treats an active voice as an active effect.
                audioCapture.voiceChanger.apply(studio.voice)
                updateMenuBarState()
            }
            if studio.cleanup != oldValue.cleanup {
                // §5.15: cleanup is a repair, not a costume — it never
                // reaches the menu bar's effect glyph.
                audioCapture.voiceCleanup.apply(studio.cleanup)
            }
            if studio.micWatch != oldValue.micWatch {
                refreshMutedTalkingNotice()
            }
            // §5.12: dragging the delay while engaged retargets it live —
            // whichever knob owns the current delay. During a catch-up the
            // rate is the control, so the slider waits its turn.
            if isLagging, !isCatchingUp {
                if connectionEngagedLag {
                    if studio.connection.lagMs != oldValue.connection.lagMs {
                        retargetLagDepth(seconds: studio.connection.lagSeconds,
                                         delaysAudio: true)
                    }
                } else if studio.lag.delayMs != oldValue.lag.delayMs {
                    retargetLagDepth(seconds: studio.lag.delaySeconds,
                                     delaysAudio: studio.lag.delaysAudio)
                }
            }
            persistStudio()
        }
    }
    /// Mirrors ReplayPlayer, republished at 4 Hz for the transport UI.
    @Published public var replayMode: ReplayMode = .idle
    @Published public var replayPosition: Double = 0
    @Published public var replayDuration: Double = 0
    /// Seconds currently held in the rolling buffer — what "rewind" can reach.
    @Published public var bufferedSeconds: Double = 0
    @Published public var isAway = false
    @Published public var isPanicked = false
    /// §5.12 — the deliberate delay is engaged.
    @Published public var isLagging = false
    /// §5.14 — the fake bad connection is degrading the published picture.
    @Published public var isBadConnection = false
    /// Playing the backlog out faster than real time after a catch-up release.
    @Published public var isCatchingUp = false
    /// Eye contact has found a face and is actually correcting. A correction
    /// that silently does nothing is indistinguishable from a broken one.
    @Published public var eyeContactTracking = false

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
    /// §5.13 mic check — record a few seconds of the processed microphone
    /// and play it back, the only way to hear your own voice effect.
    public let micCheck: MicCheck

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
    /// §5.15 — 10 Hz while the input meter has an audience. The RT side is
    /// armed and disarmed with it, so a PRISM nobody is looking at measures
    /// nothing.
    private var levelTimer: Timer?
    private let micWatch = MicWatch()
    /// Last window counter seen from the level mailbox; an unchanged counter
    /// means no audio arrived and the meter decays instead of freezing.
    private var lastInputLevelSequence: UInt32 = 0
    private var autoFrameTimer: Timer?
    private var noCameraTimer: Timer?
    private var replayTimer: Timer?
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

    /// Configuration snapshot taken when panic engaged, restored on release.
    /// Panic mutates `config` so every surface shows what is actually on air,
    /// but it must never outlive the panic: this is what gets persisted and
    /// what a preset save captures while the chord is held.
    private var panicRestore: PipelineConfiguration?
    /// Whether panic (or away) engaged mute itself, so releasing restores the
    /// user's own mute rather than blanket-unmuting.
    private var panicMutedByUs = false
    private var awayMutedByUs = false
    /// Whether the bad connection engaged the §5.12 delay itself (§5.14), so
    /// releasing it releases only the delay it engaged — never one the user
    /// asked for separately with the lag switch.
    private var connectionEngagedLag = false

    private enum DefaultsKey {
        static let configuration = "PRISM.configuration"
        static let camera = "PRISM.selectedCamera"
        static let microphone = "PRISM.selectedMicrophone"
        static let sections = "PRISM.expandedSections"
        static let popoverLayout = "PRISM.popoverLayout"
        static let studio = "PRISM.studio"
    }

    // MARK: - Init

    public init() {
        micCheck = MicCheck(capture: audioCapture)
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
        wireReplayPlayer()
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
        pipeline?.applyStudio(studio)
        // The studio didSet only fires on a *change*; a launch with no
        // persisted file (or a file identical to the defaults) would
        // otherwise leave both microphone chains holding their init-time
        // programs rather than the ones the user can see on screen.
        audioCapture.voiceChanger.apply(studio.voice)
        audioCapture.voiceCleanup.apply(studio.cleanup)
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
        deviceMonitor.onVirtualMicInUseChanged = { [weak self] inUse in
            guard let self, self.virtualMicInUse != inUse else { return }
            self.virtualMicInUse = inUse
            self.reconcileCaptures()
        }
        deviceMonitor.onWake = { [weak self] in
            guard let self else { return }
            // §7: both capture paths reestablish after wake; each class
            // runs the 0.5/1/2/4s retry ladder internally. Only while
            // something is consuming frames — a wake with the popover closed
            // and no clients must not turn the camera on.
            guard self.audioCaptureDemand else { return }
            if self.captureDemand {
                self.cameraCapture.restart()
            }
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
        hotkeys.onReplay = { [weak self] in self?.toggleReplay() }
        hotkeys.onAway = { [weak self] in self?.toggleAway() }
        hotkeys.onPanic = { [weak self] in self?.togglePanic() }
        hotkeys.onEyeContact = { [weak self] in self?.toggleEyeContact() }
        hotkeys.onVoice = { [weak self] in self?.toggleVoice() }
        hotkeys.onLag = { [weak self] pressed in self?.handleLagKey(pressed: pressed) }
        hotkeys.onBadConnection = { [weak self] in self?.toggleBadConnection() }
        hotkeys.onPreset = { [weak self] id in self?.selectPreset(id) }
        pushPresetHotkeyBindings(presetStore.presets)
    }

    private func wireReplayPlayer() {
        guard let pipeline else { return }
        pipeline.replayPlayer.onReplayFinished = { [weak self] in
            guard let self else { return }
            // Two things reach the live edge: a replay running out, and a lag
            // catch-up consuming its backlog. The away loop never does.
            if self.isCatchingUp {
                self.finishCatchUp()
                return
            }
            guard self.replayMode == .replay else { return }
            if self.studio.replay.returnToLiveAtEnd {
                self.stopReplay()
            } else {
                self.refreshReplayState()
            }
        }
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

        // §5.15: suppression is acknowledged on the RT thread, so the mic can
        // go off air without any intent firing. 1 Hz reconciliation caps how
        // long the watch can be looking the wrong way.
        reconcileInputLevel()

        if let pipeline {
            let buffered = pipeline.replayBuffer.bufferedSeconds
            if abs(bufferedSeconds - buffered) > 0.1 { bufferedSeconds = buffered }
            let tracking = pipeline.gazeStage.isTracking
                && config.flags(for: .gaze).enabled
            if eyeContactTracking != tracking { eyeContactTracking = tracking }
        }
    }

    /// §5.15: the input meter runs only while it has an audience — a preview
    /// surface showing the bar, or the muted-and-talking watch, which can
    /// only fire while the microphone is already off air. With PRISM idle in
    /// the menu bar, unmuted, nothing here computes anything: no RT
    /// accumulation, no timer, no publishes.
    private var inputLevelDemand: Bool {
        guard started, audioCapture.isCapturing else { return false }
        return previewActive || micIsOffAir
    }

    /// The microphone is not reaching the call. Mute is the obvious case;
    /// clip audio owning the ring (§5.3) is the same thing from the talker's
    /// point of view, and is the case people actually get caught by, because
    /// nothing about playing a clip looks like a mute.
    private var micIsOffAir: Bool {
        isMuted || audioCapture.suppressionEngaged
    }

    private func reconcileInputLevel() {
        let demand = inputLevelDemand
        audioCapture.setInputLevelArmed(demand)
        guard demand != (levelTimer != nil) else { return }
        levelTimer?.invalidate()
        levelTimer = nil
        guard demand else {
            // Nothing is measuring, so nothing may be claimed: drop the
            // meter and the watch rather than leave either asserting a
            // reading that stopped arriving.
            if inputLevel != 0 { inputLevel = 0 }
            micWatch.reset(keepingHistory: true)
            if mutedTalking { mutedTalking = false }
            refreshMutedTalkingNotice()
            return
        }
        lastInputLevelSequence = audioCapture.inputLevelReading.sequence
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.inputLevelTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func inputLevelTick() {
        let reading = audioCapture.inputLevelReading
        let fresh = reading.sequence != lastInputLevelSequence
        lastInputLevelSequence = reading.sequence
        // A window that never arrived is not silence — it is the absence of
        // evidence — so the bar decays the way the mic check's does rather
        // than snapping to zero or holding the last value forever.
        let level = fresh
            ? max(MicCheck.displayLevel(rms: reading.rms),
                  inputLevel * MicCheck.meterDecay)
            : inputLevel * MicCheck.meterDecay
        if abs(level - inputLevel) > 0.005 || (level == 0 && inputLevel != 0) {
            inputLevel = level
        }

        let talking = micWatch.update(rms: fresh ? reading.rms : 0,
                                      offAir: micIsOffAir,
                                      at: Date())
        if talking != mutedTalking {
            mutedTalking = talking
            refreshMutedTalkingNotice()
            updateMenuBarState()
        }
    }

    /// The banner is opt-in (§5.15); the menu bar signal is not. Only ever
    /// touches the notice slot it owns, so a notice posted by anything else
    /// survives.
    private func refreshMutedTalkingNotice() {
        let wanted = mutedTalking && studio.micWatch.showsBanner
        if wanted {
            if notice?.action != .unmute {
                notice = NoticeMessage(text: "You're muted — nobody can hear you.",
                                       action: .unmute)
            }
        } else if notice?.action == .unmute {
            notice = nil
        }
    }

    /// 4 Hz while a replay or away loop is on air, so the transport row
    /// tracks without a timer running for a feature nobody is using.
    private func restartReplayTimerIfNeeded() {
        replayTimer?.invalidate()
        replayTimer = nil
        guard replayMode != .idle else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshReplayState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        replayTimer = timer
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
                // Anything substituting for the camera has to keep producing
                // frames when the camera itself is not delivering — an away
                // loop must survive the camera dropping out, since that is
                // precisely when nobody is there to notice.
                let substituting = self.clipState != .none || self.isFrozen
                    || self.replayMode != .idle
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

    /// Mirror of kAudioDevicePropertyDeviceIsRunningSomewhere on the virtual
    /// microphone, fed by DeviceMonitor. Main thread.
    private var virtualMicInUse = false

    /// §4.4: an app recording from "PRISM Microphone" is microphone demand
    /// all by itself — the popover can be closed and no video client
    /// attached, and the ring must still carry live audio (before this, the
    /// virtual mic went silent exactly when someone listened to it). It
    /// widens audio demand only: an audio-only client must not turn the
    /// camera on.
    private var audioCaptureDemand: Bool {
        captureDemand || virtualMicInUse
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
            clipPlayer?.setDemandActive(true)
            // Background and overlay videos are media clocks too (§5.7, §5.8).
            pipeline?.setDemandActive(true)
            restartNoCameraTimer()
        } else {
            // §5.13: no preview surface means nobody is looking at the mic
            // check — and the capture that feeds it may be about to stop. End
            // a recording or playback rather than strand either invisibly.
            if micCheck.phase != .idle {
                micCheck.cancel()
            }
            cameraCapture.stop()
            // Suspend the clip clock too: otherwise an idle PRISM keeps
            // decoding, and the next demand fast-forwards through the gap.
            clipPlayer?.setDemandActive(false)
            pipeline?.setDemandActive(false)
            // No consumers → nothing to tick placeholder frames for.
            noCameraTimer?.invalidate()
            noCameraTimer = nil
        }
        // Audio demand is wider than video demand: an app recording from the
        // virtual microphone keeps capture alive with every window closed.
        if audioCaptureDemand {
            if !audioCapture.isCapturing, permissions.microphone == .granted {
                startAudio()
            }
        } else {
            audioCapture.stop()
        }
        reconcileInputLevel()
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
        // §5.13: while clip audio owns the ring the mic-check tap starves;
        // an in-flight recording can only stall, so end it cleanly.
        if clipOwnsAudio, micCheck.phase == .recording {
            micCheck.cancel()
        }
        reconcileInputLevel()
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
            } else if audioCaptureDemand, audioCapture.isCapturing,
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
        // §5.13: muting silences the mic-check tap too, so an in-flight
        // recording can only ever produce silence — cancel it rather than
        // let it stall and then misdiagnose the microphone.
        if isMuted, micCheck.phase == .recording {
            micCheck.cancel()
        }
        // §5.15: unmuting resolves the watch immediately rather than waiting
        // for the next tick to notice — the badge must not outlive the mute.
        if !isMuted, mutedTalking {
            micWatch.reset(keepingHistory: true)
            mutedTalking = false
            refreshMutedTalkingNotice()
        }
        reconcileInputLevel()
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

    // MARK: - Intents: background (§5.4 blur / §5.7 replacement)

    /// The single "what is behind me" answer, derived from the two stages
    /// that can provide it.
    public var backgroundMode: BackgroundMode {
        let cfg = editingConfig
        if cfg.flags(for: .blur).enabled { return .blur }
        guard cfg.flags(for: .background).enabled else { return .off }
        switch cfg.background.kind {
        case .color: return .color
        case .image: return .image
        case .video: return .video
        }
    }

    /// Sets blur and replacement together so they can never both be on —
    /// blurring a background you have already replaced is nonsense, and two
    /// independent switches would let a user create exactly that.
    public func setBackgroundMode(_ mode: BackgroundMode) {
        updateEditing { cfg in
            var blurFlags = cfg.flags(for: .blur)
            var backgroundFlags = cfg.flags(for: .background)
            blurFlags.enabled = mode == .blur
            backgroundFlags.enabled = mode != .off && mode != .blur
            cfg.flags[.blur] = blurFlags
            cfg.flags[.background] = backgroundFlags
            switch mode {
            case .color: cfg.background.kind = .color
            case .image: cfg.background.kind = .image
            case .video: cfg.background.kind = .video
            case .off, .blur: break
            }
        }
        // A manual choice clears the degradation latch on whichever stage it
        // just turned on, exactly as setStageEnabled does.
        if draftConfig == nil {
            for id: StageID in [.blur, .background] {
                var status = stageStatus[id] ?? StageStatus()
                status.autoDisabled = false
                stageStatus[id] = status
            }
        }
    }

    public func setBackgroundAsset(_ url: URL?) {
        updateEditing { cfg in
            cfg.background.assetPath = url?.path
            if let url {
                cfg.background.kind = PanicSettings.isVideoPath(url.path) ? .video : .image
                var flags = cfg.flags(for: .background)
                flags.enabled = true
                cfg.flags[.background] = flags
                var blurFlags = cfg.flags(for: .blur)
                blurFlags.enabled = false
                cfg.flags[.blur] = blurFlags
            }
        }
    }

    // MARK: - Intents: overlay layers (§5.8)

    public func addOverlayLayer(url: URL) {
        guard editingConfig.overlay.layers.count < OverlaySettings.maxLayers else {
            warning = WarningMessage(
                text: "PRISM composites up to \(OverlaySettings.maxLayers) layers at once")
            return
        }
        let isVideo = PanicSettings.isVideoPath(url.path)
        var layer = OverlayLayer(
            name: url.deletingPathExtension().lastPathComponent,
            sourceKind: isVideo ? .video : .image,
            assetPath: url.path)
        // A video dropped onto the stage is almost always a keyed element —
        // a green-screen clip or an alpha-less effect loop — so start it on
        // chroma. A still is usually a PNG that carries its own alpha.
        layer.keyMode = isVideo ? .chroma : .none
        updateEditing { cfg in
            cfg.overlay.layers.append(layer)
            var flags = cfg.flags(for: .overlay)
            flags.enabled = true
            cfg.flags[.overlay] = flags
        }
    }

    public func updateOverlayLayer(_ id: UUID,
                                   _ mutate: (inout OverlayLayer) -> Void) {
        updateEditing { cfg in
            guard let index = cfg.overlay.layers.firstIndex(where: { $0.id == id }) else { return }
            mutate(&cfg.overlay.layers[index])
        }
    }

    public func removeOverlayLayer(_ id: UUID) {
        updateEditing { cfg in
            cfg.overlay.layers.removeAll { $0.id == id }
            if cfg.overlay.layers.isEmpty {
                var flags = cfg.flags(for: .overlay)
                flags.enabled = false
                cfg.flags[.overlay] = flags
            }
        }
    }

    public func moveOverlayLayers(fromOffsets: IndexSet, toOffset: Int) {
        updateEditing { cfg in
            cfg.overlay.layers.move(fromOffsets: fromOffsets, toOffset: toOffset)
        }
    }

    // MARK: - Intents: instant replay (§5.9)

    /// Rewinds to the start of the rolling buffer and plays forward at the
    /// configured rate. Above 1× the replay catches up to live on its own.
    public func startReplay() {
        guard let pipeline else { return }
        guard studio.replay.isArmed else {
            warning = WarningMessage(
                text: "Turn on the rolling buffer to use instant replay",
                action: .armBuffer)
            return
        }
        // Clear any other substitution BEFORE starting, and without calling
        // stop(): the player is a single transport, so stopping it after
        // startReplay has already claimed it would tear down the replay we
        // just asked for. `begin` supersedes whatever was playing on its own.
        if isAway {
            isAway = false
            if awayMutedByUs {
                awayMutedByUs = false
                if isMuted { toggleMute() }
            }
        }
        if isLagging || isCatchingUp {
            isLagging = false
            isCatchingUp = false
            connectionEngagedLag = false
            audioCapture.delaySeconds = 0
        }

        guard pipeline.replayPlayer.startReplay(
            rate: studio.replay.clampedPlaybackRate) else {
            warning = WarningMessage(text: "Nothing buffered to replay yet")
            return
        }
        pipeline.beginCrossfade(durationMs: 200)
        refreshReplayState()
        updateMenuBarState()
    }

    public func stopReplay() {
        guard let pipeline, pipeline.replayPlayer.isActive else { return }
        // §5.2: a replay ending while frozen must not resume live video under
        // a frozen UI — re-arm the freeze from what is currently on air first.
        if isFrozen {
            pipeline.refreezeFromCurrentOutput()
        }
        pipeline.replayPlayer.stop()
        pipeline.beginCrossfade(durationMs: 200)
        refreshReplayState()
        updateMenuBarState()
    }

    public func toggleReplay() {
        if replayMode == .replay {
            stopReplay()
        } else {
            startReplay()
        }
    }

    public func scrubReplay(to seconds: Double) {
        pipeline?.replayPlayer.seek(toSeconds: seconds)
        replayPosition = seconds
    }

    /// Arms the rolling buffer from a warning action or a settings toggle.
    public func setBufferArmed(_ armed: Bool) {
        studio.replay.isArmed = armed
        if armed, warning?.action == .armBuffer {
            warning = nil
        }
    }

    // MARK: - Intents: away loop (§5.10)

    public func toggleAway() {
        if isAway {
            endAway(returnToLive: true)
        } else {
            beginAway()
        }
    }

    private func beginAway() {
        guard let pipeline else { return }
        guard studio.replay.isArmed else {
            // First use with the buffer off: arm it and say so. The loop
            // cannot start yet — nothing is recorded — but the next press
            // will work, which beats a control that does nothing.
            if studio.away.armsBufferOnFirstUse {
                studio.replay.isArmed = true
                warning = WarningMessage(
                    text: "Rolling buffer on. The away loop needs a few seconds of video first.")
            } else {
                warning = WarningMessage(
                    text: "Turn on the rolling buffer to use the away loop",
                    action: .armBuffer)
            }
            return
        }
        // Stepping away supersedes a delay; same no-stop() rule as above.
        if isLagging || isCatchingUp {
            isLagging = false
            isCatchingUp = false
            connectionEngagedLag = false
            audioCapture.delaySeconds = 0
        }
        guard pipeline.replayPlayer.startAway(
            loopSeconds: studio.away.clampedLoopSeconds,
            crossfadeMs: studio.away.clampedCrossfadeMs) else {
            warning = WarningMessage(
                text: "Not enough video buffered yet for an away loop")
            return
        }
        isAway = true
        pipeline.beginCrossfade(durationMs: 300)
        if studio.away.mutesAudio, !isMuted {
            awayMutedByUs = true
            toggleMute()
        }
        refreshReplayState()
        updateMenuBarState()
    }

    private func endAway(returnToLive: Bool) {
        guard let pipeline, isAway else { return }
        isAway = false
        // Same freeze-safety rule as stopReplay.
        if isFrozen {
            pipeline.refreezeFromCurrentOutput()
        }
        pipeline.replayPlayer.stop()
        if returnToLive {
            pipeline.beginCrossfade(durationMs: 300)
        }
        if awayMutedByUs {
            awayMutedByUs = false
            if isMuted { toggleMute() }
        }
        refreshReplayState()
        updateMenuBarState()
    }

    // MARK: - Intents: lag switch (§5.12)

    /// Engages the deliberate delay. The picture holds where it is for the
    /// configured delay and then resumes that far behind live — a stall, not
    /// a rewind, which is what adding latency actually looks like.
    public func engageLag() {
        guard let pipeline, !isLagging else { return }
        guard studio.replay.isArmed else {
            warning = WarningMessage(
                text: "Turn on the rolling buffer to use the lag switch",
                action: .armBuffer)
            return
        }
        guard replayMode != .replay else {
            warning = WarningMessage(text: "Stop the replay before adding delay")
            return
        }
        // Away and lag are both "what is on air is not live"; the newer
        // intent wins. Cleared without stop() for the same reason startReplay
        // does — `begin` supersedes the transport by itself.
        if isAway {
            isAway = false
            if awayMutedByUs {
                awayMutedByUs = false
                if isMuted { toggleMute() }
            }
        }
        let requested = studio.lag.delaySeconds
        // The delay is held in the rolling buffer, so it cannot exceed it.
        let available = min(requested, studio.replay.clampedBufferSeconds - 0.5)
        guard available > 0.1, pipeline.replayPlayer.startLag(delaySeconds: available) else {
            warning = WarningMessage(text: "Nothing buffered to delay yet")
            return
        }
        isLagging = true
        if studio.lag.delaysAudio {
            audioCapture.delaySeconds = available
        }
        refreshReplayState()
        updateMenuBarState()
    }

    /// Releases it. Snap-back cuts to live and never sends the backlog; catch
    /// up plays the backlog out faster than real time first.
    public func releaseLag() {
        guard let pipeline, isLagging else { return }
        isLagging = false
        // Releasing via the lag switch also settles a connection-engaged
        // delay; the visual degrade (if any) stays until its own release.
        connectionEngagedLag = false
        // Audio has no honest catch-up: speeding up a delay line means
        // resampling or dropping samples, and both sound worse than the skew.
        // The microphone therefore always snaps back (§5.12).
        audioCapture.delaySeconds = 0

        switch studio.lag.release {
        case .snapBack:
            if isFrozen {
                pipeline.refreezeFromCurrentOutput()
            }
            pipeline.replayPlayer.stop()
            pipeline.beginCrossfade(durationMs: 200)
            refreshReplayState()
        case .catchUp:
            isCatchingUp = true
            pipeline.replayPlayer.beginCatchUp(rate: studio.lag.clampedCatchUpRate)
        }
        updateMenuBarState()
    }

    /// §5.12 — retargets an engaged delay without releasing it. Deepening
    /// holds the picture until the extra delay is absorbed; shortening drops
    /// exactly that much backlog. The audio delay line follows in one step —
    /// it has no honest gradual path (§5.12), and the skew during the video's
    /// absorb/skip is brief.
    private func retargetLagDepth(seconds requested: Double, delaysAudio: Bool) {
        guard let pipeline, isLagging else { return }
        // Same buffer bound as engaging: the delay lives in the ring.
        let available = min(requested, studio.replay.clampedBufferSeconds - 0.5)
        guard available > 0.1 else { return }
        pipeline.replayPlayer.adjustLag(toSeconds: available)
        if delaysAudio {
            audioCapture.delaySeconds = available
        }
        refreshReplayState()
    }

    /// Hotkey edge. A press while already lagging releases, so a missed key
    /// release (focus change, revoked input monitoring) can never strand the
    /// switch on.
    public func handleLagKey(pressed: Bool) {
        if pressed {
            if isLagging {
                releaseLag()
            } else {
                engageLag()
            }
        } else if studio.lag.holdToLag, isLagging {
            releaseLag()
        }
    }

    public func toggleLag() {
        if isLagging { releaseLag() } else { engageLag() }
    }

    // MARK: - Intents: bad connection (§5.14)

    /// Degrades the published picture — macroblocks, starved colour, a choppy
    /// frame rate — and, when configured, falls behind live on the §5.12
    /// transport. One switch, because "my connection is struggling" is one
    /// story, not three settings to remember mid-call.
    public func engageBadConnection() {
        guard let pipeline, !isBadConnection else { return }
        pipeline.connectionStage.settings = studio.connection
        pipeline.connectionStage.setEngaged(true)
        isBadConnection = true

        // The delay half rides the lag switch's transport with the
        // connection's own, shorter delay. It needs the rolling buffer
        // exactly like §5.12 — but the visual half must not fail with it:
        // degrade what can be degraded, and say what could not.
        if studio.connection.addsLag, !isLagging, !isCatchingUp,
           replayMode != .replay {
            if !studio.replay.isArmed {
                warning = WarningMessage(
                    text: "Degrading the picture. Turn on the rolling buffer to fall behind live too",
                    action: .armBuffer)
            } else {
                let available = min(studio.connection.lagSeconds,
                                    studio.replay.clampedBufferSeconds - 0.5)
                if available > 0.1,
                   pipeline.replayPlayer.startLag(delaySeconds: available) {
                    isLagging = true
                    connectionEngagedLag = true
                    // A real network delays both paths together; picture
                    // behind live audio reads as broken software (§5.12).
                    audioCapture.delaySeconds = available
                } else {
                    warning = WarningMessage(
                        text: "Degrading the picture. Nothing buffered yet to fall behind live")
                }
            }
        }
        refreshReplayState()
        updateMenuBarState()
    }

    /// Restores the clean picture, instantly — recovery costs nothing because
    /// the full chain kept running underneath. A delay this switch engaged
    /// itself snaps back to live (a recovering connection drops its backlog);
    /// a delay the user engaged separately with the lag switch is left alone.
    public func releaseBadConnection() {
        guard let pipeline, isBadConnection else { return }
        isBadConnection = false
        pipeline.connectionStage.setEngaged(false)
        if connectionEngagedLag, isLagging {
            isLagging = false
            audioCapture.delaySeconds = 0
            if isFrozen {
                pipeline.refreezeFromCurrentOutput()
            }
            pipeline.replayPlayer.stop()
            pipeline.beginCrossfade(durationMs: 200)
            refreshReplayState()
        }
        connectionEngagedLag = false
        updateMenuBarState()
    }

    public func toggleBadConnection() {
        if isBadConnection { releaseBadConnection() } else { engageBadConnection() }
    }

    /// Called when a catch-up reaches the live edge.
    private func finishCatchUp() {
        guard isCatchingUp, let pipeline else { return }
        isCatchingUp = false
        if isFrozen {
            pipeline.refreezeFromCurrentOutput()
        }
        pipeline.replayPlayer.stop()
        pipeline.beginCrossfade(durationMs: 200)
        refreshReplayState()
        updateMenuBarState()
    }

    // MARK: - Intents: panic (§5.11)

    /// One chord, assembled entirely from primitives PRISM already has:
    /// freeze the picture, mute the microphone, and swap the background for a
    /// "back in a bit" backdrop. Pressing it again puts everything back
    /// exactly as it was — including a freeze or mute the user had engaged
    /// themselves before panicking.
    public func togglePanic() {
        if isPanicked {
            releasePanic()
        } else {
            engagePanic()
        }
    }

    private func engagePanic() {
        guard !isPanicked else { return }
        isPanicked = true

        if studio.panic.swapsBackdrop {
            // Snapshot before mutating; this is what gets persisted and what
            // a preset save captures while panic is held.
            panicRestore = config
            updateConfig { cfg in
                cfg.background = self.studio.panic.backdropConfiguration
                var flags = cfg.flags(for: .background)
                flags.enabled = true
                cfg.flags[.background] = flags
            }
        }
        if studio.panic.mutes, !isMuted {
            panicMutedByUs = true
            toggleMute()
        }
        if studio.panic.freezes, !isFrozen {
            toggleFreeze()
        }
        updateMenuBarState()
    }

    private func releasePanic() {
        guard isPanicked else { return }
        isPanicked = false

        if isFrozen, studio.panic.freezes {
            toggleFreeze()
        }
        if panicMutedByUs {
            panicMutedByUs = false
            if isMuted { toggleMute() }
        }
        if let restore = panicRestore {
            panicRestore = nil
            pipeline?.beginCrossfade(durationMs: 200)
            updateConfig { $0 = restore }
        }
        updateMenuBarState()
    }

    // MARK: - Intents: eye contact (§5.6)

    public func toggleEyeContact() {
        let enabled = editingConfig.flags(for: .gaze).enabled
        setStageEnabled(.gaze, !enabled)
    }

    // MARK: - Intents: voice changer (§5.13)

    /// A voice effect is on air. Everyone else hears it; the user does not —
    /// PRISM publishes a microphone, it does not monitor one — which is why
    /// this state feeds the menu bar's effects glyph.
    public var isVoiceActive: Bool { studio.voice.isActive }

    /// Picking an effect is the same intent as switching the voice on, and
    /// picking Off is the same intent as switching it off — one question,
    /// one control (§8.7). A real effect is also remembered for the toggle.
    public func setVoiceEffect(_ effect: VoiceEffect) {
        var voice = studio.voice
        voice.effect = effect
        if effect != .off {
            voice.lastUsedEffect = effect
        }
        studio.voice = voice        // one mutation → one didSet → one persist
    }

    public func setVoiceAmount(_ amount: Double) {
        studio.voice.amount = amount
    }

    /// ⌃⌥⌘V: off ↔ the last voice used, so a quick unmask before saying
    /// something serious does not lose the alien you spent a meeting on.
    public func toggleVoice() {
        setVoiceEffect(isVoiceActive ? .off : studio.voice.recallEffect)
    }

    // MARK: - Intents: voice cleanup and the mic watch (§5.15)

    /// One picker, because "how much should PRISM tidy the microphone" is
    /// one question (§8.7). Cleanup is independent of the voice effects and
    /// always runs ahead of them.
    public func setVoiceCleanupMode(_ mode: VoiceCleanupMode) {
        studio.cleanup.mode = mode
    }

    public var isVoiceCleanupActive: Bool { studio.cleanup.isActive }

    /// The banner is opt-in; the menu bar signal is not (§5.15).
    public func setMicWatchBanner(_ shows: Bool) {
        studio.micWatch.showsBanner = shows
    }

    /// Why the mic check cannot run right now, or nil when it can. The check
    /// taps the same path the ring hears, so anything silencing that path
    /// would only record silence — better to say why than to play nothing.
    public var micCheckInhibition: String? {
        if permissions.microphone != .granted {
            return "Allow microphone access to test your voice"
        }
        if isMuted {
            return "Unmute to test your voice"
        }
        if clipState == .playing, clipUsesClipAudio {
            return "Clip audio owns the microphone right now"
        }
        return nil
    }

    // MARK: - Replay state mirroring

    private func refreshReplayState() {
        guard let pipeline else { return }
        let player = pipeline.replayPlayer
        let mode = player.mode
        if replayMode != mode {
            replayMode = mode
            restartReplayTimerIfNeeded()
        }
        let duration = player.durationSeconds
        if abs(replayDuration - duration) > 0.01 { replayDuration = duration }
        let position = player.positionSeconds
        if abs(replayPosition - position) > 0.01 { replayPosition = position }
        // A replay that ran to the live edge with return-to-live off simply
        // holds there; isAway is unaffected.
        if mode == .idle {
            if isAway { isAway = false }
            if isLagging { isLagging = false }
            if isCatchingUp { isCatchingUp = false }
            connectionEngagedLag = false
        }
        // The deliberate delay is reported to the monitor, and therefore to
        // the user, for as long as it is being applied (§6).
        monitor.setDeliberateDelayMs(
            mode == .lag ? player.appliedDelaySeconds * 1000 : 0)
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
            // Turning a stage on whose parameters are all at identity flips a
            // switch and changes nothing (PipelineConfiguration.isInert). LUT
            // and Style have the one unambiguous remedy: when the identity
            // entry ("Neutral", "Normal") is selected, switching on picks the
            // first real look. A zero strength/intensity is deliberately left
            // alone — like Adjust, there is no value to guess at, so the
            // surfaces caption it and point at the slider instead.
            if enabled, id == .lut, cfg.lut.isNeutral,
               let firstLook = LUTStore.shared.firstNonNeutralLUT {
                cfg.lut.lutName = firstLook
            }
            if enabled, id == .style, cfg.style.isNormal,
               let firstEffect = StyleEffect.distortions.first {
                // The catalogue's first tile after Normal (grids lead with
                // the distortions).
                cfg.style.effect = firstEffect
            }
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

    /// Picking a LUT is the same intent as switching the stage on, and
    /// picking Neutral is the same intent as switching it off — Neutral is
    /// the identity LUT, so any other pairing puts the picker and the switch
    /// in visible disagreement about whether a look is applied.
    public func setLUTName(_ name: String) {
        updateEditing { cfg in
            cfg.lut.lutName = name
            var flags = cfg.flags(for: .lut)
            flags.enabled = !LUTSettings.isNeutral(name)
            cfg.flags[.lut] = flags
        }
        if draftConfig == nil {
            var status = stageStatus[.lut] ?? StageStatus()
            status.autoDisabled = false
            stageStatus[.lut] = status
        }
    }

    /// Picking a style is the same intent as switching the stage on, and
    /// picking Normal is the same intent as switching it off — Normal is
    /// the unstyled picture, so any other pairing puts the picker and the
    /// switch in visible disagreement about whether a look is applied (the
    /// LUT / Neutral rule applied to the style catalogue).
    public func setStyleEffect(_ effect: StyleEffect) {
        updateEditing { cfg in
            cfg.style.effect = effect
            var flags = cfg.flags(for: .style)
            flags.enabled = effect != .normal
            cfg.flags[.style] = flags
        }
        if draftConfig == nil {
            var status = stageStatus[.style] ?? StageStatus()
            status.autoDisabled = false
            stageStatus[.style] = status
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
        if audioCaptureDemand, permissions.microphone == .granted {
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
        // the live config would silently omit every staged edit. Mid-panic,
        // "current" is a "back in a bit" card, which nobody means to save as
        // a preset, so the pre-panic snapshot wins over the live config.
        var cfg = draftConfig ?? panicRestore ?? config
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
        micCheck.cancel()
        levelTimer?.invalidate()
        levelTimer = nil
        audioCapture.stop()
        clipPlayer?.stop()
        pipeline?.replayPlayer.stop()
        pipeline?.replayBuffer.reset()
        cameraCapture.stop()
        cmioSink.disconnect()
        audioSink?.close()      // marks producerAlive = 0 → plug-in emits silence
        NSApp.terminate(nil)
    }

    // MARK: - Derived state

    private func updateMenuBarState() {
        // §8.2 precedence, extended: error > panic > away > bad connection >
        // lagging > replaying > frozen > muted-and-talking > muted > effects
        // > live > idle. The substitution states outrank the effect states
        // because forgetting you are in one is the damaging failure — panic
        // and away most of all, since both mean "the picture on air is not
        // you right now". Bad connection outranks lagging: when the switch
        // engaged the delay itself, the delay is a part of the stunt, and the
        // badge should name the stunt the user engaged. Muted-and-talking
        // sits directly above muted because it is the muted state plus the
        // one fact that makes it urgent (§5.15); it does not outrank freeze,
        // which is a bigger lie about a bigger surface.
        let newState: MenuBarState
        if case .failed = setup.cameraExtension {
            newState = .error
        } else if isPanicked {
            newState = .panicked
        } else if isAway {
            newState = .away
        } else if isBadConnection {
            newState = .badConnection
        } else if isLagging || isCatchingUp {
            newState = .lagging
        } else if replayMode == .replay {
            newState = .replaying
        } else if isFrozen {
            newState = .frozen
        } else if mutedTalking {
            newState = .mutedTalking
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
        // §5.13: an active voice effect is on air exactly like a visual one,
        // and forgetting it is the same class of failure.
        if isVoiceActive { return true }
        // Enabled is not the same as doing something: a stage the pipeline
        // skips (isInert) changes no pixels, and the menu bar must not claim
        // an effect is on air when the picture is untouched. Geometry was
        // always excluded this way; isInert applies the same test to the rest.
        for id: StageID in [.adjust, .lut, .style, .blur, .gaze, .background, .overlay,
                            .geometry]
        where config.flags(for: id).enabled && !config.isInert(id) {
            if !(stageStatus[id]?.autoDisabled ?? false) { return true }
        }
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
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.studio),
           let decoded = try? JSONDecoder().decode(StudioSettings.self, from: data) {
            studio = decoded
        }
        // §8.3 default: Framing, Effects, Format collapsed on first launch —
        // an empty set is exactly that, so no seeding is needed.
    }

    /// Panic's backdrop swap lives in `config` so every surface shows what is
    /// on air — but it must not survive a quit. Persisting the pre-panic
    /// snapshot means relaunching after panicking leaves you where you were,
    /// not stuck behind a "back in a bit" card with no memory of why.
    private func persistConfig() {
        if let data = try? JSONEncoder().encode(panicRestore ?? config) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.configuration)
        }
    }

    private func persistStudio() {
        if let data = try? JSONEncoder().encode(studio) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.studio)
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
