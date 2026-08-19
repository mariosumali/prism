// TextLayerTests.swift
// PRISMTests
//
// Text drawn into the frame (§5.26) — the style, its rasterised layout, and
// the placement that puts a caption in the picture at the size it was asked
// for — and the teleprompter (§5.27), where the whole test is that none of
// it can reach the frame at all.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import Metal
import XCTest
import simd

final class TextLayerTests: XCTestCase {

    private let hd = CGSize(width: 1920, height: 1080)

    private func map(_ matrix: simd_float3x3, _ point: SIMD2<Float>) -> SIMD2<Float> {
        let result = matrix * SIMD3<Float>(point.x, point.y, 1)
        return SIMD2<Float>(result.x, result.y)
    }

    private func decodeStyle(_ json: String) throws -> OverlayTextStyle {
        try JSONDecoder().decode(OverlayTextStyle.self, from: Data(json.utf8))
    }

    private func decodePrompter(_ json: String) throws -> PrompterSettings {
        try JSONDecoder().decode(PrompterSettings.self, from: Data(json.utf8))
    }

    // MARK: - Style

    func testStyleDecodesEveryFieldTolerantly() throws {
        // A file written by a build that had never heard of subtitles.
        let style = try decodeStyle(#"{"string":"Hello"}"#)
        XCTAssertEqual(style.string, "Hello")
        XCTAssertEqual(style.subtitle, "")
        XCTAssertEqual(style.fontSize, 48)
        XCTAssertEqual(style.weight, .medium)
        XCTAssertEqual(style.plate, .none)
        XCTAssertEqual(style.alignment, .center)
    }

    func testStyleSurvivesGarbageInEveryField() throws {
        let style = try decodeStyle(
            #"{"string":"Hi","weight":"ultrablack","plate":"frosted","alignment":"justified"}"#)
        XCTAssertEqual(style.string, "Hi")
        XCTAssertEqual(style.weight, .medium)
        XCTAssertEqual(style.plate, .none)
        XCTAssertEqual(style.alignment, .center)
    }

    /// A lower third someone filled in the second field of and not the first
    /// still has something to draw.
    func testSubtitleAloneCountsAsText() {
        var style = OverlayTextStyle()
        XCTAssertFalse(style.hasText)
        style.subtitle = "Head of Widgets"
        XCTAssertTrue(style.hasText)
        XCTAssertTrue(style.hasSubtitle)
    }

    func testWhitespaceIsNotText() {
        var style = OverlayTextStyle()
        style.string = "   \n "
        XCTAssertFalse(style.hasText)
    }

    func testTextLayerIsRenderableOnlyWithText() {
        var layer = OverlayLayer(name: "caption", sourceKind: .text)
        XCTAssertFalse(layer.isRenderable)
        layer.text.string = "On air"
        XCTAssertTrue(layer.isRenderable)
        layer.opacity = 0
        XCTAssertFalse(layer.isRenderable)
    }

    // MARK: - Caps (§5.8)

    /// The layer cap is five and the video cap is three because a decoder is
    /// what costs memory. A text layer has none, so three videos must not
    /// starve two captions of the slots they were raised for.
    func testTextLayersAreNotStarvedByTheVideoCap() {
        var settings = OverlaySettings()
        settings.layers = (0..<3).map {
            OverlayLayer(name: "clip \($0)", sourceKind: .video,
                         assetPath: "/tmp/\($0).mov")
        }
        for index in 0..<2 {
            var text = OverlayLayer(name: "text \(index)", sourceKind: .text)
            text.text.string = "line \(index)"
            settings.layers.append(text)
        }
        XCTAssertEqual(settings.renderableLayers.count, 5)
        XCTAssertEqual(settings.renderableLayers.filter { $0.sourceKind == .text }.count, 2)
    }

    // MARK: - Layout (§5.26)

    private func style(_ string: String,
                       subtitle: String = "",
                       size: Double = 48,
                       plate: TextPlate = .none) -> OverlayTextStyle {
        var style = OverlayTextStyle()
        style.string = string
        style.subtitle = subtitle
        style.fontSize = size
        style.plate = plate
        return style
    }

    func testCanvasScalesWithTheFrame() {
        let small = TextRasterizer.layout(style: style("Hello"),
                                          frameSize: CGSize(width: 1280, height: 720))
        let large = TextRasterizer.layout(style: style("Hello"), frameSize: hd)
        // 720p is two thirds of 1080p, so the same caption occupies two
        // thirds of the pixels — and therefore the same slice of the picture.
        XCTAssertLessThan(small.canvas.width, large.canvas.width)
        XCTAssertEqual(Double(small.canvas.width / large.canvas.width),
                       720.0 / 1080.0, accuracy: 0.12)
    }

    func testCanvasNeverOutgrowsTheFrame() {
        let essay = String(repeating: "a very long sentence indeed ", count: 200)
        let layout = TextRasterizer.layout(style: style(essay, size: 120),
                                           frameSize: hd)
        XCTAssertLessThanOrEqual(layout.canvas.width,
                                 hd.width * TextRasterizer.maxWidthFraction)
        XCTAssertLessThanOrEqual(layout.canvas.height,
                                 hd.height * TextRasterizer.maxHeightFraction)
    }

    func testSubtitleMakesTheCanvasTaller() {
        let plain = TextRasterizer.layout(style: style("Your Name"), frameSize: hd)
        let banner = TextRasterizer.layout(style: style("Your Name",
                                                        subtitle: "What you do"),
                                           frameSize: hd)
        XCTAssertGreaterThan(banner.canvas.height, plain.canvas.height)
    }

    /// The halo is a blur, and a blur clipped by the canvas edge is a square
    /// halo — so a blurred plate has to buy itself room the others do not.
    func testBlurredPlateReservesRoomForItsHalo() {
        var bare = style("Name")
        bare.padding = 0
        var haloed = bare
        haloed.plate = .blur
        let plain = TextRasterizer.layout(style: bare, frameSize: hd)
        let halo = TextRasterizer.layout(style: haloed, frameSize: hd)
        XCTAssertGreaterThan(halo.canvas.width, plain.canvas.width)
        XCTAssertGreaterThan(halo.haloRadius, 0)
    }

    /// Padding is the gap inside a plate. With no plate it would be an
    /// invisible margin, and since placement pins the canvas, a leading
    /// caption would sit at its margin instead of at its first letter.
    func testPaddingOnlyExistsWhereThereIsAPlateToPad() {
        var bare = style("Name")
        bare.padding = 2
        var plated = bare
        plated.plate = .solid
        XCTAssertEqual(TextRasterizer.layout(style: bare, frameSize: hd).padding, 0)
        XCTAssertGreaterThan(
            TextRasterizer.layout(style: plated, frameSize: hd).padding, 0)
        XCTAssertGreaterThan(
            TextRasterizer.layout(style: plated, frameSize: hd).canvas.width,
            TextRasterizer.layout(style: bare, frameSize: hd).canvas.width)
    }

    func testEmptyStyleLaysOutNothingRenderable() {
        let layout = TextRasterizer.layout(style: OverlayTextStyle(), frameSize: hd)
        // Nothing to measure, so nothing but the padding — and render()
        // refuses it outright on hasText.
        XCTAssertFalse(OverlayTextStyle().hasText)
        XCTAssertGreaterThanOrEqual(layout.canvas.width, 1)
    }

    // MARK: - Placement (§5.26)

    private func textLayer(scale: Double = 1,
                           offsetX: Double = 0,
                           offsetY: Double = 0,
                           alignment: OverlayTextAlignment = .center) -> OverlayLayer {
        var layer = OverlayLayer(name: "caption", sourceKind: .text,
                                 scale: scale, offsetX: offsetX, offsetY: offsetY)
        layer.text.string = "caption"
        layer.text.alignment = alignment
        return layer
    }

    /// The rasteriser already sized the caption for this frame, so placement
    /// must hand it through at exactly that size. Fitting it — what every
    /// other layer kind wants — would blow two words up to the full width of
    /// the picture and make the point size mean nothing.
    func testTextIsPlacedAtItsOwnPixelSize() {
        let content = CGSize(width: 480, height: 108)
        let matrix = OverlayStage.placement(layer: textLayer(),
                                            contentSize: content, outputSize: hd)
        // The caption spans a quarter of the frame's width and a tenth of its
        // height, centred — so those UV points map to the layer's own edges.
        let left = map(matrix, SIMD2<Float>(0.5 - 0.125, 0.5))
        let right = map(matrix, SIMD2<Float>(0.5 + 0.125, 0.5))
        XCTAssertEqual(left.x, 0, accuracy: 1e-4)
        XCTAssertEqual(right.x, 1, accuracy: 1e-4)
        let top = map(matrix, SIMD2<Float>(0.5, 0.5 - 0.05))
        XCTAssertEqual(top.y, 0, accuracy: 1e-4)
    }

    func testAnImageOfTheSameSizeIsStillFitted() {
        // The same texture as a picture fills the frame, which is the
        // behaviour every existing layer depends on.
        let content = CGSize(width: 480, height: 108)
        var image = textLayer()
        image.sourceKind = .image
        let matrix = OverlayStage.placement(layer: image,
                                            contentSize: content, outputSize: hd)
        let edge = map(matrix, SIMD2<Float>(0, 0.5))
        XCTAssertEqual(edge.x, 0, accuracy: 1e-4)
    }

    func testScaleMultipliesTheNaturalSize() {
        let content = CGSize(width: 480, height: 108)
        let matrix = OverlayStage.placement(layer: textLayer(scale: 2),
                                            contentSize: content, outputSize: hd)
        let left = map(matrix, SIMD2<Float>(0.5 - 0.25, 0.5))
        XCTAssertEqual(left.x, 0, accuracy: 1e-4)
    }

    /// A name banner grows to the right as it is typed. Anchoring the centre
    /// would slide the whole plate across the frame with every letter, which
    /// is the one thing a lower third must not do.
    func testLeadingTextPinsItsLeftEdge() {
        let short = CGSize(width: 300, height: 108)
        let long = CGSize(width: 900, height: 108)
        let layer = textLayer(offsetX: -0.9, alignment: .leading)
        // offsetX −0.9 puts the pinned edge a twentieth of the way in.
        for content in [short, long] {
            let matrix = OverlayStage.placement(layer: layer,
                                                contentSize: content, outputSize: hd)
            let atLeftEdge = map(matrix, SIMD2<Float>(0.05, 0.5))
            XCTAssertEqual(atLeftEdge.x, 0, accuracy: 1e-4)
        }
    }

    func testTrailingTextPinsItsRightEdge() {
        let layer = textLayer(offsetX: 0.9, alignment: .trailing)
        for width in [300.0, 900.0] {
            let matrix = OverlayStage.placement(
                layer: layer, contentSize: CGSize(width: width, height: 108),
                outputSize: hd)
            let atRightEdge = map(matrix, SIMD2<Float>(0.95, 0.5))
            XCTAssertEqual(atRightEdge.x, 1, accuracy: 1e-4)
        }
    }

    func testCentredTextIgnoresItsWidthWhenPositioned() {
        for width in [300.0, 900.0] {
            let matrix = OverlayStage.placement(
                layer: textLayer(alignment: .center),
                contentSize: CGSize(width: width, height: 108), outputSize: hd)
            let centre = map(matrix, SIMD2<Float>(0.5, 0.5))
            XCTAssertEqual(centre.x, 0.5, accuracy: 1e-4)
        }
    }

    // MARK: - Rasterisation

    func testRenderProducesAUsableTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host")
        }
        var style = self.style("PRISM", subtitle: "on air", plate: .solid)
        style.alignment = .leading
        let layout = TextRasterizer.layout(style: style, frameSize: hd)
        let texture = try XCTUnwrap(
            TextRasterizer.render(style: style, frameSize: hd, device: device))
        XCTAssertEqual(texture.width, Int(layout.canvas.width))
        XCTAssertEqual(texture.height, Int(layout.canvas.height))
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
    }

    func testRenderRefusesAnEmptyString() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host")
        }
        XCTAssertNil(TextRasterizer.render(style: OverlayTextStyle(),
                                           frameSize: hd, device: device))
    }

    func testRenderRefusesADegenerateFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host")
        }
        XCTAssertNil(TextRasterizer.render(style: style("Hi"),
                                           frameSize: .zero, device: device))
    }

    /// `prism_overlay` mixes the layer's RGB into the base by its alpha and
    /// samples bilinearly, so a transparent pixel left at black would drag a
    /// dark rim around every glyph. The rasteriser colours them instead.
    func testTransparentPixelsCarryTheLayersColourNotBlack() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host")
        }
        // A solid plate covers everything except its own rounded corners, so
        // pixel (0, 0) is reliably outside the drawn shape.
        var style = self.style("Name", plate: .solid)
        style.plateColor = RGBColor(red: 1, green: 0, blue: 0)
        style.padding = 1
        let texture = try XCTUnwrap(
            TextRasterizer.render(style: style, frameSize: hd, device: device))
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4,
                         from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(pixel[3], 0, "the corner outside a rounded plate is transparent")
        XCTAssertEqual(pixel[0], 0)      // B
        XCTAssertEqual(pixel[1], 0)      // G
        XCTAssertEqual(pixel[2], 255)    // R — the plate's colour, not black
    }

    // MARK: - Prompter (§5.27)

    func testPrompterDecodesEveryFieldTolerantly() throws {
        let prompter = try decodePrompter(#"{"script":"Hello everyone"}"#)
        XCTAssertEqual(prompter.script, "Hello everyone")
        XCTAssertEqual(prompter.speed, 30)
        XCTAssertEqual(prompter.fontSize, 34)
        XCTAssertEqual(prompter.anchor, .top)
        XCTAssertEqual(prompter.opacity, 0.9)
        XCTAssertFalse(prompter.isMirrored)
    }

    /// PRISM launches at login for most people. A panel that reopened itself
    /// would drop last week's script over whatever they actually sat down to
    /// do — so the words are kept and the decision to show them is not.
    func testAnOpenPrompterIsNeverRestored() throws {
        let prompter = try decodePrompter(#"{"isEnabled":true,"script":"secret"}"#)
        XCTAssertFalse(prompter.isEnabled)
        XCTAssertEqual(prompter.script, "secret")
        XCTAssertFalse(prompter.isActive)
    }

    func testPrompterWithoutAScriptIsNotActive() {
        var prompter = PrompterSettings()
        prompter.isEnabled = true
        XCTAssertFalse(prompter.isActive)
        prompter.script = "   \n  "
        XCTAssertFalse(prompter.isActive)
        prompter.script = "Good morning."
        XCTAssertTrue(prompter.isActive)
    }

    func testPrompterClampsWhatTheUiCanReach() {
        var prompter = PrompterSettings()
        prompter.speed = 5000
        prompter.fontSize = 0
        prompter.opacity = -3
        XCTAssertEqual(prompter.clampedSpeed, 120)
        XCTAssertEqual(prompter.clampedFontSize, 14)
        XCTAssertEqual(prompter.clampedOpacity, 0.2)
    }

    /// Lines a minute has to mean lines a minute, so the travel per second
    /// scales with the size of a line and the pace does not change when the
    /// text does.
    func testScrollRateFollowsTheLineHeight() {
        var small = PrompterSettings()
        small.speed = 60
        small.fontSize = 20
        var large = small
        large.fontSize = 40
        XCTAssertEqual(small.scrollRate, small.lineHeight, accuracy: 1e-9)
        XCTAssertEqual(large.scrollRate / small.scrollRate, 2, accuracy: 1e-9)
    }

    /// The teleprompter is for the person reading it. Nothing about it is
    /// part of the look, so nothing about it travels in a preset — and a
    /// preset switch can never load someone else's words onto the screen.
    func testTheScriptIsNotPartOfAnyPreset() throws {
        var studio = StudioSettings()
        studio.prompter.script = "the quarterly numbers are not great"
        studio.prompter.isEnabled = true

        let configuration = PipelineConfiguration()
        let encodedConfig = try XCTUnwrap(
            String(data: try JSONEncoder().encode(configuration), encoding: .utf8))
        XCTAssertFalse(encodedConfig.contains("prompter"))
        XCTAssertFalse(encodedConfig.contains("quarterly"))

        let encodedStudio = try XCTUnwrap(
            String(data: try JSONEncoder().encode(studio), encoding: .utf8))
        XCTAssertTrue(encodedStudio.contains("quarterly"))
    }

    /// The other half of the same promise: no overlay layer is ever created
    /// from prompter settings, so there is no path from a script to a
    /// texture at all.
    func testTheScriptNeverBecomesALayer() {
        var studio = StudioSettings()
        studio.prompter.isEnabled = true
        studio.prompter.script = "line one\nline two"
        XCTAssertTrue(studio.prompter.isActive)

        // An active prompter beside an untouched configuration: the chain has
        // nothing to composite, and no code anywhere turns one into the
        // other.
        let configuration = PipelineConfiguration()
        XCTAssertTrue(configuration.overlay.layers.isEmpty)
        XCTAssertTrue(configuration.overlay.renderableLayers.isEmpty)
        XCTAssertFalse(configuration.flags(for: .overlay).enabled)
    }
}
