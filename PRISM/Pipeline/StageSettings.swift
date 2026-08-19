// StageSettings.swift
// PRISM
//
// Codable parameter sets for every stage, plus the full pipeline
// configuration that presets capture (§5.5). These types are the contract
// between the stages, the UI, and the preset store.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Forward compatibility

/// Decodes a key if it is present and well-formed, and falls back to the
/// property's default otherwise.
///
/// Swift's synthesised `Codable` does not fall back to property defaults —
/// it throws on an absent key. Every settings struct below is persisted, in
/// UserDefaults and in shareable preset JSON, so with synthesised decoding
/// the moment any of them gains a field every file written by an earlier
/// build fails to decode and the user silently loses that whole struct on
/// upgrade. Tolerating absence per field makes new fields additive.
///
/// This has to be applied at EVERY level, not just the outermost one: a
/// tolerant `PipelineConfiguration` decoding a `BlurSettings` that throws
/// still discards the user's blur settings entirely. Version skew shows up
/// as a partial nested object, which is exactly the case a top-level-only
/// fallback misses.
extension KeyedDecodingContainer {
    func tolerant<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

// MARK: - Per-stage settings (§5.4)

public struct AdjustSettings: Codable, Equatable {
    public var exposureEV: Double = 0      // −2…+2
    public var contrast: Double = 1        // 0…2
    public var saturation: Double = 1      // 0…2
    public var temperature: Double = 0     // −100…+100
    public var vignette: Double = 0        // 0…1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposureEV = c.tolerant(.exposureEV, 0)
        contrast = c.tolerant(.contrast, 1)
        saturation = c.tolerant(.saturation, 1)
        temperature = c.tolerant(.temperature, 0)
        vignette = c.tolerant(.vignette, 0)
    }

    public var isIdentity: Bool {
        exposureEV == 0 && contrast == 1 && saturation == 1
            && temperature == 0 && vignette == 0
    }
}

public struct LUTSettings: Codable, Equatable {
    /// The identity LUT. Shipped as a file and synthesized as a fallback, so
    /// "LUT = Neutral" and "LUT off" are the same picture — which is why
    /// every surface has to treat them as the same state (see `isInert`).
    public static let neutralName = "Neutral"

    /// Name of a bundled or imported .cube file, without extension.
    public var lutName: String = LUTSettings.neutralName
    public var strength: Double = 1        // 0…1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lutName = c.tolerant(.lutName, LUTSettings.neutralName)
        strength = c.tolerant(.strength, 1)
    }

    /// Lookup is case-insensitive everywhere (LUTStore keys on lowercase), so
    /// the neutral test has to be too.
    public static func isNeutral(_ name: String) -> Bool {
        name.caseInsensitiveCompare(neutralName) == .orderedSame
    }

    public var isNeutral: Bool { Self.isNeutral(lutName) }
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quality = c.tolerant(.quality, .balanced)
        radius = c.tolerant(.radius, 18)
    }
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
    public var rotationDegrees: Double = 0 // −180…+180
    public var orientation: Orientation = .deg0
    public var mirror: Mirror = .none
    public var cropAspect: CropAspect = .free
    public var autoFrame: Bool = false
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zoom = c.tolerant(.zoom, 1)
        panX = c.tolerant(.panX, 0)
        panY = c.tolerant(.panY, 0)
        rotationDegrees = c.tolerant(.rotationDegrees, 0)
        orientation = c.tolerant(.orientation, .deg0)
        mirror = c.tolerant(.mirror, Mirror.none)
        cropAspect = c.tolerant(.cropAspect, .free)
        autoFrame = c.tolerant(.autoFrame, false)
    }

    public var isIdentity: Bool {
        zoom == 1 && panX == 0 && panY == 0 && rotationDegrees == 0
            && orientation == .deg0 && mirror == .none
            && cropAspect == .free && !autoFrame
    }
}

// MARK: - Eye-contact correction (§5.6)

public struct GazeSettings: Codable, Equatable {
    /// How much of the measured gaze error to remove. 1 aims the eyes at the
    /// lens exactly; the default leaves a little residual because a gaze
    /// nailed to the lens for minutes at a time reads as a stare.
    public var strength: Double = 0.75      // 0…1
    /// Hard ceiling on the warp, as a fraction of iris radius. Past roughly
    /// half an iris width the sclera stretch becomes visible, so this is a
    /// quality clamp, not a safety one.
    public var maxShift: Double = 0.5       // 0…1
    /// Where the camera sits relative to the screen you actually look at.
    /// Positive = camera above (the usual laptop case, eyes need lifting).
    public var verticalBias: Double = 1.0   // −1…1
    /// Landmark smoothing. Vision's per-frame jitter is small but visible on
    /// something as fine as an iris, so this is high by default.
    public var smoothing: Double = 0.8      // 0…1
    /// Softness of the sclera transition between iris and eyelid.
    public var feather: Double = 0.25       // 0.05…1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strength = c.tolerant(.strength, 0.75)
        maxShift = c.tolerant(.maxShift, 0.5)
        verticalBias = c.tolerant(.verticalBias, 1.0)
        smoothing = c.tolerant(.smoothing, 0.8)
        feather = c.tolerant(.feather, 0.25)
    }
}

// MARK: - Virtual background (§5.7)

public enum BackgroundKind: String, Codable, CaseIterable {
    case color, image, video

    public var displayName: String {
        switch self {
        case .color: return "Colour"
        case .image: return "Image"
        case .video: return "Video"
        }
    }
}

/// A colour that survives a preset round-trip. `Color` is not Codable and
/// NSColor archiving would drag AppKit into the pipeline layer.
public struct RGBColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let prismSlate = RGBColor(red: 0.10, green: 0.11, blue: 0.13)
}

public struct BackgroundSettings: Codable, Equatable {
    public var kind: BackgroundKind = .image
    /// File path of the still or looping video. Absolute; PRISM is not
    /// sandboxed (§9), so no bookmark round-trip is needed.
    public var assetPath: String?
    public var color: RGBColor = .prismSlate
    public var fillMode: ClipFillMode = .fill    // backgrounds fill, they do not letterbox
    public var maskContrast: Double = 1.4        // 1…4
    public var edgeSoftness: Double = 0.3        // 0…1
    public var lightWrap: Double = 0.25          // 0…1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.tolerant(.kind, .image)
        assetPath = (try? c.decodeIfPresent(String.self, forKey: .assetPath)) ?? nil
        color = c.tolerant(.color, .prismSlate)
        fillMode = c.tolerant(.fillMode, .fill)
        maskContrast = c.tolerant(.maskContrast, 1.4)
        edgeSoftness = c.tolerant(.edgeSoftness, 0.3)
        lightWrap = c.tolerant(.lightWrap, 0.25)
    }

    public var assetURL: URL? {
        assetPath.map { URL(fileURLWithPath: $0) }
    }

    /// A video/image background with no file chosen renders as the colour
    /// rather than as nothing — an empty picker must never blank the camera.
    public var resolvedKind: BackgroundKind {
        (kind == .color || assetPath != nil) ? kind : .color
    }
}

// MARK: - Overlay layers — the green-screen / puppet-stage stage (§5.8)

public enum KeyMode: String, Codable, CaseIterable {
    case none, chroma, luma

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .chroma: return "Chroma key"
        case .luma: return "Luma key"
        }
    }
}

public enum LayerPlacement: String, Codable, CaseIterable {
    case front, behind

    public var displayName: String {
        switch self {
        case .front: return "In front"
        case .behind: return "Behind me"
        }
    }
}

public enum LayerSourceKind: String, Codable, CaseIterable {
    case image, video
    /// Drawn from `OverlayLayer.text`, not from a file. Costs a rasterisation
    /// when the string changes and nothing per frame after that.
    case text
    /// A second camera or a screen, from `OverlayLayer.liveFeed`.
    case live

    public var displayName: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .text: return "Text"
        case .live: return "Live feed"
        }
    }
}

public struct OverlayLayer: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var sourceKind: LayerSourceKind
    public var assetPath: String?
    public var placement: LayerPlacement
    public var keyMode: KeyMode
    /// Chroma-key target. Defaults to broadcast green; any colour works.
    public var keyColor: RGBColor
    public var similarity: Double        // 0…1 chroma distance threshold
    public var smoothness: Double        // 0…1 soft edge above the threshold
    public var spill: Double             // 0…1 despill
    public var lumaLow: Double           // 0…1
    public var lumaHigh: Double          // 0…1
    public var opacity: Double           // 0…1
    public var scale: Double             // 0.05…4, relative to the frame
    public var offsetX: Double           // −1…1 in output UV, 0 = centred
    public var offsetY: Double           // −1…1
    public var rotationDegrees: Double   // −180…180
    public var mirrored: Bool
    /// Content for a `.text` layer; ignored by every other kind.
    public var text: OverlayTextStyle
    /// Feed for a `.live` layer. Optional because "live layer with nothing
    /// chosen yet" is a real state the picker passes through, and it must
    /// draw nothing rather than black (see `isRenderable`).
    public var liveFeed: LiveLayerFeed?
    /// Frame-relative or face-relative placement.
    public var anchor: LayerAnchor
    /// Which landmark a face-anchored layer hangs from; ignored when the
    /// anchor is `.frame`.
    public var facePoint: FaceAnchorPoint
    /// Rotate with the head's tilt. Off by default even for face-anchored
    /// layers: roll is the noisiest of the tracked quantities, and a prop
    /// that jitters in rotation is more distracting than one that stays level.
    public var followsRoll: Bool

    public init(id: UUID = UUID(),
                name: String = "Layer",
                isEnabled: Bool = true,
                sourceKind: LayerSourceKind = .image,
                assetPath: String? = nil,
                placement: LayerPlacement = .front,
                keyMode: KeyMode = .none,
                keyColor: RGBColor = RGBColor(red: 0, green: 0.7, blue: 0.1),
                similarity: Double = 0.2,
                smoothness: Double = 0.1,
                spill: Double = 0.5,
                lumaLow: Double = 0.05,
                lumaHigh: Double = 0.25,
                opacity: Double = 1,
                scale: Double = 1,
                offsetX: Double = 0,
                offsetY: Double = 0,
                rotationDegrees: Double = 0,
                mirrored: Bool = false,
                // Appended, defaulted: this initialiser is called positionally
                // all over the app and its tests, and inserting a parameter in
                // the middle would break every one of those call sites.
                text: OverlayTextStyle = OverlayTextStyle(),
                liveFeed: LiveLayerFeed? = nil,
                anchor: LayerAnchor = .frame,
                facePoint: FaceAnchorPoint = .aboveHead,
                followsRoll: Bool = false) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sourceKind = sourceKind
        self.assetPath = assetPath
        self.placement = placement
        self.keyMode = keyMode
        self.keyColor = keyColor
        self.similarity = similarity
        self.smoothness = smoothness
        self.spill = spill
        self.lumaLow = lumaLow
        self.lumaHigh = lumaHigh
        self.opacity = opacity
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotationDegrees = rotationDegrees
        self.mirrored = mirrored
        self.text = text
        self.liveFeed = liveFeed
        self.anchor = anchor
        self.facePoint = facePoint
        self.followsRoll = followsRoll
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An id is the one field with no sensible default — a layer that
        // loses its identity would detach from its media source — so a fresh
        // one is minted rather than failing the whole preset.
        id = c.tolerant(.id, UUID())
        name = c.tolerant(.name, "Layer")
        isEnabled = c.tolerant(.isEnabled, true)
        sourceKind = c.tolerant(.sourceKind, .image)
        assetPath = (try? c.decodeIfPresent(String.self, forKey: .assetPath)) ?? nil
        placement = c.tolerant(.placement, .front)
        keyMode = c.tolerant(.keyMode, KeyMode.none)
        keyColor = c.tolerant(.keyColor, RGBColor(red: 0, green: 0.7, blue: 0.1))
        similarity = c.tolerant(.similarity, 0.2)
        smoothness = c.tolerant(.smoothness, 0.1)
        spill = c.tolerant(.spill, 0.5)
        lumaLow = c.tolerant(.lumaLow, 0.05)
        lumaHigh = c.tolerant(.lumaHigh, 0.25)
        opacity = c.tolerant(.opacity, 1)
        scale = c.tolerant(.scale, 1)
        offsetX = c.tolerant(.offsetX, 0)
        offsetY = c.tolerant(.offsetY, 0)
        rotationDegrees = c.tolerant(.rotationDegrees, 0)
        mirrored = c.tolerant(.mirrored, false)
        text = c.tolerant(.text, OverlayTextStyle())
        liveFeed = (try? c.decodeIfPresent(LiveLayerFeed.self, forKey: .liveFeed)) ?? nil
        anchor = c.tolerant(.anchor, .frame)
        facePoint = c.tolerant(.facePoint, .aboveHead)
        followsRoll = c.tolerant(.followsRoll, false)
    }

    public var assetURL: URL? {
        assetPath.map { URL(fileURLWithPath: $0) }
    }

    /// A layer with nothing to draw draws nothing, rather than a black
    /// rectangle. What counts as "nothing" depends on the kind: a file for
    /// image and video, a non-blank string for text, a chosen feed for live.
    public var isRenderable: Bool {
        guard isEnabled, opacity > 0 else { return false }
        switch sourceKind {
        case .image, .video: return assetPath != nil
        case .text: return text.hasText
        case .live: return liveFeed != nil
        }
    }
}

public struct OverlaySettings: Codable, Equatable {
    /// Total composited layers. Each one is a full-frame compute pass, which
    /// is GPU time — the cheap half of the cost.
    public static let maxLayers = 5
    /// Video layers specifically. This is the cap that matters: a video layer
    /// carries its own decoder and frame FIFO, and three 1080p decoders
    /// already cost more resident memory than the rest of the pipeline
    /// combined (§7, < 250 MB). Text and live layers have no decoder — text
    /// is a rasterisation that only redraws when the string changes, and a
    /// live feed is a capture session that already exists — which is why the
    /// total can rise above three while this one cannot.
    public static let maxVideoLayers = 3

    public var layers: [OverlayLayer] = []
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = c.tolerant(.layers, [])
    }

    /// Admission in the user's own order, so which layers survive the caps is
    /// a consequence of how they arranged the list rather than of how the
    /// filter happened to be written. A flat prefix would let three video
    /// layers at the top starve the text layer below them of a slot that
    /// costs no decoder to give.
    private func admitted(_ include: (OverlayLayer) -> Bool) -> [OverlayLayer] {
        var result: [OverlayLayer] = []
        var videoCount = 0
        for layer in layers where include(layer) {
            if result.count == Self.maxLayers { break }
            if layer.sourceKind == .video {
                guard videoCount < Self.maxVideoLayers else { continue }
                videoCount += 1
            }
            result.append(layer)
        }
        return result
    }

    public var renderableLayers: [OverlayLayer] {
        admitted { $0.isRenderable }
    }

    /// The layers the stage keeps a media source for. Deliberately not
    /// filtered by `isRenderable`: a layer whose opacity is momentarily at
    /// zero, or whose file picker is open, must keep its decoder, because
    /// releasing it would restart a running video mid-slider-drag.
    public var mediaLayers: [OverlayLayer] {
        admitted { _ in true }
    }

    /// True when any enabled layer sits behind the subject — that is what
    /// makes the overlay stage a mask consumer.
    public var needsPersonMask: Bool {
        renderableLayers.contains { $0.placement == .behind }
    }
}

// MARK: - Style — preset visual effects (§5.4)

/// The preset effects, curated toward what plays on a live call: warps,
/// glitches and motion trails, plus a few gadget-camera looks — not color
/// filters. Raw values are persisted in presets AND generate the kernel
/// names (`prism_style_<raw>`), so renaming a case is a preset-format
/// change and a kernel rename — don't. Removed cases decode as .normal via
/// the tolerant fallback, so old presets degrade to the unstyled picture.
public enum StyleEffect: String, Codable, CaseIterable, Identifiable {
    case normal
    // Looks — the gadget cameras.
    case thermal, xray, nightVision, vhs, pixellate
    // Distortions — move the picture around (some animated).
    case bulge, dent, twirl, squeeze, mirror, lightTunnel, fisheye, stretch
    case kaleidoscope, wave, underwater, glitch, tinyPlanet, rgbSplit
    // Motion — trails and ghosts of your own movement (feedback history).
    case afterimage, echo, longExposure, strobe

    public var id: String { rawValue }

    /// The three catalogue pages: distortions move pixels, motion effects
    /// remember them, looks recolor them. Normal belongs to none — it is
    /// the unstyled picture.
    public static let looks: [StyleEffect] = [
        .thermal, .xray, .nightVision, .vhs, .pixellate,
    ]
    public static let distortions: [StyleEffect] = [
        .bulge, .dent, .twirl, .squeeze, .fisheye, .stretch, .mirror,
        .lightTunnel, .kaleidoscope, .wave, .underwater, .glitch,
        .tinyPlanet, .rgbSplit,
    ]
    public static let motion: [StyleEffect] = [
        .afterimage, .echo, .longExposure, .strobe,
    ]

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .thermal: return "Thermal Camera"
        case .xray: return "X-Ray"
        case .nightVision: return "Night Vision"
        case .vhs: return "VHS"
        case .pixellate: return "Pixelate"
        case .bulge: return "Bulge"
        case .dent: return "Dent"
        case .twirl: return "Twirl"
        case .squeeze: return "Squeeze"
        case .mirror: return "Mirror"
        case .lightTunnel: return "Light Tunnel"
        case .fisheye: return "Fish Eye"
        case .stretch: return "Stretch"
        case .kaleidoscope: return "Kaleidoscope"
        case .wave: return "Wave"
        case .underwater: return "Underwater"
        case .glitch: return "Glitch"
        case .tinyPlanet: return "Tiny Planet"
        case .rgbSplit: return "RGB Split"
        case .afterimage: return "Afterimage"
        case .echo: return "Echo"
        case .longExposure: return "Long Exposure"
        case .strobe: return "Strobe"
        }
    }

    /// Metal kernel for this effect; nil for .normal (nothing to run).
    public var kernelFunction: String? {
        self == .normal ? nil : "prism_style_\(rawValue)"
    }

    /// Motion effects read a history texture holding the previous styled
    /// frame (the stage blits its output into it each frame). Everything
    /// else is a pure function of the current frame.
    public var isTemporal: Bool {
        Self.motion.contains(self)
    }
}

public struct StyleSettings: Codable, Equatable {
    public var effect: StyleEffect = .normal
    public var intensity: Double = 1       // 0…1
    /// Drive the effect from the microphone level. Off by default: an effect
    /// that pulses with your voice is a stunt, and a preset that silently
    /// coupled the picture to the mic would be a surprise on a call.
    public var audioReactive: Bool = false
    /// How much of the intensity range the level controls. Below 1 so a
    /// silent room still shows the effect — an audio-reactive style that
    /// vanishes between sentences reads as a dropout, not as an effect.
    public var audioDepth: Double = 0.7    // 0…1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        effect = c.tolerant(.effect, .normal)
        intensity = c.tolerant(.intensity, 1)
        audioReactive = c.tolerant(.audioReactive, false)
        audioDepth = c.tolerant(.audioDepth, 0.7)
    }

    public var clampedAudioDepth: Double { min(max(audioDepth, 0), 1) }

    /// "Normal" IS the unstyled picture, so every surface treats
    /// "Style = Normal" and "Style off" as the same state (see `isInert`) —
    /// the LUT / Neutral rule applied to the second catalogue.
    public var isNormal: Bool { effect == .normal }
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.tolerant(.enabled, false)
        pinned = c.tolerant(.pinned, false)
    }
}

// MARK: - Full pipeline configuration (what a preset captures, §5.5)

public struct PipelineConfiguration: Codable, Equatable {
    public var adjust = AdjustSettings()
    public var retouch = RetouchSettings()
    public var lut = LUTSettings()
    public var blur = BlurSettings()
    public var geometry = GeometrySettings()
    public var gaze = GazeSettings()
    public var background = BackgroundSettings()
    public var overlay = OverlaySettings()
    public var style = StyleSettings()

    public var flags: [StageID: StageFlags] = [
        .geometry: StageFlags(), .retouch: StageFlags(),
        .adjust: StageFlags(), .lut: StageFlags(),
        .blur: StageFlags(), .gaze: StageFlags(),
        .background: StageFlags(), .overlay: StageFlags(),
        .style: StageFlags(),
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

    /// True when a stage is switched ON but its parameters make the pass a
    /// no-op, so `wantsEncode()` declines it and the pipeline skips it
    /// entirely (§5.4 fast paths: Adjust at identity, LUT at Neutral or zero
    /// strength, Geometry at identity, Overlay with no file).
    ///
    /// Skipping the pass is right — it is free latency. Saying nothing about
    /// it is not: a switch that is on and changes nothing is indistinguishable
    /// from a broken one, and that is exactly how it gets reported. Every
    /// surface that draws the switch reads this so it can say which it is.
    public func isInert(_ id: StageID) -> Bool {
        guard flags(for: id).enabled else { return false }
        switch id {
        case .adjust:
            return adjust.isIdentity
        case .lut:
            return lut.isNeutral || lut.strength <= 0
        case .geometry:
            return geometry.isIdentity
        case .overlay:
            return overlay.renderableLayers.isEmpty
        case .style:
            return style.isNormal || style.intensity <= 0
        case .blur, .background, .gaze, .retouch, .clip, .replay, .freeze,
             .connection, .outputFit:
            // These change the picture whenever they are on (background
            // replacement falls back to its colour rather than to nothing,
            // blur waits for the mask rather than declining, and connection's
            // severity is floored above zero for exactly this reason).
            return false
        }
    }

    /// Why the stage is doing nothing, in the user's words — nil when it is
    /// doing something. Lives here rather than in either Effects surface so
    /// the popover and the main window cannot drift apart on the answer.
    public func inertReason(_ id: StageID) -> String? {
        guard isInert(id) else { return nil }
        switch id {
        case .adjust:
            return "On, but every adjustment is still at its default."
        case .lut:
            return lut.strength <= 0
                ? "On, but strength is 0."
                : "On, but Neutral is the identity LUT."
        case .geometry:
            return "On, but framing is still at its default."
        case .overlay:
            return "On, but no layer has a file or any text."
        case .style:
            return style.intensity <= 0
                ? "On, but intensity is 0."
                : "On, but Normal is the unstyled picture."
        default:
            return nil
        }
    }

    public enum CodingKeys: String, CodingKey {
        case adjust, retouch, lut, blur, geometry, gaze, background, overlay, style
        case flags, format, latencyPolicy, cameraID, microphoneID
    }

    // Synthesised Codable does not fall back to property defaults for absent
    // keys — it throws. That would mean every saved configuration and every
    // user preset written by an earlier build fails to decode the moment
    // this struct gains a field, and the user silently loses their whole
    // setup on upgrade. Decoding each field independently makes new fields
    // additive and old files forward-compatible; `encode` stays synthesised.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        adjust = decode(.adjust, AdjustSettings())
        retouch = decode(.retouch, RetouchSettings())
        lut = decode(.lut, LUTSettings())
        blur = decode(.blur, BlurSettings())
        geometry = decode(.geometry, GeometrySettings())
        gaze = decode(.gaze, GazeSettings())
        background = decode(.background, BackgroundSettings())
        overlay = decode(.overlay, OverlaySettings())
        style = decode(.style, StyleSettings())
        flags = decode(.flags, [:])
        format = decode(.format, VideoFormat(width: 1920, height: 1080, frameRate: 30))
        latencyPolicy = decode(.latencyPolicy, LatencyPolicy.balanced)
        cameraID = (try? container.decodeIfPresent(String.self, forKey: .cameraID)) ?? nil
        microphoneID = (try? container.decodeIfPresent(String.self, forKey: .microphoneID)) ?? nil
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
public struct HotkeyCombo: Codable, Equatable, Hashable {
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

    /// The modifiers tolerate absence; the keycode deliberately does not.
    /// A combo defaulting its keycode would silently become ⌥⌘A — binding a
    /// user to a chord they never chose is worse than dropping the binding
    /// and falling back to the default, which is what a throw here does at
    /// the enclosing tolerant level.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        option = c.tolerant(.option, false)
        command = c.tolerant(.command, false)
        shift = c.tolerant(.shift, false)
        control = c.tolerant(.control, false)
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
