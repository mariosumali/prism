// MomentsSection.swift
// PRISM
//
// The popover's Replay / Away / Panic tiles and the replay transport row
// (§5.9–§5.11). Same Control Center tile vocabulary as Freeze / Mute / Clip,
// because these are the same kind of control: one tap, obvious state, and a
// hotkey spelled out for when the popover is not open.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct MomentsSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            HStack(spacing: Metrics.itemGap) {
                replayTile
                awayTile
                panicTile
            }
            if state.replayMode != .idle {
                transportRow
            } else if state.studio.replay.isArmed {
                bufferLine
            }
        }
    }

    // MARK: - Tiles

    private var replayTile: some View {
        ControlTile(title: "Replay",
                    symbol: "backward.fill",
                    isActive: state.replayMode == .replay,
                    accessibilityValue: replayAccessibilityValue) {
            state.toggleReplay()
        }
        .help("Rewind the last \(Int(state.studio.replay.clampedBufferSeconds)) seconds · ⌥⌘R")
    }

    private var awayTile: some View {
        ControlTile(title: "Away",
                    symbol: "moon.zzz.fill",
                    isActive: state.isAway,
                    accessibilityValue: state.isAway ? "idle loop on air" : "off") {
            state.toggleAway()
        }
        .help("Loop a still-here idle clip while you step away · ⌥⌘A")
    }

    private var panicTile: some View {
        ControlTile(title: "Panic",
                    symbol: "hand.raised.fill",
                    isActive: state.isPanicked,
                    accessibilityValue: state.isPanicked ? "engaged" : "off") {
            state.togglePanic()
        }
        .help(panicHelp)
    }

    private var panicHelp: String {
        var parts: [String] = []
        if state.studio.panic.freezes { parts.append("freeze") }
        if state.studio.panic.mutes { parts.append("mute") }
        if state.studio.panic.swapsBackdrop { parts.append("backdrop") }
        let actions = parts.isEmpty ? "nothing yet — configure it" : parts.joined(separator: " + ")
        return "\(actions) · ⌥⌘P"
    }

    private var replayAccessibilityValue: String {
        switch state.replayMode {
        case .idle: return state.studio.replay.isArmed ? "ready" : "buffer off"
        case .replay: return "playing"
        case .away: return "away loop on air"
        }
    }

    // MARK: - Transport

    private var transportRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Metrics.itemGap) {
                Text(timeString(state.replayPosition))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { state.replayPosition },
                    set: { state.scrubReplay(to: $0) }),
                       in: 0...max(state.replayDuration, 0.01))
                    .controlSize(.small)
                    .accessibilityLabel("Replay position")
                    .accessibilityValue(timeString(state.replayPosition))
                Text(timeString(state.replayDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(transportCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var transportCaption: String {
        switch state.replayMode {
        case .away:
            return "Looping. Everyone sees the idle clip until you turn this off."
        case .replay:
            let rate = state.studio.replay.clampedPlaybackRate
            let rateText = rate == 1
                ? "Playing back"
                : String(format: "Playing back at %.2g×", rate)
            return "\(rateText) — everyone is seeing the past right now."
        case .idle:
            return ""
        }
    }

    private var bufferLine: some View {
        Text(state.bufferedSeconds < 1
             ? "Buffering…"
             : String(format: "%.0f s buffered", state.bufferedSeconds))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
