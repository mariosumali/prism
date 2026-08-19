// ClipDisclosure.swift
// PRISM
//
// What a saved clip shows that the call does not (§5.15).
//
// The rolling buffer records the camera upstream of every effect, which is
// exactly right for replay — a replay runs the live chain, so it matches
// whatever look is on air — and is the single most dangerous property this
// app has the moment those frames go to disk. Someone with background blur
// on has decided their room is nobody's business. Saving a clip writes the
// room. There is no warning the pipeline can give them after the fact, so
// the check happens here, before a byte is written, and it is the same
// answer on every surface.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public enum ClipDisclosure {

    /// The effects on air whose whole purpose is hiding what the camera can
    /// see, named as the user names them.
    ///
    /// Deliberately only these. Cropping, rotation and colour also make a
    /// saved clip differ from the call, and they are covered by the standing
    /// "a saved clip is the raw camera" line every surface shows — but they
    /// do not *conceal* anything, and a confirmation that fires on a zoom is
    /// a confirmation nobody reads by the time it matters.
    public static func concealments(in config: PipelineConfiguration,
                                    isPanicked: Bool) -> [String] {
        var names: [String] = []
        if config.flags(for: .blur).enabled {
            names.append("background blur")
        }
        if config.flags(for: .background).enabled {
            names.append(isPanicked ? "the panic backdrop" : "your virtual background")
        }
        if config.flags(for: .overlay).enabled, config.overlay.needsPersonMask {
            names.append("a layer sitting behind you")
        }
        return names
    }

    /// The list as one clause: "background blur and your virtual background".
    public static func phrase(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }

    /// The standing line, shown whether or not anything is being concealed.
    /// Always visible on purpose: the surprise is the point, and a caption
    /// that only appears when PRISM has already decided you are at risk
    /// teaches nobody what the feature does.
    public static let alwaysTrue =
        "A saved clip is the raw camera — no effects, no sound."

    /// Today's consequence — nil when nothing on air is hiding anything.
    ///
    /// It is an addition to `alwaysTrue`, never a substitute for it (§5.15,
    /// §8.3). Swapping the two over is the tempting edit, because the
    /// concealment sentence is the more alarming one — and it is exactly
    /// wrong: it drops "no effects", the half that teaches that the crop,
    /// the colour and the overlays go too, in the one state where a clip is
    /// most revealing. The rule teaches; the consequence stops someone.
    public static func consequence(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "Right now that means the room behind \(phrase(names)). "
            + "PRISM will ask before it writes the file."
    }

    /// Every line a capture surface shows, in order, so no surface can print
    /// a different disclosure than another for the same pending file.
    public static func captions(_ names: [String]) -> [String] {
        [alwaysTrue] + (consequence(names).map { [$0] } ?? [])
    }
}
