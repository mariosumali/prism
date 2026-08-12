// EffectStage.swift
// PRISM
//
// Core pipeline vocabulary: stage identity, cost class, latency policy, and
// the stage protocol itself. Every stage, the monitor, the preset store, and
// the UI share these types — change them only in lockstep with CONTRACTS.md.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal

/// Fixed chain order (§3.3):
/// Clip substitution → Freeze → Geometry → Adjust → LUT → Background blur → Output fit
public enum StageID: String, Codable, CaseIterable, Hashable, Comparable {
    case clip
    case freeze
    case geometry
    case adjust
    case lut
    case blur
    case outputFit   // always-on final fit; not user-visible as a stage

    /// Position in the chain; also the degradation tie-breaker (§3.4:
    /// later position loses first).
    public var chainIndex: Int {
        switch self {
        case .clip: return 0
        case .freeze: return 1
        case .geometry: return 2
        case .adjust: return 3
        case .lut: return 4
        case .blur: return 5
        case .outputFit: return 6
        }
    }

    public static func < (lhs: StageID, rhs: StageID) -> Bool {
        lhs.chainIndex < rhs.chainIndex
    }

    /// User-facing name, §8.4: name things by what the user controls.
    public var displayName: String {
        switch self {
        case .clip: return "Clip"
        case .freeze: return "Freeze"
        case .geometry: return "Framing"
        case .adjust: return "Adjust"
        case .lut: return "LUT"
        case .blur: return "Background blur"
        case .outputFit: return "Output fit"
        }
    }
}

public enum StageCost: Int, Codable, Comparable {
    case cheap = 0
    case moderate = 1
    case expensive = 2

    public static func < (lhs: StageCost, rhs: StageCost) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// §3.4 — GPU budget as a fraction of the frame interval.
public enum LatencyPolicy: String, CaseIterable, Codable {
    case lowest    // budget = 20% of frame interval
    case balanced  // budget = 40% of frame interval   (default)
    case quality   // budget = 70% of frame interval

    public var budgetFraction: Double {
        switch self {
        case .lowest: return 0.20
        case .balanced: return 0.40
        case .quality: return 0.70
        }
    }

    public var displayName: String {
        switch self {
        case .lowest: return "Lowest latency"
        case .balanced: return "Balanced"
        case .quality: return "Maximum quality"
        }
    }

    public func budgetMs(frameIntervalMs: Double) -> Double {
        frameIntervalMs * budgetFraction
    }
}

public protocol EffectStage: AnyObject {
    var id: StageID { get }
    var isEnabled: Bool { get set }
    var cost: StageCost { get }
    func encode(commandBuffer: MTLCommandBuffer,
                input: MTLTexture,
                output: MTLTexture) throws

    /// Stages that pass input through unchanged when their work is a no-op
    /// (e.g. Geometry at identity) may return false so the pipeline can skip
    /// the pass entirely. Default: true when enabled.
    func wantsEncode() -> Bool
}

public extension EffectStage {
    func wantsEncode() -> Bool { isEnabled }
}

public enum PipelineError: Error {
    case pipelineStateUnavailable(String)
    case textureAllocationFailed
    case encodingFailed(String)
}

/// §6 — published by LatencyMonitor at 4Hz; every field surfaced in the UI.
public struct LatencyReport: Equatable {
    public var captureMs: Double
    public var stages: [StageID: Double]     // GPU ms per enabled stage
    public var handoffMs: Double             // sink push → source emit
    public var totalAddedMs: Double
    public var budgetMs: Double              // current policy budget
    public var frameIntervalMs: Double
    public var droppedFrames: Int            // since session start
    public var audioAddedMs: Double
    public var syncSkewMs: Double            // video − audio

    public init(captureMs: Double = 0,
                stages: [StageID: Double] = [:],
                handoffMs: Double = 0,
                totalAddedMs: Double = 0,
                budgetMs: Double = 13.3,
                frameIntervalMs: Double = 33.3,
                droppedFrames: Int = 0,
                audioAddedMs: Double = 0,
                syncSkewMs: Double = 0) {
        self.captureMs = captureMs
        self.stages = stages
        self.handoffMs = handoffMs
        self.totalAddedMs = totalAddedMs
        self.budgetMs = budgetMs
        self.frameIntervalMs = frameIntervalMs
        self.droppedFrames = droppedFrames
        self.audioAddedMs = audioAddedMs
        self.syncSkewMs = syncSkewMs
    }
}
