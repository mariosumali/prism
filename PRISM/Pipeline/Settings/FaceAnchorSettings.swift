// FaceAnchorSettings.swift
// PRISM
//
// Where an overlay layer (§5.8) is pinned: to the frame, or to the face the
// shared tracker is already measuring. Its own file so the face-anchored
// placement work can add points without touching the layer model.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// The coordinate space a layer's offset and scale are measured in.
public enum LayerAnchor: String, Codable, CaseIterable {
    /// Fixed in the output frame — a lower third, a border, a watermark.
    case frame
    /// Rides the face. Costs nothing extra: the tracker runs for eye contact
    /// and retouch already, and the overlay stage holds the same instance.
    case face

    public var displayName: String {
        switch self {
        case .frame: return "The frame"
        case .face: return "My face"
        }
    }
}

/// Which landmark a face-anchored layer hangs from. These are named for what
/// they are worn on rather than for the landmark index behind them, because
/// the choice a user makes is "hat" or "moustache", not "landmark 27".
public enum FaceAnchorPoint: String, Codable, CaseIterable {
    case aboveHead
    case eyes
    case underNose
    case mouth
    case chin
    /// The whole face box — for masks and full-face props that need to scale
    /// with the head rather than sit at one point on it.
    case face

    public var displayName: String {
        switch self {
        case .aboveHead: return "Above my head"
        case .eyes: return "My eyes"
        case .underNose: return "Under my nose"
        case .mouth: return "My mouth"
        case .chin: return "My chin"
        case .face: return "My whole face"
        }
    }
}
