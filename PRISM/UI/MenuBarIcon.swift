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
            .foregroundStyle(state == .error
                             ? AnyShapeStyle(.red)
                             : AnyShapeStyle(.primary))
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
        case .effects, .frozen, .muted, .error:
            return true
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
        case .muted: return "mic.slash.fill"
        default: return nil
        }
    }

    private var accessibilityDescription: String {
        switch state {
        case .idle: return "PRISM, not in use"
        case .live: return "PRISM, live"
        case .effects: return "PRISM, effects active"
        case .frozen: return "PRISM, frozen"
        case .muted: return "PRISM, muted"
        case .error: return "PRISM, error"
        }
    }
}
