// StageSettings.swift
// PRISM
//
// Codable parameter sets for every stage, plus the full pipeline
// configuration that presets capture (§5.5). These types are the contract
// between the stages, the UI, and the preset store.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Per-stage settings (§5.4)

public struct AdjustSettings: Codable, Equatable {
    public var exposureEV: Double = 0      // −2…+2
    public var contrast: Double = 1        // 0…2
    public var saturation: Double = 1      // 0…2
    public var temperature: Double = 0     // −100…+100
    public var vignette: Double = 0        // 0…1
    public init() {}

    public var isIdentity: Bool {
        exposureEV == 0 && contrast == 1 && saturation == 1
            && temperature == 0 && vignette == 0
    }
}

public struct LUTSettings: Codable, Equatable {
    /// Name of a bundled or imported .cube file, without extension.
    public var lutName: String = "Neutral"
    public var strength: Double = 1        // 0…1
    public init() {}
}

public enum BlurQuality: String, Codable, CaseIterable {
    case fast, balanced, accurate

    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        }
    }
}

public struct BlurSettings: Codable, Equatable {
    public var quality: BlurQuality = .balanced
    public var radius: Double = 18         // pixels at 1080p, scaled by height
    public init() {}
}

public enum Orientation: Int, Codable, CaseIterable {
    case deg0 = 0, deg90 = 90, deg180 = 180, deg270 = 270
}

public enum Mirror: String, Codable, CaseIterable {
    case none, horizontal, vertical, both

    public var displayName: String {
        switch self {
        case .none: return "Off"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .both: return "Both"
        }
    }
}

public enum CropAspect: String, Codable, CaseIterable {
    case free, r16x9, r4x3, r1x1, r9x16

    public var ratio: Double? {
        switch self {
        case .free: return nil
        case .r16x9: return 16.0 / 9.0
        case .r4x3: return 4.0 / 3.0
        case .r1x1: return 1.0
        case .r9x16: return 9.0 / 16.0
        }
    }

    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .r16x9: return "16:9"
        case .r4x3: return "4:3"
        case .r1x1: return "1:1"
        case .r9x16: return "9:16"
        }
    }
}

public struct GeometrySettings: Codable, Equatable {
    public var zoom: Double = 1            // 1…4
    public var panX: Double = 0            // −1…1, fraction of croppable margin
    public var panY: Double = 0            // −1…1
    public var rotationDegrees: Double = 0 // −15…+15
    public var orientation: Orientation = .deg0
    public var mirror: Mirror = .none
    public var cropAspect: CropAspect = .free
    public var autoFrame: Bool = false
    public init() {}

    public var isIdentity: Bool {
        zoom == 1 && panX == 0 && panY == 0 && rotationDegrees == 0
            && orientation == .deg0 && mirror == .none
            && cropAspect == .free && !autoFrame
    }
}

// MARK: - Stage flags

public struct StageFlags: Codable, Equatable {
    public var enabled: Bool = false
    /// Pinned as required: exempt from automatic degradation (§3.4).
    public var pinned: Bool = false
    public init(enabled: Bool = false, pinned: Bool = false) {
        self.enabled = enabled
        self.pinned = pinned
    }
}

// MARK: - Full pipeline configuration (what a preset captures, §5.5)

public struct PipelineConfiguration: Codable, Equatable {
    public var adjust = AdjustSettings()
    public var lut = LUTSettings()
    public var blur = BlurSettings()
    public var geometry = GeometrySettings()

    public var flags: [StageID: StageFlags] = [
        .geometry: StageFlags(), .adjust: StageFlags(),
        .lut: StageFlags(), .blur: StageFlags(),
    ]

    public var format: VideoFormat = VideoFormat(width: 1920, height: 1080, frameRate: 30)
    public var latencyPolicy: LatencyPolicy = .balanced

    /// Device selections; nil = system default.
    public var cameraID: String?
    public var microphoneID: String?

    public init() {}

    public func flags(for id: StageID) -> StageFlags {
        flags[id] ?? StageFlags()
    }
}

// MARK: - Presets (§5.5)

public struct Preset: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isBuiltIn: Bool
    public var configuration: PipelineConfiguration
    /// Optional global hotkey binding, e.g. "⌥⌘1"; interpreted by Hotkeys.
    public var hotkey: HotkeyCombo?

    public init(id: UUID = UUID(), name: String, isBuiltIn: Bool = false,
                configuration: PipelineConfiguration, hotkey: HotkeyCombo? = nil) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.configuration = configuration
        self.hotkey = hotkey
    }
}

/// A global hotkey: Carbon-style keycode plus modifier flags.
public struct HotkeyCombo: Codable, Equatable {
    public var keyCode: UInt16
    public var option: Bool
    public var command: Bool
    public var shift: Bool
    public var control: Bool

    public init(keyCode: UInt16, option: Bool = false, command: Bool = false,
                shift: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.option = option
        self.command = command
        self.shift = shift
        self.control = control
    }

    public var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += KeyCodeNames.name(for: keyCode)
        return s
    }
}

public enum KeyCodeNames {
    public static func name(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"; case 1: return "S"; case 2: return "D"
        case 3: return "F"; case 4: return "H"; case 5: return "G"
        case 6: return "Z"; case 7: return "X"; case 8: return "C"
        case 9: return "V"; case 11: return "B"; case 12: return "Q"
        case 13: return "W"; case 14: return "E"; case 15: return "R"
        case 16: return "Y"; case 17: return "T"; case 32: return "U"
        case 31: return "O"; case 34: return "I"; case 35: return "P"
        case 37: return "L"; case 38: return "J"; case 40: return "K"
        case 45: return "N"; case 46: return "M"
        case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 23: return "5"; case 22: return "6"
        case 26: return "7"; case 28: return "8"; case 25: return "9"
        case 29: return "0"
        default: return "key\(keyCode)"
        }
    }
}
