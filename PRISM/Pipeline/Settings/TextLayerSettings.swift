// TextLayerSettings.swift
// PRISM
//
// Text drawn into the frame: the style carried by a `.text` overlay layer
// (§5.8, §5.26), and the teleprompter (§5.27) — which is the one kind of
// text in PRISM that is never drawn into the frame at all.
//
// Both are behaviour-free here. Rasterisation lives in TextRasterizer and
// the prompter's panel lives in the UI layer; this file is only the
// persisted description of what to draw.
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

/// What is drawn behind the glyphs. White text over a bright background is
/// unreadable and no drop shadow fixes it, so the plate is a first-class
/// choice rather than a styling afterthought.
///
/// `blur` is a soft halo hugging the letterforms, not a frosted rectangle
/// sampling the picture behind it. Frosted glass would mean the compositing
/// kernel reading its base twice with a blur between, and `prism_overlay` is
/// shared by every layer in the app — a text-only branch through it would be
/// paid for by hats and green screens forever. A blurred halo is the thing
/// that actually buys legibility over a busy picture, and it costs nothing
/// at composite time because it is baked into the layer's own alpha.
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
    /// The second line, set smaller and dimmer under the first. This is the
    /// whole of the lower third (§5.26): a name banner is a name and what
    /// you do, and asking someone to build that out of two independently
    /// placed layers is asking them to keep two layers aligned by hand.
    public var subtitle: String = ""
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
        subtitle = c.tolerant(.subtitle, "")
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
    /// model and every surface agree on what "has text" means — including
    /// the subtitle, so a lower third with only a job title still renders.
    public var hasText: Bool {
        !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasSubtitle
    }

    public var hasSubtitle: Bool {
        !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var pointSize: Double { max(8, fontSize) }

    /// How much smaller the second line runs. A fixed ratio rather than a
    /// second size field: the whole point of the banner is that it is two
    /// fields, and a subtitle nobody can tell apart from the name is not a
    /// subtitle (§8.7).
    public static let subtitleRatio: Double = 0.55
}

// MARK: - Teleprompter

/// Where on the display the prompter panel opens. Top is the default because
/// the camera is above the screen on every laptop, so reading near the top of
/// the display is what keeps your eyes near the lens — the same fact §5.6
/// corrects for in software, which is exactly why the two compose: read from
/// just under the lens and let eye contact close the last few degrees.
///
/// A first position rather than a fixed one — the panel is dragged wherever
/// the user's own camera sits, and remembers where they put it.
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

/// The teleprompter (§5.27).
///
/// Not part of PipelineConfiguration: a script is not a look, and switching
/// from Meeting to Studio must not load someone else's words onto the
/// screen. And not part of the frame either — a prompter is for the person
/// reading it, so it is a floating panel over the user's own desktop and
/// never a layer in the picture. Nothing in this struct reaches a stage.
public struct PrompterSettings: Codable, Equatable {
    /// Off by default, and off means the panel is not on screen at all — a
    /// prompter that opens itself would put private notes over whatever the
    /// user was doing.
    public var isEnabled: Bool = false
    public var script: String = ""
    /// Lines per minute. Roughly conversational reading pace; the user tunes
    /// it against their own delivery, which is why there is no clever
    /// auto-scroll.
    public var speed: Double = 30              // 5…120
    /// Points on screen, not frame-relative: this text is read by a person
    /// sitting in front of a display, so it is sized in the units that
    /// display uses.
    public var fontSize: Double = 34           // 14…96
    public var anchor: PrompterAnchor = .top
    /// How solid the panel is over whatever is behind it. One control for
    /// the whole panel rather than separate text and background knobs,
    /// because the question being asked is "how much of my screen can I
    /// still see" (§8.7).
    public var opacity: Double = 0.9           // 0.2…1
    /// Flips the script horizontally for a beam-splitter rig, where the text
    /// is read off glass in front of the lens and arrives reversed.
    public var isMirrored: Bool = false
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Deliberately not restored. PRISM launches at login for most people,
        // and a panel that reopened itself would drop last week's script over
        // whatever they actually opened their Mac to do — with no visible
        // cause, because nothing asked for it. The words are kept; the
        // decision to show them is made fresh every session.
        isEnabled = false
        script = c.tolerant(.script, "")
        speed = c.tolerant(.speed, 30)
        fontSize = c.tolerant(.fontSize, 34)
        anchor = c.tolerant(.anchor, .top)
        opacity = c.tolerant(.opacity, 0.9)
        isMirrored = c.tolerant(.isMirrored, false)
    }

    public var clampedSpeed: Double { min(max(speed, 5), 120) }
    public var clampedFontSize: Double { min(max(fontSize, 14), 96) }
    public var clampedOpacity: Double { min(max(opacity, 0.2), 1) }

    /// Leading, in points: what one line of the script occupies on screen.
    /// The scroll rate is derived from it, so "30 lines per minute" means the
    /// same reading pace at every font size.
    public var lineHeight: Double { clampedFontSize * 1.35 }

    /// Points per second of travel. The one number the panel animates on.
    public var scrollRate: Double { clampedSpeed / 60 * lineHeight }

    /// An enabled prompter with no script is an "on" switch that changes
    /// nothing (§8.7); every surface reads this rather than `isEnabled`.
    public var isActive: Bool {
        isEnabled && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
