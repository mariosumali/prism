// MenuBarIcon.swift
// PRISM
//
// Maps MenuBarState to the menu bar glyph (§8.2): outline prism when idle
// or live pass-through, filled when effects are active, pause/slash badge
// overlays for frozen/muted, red tint on error, 40% opacity when idle.
// Uses the template PDF assets when present, SF Symbols otherwise.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

struct MenuBarIcon: View {
    let state: MenuBarState

    /// Asset check runs once; the assets are template PDFs so they inherit
    /// menu bar tinting and dark mode automatically.
    private static let hasCustomGlyphs: Bool =
        NSImage(named: "PrismGlyph") != nil && NSImage(named: "PrismGlyphFilled") != nil

    var body: some View {
        baseImage
            .opacity(state == .idle ? 0.4 : 1.0)
            .foregroundStyle(tint)
            .overlay(alignment: .bottomTrailing) {
                if let badge = badgeSymbol {
                    Image(systemName: badge)
                        .font(.caption2.weight(.bold))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityLabel(accessibilityDescription)
    }

    private var isFilled: Bool {
        switch state {
        case .idle, .live:
            return false
        case .effects, .replaying, .away, .badConnection, .lagging, .frozen,
             .mutedTalking, .muted, .panicked, .error:
            return true
        }
    }

    /// Red is reserved for "something is wrong or has been declared an
    /// emergency". Muted-and-talking is neither — it is a nudge — so it
    /// takes the warning colour instead of the error one (§5.15), which is
    /// also the only thing distinguishing it from a plain mute at a glance.
    private var tint: AnyShapeStyle {
        switch state {
        case .error, .panicked: return AnyShapeStyle(.red)
        case .mutedTalking: return AnyShapeStyle(.orange)
        default: return AnyShapeStyle(.primary)
        }
    }

    private var baseImage: Image {
        if Self.hasCustomGlyphs {
            return Image(isFilled ? "PrismGlyphFilled" : "PrismGlyph")
        }
        return Image(systemName: isFilled ? "triangle.fill" : "triangle")
    }

    private var badgeSymbol: String? {
        switch state {
        case .frozen: return "pause.fill"
        case .muted, .mutedTalking: return "mic.slash.fill"
        case .replaying: return "backward.fill"
        case .away: return "moon.zzz.fill"
        case .badConnection: return "wifi.exclamationmark"
        case .lagging: return "hourglass"
        case .panicked: return "hand.raised.fill"
        default: return nil
        }
    }

    private var accessibilityDescription: String {
        switch state {
        case .idle: return "PRISM, not in use"
        case .live: return "PRISM, live"
        case .effects: return "PRISM, effects active"
        case .replaying: return "PRISM, playing a replay"
        case .away: return "PRISM, away loop on air"
        case .badConnection: return "PRISM, bad connection simulated"
        case .lagging: return "PRISM, delay engaged"
        case .frozen: return "PRISM, frozen"
        case .mutedTalking: return "PRISM, muted while you are talking"
        case .muted: return "PRISM, muted"
        case .panicked: return "PRISM, panic engaged"
        case .error: return "PRISM, error"
        }
    }
}
