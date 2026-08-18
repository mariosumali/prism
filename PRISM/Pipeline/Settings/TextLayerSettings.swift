// TextLayerSettings.swift
// PRISM
//
// Text drawn into the frame: the style carried by a `.text` overlay layer
// (§5.8), and the teleprompter that scrolls a script over the picture.
//
// Both are behaviour-free here. Rasterisation is the text work's problem;
// this file is only the persisted description of what to draw, kept separate
// so that work can add fields without touching the layer model.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// Deliberately not SwiftUI's `Font.Weight`: this value is persisted in
/// presets, and a preset format must not depend on a framework type whose
/// encoding Apple owns.
public enum OverlayTextWeight: String, Codable, CaseIterable {
    case regular, medium, bold

    public var displayName: String {
        switch self {
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .bold: return "Bold"
        }
    }
}

/// Named `Overlay…` rather than `TextAlignment` because SwiftUI already
/// exports that name and every UI file imports SwiftUI.
public enum OverlayTextAlignment: String, Codable, CaseIterable {
    case leading, center, trailing

    public var displayName: String {
        switch self {
        case .leading: return "Left"
        case .center: return "Centre"
        case .trailing: return "Right"
        }
    }
}

/// The slab drawn behind the glyphs. White text over a bright background is
/// unreadable and no drop shadow fixes it, so the plate is a first-class
/// choice rather than a styling afterthought.
public enum TextPlate: String, Codable, CaseIterable {
    case none, solid, blur

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .solid: return "Solid"
        case .blur: return "Blurred"
        }
    }
}

public struct OverlayTextStyle: Codable, Equatable {
    /// What the layer says. Blank means the layer draws nothing at all rather
    /// than an empty plate — see `OverlayLayer.isRenderable`.
    public var string: String = ""
    /// A family name, resolved at draw time. Stored as a name rather than a
    /// resolved font because a preset travels between machines and the font
    /// it names may not exist on the other one; missing resolves to the
    /// system font rather than failing the layer.
    public var fontFamily: String = ""
    /// Point size at 1080p, scaled with the output height for the same reason
    /// blur radii are: a size fixed in pixels is a different size on every
    /// format.
    public var fontSize: Double = 48
    public var weight: OverlayTextWeight = .medium
    public var color: RGBColor = RGBColor(red: 1, green: 1, blue: 1)
    public var plate: TextPlate = .none
    public var plateColor: RGBColor = .prismSlate
    public var plateOpacity: Double = 0.6      // 0…1
    public var alignment: OverlayTextAlignment = .center
    /// Space between the glyphs and the plate edge, as a fraction of the font
    /// size — so padding stays proportional when the size changes.
    public var padding: Double = 0.35          // 0…2
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        string = c.tolerant(.string, "")
        fontFamily = c.tolerant(.fontFamily, "")
        fontSize = c.tolerant(.fontSize, 48)
        weight = c.tolerant(.weight, .medium)
        color = c.tolerant(.color, RGBColor(red: 1, green: 1, blue: 1))
        plate = c.tolerant(.plate, TextPlate.none)
        plateColor = c.tolerant(.plateColor, .prismSlate)
        plateOpacity = c.tolerant(.plateOpacity, 0.6)
        alignment = c.tolerant(.alignment, .center)
        padding = c.tolerant(.padding, 0.35)
    }

    /// Whitespace-only text is nothing to draw. Checked here so the layer
    /// model and every surface agree on what "has text" means.
    public var hasText: Bool {
        !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var pointSize: Double { max(8, fontSize) }
}

// MARK: - Teleprompter

/// Where the prompter sits over the picture. Top is the default because the
/// camera is above the screen on every laptop, so reading near the top of the
/// frame is what keeps your eyes near the lens — the same fact §5.6 corrects
/// for in software.
public enum PrompterAnchor: String, Codable, CaseIterable {
    case top, center, bottom

    public var displayName: String {
        switch self {
        case .top: return "Top"
        case .center: return "Middle"
        case .bottom: return "Bottom"
        }
    }
}

/// The teleprompter. Not part of PipelineConfiguration: a script is not a
/// look, and switching from Meeting to Studio must not load someone else's
/// words onto the screen.
public struct PrompterSettings: Codable, Equatable {
    /// Off by default, and off means the script is never composited — a
    /// prompter that shows in the outgoing frame by default would put private
    /// notes on a call.
    public var isEnabled: Bool = false
    public var script: String = ""
    /// Lines per minute. Roughly conversational reading pace; the user tunes
    /// it against their own delivery, which is why there is no clever
    /// auto-scroll.
    public var speed: Double = 30              // 5…120
    public var fontSize: Double = 34
    public var anchor: PrompterAnchor = .top
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.tolerant(.isEnabled, false)
        script = c.tolerant(.script, "")
        speed = c.tolerant(.speed, 30)
        fontSize = c.tolerant(.fontSize, 34)
        anchor = c.tolerant(.anchor, .top)
    }

    public var clampedSpeed: Double { min(max(speed, 5), 120) }

    /// An enabled prompter with no script is an "on" switch that changes
    /// nothing (§8.7); every surface reads this rather than `isEnabled`.
    public var isActive: Bool {
        isEnabled && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
