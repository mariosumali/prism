// LatencyMonitor.swift
// PRISM
//
// Per-stage timing and budget enforcement (§3.4, §6): 60-frame rolling means
// per stage and in total, a 4Hz main-thread LatencyReport publish, and the
// degradation engine — disable the most expensive unpinned stage when the
// mean exceeds budget (the last-resort stage only once nothing else is left),
// re-enable (most recently disabled first) after 120 consecutive frames below
// 60% of budget, hold a just-restored stage safe for a while so the two halves
// cannot oscillate, and surface policy pressure when nothing may be given up.
//
// Licensed under the Apache License, Version 2.0.

import Combine
import Foundation
import QuartzCore

public final class LatencyMonitor: ObservableObject {
    /// Published on the main thread at 4Hz.
    @Published public private(set) var report = LatencyReport()

    /// Degradation callbacks (§3.4), called on the main thread.
    public var onAutoDisable: ((StageID) -> Void)?
    public var onAutoReenable: ((StageID) -> Void)?
    public var onPolicyPressure: (() -> Void)?     // pinned chain over budget

    /// The monitor needs to know what it may disable.
    public var stageQuery: (() -> [(id: StageID, cost: StageCost,
                                    enabled: Bool, pinned: Bool)])?

    // MARK: Private state (guarded by `lock`; record() is any-queue)

    private struct RollingWindow {
        private var samples: [Double]
        private var index = 0
        private var sum: Double = 0
        private(set) var count = 0
        let size: Int

        init(size: Int) {
            self.size = size
            self.samples = [Double](repeating: 0, count: size)
        }

        mutating func push(_ value: Double) {
            if count == size {
                sum -= samples[index]
            } else {
                count += 1
            }
            samples[index] = value
            sum += value
            index = (index + 1) % size
        }

        var mean: Double { count == 0 ? 0 : sum / Double(count) }
        var isFull: Bool { count == size }

        mutating func reset() {
            index = 0
            count = 0
            sum = 0
            // samples need not be cleared; count gates reads
        }
    }

    private enum Decision {
        case none
        case overBudget
        case reenable(StageID)
    }

    private static let windowSize = 60

    private let lock = NSLock()
    private var captureWindow = RollingWindow(size: LatencyMonitor.windowSize)
    private var totalWindow = RollingWindow(size: LatencyMonitor.windowSize)
    private var stageWindows: [StageID: RollingWindow] = [:]

    private var policy: LatencyPolicy = .balanced
    private var frameIntervalMs: Double = 1000.0 / 30.0
    private var budgetMs: Double = LatencyPolicy.balanced.budgetMs(frameIntervalMs: 1000.0 / 30.0)

    /// Stages this monitor auto-disabled, in disable order (most recent last).
    private var autoDisabledOrder: [StageID] = []
    /// Consecutive frames with mean below 60% of budget.
    private var reenableStreak = 0
    /// Throttle for onPolicyPressure: at most once per 5s.
    private var lastPressureTime: CFTimeInterval = -.greatestFiniteMagnitude

    /// Host time at which a stage the engine restored may be sacrificed
    /// again. Without it the two halves of the engine chase each other: a
    /// chain that is over budget with the stage on and under 60% with it off
    /// disables it, waits out the 120-frame quiet streak, restores it, and
    /// disables it again — a look flickering on and off every few seconds,
    /// which reads as a bug and is worse than either steady state. Holding a
    /// restored stage means the second round finds nothing to give and raises
    /// policy pressure instead, which is the honest answer: the budget, not
    /// the chain, is what has to move.
    private var restoreHoldUntil: [StageID: CFTimeInterval] = [:]
    private static let restoreHoldSeconds: CFTimeInterval = 30

    private var handoffMs: Double = 0
    private var audioAddedMs: Double = 0
    private var deliberateDelayMs: Double = 0
    private var droppedFrames = 0

    private let publishTimer: DispatchSourceTimer

    /// Only effects stages are degradation candidates. Clip, replay and
    /// freeze carry user intent — auto-disabling them would put the live
    /// camera back on air behind the user's back, which is the one failure
    /// this app must never produce — and outputFit is structural.
    ///
    /// Eye contact, skin retouch, virtual background, overlay and style ARE
    /// candidates: they are looks, and a look is exactly what §3.4 says to
    /// sacrifice before a dropped frame. Virtual background degrading means
    /// the real room comes back, so it goes last of all (StageID.isLastResort)
    /// however expensive it is. Bad connection is excluded with the
    /// substituting stages: it is engaged by intent (§5.14), not a preset look.
    ///
    /// Internal rather than private so ChainRegistrationTests can prove every
    /// user-facing stage is either a candidate or deliberately intent-owned;
    /// a stage that is neither is one the budget can never reclaim.
    static let disableCandidates: Set<StageID> = [
        .geometry, .retouch, .adjust, .lut, .style, .blur, .gaze,
        .background, .overlay,
    ]

    // MARK: Lifecycle

    public init() {
        publishTimer = DispatchSource.makeTimerSource(queue: .main)
        publishTimer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        publishTimer.setEventHandler { [weak self] in
            self?.publishNow()
        }
        publishTimer.resume()
    }

    deinit {
        publishTimer.cancel()
    }

    // MARK: Inputs

    public func setPolicy(_ policy: LatencyPolicy, frameIntervalMs: Double) {
        lock.lock()
        self.policy = policy
        self.frameIntervalMs = frameIntervalMs
        self.budgetMs = policy.budgetMs(frameIntervalMs: frameIntervalMs)
        self.reenableStreak = 0
        lock.unlock()
    }

    /// Any queue; maintains the 60-frame rolling means and runs the
    /// degradation engine. A `dropped` sample carries no timing information —
    /// it only increments the dropped-frame counter.
    public func record(_ timings: StageTimings) {
        lock.lock()
        if timings.dropped {
            droppedFrames += 1
            lock.unlock()
            return
        }
        captureWindow.push(timings.captureToTextureMs)
        totalWindow.push(timings.totalGpuMs)
        for (id, ms) in timings.stageMs {
            var window = stageWindows[id] ?? RollingWindow(size: Self.windowSize)
            window.push(ms)
            stageWindows[id] = window
        }
        // Prune stages no longer encoding so the report shows enabled stages only.
        for key in stageWindows.keys where timings.stageMs[key] == nil {
            stageWindows.removeValue(forKey: key)
        }

        let mean = totalWindow.mean
        let budget = budgetMs
        var decision = Decision.none
        if totalWindow.isFull, mean > budget {
            // Over budget on a full window: degrade. The window is reset on
            // every disable/re-enable so the mean re-measures the new chain
            // before the engine acts again.
            reenableStreak = 0
            decision = .overBudget
        } else if mean < budget * 0.6 {
            reenableStreak += 1
            if reenableStreak >= 120, let mostRecent = autoDisabledOrder.last {
                autoDisabledOrder.removeLast()
                reenableStreak = 0
                totalWindow.reset()
                restoreHoldUntil[mostRecent] =
                    CACurrentMediaTime() + Self.restoreHoldSeconds
                decision = .reenable(mostRecent)
            }
        } else {
            reenableStreak = 0
        }
        lock.unlock()

        switch decision {
        case .none:
            break
        case .reenable(let id):
            DispatchQueue.main.async { [weak self] in self?.onAutoReenable?(id) }
        case .overBudget:
            handleOverBudget()
        }
    }

    /// Rolling handoff mean polled from the extension's 'hoff' property.
    public func recordHandoffMs(_ ms: Double) {
        lock.lock()
        handoffMs = ms
        lock.unlock()
    }

    public func setAudioAddedMs(_ ms: Double) {
        lock.lock()
        audioAddedMs = ms
        lock.unlock()
    }

    /// Latency the user asked for (§5.12). Reported alongside the measured
    /// cost, never folded into it — see `LatencyReport.deliberateDelayMs`.
    public func setDeliberateDelayMs(_ ms: Double) {
        lock.lock()
        deliberateDelayMs = ms
        lock.unlock()
    }

    public func noteDroppedFrame() {
        lock.lock()
        droppedFrames += 1
        lock.unlock()
    }

    // MARK: Degradation engine (§3.4, exact semantics per CONTRACTS)

    private func handleOverBudget() {
        // stageQuery is invoked outside the lock — it reaches into AppState.
        let stages = stageQuery?() ?? []
        let now = CACurrentMediaTime()
        lock.lock()
        restoreHoldUntil = restoreHoldUntil.filter { $0.value > now }
        let held = Set(restoreHoldUntil.keys)
        lock.unlock()

        // Two separate questions, and conflating them is what let the restore
        // hold hand the room back. `sacrificeable` is what the engine is
        // allowed to give up at all; `available` is what it may give up *this
        // round*, once the just-restored stages are set aside.
        let sacrificeable = stages.filter {
            $0.enabled && !$0.pinned && Self.disableCandidates.contains($0.id)
        }
        let available = sacrificeable.filter { !held.contains($0.id) }
        // The last-resort stage is not weighed against the others at all —
        // cost-first with a later-chain-position tie-break would pick it
        // FIRST among the expensive stages, which is precisely backwards
        // (§5.7: never reveal the room). It is considered only once there is
        // no ordinary look left to give.
        //
        // "No ordinary look left" has to mean none is *enabled*, not none is
        // available: a style inside its 30 s restore hold is still on air, and
        // reading its absence from `available` as an empty pool made the
        // virtual background the victim while an ordinary look kept running —
        // the hysteresis quietly undoing the exemption it sits next to. When
        // every ordinary look is merely held, the pool is empty on purpose and
        // the round raises policy pressure instead, which is what the hold was
        // always for.
        let anyOrdinaryEnabled = sacrificeable.contains { !$0.id.isLastResort }
        let pool = anyOrdinaryEnabled
            ? available.filter { !$0.id.isLastResort }
            : available
        // Highest cost first; tie broken by later chain position.
        if let target = pool.max(by: { a, b in
            if a.cost != b.cost { return a.cost < b.cost }
            return a.id.chainIndex < b.id.chainIndex
        }) {
            lock.lock()
            autoDisabledOrder.append(target.id)
            totalWindow.reset()
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onAutoDisable?(target.id) }
        } else {
            // Nothing left to give — what is enabled is pinned, or was only
            // just restored and must not flicker. Degrade the policy instead
            // of dropping frames: surface pressure, at most once per 5s.
            var fire = false
            lock.lock()
            if now - lastPressureTime >= 5 {
                lastPressureTime = now
                fire = true
            }
            lock.unlock()
            if fire {
                DispatchQueue.main.async { [weak self] in self?.onPolicyPressure?() }
            }
        }
    }

    // MARK: Publishing (4Hz, main thread)

    private func publishNow() {
        lock.lock()
        let captureMean = captureWindow.mean
        let totalGpuMean = totalWindow.mean
        let stageMeans = stageWindows.mapValues { $0.mean }
        let totalAdded = captureMean + totalGpuMean + handoffMs
        let next = LatencyReport(
            captureMs: captureMean,
            stages: stageMeans,
            handoffMs: handoffMs,
            totalAddedMs: totalAdded,
            budgetMs: budgetMs,
            frameIntervalMs: frameIntervalMs,
            droppedFrames: droppedFrames,
            audioAddedMs: audioAddedMs,
            syncSkewMs: totalAdded - audioAddedMs,
            deliberateDelayMs: deliberateDelayMs)
        lock.unlock()
        report = next
    }
}
