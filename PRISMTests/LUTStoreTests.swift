// LUTStoreTests.swift
// PRISMTests
//
// Exercises the .cube parser (§5.4): a handwritten 2³ identity cube parses
// with standard red-fastest ordering, malformed files (bad LUT_3D_SIZE,
// wrong entry count, broken domains, 1D LUTs) are rejected with typed
// errors, comments/blank lines/DOMAIN and unknown keyword lines are
// tolerated, the five bundled LUTs parse (Mono is confirmed grayscale), a
// parsed cube builds a 3D Metal texture, and importLUT validates, copies
// into the (test-overridden) import directory, and shows up in the catalog.
//
// Licensed under the Apache License, Version 2.0.

import Metal
import XCTest

final class LUTStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRISMLUTStoreTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    @discardableResult
    private func write(_ contents: String, name: String = "Test.cube") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A valid handwritten 2³ identity cube, dressed with everything the
    /// parser must tolerate: comments, blank lines, TITLE, DOMAIN lines, an
    /// unknown keyword, and mixed whitespace.
    private let identity2Cube = """
    # handwritten identity cube
    TITLE "Tiny"

    LUT_3D_SIZE 2
    DOMAIN_MIN 0.0 0.0 0.0
    DOMAIN_MAX 1.0 1.0 1.0
    LUT_IN_VIDEO_RANGE

    0 0 0
    1 0 0
    0\t1\t0
    1 1 0

    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """

    // MARK: - Valid parse

    func testHandwritten2CubeParses() throws {
        let url = try write(identity2Cube)
        let lut = try LUTStore.parseCube(at: url)

        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.title, "Tiny")
        XCTAssertEqual(lut.values.count, 2 * 2 * 2 * 3)
        XCTAssertEqual(lut.domainMin, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(lut.domainMax, SIMD3<Float>(1, 1, 1))

        // Standard .cube ordering: red varies fastest.
        func triple(_ i: Int) -> SIMD3<Float> {
            SIMD3<Float>(lut.values[i * 3], lut.values[i * 3 + 1], lut.values[i * 3 + 2])
        }
        XCTAssertEqual(triple(0), SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(triple(1), SIMD3<Float>(1, 0, 0))   // +R
        XCTAssertEqual(triple(2), SIMD3<Float>(0, 1, 0))   // +G
        XCTAssertEqual(triple(4), SIMD3<Float>(0, 0, 1))   // +B
        XCTAssertEqual(triple(7), SIMD3<Float>(1, 1, 1))
    }

    func testOutOfRangeValuesAreClampedToUnitRange() throws {
        let url = try write("""
        LUT_3D_SIZE 2
        -0.25 0 0
        1.75 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """)
        let lut = try LUTStore.parseCube(at: url)
        XCTAssertEqual(lut.values[0], 0)     // −0.25 → 0
        XCTAssertEqual(lut.values[3], 1)     // 1.75 → 1
    }

    func testScientificNotationAndSignedValuesParse() throws {
        let url = try write("""
        LUT_3D_SIZE 2
        0.0e0 0 0
        +1.0 0 0
        0 5e-1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """)
        let lut = try LUTStore.parseCube(at: url)
        XCTAssertEqual(lut.values[7], 0.5, accuracy: 1e-6)   // 5e-1 green
    }

    // MARK: - Malformed input

    private func assertMalformed(_ contents: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try write(contents, name: "Bad-\(UUID().uuidString).cube")
        XCTAssertThrowsError(try LUTStore.parseCube(at: url),
                             file: file, line: line) { error in
            guard case LUTError.malformed = error else {
                XCTFail("expected .malformed, got \(error)", file: file, line: line)
                return
            }
        }
    }

    func testRejectsBadLUT3DSize() throws {
        // Below the 2…128 range.
        try assertMalformed("""
        LUT_3D_SIZE 1
        0 0 0
        """)
        // Above the range.
        try assertMalformed("""
        LUT_3D_SIZE 129
        0 0 0
        """)
        // Not a number.
        try assertMalformed("""
        LUT_3D_SIZE banana
        0 0 0
        """)
        // Missing entirely.
        try assertMalformed("""
        0 0 0
        1 1 1
        """)
    }

    func testRejectsWrongEntryCount() throws {
        // 2³ requires 8 triples; 7 provided.
        try assertMalformed("""
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        """)
        // 9 provided.
        try assertMalformed("""
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        1 1 1
        """)
    }

    func testRejectsMalformedDataLines() throws {
        // Two numbers on a data line.
        try assertMalformed("""
        LUT_3D_SIZE 2
        0 0
        """)
        // Non-numeric field starting with a digit.
        try assertMalformed("""
        LUT_3D_SIZE 2
        0 0 0zebra
        """)
    }

    func testRejectsInvertedDomain() throws {
        try assertMalformed("""
        LUT_3D_SIZE 2
        DOMAIN_MIN 1 1 1
        DOMAIN_MAX 0 0 0
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """)
    }

    func testRejects1DLUTAsUnsupported() throws {
        let url = try write("LUT_1D_SIZE 4096\n0 0 0\n", name: "OneD.cube")
        XCTAssertThrowsError(try LUTStore.parseCube(at: url)) { error in
            guard case LUTError.unsupported = error else {
                XCTFail("expected .unsupported, got \(error)")
                return
            }
        }
    }

    func testMissingFileIsUnreadable() {
        let ghost = directory.appendingPathComponent("Ghost.cube")
        XCTAssertThrowsError(try LUTStore.parseCube(at: ghost)) { error in
            guard case LUTError.unreadable = error else {
                XCTFail("expected .unreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - Bundled LUTs

    /// The test bundle compiles the app sources and carries the app's
    /// resources, so the shipped .cube files are located relative to a type
    /// in this module — with or without the LUTs subdirectory preserved.
    private func bundledCubeURLs() -> [URL] {
        let bundle = Bundle(for: LUTStore.self)
        let inSubdirectory = bundle.urls(forResourcesWithExtension: "cube",
                                         subdirectory: "LUTs") ?? []
        if !inSubdirectory.isEmpty { return inSubdirectory }
        return bundle.urls(forResourcesWithExtension: "cube", subdirectory: nil) ?? []
    }

    func testAllFiveBundledLUTsParse() throws {
        let urls = bundledCubeURLs()
        let names = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        for expected in ["Neutral", "Warm", "Cool", "Film", "Mono"] {
            XCTAssertTrue(names.contains(expected),
                          "bundled \(expected).cube missing from test bundle")
        }
        for url in urls {
            let lut = try LUTStore.parseCube(at: url)
            XCTAssertGreaterThanOrEqual(lut.size, 2)
            XCTAssertEqual(lut.values.count, lut.size * lut.size * lut.size * 3,
                           "\(url.lastPathComponent) entry count")
        }
    }

    func testBundledNeutralIsIdentity() throws {
        let url = try XCTUnwrap(bundledCubeURLs()
            .first { $0.deletingPathExtension().lastPathComponent == "Neutral" })
        let lut = try LUTStore.parseCube(at: url)
        let reference = LUTStore.identityLUT(size: lut.size)
        for (value, expected) in zip(lut.values, reference.values) {
            XCTAssertEqual(value, expected, accuracy: 2e-3)
        }
    }

    func testBundledMonoIsGrayscale() throws {
        let url = try XCTUnwrap(bundledCubeURLs()
            .first { $0.deletingPathExtension().lastPathComponent == "Mono" })
        let lut = try LUTStore.parseCube(at: url)
        for i in 0..<(lut.values.count / 3) {
            let r = lut.values[i * 3]
            let g = lut.values[i * 3 + 1]
            let b = lut.values[i * 3 + 2]
            XCTAssertEqual(r, g, accuracy: 1e-5, "entry \(i) not gray")
            XCTAssertEqual(g, b, accuracy: 1e-5, "entry \(i) not gray")
        }
    }

    // MARK: - Texture construction

    func testParsedCubeBuildsA3DTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let url = try write(identity2Cube)
        let lut = try LUTStore.parseCube(at: url)
        let texture = try XCTUnwrap(LUTStore.makeTexture(from: lut, device: device))
        XCTAssertEqual(texture.textureType, .type3D)
        XCTAssertEqual(texture.pixelFormat, .rgba16Float)
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(texture.depth, 2)
    }

    func testSynthesizedNeutralTextureAlwaysAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let store = LUTStore()
        store.importDirectoryOverride = directory.appendingPathComponent("imports")
        // No file provides Neutral (Bundle.main is the test runner) — it is
        // synthesized as an identity and always listed.
        XCTAssertTrue(store.availableLUTs.contains("Neutral"))
        let texture = try XCTUnwrap(store.texture(named: "Neutral", device: device))
        XCTAssertEqual(texture.textureType, .type3D)
        XCTAssertEqual(texture.width, 33)
        // Cached: the same instance comes back.
        XCTAssertTrue(store.texture(named: "neutral", device: device) === texture,
                      "lookup is case-insensitive and cached")
    }

    func testFloatToHalfBitsKnownValues() {
        XCTAssertEqual(LUTStore.floatToHalfBits(0), 0)
        XCTAssertEqual(LUTStore.floatToHalfBits(1), 0x3C00)
        XCTAssertEqual(LUTStore.floatToHalfBits(0.5), 0x3800)
        // Clamped to 0…1.
        XCTAssertEqual(LUTStore.floatToHalfBits(2.0), 0x3C00)
        XCTAssertEqual(LUTStore.floatToHalfBits(-3.0), 0)
    }

    // MARK: - Import

    func testImportCopiesFileAndListsIt() throws {
        let store = LUTStore()
        let importDir = directory.appendingPathComponent("imports", isDirectory: true)
        store.importDirectoryOverride = importDir

        let source = try write(identity2Cube, name: "MyLook.cube")
        let name = try store.importLUT(from: source)
        XCTAssertEqual(name, "MyLook")

        // Copied into the import directory…
        let copied = importDir.appendingPathComponent("MyLook.cube")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        // …and listed by the catalog (after the always-present Neutral).
        XCTAssertTrue(store.availableLUTs.contains("MyLook"))
        XCTAssertTrue(store.availableLUTs.contains("Neutral"))

        // The imported LUT resolves to a texture.
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let texture = try XCTUnwrap(store.texture(named: "MyLook", device: device))
        XCTAssertEqual(texture.width, 2)
    }

    func testImportRejectsMalformedFileWithoutCopying() throws {
        let store = LUTStore()
        let importDir = directory.appendingPathComponent("imports", isDirectory: true)
        store.importDirectoryOverride = importDir

        let source = try write("LUT_3D_SIZE 2\n0 0 0\n", name: "Broken.cube")
        XCTAssertThrowsError(try store.importLUT(from: source))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: importDir.appendingPathComponent("Broken.cube").path))
        XCTAssertFalse(store.availableLUTs.contains("Broken"))
    }

    func testReimportReplacesExistingFile() throws {
        let store = LUTStore()
        let importDir = directory.appendingPathComponent("imports", isDirectory: true)
        store.importDirectoryOverride = importDir

        _ = try store.importLUT(from: try write(identity2Cube, name: "Look.cube"))
        // Re-import a different valid cube under the same name.
        let altered = identity2Cube.replacingOccurrences(of: "1 1 1", with: "0.5 0.5 0.5")
        let name = try store.importLUT(from: try write(altered, name: "Look.cube"))
        XCTAssertEqual(name, "Look")

        let copied = importDir.appendingPathComponent("Look.cube")
        let lut = try LUTStore.parseCube(at: copied)
        XCTAssertEqual(lut.values[23], 0.5, accuracy: 1e-6,
                       "re-import must replace the stored copy")
    }
}
