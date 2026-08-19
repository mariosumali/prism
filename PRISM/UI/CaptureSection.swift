// CaptureSection.swift
// PRISM
//
// The popover's Capture section — stills and saved clips (§5.15, §5.16).
// Same Control Center tile vocabulary as Freeze / Mute / Clip, because these
// are the same kind of control: one tap, obvious state, and a hotkey spelled
// out for when the popover is not open.
//
// The caption under the tiles is the point of the section. A saved clip is
// the raw camera, upstream of every effect, and that has to be legible
// before the file exists rather than after — so the line is always there,
// and it gets louder when something on air is actually hiding a room.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct CaptureSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            HStack(spacing: Metrics.itemGap) {
                stillTile
                clipTile
            }
            disclosure
        }
    }

    // MARK: - The disclosure (§5.15)

    /// Rendered straight from `ClipDisclosure.captions`, which decides what
    /// is said and when: the standing rule first, always, and today's
    /// consequence under it when something on air is hiding a room. Both,
    /// never one instead of the other — showing only the consequence would
    /// take "no effects" off the screen in the exact state where a saved
    /// clip gives most away, and would leave this section and the main
    /// window disclosing different things about the same pending file.
    private var disclosure: some View {
        let captions = ClipDisclosure.captions(state.clipConcealments)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(captions.enumerated()), id: \.offset) { index, line in
                if index == 0 {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    concealmentLine(line)
                }
            }
        }
    }

    // MARK: - Tiles

    private var stillTile: some View {
        ControlTile(title: stillTitle,
                    symbol: "camera.fill",
                    isActive: state.capturePhase != .idle,
                    accessibilityValue: stillAccessibilityValue) {
            state.takeSnapshot()
        }
        .help(stillHelp)
    }

    /// The tile counts the countdown down itself. A spinner would say
    /// "working", which is not the same promise as "in three seconds".
    private var stillTitle: String {
        if case .countdown(let remaining) = state.capturePhase {
            return "\(remaining)…"
        }
        return "Still"
    }

    private var stillAccessibilityValue: String {
        switch state.capturePhase {
        case .idle: return "ready"
        case .countdown(let remaining): return "\(remaining) seconds to go, press again to cancel"
        case .writing: return "saving"
        }
    }

    private var stillHelp: String {
        let format = state.studio.capture.format.displayName
        let sharp = state.studio.capture.prefersSharp
            ? "the sharpest of the last few frames"
            : "the picture on air"
        return "Save \(sharp) as \(format)" + state.shortcutSuffix(.snapshot)
    }

    private var clipTile: some View {
        ControlTile(title: "Save clip",
                    symbol: "square.and.arrow.down.fill",
                    isActive: false,
                    accessibilityValue: clipAccessibilityValue) {
            state.saveLastSeconds()
        }
        .help("Write the last \(Int(state.studio.replay.clampedBufferSeconds)) seconds of raw camera to a file"
              + state.shortcutSuffix(.saveClip))
    }

    private var clipAccessibilityValue: String {
        guard state.studio.replay.isArmed else { return "rolling buffer off" }
        return state.bufferedSeconds < 1
            ? "buffering"
            : String(format: "%.0f seconds available", state.bufferedSeconds)
    }

    /// Loud, not decorative: this is the one place the popover can say that
    /// the file about to be written shows what the call does not.
    private func concealmentLine(_ consequence: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "eye.trianglebadge.exclamationmark.fill")
                .foregroundStyle(.orange)
            Text(consequence)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
