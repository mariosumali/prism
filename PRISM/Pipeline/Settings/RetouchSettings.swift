// RetouchSettings.swift
// PRISM
//
// Parameters for the skin retouch stage (§5.4, .expensive). The stage is
// registered and declines to encode; these are the knobs its kernel will
// read. They live here, in their own file, so that the retouch work can add
// fields without touching a file any other track is editing.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public struct RetouchSettings: Codable, Equatable {
    /// How much smoothing to apply. Deliberately well under half: retouch is
    /// the effect people notice on other people's calls, and the failure mode
    /// is a plastic mask, not an under-smoothed cheek.
    public var amount: Double = 0.35        // 0…1
    /// How much fine texture survives. Pores and stubble are what stop a
    /// smoothed face reading as a render, so the default keeps most of them —
    /// this is the knob that separates "retouched" from "airbrushed".
    public var detail: Double = 0.55        // 0…1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = c.tolerant(.amount, 0.35)
        detail = c.tolerant(.detail, 0.55)
    }

    /// The floor exists because an amount of zero would be an "on" switch
    /// that changes nothing — the §8.7 inert-toggle problem, and the same
    /// reason ConnectionSettings.severity is floored.
    public var clampedAmount: Double { min(max(amount, 0.1), 1) }
    public var clampedDetail: Double { min(max(detail, 0), 1) }

    /// Spatial radius of the smoothing kernel, in pixels at the given frame
    /// height. Expressed against 1080 and scaled, exactly like the blur and
    /// bad-connection block sizes: a radius fixed in pixels smooths a 720p
    /// face twice as hard as a 1080p one, which is how the same slider ends
    /// up meaning two different looks on two different formats.
    public func spatialSigma(forHeight height: Int) -> Double {
        let at1080 = 1.5 + 6.5 * clampedAmount
        return max(0.5, at1080 * Double(height) / 1080)
    }

    /// Tonal tolerance of the edge-aware weight, in normalised luma. Anything
    /// further than this from the centre pixel is treated as an edge and left
    /// alone — this is the term that keeps eyelashes, nostrils and the lip
    /// line out of the blur, so it shrinks as `detail` rises.
    public var rangeSigma: Double {
        0.02 + 0.10 * (1 - clampedDetail)
    }

    /// Fraction of the smoothed result mixed back over the original. Kept
    /// below one at full amount: a retouch that fully replaces the skin has
    /// no high-frequency content left to blend, and that is the plastic look.
    public var blend: Double {
        0.15 + 0.75 * clampedAmount
    }
}
