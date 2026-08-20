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

    /// Asset check: custom glyphs inherit menu bar tinting and dark mode
    /// automatically as template images. Check on every render to catch
    /// asset unloading under memory pressure (and ensure both exist before
    /// using either).
    private var hasCustomGlyphs: Bool {
        guard NSImage(named: "PrismGlyph") != nil &&
              NSImage(named: "PrismGlyphFilled") != nil else {
            return false
        }
        return true
    }

    var body: some View {
        baseImage
            .opacity(state == .idle ? 0.4 : 1.0)
            .foregroundStyle(isAlerting
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
        case .effects, .sharingScreen, .replaying, .away, .badConnection,
             .lagging, .frozen, .muted, .mutedTalking, .panicked, .error:
            return true
        }
    }

    /// The states worth spending the red on: something is broken, or the
    /// picture on air is not what the user thinks it is. Talking into a muted
    /// microphone qualifies — it is the one state the user cannot notice.
    private var isAlerting: Bool {
        state == .error || state == .panicked || state == .mutedTalking
    }

    private var baseImage: Image {
        if hasCustomGlyphs {
            return Image(isFilled ? "PrismGlyphFilled" : "PrismGlyph")
        }
        return Image(systemName: isFilled ? "triangle.fill" : "triangle")
    }

    private var badgeSymbol: String? {
        switch state {
        case .frozen: return "pause.fill"
        case .muted, .mutedTalking: return "mic.slash.fill"
        case .sharingScreen: return "display"
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
        case .sharingScreen: return "PRISM, sharing a screen"
        case .replaying: return "PRISM, playing a replay"
        case .away: return "PRISM, away loop on air"
        case .badConnection: return "PRISM, bad connection simulated"
        case .lagging: return "PRISM, delay engaged"
        case .frozen: return "PRISM, frozen"
        case .muted: return "PRISM, muted"
        case .mutedTalking: return "PRISM, muted while you are talking"
        case .panicked: return "PRISM, panic engaged"
        case .error: return "PRISM, error"
        }
    }
}
