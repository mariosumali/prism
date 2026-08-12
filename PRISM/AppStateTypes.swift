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

/// §8.2 — drives the menu bar glyph.
///
/// The states below `.effects` all share one property: forgetting you are in
/// one is the most damaging thing this app can do to you. That is why replay,
/// away and panic each get their own glyph rather than folding into frozen —
/// "why can nobody see me moving" has to be answerable at a glance.
public enum MenuBarState: Equatable {
    case idle          // not in use by any client: outline, 40% opacity
    case live          // pass-through: outline, full opacity
    case effects       // filled
    case replaying     // filled + rewind badge: clients are seeing the past
    case away          // filled + moon badge: the idle loop is on air
    case frozen        // filled + pause bar
    case muted         // filled + slash
    case panicked      // filled + raised hand, red tint
    case error         // filled, red tint
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

/// §9 — the three grants driven by OnboardingView, as one state machine.
public struct SetupStatus: Equatable {
    public var camera: PermissionState = .notDetermined
    public var microphone: PermissionState = .notDetermined
    public var cameraExtension: ExtensionStatus = .unknown
    public var audioPlugInInstalled: Bool = false

    public init() {}

    public var isComplete: Bool {
        camera == .granted && microphone == .granted
            && cameraExtension == .installed && audioPlugInInstalled
    }
}

/// Warning row under the status line (§8.3), with optional one-tap action.
public struct WarningMessage: Equatable, Identifiable {
    public enum Action: Equatable {
        case raiseBudget          // §3.4 pinned chain over budget
        case armBuffer            // §5.9 replay/away asked for without a buffer
        case openSettings
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
    case framing, effects, format, scene, moments
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
    case presets
    case scene         // background mode + eye contact
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
        case .presets: return "Presets"
        case .scene: return "Scene"
        case .framing: return "Framing"
        case .effects: return "Effects"
        case .format: return "Format"
        case .devices: return "Device pickers"
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
        case .presets: return "square.stack"
        case .scene: return "theatermasks"
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
