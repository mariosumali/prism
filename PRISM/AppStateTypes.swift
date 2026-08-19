// AppStateTypes.swift
// PRISM
//
// Supporting value types for AppState, shared by the UI and the system
// layer. AppState itself lives in AppState.swift.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public struct CameraDeviceInfo: Identifiable, Equatable, Hashable {
    public var id: String          // AVCaptureDevice.uniqueID
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AudioDeviceInfo: Identifiable, Equatable, Hashable {
    public var id: String          // CoreAudio device UID
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One app streaming from the PRISM camera, as reported by the extension's
/// 'clnt' property (§3.2).
///
/// The signing ID is the identity — it is what per-app rules match on, and
/// what survives an app being renamed — while the display name is only what
/// a human is shown. Carrying both means neither surface has to re-derive
/// the other, and a friendly name can never be mistaken for an identity: two
/// apps can both render as "Studio".
public struct CameraClient: Identifiable, Equatable, Hashable {
    public var signingID: String
    public var displayName: String

    public var id: String { signingID }

    public init(signingID: String, displayName: String) {
        self.signingID = signingID
        self.displayName = displayName
    }

    /// The usual construction: the name is derived, not supplied.
    public init(signingID: String) {
        self.signingID = signingID
        self.displayName = CMIOSink.displayName(forSigningID: signingID)
    }
}

/// §8.2 — drives the menu bar glyph.
///
/// The states below `.effects` all share one property: forgetting you are in
/// one is the most damaging thing this app can do to you. That is why replay,
/// away and panic each get their own glyph rather than folding into frozen —
/// "why can nobody see me moving" has to be answerable at a glance.
/// There is deliberately no recording state: writing a file changes nothing
/// on air, and this ladder ranks what is on air.
public enum MenuBarState: Equatable {
    case idle          // not in use by any client: outline, 40% opacity
    case live          // pass-through: outline, full opacity
    case effects       // filled
    case sharingScreen // filled + display badge: the screen is on air, not you
    case replaying     // filled + rewind badge: clients are seeing the past
    case away          // filled + moon badge: the idle loop is on air
    case badConnection // filled + wifi badge: §5.14 fake bad connection on air
    case lagging       // filled + hourglass badge: deliberate delay engaged
    case frozen        // filled + pause bar
    /// Muted, and the microphone is hearing speech anyway. Its own glyph
    /// because it is the one state the user is provably not aware of — they
    /// are talking.
    case mutedTalking  // filled + slash, red tint
    case muted         // filled + slash
    case panicked      // filled + raised hand, red tint
    case error         // filled, red tint

    /// How this state reads in the session log (§5.21), in the past tense a
    /// history wants rather than the label a live badge wants.
    ///
    /// Exhaustive rather than defaulted: a new glyph state that logged a
    /// blank row would be invisible in exactly the history that exists to
    /// explain it.
    public var sessionDescription: String {
        switch self {
        case .idle: return "No app is using PRISM Camera"
        case .live: return "Passing the camera through"
        case .effects: return "Effects on air"
        case .sharingScreen: return "Sharing a screen"
        case .replaying: return "Replay on air"
        case .away: return "Away loop on air"
        case .badConnection: return "Bad connection on air"
        case .lagging: return "Deliberate delay engaged"
        case .frozen: return "Output frozen"
        case .mutedTalking: return "Talking while muted"
        case .muted: return "Microphone muted"
        case .panicked: return "Panic engaged"
        case .error: return "PRISM stopped working"
        }
    }
}

public enum PermissionState: Equatable {
    case notDetermined, granted, denied
}

/// §9 — camera extension approval state.
public enum ExtensionStatus: Equatable {
    case unknown
    case notInstalled
    case needsApproval    // request submitted, waiting in System Settings
    case installed
    case failed(String)
}

/// §9 — the grants driven by OnboardingView, as one state machine.
public struct SetupStatus: Equatable {
    public var camera: PermissionState = .notDetermined
    public var microphone: PermissionState = .notDetermined
    public var cameraExtension: ExtensionStatus = .unknown
    public var audioPlugInInstalled: Bool = false
    /// §5.24. The fourth grant, and the only conditional one.
    public var screenRecording: PermissionState = .notDetermined
    /// Whether anything is currently asking for the screen — a screen or
    /// window chosen as the source, or a picture-in-picture layer looking at
    /// one. Sharing a screen ships off, and a setup banner that never goes
    /// away because of a feature the user has not switched on is a banner
    /// people learn to ignore. So the row appears when the feature does.
    public var screenRecordingNeeded: Bool = false

    public init() {}

    public var isComplete: Bool {
        camera == .granted && microphone == .granted
            && cameraExtension == .installed && audioPlugInInstalled
            && (!screenRecordingNeeded || screenRecording == .granted)
    }
}

/// Warning row under the status line (§8.3), with optional one-tap action.
public struct WarningMessage: Equatable, Identifiable {
    public enum Action: Equatable {
        case raiseBudget          // §3.4 pinned chain over budget
        case armBuffer            // §5.9 replay/away asked for without a buffer
        /// §5.18 — a per-app block is refusing a client right now. The
        /// action lifts every block rather than opening the rules pane: this
        /// is the one state in PRISM that can leave an app without a camera,
        /// so the way out belongs in the row that reports it.
        case clearBlocks
        case openSettings
        /// Stills have nowhere writable to go.
        case chooseCaptureFolder
        /// Screen capture needs its own grant, and the picker is useless
        /// until it is given.
        case openScreenRecordingSettings
        case none
    }

    public var id = UUID()
    public var text: String
    public var action: Action = .none

    public init(text: String, action: Action = .none) {
        self.text = text
        self.action = action
    }
}

/// The second row under the status line (§8.3): something PRISM noticed.
/// Deliberately a separate slot from WarningMessage, which is a standing
/// "this is wrong, here is the fix" — there is exactly one warning, and
/// posting through it would evict a fact (the camera is gone) in favour of
/// a hint. Two slots, two questions, no race to be the last writer.
///
/// Most notices are events: something happened, it went right, it is worth
/// confirming once and then forgetting. That is why one carries the moment
/// it happened and, when the event produced a file, the file itself — a
/// still that lands somewhere the user cannot find is a still that was not
/// saved. A few are conditions instead ("you're muted and talking", §5.17),
/// and those carry an `action` and are cleared by whoever posted them when
/// the condition goes away rather than by the expiry timer.
public struct NoticeMessage: Equatable, Identifiable {
    /// The one button the row offers, if any.
    public enum Action: Equatable {
        /// §5.17 muted-and-talking. The fix is one keystroke, so offer it.
        case unmute
        /// §5.28 — presence automation acted, or noticed you were out of
        /// frame with the camera still on. The way out belongs in the row
        /// that announces it: this is the one thing in PRISM that puts
        /// something on air without being asked each time, so the escape has
        /// to be in front of the user rather than one pane away.
        case comeBack
        case none
    }

    public var id = UUID()
    public var text: String
    public var symbolName: String
    public var fileURL: URL?
    public var action: Action
    public var date: Date

    public init(text: String,
                symbolName: String = "checkmark.circle",
                fileURL: URL? = nil,
                action: Action = .none,
                date: Date = Date()) {
        self.text = text
        self.symbolName = symbolName
        self.fileURL = fileURL
        self.action = action
        self.date = date
    }
}

/// Where a still capture is. The countdown carries its remaining seconds
/// because the surfaces draw that number — a spinner would say "working",
/// which is not the same promise as "in three seconds".
public enum CapturePhase: Equatable {
    case idle
    case countdown(remaining: Int)
    case writing
}

/// What a finished capture produced. The failure carries a sentence rather
/// than an error code because it is shown to the user verbatim.
public enum CaptureResult: Equatable {
    case saved(URL)
    case failed(String)
}

/// Whether the subject is in frame.
///
/// `unknown` is not `absent`: before the detector has measured anything — no
/// camera, no demand, feature just switched on — treating the frame as empty
/// would fire the away loop at precisely the wrong moment.
public enum PresenceState: Equatable {
    case unknown, present, absent
}

/// What is feeding the pipeline. The camera is the only source that exists
/// without a grant, which is why it is the fallback everywhere.
public enum VideoSourceKind: String, Codable, CaseIterable {
    case camera, display, window

    public var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .display: return "Screen"
        case .window: return "Window"
        }
    }

    public var symbolName: String {
        switch self {
        case .camera: return "camera"
        case .display: return "display"
        case .window: return "macwindow"
        }
    }
}

/// One shareable screen source. The id is the window-server's, so it is
/// valid only for as long as that display or window is; the name and owning
/// application exist so a source that has gone away can still be named in
/// the sentence explaining why PRISM fell back to the camera.
public struct ScreenSourceInfo: Identifiable, Equatable, Hashable {
    public var id: String
    public var kind: VideoSourceKind      // .display or .window
    public var name: String
    public var applicationName: String?

    public init(id: String, kind: VideoSourceKind, name: String,
                applicationName: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.applicationName = applicationName
    }

    /// How a picker names it. A window title on its own is frequently a
    /// document name and nothing else — "Untitled 2" — so the application
    /// that owns it leads, which is also how a person would say it out loud.
    public var displayName: String {
        guard let applicationName, !applicationName.isEmpty else { return name }
        return "\(applicationName) — \(name)"
    }

    /// How the §5.21 session log may name it, which is not how a picker may.
    ///
    /// A display's name is a device name — the log's standing promise. A
    /// window's name is its *title*, which is a document, a spreadsheet, a
    /// browser tab: "Q3 layoffs (confidential).xlsx". The log is a plain-text
    /// file people export and attach to a support thread, so the title never
    /// reaches it. The owning application does, because "what was I sharing
    /// when the stream died" needs an answer and "a Microsoft Excel window"
    /// is that answer without being the document's name.
    public var logName: String {
        Self.logName(kind: kind, name: name, applicationName: applicationName)
    }

    /// The same rule where only the parts are to hand — ScreenCapture names
    /// its running stream from an `SCWindow`, not from a picker row.
    public static func logName(kind: VideoSourceKind, name: String,
                               applicationName: String?) -> String {
        guard kind == .window else {
            guard let applicationName, !applicationName.isEmpty else { return name }
            return "\(applicationName) — \(name)"
        }
        guard let applicationName, !applicationName.isEmpty else {
            return "a shared window"
        }
        return "a \(applicationName) window"
    }
}

/// The user's source pick, persisted.
///
/// Tolerant per field like every persisted struct, and deliberately stores
/// only the id: a window id does not survive a reboot, and a source that
/// cannot be resolved has to fall back to the camera rather than to a black
/// frame nobody can explain.
public struct VideoSourceSelection: Codable, Equatable, Hashable {
    public var kind: VideoSourceKind = .camera
    /// nil for `.camera`; a `ScreenSourceInfo.id` otherwise.
    public var sourceID: String?

    public init(kind: VideoSourceKind = .camera, sourceID: String? = nil) {
        self.kind = kind
        self.sourceID = sourceID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.tolerant(.kind, VideoSourceKind.camera)
        sourceID = (try? c.decodeIfPresent(String.self, forKey: .sourceID)) ?? nil
    }

    public static let camera = VideoSourceSelection()
}

/// A recognised hand gesture, at the moment it fired. Carries the pose as
/// well as the action so a surface can say what it saw: a gesture that acts
/// without saying so is indistinguishable from a misfire, and gestures
/// misfire.
public struct GestureEvent: Equatable, Identifiable {
    public var id = UUID()
    public var pose: HandPose
    public var action: GestureAction
    public var date: Date

    public init(pose: HandPose, action: GestureAction, date: Date = Date()) {
        self.pose = pose
        self.action = action
        self.date = date
    }
}

public enum ClipState: Equatable {
    case none          // no clip loaded
    case playing
    case paused
}

/// Live per-stage status for the Effects list (§8.3, §8.6).
public struct StageStatus: Equatable {
    public var measuredMs: Double = 0
    public var autoDisabled: Bool = false
    public init() {}
}

/// Popover disclosure groups remember their state (§8.3).
public enum PopoverSection: String, CaseIterable {
    case framing, effects, format, scene, moments, voice, capture, prompter
}

/// What is behind you, as one choice (§5.4, §5.7).
///
/// Blur and replacement are separate stages with separate costs, but they
/// answer the same question and cannot both be true — blurring a background
/// you have already replaced is nonsense. Presenting them as one control
/// with modes is the honest shape; AppState.setBackgroundMode keeps the two
/// stages consistent underneath.
public enum BackgroundMode: String, CaseIterable, Identifiable, Hashable {
    case off, blur, color, image, video

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .blur: return "Blur"
        case .color: return "Colour"
        case .image: return "Image"
        case .video: return "Video"
        }
    }

    public var symbolName: String {
        switch self {
        case .off: return "person.crop.square"
        case .blur: return "drop.fill"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .video: return "film.stack"
        }
    }

    /// The modes that need a file chosen before they render anything.
    public var needsAsset: Bool { self == .image || self == .video }
}

/// The building blocks of the menu bar dropdown (§8.3), each independently
/// showable/hidable and reorderable from the main window's Menu Bar pane.
/// The setup banner, the warning row, and the bottom bar are deliberately
/// not modules — they always show.
public enum PopoverModule: String, Codable, CaseIterable, Identifiable {
    case preview
    case status
    case latencyMeter
    case inUse
    case controls      // Freeze / Mute / Clip tiles plus the clip scrub row
    case moments       // Replay / Away / Panic tiles plus the replay transport
    case capture       // stills and saved clips
    case presets
    case scene         // background mode + eye contact
    case voice         // §5.13 microphone voice effects
    case prompter      // the script, and the controls that scroll it
    case framing
    case effects
    case format
    case devices

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .preview: return "Live preview"
        case .status: return "Status line"
        case .latencyMeter: return "Latency meter"
        case .inUse: return "In-use apps"
        case .controls: return "Freeze / Mute / Clip"
        case .moments: return "Replay / Away / Panic"
        case .capture: return "Capture"
        case .presets: return "Presets"
        case .scene: return "Scene"
        case .voice: return "Voice"
        case .prompter: return "Prompter"
        case .framing: return "Framing"
        case .effects: return "Effects"
        case .format: return "Format"
        case .devices: return "Source & devices"
        }
    }

    public var symbolName: String {
        switch self {
        case .preview: return "rectangle.inset.filled"
        case .status: return "text.alignleft"
        case .latencyMeter: return "gauge.medium"
        case .inUse: return "app.connected.to.app.below.fill"
        case .controls: return "square.grid.3x1.below.line.grid.1x2"
        case .moments: return "backward.end.alt.fill"
        case .capture: return "square.and.arrow.down"
        case .presets: return "square.stack"
        case .scene: return "theatermasks"
        case .voice: return "waveform.and.mic"
        case .prompter: return "doc.plaintext"
        case .framing: return "crop.rotate"
        case .effects: return "wand.and.stars"
        case .format: return "rectangle.on.rectangle"
        case .devices: return "camera"
        }
    }
}

/// One row of the dropdown layout: a module and whether it currently shows.
public struct PopoverModuleItem: Codable, Equatable, Identifiable {
    public var module: PopoverModule
    public var visible: Bool

    public var id: PopoverModule { module }

    public init(module: PopoverModule, visible: Bool = true) {
        self.module = module
        self.visible = visible
    }

    /// Every module visible, in the §8.3 top-to-bottom order.
    public static let defaultLayout: [PopoverModuleItem] =
        PopoverModule.allCases.map { PopoverModuleItem(module: $0) }

    /// Repairs a persisted layout: duplicates dropped, unknown entries
    /// already failed decoding, and modules added in an app update appended
    /// visible so new features are never silently hidden.
    public static func sanitized(_ layout: [PopoverModuleItem]) -> [PopoverModuleItem] {
        var seen = Set<PopoverModule>()
        var result = layout.filter { seen.insert($0.module).inserted }
        for module in PopoverModule.allCases where !seen.contains(module) {
            result.append(PopoverModuleItem(module: module))
        }
        return result
    }
}

/// Who owns the one ReplayPlayer transport, as the flags every surface reads:
/// the away loop (§5.10), the lag switch (§5.12) and the delay half of the bad
/// connection (§5.14). Instant replay (§5.9) claims it too and publishes
/// nothing of its own — `replayMode` is its flag.
///
/// ReplayPlayer is a single transport. `begin()` bumps the generation, sets
/// the mode and re-bases on the newest buffered frame, so whatever it was
/// playing is destroyed the instant somebody else starts it. A claimant that
/// takes the transport without dropping the previous claimant's flag leaves
/// the app saying "Away" over delayed LIVE camera — the worst thing this app
/// can do, because the user is not at their desk to see it.
///
/// Modelled here rather than open-coded at each call site because the failure
/// is one of omission: flags derived from the claimant cannot be forgotten by
/// the claimant after next.
struct ReplayTransportClaim: Equatable {
    /// §5.10 — the away loop is playing.
    var isAway = false
    /// §5.12 — the delay line is engaged.
    var isLagging = false
    /// §5.12 — a release is playing the backlog out faster than real time.
    var isCatchingUp = false
    /// §5.14 — the delay was engaged by the bad-connection switch, so that
    /// switch releases it and the lag switch's own delay is left alone.
    var connectionEngagedLag = false

    /// Who is taking the transport.
    enum Claimant: Equatable {
        case replay         // §5.9
        case away           // §5.10
        case lag            // §5.12
        case connectionLag  // §5.14
    }

    /// The flags after `claimant` has taken the transport: its own, and
    /// nobody else's.
    static func claimed(by claimant: Claimant) -> ReplayTransportClaim {
        switch claimant {
        case .replay:
            return ReplayTransportClaim()
        case .away:
            return ReplayTransportClaim(isAway: true)
        case .lag:
            return ReplayTransportClaim(isLagging: true)
        case .connectionLag:
            return ReplayTransportClaim(isLagging: true, connectionEngagedLag: true)
        }
    }

    /// What the outgoing claimant leaves the new one to undo. Derived from
    /// what was standing rather than from who is taking over: the away loop's
    /// mute and presence's claim on it belong to the loop, and the audio delay
    /// line belongs to the delay — whoever replaces them inherits neither.
    struct Release: Equatable {
        var loop = false
        var delayLine = false
    }

    var release: Release {
        Release(loop: isAway, delayLine: isLagging || isCatchingUp)
    }

    /// §5.14 — whether the bad connection may take the transport for its
    /// delay half. It may not: the delay is the optional half of that switch
    /// ("degrade what can be degraded, and say what could not"), while a
    /// replay or an away loop is a picture the user deliberately put on air.
    /// Taking the transport from the away loop would put delayed live camera
    /// on air with nobody in front of the camera to notice.
    static func connectionMayClaimTransport(mode: ReplayMode,
                                            standing: ReplayTransportClaim) -> Bool {
        mode == .idle && !standing.isAway && !standing.isLagging
            && !standing.isCatchingUp
    }
}

/// What the panic chord (§5.11) engaged itself, so releasing it undoes
/// exactly that and nothing else.
///
/// The rule is the one presence automation already follows (§5.28): a freeze
/// or a mute the user engaged before panicking is theirs, and releasing panic
/// leaves it engaged. Deciding the release from the settings instead — "panic
/// freezes, so releasing thaws" — thaws the picture a user froze to step out
/// of shot and puts them back on air without asking.
struct PanicHold: Equatable {
    var frozeByUs = false
    var mutedByUs = false

    /// What engaging does, given what is already true. Anything already
    /// engaged is left alone: it is the user's, and it stays theirs.
    static func engaging(settings: PanicSettings,
                         isFrozen: Bool,
                         isMuted: Bool) -> (hold: PanicHold, freeze: Bool, mute: Bool) {
        let freeze = settings.freezes && !isFrozen
        let mute = settings.mutes && !isMuted
        return (PanicHold(frozeByUs: freeze, mutedByUs: mute), freeze, mute)
    }

    /// What releasing undoes: only what this hold engaged, and only while it
    /// is still true — a user who thawed the picture by hand mid-panic must
    /// not have it re-frozen or double-toggled on the way out.
    func releasing(isFrozen: Bool, isMuted: Bool) -> (thaw: Bool, unmute: Bool) {
        (thaw: frozeByUs && isFrozen, unmute: mutedByUs && isMuted)
    }
}
