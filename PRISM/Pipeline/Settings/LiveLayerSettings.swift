// LiveLayerSettings.swift
// PRISM
//
// What a live overlay layer (§5.8) shows: a second camera, or a screen. Its
// own file because the live-layer work owns the capture plumbing and nothing
// else needs to change when it grows a case.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// The source behind a `.live` overlay layer. Not a file path: these arrive
/// from a running capture session, so the layer holds a choice of feed rather
/// than a URL, and a layer whose feed is nil draws nothing (`isRenderable`).
public enum LiveLayerFeed: String, Codable, CaseIterable {
    case camera
    case screen

    public var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .screen: return "Screen"
        }
    }
}
