// LatencyMonitorTests.swift
// PRISMTests
//
// Exercises the degradation engine exactly as §3.4 / CONTRACTS.md specify:
// a full 60-frame rolling mean over budget disables the most expensive
// enabled unpinned stage (ties → later chain position), the last-resort
// stage survives every other look, pinned stages are exempt, re-enable fires
// only after 120 consecutive frames with the mean below 60% of budget, a
// restored stage is held rather than sacrificed straight back, a chain with
// nothing left to give raises policy pressure (rate-limited to once per 5s),
// and the published LatencyReport carries the policy budget and accumulated
// dropped frames.
//
// All timing is synthetic — no camera, no GPU. Callbacks are dispatched to
// the main thread, so assertions ride on XCTest expectations.
//
// Licensed under the Apache License, Version 2.0.

import Combine
import XCTest

final class LatencyMonitorTests: XCTestCase {

    private typealias StageRow = (id: StageID, cost: StageCost, enabled: Bool, pinned: Bool)

    /// Mutable stage table backing `stageQuery`. Everything in these tests
    /// runs on the main thread (record() is called from the test, callbacks
    /// are delivered on main), so plain vars are race-free.
    private final class StageTable {
        var enabled: Set<StageID>
        var pinned: Set<StageID>
        let all: [(StageID, StageCost)]

        init(enabled: Set<StageID>, pinned: Set<StageID> = [],
             all: [(StageID, StageCost)] = [(.geometry, .cheap), (.adjust, .cheap),
                                            (.lut, .moderate), (.blur, .expensive)]) {
            self.enabled = enabled
            self.pinned = pinned
            self.all = all
        }

        func rows() -> [StageRow] {
            all.map { (id: $0.0, cost: $0.1,
                       enabled: enabled.contains($0.0),
                       pinned: pinned.contains($0.0)) }
        }
    }

    private func makeTimings(gpuMs: Double,
                             captureMs: Double = 0.2,
                             stageMs: [StageID: Double] = [:],
                             dropped: Bool = false) -> StageTimings {
        StageTimings(captureToTextureMs: captureMs,
                     stageMs: stageMs,
                     totalGpuMs: gpuMs,
                     wallMs: captureMs + gpuMs + 1,
                     dropped: dropped)
    }

    private func feed(_ monitor: LatencyMonitor, frames: Int, gpuMs: Double) {
        for _ in 0..<frames {
            monitor.record(makeTimings(gpuMs: gpuMs))
        }
    }

    /// setPolicy(.balanced, 25ms) → budget = 10ms exactly. 12ms frames are
    /// over budget; 2ms frames are below the 6ms (60%) re-enable threshold.
    private func makeMonitor(table: StageTable) -> LatencyMonitor {
        let monitor = LatencyMonitor()
        monitor.setPolicy(.balanced, frameIntervalMs: 25)
        monitor.stageQuery = { table.rows() }
        return monitor
    }

    // MARK: (a) Over budget disables the most expensive enabled unpinned stage

    func testDegradationDisablesMostExpensiveFirstThenWorksDownTheChain() {
        let table = StageTable(enabled: [.geometry, .adjust, .lut, .blur])
        let monitor = makeMonitor(table: table)

        var disabledSequence: [StageID] = []
        var currentExpectation: XCTestExpectation?
        monitor.onAutoDisable = { id in
            disabledSequence.append(id)
            table.enabled.remove(id)          // mirror what AppState would do
            currentExpectation?.fulfill()
        }

        // §3.4 ordering: expensive → moderate → cheap; the cheap tie between
        // geometry and adjust breaks toward the later chain position (adjust).
        for expected in [StageID.blur, .lut, .adjust, .geometry] {
            let exp = expectation(description: "auto-disable \(expected)")
            currentExpectation = exp
            // Exactly one full 60-frame window over budget per round; the
            // monitor resets the window after each disable.
            feed(monitor, frames: 60, gpuMs: 12)
            wait(for: [exp], timeout: 2)
        }
        XCTAssertEqual(disabledSequence, [.blur, .lut, .adjust, .geometry])
    }

    func testNoDisableBeforeWindowIsFull() {
        let table = StageTable(enabled: [.geometry, .adjust, .lut, .blur])
        let monitor = makeMonitor(table: table)

        let noFire = expectation(description: "no disable on a partial window")
        noFire.isInverted = true
        monitor.onAutoDisable = { _ in noFire.fulfill() }

        feed(monitor, frames: 59, gpuMs: 12)   // over budget, but window not full
        wait(for: [noFire], timeout: 0.3)
    }

    func testCheapTieBreaksTowardLaterChainIndex() {
        // Only the two cheap stages enabled: geometry (chainIndex 2) vs
        // adjust (chainIndex 3) → adjust must lose first.
        let table = StageTable(enabled: [.geometry, .adjust])
        let monitor = makeMonitor(table: table)

        let exp = expectation(description: "tie broken by later chain position")
        var disabled: StageID?
        monitor.onAutoDisable = { id in
            disabled = id
            table.enabled.remove(id)
            exp.fulfill()
        }
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(disabled, .adjust)
    }

    /// §5.7: a degraded path errs toward covering the background, never
    /// revealing it. Cost-then-later-chain-position alone gets this exactly
    /// backwards — virtual background (9) sits after both other expensive
    /// stages, so the plain tie-break hands the user's real room back to the
    /// call before it gives up eye contact or blur.
    func testVirtualBackgroundIsSurrenderedLastAmongEqualCosts() {
        let table = StageTable(enabled: [.gaze, .blur, .background],
                               all: [(.gaze, .expensive), (.blur, .expensive),
                                     (.background, .expensive)])
        let monitor = makeMonitor(table: table)

        var disabledSequence: [StageID] = []
        var currentExpectation: XCTestExpectation?
        monitor.onAutoDisable = { id in
            disabledSequence.append(id)
            table.enabled.remove(id)
            currentExpectation?.fulfill()
        }

        for expected in [StageID.blur, .gaze, .background] {
            let exp = expectation(description: "auto-disable \(expected)")
            currentExpectation = exp
            feed(monitor, frames: 60, gpuMs: 12)
            wait(for: [exp], timeout: 2)
        }
        XCTAssertEqual(disabledSequence, [.blur, .gaze, .background])
    }

    // MARK: (b) Pinned stages are never auto-disabled

    func testPinnedStageIsSkippedAndUnpinnedStagesLoseInstead() {
        let table = StageTable(enabled: [.geometry, .adjust, .blur],
                               pinned: [.blur])
        let monitor = makeMonitor(table: table)

        var disabledSequence: [StageID] = []
        var currentExpectation: XCTestExpectation?
        monitor.onAutoDisable = { id in
            disabledSequence.append(id)
            table.enabled.remove(id)
            currentExpectation?.fulfill()
        }
        var pressureCount = 0
        var pressureExpectation: XCTestExpectation?
        monitor.onPolicyPressure = {
            pressureCount += 1
            pressureExpectation?.fulfill()
        }

        // Blur is expensive but pinned; the cheap unpinned stages go first,
        // adjust before geometry (later chain position loses the tie).
        for expected in [StageID.adjust, .geometry] {
            let exp = expectation(description: "auto-disable \(expected)")
            currentExpectation = exp
            feed(monitor, frames: 60, gpuMs: 12)
            wait(for: [exp], timeout: 2)
        }
        XCTAssertEqual(disabledSequence, [.adjust, .geometry])
        XCTAssertFalse(disabledSequence.contains(.blur))

        // Only the pinned stage remains: still over budget → policy pressure,
        // never a disable of the pinned stage.
        let pressure = expectation(description: "policy pressure once pinned-only")
        pressureExpectation = pressure
        currentExpectation = nil
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [pressure], timeout: 2)
        XCTAssertEqual(pressureCount, 1)
        XCTAssertFalse(disabledSequence.contains(.blur))
    }

    // MARK: (c) Re-enable only after 120 consecutive frames below 60% of budget

    func testReenableFiresOnlyAfter120ConsecutiveQuietFrames() {
        let table = StageTable(enabled: [.geometry, .adjust, .lut, .blur])
        let monitor = makeMonitor(table: table)

        let disabled = expectation(description: "blur disabled")
        monitor.onAutoDisable = { id in
            table.enabled.remove(id)
            disabled.fulfill()
        }
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [disabled], timeout: 2)

        // 119 quiet frames (mean 2ms < 6ms): not yet.
        let premature = expectation(description: "no re-enable at 119 frames")
        premature.isInverted = true
        monitor.onAutoReenable = { _ in premature.fulfill() }
        feed(monitor, frames: 119, gpuMs: 2)
        wait(for: [premature], timeout: 0.3)

        // Frame 120 completes the streak → re-enable the most recent victim.
        let fired = expectation(description: "re-enable on frame 120")
        var reenabled: StageID?
        monitor.onAutoReenable = { id in
            reenabled = id
            fired.fulfill()
        }
        feed(monitor, frames: 1, gpuMs: 2)
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(reenabled, .blur)
    }

    func testQuietStreakResetsWhenMeanCrossesSixtyPercent() {
        let table = StageTable(enabled: [.geometry, .adjust, .lut, .blur])
        let monitor = makeMonitor(table: table)

        let disabled = expectation(description: "blur disabled")
        monitor.onAutoDisable = { id in
            table.enabled.remove(id)
            disabled.fulfill()
        }
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [disabled], timeout: 2)

        // 60 quiet frames build a streak, then one 300ms spike lifts the
        // 60-frame mean to ~6.97ms — above the 6ms threshold (but below the
        // 10ms budget, so no new disable). The streak must restart, and the
        // spike stays in the rolling window for 60 pushes: 59 frames with
        // the mean still elevated, then 119 more to rebuild the streak.
        feed(monitor, frames: 60, gpuMs: 2)
        feed(monitor, frames: 1, gpuMs: 300)

        let premature = expectation(description: "no re-enable while streak rebuilt")
        premature.isInverted = true
        monitor.onAutoReenable = { _ in premature.fulfill() }
        var prematureDisable = false
        monitor.onAutoDisable = { _ in prematureDisable = true }
        feed(monitor, frames: 178, gpuMs: 2)   // 59 elevated-mean + 119 streak
        wait(for: [premature], timeout: 0.3)
        XCTAssertFalse(prematureDisable, "the spike must not trigger a disable")

        let fired = expectation(description: "re-enable after the rebuilt streak")
        var reenabled: StageID?
        monitor.onAutoReenable = { id in
            reenabled = id
            fired.fulfill()
        }
        feed(monitor, frames: 1, gpuMs: 2)
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(reenabled, .blur)
    }

    func testNoReenableWhenNothingWasAutoDisabled() {
        let table = StageTable(enabled: [.geometry, .adjust, .lut, .blur])
        let monitor = makeMonitor(table: table)

        let noFire = expectation(description: "no spontaneous re-enable")
        noFire.isInverted = true
        monitor.onAutoReenable = { _ in noFire.fulfill() }

        feed(monitor, frames: 150, gpuMs: 2)   // quiet forever, nothing disabled
        wait(for: [noFire], timeout: 0.3)
    }

    /// A chain that is over budget with a stage on and comfortably under it
    /// with the stage off satisfies both halves of the engine forever. Without
    /// hysteresis the user watches the same look switch off, come back, and
    /// switch off again every few seconds; the restored stage is held instead,
    /// so the second round finds nothing to give and asks for a bigger budget.
    func testRestoredStageIsNotImmediatelySacrificedAgain() {
        let table = StageTable(enabled: [.blur], all: [(.blur, .expensive)])
        let monitor = makeMonitor(table: table)

        let disabled = expectation(description: "blur disabled")
        monitor.onAutoDisable = { id in
            table.enabled.remove(id)
            disabled.fulfill()
        }
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [disabled], timeout: 2)

        let restored = expectation(description: "blur restored")
        monitor.onAutoReenable = { id in
            table.enabled.insert(id)
            restored.fulfill()
        }
        feed(monitor, frames: 120, gpuMs: 2)
        wait(for: [restored], timeout: 2)

        // Over budget again with only the just-restored stage to give.
        var disabledAgain = false
        monitor.onAutoDisable = { _ in disabledAgain = true }
        let pressure = expectation(description: "policy pressure instead of a second cycle")
        monitor.onPolicyPressure = { pressure.fulfill() }
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [pressure], timeout: 2)
        XCTAssertFalse(disabledAgain, "a restored stage must not flicker back off")
    }

    /// The two protections have to hold at the same time. The restore hold
    /// takes a just-restored ordinary look out of this round's candidates,
    /// and reading that absence as "no ordinary look is left" handed the
    /// virtual background over while style was still running — the room comes
    /// back to the call because a style was being protected from flicker
    /// (§5.7). A held look is still on air, so the round has nothing to give
    /// and asks for a bigger budget instead.
    func testAHeldOrdinaryLookIsNeverPaidForWithTheVirtualBackground() {
        let table = StageTable(enabled: [.style, .background],
                               all: [(.style, .expensive),
                                     (.background, .expensive)])
        let monitor = makeMonitor(table: table)

        let disabled = expectation(description: "style disabled, not the background")
        monitor.onAutoDisable = { id in
            table.enabled.remove(id)
            XCTAssertEqual(id, .style, "the last resort must not go first")
            disabled.fulfill()
        }
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [disabled], timeout: 2)

        let restored = expectation(description: "style restored and held")
        monitor.onAutoReenable = { id in
            table.enabled.insert(id)
            restored.fulfill()
        }
        feed(monitor, frames: 120, gpuMs: 2)
        wait(for: [restored], timeout: 2)

        // Over budget again inside style's 30 s hold. The only stage not held
        // is the background — and it must still not be the one that goes.
        var disabledAgain: [StageID] = []
        monitor.onAutoDisable = { disabledAgain.append($0) }
        let pressure = expectation(description: "policy pressure, not the room")
        monitor.onPolicyPressure = { pressure.fulfill() }
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [pressure], timeout: 2)
        XCTAssertTrue(disabledAgain.isEmpty,
                      "the virtual background went while an ordinary look was "
                        + "merely inside its restore hold")
    }

    /// …and the exemption is not a veto. With no ordinary look left at all,
    /// the last-resort stage IS the candidate — §3.4 sacrifices a look before
    /// it drops a frame, and by then the background is the only look there is.
    func testTheVirtualBackgroundStillGoesWhenItIsAllThatIsLeft() {
        let table = StageTable(enabled: [.background],
                               all: [(.background, .expensive)])
        let monitor = makeMonitor(table: table)

        let disabled = expectation(description: "background disabled last of all")
        monitor.onAutoDisable = { id in
            table.enabled.remove(id)
            XCTAssertEqual(id, .background)
            disabled.fulfill()
        }
        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [disabled], timeout: 2)
    }

    // MARK: (d) All-pinned chain over budget → policy pressure, rate-limited

    func testAllPinnedOverBudgetFiresPolicyPressureExactlyOnceWithin5s() {
        let table = StageTable(enabled: [.geometry, .adjust, .lut, .blur],
                               pinned: [.geometry, .adjust, .lut, .blur])
        let monitor = makeMonitor(table: table)

        var disableFired = false
        monitor.onAutoDisable = { _ in disableFired = true }

        var pressureCount = 0
        let first = expectation(description: "policy pressure fires")
        monitor.onPolicyPressure = {
            pressureCount += 1
            if pressureCount == 1 { first.fulfill() }
        }

        feed(monitor, frames: 60, gpuMs: 12)
        wait(for: [first], timeout: 2)
        XCTAssertFalse(disableFired, "pinned stages must never be auto-disabled")

        // The window stays full and over budget, so every subsequent frame
        // re-evaluates pressure — the 5s rate limit must swallow all of them.
        let noSecond = expectation(description: "no second pressure within 5s")
        noSecond.isInverted = true
        monitor.onPolicyPressure = {
            pressureCount += 1
            noSecond.fulfill()
        }
        feed(monitor, frames: 30, gpuMs: 12)
        wait(for: [noSecond], timeout: 0.3)
        XCTAssertEqual(pressureCount, 1)
        XCTAssertFalse(disableFired)
    }

    // MARK: (e) LatencyReport fields

    func testReportCarriesBudgetMeansHandoffAudioAndDroppedFrames() throws {
        let monitor = LatencyMonitor()
        let interval = 1000.0 / 24.0
        monitor.setPolicy(.quality, frameIntervalMs: interval)   // 70% → 29.17ms

        for _ in 0..<10 {
            monitor.record(makeTimings(gpuMs: 3.0, captureMs: 0.5,
                                       stageMs: [.adjust: 1.0, .lut: 2.0]))
        }
        // Dropped frames accumulate from both entry points and carry no
        // timing information.
        for _ in 0..<3 {
            monitor.record(makeTimings(gpuMs: 999, dropped: true))
        }
        monitor.noteDroppedFrame()
        monitor.noteDroppedFrame()
        monitor.recordHandoffMs(1.5)
        monitor.setAudioAddedMs(2.25)

        let exp = expectation(description: "4Hz report includes everything")
        exp.assertForOverFulfill = false
        var captured: LatencyReport?
        let cancellable = monitor.$report.sink { report in
            if report.droppedFrames == 5, report.handoffMs == 1.5 {
                captured = report
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2)
        cancellable.cancel()

        let report = try XCTUnwrap(captured)
        // budgetMs = policy fraction × frame interval (§3.4).
        XCTAssertEqual(report.budgetMs, 0.70 * interval, accuracy: 0.001)
        XCTAssertEqual(report.frameIntervalMs, interval, accuracy: 0.001)
        // 60-frame rolling means over the 10 identical valid samples.
        XCTAssertEqual(report.captureMs, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.stages[.adjust] ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(report.stages[.lut] ?? -1, 2.0, accuracy: 0.001)
        // Total added = capture + GPU + handoff; the dropped samples must not
        // have polluted the means.
        XCTAssertEqual(report.totalAddedMs, 0.5 + 3.0 + 1.5, accuracy: 0.001)
        XCTAssertEqual(report.droppedFrames, 5)
        XCTAssertEqual(report.audioAddedMs, 2.25, accuracy: 0.001)
        XCTAssertEqual(report.syncSkewMs, report.totalAddedMs - 2.25, accuracy: 0.001)
    }

    func testReportBudgetTracksPolicyChanges() {
        let monitor = LatencyMonitor()
        monitor.setPolicy(.lowest, frameIntervalMs: 1000.0 / 60.0)   // 20% → 3.33ms

        let exp = expectation(description: "budget follows the new policy")
        exp.assertForOverFulfill = false
        let cancellable = monitor.$report.sink { report in
            if abs(report.budgetMs - 0.20 * 1000.0 / 60.0) < 0.001 {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2)
        cancellable.cancel()
    }
}
