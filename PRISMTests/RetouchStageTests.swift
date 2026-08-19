// RetouchStageTests.swift
// PRISMTests
//
// Skin retouch's arithmetic and its gating (§5.22). The smoothing itself is
// two Metal kernels and is covered in KernelTests; what is here is everything
// that decides how hard to smooth, and — more importantly — when to refuse
// to run at all.
//
// Licensed under the Apache License, Version 2.0.

import Metal
import XCTest

final class RetouchStageTests: XCTestCase {

    private static var sharedMetal: MetalContext?
    private static var metalError: Error?
    private static let metalOnce: Void = {
        do { sharedMetal = try MetalContext() } catch { metalError = error }
    }()

    private func makeStage() throws -> RetouchStage {
        _ = Self.metalOnce
        guard let metal = Self.sharedMetal else {
            throw XCTSkip("Metal unavailable: \(String(describing: Self.metalError))")
        }
        return try RetouchStage(metal: metal, segmenter: PersonSegmenter(metal: metal))
    }

    // MARK: - Default-off, default-inert

    /// The whole shipping posture in one assertion: a fresh install smooths
    /// nothing, and it does not merely skip the pass — the knob itself is at
    /// zero, so a user who switches the stage on and looks at the slider sees
    /// the number that matches the picture.
    func testShipsOffAndInert() {
        let config = PipelineConfiguration()
        XCTAssertFalse(config.flags(for: .retouch).enabled)
        XCTAssertEqual(config.retouch.amount, 0)
        XCTAssertTrue(config.retouch.isInert)
    }

    func testInertAmountIsReportedRatherThanSilentlySkipped() {
        var config = PipelineConfiguration()
        config.flags[.retouch] = StageFlags(enabled: true, pinned: false)
        XCTAssertTrue(config.isInert(.retouch))
        XCTAssertEqual(config.inertReason(.retouch), "On, but the amount is 0.")

        config.retouch.amount = RetouchSettings.defaultAmount
        XCTAssertFalse(config.isInert(.retouch))
        XCTAssertNil(config.inertReason(.retouch))
    }

    func testStageDeclinesUntilBothEnabledAndNonZero() throws {
        let stage = try makeStage()
        XCTAssertFalse(stage.wantsEncode(), "off is off")

        stage.isEnabled = true
        XCTAssertFalse(stage.wantsEncode(),
                       "an amount of 0 must skip the pass, not run four of them")

        stage.settings.amount = RetouchSettings.defaultAmount
        XCTAssertTrue(stage.wantsEncode())

        stage.settings.amount = -1
        XCTAssertFalse(stage.wantsEncode(), "a negative amount is still off")
    }

    /// Retouch reads a mask if one is lying around and never asks for one —
    /// that is what the chroma gate is for. The moment this stage raises
    /// segmentation demand, switching retouch on starts a Vision request
    /// nobody agreed to pay for.
    func testEncodingNeverRaisesSegmentationDemand() throws {
        let stage = try makeStage()
        guard let metal = Self.sharedMetal else { throw XCTSkip("no Metal") }
        stage.isEnabled = true
        stage.settings.amount = 1
        XCTAssertFalse(stage.segmenter.isDemanded)
        XCTAssertTrue(stage.wantsEncode())

        let input = try metal.makeIntermediate(width: 64, height: 36)
        let output = try metal.makeIntermediate(width: 64, height: 36)
        guard let buffer = metal.commandQueue.makeCommandBuffer() else {
            throw XCTSkip("no command buffer")
        }
        try stage.encode(commandBuffer: buffer, input: input, output: output)
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertFalse(stage.segmenter.isDemanded)
        XCTAssertNil(stage.segmenter.latestMask,
                     "a mask appeared without anyone requesting one")
    }

    // MARK: - The smoothing scale

    /// A radius fixed in pixels smooths a 720p face twice as hard as a 1080p
    /// one, which is how the same slider ends up meaning two different looks
    /// on two different formats.
    func testSpatialSigmaScalesWithFrameHeight() {
        var settings = RetouchSettings()
        settings.amount = 0.5
        let at1080 = settings.spatialSigma(forHeight: 1080)
        let at720 = settings.spatialSigma(forHeight: 720)
        XCTAssertEqual(at720, at1080 * 720 / 1080, accuracy: 1e-9)
        XCTAssertGreaterThan(at1080, at720)
    }

    func testSpatialSigmaRisesWithAmount() {
        var low = RetouchSettings(); low.amount = 0.1
        var high = RetouchSettings(); high.amount = 1
        XCTAssertGreaterThan(high.spatialSigma(forHeight: 1080),
                             low.spatialSigma(forHeight: 1080))
    }

    /// The range sigma is the term that keeps lashes, nostrils and the lip
    /// line out of the blur, so more surviving detail has to mean a tighter
    /// tolerance — not a wider one.
    func testRangeSigmaShrinksAsDetailRises() {
        var coarse = RetouchSettings(); coarse.detail = 0
        var fine = RetouchSettings(); fine.detail = 1
        XCTAssertGreaterThan(coarse.rangeSigma, fine.rangeSigma)
        XCTAssertGreaterThan(fine.rangeSigma, 0, "a zero tolerance blurs nothing at all")
    }

    func testBlendReachesZeroAtZeroAmountAndStaysBelowOne() {
        var settings = RetouchSettings()
        settings.amount = 0
        XCTAssertEqual(settings.blend, 0, accuracy: 1e-9)
        settings.amount = 1
        XCTAssertGreaterThan(settings.blend, 0.5)
        XCTAssertLessThan(settings.blend, 1,
                          "fully replacing the skin leaves nothing to disagree with it")
    }

    func testOutOfRangeValuesAreClampedRatherThanTrusted() {
        var settings = RetouchSettings()
        settings.amount = 5
        settings.detail = -3
        XCTAssertEqual(settings.clampedAmount, 1)
        XCTAssertEqual(settings.clampedDetail, 0)
        XCTAssertLessThanOrEqual(settings.blend, 1)
    }

    // MARK: - Encoding

    /// Four passes into one command buffer, with no mask anywhere in sight.
    func testEncodesWithoutAMask() throws {
        let stage = try makeStage()
        guard let metal = Self.sharedMetal else { throw XCTSkip("no Metal") }
        stage.isEnabled = true
        stage.settings.amount = 1
        let input = try metal.makeIntermediate(width: 128, height: 72)
        let output = try metal.makeIntermediate(width: 128, height: 72)
        guard let buffer = metal.commandQueue.makeCommandBuffer() else {
            throw XCTSkip("no command buffer")
        }
        XCTAssertNoThrow(try stage.encode(commandBuffer: buffer,
                                          input: input, output: output))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
    }
}
