// ClientNameTests.swift
// PRISMTests
//
// Locks down CMIOSink.displayName(forSigningID:) — the mapping from the
// extension's 'clnt' signing IDs to the friendly names shown in "In use by
// Zoom, FaceTime" (§8.4): the known-app table, and the fallback that
// capitalizes the last reverse-DNS component for everything else.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class ClientNameTests: XCTestCase {

    private func name(_ signingID: String) -> String {
        CMIOSink.displayName(forSigningID: signingID)
    }

    // MARK: - Known signing IDs

    func testKnownSigningIDsMapToFriendlyNames() {
        let expected: [String: String] = [
            "us.zoom.xos": "Zoom",
            "com.apple.FaceTime": "FaceTime",
            "com.apple.PhotoBooth": "Photo Booth",
            "com.apple.QuickTimePlayerX": "QuickTime Player",
            "com.google.Chrome": "Chrome",
            "com.apple.Safari": "Safari",
            "com.microsoft.teams2": "Teams",
            "com.hnc.Discord": "Discord",
            "com.tinyspeck.slackmacgap": "Slack",
        ]
        for (signingID, friendly) in expected {
            XCTAssertEqual(name(signingID), friendly, "mapping for \(signingID)")
        }
    }

    func testKnownMappingsAreCaseSensitiveExactMatches() {
        // A differently-cased ID is not the known app — it takes the fallback
        // path (last component, first letter uppercased).
        XCTAssertEqual(name("US.ZOOM.XOS"), "XOS")
        XCTAssertEqual(name("com.apple.facetime"), "Facetime")
    }

    // MARK: - Fallback capitalization

    func testFallbackCapitalizesLastReverseDNSComponent() {
        XCTAssertEqual(name("com.example.myapp"), "Myapp")
        XCTAssertEqual(name("org.mozilla.firefox"), "Firefox")
        XCTAssertEqual(name("tv.obsproject.obs-studio"), "Obs-studio")
    }

    func testFallbackPreservesInteriorCasing() {
        // Only the first character is uppercased; the rest is untouched.
        XCTAssertEqual(name("com.microsoft.VSCode"), "VSCode")
        XCTAssertEqual(name("com.example.WebEx"), "WebEx")
    }

    func testFallbackHandlesSingleComponentIDs() {
        XCTAssertEqual(name("zoom"), "Zoom")
        XCTAssertEqual(name("A"), "A")
    }

    func testFallbackHandlesDegenerateIDs() {
        // Empty string comes back unchanged rather than crashing.
        XCTAssertEqual(name(""), "")
        // Split drops empty components, so a trailing dot still yields the
        // last real component.
        XCTAssertEqual(name("com.example."), "Example")
        // Dots only: no components at all → the original string.
        XCTAssertEqual(name("..."), "...")
    }

    func testFallbackAlreadyCapitalizedStaysPut() {
        XCTAssertEqual(name("com.company.Studio"), "Studio")
    }
}
