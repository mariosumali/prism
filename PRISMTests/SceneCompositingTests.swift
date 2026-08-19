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

    // MARK: - Face-anchored placement (§5.8)

    /// A face filling a fifth of the frame width, centred and level.
    private func face(box: CGRect = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3),
                      roll: Float = 0,
                      eyes: Bool = false) -> FaceTracker.FaceSample {
        func eye(_ x: Float) -> FaceTracker.EyeMeasurement {
            FaceTracker.EyeMeasurement(lidCenter: SIMD2<Float>(x, 0.38),
                                       lidRadii: SIMD2<Float>(0.02, 0.012),
                                       irisCenter: SIMD2<Float>(x, 0.38),
                                       irisRadii: SIMD2<Float>(0.008, 0.014))
        }
        return FaceTracker.FaceSample(box: box, roll: roll,
                                      left: eyes ? eye(0.46) : nil,
                                      right: eyes ? eye(0.54) : nil)
    }

    private func faceLayer(point: FaceAnchorPoint = .face,
                           scale: Double = 1,
                           offsetX: Double = 0,
                           offsetY: Double = 0,
                           followsRoll: Bool = false) -> OverlayLayer {
        OverlayLayer(name: "prop", scale: scale, offsetX: offsetX, offsetY: offsetY,
                     anchor: .face, facePoint: point, followsRoll: followsRoll)
    }

    /// The whole-face anchor puts the layer's centre on the face's centre.
    func testFaceAnchorCentresOnTheFace() {
        let sample = face()
        let matrix = OverlayStage.facePlacement(
            layer: faceLayer(), contentSize: hd, frameSize: hd,
            face: sample, geometry: matrix_identity_float3x3)
        let mapped = map(matrix, SIMD2<Float>(Float(sample.box.midX),
                                              Float(sample.box.midY)))
        XCTAssertEqual(mapped.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(mapped.y, 0.5, accuracy: 1e-5)
    }

    /// Size 1 means "as wide as my face", which is what makes a prop keep its
    /// proportion as someone leans toward the camera and back out again.
    func testSizeOneSpansExactlyTheFaceWidth() {
        let sample = face()
        let matrix = OverlayStage.facePlacement(
            layer: faceLayer(), contentSize: hd, frameSize: hd,
            face: sample, geometry: matrix_identity_float3x3)
        // The face box's left edge is the layer's left edge.
        let left = map(matrix, SIMD2<Float>(Float(sample.box.minX),
                                            Float(sample.box.midY)))
        XCTAssertEqual(left.x, 0, accuracy: 1e-5)
        let right = map(matrix, SIMD2<Float>(Float(sample.box.maxX),
                                             Float(sample.box.midY)))
        XCTAssertEqual(right.x, 1, accuracy: 1e-5)
    }

    /// Twice as close to the camera is twice the prop — the point of measuring
    /// scale against the face rather than the frame.
    func testPropGrowsWithTheFace() {
        // How fast layer UV runs as you cross the frame: the bigger the prop,
        // the slower it runs.
        func samplingRate(_ box: CGRect) -> Float {
            let matrix = OverlayStage.facePlacement(
                layer: faceLayer(), contentSize: hd, frameSize: hd,
                face: face(box: box), geometry: matrix_identity_float3x3)
            let centre = Float(box.midX)
            let atCentre = map(matrix, SIMD2<Float>(centre, Float(box.midY))).x
            let atOffset = map(matrix, SIMD2<Float>(centre + 0.05, Float(box.midY))).x
            return (atOffset - atCentre) / 0.05
        }
        let near = samplingRate(CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6))
        let far = samplingRate(CGRect(x: 0.45, y: 0.35, width: 0.1, height: 0.15))
        XCTAssertLessThan(near, far)
        XCTAssertEqual(far / near, 4, accuracy: 1e-3,
                       "a face four times as wide must carry a prop four times as wide")
    }

    /// Offsets are in face widths, not frame widths, so a nudge means the
    /// same thing however far away the person is sitting.
    func testOffsetIsMeasuredInFaceWidths() {
        let sample = face()
        let matrix = OverlayStage.facePlacement(
            layer: faceLayer(offsetX: 1), contentSize: hd, frameSize: hd,
            face: sample, geometry: matrix_identity_float3x3)
        let shifted = SIMD2<Float>(Float(sample.box.midX + sample.box.width),
                                   Float(sample.box.midY))
        let mapped = map(matrix, shifted)
        XCTAssertEqual(mapped.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(mapped.y, 0.5, accuracy: 1e-5)
    }

    /// The rotation slider spins the artwork in place. Having it drag the
    /// layer's position around as well would make the two controls fight,
    /// and it does not do that on a frame-anchored layer either.
    func testRotationSpinsTheArtworkWithoutMovingIt() {
        let sample = face()
        func centre(_ rotation: Double) -> SIMD2<Float> {
            var layer = faceLayer(offsetX: 0.5, offsetY: -0.4)
            layer.rotationDegrees = rotation
            let matrix = OverlayStage.facePlacement(
                layer: layer, contentSize: hd, frameSize: hd,
                face: sample, geometry: matrix_identity_float3x3)
            // Search is unnecessary: the placement maps the layer's centre to
            // (0.5, 0.5), so invert it once.
            let inverse = matrix.inverse
            let origin = inverse * SIMD3<Float>(0.5, 0.5, 1)
            return SIMD2<Float>(origin.x, origin.y)
        }
        let still = centre(0)
        let spun = centre(120)
        XCTAssertEqual(spun.x, still.x, accuracy: 1e-5)
        XCTAssertEqual(spun.y, still.y, accuracy: 1e-5)
    }

    /// The measured eye midpoint beats any fraction of a bounding box, so
    /// glasses land where the eyes actually are.
    func testEyeAnchorPrefersTheMeasuredEyes() {
        let sample = face(eyes: true)
        let anchor = OverlayStage.anchorPoint(face: sample, point: .eyes,
                                              roll: 0, frameAspect: 16.0 / 9.0)
        XCTAssertEqual(anchor.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(anchor.y, 0.38, accuracy: 1e-5)
    }

    /// Without eye landmarks — a profile turn, a squint the model gives up on
    /// — the box fraction has to carry it rather than the layer vanishing.
    func testEyeAnchorFallsBackToTheBoxWhenNoEyesAreMeasured() {
        let sample = face()
        let anchor = OverlayStage.anchorPoint(face: sample, point: .eyes,
                                              roll: 0, frameAspect: 16.0 / 9.0)
        XCTAssertEqual(anchor.x, Float(sample.box.midX), accuracy: 1e-5)
        XCTAssertLessThan(anchor.y, Float(sample.box.midY),
                          "the eye line sits above the centre of the face")
    }

    /// Ordering, top to bottom, is the whole point of naming the anchors for
    /// what they are worn on.
    func testAnchorPointsRunDownTheFaceInOrder() {
        let sample = face()
        let ys = [FaceAnchorPoint.aboveHead, .eyes, .face, .underNose, .mouth, .chin]
            .map { OverlayStage.anchorPoint(face: sample, point: $0,
                                            roll: 0, frameAspect: 16.0 / 9.0).y }
        XCTAssertEqual(ys, ys.sorted(), "anchors are out of vertical order")
        XCTAssertLessThan(ys[0], Float(sample.box.minY),
                          "a hat belongs above the top of the head")
    }

    /// The landmark moves with the tilt whether or not the prop rotates: a
    /// moustache belongs under the nose wherever the nose has gone.
    func testAnchorPointSwingsWithTheHeadTilt() {
        let sample = face()
        let level = OverlayStage.anchorPoint(face: sample, point: .chin,
                                             roll: 0, frameAspect: 16.0 / 9.0)
        let tilted = OverlayStage.anchorPoint(face: sample, point: .chin,
                                              roll: 0.4, frameAspect: 16.0 / 9.0)
        XCTAssertEqual(level.x, Float(sample.box.midX), accuracy: 1e-5)
        XCTAssertNotEqual(tilted.x, level.x, accuracy: 1e-3)
        XCTAssertLessThan(tilted.y, level.y, "a tilted chin swings up as it swings out")
    }

    /// Roll is only in the transform when the user asked for it — it is the
    /// noisiest quantity the tracker reports.
    func testFollowsRollGatesTheRotation() {
        let sample = face(roll: 0.5)
        let level = OverlayStage.facePlacement(
            layer: faceLayer(), contentSize: hd, frameSize: hd,
            face: sample, geometry: matrix_identity_float3x3)
        let rolled = OverlayStage.facePlacement(
            layer: faceLayer(followsRoll: true), contentSize: hd, frameSize: hd,
            face: sample, geometry: matrix_identity_float3x3)
        let straight = OverlayStage.facePlacement(
            layer: faceLayer(), contentSize: hd, frameSize: hd,
            face: face(roll: 0), geometry: matrix_identity_float3x3)
        XCTAssertEqual(level, straight,
                       "a level prop must not notice the head's roll")
        XCTAssertNotEqual(rolled, straight)
    }

    /// Vision reports roll in a y-up frame and this space is y-down, so the
    /// angle is negated once, on the way in. A positive Vision roll therefore
    /// turns the prop anticlockwise on screen — and a screen point to the
    /// right of the face's centre samples from *below* the layer's middle,
    /// because the placement matrix runs backwards. Pinned because getting
    /// the sign wrong tips every prop onto the wrong shoulder.
    func testRollIsNegatedIntoScreenSpace() {
        let sample = face(roll: 0.3)
        let rolled = OverlayStage.facePlacement(
            layer: faceLayer(followsRoll: true), contentSize: hd, frameSize: hd,
            face: sample, geometry: matrix_identity_float3x3)
        let level = OverlayStage.facePlacement(
            layer: faceLayer(), contentSize: hd, frameSize: hd,
            face: face(roll: 0), geometry: matrix_identity_float3x3)
        let probe = SIMD2<Float>(Float(sample.box.midX) + 0.05,
                                 Float(sample.box.midY))
        XCTAssertEqual(map(level, probe).y, 0.5, accuracy: 1e-5)
        XCTAssertGreaterThan(map(rolled, probe).y, map(level, probe).y)
    }

    /// The face is measured before Geometry and layers land after it, so the
    /// crop has to be composed in or a prop sits where the head used to be.
    func testGeometryIsComposedSoThePropStaysOnTheHead() {
        let sample = face()
        // A 2× centred zoom: output UV → input UV halves around the centre.
        let zoom = simd_float3x3(columns: (SIMD3<Float>(0.5, 0, 0),
                                           SIMD3<Float>(0, 0.5, 0),
                                           SIMD3<Float>(0.25, 0.25, 1)))
        let matrix = OverlayStage.facePlacement(
            layer: faceLayer(), contentSize: hd, frameSize: hd,
            face: sample, geometry: zoom)
        // The face's centre in input UV is at (0.5, 0.45); under the zoom it
        // shows at the output UV that maps back to it.
        let outputOfFaceCentre = SIMD2<Float>(
            (Float(sample.box.midX) - 0.25) / 0.5,
            (Float(sample.box.midY) - 0.25) / 0.5)
        let mapped = map(matrix, outputOfFaceCentre)
        XCTAssertEqual(mapped.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(mapped.y, 0.5, accuracy: 1e-5)
    }

    func testFacePlacementToleratesADegenerateFace() {
        let matrix = OverlayStage.facePlacement(
            layer: faceLayer(), contentSize: hd, frameSize: hd,
            face: face(box: .zero), geometry: matrix_identity_float3x3)
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

    /// Nobody pays for Vision because they dropped a lower third on the
    /// picture: only a layer actually riding the face raises the demand, and
    /// removing it drops the demand again.
    func testNeedsFaceTrackerOnlyForFaceAnchoredLayers() {
        var settings = OverlaySettings()
        settings.layers = [OverlayLayer(name: "lower third", assetPath: "/tmp/a.png")]
        XCTAssertFalse(settings.needsFaceTracker)

        settings.layers.append(OverlayLayer(name: "hat", assetPath: "/tmp/hat.png",
                                            anchor: .face, facePoint: .aboveHead))
        XCTAssertTrue(settings.needsFaceTracker)

        // A layer with nothing to draw is not a reason to run a face request.
        settings.layers[1].assetPath = nil
        XCTAssertFalse(settings.needsFaceTracker)
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
