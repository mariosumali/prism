// StudioSettings.swift
// PRISM
//
// Behaviour settings for instant replay, the away loop, the panic chord,
// the lag switch and the voice changer (§5.9–§5.13). Deliberately NOT part
// of PipelineConfiguration: a preset captures a *look*, and "how many
// seconds of video do you keep in memory" or "what does the panic key do"
// are not looks. Switching from Meeting to Studio must not silently rearm a
// buffer, repoint a panic backdrop, or change what you sound like.
//
// Persisted whole in UserDefaults by AppState.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Instant replay / rolling buffer (§5.9)

public struct ReplaySettings: Codable, Equatable {
    /// Arms the rolling buffer. Powers instant replay AND the away loop —
    /// there is one recorder, not two. Off by default: an armed buffer runs
    /// a hardware encoder on every frame, and a resident agent should cost
    /// nothing for a feature you are not using.
    public var isArmed: Bool = false
    /// How far back you can rewind. 10 s covers "say that again" without
    /// making the buffer a memory line item (§7: < 250 MB resident).
    public var bufferSeconds: Double = 10        // 4…30
    /// Playback speed for a replay. Above 1× the replay catches up to live,
    /// which is the point: you want to rejoin the conversation, not narrate
    /// a rerun.
    public var playbackRate: Double = 1.5        // 0.25…4
    /// Recording height cap. Frames are encoded, not stored raw, but the
    /// encoder still costs bandwidth proportional to resolution, and nobody
    /// scrutinises a replay for 4K detail.
    public var maxHeight: Int = 1080             // 540 / 720 / 1080
    /// Return to live automatically once playback reaches the live edge.
    public var returnToLiveAtEnd: Bool = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isArmed = c.tolerant(.isArmed, false)
        bufferSeconds = c.tolerant(.bufferSeconds, 10)
        playbackRate = c.tolerant(.playbackRate, 1.5)
        maxHeight = c.tolerant(.maxHeight, 1080)
        returnToLiveAtEnd = c.tolerant(.returnToLiveAtEnd, true)
    }

    public var clampedBufferSeconds: Double { min(max(bufferSeconds, 4), 30) }
    public var clampedPlaybackRate: Double { min(max(playbackRate, 0.25), 4) }
}

// MARK: - Away loop (§5.10)

public struct AwaySettings: Codable, Equatable {
    /// Length of the generated idle loop. Long enough not to read as a
    /// GIF, short enough that the seam search has candidates to choose from.
    public var loopSeconds: Double = 4           // 2…10
    /// Crossfade back to the loop's first frame at the wrap point. The seam
    /// search already picks the least visible cut; this softens what is left.
    public var crossfadeMs: Double = 400         // 0…1500
    /// Stepping away means stepping away — the mic goes with you.
    public var mutesAudio: Bool = true
    /// Arm the rolling buffer the first time Away is used, rather than
    /// failing with an explanation. The loop still cannot start on that first
    /// press — there is nothing recorded yet — so PRISM arms the buffer and
    /// says so, and the next press works. That is a better answer than a
    /// control that silently does nothing, and a far better one than arming
    /// a hardware encoder by default for a feature nobody has touched.
    public var armsBufferOnFirstUse: Bool = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loopSeconds = c.tolerant(.loopSeconds, 4)
        crossfadeMs = c.tolerant(.crossfadeMs, 400)
        mutesAudio = c.tolerant(.mutesAudio, true)
        armsBufferOnFirstUse = c.tolerant(.armsBufferOnFirstUse, true)
    }

    public var clampedLoopSeconds: Double { min(max(loopSeconds, 2), 10) }
    public var clampedCrossfadeMs: Double { min(max(crossfadeMs, 0), 1500) }
}

// MARK: - Lag switch (§5.12)

/// What happens to the accumulated delay when the switch is released.
public enum LagRelease: String, Codable, CaseIterable {
    /// Cut straight back to live. The delayed backlog is never sent — the
    /// same thing a real connection does when it recovers by dropping its
    /// buffer. This is what a lag switch looks like.
    case snapBack
    /// Play out the backlog faster than real time until it is caught up, so
    /// nothing you said while lagging is lost.
    case catchUp

    public var displayName: String {
        switch self {
        case .snapBack: return "Snap back to live"
        case .catchUp: return "Catch up"
        }
    }
}

/// Deliberate added latency (§5.12) — the exact inverse of everything else
/// this app does.
///
/// Legitimate uses, in rough order of how often they come up: buying a few
/// seconds before you have to answer; making a call look like it is
/// struggling; correcting A/V skew when the audio path is running ahead of
/// the video path; and exercising PRISM's own latency reporting and
/// degradation engine with a known, controllable delay.
public struct LagSettings: Codable, Equatable {
    /// How far behind live to run. Bounded by the rolling buffer, which is
    /// where the delayed video is held (§5.9).
    public var delayMs: Double = 3000            // 200…10000
    /// Delay the microphone by the same amount. On by default: video running
    /// three seconds behind live audio does not read as a bad connection, it
    /// reads as broken software.
    public var delaysAudio: Bool = true
    public var release: LagRelease = .snapBack
    /// Speed used to consume the backlog on a catch-up release.
    public var catchUpRate: Double = 2.0         // 1.25…4
    /// Hold the hotkey to lag, rather than pressing it to toggle. A switch
    /// you hold is what the name describes, and it cannot be left on by
    /// accident — but it depends on seeing the key release, so the tile
    /// stays a plain toggle regardless.
    public var holdToLag: Bool = true
    public init() {}

    public var clampedDelayMs: Double { min(max(delayMs, 200), 10_000) }
    public var delaySeconds: Double { clampedDelayMs / 1000 }
    public var clampedCatchUpRate: Double { min(max(catchUpRate, 1.25), 4) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delayMs = c.tolerant(.delayMs, 3000)
        delaysAudio = c.tolerant(.delaysAudio, true)
        release = c.tolerant(.release, .snapBack)
        catchUpRate = c.tolerant(.catchUpRate, 2.0)
        holdToLag = c.tolerant(.holdToLag, true)
    }
}

// MARK: - Bad connection (§5.14)

/// Simulated poor network (§5.14): the picture goes blocky and colour-starved,
/// the frame rate collapses, and — optionally — the whole feed falls behind
/// live via the §5.12 delay machinery. One switch, because "my connection is
/// struggling" is one excuse, not three settings to remember.
///
/// The degradation is cosmetic and applies to the published frame only: PRISM
/// still runs the full chain at full rate underneath, so releasing the switch
/// is instant and costless.
public struct ConnectionSettings: Codable, Equatable {
    /// How bad it looks, 0.1…1. One knob drives block size, colour depth and
    /// frame rate together, because a connection never degrades one of those
    /// without the others — independent sliders would let you dial in a
    /// failure mode no network produces.
    public var severity: Double = 0.6
    /// Hold each frame and refresh at the throttled rate below. Off leaves
    /// motion smooth and degrades only the image itself.
    public var dropsFrames: Bool = true
    /// Also fall behind live (§5.12) while degraded. On by default: a feed
    /// that pixelates but answers instantly reads as a filter, not a network.
    /// Requires the rolling buffer, exactly like the lag switch.
    public var addsLag: Bool = true
    /// Delay used when `addsLag` engages. Smaller default than the lag
    /// switch's 3 s — a struggling connection is behind, not absent.
    public var lagMs: Double = 1200              // 200…10000
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = c.tolerant(.severity, 0.6)
        dropsFrames = c.tolerant(.dropsFrames, true)
        addsLag = c.tolerant(.addsLag, true)
        lagMs = c.tolerant(.lagMs, 1200)
    }

    /// The floor exists because a severity of zero would be an "on" switch
    /// that changes nothing — the §8.7 inert-toggle problem.
    public var clampedSeverity: Double { min(max(severity, 0.1), 1) }
    public var clampedLagMs: Double { min(max(lagMs, 200), 10_000) }
    public var lagSeconds: Double { clampedLagMs / 1000 }

    // Severity mappings live here, in one place, so the stage, the UI's
    // "looks like" readout and the tests can never disagree about what a
    // severity means.

    /// Pixelation block edge in pixels at the given frame height. Quadratic
    /// in severity: block *area* is what the eye reads, and linear edge
    /// growth back-loads the whole range into the last quarter of the slider.
    public func blockSize(forHeight height: Int) -> Double {
        let s = clampedSeverity
        let at1080 = 4 + 44 * s * s
        return max(2, at1080 * Double(height) / 1080)
    }

    /// Colour steps per channel. A starved encoder posterises before it
    /// pixelates — but subtly: heavy uniform banding reads as a poster
    /// filter, not a codec, so the floor stays well above unmistakable.
    public var posterizeLevels: Double {
        (34 - 22 * clampedSeverity).rounded()
    }

    /// Mean refresh rate while `dropsFrames` is on — the gate jitters the
    /// actual intervals and adds occasional stalls, because a metronomic
    /// frame rate is a strobe, not a network. Never reaches zero: a frozen
    /// picture is the §5.2 freeze, not a bad connection.
    public var throttledFps: Double {
        18 - 12 * clampedSeverity
    }

    /// Per-block shimmer amplitude — the boiling, blocky noise of a codec
    /// running out of bits. Kept subtle; the pulsing does the selling.
    public var artifactAmount: Double {
        0.02 + 0.05 * clampedSeverity
    }

    /// Fraction of blocks that receive fresh content on each refresh; the
    /// rest hold last frame's pixels. This is the packet-loss smear — moving
    /// subjects leave stale blocks behind, which is the single most
    /// recognisable artifact of a genuinely bad connection. A uniform
    /// full-frame mosaic, by contrast, reads as a deliberate filter.
    public var updateFraction: Double {
        0.95 - 0.55 * clampedSeverity
    }
}

// MARK: - Panic chord (§5.11)

/// One chord, built entirely from primitives PRISM already has. Every part
/// is individually switchable because "panic" means different things: some
/// people need the camera gone, some need the mic gone, most need both.
public struct PanicSettings: Codable, Equatable {
    public var freezes: Bool = true
    public var mutes: Bool = true
    /// Swaps the virtual background for the backdrop below. With no backdrop
    /// chosen this falls back to a flat colour rather than doing nothing.
    public var swapsBackdrop: Bool = true
    public var backdropPath: String?
    public var backdropColor: RGBColor = .prismSlate
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        freezes = c.tolerant(.freezes, true)
        mutes = c.tolerant(.mutes, true)
        swapsBackdrop = c.tolerant(.swapsBackdrop, true)
        backdropPath = (try? c.decodeIfPresent(String.self, forKey: .backdropPath)) ?? nil
        backdropColor = c.tolerant(.backdropColor, .prismSlate)
    }

    public var backdropURL: URL? {
        backdropPath.map { URL(fileURLWithPath: $0) }
    }

    /// The background configuration panic installs while engaged.
    public var backdropConfiguration: BackgroundSettings {
        var settings = BackgroundSettings()
        settings.color = backdropColor
        if let path = backdropPath {
            settings.assetPath = path
            settings.kind = Self.isVideoPath(path) ? .video : .image
        } else {
            settings.kind = .color
        }
        // A "back in a bit" card wants a hard, unambiguous edge, not a
        // photographic composite.
        settings.edgeSoftness = 0.2
        settings.lightWrap = 0.1
        return settings
    }

    static func isVideoPath(_ path: String) -> Bool {
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "qt"]
        return videoExtensions.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

// MARK: - Voice changer (§5.13)

/// The microphone voice effects. Behaviour, not look: an alien voice is a
/// stunt you engage, and a preset switch must never silently change what
/// you sound like — so this lives here, beside mute's other neighbours,
/// rather than in PipelineConfiguration.
public struct VoiceSettings: Codable, Equatable {
    /// What is on air right now. `.off` is honest pass-through.
    public var effect: VoiceEffect = .off
    /// Remembered by the ⌃⌥⌘V toggle: switching the voice off must not
    /// forget which voice it was.
    public var lastUsedEffect: VoiceEffect = .chipmunk
    /// Effect strength, 0.25…1. Scales pitch offsets geometrically and
    /// mixes linearly; the floor exists because an amount of zero would be
    /// an "on" switch that changes nothing (the §8.7 inert-toggle problem).
    public var amount: Double = 1
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        effect = c.tolerant(.effect, .off)
        lastUsedEffect = c.tolerant(.lastUsedEffect, .chipmunk)
        amount = c.tolerant(.amount, 1)
    }

    public var clampedAmount: Double { min(max(amount, 0.25), 1) }
    public var isActive: Bool { effect != .off }

    /// What the toggle recalls. Never `.off`: a toggle that recalls "off"
    /// is a switch wired to nothing.
    public var recallEffect: VoiceEffect {
        lastUsedEffect == .off ? .chipmunk : lastUsedEffect
    }
}

// MARK: - Aggregate

public struct StudioSettings: Codable, Equatable {
    public var replay = ReplaySettings()
    public var away = AwaySettings()
    public var panic = PanicSettings()
    public var lag = LagSettings()
    public var voice = VoiceSettings()
    public var connection = ConnectionSettings()
    public var capture = CaptureSettings()
    public var apps = AppRulesSettings()
    public var cleanup = VoiceCleanupSettings()
    public var micWatch = MicWatchSettings()
    public var presence = PresenceSettings()
    public var prompter = PrompterSettings()
    public var gestures = GestureSettings()
    public init() {}

    public enum CodingKeys: String, CodingKey {
        case replay, away, panic, lag, voice, connection
        case capture, apps, cleanup, micWatch, presence, prompter, gestures
    }

    /// Same forward-compatibility contract as PipelineConfiguration: a field
    /// added later must not invalidate a user's existing file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        replay = decode(.replay, ReplaySettings())
        away = decode(.away, AwaySettings())
        panic = decode(.panic, PanicSettings())
        lag = decode(.lag, LagSettings())
        voice = decode(.voice, VoiceSettings())
        connection = decode(.connection, ConnectionSettings())
        capture = decode(.capture, CaptureSettings())
        apps = decode(.apps, AppRulesSettings())
        cleanup = decode(.cleanup, VoiceCleanupSettings())
        micWatch = decode(.micWatch, MicWatchSettings())
        presence = decode(.presence, PresenceSettings())
        prompter = decode(.prompter, PrompterSettings())
        gestures = decode(.gestures, GestureSettings())
    }

    /// The rolling buffer runs when replay is armed, or when the away loop
    /// is configured to arm it on demand and is currently engaged. AppState
    /// owns the "currently engaged" half; this is the static part.
    public var bufferArmedByConfiguration: Bool { replay.isArmed }
}
