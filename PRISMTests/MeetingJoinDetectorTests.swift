// MeetingJoinDetectorTests.swift
// PRISMTests
//
// A meeting suggestion is consent UI. These tests keep it edge-triggered:
// detecting a call may ask once, but can never start anything or nag on a
// client-list poll/brief reconnect.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class MeetingJoinDetectorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testSupportedNativeMeetingAppsAreRecognised() {
        let expected = [
            "us.zoom.xos": "Zoom",
            "com.apple.FaceTime": "FaceTime",
            "com.microsoft.teams": "Teams",
            "com.microsoft.teams2": "Teams",
        ]
        for (signingID, name) in expected {
            XCTAssertEqual(MeetingClientCatalog.candidate(signingID: signingID),
                           MeetingJoinCandidate(signingID: signingID,
                                                applicationName: name))
        }
    }

    func testGoogleMeetBrowsersAreRecognisedWithoutInspectingTabs() {
        XCTAssertEqual(MeetingClientCatalog.candidate(signingID: "com.google.Chrome")?.applicationName,
                       "Chrome")
        XCTAssertEqual(MeetingClientCatalog.candidate(signingID: "com.apple.Safari")?.applicationName,
                       "Safari")
        XCTAssertEqual(MeetingClientCatalog.candidate(
            signingID: "com.google.Chrome.app.meet-generated")?.applicationName,
                       "Google Meet in Chrome")
    }

    func testOrdinaryCameraClientsDoNotPrompt() {
        var detector = MeetingJoinDetector()
        let result = detector.update(
            cameraClients: [CameraClient(signingID: "com.apple.PhotoBooth")],
            microphoneClient: nil, at: start)
        XCTAssertNil(result.prompt)
    }

    func testJoiningPromptsExactlyOnceWhileClientRemains() {
        var detector = MeetingJoinDetector()
        let zoom = CameraClient(signingID: "us.zoom.xos")

        XCTAssertEqual(detector.update(cameraClients: [zoom], microphoneClient: nil,
                                       at: start).prompt?.applicationName, "Zoom")
        XCTAssertNil(detector.update(cameraClients: [zoom], microphoneClient: nil,
                                     at: start.addingTimeInterval(5)).prompt)
    }

    func testBriefRenegotiationDoesNotNagAgain() {
        var detector = MeetingJoinDetector(reconnectGrace: 120)
        let zoom = CameraClient(signingID: "us.zoom.xos")
        _ = detector.update(cameraClients: [zoom], microphoneClient: nil, at: start)
        let ended = detector.update(cameraClients: [], microphoneClient: nil,
                                    at: start.addingTimeInterval(30))
        XCTAssertEqual(ended.endedSigningIDs, ["us.zoom.xos"])

        let returned = detector.update(cameraClients: [zoom], microphoneClient: nil,
                                       at: start.addingTimeInterval(40))
        XCTAssertNil(returned.prompt)
    }

    func testASeparateCallPromptsAgainAfterGrace() {
        var detector = MeetingJoinDetector(reconnectGrace: 120)
        let teams = CameraClient(signingID: "com.microsoft.teams2")
        _ = detector.update(cameraClients: [teams], microphoneClient: nil, at: start)
        _ = detector.update(cameraClients: [], microphoneClient: nil,
                            at: start.addingTimeInterval(10))

        let next = detector.update(cameraClients: [teams], microphoneClient: nil,
                                   at: start.addingTimeInterval(131))
        XCTAssertEqual(next.prompt?.applicationName, "Teams")
    }

    func testVirtualMicrophoneCanDetectACameraOffCall() {
        var detector = MeetingJoinDetector()
        let faceTime = CameraClient(signingID: "com.apple.FaceTime")
        let result = detector.update(cameraClients: [], microphoneClient: faceTime,
                                     at: start)
        XCTAssertEqual(result.prompt?.applicationName, "FaceTime")
    }

    func testCameraAndMicrophoneForSameAppProduceOnePrompt() {
        var detector = MeetingJoinDetector()
        let zoom = CameraClient(signingID: "us.zoom.xos")
        let result = detector.update(cameraClients: [zoom], microphoneClient: zoom,
                                     at: start)
        XCTAssertEqual(result.prompt?.applicationName, "Zoom")
    }

    func testSeveralAppsProduceOnlyOneConsentPrompt() {
        var detector = MeetingJoinDetector()
        let result = detector.update(
            cameraClients: [CameraClient(signingID: "us.zoom.xos"),
                            CameraClient(signingID: "com.apple.FaceTime")],
            microphoneClient: nil, at: start)
        XCTAssertEqual(result.prompt?.applicationName, "Zoom")
    }
}
