// CaptureDestinationTests.swift
// PRISMTests
//
// Naming and destination for saved stills and clips (§5.15, §5.16), plus
// the settings that point at them.
//
// A capture whose file cannot be found is a capture that did not happen, so
// the names are an interface: fixed shape, sortable, and recognisably the
// system's own screenshot convention.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class CaptureDestinationTests: XCTestCase {

    /// 2026-08-18 14:23:05 UTC, as a fixed instant.
    private var moment: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 18
        components.hour = 14
        components.minute = 23
        components.second = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private func name(_ kind: CaptureDestination.Kind, _ ext: String) -> String {
        // Formatted in the current zone, so compare only the parts that do
        // not move with it.
        CaptureDestination.fileName(kind: kind, date: moment, fileExtension: ext)
    }

    // MARK: - Naming

    func testStillsAndClipsUseDistinctPrefixes() {
        XCTAssertTrue(name(.still, "png").hasPrefix("PRISM 2026-08-"))
        XCTAssertTrue(name(.clip, "mov").hasPrefix("PRISM Clip 2026-08-"))
    }

    func testNameCarriesTheRequestedExtension() {
        XCTAssertTrue(name(.still, "heic").hasSuffix(".heic"))
        XCTAssertTrue(name(.clip, "mov").hasSuffix(".mov"))
    }

    /// The clock is dot-separated because a colon is not usable in a file
    /// name shown in Finder — the same reason the system's screenshots are.
    func testNameContainsNoColons() {
        XCTAssertFalse(name(.still, "png").contains(":"))
    }

    /// A name is an identifier. One that changes shape with the user's
    /// region cannot be sorted, scripted, or recognised.
    func testNameShapeDoesNotFollowTheUsersRegion() {
        let still = name(.still, "png")
        XCTAssertTrue(still.contains(" at "))
        // "PRISM yyyy-MM-dd at HH.mm.ss.png"
        XCTAssertEqual(still.count, "PRISM 2026-08-18 at 14.23.05.png".count)
    }

    // MARK: - Collisions

    func testUniqueURLLeavesAFreeNameAlone() {
        let folder = URL(fileURLWithPath: "/tmp/prism", isDirectory: true)
        let url = CaptureDestination.uniqueURL(in: folder, fileName: "PRISM.png",
                                               exists: { _ in false })
        XCTAssertEqual(url.lastPathComponent, "PRISM.png")
    }

    func testUniqueURLDisambiguatesASecondCaptureInTheSameSecond() {
        let folder = URL(fileURLWithPath: "/tmp/prism", isDirectory: true)
        let taken: Set<String> = ["PRISM.png", "PRISM (2).png"]
        let url = CaptureDestination.uniqueURL(in: folder, fileName: "PRISM.png",
                                               exists: { taken.contains($0.lastPathComponent) })
        XCTAssertEqual(url.lastPathComponent, "PRISM (3).png")
    }

    // MARK: - Destination

    func testPrepareCreatesAMissingFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("prism-capture-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("deeper", isDirectory: true)
        XCTAssertEqual(try CaptureDestination.prepare(nested), nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    /// The check happens before anything is encoded: a capture that fails
    /// after the work is done has already cost the moment it was keeping.
    func testPrepareRejectsAPathThatIsAFile() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("prism-capture-\(UUID().uuidString).txt")
        try Data().write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try CaptureDestination.prepare(file)) { error in
            XCTAssertEqual(error as? CaptureError, .folderUnavailable(file.path))
        }
    }

    // MARK: - Settings

    func testCaptureDefaultsAreTheQuietOnes() {
        let capture = CaptureSettings()
        XCTAssertEqual(capture.format, .png)
        XCTAssertEqual(capture.countdownSeconds, 0,
                       "a countdown you did not ask for is a photo you missed")
        XCTAssertFalse(capture.prefersSharp,
                       "holding finished frames costs memory nobody asked to spend")
        XCTAssertTrue(capture.usesDefaultFolder)
    }

    func testDefaultFolderIsPrismsOwnInsideMovies() {
        let url = CaptureSettings().folderURL
        XCTAssertEqual(url.lastPathComponent, "PRISM")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Movies")
    }

    func testCountdownClamps() {
        var capture = CaptureSettings()
        capture.countdownSeconds = -3
        XCTAssertEqual(capture.clampedCountdownSeconds, 0)
        capture.countdownSeconds = 99
        XCTAssertEqual(capture.clampedCountdownSeconds, 10)
    }

    /// Synthesised Codable throws on an absent key rather than falling back
    /// to a property default, which would wipe a user's folder choice the
    /// first time this struct gained a field.
    func testCaptureSettingsDecodeToleratesAnOlderFile() throws {
        let json = Data(#"{"folderPath":"/Users/someone/Clips"}"#.utf8)
        let capture = try JSONDecoder().decode(CaptureSettings.self, from: json)
        XCTAssertEqual(capture.folderPath, "/Users/someone/Clips")
        XCTAssertEqual(capture.format, .png)
        XCTAssertEqual(capture.countdownSeconds, 0)
        XCTAssertFalse(capture.prefersSharp)
    }

    func testCaptureSettingsDecodeToleratesGarbageFields() throws {
        let json = Data(#"{"format":"tiff","countdownSeconds":"soon","prefersSharp":3}"#.utf8)
        let capture = try JSONDecoder().decode(CaptureSettings.self, from: json)
        XCTAssertEqual(capture.format, .png)
        XCTAssertEqual(capture.countdownSeconds, 0)
        XCTAssertFalse(capture.prefersSharp)
    }

    func testStudioSettingsCarryCaptureThroughARoundTrip() throws {
        var studio = StudioSettings()
        studio.capture.format = .heic
        studio.capture.countdownSeconds = 5
        studio.capture.folderPath = "/Volumes/Work/PRISM"
        let data = try JSONEncoder().encode(studio)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: data)
        XCTAssertEqual(decoded.capture, studio.capture)
    }
}
