// StudioSettings.swift
// PRISM
//
// Behaviour settings for instant replay, the away loop, and the panic chord
// (§5.9–§5.11). Deliberately NOT part of PipelineConfiguration: a preset
// captures a *look*, and "how many seconds of video do you keep in memory"
// or "what does the panic key do" are not looks. Switching from Meeting to
// Studio must not silently rearm a buffer or repoint a panic backdrop.
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

// MARK: - Aggregate

public struct StudioSettings: Codable, Equatable {
    public var replay = ReplaySettings()
    public var away = AwaySettings()
    public var panic = PanicSettings()
    public init() {}

    public enum CodingKeys: String, CodingKey {
        case replay, away, panic
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
    }

    /// The rolling buffer runs when replay is armed, or when the away loop
    /// is configured to arm it on demand and is currently engaged. AppState
    /// owns the "currently engaged" half; this is the static part.
    public var bufferArmedByConfiguration: Bool { replay.isArmed }
}
