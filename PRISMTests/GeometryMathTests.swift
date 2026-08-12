// GeometryMathTests.swift
// PRISMTests
//
// Probes GeometryStage.buildUVTransform — the single 3×3 matrix mapping
// output UV to input UV (§5.4) — with hand-derived fixed points: identity
// settings produce the identity mapping, zoom pulls corners inward around a
// fixed center, pan clamps at the croppable margin, mirror flips, quarter
// turns rotate with aspect-preserving fit, fine rotation composes without
// scale drift (determinant check), and a 1:1 crop on 16:9 input narrows the
// sampled width. Requires a Metal device only to compile the stage's
// pipeline state; no frames are rendered and no capture session is touched.
//
// Licensed under the Apache License, Version 2.0.

import simd
import XCTest

final class GeometryMathTests: XCTestCase {

    private static var sharedMetal: MetalContext?
    private static var metalError: Error?
    private static let metalOnce: Void = {
        do { sharedMetal = try MetalContext() } catch { metalError = error }
    }()

    private func makeStage() throws -> GeometryStage {
        _ = Self.metalOnce
        guard let metal = Self.sharedMetal else {
            throw XCTSkip("Metal unavailable: \(String(describing: Self.metalError))")
        }
        return try GeometryStage(metal: metal)
    }

    private let size16x9 = CGSize(width: 1920, height: 1080)
    private let sizeSquare = CGSize(width: 1000, height: 1000)

    /// Applies the output-UV → input-UV matrix to a probe point.
    private func map(_ m: simd_float3x3, _ u: Float, _ v: Float) -> SIMD2<Float> {
        let r = m * SIMD3<Float>(u, v, 1)
        return SIMD2<Float>(r.x / r.z, r.y / r.z)
    }

    private func assertMaps(_ m: simd_float3x3,
                            _ output: (Float, Float),
                            to input: (Float, Float),
                            accuracy: Float = 1e-4,
                            file: StaticString = #filePath, line: UInt = #line) {
        let p = map(m, output.0, output.1)
        XCTAssertEqual(p.x, input.0, accuracy: accuracy,
                       "u: (\(output)) → \(p)", file: file, line: line)
        XCTAssertEqual(p.y, input.1, accuracy: accuracy,
                       "v: (\(output)) → \(p)", file: file, line: line)
    }

    /// Determinant of the 2×2 linear part — the area scale of the mapping.
    private func linearDeterminant(_ m: simd_float3x3) -> Float {
        m.columns.0.x * m.columns.1.y - m.columns.1.x * m.columns.0.y
    }

    // MARK: - Identity

    func testIdentitySettingsYieldIdentityMapping() throws {
        let stage = try makeStage()
        let m = stage.buildUVTransform(inputSize: size16x9)

        for probe: (Float, Float) in [(0, 0), (1, 0), (0, 1), (1, 1),
                                      (0.5, 0.5), (0.25, 0.75)] {
            assertMaps(m, probe, to: probe)
        }
        // Affine: bottom row stays (0, 0, 1).
        XCTAssertEqual(m.columns.0.z, 0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.z, 0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.z, 1, accuracy: 1e-6)
    }

    func testIdentityIsAspectIndependent() throws {
        let stage = try makeStage()
        let m = stage.buildUVTransform(inputSize: sizeSquare)
        assertMaps(m, (0, 0), to: (0, 0))
        assertMaps(m, (1, 1), to: (1, 1))
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
    }

    func testDegenerateInputSizeReturnsIdentityMatrix() throws {
        let stage = try makeStage()
        stage.settings.zoom = 3
        XCTAssertEqual(stage.buildUVTransform(inputSize: .zero),
                       matrix_identity_float3x3)
    }

    // MARK: - Zoom

    func testZoom2KeepsCenterFixedAndPullsCornersInward() throws {
        let stage = try makeStage()
        stage.settings.zoom = 2
        let m = stage.buildUVTransform(inputSize: size16x9)

        // Center is the fixed point; corners sample the middle half.
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
        assertMaps(m, (0, 0), to: (0.25, 0.25))
        assertMaps(m, (1, 1), to: (0.75, 0.75))
        assertMaps(m, (1, 0), to: (0.75, 0.25))
        assertMaps(m, (0, 1), to: (0.25, 0.75))
    }

    func testZoomShrinksSampledAreaQuadratically() throws {
        let stage = try makeStage()
        stage.settings.zoom = 2
        let m = stage.buildUVTransform(inputSize: size16x9)
        // Sampling window is 1/zoom per axis → |det| = 1/zoom².
        XCTAssertEqual(abs(linearDeterminant(m)), 0.25, accuracy: 1e-4)
    }

    func testAutoFrameZoomOffsetMatchesEquivalentUserZoom() throws {
        let auto = try makeStage()
        auto.autoFrameOffset = (zoom: 2, panX: 0, panY: 0)
        let manual = try makeStage()
        manual.settings.zoom = 2

        let a = auto.buildUVTransform(inputSize: size16x9)
        let b = manual.buildUVTransform(inputSize: size16x9)
        for c in 0..<3 {
            XCTAssertEqual(simd_distance(a[c], b[c]), 0, accuracy: 1e-5)
        }
    }

    // MARK: - Pan

    func testPanReachesTheMarginExactlyAtFullDeflection() throws {
        let stage = try makeStage()
        stage.settings.zoom = 2
        stage.settings.panX = 1
        stage.settings.panY = -1
        let m = stage.buildUVTransform(inputSize: size16x9)

        // Full +X pan at zoom 2: the window is the right half; full −Y pan:
        // the top half. Edges land exactly on the input edges — never beyond.
        assertMaps(m, (1, 0.5), to: (1.0, 0.25))
        assertMaps(m, (0, 0.5), to: (0.5, 0.25))
        assertMaps(m, (0.5, 0), to: (0.75, 0.0))
        assertMaps(m, (0.5, 1), to: (0.75, 0.5))
    }

    func testPanClampsBeyondFullDeflection() throws {
        let clamped = try makeStage()
        clamped.settings.zoom = 2
        clamped.settings.panX = 5      // out of range → clamps to 1
        clamped.settings.panY = -7     // out of range → clamps to −1

        let reference = try makeStage()
        reference.settings.zoom = 2
        reference.settings.panX = 1
        reference.settings.panY = -1

        let a = clamped.buildUVTransform(inputSize: size16x9)
        let b = reference.buildUVTransform(inputSize: size16x9)
        for c in 0..<3 {
            XCTAssertEqual(simd_distance(a[c], b[c]), 0, accuracy: 1e-5)
        }
        // And the sampled window never leaves the input: all four corners of
        // the output map inside [0, 1]².
        for probe: (Float, Float) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let p = map(a, probe.0, probe.1)
            XCTAssertGreaterThanOrEqual(p.x, -1e-4)
            XCTAssertLessThanOrEqual(p.x, 1 + 1e-4)
            XCTAssertGreaterThanOrEqual(p.y, -1e-4)
            XCTAssertLessThanOrEqual(p.y, 1 + 1e-4)
        }
    }

    func testPanHasNoEffectAtZoom1WithFreeCrop() throws {
        // Zoom 1, free crop: the croppable margin is zero, so pan moves
        // nothing (fraction of a zero margin).
        let stage = try makeStage()
        stage.settings.panX = 1
        stage.settings.panY = 1
        let m = stage.buildUVTransform(inputSize: size16x9)
        assertMaps(m, (0, 0), to: (0, 0))
        assertMaps(m, (1, 1), to: (1, 1))
    }

    // MARK: - Mirror

    func testHorizontalMirrorFlipsXProbes() throws {
        let stage = try makeStage()
        stage.settings.mirror = .horizontal
        let m = stage.buildUVTransform(inputSize: size16x9)

        assertMaps(m, (0, 0), to: (1, 0))
        assertMaps(m, (1, 0), to: (0, 0))
        assertMaps(m, (0.25, 0.7), to: (0.75, 0.7))
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
    }

    func testVerticalMirrorFlipsYProbes() throws {
        let stage = try makeStage()
        stage.settings.mirror = .vertical
        let m = stage.buildUVTransform(inputSize: size16x9)

        assertMaps(m, (0, 0), to: (0, 1))
        assertMaps(m, (0.3, 0.2), to: (0.3, 0.8))
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
    }

    func testBothMirrorEquals180Rotation() throws {
        let stage = try makeStage()
        stage.settings.mirror = .both
        let m = stage.buildUVTransform(inputSize: size16x9)
        assertMaps(m, (0, 0), to: (1, 1))
        assertMaps(m, (0.25, 0.7), to: (0.75, 0.3))
    }

    // MARK: - Orientation

    func testOrientation90RotatesProbesOnSquareInput() throws {
        let stage = try makeStage()
        stage.settings.orientation = .deg90
        let m = stage.buildUVTransform(inputSize: sizeSquare)

        // On square input the fit scale is 1 and the quarter turn is exact:
        // output (u, v) samples input (v, 1 − u).
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
        assertMaps(m, (0.5, 0.25), to: (0.25, 0.5))
        assertMaps(m, (1, 0.5), to: (0.5, 0))
        assertMaps(m, (0, 0), to: (0, 1))
    }

    func testOrientation90On16x9LetterboxesWithoutStretching() throws {
        let stage = try makeStage()
        stage.settings.orientation = .deg90
        let m = stage.buildUVTransform(inputSize: size16x9)

        let aspect: Float = 16.0 / 9.0
        // Center column maps through the rotated content; the vertical axis
        // is compressed by aspect² (fit scale), so output (0.5, 0.25) reads
        // input (0.25, 0.5) — same as the square case for x, exact center
        // for y.
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
        assertMaps(m, (0.5, 0.25), to: (0.25, 0.5), accuracy: 1e-3)
        // Content occupies a centered pillarbox of width (9/16)/(16/9); a
        // probe outside it samples out of range (rendered opaque black).
        let halfWidth = 0.5 / (aspect * aspect)
        let outside = map(m, 0.5 + halfWidth + 0.05, 0.5)
        XCTAssertTrue(outside.y < -1e-3 || outside.y > 1 + 1e-3,
                      "probe beyond the pillarbox must sample out of range")
        // Just inside the pillarbox edge stays in range.
        let inside = map(m, 0.5 + halfWidth - 0.05, 0.5)
        XCTAssertTrue((0...1).contains(Double(inside.y)))
    }

    func testOrientation180MapsToPointReflection() throws {
        let stage = try makeStage()
        stage.settings.orientation = .deg180
        let m = stage.buildUVTransform(inputSize: size16x9)
        assertMaps(m, (0, 0), to: (1, 1), accuracy: 1e-3)
        assertMaps(m, (0.25, 0.7), to: (0.75, 0.3), accuracy: 1e-3)
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
    }

    // MARK: - Fine rotation

    func testFineRotationKeepsCenterFixed() throws {
        let stage = try makeStage()
        stage.settings.rotationDegrees = 10
        let m = stage.buildUVTransform(inputSize: size16x9)
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
    }

    func testRotationComposesWithoutScaleDrift() throws {
        // The determinant magnitude — the area scale — must be identical
        // with and without rotation for the same zoom/pan/mirror settings:
        // rotation is rigid, it must not sneak scale into the transform.
        for zoom in [1.0, 1.7, 3.0] {
            let plain = try makeStage()
            plain.settings.zoom = zoom
            plain.settings.panX = 0.4
            plain.settings.mirror = .horizontal

            let rotated = try makeStage()
            rotated.settings.zoom = zoom
            rotated.settings.panX = 0.4
            rotated.settings.mirror = .horizontal
            rotated.settings.rotationDegrees = 12

            let d0 = abs(linearDeterminant(plain.buildUVTransform(inputSize: size16x9)))
            let d1 = abs(linearDeterminant(rotated.buildUVTransform(inputSize: size16x9)))
            XCTAssertEqual(d0, d1, accuracy: 1e-4 * d0 + 1e-6,
                           "zoom \(zoom): rotation changed the area scale")
        }
    }

    func testPureRotationHasUnitDeterminantMagnitude() throws {
        let stage = try makeStage()
        stage.settings.rotationDegrees = -15
        let m = stage.buildUVTransform(inputSize: size16x9)
        XCTAssertEqual(abs(linearDeterminant(m)), 1, accuracy: 1e-4)
    }

    func testRotationDegreesClampToSpecRange() throws {
        // ±15° is the spec range (§5.4); values beyond clamp.
        let wild = try makeStage()
        wild.settings.rotationDegrees = 90
        let limit = try makeStage()
        limit.settings.rotationDegrees = 15
        let a = wild.buildUVTransform(inputSize: size16x9)
        let b = limit.buildUVTransform(inputSize: size16x9)
        for c in 0..<3 {
            XCTAssertEqual(simd_distance(a[c], b[c]), 0, accuracy: 1e-5)
        }
    }

    // MARK: - Crop aspect

    func testSquareCropOn16x9CropsWidthNotHeight() throws {
        let stage = try makeStage()
        stage.settings.cropAspect = .r1x1
        let m = stage.buildUVTransform(inputSize: size16x9)

        // 1:1 on 16:9 keeps full height and samples the centered 9/16-wide
        // band: x ∈ [0.21875, 0.78125].
        assertMaps(m, (0.5, 0.5), to: (0.5, 0.5))
        assertMaps(m, (0, 0), to: (0.21875, 0))
        assertMaps(m, (1, 1), to: (0.78125, 1))
        assertMaps(m, (0, 1), to: (0.21875, 1))
    }

    func testWideCropOnSquareInputCropsHeight() throws {
        let stage = try makeStage()
        stage.settings.cropAspect = .r16x9
        let m = stage.buildUVTransform(inputSize: sizeSquare)

        // 16:9 on square input keeps full width, samples 9/16 of the height.
        let inset = Float((1.0 - 9.0 / 16.0) / 2.0)   // 0.21875
        assertMaps(m, (0, 0), to: (0, inset))
        assertMaps(m, (1, 1), to: (1, 1 - inset))
    }

    // MARK: - wantsEncode fast path

    func testWantsEncodeSkipsIdentityAndEncodesWhenActive() throws {
        let stage = try makeStage()
        XCTAssertFalse(stage.wantsEncode(), "identity settings need no pass")
        stage.settings.zoom = 1.5
        XCTAssertTrue(stage.wantsEncode())
        stage.settings = GeometrySettings()
        stage.autoFrameOffset = (zoom: 1.2, panX: 0, panY: 0)
        XCTAssertTrue(stage.wantsEncode(), "auto-frame deltas need the pass")
        stage.isEnabled = false
        XCTAssertFalse(stage.wantsEncode())
    }
}
