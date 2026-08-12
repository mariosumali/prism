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
public enum MenuBarState: Equatable {
    case idle          // not in use by any client: outline, 40% opacity
    case live          // pass-through: outline, full opacity
    case effects       // filled
    case frozen        // filled + pause bar
    case muted         // filled + slash
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
    case framing, effects, format
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
    case presets
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
        case .presets: return "Presets"
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
        case .presets: return "square.stack"
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
