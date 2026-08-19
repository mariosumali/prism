// RetouchSettings.swift
// PRISM
//
// Parameters for the skin retouch stage (§5.22, .expensive). One user knob —
// amount — and the derived quantities its kernel reads. They live here, in
// their own file, so that the retouch work can add fields without touching a
// file any other track is editing.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public struct RetouchSettings: Codable, Equatable {
    /// What switching the stage on picks when the amount is still at zero.
    /// Deliberately well under half: retouch is the effect people notice on
    /// other people's calls, and the failure mode is a plastic mask, not an
    /// under-smoothed cheek.
    public static let defaultAmount: Double = 0.35

    /// How much smoothing to apply. Zero is off, and zero is where it starts:
    /// the stage ships disabled and its knob ships inert, so a fresh install
    /// and a fresh preset both send the camera through untouched. Switching
    /// the stage on lifts a zero amount to `defaultAmount` (AppState), which
    /// is the LUT/Neutral remedy for the §8.7 inert-toggle problem — the
    /// switch is never on and doing nothing.
    public var amount: Double = 0            // 0…1
    /// How much fine texture survives. Pores and stubble are what stop a
    /// smoothed face reading as a render, so the default keeps most of them.
    ///
    /// Not a control. §8.7 asks one question per effect, and the question
    /// here is "how much", not "how much, and how much of what you removed
    /// would you like back" — the second one has no answer a user can hold in
    /// their head. It stays a persisted field so the value is stable across
    /// builds and can be dialled from an exported preset.
    public var detail: Double = 0.55         // 0…1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = c.tolerant(.amount, 0)
        detail = c.tolerant(.detail, 0.55)
    }

    public var clampedAmount: Double { min(max(amount, 0), 1) }
    public var clampedDetail: Double { min(max(detail, 0), 1) }

    /// True when the stage would change nothing, so `wantsEncode()` can
    /// decline and every surface can say why the switch is doing nothing.
    public var isInert: Bool { clampedAmount <= 0 }

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
    /// below one at full amount: even with the detail pass handing texture
    /// back, a retouch that fully replaces the skin has nothing of the
    /// original left to disagree with it, and that is the plastic look.
    public var blend: Double {
        0.9 * clampedAmount
    }
}
