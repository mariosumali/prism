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

/// Fixed chain order (§3.3, extended):
/// Clip → Replay → Freeze → Eye contact → Geometry → Skin retouch → Adjust →
/// LUT → Background blur → Virtual background → Overlay → Style →
/// Bad connection → Output fit
///
/// The three substituting stages come first and in escalating order of
/// authority: a clip replaces the camera, a replay overrides the clip, and a
/// freeze overrides both — each is a more deliberate "stop showing me live"
/// than the one before it. Eye contact runs before Geometry so it warps in
/// the same space Vision measured the landmarks in. Skin retouch follows
/// Geometry and precedes every colour stage: it gates on skin chroma, and
/// Geometry only moves pixels around, whereas an exposure or temperature edit
/// upstream of the gate would detune it — the smoothing would drift off the
/// face exactly when the user warms the picture. Virtual background and
/// Overlay run after blur because both consume the same person mask and must
/// composite over the finished look, and Overlay runs last of the two so a
/// foreground layer sits above a replaced background. Style is the last
/// composing stage: a preset look applies to the finished scene — backdrop
/// and overlays included — exactly as Photo Booth styles a finished photo.
/// Bad connection sits after everything the user composes: a struggling
/// network degrades the finished picture, styled look included — a crisp
/// overlay on a pixelated face would give the game away instantly.
public enum StageID: String, Codable, CaseIterable, Hashable, Comparable {
    case clip
    case replay
    case freeze
    case gaze
    case geometry
    case retouch     // §5.22 skin smoothing; gated on skin chroma, pre-colour
    case adjust
    case lut
    case blur
    case background
    case overlay
    case style       // §5.4 preset visual effects (Photo Booth-style looks)
    case connection  // §5.14 simulated bad connection; engaged, not preset
    case outputFit   // always-on final fit; not user-visible as a stage

    /// Position in the chain; also the degradation tie-breaker (§3.4:
    /// later position loses first).
    public var chainIndex: Int {
        switch self {
        case .clip: return 0
        case .replay: return 1
        case .freeze: return 2
        case .gaze: return 3
        case .geometry: return 4
        case .retouch: return 5
        case .adjust: return 6
        case .lut: return 7
        case .blur: return 8
        case .background: return 9
        case .overlay: return 10
        case .style: return 11
        case .connection: return 12
        case .outputFit: return 13
        }
    }

    /// The stage the degradation engine gives up last. §5.7 requires every
    /// degraded path to err toward COVERING the room the user chose to hide;
    /// dropping the virtual background reveals it, which is worse than any
    /// other look the chain can lose — so it goes only when nothing else is
    /// left to give.
    public var isLastResort: Bool { self == .background }

    public static func < (lhs: StageID, rhs: StageID) -> Bool {
        lhs.chainIndex < rhs.chainIndex
    }

    /// User-facing name, §8.4: name things by what the user controls.
    public var displayName: String {
        switch self {
        case .clip: return "Clip"
        case .replay: return "Replay"
        case .freeze: return "Freeze"
        case .gaze: return "Eye contact"
        case .geometry: return "Framing"
        case .retouch: return "Skin retouch"
        case .adjust: return "Adjust"
        case .lut: return "LUT"
        case .blur: return "Background blur"
        case .background: return "Virtual background"
        case .overlay: return "Overlay"
        case .style: return "Style"
        case .connection: return "Bad connection"
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

    /// Latency the user asked for (§5.12 lag switch), reported separately
    /// from `totalAddedMs` rather than folded into it.
    ///
    /// Both choices are defensible and this one is deliberate. The meter's
    /// whole job is showing what PRISM costs you against a budget; three
    /// seconds of requested delay would peg it permanently and destroy the
    /// one number the app exists to keep honest. So the meter keeps
    /// measuring the involuntary cost, and the deliberate delay is shown
    /// beside it in full — never hidden, never averaged in.
    public var deliberateDelayMs: Double

    public init(captureMs: Double = 0,
                stages: [StageID: Double] = [:],
                handoffMs: Double = 0,
                totalAddedMs: Double = 0,
                budgetMs: Double = 13.3,
                frameIntervalMs: Double = 33.3,
                droppedFrames: Int = 0,
                audioAddedMs: Double = 0,
                syncSkewMs: Double = 0,
                deliberateDelayMs: Double = 0) {
        self.captureMs = captureMs
        self.stages = stages
        self.handoffMs = handoffMs
        self.totalAddedMs = totalAddedMs
        self.budgetMs = budgetMs
        self.frameIntervalMs = frameIntervalMs
        self.droppedFrames = droppedFrames
        self.audioAddedMs = audioAddedMs
        self.syncSkewMs = syncSkewMs
        self.deliberateDelayMs = deliberateDelayMs
    }

    /// Everything between the lens and the client app, deliberate delay
    /// included. This is the number that answers "how far behind am I?"
    public var endToEndMs: Double { totalAddedMs + deliberateDelayMs }
}
