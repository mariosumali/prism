// SceneCompositingTests.swift
// PRISMTests
//
// Placement geometry for virtual backgrounds (§5.7) and overlay layers
// (§5.8), plus the studio behaviour settings behind replay, away and panic
// (§5.9–§5.11).
//
// The placement matrices map output UV → source UV, so the tests read
// backwards from how the picture is described: "the layer's centre lands at
// the frame's centre" is asserted as "the frame's centre maps to the layer's
// centre".
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import XCTest
import simd

final class SceneCompositingTests: XCTestCase {

    private let hd = CGSize(width: 1920, height: 1080)

    private func map(_ matrix: simd_float3x3, _ point: SIMD2<Float>) -> SIMD2<Float> {
        let result = matrix * SIMD3<Float>(point.x, point.y, 1)
        return SIMD2<Float>(result.x, result.y)
    }

    // MARK: - Background fit (§5.7)

    func testBackgroundFillCoversTheFrame() {
        // A 4:3 backdrop in a 16:9 frame must cover, cropping the sides.
        let (scale, offset) = BackgroundStage.fit(
            contentSize: CGSize(width: 1440, height: 1080),
            outputSize: hd, mode: .fill)
        XCTAssertGreaterThanOrEqual(scale.x, 1)
        XCTAssertGreaterThanOrEqual(scale.y, 1)
        // Content is centred, so the overhang is split evenly.
        XCTAssertEqual(offset.x, (1 - scale.x) / 2, accuracy: 1e-6)
        XCTAssertEqual(offset.y, (1 - scale.y) / 2, accuracy: 1e-6)
    }

    func testBackgroundLetterboxFitsInsideTheFrame() {
        let (scale, offset) = BackgroundStage.fit(
            contentSize: CGSize(width: 1440, height: 1080),
            outputSize: hd, mode: .letterbox)
        XCTAssertLessThanOrEqual(scale.x, 1 + 1e-6)
        XCTAssertLessThanOrEqual(scale.y, 1 + 1e-6)
        XCTAssertGreaterThanOrEqual(offset.x, -1e-6)
        XCTAssertGreaterThanOrEqual(offset.y, -1e-6)
    }

    func testBackgroundFitPreservesAspectInBothModes() {
        let content = CGSize(width: 1000, height: 500)   // 2:1
        for mode in [ClipFillMode.fill, .letterbox] {
            let (scale, _) = BackgroundStage.fit(contentSize: content,
                                                 outputSize: hd, mode: mode)
            // One axis is exactly 1 and the other carries the whole ratio —
            // that is what "never stretch" means numerically.
            let touchesOne = abs(scale.x - 1) < 1e-6 || abs(scale.y - 1) < 1e-6
            XCTAssertTrue(touchesOne, "mode \(mode) stretched the backdrop")
        }
    }

    func testBackgroundFitToleratesDegenerateSizes() {
        let (scale, offset) = BackgroundStage.fit(contentSize: .zero,
                                                  outputSize: hd, mode: .fill)
        XCTAssertEqual(scale, SIMD2<Float>(1, 1))
        XCTAssertEqual(offset, SIMD2<Float>(0, 0))
    }

    // MARK: - Overlay placement (§5.8)

    private func layer(scale: Double = 1,
                       offsetX: Double = 0,
                       offsetY: Double = 0,
                       rotation: Double = 0,
                       mirrored: Bool = false) -> OverlayLayer {
        OverlayLayer(name: "test",
                     scale: scale,
                     offsetX: offsetX,
                     offsetY: offsetY,
                     rotationDegrees: rotation,
                     mirrored: mirrored)
    }

    func testCentredLayerMapsFrameCentreToLayerCentre() {
        let matrix = OverlayStage.placement(layer: layer(),
                                            contentSize: hd, outputSize: hd)
        let mapped = map(matrix, SIMD2<Float>(0.5, 0.5))
        XCTAssertEqual(mapped.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(mapped.y, 0.5, accuracy: 1e-5)
    }

    func testMatchingAspectAtScaleOneIsIdentity() {
        let matrix = OverlayStage.placement(layer: layer(),
                                            contentSize: hd, outputSize: hd)
        for point in [SIMD2<Float>(0, 0), SIMD2<Float>(1, 1), SIMD2<Float>(0.25, 0.75)] {
            let mapped = map(matrix, point)
            XCTAssertEqual(mapped.x, point.x, accuracy: 1e-5)
            XCTAssertEqual(mapped.y, point.y, accuracy: 1e-5)
        }
    }

    /// Halving the size means the layer occupies half the frame, so frame UV
    /// runs through layer UV twice as fast.
    func testHalfScaleDoublesTheSamplingRate() {
        let matrix = OverlayStage.placement(layer: layer(scale: 0.5),
                                            contentSize: hd, outputSize: hd)
        let centre = map(matrix, SIMD2<Float>(0.5, 0.5))
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-5)
        // A quarter of the way across the frame is a quarter *before* the
        // layer's left edge at half scale: 0.5 − 0.25/0.5 = 0.0.
        let quarter = map(matrix, SIMD2<Float>(0.25, 0.5))
        XCTAssertEqual(quarter.x, 0.0, accuracy: 1e-5)
    }

    func testOffsetMovesTheLayerAndNotTheSampling() {
        // offsetX = 1 puts the layer's centre at the frame's right edge.
        let matrix = OverlayStage.placement(layer: layer(offsetX: 1),
                                            contentSize: hd, outputSize: hd)
        let mapped = map(matrix, SIMD2<Float>(1.0, 0.5))
        XCTAssertEqual(mapped.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(mapped.y, 0.5, accuracy: 1e-5)
    }

    func testMirrorFlipsHorizontallyAboutTheCentre() {
        let matrix = OverlayStage.placement(layer: layer(mirrored: true),
                                            contentSize: hd, outputSize: hd)
        let centre = map(matrix, SIMD2<Float>(0.5, 0.5))
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-5)
        let left = map(matrix, SIMD2<Float>(0.25, 0.5))
        XCTAssertEqual(left.x, 0.75, accuracy: 1e-5)
        XCTAssertEqual(left.y, 0.5, accuracy: 1e-5, "mirroring must not touch y")
    }

    func testRotationIsAboutTheLayerCentre() {
        let matrix = OverlayStage.placement(layer: layer(rotation: 90),
                                            contentSize: hd, outputSize: hd)
        let centre = map(matrix, SIMD2<Float>(0.5, 0.5))
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(centre.y, 0.5, accuracy: 1e-5)
    }

    /// A square PNG dropped into a 16:9 frame must stay square, not stretch
    /// to fill — the same "never stretch" rule the output fit follows.
    func testSquareLayerKeepsItsAspectInAWideFrame() {
        let square = CGSize(width: 512, height: 512)
        let matrix = OverlayStage.placement(layer: layer(),
                                            contentSize: square, outputSize: hd)
        // The layer is fitted, so it spans the full height and 9/16 of the
        // width: half a frame-height above centre is the layer's top edge.
        let top = map(matrix, SIMD2<Float>(0.5, 0.0))
        XCTAssertEqual(top.y, 0.0, accuracy: 1e-5)
        // …while the frame's left edge falls well outside the layer.
        let left = map(matrix, SIMD2<Float>(0.0, 0.5))
        XCTAssertLessThan(left.x, 0)
    }

    func testPlacementToleratesDegenerateSizes() {
        let matrix = OverlayStage.placement(layer: layer(),
                                            contentSize: .zero, outputSize: hd)
        XCTAssertEqual(matrix, matrix_identity_float3x3)
    }

    // MARK: - Overlay settings

    func testRenderableLayersSkipDisabledAndFilelessLayers() {
        var settings = OverlaySettings()
        settings.layers = [
            OverlayLayer(name: "on", assetPath: "/tmp/a.png"),
            OverlayLayer(name: "off", isEnabled: false, assetPath: "/tmp/b.png"),
            OverlayLayer(name: "no file"),
        ]
        XCTAssertEqual(settings.renderableLayers.map(\.name), ["on"])
    }

    func testRenderableLayersAreCappedAtTheDocumentedMaximum() {
        var settings = OverlaySettings()
        settings.layers = (0..<10).map {
            OverlayLayer(name: "layer\($0)", assetPath: "/tmp/\($0).png")
        }
        XCTAssertEqual(settings.renderableLayers.count, OverlaySettings.maxLayers)
    }

    func testNeedsPersonMaskOnlyForBehindLayers() {
        var settings = OverlaySettings()
        settings.layers = [OverlayLayer(name: "front", assetPath: "/tmp/a.png")]
        XCTAssertFalse(settings.needsPersonMask)

        settings.layers = [OverlayLayer(name: "behind", assetPath: "/tmp/a.png",
                                        placement: .behind)]
        XCTAssertTrue(settings.needsPersonMask)
    }

    // MARK: - Background settings

    /// An image or video background with no file chosen must fall back to the
    /// colour, never to the real room — this stage exists partly for privacy.
    func testBackgroundWithoutAssetResolvesToColour() {
        var settings = BackgroundSettings()
        settings.kind = .image
        settings.assetPath = nil
        XCTAssertEqual(settings.resolvedKind, .color)

        settings.assetPath = "/tmp/backdrop.png"
        XCTAssertEqual(settings.resolvedKind, .image)
    }

    func testBackgroundDefaultsToFillNotLetterbox() {
        XCTAssertEqual(BackgroundSettings().fillMode, .fill,
                       "a letterboxed backdrop reads as a bug")
    }
}
