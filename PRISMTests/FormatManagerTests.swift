// FormatManagerTests.swift
// PRISMTests
//
// Locks down the §3.2 physical-format selection rule through the pure
// candidate-list helper (smallest native ≥ output in both dimensions,
// else largest; deterministic tie-breaks), and the persistence round-trip
// of the published set + active format through an isolated UserDefaults
// suite. The persisted key strings are asserted literally — changing them
// silently discards every user's saved format configuration.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

@MainActor
final class FormatManagerTests: XCTestCase {

    // MARK: - §3.2 physical format selection (pure helper)

    private typealias Candidate = (width: Int, height: Int, supportsRate: Bool)

    private func select(_ candidates: [Candidate],
                        output: VideoFormat) -> Int? {
        FormatManager.selectPhysicalFormatIndex(candidates: candidates, output: output)
    }

    private let out1080p30 = VideoFormat(width: 1920, height: 1080, frameRate: 30)

    func testEmptyCandidatesReturnsNil() {
        XCTAssertNil(select([], output: out1080p30))
    }

    func testExactMatchWins() {
        let candidates: [Candidate] = [
            (3840, 2160, true),
            (1920, 1080, true),
            (1280, 720, true),
        ]
        XCTAssertEqual(select(candidates, output: out1080p30), 1)
    }

    func testSmallestFittingFormatWinsByArea() {
        // All large enough — the smallest area must win, not the first.
        let candidates: [Candidate] = [
            (3840, 2160, true),
            (2560, 1440, true),
            (1920, 1080, true),
        ]
        let output = VideoFormat(width: 1280, height: 720, frameRate: 30)
        XCTAssertEqual(select(candidates, output: output), 2)
    }

    func testNextSizeUpWhenNoExactMatch() {
        let candidates: [Candidate] = [
            (1280, 720, true),
            (1760, 990, true),      // width below 1920 → not fitting
            (3840, 2160, true),
        ]
        XCTAssertEqual(select(candidates, output: out1080p30), 2)
    }

    func testFittingRequiresBothDimensions() {
        // 1920×1079 misses height by one pixel; it must be rejected even
        // though its area beats the 4K entry.
        let candidates: [Candidate] = [
            (1920, 1079, true),
            (3840, 2160, true),
        ]
        XCTAssertEqual(select(candidates, output: out1080p30), 1)
    }

    func testNoFittingFormatFallsBackToLargestArea() {
        let candidates: [Candidate] = [
            (1280, 720, true),
            (1920, 1080, true),
            (960, 540, true),
        ]
        let output = VideoFormat(width: 3840, height: 2160, frameRate: 30)
        XCTAssertEqual(select(candidates, output: output), 1)
    }

    func testFallbackWhenNoCandidateFitsBothDimensions() {
        // 4000×1000 fits width only, 1500×1500 fits neither — fallback picks
        // the larger area (4000×1000 = 4MP vs 2.25MP).
        let candidates: [Candidate] = [
            (4000, 1000, true),
            (1500, 1500, true),
        ]
        XCTAssertEqual(select(candidates, output: out1080p30), 0)
    }

    func testEqualAreaTiePrefersNativeRateSupport() {
        let candidates: [Candidate] = [
            (1920, 1080, false),
            (1920, 1080, true),
        ]
        XCTAssertEqual(select(candidates, output: out1080p30), 1)
    }

    func testEqualAreaAndRateTieKeepsEarliestCandidate() {
        let candidates: [Candidate] = [
            (1920, 1080, true),
            (1920, 1080, true),
        ]
        XCTAssertEqual(select(candidates, output: out1080p30), 0)
    }

    func testFallbackAreaTieKeepsEarliestCandidate() {
        // Nothing fits 4K; two equal-area candidates → the first wins.
        let candidates: [Candidate] = [
            (1920, 1080, true),
            (1080, 1920, true),
        ]
        let output = VideoFormat(width: 3840, height: 2160, frameRate: 30)
        XCTAssertEqual(select(candidates, output: output), 0)
    }

    func testRateSupportDoesNotOverrideSmallerArea() {
        // Area dominates the tie-break: a smaller fitting format without
        // native rate support still beats a larger one with it.
        let candidates: [Candidate] = [
            (3840, 2160, true),
            (1920, 1080, false),
        ]
        XCTAssertEqual(select(candidates, output: out1080p30), 1)
    }

    // MARK: - Persistence (isolated UserDefaults suite)

    private static let suiteName = "horse.prism.PRISMTests.FormatManager"
    private static let publishedKey = "PRISM.publishedFormats"
    private static let activeKey = "PRISM.activeFormat"

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        XCTAssertNotNil(defaults)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFreshManagerStartsWithDefaultSetAnd1080p30() {
        let manager = FormatManager(defaults: defaults)
        XCTAssertEqual(manager.publishedFormats, VideoFormat.defaultSet)
        XCTAssertEqual(manager.activeFormat,
                       VideoFormat(width: 1920, height: 1080, frameRate: 30))
    }

    func testPersistRoundTripRestoresPublishedSetAndActiveFormat() {
        let manager = FormatManager(defaults: defaults)
        manager.activeFormat = VideoFormat(width: 1280, height: 720, frameRate: 60)
        manager.persist()

        let reloaded = FormatManager(defaults: defaults)
        XCTAssertEqual(Set(reloaded.publishedFormats), Set(VideoFormat.defaultSet))
        // The load path normalizes ordering (largest first, higher rate first).
        XCTAssertEqual(reloaded.publishedFormats, VideoFormat.defaultSet.sorted())
        XCTAssertEqual(reloaded.activeFormat,
                       VideoFormat(width: 1280, height: 720, frameRate: 60))
    }

    func testPersistedCustomSetRoundTrips() throws {
        let custom = [
            VideoFormat(width: 960, height: 540, frameRate: 30),
            VideoFormat(width: 1280, height: 720, frameRate: 60),
        ]
        defaults.set(try JSONEncoder().encode(custom), forKey: Self.publishedKey)
        defaults.set(try JSONEncoder().encode(custom[0]), forKey: Self.activeKey)

        let manager = FormatManager(defaults: defaults)
        XCTAssertEqual(manager.publishedFormats, custom.sorted())
        XCTAssertEqual(manager.activeFormat, custom[0])
    }

    func testPersistedActiveOutsideSetFallsBackToLargestPublished() throws {
        let custom = [
            VideoFormat(width: 1280, height: 720, frameRate: 60),
            VideoFormat(width: 960, height: 540, frameRate: 30),
        ]
        defaults.set(try JSONEncoder().encode(custom), forKey: Self.publishedKey)
        defaults.set(try JSONEncoder().encode(
            VideoFormat(width: 3840, height: 2160, frameRate: 30)), forKey: Self.activeKey)

        let manager = FormatManager(defaults: defaults)
        // 1080p30 is not published either, so the first (largest) entry wins.
        XCTAssertEqual(manager.activeFormat,
                       VideoFormat(width: 1280, height: 720, frameRate: 60))
    }

    func testPersistedActiveFallsBackTo1080p30WhenAvailable() throws {
        let custom = [
            VideoFormat(width: 1920, height: 1080, frameRate: 30),
            VideoFormat(width: 960, height: 540, frameRate: 30),
        ]
        defaults.set(try JSONEncoder().encode(custom), forKey: Self.publishedKey)
        defaults.set(try JSONEncoder().encode(
            VideoFormat(width: 640, height: 480, frameRate: 30)), forKey: Self.activeKey)

        let manager = FormatManager(defaults: defaults)
        XCTAssertEqual(manager.activeFormat,
                       VideoFormat(width: 1920, height: 1080, frameRate: 30))
    }

    func testCorruptedPublishedDataFallsBackToDefaultSet() {
        defaults.set(Data("not json".utf8), forKey: Self.publishedKey)
        let manager = FormatManager(defaults: defaults)
        XCTAssertEqual(manager.publishedFormats, VideoFormat.defaultSet)
    }

    func testEmptyPersistedSetFallsBackToDefaultSet() throws {
        defaults.set(try JSONEncoder().encode([VideoFormat]()), forKey: Self.publishedKey)
        let manager = FormatManager(defaults: defaults)
        XCTAssertEqual(manager.publishedFormats, VideoFormat.defaultSet)
    }
}
