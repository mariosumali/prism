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
            // One full row rather than three tiles and an orphan: a lone
            // tile with two empty slots beside it reads as a layout bug.
            HStack(spacing: Metrics.itemGap) {
                replayTile
                awayTile
                panicTile
                lagTile
                glitchTile
            }
            // §5.28 sits above the transport rather than inside its if/else
            // chain, because it answers a different question: not "what is
            // the transport doing" but "is something about to happen without
            // me asking". Both answers can be needed at once.
            if state.presenceEngaged {
                presenceEngagedRow
            } else if state.studio.presence.isActive {
                presenceArmedLine
            }
            if state.isBadConnection {
                connectionLine
            } else if state.isLagging || state.isCatchingUp {
                lagLine
            } else if state.replayMode != .idle {
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
        .help("Rewind the last \(Int(state.studio.replay.clampedBufferSeconds)) seconds\(state.shortcutSuffix(.replay))")
    }

    private var awayTile: some View {
        ControlTile(title: "Away",
                    symbol: "moon.zzz.fill",
                    isActive: state.isAway,
                    accessibilityValue: state.isAway ? "idle loop on air" : "off") {
            state.toggleAway()
        }
        .help("Loop a still-here idle clip while you step away\(state.shortcutSuffix(.away))")
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
        return actions + state.shortcutSuffix(.panic)
    }

    private var lagTile: some View {
        ControlTile(title: "Lag",
                    symbol: "hourglass",
                    isActive: state.isLagging || state.isCatchingUp,
                    accessibilityValue: lagAccessibilityValue) {
            state.toggleLag()
        }
        .help(lagHelp)
    }

    private var lagHelp: String {
        let seconds = state.studio.lag.delaySeconds
        let audio = state.studio.lag.delaysAudio ? "picture and sound" : "picture only"
        let held = state.shortcut(for: .lag).map { " · hold \($0.displayString)" } ?? ""
        return String(format: "Fall %.1fs behind live (%@)", seconds, audio) + held
    }

    /// §5.14 — tile copy is "Glitch" because "Bad connection" cannot fit a
    /// tile label; the help line and the caption below name the feature.
    private var glitchTile: some View {
        ControlTile(title: "Glitch",
                    symbol: "wifi.exclamationmark",
                    isActive: state.isBadConnection,
                    accessibilityValue: state.isBadConnection
                        ? "bad connection on air" : "off") {
            state.toggleBadConnection()
        }
        .help(glitchHelp)
    }

    private var glitchHelp: String {
        let lag = state.studio.connection.addsLag
            ? String(format: " and %.1f s behind live",
                     state.studio.connection.lagSeconds)
            : ""
        return "Look like a bad connection — pixelated, choppy\(lag)"
            + state.shortcutSuffix(.badConnection)
    }

    /// Same honesty rule as the lag line: while the picture on air is
    /// degraded, say exactly how, in the terms the settings use.
    private var connectionLine: some View {
        Text(connectionCaption)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var connectionCaption: String {
        let connection = state.studio.connection
        var parts = [String(format: "%.0f px blocks",
                            connection.blockSize(forHeight: 1080))]
        if connection.dropsFrames {
            parts.append(String(format: "≈%.0f fps", connection.throttledFps))
        }
        if state.isLagging {
            parts.append(String(format: "%.1f s behind live",
                                state.latency.deliberateDelayMs / 1000))
        }
        return "Looking like a bad connection — " + parts.joined(separator: " · ")
    }

    private var lagAccessibilityValue: String {
        if state.isCatchingUp { return "catching up to live" }
        if state.isLagging {
            return String(format: "%.1f seconds behind live",
                          state.latency.deliberateDelayMs / 1000)
        }
        return "off"
    }

    /// The delay is stated outright rather than folded into the latency
    /// meter, which stays a measure of what PRISM costs you involuntarily.
    private var lagLine: some View {
        Text(lagCaption)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var lagCaption: String {
        if state.isCatchingUp {
            return String(format: "Catching up at %.2g×…",
                          state.studio.lag.clampedCatchUpRate)
        }
        let behind = state.latency.deliberateDelayMs / 1000
        let target = state.studio.lag.delaySeconds
        if behind < target - 0.15 {
            // Still absorbing the delay: the picture is held, not moving.
            return String(format: "Holding — %.1fs of %.1fs absorbed", behind, target)
        }
        return String(format: "%.1fs behind live", behind)
    }

    private var replayAccessibilityValue: String {
        switch state.replayMode {
        case .idle: return state.studio.replay.isArmed ? "ready" : "buffer off"
        case .replay: return "playing"
        case .away: return "away loop on air"
        case .lag: return "delay engaged"
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
        case .lag, .idle:
            return ""
        }
    }

    // MARK: - Presence (§5.28)

    /// The escape, in the surface the user is most likely to open when they
    /// sit back down. It duplicates the notice row's button on purpose: a
    /// notice can be dismissed, and the way out of something PRISM started by
    /// itself must not be dismissable.
    private var presenceEngagedRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Label(presenceEngagedCaption, systemImage: "person.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("I'm back") { state.comeBack() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    private var presenceEngagedCaption: String {
        state.isAway
            ? "PRISM put the away loop on — you were out of frame."
            : "PRISM held the picture — you were out of frame."
    }

    /// Armed and idle. Says what will happen and after how long, because a
    /// feature that acts on its own has to be predictable before it acts and
    /// not only explicable afterwards.
    private var presenceArmedLine: some View {
        Text(presenceArmedCaption)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var presenceArmedCaption: String {
        let seconds = Int(state.studio.presence.clampedAwaySeconds.rounded())
        switch state.studio.presence.action {
        case .loop:
            return "Watching — the away loop starts \(seconds) s after you leave."
        case .freeze:
            return "Watching — the picture holds \(seconds) s after you leave."
        case .none:
            return "Watching — you'll be told if you leave with PRISM on air."
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
