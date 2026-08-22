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
import QuartzCore
import SwiftUI
import UserNotifications

/// A finished still buffer crossing to the file-writing queue. CoreVideo's
/// overlay lacks Sendable conformance, but this buffer is immutable after the
/// pipeline hands it out and the exporter is its only consumer.
private struct SendableStillBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

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
    private var observers: [UUID: () -> Void] = [:]

    func store(_ t: MTLTexture?) {
        lock.lock()
        texture = enabled ? t : nil
        // Dictionary assignment is copy-on-write, so this snapshots the
        // observer set without allocating an Array on every video frame.
        let callbacks = enabled && t != nil ? observers : [:]
        lock.unlock()
        // Never invoke foreign code under the mailbox lock. A preview draw
        // can immediately call take(), and doing that while locked would
        // turn a frame notification into a deadlock.
        for callback in callbacks.values { callback() }
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

    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }
}

/// Lifetime token for PreviewView's frame-driven invalidation. It observes
/// both live and draft mailboxes because a pane can switch between them while
/// it remains on screen; the renderer itself decides which texture to draw.
final class PreviewFrameObservation {
    private let cancelClosure: () -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(cancel: @escaping () -> Void) { cancelClosure = cancel }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        cancelClosure()
    }

    deinit { cancel() }
}

/// Which capture is driving the chain, readable from the capture queues.
///
/// `AppState.videoSource` is main-thread state and the frame path may not
/// touch it: a camera frame and a screen frame arrive on different queues and
/// each has to know, without a hop, whether it is the picture or a layer on
/// top of it. One lock-guarded enum answers that for both.
final class SourceRoute {
    private let lock = NSLock()
    private var kind: VideoSourceKind = .camera

    func set(_ newKind: VideoSourceKind) {
        lock.lock()
        kind = newKind
        lock.unlock()
    }

    var cameraIsSource: Bool {
        lock.lock()
        defer { lock.unlock() }
        return kind == .camera
    }
}

@MainActor
public final class AppState: ObservableObject {

    // MARK: - Published surface (CONTRACTS.md)

    // Status
    @Published public var latency = LatencyReport()
    /// §7 — what the memory ceiling is currently paying for. Published
    /// because the alternative is a freeze window that quietly halves at
    /// 60 fps and a user with no way to find out why.
    @Published public private(set) var resources = ResourceGovernor.plan(
        for: ResourceDemand(format: VideoFormat(width: 1920, height: 1080,
                                                frameRate: 30)))
    /// Who is streaming, with the signing IDs per-app rules match on. Two
    /// apps can share a display name, so the name alone cannot identify a
    /// client and cannot be the thing rules are keyed on.
    @Published public var clients: [CameraClient] = []
    /// The same clients as names, in the same order. A projection rather
    /// than a second stored array, so the two can never disagree.
    public var clientsInUse: [String] { clients.map(\.displayName) }
    /// §5.18 — apps the extension is refusing right now. Non-empty only
    /// while a block is actually biting, which is exactly when the user needs
    /// to be told why an app's video is dark.
    @Published public var blockedClients: [CameraClient] = []
    @Published public var warning: WarningMessage?
    /// The second row under the status line, and deliberately not the
    /// warning slot: there is only one warning, and evicting a
    /// device-disconnect message to say "Saved" or "you're muted" would
    /// trade a fact for a hint. Set by the capture features (§5.15, §5.16),
    /// which clear it on a timer because a "Saved …" line that outlives its
    /// moment is clutter, and by the mic watch (§5.17), which clears it when
    /// the condition it describes goes away.
    @Published public var notice: NoticeMessage?
    /// §5.16 — where a still is between the key press and the file.
    @Published public var capturePhase: CapturePhase = .idle
    @Published public var menuBarState: MenuBarState = .idle
    @Published public var setup = SetupStatus()
    // Controls
    @Published public var isFrozen = false
    @Published public var isMuted = false
    /// §5.17 — live microphone level, 0…1, perceptually scaled by the same
    /// mapping the mic check uses so the two meters read alike. Zero unless
    /// something is watching (see inputLevelDemand).
    @Published public private(set) var inputLevel: Double = 0
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
                // §5.17: cleanup is a repair, not a costume — it never
                // reaches the menu bar's effect glyph.
                audioCapture.voiceCleanup.apply(studio.cleanup)
            }
            if studio.micWatch != oldValue.micWatch {
                micWatch.apply(studio.micWatch)
                refreshMutedTalkingNotice()
            }
            // §5.28: the presence switches are the whole demand gate for a
            // Vision request, so the detector has to be armed and disarmed
            // with them rather than on the next frame that happens to notice.
            if studio.presence != oldValue.presence {
                updatePresenceWatching()
            }
            // §5.31: the same arrangement one modality along — the gesture
            // switches ARE the demand gate for a Vision request, so they have
            // to reach the recogniser now rather than on some later frame
            // that happens to notice.
            // §5.32/§5.33: both sessions hold a snapshot rather than
            // reading `studio` per tick, so a settings change has to be
            // pushed to them the way the voice chains are.
            if studio.meeting != oldValue.meeting {
                meeting.apply(studio.meeting)
                reconcileTranscription()
            }
            if studio.assistant != oldValue.assistant {
                assistant.apply(studio.assistant)
                insights.apply(studio.assistant)
            }
            if studio.gestures != oldValue.gestures {
                updateGestureWatching()
            }
            // §5.18: the extension keeps enforcing whatever it last
            // persisted, so every edit to the rule list has to reach it.
            if studio.apps != oldValue.apps {
                publishAccessPolicy()
                reconcileAppRules()
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
    /// §5.17 — muted, and the microphone is hearing sustained speech
    /// anyway. Owned by the mic watch, so it is read-only from outside:
    /// anything that could set it would be claiming to have heard
    /// something.
    @Published public private(set) var mutedTalking = false
    /// A screen or window is on air in place of the camera. Derived from
    /// `videoSource`, so it is read-only from outside: a surface that could
    /// set it would be claiming the picture had changed without changing it.
    @Published public private(set) var isSharingScreen = false
    /// Playing the backlog out faster than real time after a catch-up release.
    @Published public var isCatchingUp = false
    /// Eye contact has found a face and is actually correcting. A correction
    /// that silently does nothing is indistinguishable from a broken one.
    @Published public var eyeContactTracking = false
    /// A face-anchored layer (§5.8) has a face to sit on. Separate from
    /// `eyeContactTracking` because it asks a weaker question: a prop needs a
    /// face box, which a profile turn still gives, while a gaze correction
    /// needs both pupils, which it does not.
    @Published public var faceAnchorTracking = false
    /// §5.28 — whether anybody is in front of the camera. `.unknown` whenever
    /// presence is not being watched, which is most of the time. Read-only
    /// from outside: a surface that could set it would be claiming to have
    /// seen something.
    @Published public private(set) var presence: PresenceState = .unknown
    /// §5.28 — presence automation put something on air and is holding it
    /// there. What it did is `presenceAction`; this is the bit every surface
    /// needs, which is that the user did not press anything for this.
    @Published public private(set) var presenceEngaged = false
    /// §5.31 — the last gesture that fired, kept so a surface can say what
    /// PRISM saw. A gesture that acts without saying so is indistinguishable
    /// from a misfire, and gestures misfire.
    @Published public private(set) var lastGesture: GestureEvent?

    // Pipeline / format
    @Published public var config = PipelineConfiguration()
    @Published public var stageStatus: [StageID: StageStatus] = [:]
    @Published public var publishedFormats: [VideoFormat] = VideoFormat.defaultSet
    // Devices
    /// What feeds the pipeline: the camera, or a screen or window. One
    /// question, one control (§8.7) — which is why the source sits with the
    /// device pickers rather than in a pane of its own. Written only through
    /// `selectVideoSource`, which is what starts and stops the capture behind
    /// it; a surface writing this directly would move the label without
    /// moving the picture.
    @Published public private(set) var videoSource = VideoSourceSelection.camera
    /// Which screen or window the screen capture is pointed at. Usually the
    /// same as `videoSource`, and separate from it for the one case where it
    /// cannot be: a picture-in-picture of a screen while the camera is the
    /// source (§5.25). Never `.camera`.
    @Published public private(set) var screenFeed = VideoSourceSelection(
        kind: .display, sourceID: ScreenCapture.sourceID(display: CGMainDisplayID()))
    /// Everything shareable right now, refreshed when a picker is drawn.
    /// Empty without the Screen Recording grant — enumerating would raise the
    /// system prompt, and a prompt nobody asked for is not a picker.
    @Published public private(set) var screenSources: [ScreenSourceInfo] = []
    @Published public var cameras: [CameraDeviceInfo] = []
    @Published public var microphones: [AudioDeviceInfo] = []
    // Presets
    @Published public var presets: [Preset] = []
    @Published public var activePresetID: UUID?
    /// §5.18 per-app rules. Behaviour rather than look, so they live in
    /// `StudioSettings` alongside replay and panic: a preset that carried
    /// rules could apply itself. Projected rather than stored a second time,
    /// so `studio` stays the single persisted home and the two can never
    /// disagree; writing through here fires the `studio` didSet, which is
    /// where the republish and re-resolve happen.
    public var appRules: AppRulesSettings {
        get { studio.apps }
        set { studio.apps = newValue }
    }
    /// Non-nil while a rule — not the user — is responsible for the active
    /// preset. Every preset surface reads this so "why did my look change"
    /// is answerable without opening a pane.
    @Published public private(set) var activeAppRule: AppRuleMatch?
    // Sections
    @Published public var expandedSections: Set<PopoverSection> = [] {
        didSet { persistExpandedSections() }
    }
    /// Which modules the menu bar dropdown shows, in order — edited from the
    /// main window's Menu Bar pane.
    @Published public var popoverLayout: [PopoverModuleItem] = PopoverModuleItem.defaultLayout {
        didSet { persistPopoverLayout() }
    }
    /// §5.19 — the user's global chords. Written through setShortcut and
    /// friends, which resolve collisions first; the didSet is what keeps the
    /// tap and the stored copy in step no matter which surface wrote.
    @Published public var hotkeyBindings = HotkeyBindings() {
        didSet {
            guard hotkeyBindings != oldValue else { return }
            hotkeys.setBindings(hotkeyBindings.resolved)
            persistHotkeyBindings()
        }
    }
    /// §5.20 — whether App Intents may drive PRISM. Off until asked for:
    /// every other process on the machine can see the intents, and the point
    /// of the switch is that seeing them is not the same as being able to
    /// use them.
    @Published public var externalControlEnabled = false {
        didSet {
            guard externalControlEnabled != oldValue else { return }
            UserDefaults.standard.set(externalControlEnabled,
                                      forKey: DefaultsKey.externalControl)
        }
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
    /// §5.27 — puts the teleprompter panel on screen, or takes it away. Same
    /// arrangement as the main window, for the same reason: the panel is an
    /// NSPanel the app delegate owns, and nothing in the tested half of the
    /// app is allowed to know it exists.
    public var prompterPanelHandler: ((Bool) -> Void)?
    /// §5.27 — the script is scrolling. Deliberately transient: a prompter
    /// that resumed by itself on the next launch would start reading over
    /// whatever the user opened PRISM to do.
    @Published public private(set) var prompterRunning = false
    /// Bumped to send the panel's scroll back to the first line. A token
    /// rather than a position because the position lives in the panel, where
    /// the font metrics that define it are.
    @Published public private(set) var prompterResetToken = 0

    public var previewTextureProvider: (() -> MTLTexture?) = { nil }
    public var draftPreviewTextureProvider: (() -> MTLTexture?) = { nil }

    /// Drives MTKView from actual pipeline output instead of a free-running
    /// display link. Internal UI plumbing: no published state and therefore
    /// no SwiftUI invalidation per frame.
    func observePreviewFrames(_ observer: @escaping () -> Void) -> PreviewFrameObservation {
        let liveID = previewBox.addObserver(observer)
        let draftID = draftPreviewBox.addObserver(observer)
        return PreviewFrameObservation { [previewBox, draftPreviewBox] in
            previewBox.removeObserver(liveID)
            draftPreviewBox.removeObserver(draftID)
        }
    }

    // MARK: - Sub-objects the UI observes directly

    public let permissions = Permissions()
    public let extensionInstaller = ExtensionInstaller()
    public let presetStore = PresetStore()
    /// §5.13 mic check — record a few seconds of the processed microphone
    /// and play it back, the only way to hear your own voice effect.
    public let micCheck: MicCheck
    /// §5.21 — this session's history, in memory only.
    public let sessionLog = SessionLog()
    /// §5.32 — the live transcript. Owns its own capture wiring and state
    /// machine; AppState supplies the taps and the demand signal and stays
    /// out of the rest.
    public let meeting: MeetingSession
    /// Installed by the app delegate. Detection can request consent or clear
    /// a stale request, but it cannot start Meeting mode by itself.
    public var meetingJoinPromptHandler: ((MeetingJoinCandidate) -> Void)?
    public var meetingJoinEndedHandler: (([String]) -> Void)?
    public var clearMeetingJoinPromptsHandler: (() -> Void)?
    /// §5.33 — the in-meeting assistant.
    public let assistant = AssistantSession()
    /// §5.34 — live insights. Its own object for the assistant's reason, and
    /// armed only through `wireMeeting`: it needs the panel, a provider and
    /// a listening meeting, and any one of them going away disarms it.
    public let insights = InsightSession()

    // MARK: - Components

    private var metal: MetalContext?
    private var pipeline: VideoPipeline?
    private let cameraCapture = CameraCapture()
    private let screenCapture = ScreenCapture()
    private let sourceRoute = SourceRoute()
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
    private var meetingJoinDetector = MeetingJoinDetector()

    private let previewBox = PreviewTextureBox()
    /// Draft preview path: the renderer lives only while the main window is
    /// open with a draft pending; the box outlives it (same shape as the
    /// live previewBox).
    private let draftRendererBox = DraftRendererBox()
    private let draftPreviewBox = PreviewTextureBox()
    private var cancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?
    /// §5.17 — 10 Hz while the input meter has an audience. The RT side is
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
    /// §5.16 shutter delay, and the expiry of the "Saved …" line.
    private var countdownTimer: Timer?
    private var noticeTimer: Timer?
    private var lastCameraFrameAt = Date.distantPast
    private let lastFrameLock = NSLock()
    /// What the running screen session was started for, so reconciliation can
    /// tell "already capturing this" from "capturing something else".
    private var activeScreenRequest: (selection: VideoSourceSelection,
                                      format: VideoFormat)?
    /// Set when a screen session reported it could not run. Without it a
    /// picture-in-picture of a window that has closed would rebuild a failing
    /// stream on every reconciliation, forever. It suppresses only the
    /// *automatic* rebuild: a new pick, a new layer, a wake, or the grant
    /// arriving all clear it, because each of them is the user or the system
    /// saying the answer might be different now.
    private var screenCaptureBlocked = false
    /// Live-feed demand as of the last reconciliation, so an edit that did
    /// not touch it does not tear a capture session down and build it again
    /// on every drag of a slider.
    private var lastLiveFeedDemand: Set<LiveLayerFeed> = []
    private var formatsPublishedToExtension = false
    /// Dirty flag for the §5.18 'polc' write, same shape as the one above.
    private var appRulePolicyPublished = false
    /// One-shot: the automatic extension activation request for this launch.
    private var autoRequestedExtension = false
    /// Last client-negotiated format observed via 'afmt'; only *changes* are
    /// applied so a stale extension value never fights the user's selection.
    private var lastNegotiatedFormat: VideoFormat?
    private var lastSinkDroppedFrames = 0
    private var started = false
    /// How many shortcut recorders are armed (§5.19); the tap is off while
    /// any of them is.
    private var shortcutRecorders = 0

    /// Configuration snapshot taken when panic engaged, restored on release.
    /// Panic mutates `config` so every surface shows what is actually on air,
    /// but it must never outlive the panic: this is what gets persisted and
    /// what a preset save captures while the chord is held.
    private var panicRestore: PipelineConfiguration?
    /// What panic engaged itself (§5.11) — a freeze, a mute, or both — so
    /// releasing restores the user's own freeze and mute rather than blanket
    /// thawing and unmuting. The away loop keeps the same bookkeeping for the
    /// mute it engages.
    private var panicHold = PanicHold()
    private var awayMutedByUs = false
    /// §5.28. The hysteresis lives in PresenceWatcher; these three are the
    /// bookkeeping for undoing exactly what presence did and nothing else —
    /// a freeze the user had already engaged is theirs to release, and a mute
    /// they set themselves must survive them walking back into shot.
    private let presenceWatcher = PresenceWatcher()
    private var presenceAction: PresenceAction?
    private var presenceFrozeByUs = false
    private var presenceMutedByUs = false
    /// Mirrors what the pipeline was last told, so the gate is recomputed
    /// from several places without churning the frame path.
    private var presenceWatching = false
    private var lastPresenceSequence: UInt64 = 0
    /// §5.31. The dwell, debounce and cooldown live in GestureWatch; these
    /// two are the same bookkeeping presence keeps — what the pipeline was
    /// last told, and which sighting has already been counted.
    private let gestureWatch = GestureWatch()
    private var gestureWatching = false
    private var lastGestureSequence: UInt64 = 0
    /// Whether the bad connection engaged the §5.12 delay itself (§5.14), so
    /// releasing it releases only the delay it engaged — never one the user
    /// asked for separately with the lag switch.
    private var connectionEngagedLag = false

    /// The look to put back when the rule-driven client stops streaming.
    /// Taken once, on the transition from "no rule in effect" to "a rule is
    /// in effect", so a Zoom → Teams handover in one sitting still returns
    /// to what the user had before any of it started.
    private var appRuleRestore: PipelineConfiguration?
    /// The preset that was active before a rule took over, so the chips go
    /// back to reading the way the user left them.
    private var appRuleRestorePresetID: UUID?

    private enum DefaultsKey {
        static let configuration = "PRISM.configuration"
        static let camera = "PRISM.selectedCamera"
        static let microphone = "PRISM.selectedMicrophone"
        static let sections = "PRISM.expandedSections"
        static let popoverLayout = "PRISM.popoverLayout"
        static let studio = "PRISM.studio"
        static let videoSource = "PRISM.videoSource"
        /// Which screen a picture-in-picture shows while the camera is the
        /// source — a question `videoSource` cannot hold the answer to.
        static let screenFeed = "PRISM.screenFeed"
        static let hotkeys = "PRISM.hotkeys"
        static let externalControl = "PRISM.externalControl"
    }

    /// The running instance, for App Intents (§5.20) — which are constructed
    /// by the system and so cannot be handed a reference. Weak and
    /// single-writer: AppState is created once, by the app.
    @MainActor public private(set) static weak var current: AppState?

    // MARK: - Init

    public init() {
        micCheck = MicCheck(capture: audioCapture)
        // §5.32. Every dependency arrives as a closure so the session can be
        // driven headless in a test — no microphone, no permission, no
        // model. `micIsOffAir` is the same signal the status line uses:
        // while it is true the transcription tap receives nothing at all,
        // and the session marks a gap rather than stitching across it.
        let systemAudio = SystemAudioCapture()
        self.systemAudioCapture = systemAudio
        let capture = audioCapture
        meeting = MeetingSession(
            engineFactory: { model in
                SpeechEngineRegistry.make(model)
            },
            armMicTap: { [capture] in capture.setASRTapArmed($0) },
            micTapCursor: { [capture] in capture.asrTapCursor },
            readMicTap: { [capture] cursor, buffer, maxFrames in
                capture.readASRTap(from: cursor, into: buffer, maxFrames: maxFrames)
            },
            farEnd: systemAudio)
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
        wireMeeting()
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
        AppState.current = self
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
        micWatch.apply(studio.micWatch)
        updatePresenceWatching()
        updateGestureWatching()
        monitor.setPolicy(config.latencyPolicy,
                          frameIntervalMs: formatManager.activeFormat.frameIntervalMs)

        Task { [weak self] in
            guard let self else { return }
            // Prompt at launch (onboarding needs the grants), but do NOT
            // start capturing: capture follows demand, not permission.
            _ = await self.permissions.requestCamera()
            _ = await self.permissions.requestMicrophone()
            // Screen Recording is deliberately not prompted for here: the
            // feature ships off, and a permission dialog at first launch for
            // something nobody has asked for is how apps lose that grant for
            // good. The persisted pick is only *resolved* — which needs the
            // grant it already has, or falls back to the camera.
            await self.resolvePersistedSource()
            self.refreshScreenRecordingNeed()
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
            // The camera is either the picture or a layer on top of it
            // (§5.25), and the two are the same frames arriving on the same
            // queue — only the destination differs.
            guard self.sourceRoute.cameraIsSource else {
                pipeline.liveFeeds.publish(buffer, feed: .camera)
                return
            }
            self.lastFrameLock.lock()
            self.lastCameraFrameAt = Date()
            self.lastFrameLock.unlock()
            pipeline.submitCameraFrame(buffer, at: time)
            // Draft preview rides the same frames; submit() drops when busy.
            draftRendererBox.get()?.submit(buffer)
        }
        // §5.24: screen frames enter through the camera's door on purpose.
        // Everything downstream — the ring, freeze, replay, the still ring,
        // latency attribution — keeps working precisely because none of it
        // ever asked where the pixels came from.
        screenCapture.onFrame = { [weak self, weak pipeline, draftRendererBox] buffer, time in
            guard let self, let pipeline else { return }
            guard !self.sourceRoute.cameraIsSource else {
                pipeline.liveFeeds.publish(buffer, feed: .screen)
                return
            }
            self.lastFrameLock.lock()
            self.lastCameraFrameAt = Date()
            self.lastFrameLock.unlock()
            pipeline.submitCameraFrame(buffer, at: time)
            draftRendererBox.get()?.submit(buffer)
        }
        screenCapture.onStopped = { [weak self] stop in
            Task { @MainActor [weak self] in self?.handleScreenCaptureStopped(stop) }
        }
        cameraCapture.onRuntimeError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.warning = WarningMessage(text: message)
                self.sessionLog.record(.device, message)
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
        // §5.28. Pushed rather than polled: the watcher integrates the gap
        // between consecutive observations, and a 1 Hz poll against a ~1 Hz
        // detector would silently drop every other one — halving the rate the
        // away clock advances at, which is exactly the sort of drift nobody
        // would ever trace back to a timer.
        pipeline.presenceDetector.onSample = { [weak self] sample in
            Task { @MainActor [weak self] in self?.handlePresence(sample) }
        }
        // §5.31, pushed for the same reason presence is: the watch integrates
        // the gap between consecutive sightings, and a poll slower than the
        // recogniser would make a held pose take twice as long to satisfy the
        // dwell — or, worse, satisfy it in half the sightings the dwell was
        // reasoned about.
        pipeline.handTracker.onSample = { [weak self] sample in
            Task { @MainActor [weak self] in self?.handleHandPose(sample) }
        }
        // §5.30: the frame path reads the microphone through the same
        // lock-free mailbox the meter does — one acquire-load per frame, so
        // the audio callback never waits on the frame queue and the frame
        // queue never waits on anything.
        pipeline.styleStage.audioLevelSource = Self.audioLevelSource(of: audioCapture)
        pipeline.onResourcePlan = { [weak self] plan in
            Task { @MainActor [weak self] in
                guard let self, plan != self.resources else { return }
                self.resources = plan
                // §5.21: the freeze window shortening is invisible until
                // someone freezes and finds the picture came from less
                // history than they expected. It goes in the record for the
                // same reason an auto-disabled effect does.
                self.sessionLog.record(.degradation, plan.summary)
                if let stills = plan.stillsSummary, plan.stillDepth == 0 {
                    self.sessionLog.record(.degradation, stills)
                }
            }
        }
        resources = pipeline.resourcePlan
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
            // §5.21: the warning row is transient and the next event replaces
            // it, so this is the only place the answer to "why did my effects
            // turn off?" survives past the next minute.
            self.sessionLog.record(.degradation, String(
                format: "%@ turned off — %.1f ms over a %.1f ms budget",
                id.displayName, self.latency.stages[id] ?? 0, self.latency.budgetMs))
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
            self.sessionLog.record(.degradation, "\(id.displayName) came back on")
            self.updateMenuBarState()
        }
        monitor.onPolicyPressure = { [weak self] in
            guard let self else { return }
            self.warning = WarningMessage(
                text: "Effects are exceeding your latency budget",
                action: .raiseBudget)
            self.sessionLog.record(.degradation, String(
                format: "Chain over budget — %.1f ms against %.1f ms",
                self.latency.totalAddedMs, self.latency.budgetMs))
        }
        monitor.$report
            .receive(on: DispatchQueue.main)
            .sink { [weak self] report in
                guard let self else { return }
                guard report != self.latency else { return }
                self.latency = report
                self.sessionLog.observe(report)
                var nextStatus = self.stageStatus
                var statusChanged = false
                for id in StageID.allCases {
                    var status = nextStatus[id] ?? StageStatus()
                    let measured = report.stages[id] ?? 0
                    if status.measuredMs != measured {
                        status.measuredMs = measured
                        nextStatus[id] = status
                        statusChanged = true
                    }
                }
                // One dictionary publication per report, not one publication
                // per registered stage. At 4 Hz the old loop could invalidate
                // the complete SwiftUI tree dozens of times a second.
                if statusChanged { self.stageStatus = nextStatus }
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
            self.logDeviceChange(kind: "Camera",
                                 before: self.cameras.map(\.name),
                                 after: list.map(\.name))
            self.cameras = list
            self.handleSelectedDeviceRemoval(cameraList: list, micList: nil)
            // Arrival is a reconciliation trigger too: a capture whose retry
            // ladder exhausted while the device was absent restarts here.
            self.reconcileCaptures()
        }
        deviceMonitor.onMicrophonesChanged = { [weak self] list in
            guard let self else { return }
            self.logDeviceChange(kind: "Microphone",
                                 before: self.microphones.map(\.name),
                                 after: list.map(\.name))
            self.microphones = list
            self.handleSelectedDeviceRemoval(cameraList: nil, micList: list)
            self.reconcileCaptures()
        }
        deviceMonitor.onVirtualMicInUseChanged = { [weak self] inUse in
            guard let self, self.virtualMicInUse != inUse else { return }
            self.virtualMicInUse = inUse
            self.reconcileCaptures()
            self.reconcileMeetingJoinDetection()
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
                // A wake is the other side of a display configuration change:
                // lids close, docks come and go, and the screen session that
                // gave up before sleeping deserves a fresh attempt.
                self.screenCaptureBlocked = false
                self.activeScreenRequest = nil
                self.reconcileCaptures()
            }
            self.audioCapture.restart()
        }
    }

    /// §5.21. The device lists arrive whole, so the story ("the Logitech
    /// came back") only exists as the difference between two of them — which
    /// is why this runs before the published list is replaced.
    private func logDeviceChange(kind: String, before: [String], after: [String]) {
        guard !before.isEmpty || !after.isEmpty else { return }
        for name in after where !before.contains(name) {
            sessionLog.record(.device, "\(kind) connected: \(name)")
        }
        for name in before where !after.contains(name) {
            sessionLog.record(.device, "\(kind) disconnected: \(name)")
        }
    }

    private func wireSink() {
        cmioSink.onClientsChanged = { [weak self] list in
            guard let self else { return }
            // §5.21: the arrival and the departure are only visible as the
            // difference between two whole lists, so both are read off before
            // the published one is replaced.
            // Matched on the signing ID, which is the identity, but reported
            // by display name, which is what the user recognises.
            for client in list where !self.clients.contains(client) {
                self.sessionLog.record(
                    .clients, "\(client.displayName) started using PRISM Camera")
            }
            for client in self.clients where !list.contains(client) {
                self.sessionLog.record(
                    .clients, "\(client.displayName) stopped using PRISM Camera")
            }
            self.clients = list
            self.updateMenuBarState()
            self.reconcileCaptures()       // a first client starts capture
            self.reconcileAppRules()       // §5.18: who is watching decides the look
            self.reconcileMeetingJoinDetection()
        }
        cmioSink.onBlockedClientsChanged = { [weak self] blocked in
            guard let self else { return }
            self.blockedClients = blocked
            self.updateBlockedWarning()
        }
    }

    /// A supported app beginning to read PRISM Camera is an exact call edge.
    /// PRISM Microphone supplies the camera-off fallback; Core Audio cannot
    /// name its client, so that path is used only when the frontmost app is a
    /// supported meeting app, or exactly one supported app is running.
    private func reconcileMeetingJoinDetection() {
        let detection = meetingJoinDetector.update(
            cameraClients: clients,
            microphoneClient: runningMeetingClientForMicrophone(),
            at: Date()
        )
        if !detection.endedSigningIDs.isEmpty {
            meetingJoinEndedHandler?(detection.endedSigningIDs)
        }
        guard !meeting.phase.isRunning, let prompt = detection.prompt else { return }
        meetingJoinPromptHandler?(prompt)
    }

    private func runningMeetingClientForMicrophone() -> CameraClient? {
        guard virtualMicInUse else { return nil }
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications

        if let signingID = workspace.frontmostApplication?.bundleIdentifier,
           MeetingClientCatalog.candidate(signingID: signingID) != nil {
            return CameraClient(signingID: signingID)
        }

        var candidates: [String: CameraClient] = [:]
        for app in running where !app.isTerminated {
            guard let signingID = app.bundleIdentifier,
                  let candidate = MeetingClientCatalog.candidate(signingID: signingID)
            else { continue }
            candidates[candidate.id] = CameraClient(signingID: signingID)
        }
        return candidates.count == 1 ? candidates.values.first : nil
    }

    private func wireHotkeys() {
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.onActionRelease = { [weak self] action in
            // §5.12: the lag switch is the only chord that is held rather
            // than toggled, so it is the only release that means anything.
            guard action == .lag else { return }
            self?.handleLagKey(pressed: false)
        }
        hotkeys.onPreset = { [weak self] id in self?.selectPreset(id) }
        hotkeys.setBindings(hotkeyBindings.resolved)
        pushPresetHotkeyBindings(presetStore.presets)
    }

    /// The one place a chord becomes an intent — the tap, the App Intents
    /// (§5.20) and anything added later all come through here, so they cannot
    /// drift apart. Exhaustive on purpose: a shortcut cannot be added without
    /// the compiler making someone say what it does, which is the failure mode
    /// a table of callbacks invited.
    public func perform(_ action: ShortcutAction) {
        switch action {
        case .freeze: toggleFreeze()
        case .mute: toggleMute()
        case .freezeAndMute: freezeAndMute()
        case .replay: toggleReplay()
        case .away: toggleAway()
        case .panic: togglePanic()
        case .eyeContact: toggleEyeContact()
        // Press, not toggle: the lag switch is held (§5.12) and its release
        // arrives separately.
        case .lag: handleLagKey(pressed: true)
        case .badConnection: toggleBadConnection()
        case .voice: toggleVoice()
        case .saveClip: saveLastSeconds()
        case .snapshot: takeSnapshot()
        case .screenSource: toggleScreenSource()
        case .prompter: togglePrompter()
        case .meeting: toggleMeeting()
        case .ask: askAssistant()
        case .insights: toggleLiveInsights()
        }
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

    /// §5.32/§5.33. Installs the signals the two sessions cannot form for
    /// themselves, and mirrors their published state back into the demand
    /// gate.
    private func wireMeeting() {
        meeting.micIsOffAir = { [weak self] in self?.micIsOffAir ?? false }
        meeting.apply(studio.meeting)
        assistant.apply(studio.assistant)
        insights.apply(studio.assistant)
        // §5.34 builds its requests from the same provider the assistant
        // uses, reached through the factory so the key never leaves here.
        insights.providerFactory = { [weak self] in self?.makeProvider() }

        // The key is read once, here, rather than per request.
        cachedAnthropicKey = Keychain.get(account: Keychain.Account.anthropic) ?? ""
        hasAnthropicKey = !cachedAnthropicKey.isEmpty

        // A meeting that stops for any reason — the user, a failure, or a
        // model that would not load — has to drop audio demand with it, or
        // the microphone stays live for a transcript nobody is taking.
        // §5.34 follows the same signal: no listening, no insights, and a
        // meeting that ends takes its cards with it.
        meeting.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.reconcileTranscription()
                self?.insights.setListening(phase.isListening)
                if phase.isRunning {
                    self?.clearMeetingJoinPromptsHandler?()
                }
            }
            .store(in: &cancellables)

        // The detector runs on settled far-end text and lights a control.
        // It never causes a request by itself — see §5.33 and
        // QuestionDetector. §5.34 is the opt-in exception: it is fed every
        // change too, and decides for itself, against its own switches and
        // its own cooldowns, whether now is a moment to ask.
        meeting.$lines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in
                guard let self else { return }
                self.insights.observe(lines: lines)
                guard self.studio.assistant.isActive else { return }
                // Only the newest settled turn can be a question that is
                // still waiting for an answer. Passing the rolling history
                // repeatedly resurfaced old questions and rendered six
                // transcript lines on every publication for no benefit.
                let newest = lines.last(where: \.isSettled)
                self.assistant.observeTranscript(
                    newest?.channel == .farEnd ? newest?.text ?? "" : "")
            }
            .store(in: &cancellables)
    }

    private func wireSetupObservers() {
        permissions.$camera
            .combineLatest(permissions.$microphone, permissions.$screenRecording)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] camera, microphone, screenRecording in
                guard let self else { return }
                self.setup.camera = camera
                self.setup.microphone = microphone
                let gained = screenRecording == .granted
                    && self.setup.screenRecording != .granted
                self.setup.screenRecording = screenRecording
                // A grant given in System Settings arrives here, not through
                // an intent — and it is the only thing standing between a
                // chosen screen and a running one.
                if gained {
                    self.screenCaptureBlocked = false
                    self.refreshScreenSources()
                    self.reconcileCaptures()
                }
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
            MainActor.assumeIsolated { self?.pollTick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // The no-camera tick timer is owned by reconcileCaptures(): it runs
        // only while capture demand exists, so an idle PRISM ticks nothing.
    }

    private func pollTick() {
        if let handoff = cmioSink.handoffMs {
            monitor.recordHandoffMs(handoff)
        }
        monitor.setAudioAddedMs(audioCapture.addedLatencyMs)

        let dropped = cmioSink.droppedFrames
        if dropped > lastSinkDroppedFrames {
            monitor.noteDroppedFrames(dropped - lastSinkDroppedFrames)
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

        // §5.18: same dirty-flag treatment for 'polc', and it matters more —
        // the extension keeps enforcing the last policy it persisted, so a
        // write that never lands leaves the user's *previous* blocks in force
        // while the UI shows the new list. Retried every tick until it sticks.
        if !appRulePolicyPublished, cmioSink.isConnected {
            publishAccessPolicy()
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
        if !cmioSink.isConnected, !clients.isEmpty {
            clients = []
            updateMenuBarState()
            reconcileCaptures()
            reconcileAppRules()
        }

        // §5.17: suppression is acknowledged on the RT thread, so the mic can
        // go off air without any intent firing. 1 Hz reconciliation caps how
        // long the watch can be looking the wrong way.
        reconcileInputLevel()

        if let pipeline {
            let buffered = pipeline.replayBuffer.bufferedSeconds
            if abs(bufferedSeconds - buffered) > 0.1 { bufferedSeconds = buffered }
            let tracking = pipeline.gazeStage.isTracking
                && config.flags(for: .gaze).enabled
            if eyeContactTracking != tracking { eyeContactTracking = tracking }
            let anchored = pipeline.faceTracker.isTracking
                && pipeline.overlayStage.needsFaceTracker
            if faceAnchorTracking != anchored { faceAnchorTracking = anchored }
        }
    }

    /// §5.17: the input meter runs only while it has an audience — a preview
    /// surface showing the bar, or the muted-and-talking watch, which can
    /// only fire while the microphone is already off air. With PRISM idle in
    /// the menu bar, unmuted, nothing here computes anything: no RT
    /// accumulation, no timer, no publishes.
    private var inputLevelDemand: Bool {
        guard started, audioCapture.isCapturing else { return false }
        // §5.30 joins the audience: an audio-reactive style reads the same
        // mailbox the meter does, and an unarmed mailbox publishes nothing —
        // so a style set to pulse with the voice while PRISM sits in the menu
        // bar would simply hold still, which looks exactly like a broken
        // effect. It is the one audience with no surface on screen, which is
        // precisely why it has to be named here.
        return previewActive || micIsOffAir || styleWantsAudio
    }

    /// Whether anything is driving an effect from the microphone. Live chain
    /// OR staged draft, deliberately: the draft counts because previewing a
    /// look means previewing what it does with your voice, and the live chain
    /// counts because a draft that happens not to use audio must not disarm
    /// the meter underneath the picture that is actually on air.
    private var styleWantsAudio: Bool {
        func wants(_ configuration: PipelineConfiguration) -> Bool {
            configuration.flags(for: .style).enabled
                && configuration.style.isAudioReactive
        }
        return wants(config) || (draftConfig.map(wants) ?? false)
    }

    /// The level the style stage samples (§5.30), mapped exactly as the
    /// meter maps it so "the bar is halfway up" and "the effect is halfway
    /// on" are the same statement. Static, and capturing only the capture
    /// object, so the closure the frame queue calls holds nothing of
    /// AppState — a main-actor hop per frame is precisely what this must
    /// never be.
    ///
    /// The rules live in AudioReactiveLevel: a counter that stopped moving
    /// reads as silence rather than pinning the effect at the last loudness
    /// heard, and a microphone that is off air reads as silence too. Each
    /// installation gets its own follower, captured by the closure and
    /// touched only by the queue that renders that chain — the live pipeline
    /// and the draft renderer are two chains, two closures, two followers.
    nonisolated private static func audioLevelSource(
        of capture: AudioCapture) -> () -> Double {
        var follower = AudioReactiveLevel()
        return {
            let reading = capture.inputLevelReading
            return follower.level(rms: reading.rms,
                                  sequence: reading.sequence,
                                  offAir: capture.isOffAir,
                                  at: CACurrentMediaTime())
        }
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
            MainActor.assumeIsolated { self?.inputLevelTick() }
        }
        timer.tolerance = 0.015
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

    /// The banner is opt-in (§5.17); the menu bar signal is not.
    ///
    /// Only ever touches the notice slot when the slot is empty or already
    /// ours, so a "Saved …" notice (§5.15/§5.16) is never evicted by a hint
    /// — and, once posted, is never re-asserted over one either. A notice is
    /// the weaker claim of the two and does not fight for the row.
    private func refreshMutedTalkingNotice() {
        let wanted = mutedTalking && studio.micWatch.isEnabled
        if wanted {
            guard notice == nil else { return }
            // Cancel the capture expiry: this notice is a condition, not an
            // event, and it goes away when the mute does rather than on a
            // clock.
            noticeTimer?.invalidate()
            noticeTimer = nil
            notice = NoticeMessage(text: "You're muted — nobody can hear you.",
                                   symbolName: "mic.slash.fill",
                                   action: .unmute)
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
            MainActor.assumeIsolated { self?.refreshReplayState() }
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        replayTimer = timer
    }

    /// Drives the pipeline when the camera is not delivering (clip playback
    /// or freeze with no camera): §5.3/§5.2 must keep producing frames.
    private func restartNoCameraTimer() {
        noCameraTimer?.invalidate()
        let interval = 1.0 / Double(formatManager.activeFormat.frameRate)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastFrameLock.lock()
                let sinceCamera = Date().timeIntervalSince(self.lastCameraFrameAt)
                self.lastFrameLock.unlock()
                guard sinceCamera > interval * 2.5 else { return }
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
        guard config.geometry.autoFrame, pipeline != nil else {
            autoFramer.reset()
            self.pipeline?.geometryStage.autoFrameOffset = (1, 0, 0)
            self.draftRendererBox.get()?.setAutoFrameOffset((1, 0, 0))
            return
        }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pipeline = self.pipeline else { return }
                let box = pipeline.blurStage.latestSubjectBox
                let offset = self.autoFramer.update(subjectBox: box, dt: 1.0 / 30.0)
                pipeline.geometryStage.autoFrameOffset = offset
                // The draft previews the same auto-framing motion (it runs no
                // segmentation of its own — see DraftRenderer).
                self.draftRendererBox.get()?.setAutoFrameOffset(offset)
            }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        autoFrameTimer = timer
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
        previewActive || !clients.isEmpty
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
    /// §5.32: a meeting being transcribed is microphone demand too. The
    /// popover can be closed, no app can be reading the virtual mic, and
    /// PRISM still has to be hearing the room — otherwise the transcript
    /// stops the moment the user looks away from it.
    ///
    /// Flipped only from `meeting.phase`, and every flip reconciles, in the
    /// same shape as `virtualMicInUse`.
    private var transcriptionActive = false

    /// §5.33. Read once at launch and held in memory: every `SecItem` call
    /// blocks the calling thread, and doing that per request would put a
    /// synchronous keychain read on the path of a live answer.
    private var cachedAnthropicKey = ""
    /// Published so the pane can show "saved" without the key itself ever
    /// reaching a view.
    @Published public private(set) var hasAnthropicKey = false
    /// §5.32 far-end capture. Held here so its lifetime matches the app's;
    /// `MeetingSession` starts and stops it.
    private let systemAudioCapture: SystemAudioCapture
    private let noteWriter = MeetingNoteWriter()
    /// One ephemeral URLSession shared by Ask, notes, and live insights.
    /// Providers are cheap request configuration; constructing a fresh
    /// transport for each one threw away connection reuse and kept multiple
    /// networking session objects resident for identical privacy settings.
    private let llmTransport = LLMTransport()

    private var audioCaptureDemand: Bool {
        captureDemand || virtualMicInUse || transcriptionActive
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
            // The source picker is about to be drawn, and windows open and
            // close while PRISM is not looking.
            refreshScreenSources()
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

    /// The camera runs while it is the source, and while a picture-in-picture
    /// layer is looking at it (§5.25) — the two are the same session, so
    /// neither has to know about the other.
    private var wantsCameraCapture: Bool {
        captureDemand && (videoSource.kind == .camera || liveFeedDemand.contains(.camera))
    }

    /// The screen capture, on the same rule, with one addition: no grant, no
    /// session. The framework would raise the system prompt on the user's
    /// behalf, and a prompt nobody asked for is the thing §9 exists to avoid.
    private var wantsScreenCapture: Bool {
        captureDemand && !screenCaptureBlocked
            && permissions.screenRecording == .granted
            && (videoSource.kind != .camera || liveFeedDemand.contains(.screen))
    }

    /// Which feeds a `.live` overlay layer is currently compositing, read off
    /// the live configuration rather than the draft: capture follows what is
    /// on air, not what is being edited.
    private var liveFeedDemand: Set<LiveLayerFeed> {
        guard config.flags(for: .overlay).enabled else { return [] }
        return Set(LiveLayerFeed.allCases.filter { config.overlay.needsLiveFeed($0) })
    }

    /// The screen or window a session would be started on.
    private var screenSelection: VideoSourceSelection {
        videoSource.kind == .camera ? screenFeed : videoSource
    }

    /// Single reconciliation point between demand and the capture hardware.
    /// Call whenever an input to a demand expression changes. Idempotent;
    /// start/stop on an already-started/stopped capture no-ops.
    private func reconcileCaptures() {
        guard started else { return }
        lastLiveFeedDemand = liveFeedDemand
        if wantsCameraCapture {
            if !cameraCapture.isRunning, permissions.camera == .granted {
                startCamera()
            }
        } else {
            cameraCapture.stop()
            pipeline?.liveFeeds.clear(.camera)
        }
        if wantsScreenCapture {
            let request = (screenSelection, formatManager.activeFormat)
            if !screenCapture.isRunning
                || activeScreenRequest?.selection != request.0
                || activeScreenRequest?.format != request.1 {
                activeScreenRequest = request
                screenCapture.start(selection: request.0, outputFormat: request.1)
            }
        } else {
            screenCapture.stop()
            activeScreenRequest = nil
            pipeline?.liveFeeds.clear(.screen)
        }
        // §5.23: ScreenCaptureKit's queue is three full-size surfaces the
        // governor has to see before it hands the rest of the ceiling out.
        pipeline?.setScreenSourceActive(wantsScreenCapture)
        if captureDemand {
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
        // §5.28: thawing a picture presence froze is the user saying they are
        // back. Routed through the release rather than handled here so the
        // mute that went with the freeze comes off too — a user who unfroze
        // themselves and stayed silently muted would have no way to connect
        // the two.
        if isFrozen, presenceAction == .freeze {
            releasePresence()
            return
        }
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
        // §5.17: unmuting resolves the watch immediately rather than waiting
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
        // Video carries a second, tighter cap: past three decoders the memory
        // budget (§7) is the binding constraint, and a fourth video layer
        // would be added to the list and then silently never composited.
        if isVideo,
           editingConfig.overlay.layers.filter({ $0.sourceKind == .video }).count
               >= OverlaySettings.maxVideoLayers {
            warning = WarningMessage(
                text: "PRISM plays up to \(OverlaySettings.maxVideoLayers) video layers at once")
            return
        }
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

    // MARK: - Intents: text layers (§5.26)

    /// A caption, centred, at the size the style quotes. Seeded with a word
    /// rather than left blank: an empty text layer draws nothing at all
    /// (`isRenderable`), so a new one would appear in the list and change
    /// nothing on air, which is the one thing a control must never do.
    public func addTextLayer() {
        var style = OverlayTextStyle()
        style.string = "Text"
        style.plate = .blur
        addTextLayer(named: "Text", style: style, offsetY: 0)
    }

    /// §5.26 — the name banner, as two fields. Everything else about it is
    /// decided here, because "lower third" already names the plate, the
    /// alignment and the height; asking someone to rebuild that out of a
    /// generic layer every time is asking them to do the app's job.
    public func addLowerThird() {
        var style = OverlayTextStyle()
        style.string = "Your Name"
        style.subtitle = "What you do"
        style.plate = .solid
        style.alignment = .leading
        style.fontSize = 44
        // Left edge a twentieth of the way in, and the plate sitting in the
        // lower third of the frame — which is what the name means.
        addTextLayer(named: "Lower third", style: style,
                     offsetX: -0.9, offsetY: 0.55)
    }

    private func addTextLayer(named name: String,
                              style: OverlayTextStyle,
                              offsetX: Double = 0,
                              offsetY: Double) {
        guard editingConfig.overlay.layers.count < OverlaySettings.maxLayers else {
            warning = WarningMessage(
                text: "PRISM composites up to \(OverlaySettings.maxLayers) layers at once")
            return
        }
        // No key: the rasteriser hands the compositor real alpha, and a
        // chroma key over antialiased glyphs would eat their edges.
        let layer = OverlayLayer(name: name,
                                 sourceKind: .text,
                                 keyMode: .none,
                                 offsetX: offsetX,
                                 offsetY: offsetY,
                                 text: style)
        updateEditing { cfg in
            cfg.overlay.layers.append(layer)
            var flags = cfg.flags(for: .overlay)
            flags.enabled = true
            cfg.flags[.overlay] = flags
        }
    }

    public func updateOverlayText(_ id: UUID,
                                  _ mutate: (inout OverlayTextStyle) -> Void) {
        updateOverlayLayer(id) { mutate(&$0.text) }
    }

    // MARK: - The one replay transport (§5.9–§5.14)

    /// The single entry point to ReplayPlayer's transport. Everything that
    /// starts it — a replay, the away loop, the lag switch, the bad
    /// connection's delay — comes through here, and the flags every surface
    /// reads are then derived from the claimant rather than set by hand.
    ///
    /// The player is one transport: `begin()` re-bases it on the newest
    /// buffered frame, so the previous claimant's picture is already gone by
    /// the time this returns. A claim that left another claimant's flag
    /// standing would leave the menu bar saying "Away" over delayed live
    /// camera. Deriving the flags is what makes that unstateable rather than
    /// merely fixed at four call sites.
    ///
    /// The flags are dropped only on a start that actually succeeded: a
    /// refused start leaves whatever was playing playing, and the app has to
    /// keep saying so. Nothing here calls `stop()` — stopping the player
    /// after `begin` has claimed it would tear down the substitution we just
    /// asked for.
    @discardableResult
    private func claimReplayTransport(
        for claimant: ReplayTransportClaim.Claimant,
        start: (ReplayPlayer) -> Bool) -> Bool {
        guard let pipeline else { return false }
        let standing = ReplayTransportClaim(isAway: isAway,
                                            isLagging: isLagging,
                                            isCatchingUp: isCatchingUp,
                                            connectionEngagedLag: connectionEngagedLag)
        guard pipeline.startReplayTransport(start) else { return false }

        let claimed = ReplayTransportClaim.claimed(by: claimant)
        if isAway != claimed.isAway { isAway = claimed.isAway }
        if isLagging != claimed.isLagging { isLagging = claimed.isLagging }
        if isCatchingUp != claimed.isCatchingUp { isCatchingUp = claimed.isCatchingUp }
        connectionEngagedLag = claimed.connectionEngagedLag

        let release = standing.release
        if release.loop {
            presenceYieldsTheLoop()
            if awayMutedByUs {
                awayMutedByUs = false
                if isMuted { toggleMute() }
            }
        }
        if release.delayLine {
            // Zeroed here rather than left to the new claimant: a lag sets its
            // own delay immediately after this returns, and everything else
            // has to hear live audio again.
            audioCapture.delaySeconds = 0
        }
        return true
    }

    /// §5.14 — whether the bad connection's optional delay half may take the
    /// transport. It never takes it from a picture the user deliberately put
    /// on air.
    private var replayTransportIsFreeForTheConnection: Bool {
        ReplayTransportClaim.connectionMayClaimTransport(
            mode: replayMode,
            standing: ReplayTransportClaim(isAway: isAway,
                                           isLagging: isLagging,
                                           isCatchingUp: isCatchingUp,
                                           connectionEngagedLag: connectionEngagedLag))
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
        guard claimReplayTransport(for: .replay, start: {
            $0.startReplay(rate: studio.replay.clampedPlaybackRate)
        }) else {
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
            // §5.28: turning off a loop presence started is the user saying
            // they are back, and it has to release the mute presence engaged
            // with it rather than leaving them silently off air.
            if presenceAction == .loop {
                releasePresence()
                return
            }
            endAway(returnToLive: true)
        } else {
            beginAway()
        }
    }

    /// Engages the away loop, reporting whether it actually started. The
    /// chord wants the explanation in the warning row; presence automation
    /// (§5.28) wants the answer, because a failure there means falling back
    /// to a held frame rather than telling the empty chair about it.
    @discardableResult
    private func beginAway(explaining: Bool = true) -> Bool {
        guard let pipeline else { return false }
        guard studio.replay.isArmed else {
            // First use with the buffer off: arm it and say so. The loop
            // cannot start yet — nothing is recorded — but the next press
            // will work, which beats a control that does nothing.
            if studio.away.armsBufferOnFirstUse {
                studio.replay.isArmed = true
                if explaining {
                    warning = WarningMessage(
                        text: "Rolling buffer on. The away loop needs a few seconds of video first.")
                }
            } else if explaining {
                warning = WarningMessage(
                    text: "Turn on the rolling buffer to use the away loop",
                    action: .armBuffer)
            }
            return false
        }
        // Stepping away supersedes a delay; the claim below drops its flags
        // and its audio delay line.
        guard claimReplayTransport(for: .away, start: {
            $0.startAway(loopSeconds: studio.away.clampedLoopSeconds,
                         crossfadeMs: studio.away.clampedCrossfadeMs)
        }) else {
            if explaining {
                warning = WarningMessage(
                    text: "Not enough video buffered yet for an away loop")
            }
            return false
        }
        pipeline.beginCrossfade(durationMs: 300)
        if studio.away.mutesAudio, !isMuted {
            awayMutedByUs = true
            toggleMute()
        }
        refreshReplayState()
        updateMenuBarState()
        return true
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
        // The pipeline is a precondition, not a participant: the transport is
        // claimed through claimReplayTransport below.
        guard pipeline != nil, !isLagging else { return }
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
        let requested = studio.lag.delaySeconds
        // The delay is held in the rolling buffer, so it cannot exceed it.
        let available = min(requested, studio.replay.clampedBufferSeconds - 0.5)
        // Away and lag are both "what is on air is not live"; the newer
        // deliberate intent wins, and the claim drops the loop's flag and the
        // mute it engaged.
        guard available > 0.1,
              claimReplayTransport(for: .lag, start: {
                  $0.startLag(delaySeconds: available)
              }) else {
            warning = WarningMessage(text: "Nothing buffered to delay yet")
            return
        }
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
        if studio.connection.addsLag {
            if !replayTransportIsFreeForTheConnection {
                // Something the user deliberately put on air already owns the
                // transport. Starting the delay would re-base the player and
                // destroy it — an away loop replaced by delayed LIVE camera,
                // with nobody in front of the camera to notice. So the stunt
                // degrades the picture that is already there and says the
                // delay is the half it could not add.
                if isAway {
                    warning = WarningMessage(
                        text: "Degrading the picture. The away loop stays on air")
                }
            } else if !studio.replay.isArmed {
                warning = WarningMessage(
                    text: "Degrading the picture. Turn on the rolling buffer to fall behind live too",
                    action: .armBuffer)
            } else {
                let available = min(studio.connection.lagSeconds,
                                    studio.replay.clampedBufferSeconds - 0.5)
                if available > 0.1,
                   claimReplayTransport(for: .connectionLag, start: {
                       $0.startLag(delaySeconds: available)
                   }) {
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
        let engaging = PanicHold.engaging(settings: studio.panic,
                                          isFrozen: isFrozen, isMuted: isMuted)
        panicHold = engaging.hold
        if engaging.mute { toggleMute() }
        if engaging.freeze { toggleFreeze() }
        updateMenuBarState()
    }

    private func releasePanic() {
        guard isPanicked else { return }
        isPanicked = false

        // Only what panic engaged, and only while it is still true: a freeze
        // the user set themselves before panicking is theirs to release, and
        // thawing it here would put live video on air without being asked.
        let releasing = panicHold.releasing(isFrozen: isFrozen, isMuted: isMuted)
        panicHold = PanicHold()
        if releasing.thaw { toggleFreeze() }
        if releasing.unmute { toggleMute() }
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

    // MARK: - Intents: capture (§5.15, §5.16)

    /// Effects on air that a saved clip would strip away, exposing what they
    /// hide. Empty when nothing is being concealed. Read by both surfaces so
    /// the standing caption and the confirmation cannot disagree.
    public var clipConcealments: [String] {
        ClipDisclosure.concealments(in: config, isPanicked: isPanicked)
    }

    /// ⌥⌘S — write the rolling buffer to a .mov (§5.15).
    ///
    /// The buffer records the camera upstream of every effect, so a save is
    /// a remux of frames the call never saw in that form. When something on
    /// air exists to hide the room, the write does not happen until the user
    /// has read a sentence saying so and said yes.
    public func saveLastSeconds() {
        guard let pipeline else { return }
        let samples = pipeline.replayBuffer.snapshot()
        guard let format = pipeline.replayBuffer.sampleFormatDescription,
              samples.count > 1 else {
            warning = studio.replay.isArmed
                ? WarningMessage(text: "Nothing buffered to save yet")
                : WarningMessage(text: "Turn the rolling buffer on to save the last seconds",
                                 action: .armBuffer)
            return
        }
        guard capturePhase == .idle else { return }

        let concealed = clipConcealments
        guard concealed.isEmpty || confirmRawCameraSave(hiding: concealed) else { return }
        guard let url = prepareCaptureURL(kind: .clip, fileExtension: "mov") else { return }

        capturePhase = .writing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: CaptureResult
            var summary: String?
            do {
                let plan = try ClipExporter.write(samples: samples,
                                                  formatDescription: format, to: url)
                result = .saved(url)
                // The clip's real length, not the length that was asked for:
                // the buffer is trimmed to a keyframe, so a 10 s window is
                // routinely a 9 s file and saying otherwise invites a bug
                // report.
                summary = String(format: "Saved %.0f s of raw camera",
                                 plan.durationSeconds.rounded())
            } catch {
                result = .failed((error as? CaptureError)?.errorDescription
                                 ?? error.localizedDescription)
            }
            let text = summary
            DispatchQueue.main.async { self?.finishCapture(result, summary: text) }
        }
    }

    /// ⌥⌘⇧S — write one finished frame (§5.16). Pressed during a countdown
    /// it cancels it: the second press of a shutter key is a change of mind
    /// far more often than a second photo.
    public func takeSnapshot() {
        if case .countdown = capturePhase {
            cancelCountdown()
            return
        }
        guard capturePhase == .idle else { return }
        let seconds = studio.capture.clampedCountdownSeconds
        guard seconds > 0 else {
            writeStill()
            return
        }
        capturePhase = .countdown(remaining: seconds)
        countdownTimer?.invalidate()
        // .common mode: the countdown has to keep counting while a menu is
        // tracking or a panel is up, which is exactly when someone uses it.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickCountdown() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func tickCountdown() {
        guard case .countdown(let remaining) = capturePhase else {
            cancelCountdown()
            return
        }
        guard remaining <= 1 else {
            capturePhase = .countdown(remaining: remaining - 1)
            return
        }
        countdownTimer?.invalidate()
        countdownTimer = nil
        writeStill()
    }

    public func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        if case .countdown = capturePhase { capturePhase = .idle }
    }

    /// nil restores ~/Movies/PRISM.
    public func setCaptureFolder(_ url: URL?) {
        studio.capture.folderPath = url?.path
        if warning?.action == .chooseCaptureFolder {
            warning = nil
        }
    }

    public func dismissNotice() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        notice = nil
    }

    private func writeStill() {
        guard let pipeline, let frame = pipeline.stillFrame() else {
            capturePhase = .idle
            warning = WarningMessage(text: CaptureError.noPicture.errorDescription ?? "")
            return
        }
        let format = studio.capture.format
        guard let url = prepareCaptureURL(kind: .still,
                                          fileExtension: format.fileExtension) else {
            capturePhase = .idle
            return
        }
        capturePhase = .writing
        // The frame is a pool buffer; holding it here keeps its IOSurface out
        // of the free list until the encoder has copied the pixels out, which
        // is the whole reason it is passed rather than the texture.
        let sendableFrame = SendableStillBuffer(value: frame)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: CaptureResult
            do {
                try StillExporter.write(sendableFrame.value, format: format, to: url)
                result = .saved(url)
            } catch {
                result = .failed((error as? CaptureError)?.errorDescription
                                 ?? error.localizedDescription)
            }
            DispatchQueue.main.async { self?.finishCapture(result, summary: nil) }
        }
    }

    /// Resolves and proves the destination *before* anything is encoded — a
    /// capture that fails after the work is done has already cost the user
    /// the moment it was trying to keep.
    private func prepareCaptureURL(kind: CaptureDestination.Kind,
                                   fileExtension: String) -> URL? {
        do {
            let folder = try CaptureDestination.prepare(studio.capture.folderURL)
            let name = CaptureDestination.fileName(kind: kind, date: Date(),
                                                   fileExtension: fileExtension)
            return CaptureDestination.uniqueURL(in: folder, fileName: name)
        } catch {
            warning = WarningMessage(
                text: (error as? CaptureError)?.errorDescription ?? error.localizedDescription,
                action: .chooseCaptureFolder)
            return nil
        }
    }

    /// A saved file the user cannot find is a file that was not saved, so
    /// every success carries the URL. Successes expire on their own; the
    /// warning row, which describes a standing problem, does not.
    private func finishCapture(_ result: CaptureResult, summary: String?) {
        capturePhase = .idle
        switch result {
        case .saved(let url):
            notice = NoticeMessage(text: summary ?? "Saved \(url.lastPathComponent)",
                                   symbolName: "checkmark.circle",
                                   fileURL: url)
            noticeTimer?.invalidate()
            let timer = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.notice = nil }
            }
            RunLoop.main.add(timer, forMode: .common)
            noticeTimer = timer
            // The chords work with every PRISM surface closed, so the only
            // place a hotkey capture can be acknowledged is Notification
            // Centre.
            if !popoverOpen {
                postNotification(body: "Saved \(url.lastPathComponent)")
            }
        case .failed(let reason):
            warning = WarningMessage(text: reason)
        }
    }

    /// The one confirmation in PRISM that is deliberately modal (§5.15).
    ///
    /// Everything else this app does is undoable or on air where the user can
    /// see it. This writes a file of the room somebody chose to hide, and it
    /// is triggered by a global chord that works with every window closed —
    /// there is no surface a passive warning could appear on. Cancel is the
    /// default button: a return key pressed out of habit must not disclose
    /// anything.
    private func confirmRawCameraSave(hiding names: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "This clip will show the room behind you."
        alert.informativeText = """
            PRISM records the camera before effects, so the saved file has no \
            \(ClipDisclosure.phrase(names)) — and no sound. Nobody in your call sees \
            this file, but whoever you send it to sees everything the camera did.
            """
        alert.addButton(withTitle: "Save the raw camera")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // The sections below are landing zones, one per feature still to be
    // built, and empty on purpose. Nine tracks append their intents into this
    // one file; disjoint regions are the difference between nine clean
    // additions and nine edits to the same hunk.

    // MARK: - Intents: screen source (§5.24, §5.25)

    /// ⌥⌘D. Straight to the last screen and straight back, because the point
    /// of the chord is that it is faster than the picker — and a toggle that
    /// re-asked which screen every time would not be.
    public func toggleScreenSource() {
        selectVideoSource(videoSource.kind == .camera ? screenFeed : .camera)
    }

    /// The one place the source changes. Everything else — the pickers, the
    /// chord, the fallback when a window closes — comes through here, so the
    /// capture sessions, the menu bar, the memory plan and the persisted pick
    /// cannot drift apart.
    public func selectVideoSource(_ selection: VideoSourceSelection) {
        if selection.kind != .camera, !ensureScreenRecording() { return }
        guard selection != videoSource else { return }
        videoSource = selection
        sourceRoute.set(selection.kind)
        if selection.kind != .camera {
            screenFeed = selection
            // Only a pick clears the block. Falling back to the camera after
            // a window closed must not, or a picture-in-picture of that same
            // window would rebuild the failing stream on the way past.
            screenCaptureBlocked = false
        }
        // Whatever was on air a moment ago is not the source any more; a
        // stale frame left in a layer would be a picture of the past.
        pipeline?.liveFeeds.clear(.camera)
        pipeline?.liveFeeds.clear(.screen)
        // A source change replaces every pixel, so it fades rather than cuts
        // — the same 200 ms a preset switch gets (§5.5).
        pipeline?.beginCrossfade(durationMs: 200)
        persistVideoSource()
        refreshScreenRecordingNeed()
        reconcileCaptures()
        // §5.28: presence watches the camera, so a screen taking over is a
        // reason to stop watching — and to release anything presence is
        // currently holding, since it can no longer see whether the user
        // came back.
        updatePresenceWatching()
        // §5.31: and there are no hands in a screen share either.
        updateGestureWatching()
        sessionLog.record(.device, "Source: \(videoSourceLogName)")
        updateMenuBarState()
    }

    /// Which screen a picture-in-picture of "the screen" shows, for the case
    /// the source picker cannot answer: the camera is on air and the screen
    /// is the layer. Retargets the source itself when the screen *is* the
    /// source, so there is one control and never two disagreeing answers.
    public func selectScreenFeed(_ selection: VideoSourceSelection) {
        guard selection.kind != .camera else { return }
        if videoSource.kind != .camera {
            selectVideoSource(selection)
            return
        }
        guard selection != screenFeed else { return }
        guard ensureScreenRecording() else { return }
        screenFeed = selection
        screenCaptureBlocked = false
        pipeline?.liveFeeds.clear(.screen)
        persistVideoSource()
        reconcileCaptures()
    }

    /// §5.25 — you over your screen, or your screen over you, whichever way
    /// round the source currently is. Deliberately one action rather than a
    /// choice: the only picture-in-picture worth having is of the feed that
    /// is not already the picture (§8.7).
    public func addPictureInPicture() {
        let feed: LiveLayerFeed = videoSource.kind == .camera ? .screen : .camera
        if feed == .screen, !ensureScreenRecording() { return }
        guard editingConfig.overlay.layers.count < OverlaySettings.maxLayers else {
            warning = WarningMessage(
                text: "PRISM composites up to \(OverlaySettings.maxLayers) layers at once")
            return
        }
        // Bottom right at just over a quarter width: the corner a call
        // application would have put it in, at the size it would have used.
        // A live feed carries its own alpha-free rectangle, so no key.
        let layer = OverlayLayer(name: feed == .camera ? "Camera" : "Screen",
                                 sourceKind: .live,
                                 keyMode: .none,
                                 scale: 0.28,
                                 offsetX: 0.62,
                                 offsetY: 0.62,
                                 liveFeed: feed)
        screenCaptureBlocked = false
        updateEditing { cfg in
            cfg.overlay.layers.append(layer)
            var flags = cfg.flags(for: .overlay)
            flags.enabled = true
            cfg.flags[.overlay] = flags
        }
    }

    /// Asks for the grant and nothing else, for the surfaces that offer it
    /// beside an empty picker. Deliberately not "pick a screen": a button
    /// labelled Allow must not also put a screen on air.
    public func requestScreenRecordingAccess() {
        ensureScreenRecording()
    }

    /// Re-reads what is shareable. Refused without the grant rather than
    /// prompting: this runs whenever a picker is drawn, and enumerating
    /// raises the system prompt.
    public func refreshScreenSources() {
        guard permissions.screenRecording == .granted else {
            if !screenSources.isEmpty { screenSources = [] }
            return
        }
        Task { @MainActor [weak self] in
            let list = await ScreenCapture.shareableSources()
            guard let self, list != self.screenSources else { return }
            self.screenSources = list
        }
    }

    /// What the source is called, for the status line and the session log.
    /// Falls back to the kind when the source has gone: naming a window that
    /// has closed is exactly the sentence a user needs.
    public var videoSourceName: String {
        guard videoSource.kind != .camera else {
            return cameraCapture.currentDeviceName ?? "Camera"
        }
        return screenSources.first { $0.id == videoSource.sourceID }?.displayName
            ?? screenCapture.currentSourceName
            ?? videoSource.kind.displayName
    }

    /// The same name for the §5.21 session log, which the user exports as a
    /// file and sends to strangers. A window's title is the document they
    /// had open, so the log gets the application and not the title — see
    /// `ScreenSourceInfo.logName`.
    public var videoSourceLogName: String {
        guard videoSource.kind != .camera else {
            return cameraCapture.currentDeviceName ?? "Camera"
        }
        return screenSources.first { $0.id == videoSource.sourceID }?.logName
            ?? screenCapture.currentSourceLogName
            ?? videoSource.kind.displayName
    }

    /// Returns whether a screen may be captured, asking for the grant the
    /// first time and pointing at System Settings after that. The prompt is
    /// only ever raised from here — that is, only from an intent the user
    /// expressed.
    @discardableResult
    private func ensureScreenRecording() -> Bool {
        setup.screenRecordingNeeded = true
        if permissions.screenRecording == .notDetermined {
            permissions.requestScreenRecording()
        }
        setup.screenRecording = permissions.screenRecording
        guard permissions.screenRecording != .granted else { return true }
        warning = WarningMessage(
            text: "PRISM needs Screen Recording. Allow it in System Settings, then reopen PRISM.",
            action: .openScreenRecordingSettings)
        return false
    }

    /// The grant is demanded by the feature, not by the app (§9): the setup
    /// row appears when something is actually asking for a screen and goes
    /// away with it.
    private func refreshScreenRecordingNeed() {
        let needed = videoSource.kind != .camera || liveFeedDemand.contains(.screen)
        if setup.screenRecordingNeeded != needed {
            setup.screenRecordingNeeded = needed
        }
    }

    /// A window closed, a display was unplugged, or the stream could not be
    /// built. §3.2's placeholder rule is the precedent: never a black frame.
    /// The camera is the only source that exists without a grant, so it is
    /// where a lost screen lands.
    private func handleScreenCaptureStopped(_ stop: ScreenCaptureStop) {
        let message = stop.message
        screenCaptureBlocked = true
        activeScreenRequest = nil
        pipeline?.liveFeeds.clear(.screen)
        // The user is shown the window's own title; the log is not (§5.21).
        sessionLog.record(.device, stop.logMessage)
        warning = WarningMessage(
            text: message,
            action: permissions.screenRecording == .granted
                ? .none : .openScreenRecordingSettings)
        postNotification(body: message)
        if videoSource.kind != .camera {
            selectVideoSource(.camera)
        } else {
            reconcileCaptures()
        }
    }

    /// Launch-time resolution of the persisted pick. A display id survives a
    /// reboot and a window id does not, which is the whole reason the
    /// selection stores an id and nothing else — an unresolvable one falls
    /// back to the camera rather than to a black frame nobody can explain.
    private func resolvePersistedSource() async {
        guard videoSource.kind != .camera else { return }
        guard permissions.screenRecording == .granted else {
            revertToCamera(logging: "Screen sharing needs permission PRISM does not have; using the camera.")
            return
        }
        let list = await ScreenCapture.shareableSources()
        screenSources = list
        guard !list.contains(where: { $0.id == videoSource.sourceID }) else { return }
        revertToCamera(logging: "The \(videoSource.kind.displayName.lowercased()) PRISM was sharing is gone; using the camera.")
    }

    /// The quiet fallback. Deliberately not a warning: this happens at launch
    /// after a reboot, every time, for anyone who shared a window — and a
    /// warning that fires on a schedule is one people stop reading.
    private func revertToCamera(logging message: String) {
        sessionLog.record(.device, message)
        selectVideoSource(.camera)
    }

    // MARK: - Intents: meetings (§5.32)

    /// ⌃⌥⌘M. Starts transcribing this call, or stops and files the
    /// transcript.
    public func toggleMeeting() {
        if meeting.phase.isRunning {
            stopMeeting()
        } else {
            startMeeting()
        }
    }

    public func startMeeting() {
        guard !meeting.phase.isRunning else { return }
        // The switch and the action ask one question between them (§8.7):
        // pressing the chord on a machine where transcription has never
        // been turned on turns it on, rather than doing nothing and
        // explaining why.
        if !studio.meeting.transcribes {
            studio.meeting.transcribes = true
            meeting.apply(studio.meeting)
        }
        guard permissions.microphone == .granted else {
            warning = WarningMessage(
                text: "PRISM needs microphone access to transcribe this call.")
            return
        }
        meeting.start()
        reconcileTranscription()
        sessionLog.record(.device, "Started transcribing (\(farEndLogPhrase))")
    }

    /// The notification action arrives here. Keeping it separate from
    /// detection is the consent boundary: observing a client can only post a
    /// question, while this explicit user action may start the existing mode.
    public func startMeeting(fromPromptFor signingID: String) {
        guard MeetingClientCatalog.candidate(signingID: signingID) != nil else { return }
        clearMeetingJoinPromptsHandler?()
        if studio.meeting.farEnd == .chosenApp {
            studio.meeting.farEndBundleID = signingID
        }
        startMeeting()
    }

    public func stopMeeting() {
        guard meeting.phase.isRunning else { return }
        let minutes = Int(meeting.elapsed / 60)
        // Read before `stop()`: the phase change resets the counters.
        let insightSummary = insights.meetingSummary
        meeting.stop()
        reconcileTranscription()
        sessionLog.record(.device, "Stopped transcribing after \(minutes) min")
        // §5.34, counts only. Never a word of what a card said.
        if let insightSummary {
            sessionLog.record(.device, insightSummary)
        }
    }

    /// The §5.21 redaction rule at its sharpest. A log row may say PRISM was
    /// transcribing and which application it was listening to — both things
    /// the pickers already show. It may never say a word of what was heard.
    private var farEndLogPhrase: String {
        switch studio.meeting.farEnd {
        case .off: return "you only"
        case .everything: return "you and this Mac's audio"
        case .chosenApp:
            let name = studio.meeting.farEndBundleID ?? "an app"
            return "you and \(name)"
        }
    }

    public func setMeetingTranscribes(_ on: Bool) {
        guard on != studio.meeting.transcribes else { return }
        studio.meeting.transcribes = on
        if !on, meeting.phase.isRunning { stopMeeting() }
    }

    public func setMeetingModel(_ shortName: String) {
        guard shortName != studio.meeting.model else { return }
        studio.meeting.model = shortName
    }

    public func setMeetingLanguage(_ language: String) {
        studio.meeting.language = language
    }

    public func setMeetingFarEnd(_ source: FarEndSource) {
        guard source != studio.meeting.farEnd else { return }
        studio.meeting.farEnd = source
        if source != .off, permissions.screenRecording != .granted {
            // Asked for rather than demanded: mic-only transcription is a
            // complete feature, and the pane explains that Screen Recording
            // is macOS's name for the permission covering another
            // application's *sound*. PRISM captures no pixels for this.
            Task { [weak self] in
                _ = self?.permissions.requestScreenRecording()
            }
        }
    }

    public func setMeetingFarEndApp(_ bundleID: String?) {
        studio.meeting.farEndBundleID = bundleID
    }

    public func setMeetingFarEndLabel(_ label: String) {
        studio.meeting.farEndLabel = label
    }

    public func setMeetingSilenceRMS(_ value: Double) {
        studio.meeting.silenceRMS = value
    }

    public func setMeetingSavesTranscript(_ saves: Bool) {
        studio.meeting.savesTranscript = saves
    }

    public func setMeetingTemplate(_ name: String) {
        studio.meeting.templateName = name
    }

    /// Arms or disarms the tap and the drain, exactly as
    /// `reconcileInputLevel` does for the meter. Gated on the session
    /// actually listening, so an armed tap and a running drain can only
    /// exist while there is a meeting to feed.
    private func reconcileTranscription() {
        let active = meeting.phase.isRunning
        guard active != transcriptionActive else { return }
        transcriptionActive = active
        reconcileCaptures()
    }

    // MARK: - Intents: assistant (§5.33)

    /// §5.33 — puts the answer panel on screen, or takes it away. The same
    /// shape as the prompter's handler, and for the same reason: AppState
    /// may not reference the UI layer, so the app delegate installs this.
    public var assistantPanelHandler: ((Bool) -> Void)?

    public func setAssistantEnabled(_ enabled: Bool) {
        guard enabled != studio.assistant.isEnabled else { return }
        studio.assistant.isEnabled = enabled
        if !enabled { assistant.cancel() }
        assistantPanelHandler?(enabled)
    }

    /// ⌃⌥⌘A. Opens the panel if it is closed; otherwise asks — the detected
    /// question if there is one, and a "what should I know" summary if not.
    ///
    /// It never dismisses. See `ShortcutAction.ask`.
    public func askAssistant(_ text: String? = nil) {
        guard studio.assistant.provider != .none else {
            warning = WarningMessage(
                text: "Choose an AI provider in the Assistant pane first.")
            return
        }
        if !studio.assistant.isEnabled {
            setAssistantEnabled(true)
        }
        guard let provider = makeProvider() else {
            warning = WarningMessage(
                text: LLMError.missingKey.errorDescription ?? "That provider isn't set up yet.")
            return
        }
        assistant.ask(text, provider: provider,
                      transcriptTail: meeting.transcriptTail(
                        turns: studio.assistant.clampedContextTurns))
    }

    public func setAssistantProvider(_ kind: LLMProviderKind) {
        guard kind != studio.assistant.provider else { return }
        studio.assistant.provider = kind
        if kind == .none { assistant.cancel() }
    }

    public func setAssistantModel(_ model: String) {
        switch studio.assistant.provider {
        case .anthropic: studio.assistant.anthropicModel = model
        case .ollama: studio.assistant.ollamaModel = model
        case .openAICompatible: studio.assistant.compatibleModel = model
        case .none: break
        }
    }

    public func setAssistantBaseURL(_ url: String) {
        studio.assistant.compatibleBaseURL = url
    }

    public func setAssistantOpacity(_ value: Double) {
        studio.assistant.opacity = value
    }

    public func setAssistantAnchor(_ anchor: AssistantAnchor) {
        studio.assistant.anchor = anchor
    }

    public func setAssistantContextTurns(_ turns: Int) {
        studio.assistant.contextTurns = turns
    }

    public func setAssistantHighlightsQuestions(_ on: Bool) {
        studio.assistant.highlightsQuestions = on
    }

    public func setAssistantAboutMe(_ text: String) {
        studio.assistant.aboutMe = text
    }

    // MARK: - Intents: live insights (§5.34)

    /// ⌃⌥⌘I. A toggle, unlike the ask chord — see `ShortcutAction.insights`.
    public func toggleLiveInsights() {
        setLiveInsights(!studio.assistant.liveInsights)
    }

    /// Turning the mode on turns on what it needs (§8.7): the panel, if it
    /// is not up, and listening, if it is not running. Turning it off leaves
    /// both alone — the transcript is still wanted for the notes, and a panel
    /// the user may be reading an answer on is not this switch's to close.
    ///
    /// Refused, with the reason in the warning row, when there is nowhere to
    /// send a request. A mode that sends on its own must not be switchable
    /// into a state where every attempt fails quietly.
    public func setLiveInsights(_ on: Bool) {
        guard on else {
            guard studio.assistant.liveInsights else { return }
            studio.assistant.liveInsights = false
            sessionLog.record(.device, "Live insights off")
            return
        }
        guard studio.assistant.provider != .none else {
            warning = WarningMessage(
                text: "Choose an AI provider in the Assistant pane first.")
            return
        }
        guard makeProvider() != nil else {
            warning = WarningMessage(
                text: LLMError.missingKey.errorDescription ?? "That provider isn't set up yet.")
            return
        }
        if !studio.assistant.liveInsights {
            studio.assistant.liveInsights = true
            // The provider's name and nothing else — §5.21. Never a card.
            sessionLog.record(.device,
                              "Live insights on (\(studio.assistant.provider.displayName))")
        }
        if !studio.assistant.isEnabled { setAssistantEnabled(true) }
        if !meeting.phase.isRunning { startMeeting() }
    }

    public func setInsightPace(_ pace: InsightPace) {
        studio.assistant.insightPace = pace
    }

    public func setInsightKind(_ kind: InsightKind, enabled: Bool) {
        if enabled {
            studio.assistant.insightKinds.insert(kind)
        } else {
            studio.assistant.insightKinds.remove(kind)
        }
    }

    public func dismissInsight(_ id: String) { insights.dismiss(id) }
    public func pinInsight(_ id: String) { insights.togglePin(id) }
    public func clearInsights() { insights.clearAll() }

    /// "More" on a card goes through the typed path, so the rolling
    /// transcript travels with it: the card is about the call, and the
    /// follow-up is elliptical by construction.
    public func askAboutInsight(_ id: String) {
        guard let card = insights.card(id: id) else { return }
        askAssistant("More about \"\(card.title)\". You suggested: \(card.body)")
    }

    /// Stores the key in the Keychain and caches it in memory.
    ///
    /// Cached because every `SecItem` call blocks the calling thread, and a
    /// keychain read per request would put that on the path of a live
    /// answer. Never written to `StudioSettings` — that is JSON in a plist
    /// any process running as this user can read.
    @discardableResult
    public func setAnthropicKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            _ = Keychain.remove(account: Keychain.Account.anthropic)
            cachedAnthropicKey = ""
            hasAnthropicKey = false
            return true
        }
        switch Keychain.set(trimmed, account: Keychain.Account.anthropic) {
        case .success:
            cachedAnthropicKey = trimmed
            hasAnthropicKey = true
            return true
        case .failure(let error):
            warning = WarningMessage(text: error.errorDescription
                                     ?? "PRISM couldn't save that key.")
            return false
        }
    }

    /// Builds the provider the settings currently describe, or nil when it
    /// is not usable yet.
    func makeProvider() -> LLMProvider? {
        switch studio.assistant.provider {
        case .none:
            return nil
        case .anthropic:
            guard !cachedAnthropicKey.isEmpty else { return nil }
            return AnthropicProvider(model: studio.assistant.anthropicModel,
                                     apiKey: cachedAnthropicKey,
                                     transport: llmTransport)
        case .ollama:
            guard !studio.assistant.ollamaModel.isEmpty else { return nil }
            return OllamaProvider(model: studio.assistant.ollamaModel,
                                  transport: llmTransport)
        case .openAICompatible:
            guard studio.assistant.providerIsConfigured else { return nil }
            return OpenAICompatibleProvider(
                baseURL: studio.assistant.compatibleBaseURL,
                model: studio.assistant.compatibleModel,
                transport: llmTransport)
        }
    }

    // MARK: - Intents: meeting notes (§5.32)

    /// Writes notes from the transcript. The one place §5.32 reaches the
    /// network, and only because the user pressed a button that says so.
    public func writeMeetingNotes() {
        guard let record = meeting.recordForNotes(), !record.words.isEmpty else {
            warning = WarningMessage(text: "There's no transcript to write notes from yet.")
            return
        }
        guard let provider = makeProvider() else {
            warning = WarningMessage(
                text: "Choose an AI provider in the Assistant pane first.")
            return
        }
        meeting.setNotesPhase(.writing, progress: "Preparing the transcript…")
        let started = Date()
        noteWriter.write(
            record: record,
            template: NoteTemplate.named(studio.meeting.templateName),
            provider: provider,
            language: studio.meeting.language,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.meeting.setNotesProgress(progress)
                }
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let notes):
                    self.meeting.applyNotes(markdown: notes.markdown,
                                            title: notes.title,
                                            items: notes.actionItems)
                    let seconds = Int(Date().timeIntervalSince(started))
                    // Names the model and the time. Never a word of what it
                    // wrote — §5.21's rule does not bend for the feature
                    // that produces the most sensitive text in the app.
                    self.sessionLog.record(
                        .degradation,
                        "Wrote meeting notes with \(provider.displayName) in \(seconds)s")
                case .failure(let error):
                    self.meeting.setNotesPhase(.failed(error.localizedDescription))
                    self.sessionLog.record(.degradation, "Meeting notes failed")
                }
            })
    }

    public func cancelMeetingNotes() {
        noteWriter.cancel()
        meeting.setNotesPhase(.none)
    }

    // MARK: - Intents: prompter (§5.27)

    /// ⌃⌥⌘T. Opens the panel if it is closed, and otherwise runs or holds the
    /// scroll — because the thing you need a chord for is the one you reach
    /// for mid-sentence, and that is "stop, I've lost my place", never
    /// "dismiss". Putting the prompter away is a click on a panel you are
    /// already looking at.
    public func togglePrompter() {
        guard studio.prompter.isEnabled else {
            setPrompterEnabled(true)
            return
        }
        if prompterRunning {
            stopPrompter()
        } else {
            startPrompter()
        }
    }

    /// The one place the panel appears and disappears. Turning it on rewinds
    /// to the first line and starts reading; turning it off stops the scroll
    /// so a prompter reopened later never resumes mid-paragraph into a
    /// meeting that has moved on.
    ///
    /// Deliberately absent from the session log (§5.21): that history answers
    /// "what could the other people see", and the answer here is nothing.
    public func setPrompterEnabled(_ enabled: Bool) {
        guard enabled != studio.prompter.isEnabled else { return }
        studio.prompter.isEnabled = enabled
        if enabled {
            resetPrompter()
            if studio.prompter.isActive { startPrompter() }
        } else {
            stopPrompter()
            resetPrompter()
        }
        prompterPanelHandler?(enabled)
    }

    public func startPrompter() {
        guard studio.prompter.isActive, !prompterRunning else { return }
        prompterRunning = true
    }

    public func stopPrompter() {
        guard prompterRunning else { return }
        prompterRunning = false
    }

    public func resetPrompter() {
        prompterResetToken &+= 1
    }

    /// Editing the script puts the reader back at the top. A scroll position
    /// measured in lines means nothing once the lines have changed, and
    /// landing mid-sentence in a script you have just rewritten is worse than
    /// starting over.
    public func setPrompterScript(_ script: String) {
        guard script != studio.prompter.script else { return }
        studio.prompter.script = script
        resetPrompter()
        if !studio.prompter.isActive { stopPrompter() }
    }

    public func setPrompterSpeed(_ linesPerMinute: Double) {
        studio.prompter.speed = linesPerMinute
    }

    public func setPrompterFontSize(_ points: Double) {
        studio.prompter.fontSize = points
    }

    public func setPrompterOpacity(_ opacity: Double) {
        studio.prompter.opacity = opacity
    }

    public func setPrompterMirrored(_ mirrored: Bool) {
        studio.prompter.isMirrored = mirrored
    }

    public func setPrompterAnchor(_ anchor: PrompterAnchor) {
        studio.prompter.anchor = anchor
    }

    // MARK: - Intents: app rules

    // MARK: - Intents: presence (§5.28)

    /// What happens when the frame empties. Choosing the away loop arms the
    /// rolling buffer, exactly as the first press of ⌥⌘A does (§5.10): the
    /// loop reads from that buffer, and an automation that fires into an
    /// unarmed recorder is an automation that does nothing at the one moment
    /// it was supposed to work. Both surfaces say so beside the control.
    public func setPresenceAction(_ action: PresenceAction) {
        guard action != studio.presence.action else { return }
        studio.presence.action = action
        if action == .loop, !studio.replay.isArmed {
            studio.replay.isArmed = true
        }
    }

    public func setPresenceAwaySeconds(_ seconds: Double) {
        studio.presence.awaySeconds = seconds
    }

    public func setPresenceReturnSeconds(_ seconds: Double) {
        studio.presence.returnSeconds = seconds
    }

    public func setPresenceCoverage(_ coverage: Double) {
        studio.presence.coverage = coverage
    }

    public func setPresenceNotifies(_ notifies: Bool) {
        studio.presence.notifiesWhenAway = notifies
    }

    /// The manual escape, and the reason the notice row carries a button.
    /// Everything presence engaged comes off in one tap, whether or not the
    /// detector agrees the user is back yet — an automatic feature the user
    /// cannot override immediately is worse than no automatic feature.
    public func comeBack() {
        releasePresence()
    }

    /// The demand gate for the whole feature. Presence is watched only while
    /// one of its switches is on AND the camera is the picture: a screen share
    /// has no person in it by construction, and a detector pointed at a slide
    /// deck would decide the user had left within seconds of them starting to
    /// present.
    private func updatePresenceWatching() {
        let watching = studio.presence.isActive && videoSource.kind == .camera
        guard watching != presenceWatching else { return }
        presenceWatching = watching
        pipeline?.setPresenceWatching(watching)
        guard !watching else { return }
        // Standing down means the evidence stops arriving, so anything
        // presence is holding has to come off now — it would otherwise stay
        // on air until the user found the tile themselves.
        releasePresence()
        presenceWatcher.reset()
        lastPresenceSequence = 0
        presence = .unknown
    }

    /// One observation from the detector, turned into an edge by the watcher.
    private func handlePresence(_ sample: PresenceDetector.Sample) {
        guard presenceWatching else { return }
        guard sample.sequence != lastPresenceSequence else { return }
        lastPresenceSequence = sample.sequence

        let transition = presenceWatcher.observe(coverage: sample.coverage,
                                                 settings: studio.presence,
                                                 at: sample.date)
        if presence != presenceWatcher.state { presence = presenceWatcher.state }
        switch transition {
        case .left: presenceDidLeave()
        case .returned: releasePresence()
        case .none: break
        }
    }

    /// The frame has been empty long enough. Fires once per departure, which
    /// is what makes the manual escape stick: turning it off by hand is not
    /// overridden a second later, because there is no second edge until the
    /// user has been seen back in shot and left again.
    private func presenceDidLeave() {
        let line: String
        switch studio.presence.action {
        case .none:
            // The nudge on its own. Nothing changes on air — this is the one
            // presence behaviour that is pure disclosure.
            line = "You're out of frame, and PRISM is still on air."
        case .loop:
            if beginAway(explaining: false) {
                presenceAction = .loop
                line = "You stepped out of frame — the away loop is on air."
            } else {
                // The honest fallback. The loop needs seconds of recorded
                // video and there are none yet; holding the frame is a worse
                // picture of the same promise, and a great deal better than a
                // feature that announced itself and then did nothing.
                engagePresenceFreeze()
                presenceAction = .freeze
                line = "You stepped out of frame — nothing was buffered to loop, so the picture is held."
            }
        case .freeze:
            engagePresenceFreeze()
            presenceAction = .freeze
            line = "You stepped out of frame — the picture is held."
        }
        presenceEngaged = presenceAction != nil
        sessionLog.record(.onAir, line)
        postPresenceNotice(line)
        // The chords and the tiles work with every PRISM surface closed, and
        // this one fires with nobody at the keyboard by definition — so the
        // only place it can be announced is Notification Centre.
        if studio.presence.notifiesWhenAway {
            postNotification(body: line)
        }
        updateMenuBarState()
    }

    private func engagePresenceFreeze() {
        if !isFrozen {
            presenceFrozeByUs = true
            toggleFreeze()
        }
        // The same question the away loop already asks, answered by the same
        // switch (§8.7): stepping away means stepping away, and a held
        // picture over a live microphone is the worse half of both.
        if studio.away.mutesAudio, !isMuted {
            presenceMutedByUs = true
            toggleMute()
        }
    }

    /// A newer intent — a replay, the lag switch — has taken the transport
    /// the away loop was using. Presence drops its claim without undoing
    /// anything, because whatever replaced it *is* the undo, and re-running
    /// the release here would tear down the thing the user just asked for.
    private func presenceYieldsTheLoop() {
        guard presenceAction == .loop else { return }
        presenceAction = nil
        presenceEngaged = false
        if notice?.action == .comeBack { dismissNotice() }
    }

    /// Undoes exactly what presence did, and only while it is still true. A
    /// freeze the user engaged themselves stays engaged; a mute they set
    /// themselves survives them walking back into shot.
    private func releasePresence() {
        if notice?.action == .comeBack { dismissNotice() }
        guard let action = presenceAction else { return }
        presenceAction = nil
        presenceEngaged = false
        switch action {
        case .loop:
            if isAway { endAway(returnToLive: true) }
        case .freeze:
            if presenceFrozeByUs, isFrozen { toggleFreeze() }
        case .none:
            break
        }
        presenceFrozeByUs = false
        if presenceMutedByUs {
            presenceMutedByUs = false
            if isMuted { toggleMute() }
        }
        sessionLog.record(.onAir, "Back in frame")
        updateMenuBarState()
    }

    /// A condition rather than an event, so it is cleared by whoever posted
    /// it rather than by the expiry timer — a "you're out of frame" line that
    /// outlived being out of frame would be the same lie the freeze badge
    /// exists to prevent.
    private func postPresenceNotice(_ text: String) {
        noticeTimer?.invalidate()
        noticeTimer = nil
        notice = NoticeMessage(text: text,
                               symbolName: presenceAction == .loop
                                   ? "moon.zzz.fill" : "person.slash",
                               action: .comeBack)
    }

    // MARK: - Intents: gestures (§5.31)

    /// The master switch. Off means no hand-pose request at all — the demand
    /// closure is the only thing that makes the modality run, and a modality
    /// nothing demands is inert (VisionCoordinatorTests).
    public func setGesturesEnabled(_ enabled: Bool) {
        studio.gestures.isEnabled = enabled
    }

    /// Binding a pose is the same intent as switching that binding on, and
    /// binding it to "Nothing" is the same intent as switching it off — the
    /// LUT / Neutral rule applied a third time. Any other pairing leaves a
    /// row whose switch and whose menu disagree about whether a hand does
    /// anything.
    public func setGestureAction(_ action: GestureAction, for pose: HandPose) {
        updateGestureBinding(pose) { binding in
            binding.action = action
            binding.isEnabled = action != .none
        }
    }

    public func setGestureBindingEnabled(_ enabled: Bool, for pose: HandPose) {
        updateGestureBinding(pose) { $0.isEnabled = enabled }
    }

    public func setGestureHoldSeconds(_ seconds: Double) {
        studio.gestures.holdSeconds = seconds
    }

    public func setGestureCooldownSeconds(_ seconds: Double) {
        studio.gestures.cooldownSeconds = seconds
    }

    public func setGestureConfidence(_ confidence: Double) {
        studio.gestures.confidence = confidence
    }

    private func updateGestureBinding(_ pose: HandPose,
                                      _ change: (inout GestureBinding) -> Void) {
        var bindings = studio.gestures.bindings
        if let index = bindings.firstIndex(where: { $0.pose == pose }) {
            change(&bindings[index])
        } else {
            // A binding list that lost a pose (a hand-edited file, an older
            // build's shape) gets it back rather than dropping the edit.
            var fresh = GestureBinding(pose: pose)
            change(&fresh)
            bindings.append(fresh)
        }
        studio.gestures.bindings = bindings
    }

    /// The demand gate for the whole feature, and the same two conditions
    /// presence uses: something must actually be bound (a switch wired to
    /// nothing is not a reason to run a Vision request, §8.7), and the camera
    /// must be the picture — there are no hands in a screen share.
    private func updateGestureWatching() {
        let watching = studio.gestures.isActive && videoSource.kind == .camera
        guard watching != gestureWatching else { return }
        gestureWatching = watching
        pipeline?.setGestureWatching(watching)
        if !watching {
            // Standing down means the sightings stop arriving, so a pose
            // half-held when it stopped watching must not complete later.
            gestureWatch.reset()
            lastGestureSequence = 0
        }
    }

    /// One sighting from the recogniser, turned into at most one action by
    /// the watch. Everything that makes a gesture safe — the confidence
    /// floor, the dwell, the debounce, the cooldown — is in there rather
    /// than here, so it can be tested against a clock instead of a hand.
    private func handleHandPose(_ sample: HandTracker.Sample) {
        guard gestureWatching else { return }
        guard sample.sequence != lastGestureSequence else { return }
        lastGestureSequence = sample.sequence

        guard let fired = gestureWatch.observe(pose: sample.pose,
                                               confidence: sample.confidence,
                                               settings: studio.gestures,
                                               at: sample.date) else { return }
        performGesture(studio.gestures.action(for: fired), pose: fired)
    }

    /// Exhaustive on purpose, exactly like `perform(_:)` for chords: a
    /// gesture action cannot be added without the compiler making someone say
    /// what it does.
    private func performGesture(_ action: GestureAction, pose: HandPose) {
        switch action {
        case .none:
            return
        case .toggleMute:
            toggleMute()
        case .toggleFreeze:
            toggleFreeze()
        case .takeStill:
            takeSnapshot()
        case .startReplay:
            toggleReplay()
        case .panic:
            togglePanic()
        }
        let event = GestureEvent(pose: pose, action: action)
        lastGesture = event
        let line = "\(pose.displayName) → \(action.displayName)"
        sessionLog.record(.onAir, line)
        // Said out loud, every time. This is the only input PRISM has that
        // the user cannot feel themselves make — a chord has a key under it
        // and a tile has a click, and a hand in the air has neither — so a
        // gesture that acted silently would be indistinguishable from the
        // app doing something by itself.
        notice = NoticeMessage(text: line, symbolName: "hand.raised")
        noticeTimer?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.notice = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        noticeTimer = timer
        updateMenuBarState()
    }

    // MARK: - Intents: voice cleanup (§5.17)

    /// Mode and strength, the same split the voice changer already uses:
    /// the picker is *what*, the slider is *how much*, which keeps each
    /// control answering one question (§8.7). Cleanup is independent of the
    /// voice effects and always runs ahead of them.
    public func setVoiceCleanupMode(_ mode: VoiceCleanupMode) {
        studio.cleanup.mode = mode
    }

    public func setVoiceCleanupAmount(_ amount: Double) {
        studio.cleanup.amount = amount
    }

    public var isVoiceCleanupActive: Bool { studio.cleanup.isActive }

    // MARK: - Intents: mic watch (§5.17)

    /// The banner is opt-in; the menu bar signal is not (§5.17).
    public func setMicWatchEnabled(_ enabled: Bool) {
        studio.micWatch.isEnabled = enabled
    }

    // MARK: - Intents: control surface (§5.19, §5.20)

    /// §5.19. Said the same way wherever a chord is refused, because it is
    /// the same rule and the reason is the whole explanation.
    private static let modifierRuleWarning =
        "A PRISM shortcut needs ⌥ or ⌃. PRISM listens without swallowing the keystroke, so a ⌘ chord would reach the app in front of you too."

    public func shortcut(for action: ShortcutAction) -> HotkeyCombo? {
        hotkeyBindings.combo(for: action)
    }

    /// The chord a control should print beside itself, empty when the action
    /// is unbound. Every hint in the UI reads through here rather than
    /// spelling "⌥⌘F" inline: a rebindable chord that the tiles still
    /// advertise as its default is a lie the user finds out about at the
    /// worst possible moment.
    public func shortcutLabel(_ action: ShortcutAction) -> String {
        shortcut(for: action)?.displayString ?? ""
    }

    /// The same, as a " · ⌥⌘F" tail for a help line.
    public func shortcutSuffix(_ action: ShortcutAction) -> String {
        shortcut(for: action).map { " · \($0.displayString)" } ?? ""
    }

    /// What a candidate chord would take away, so the editor can say so
    /// before the user commits to it. Preset bindings are in scope too: they
    /// go through the same tap, and a preset silently shadowed by a built-in
    /// is exactly the bug this check exists to prevent.
    public func shortcutConflict(for combo: HotkeyCombo,
                                 excluding action: ShortcutAction?) -> ShortcutConflict? {
        if let owner = hotkeyBindings.conflict(for: combo, excluding: action) {
            return .action(owner)
        }
        if let preset = presets.first(where: { $0.hotkey == combo }) {
            return .preset(id: preset.id, name: preset.name)
        }
        return nil
    }

    /// Assigns a chord, taking it from whoever had it.
    ///
    /// Stealing rather than refusing, because a refusal leaves the user to
    /// hunt for the owner themselves, and silently allowing a duplicate would
    /// leave two actions on one chord with only the match order deciding
    /// which fires. The loser is left unbound and named in the warning row,
    /// and "Reset all" is one click away.
    public func setShortcut(_ combo: HotkeyCombo?, for action: ShortcutAction) {
        guard let combo else {
            hotkeyBindings.set(nil, for: action)
            return
        }
        guard HotkeyBindings.isBindable(combo) else {
            warning = WarningMessage(text: Self.modifierRuleWarning)
            return
        }
        switch shortcutConflict(for: combo, excluding: action) {
        case .action(let owner):
            hotkeyBindings.set(nil, for: owner)
            warning = WarningMessage(
                text: "\(combo.displayString) now runs \(action.displayName). \(owner.displayName) has no shortcut.")
        case .preset(let id, let name):
            presetStore.setHotkey(id, hotkey: nil)
            warning = WarningMessage(
                text: "\(combo.displayString) now runs \(action.displayName). The \(name) preset has no shortcut.")
        case nil:
            break
        }
        hotkeyBindings.set(combo, for: action)
    }

    public func resetShortcut(_ action: ShortcutAction) {
        // Restoring a default can collide with whatever took its chord in the
        // meantime, so it goes through the same door as any other assignment;
        // dropping the override afterwards is what makes the row read
        // "Default" again rather than "assigned, and identical by accident".
        setShortcut(action.defaultCombo, for: action)
        if hotkeyBindings.combo(for: action) == action.defaultCombo {
            hotkeyBindings.reset(action)
        }
    }

    public func resetAllShortcuts() {
        var restored = hotkeyBindings
        restored.resetAll()
        hotkeyBindings = restored
        // Preset chords are the user's own choices and survive; only ones
        // that now collide with a restored default are cleared.
        for preset in presets {
            guard let combo = preset.hotkey,
                  hotkeyBindings.conflict(for: combo, excluding: nil) != nil
            else { continue }
            presetStore.setHotkey(preset.id, hotkey: nil)
        }
    }

    /// Same collision handling for the preset side of the table (§5.5).
    public func setPresetShortcut(_ combo: HotkeyCombo?, for presetID: UUID) {
        guard let combo else {
            presetStore.setHotkey(presetID, hotkey: nil)
            return
        }
        guard HotkeyBindings.isBindable(combo) else {
            warning = WarningMessage(text: Self.modifierRuleWarning)
            return
        }
        let name = presets.first(where: { $0.id == presetID })?.name ?? "Preset"
        switch shortcutConflict(for: combo, excluding: nil) {
        case .action(let owner):
            hotkeyBindings.set(nil, for: owner)
            warning = WarningMessage(
                text: "\(combo.displayString) now applies \(name). \(owner.displayName) has no shortcut.")
        case .preset(let id, let other) where id != presetID:
            presetStore.setHotkey(id, hotkey: nil)
            warning = WarningMessage(
                text: "\(combo.displayString) now applies \(name). The \(other) preset has no shortcut.")
        case .preset, nil:
            break
        }
        presetStore.setHotkey(presetID, hotkey: combo)
    }

    /// Recording a shortcut means typing the chord — including chords PRISM
    /// itself is listening for. The tap is stopped for the duration so that
    /// binding a key to Panic does not also panic.
    ///
    /// Counted, because clicking a second recorder while the first is still
    /// armed leaves two of them live: the last one to finish is what may
    /// restart the tap, and a tap restarted under an armed recorder is the
    /// failure this exists to prevent.
    public func beginShortcutRecording() {
        shortcutRecorders += 1
        if shortcutRecorders == 1 { hotkeys.stop() }
    }

    public func endShortcutRecording() {
        shortcutRecorders = max(0, shortcutRecorders - 1)
        if shortcutRecorders == 0, started { hotkeys.start() }
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
            // Retouch has a single knob and it ships at zero, so it is the
            // same case: there is exactly one value that means "on", and
            // guessing it is unambiguous.
            if enabled, id == .retouch, cfg.retouch.amount <= 0 {
                cfg.retouch.amount = RetouchSettings.defaultAmount
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
        setStyleEffect(effect, inSlot: 0)
    }

    /// The same intent for the second slot (§5.29). Enablement is read off
    /// the whole stack rather than off the effect just picked: clearing the
    /// first of two effects is not "switch Style off", and the switch would
    /// otherwise take the surviving effect down with it.
    public func setStyleEffect(_ effect: StyleEffect, inSlot slot: Int) {
        updateEditing { cfg in
            cfg.style.mutate(slot: slot) { $0.effect = effect }
            var flags = cfg.flags(for: .style)
            flags.enabled = !cfg.style.isNormal
            cfg.flags[.style] = flags
        }
        if draftConfig == nil {
            var status = stageStatus[.style] ?? StageStatus()
            status.autoDisabled = false
            stageStatus[.style] = status
        }
    }

    public func setStyleIntensity(_ intensity: Double, inSlot slot: Int) {
        updateEditing { $0.style.mutate(slot: slot) { $0.intensity = intensity } }
    }

    /// §5.30. Arms the level mailbox on the spot rather than waiting for the
    /// 1 Hz reconciliation: this is the one switch whose whole visible effect
    /// is that the picture starts moving, and a second of stillness after
    /// flipping it reads as the feature not working.
    public func setStyleAudioReactive(_ reactive: Bool, inSlot slot: Int) {
        updateEditing { $0.style.mutate(slot: slot) { $0.audioReactive = reactive } }
        reconcileInputLevel()
    }

    public func setStyleAudioDepth(_ depth: Double) {
        updateEditing { $0.style.audioDepth = depth }
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
        // §5.25: adding or removing a picture-in-picture layer starts or
        // stops a whole capture session. Compared rather than reconciled
        // unconditionally because this runs on every drag of every slider,
        // and reconciliation rebuilds the no-camera tick timer.
        if liveFeedDemand != lastLiveFeedDemand {
            refreshScreenRecordingNeed()
            reconcileCaptures()
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
            // Editing the look by hand takes the wheel back from a §5.18
            // rule, exactly as picking a preset does. Without this, reverting
            // when the app disconnects would throw away everything the user
            // adjusted during the call.
            clearAppRuleOverride()
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
        clearAppRuleOverride()                      // same reason as updateEditing
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
        renderer.audioLevelSource = Self.audioLevelSource(of: audioCapture)
        draftPreviewBox.setEnabled(true)
        // Seed with the latest live frame so the preview never flashes black
        // while the first draft frame renders (draft == live at begin).
        draftPreviewBox.store(previewBox.take())
        draftRendererBox.set(renderer)
        // §5.23: a second chain is resident from here until teardown — its
        // own intermediates, stage scratch, output pool and Vision requests.
        // The memory plan has to be told, or it keeps reporting the figure it
        // reported with the pane shut.
        pipeline?.setDraftChainActive(true)
        return renderer
    }

    private func teardownDraftRenderer() {
        draftRendererBox.set(nil)
        pipeline?.setDraftChainActive(false)
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
        if formatManager.activeFormat != format {
            sessionLog.record(.format, "Output format is now \(format.displayName)")
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
        // §5.24: a screen session is configured at the format's size and rate,
        // so a format change retargets it exactly as it retargets the camera's
        // physical pick. Reconciliation compares the request it started with.
        reconcileCaptures()
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
            if let first = self.clientsInUse.first {
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
        // Choosing a preset by hand takes the wheel back from a §5.18 rule:
        // the rule stops being in effect and there is nothing left to revert
        // to, because the user has just told us what they want.
        clearAppRuleOverride()
        applyPreset(preset, mayRepublishFormats: true)
    }

    /// The shared body of "put this preset on air". `mayRepublishFormats` is
    /// false for rule-driven applications: `requestPublishedFormatsChange`
    /// can raise a modal alert, and a modal nobody asked for — thrown up
    /// because an app started streaming — is not something a user can be
    /// expected to answer.
    private func applyPreset(_ preset: Preset, mayRepublishFormats: Bool) {
        activePresetID = preset.id
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
        } else if !formatAvailable, mayRepublishFormats {
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
        // a preset, so the pre-panic snapshot wins over the live config. A
        // §5.18 rule-driven look is somebody else's preset already, and
        // saving a copy of it under a new name is nobody's intent either.
        var cfg = draftConfig ?? appRuleRestore ?? panicRestore ?? config
        cfg.format = formatManager.activeFormat
        let preset = Preset(name: name, configuration: cfg)
        presetStore.add(preset)
        activePresetID = preset.id
    }

    // MARK: - Intents: per-app rules (§5.18)

    /// Recomputes what the rule list wants, given who is streaming, and moves
    /// the look to match. Idempotent: called on every client change and on
    /// every edit to the list, and does nothing when the answer is unchanged.
    private func reconcileAppRules() {
        let match = AppRuleResolver.presetMatch(
            clients: clients.map(\.signingID), in: appRules)
        guard match != activeAppRule else { return }

        guard let match else {
            activeAppRule = nil
            restoreFromAppRule()
            return
        }
        guard let preset = presetStore.presets.first(where: { $0.id == match.presetID }) else {
            // The preset was deleted out from under the rule. Leaving the
            // look alone beats guessing at a replacement; the rule editor
            // shows the row as dangling, so this is visible rather than
            // mysterious.
            return
        }
        // Taken once, on the way in. A Zoom → Teams handover inside one
        // sitting still returns to what the user had before any of it began.
        if activeAppRule == nil {
            appRuleRestore = panicRestore ?? config
            appRuleRestorePresetID = activePresetID
        }
        activeAppRule = match
        applyPreset(preset, mayRepublishFormats: false)
        if appRules.announcesPresetChanges {
            // §8.4: name the app and the preset, once, and then be quiet.
            postNotification(
                body: "\(appRuleName(match.signingID)) connected — \(preset.name) preset applied")
        }
    }

    /// What to call the app in copy: the label on its own rule when the user
    /// gave it one, otherwise the name PRISM knows the signing ID by.
    public func appRuleName(_ signingID: String) -> String {
        appRules.rules.first { $0.matches(signingID) }?.displayName
            ?? CMIOSink.displayName(forSigningID: signingID)
    }

    private func restoreFromAppRule() {
        guard let restore = appRuleRestore else { return }
        let presetID = appRuleRestorePresetID
        appRuleRestore = nil
        appRuleRestorePresetID = nil

        pipeline?.beginCrossfade(durationMs: 200)
        let previousCamera = config.cameraID
        let previousMic = config.microphoneID
        updateConfig { $0 = restore }
        if restore.cameraID != previousCamera { selectCamera(restore.cameraID) }
        if restore.microphoneID != previousMic { selectMicrophone(restore.microphoneID) }
        activePresetID = presetID
    }

    /// Forgets that a rule was ever in effect, without touching the look.
    private func clearAppRuleOverride() {
        activeAppRule = nil
        appRuleRestore = nil
        appRuleRestorePresetID = nil
    }

    /// Ships the flattened policy over 'polc'. Called on every edit and
    /// retried from pollTick until the extension acknowledges it.
    private func publishAccessPolicy() {
        let policy = AppRuleResolver.policy(for: appRules)
        cmioSink.isPolicyEnforcing = !policy.isAllowAll
        guard let json = policy.jsonData else {
            appRulePolicyPublished = false
            return
        }
        appRulePolicyPublished = cmioSink.writeAccessPolicy(json)
        if policy.isAllowAll, !blockedClients.isEmpty {
            blockedClients = []
            updateBlockedWarning()
        }
    }

    /// The refusal is invisible from inside the app being refused — it just
    /// sees a camera that will not start. PRISM is the only place that knows
    /// why, so it says so, and offers the way out in the same row.
    private func updateBlockedWarning() {
        if let first = blockedClients.first {
            warning = WarningMessage(
                text: "PRISM is blocking \(first.displayName) from using PRISM Camera",
                action: .clearBlocks)
        } else if warning?.action == .clearBlocks {
            warning = nil
        }
    }

    public func setAppRulesEnabled(_ on: Bool) {
        appRules.isEnabled = on
    }

    public func setAppRulesDefaultAccess(_ access: AppAccess) {
        appRules.defaultAccess = access
    }

    public func setAppRulesAnnounce(_ on: Bool) {
        appRules.announcesPresetChanges = on
    }

    public func addAppRule(signingID: String,
                           access: AppAccess = .allow,
                           presetID: UUID? = nil) {
        let trimmed = signingID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // One app, one rule: a second row for the same signing ID could never
        // win (first match decides) and would read as a setting that does
        // nothing. Editing the existing row is what the user meant.
        if let index = appRules.rules.firstIndex(where: { $0.matches(trimmed) }) {
            var rule = appRules.rules[index]
            rule.access = access
            rule.presetID = presetID
            appRules.rules[index] = rule
            return
        }
        // Seeded, not derived on every draw: the label is the user's to edit,
        // and a name PRISM guessed once is a better starting point than the
        // signing ID for the apps PRISM happens to know.
        appRules.rules.append(
            AppRule(signingID: trimmed,
                    name: CMIOSink.displayName(forSigningID: trimmed),
                    presetID: presetID,
                    access: access))
    }

    public func updateAppRule(_ id: UUID, _ mutate: (inout AppRule) -> Void) {
        guard let index = appRules.rules.firstIndex(where: { $0.id == id }) else { return }
        var rule = appRules.rules[index]
        mutate(&rule)
        appRules.rules[index] = rule
    }

    public func removeAppRule(_ id: UUID) {
        appRules.rules.removeAll { $0.id == id }
    }

    /// SwiftUI `onMove` semantics, same as PresetStore.move. Order is the
    /// conflict rule, so this is how the user says which app matters more.
    public func moveAppRules(fromOffsets: IndexSet, toOffset: Int) {
        appRules.rules.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// The escape hatch. Every block is lifted and the default goes back to
    /// allow, while preset assignments survive — the failure this recovers
    /// from is "my camera is dead", not "I regret my presets".
    ///
    /// Reachable from the warning row the block itself raises, so a user who
    /// locked themselves out never has to find a pane to get out.
    public func clearAllBlocks() {
        var next = appRules
        next.defaultAccess = .allow
        for index in next.rules.indices {
            next.rules[index].access = .allow
        }
        appRules = next
        blockedClients = []
        updateBlockedWarning()
    }

    /// True while blocking this app would take a camera away from a call
    /// that is happening right now. The editor asks before doing that.
    public func isStreamingNow(_ signingID: String) -> Bool {
        clients.contains { $0.signingID.caseInsensitiveCompare(signingID) == .orderedSame }
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
        // §5.32: stop rather than abandon. A meeting torn down by the
        // process exiting is a transcript that was never written, and the
        // user pressed Quit rather than asking to lose it.
        if meeting.phase.isRunning { stopMeeting() }
        assistant.cancel()
        noteWriter.cancel()
        levelTimer?.invalidate()
        levelTimer = nil
        audioCapture.stop()
        clipPlayer?.stop()
        pipeline?.replayPlayer.stop()
        pipeline?.replayBuffer.reset()
        cameraCapture.stop()
        screenCapture.stop()
        cmioSink.disconnect()
        audioSink?.close()      // marks producerAlive = 0 → plug-in emits silence
        NSApp.terminate(nil)
    }

    // MARK: - Derived state

    private func updateMenuBarState() {
        // §8.2 precedence, in full:
        //
        //   error > panicked > away > badConnection > lagging > replaying >
        //   frozen > mutedTalking > muted > sharingScreen > effects > live >
        //   idle
        //
        // The substitution states outrank the effect states because
        // forgetting you are in one is the damaging failure — panic and away
        // most of all, since both mean "the picture on air is not you right
        // now". Bad connection outranks lagging: when the switch engaged the
        // delay itself, the delay is part of the stunt, and the badge should
        // name the stunt the user engaged. Talking while muted outranks plain
        // muted for the same reason it exists at all: it is the state the
        // user is provably unaware of. Sharing a screen sits below the mute
        // states — everyone in the call can see the screen is up, so nobody
        // is being surprised by it — but above effects, because it says what
        // the camera is publishing rather than how.
        //
        // There is no recording state on purpose: writing a file changes
        // nothing on air, and this ladder ranks what is on air.
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
        } else if isSharingScreen {
            newState = .sharingScreen
        } else if hasActiveEffects {
            newState = .effects
        } else if !clients.isEmpty {
            newState = .live
        } else {
            newState = .idle
        }
        if newState != menuBarState {
            // §5.21: the glyph already summarises everything that changes
            // what clients can see, and it changes exactly when that answer
            // changes — so recording it here catches freeze, mute, panic,
            // away, replay and the rest without a call at each site.
            sessionLog.record(.onAir, newState.sessionDescription)
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
                            .geometry, .retouch]
        where config.flags(for: id).enabled && !config.isInert(id) {
            if !(stageStatus[id]?.autoDisabled ?? false) { return true }
        }
        return false
    }

    private func refreshSetupStatus() {
        permissions.refresh()
        extensionInstaller.checkStatus()
        setup.audioPlugInInstalled = AudioSink.isPlugInInstalled
        // §9: the screen row is owned by whether anything is asking for a
        // screen, and an attempt the user abandoned stops asking.
        refreshScreenRecordingNeed()
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
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.hotkeys),
           let decoded = try? JSONDecoder().decode(HotkeyBindings.self, from: data) {
            hotkeyBindings = decoded
        }
        // §5.24: the pick is restored, but not trusted — resolvePersistedSource
        // asks the window server whether it still means anything before any
        // capture is started against it.
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.videoSource),
           let decoded = try? JSONDecoder().decode(VideoSourceSelection.self, from: data) {
            videoSource = decoded
            isSharingScreen = decoded.kind != .camera
            sourceRoute.set(decoded.kind)
            if decoded.kind != .camera { screenFeed = decoded }
        }
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.screenFeed),
           let decoded = try? JSONDecoder().decode(VideoSourceSelection.self, from: data),
           decoded.kind != .camera {
            screenFeed = decoded
        }
        externalControlEnabled =
            UserDefaults.standard.bool(forKey: DefaultsKey.externalControl)
        // §8.3 default: Framing, Effects, Format collapsed on first launch —
        // an empty set is exactly that, so no seeding is needed.
    }

    /// Panic's backdrop swap lives in `config` so every surface shows what is
    /// on air — but it must not survive a quit. Persisting the pre-panic
    /// snapshot means relaunching after panicking leaves you where you were,
    /// not stuck behind a "back in a bit" card with no memory of why.
    /// A §5.18 rule-driven look is no more the user's saved configuration
    /// than a panic backdrop is: both are temporary substitutions the user
    /// did not choose for keeps. The pre-rule snapshot is the outer one — it
    /// is taken from `panicRestore ?? config` — so it wins when both exist.
    private func persistConfig() {
        if let data = try? JSONEncoder().encode(appRuleRestore ?? panicRestore ?? config) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.configuration)
        }
    }

    private func persistStudio() {
        if let data = try? JSONEncoder().encode(studio) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.studio)
        }
    }

    private func persistVideoSource() {
        if let data = try? JSONEncoder().encode(videoSource) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.videoSource)
        }
        if let data = try? JSONEncoder().encode(screenFeed) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.screenFeed)
        }
    }

    private func persistHotkeyBindings() {
        if let data = try? JSONEncoder().encode(hotkeyBindings) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.hotkeys)
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
