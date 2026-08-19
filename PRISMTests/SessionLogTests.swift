// SessionLogTests.swift
// PRISMTests
//
// The in-memory session history (§5.21): coalescing, the capacity bound,
// what a latency report contributes, and the fact that clearing the list
// does not make the next report re-announce every drop since launch.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

@MainActor
final class SessionLogTests: XCTestCase {

    func testRepeatsCollapseIntoOneRow() {
        let log = SessionLog()
        let start = Date()
        log.record(.device, "Camera disconnected: Studio Cam", at: start)
        log.record(.device, "Camera disconnected: Studio Cam", at: start + 5)
        log.record(.device, "Camera disconnected: Studio Cam", at: start + 9)
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events[0].count, 3)
        XCTAssertEqual(log.events[0].first, start)
        XCTAssertEqual(log.events[0].last, start + 9)
    }

    func testDifferentTextBreaksTheRun() {
        let log = SessionLog()
        log.record(.device, "Camera connected: A")
        log.record(.device, "Camera connected: B")
        log.record(.device, "Camera connected: A")
        // Only consecutive repeats coalesce: A → B → A is three things
        // happening, and merging the two As would reorder the story.
        XCTAssertEqual(log.events.count, 3)
    }

    func testCapacityDropsTheOldestNotTheNewest() {
        let log = SessionLog()
        for i in 0..<(SessionLog.capacity + 50) {
            log.record(.onAir, "event \(i)")
        }
        XCTAssertEqual(log.events.count, SessionLog.capacity)
        XCTAssertEqual(log.events.last?.text, "event \(SessionLog.capacity + 49)")
        XCTAssertEqual(log.events.first?.text, "event 50")
    }

    func testReportTracksPeaksAndDrops() {
        let log = SessionLog()
        var report = LatencyReport(stages: [.blur: 4.0], totalAddedMs: 9)
        log.observe(report)
        report.totalAddedMs = 4
        report.stages = [.blur: 1.0]
        log.observe(report)
        // The live meter falls back; the peak is the number that explains a
        // degradation that already happened.
        XCTAssertEqual(log.peakAddedMs, 9, accuracy: 0.001)
        XCTAssertEqual(log.peakStageMs[.blur] ?? 0, 4.0, accuracy: 0.001)
    }

    func testARunOfDropsAccumulatesIntoOneRow() {
        let log = SessionLog()
        log.observe(LatencyReport(droppedFrames: 3))
        log.observe(LatencyReport(droppedFrames: 3))   // no delta, no row
        log.observe(LatencyReport(droppedFrames: 5))
        XCTAssertEqual(log.droppedFrames, 5)
        // Reports arrive four times a second: a row apiece would push the
        // auto-disable that explains them off a 300-row list in a minute.
        XCTAssertEqual(log.events.map(\.text), ["5 frames dropped"])
    }

    func testAnyOtherEventEndsTheDropRun() {
        let log = SessionLog()
        log.observe(LatencyReport(droppedFrames: 2))
        log.record(.degradation, "Background blur turned off")
        log.observe(LatencyReport(droppedFrames: 3))
        XCTAssertEqual(log.events.map(\.text),
                       ["2 frames dropped",
                        "Background blur turned off",
                        "1 frame dropped"])
    }

    func testClearKeepsTheDropCounterSoOldDropsAreNotReannounced() {
        let log = SessionLog()
        log.observe(LatencyReport(droppedFrames: 40))
        log.clear()
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(log.peakAddedMs, 0)
        log.observe(LatencyReport(droppedFrames: 41))
        XCTAssertEqual(log.events.map(\.text), ["1 frame dropped"])
    }

    func testExportIsPlainTextAndCarriesEveryRow() {
        let log = SessionLog()
        log.record(.degradation, "Background blur turned off")
        log.record(.degradation, "Background blur turned off")
        let text = log.exportText()
        XCTAssertTrue(text.contains("PRISM session log"))
        XCTAssertTrue(text.contains("Background blur turned off (×2)"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    // MARK: - What an export may say (§5.21)

    /// The log is a file people attach to a support thread. A window's title
    /// is a document name — "Q3 layoffs (confidential).xlsx" — and every
    /// sentence that names a shared source used to carry it verbatim. The
    /// application survives, because "what was I sharing" still needs an
    /// answer; the title does not.
    func testAnExportedLogNamesTheApplicationAndNeverTheWindowTitle() {
        let shared = ScreenSourceInfo(id: "window:7", kind: .window,
                                      name: "Q3 layoffs (confidential).xlsx",
                                      applicationName: "Microsoft Excel")
        XCTAssertEqual(shared.displayName,
                       "Microsoft Excel — Q3 layoffs (confidential).xlsx",
                       "the picker still says exactly what it is")

        let log = SessionLog()
        log.record(.device, "Source: \(shared.logName)")
        log.record(.device, ScreenCaptureStop(
            message: "\(shared.displayName) stopped sharing: it closed",
            logMessage: "\(shared.logName) stopped sharing: it closed").logMessage)

        let text = log.exportText()
        XCTAssertFalse(text.localizedCaseInsensitiveContains("layoffs"),
                       "a document name reached a file the user sends to strangers")
        XCTAssertTrue(text.contains("a Microsoft Excel window"))
    }

    /// A window with no owning application loses its title all the same —
    /// the title is the sensitive half, not the attribution.
    func testAnUnattributedWindowStillLosesItsTitle() {
        let shared = ScreenSourceInfo(id: "window:7", kind: .window,
                                      name: "Divorce settlement draft")
        XCTAssertEqual(shared.logName, "a shared window")
    }

    /// A display's name is a device name, which is exactly what the log
    /// promises it may hold — nothing is redacted that did not need to be.
    func testADisplayIsNamedTheSameWayEverywhere() {
        let display = ScreenSourceInfo(id: "display:1", kind: .display,
                                       name: "Studio Display")
        XCTAssertEqual(display.logName, display.displayName)
        XCTAssertEqual(display.logName, "Studio Display")
    }

    /// A stop with nothing to redact says the same thing twice rather than
    /// leaving the log blank.
    func testAStopWithNoRedactionLogsItsOwnSentence() {
        let stop = ScreenCaptureStop(message: "That screen is no longer available.")
        XCTAssertEqual(stop.logMessage, stop.message)
    }

    func testDurationReadsAsADuration() {
        let start = Date()
        XCTAssertEqual(SessionLog.duration(from: start, to: start + 42), "42 s")
        XCTAssertEqual(SessionLog.duration(from: start, to: start + 300), "5 min")
        XCTAssertEqual(SessionLog.duration(from: start, to: start + 3720), "1 h 2 min")
    }

    func testEveryMenuBarStateHasSomethingToSay() {
        // The glyph is what the log records when what clients can see
        // changes, so a state with no sentence would log a blank row.
        for state in [MenuBarState.idle, .live, .effects, .sharingScreen,
                      .replaying, .away, .badConnection, .lagging, .frozen,
                      .mutedTalking, .muted, .panicked, .error] {
            XCTAssertFalse(state.sessionDescription.isEmpty)
        }
    }
}
