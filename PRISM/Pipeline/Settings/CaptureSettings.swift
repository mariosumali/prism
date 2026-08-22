// CaptureSettings.swift
// PRISM
//
// Where stills go and what they look like. Behaviour, not a look: a preset
// switch must never repoint someone's photo folder, so this hangs off
// StudioSettings beside replay and panic.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public enum StillFormat: String, Codable, CaseIterable, Sendable {
    /// Lossless, and readable by everything. The default because a still
    /// pulled off a call is usually pasted straight into a message.
    case png
    /// A quarter of the size for the same picture, but only Apple platforms
    /// open it without help.
    case heic

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .heic: return "HEIC"
        }
    }

    public var fileExtension: String { rawValue }
}

public struct CaptureSettings: Codable, Equatable {
    public var format: StillFormat = .png
    /// Absolute path to the destination folder; nil means ~/Movies/PRISM.
    /// PRISM is not sandboxed (§9), so no bookmark round-trip is needed —
    /// the same arrangement as background assets.
    ///
    /// One folder for stills and clips both. Two would mean two places to
    /// look for the thing you just saved, and the names already say which
    /// is which.
    public var folderPath: String?
    /// Seconds of countdown before the shutter. Zero is the default because a
    /// countdown you did not ask for is a photo you missed; the delay exists
    /// for the case where you are also the subject.
    public var countdownSeconds: Int = 0       // 0…10
    /// Pick the sharpest of the last few frames rather than the one that
    /// happened to be on screen when the key went down. Off by default: it is
    /// the surprising behaviour, and the honest still is the one you saw.
    public var prefersSharp: Bool = false
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.tolerant(.format, .png)
        folderPath = (try? c.decodeIfPresent(String.self, forKey: .folderPath)) ?? nil
        countdownSeconds = c.tolerant(.countdownSeconds, 0)
        prefersSharp = c.tolerant(.prefersSharp, false)
    }

    public var clampedCountdownSeconds: Int { min(max(countdownSeconds, 0), 10) }

    /// Resolved destination. Falls back to a folder of PRISM's own inside
    /// Movies rather than to nothing — a capture that silently goes nowhere
    /// is worse than one that goes somewhere ordinary, and the clips are
    /// the reason it is Movies rather than Pictures.
    public var folderURL: URL {
        if let folderPath {
            return URL(fileURLWithPath: folderPath, isDirectory: true)
        }
        return Self.defaultFolderURL
    }

    public static var defaultFolderURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent("PRISM", isDirectory: true)
    }

    /// True while the user has not repointed the folder — the surfaces say
    /// "~/Movies/PRISM" rather than an absolute path in that case.
    public var usesDefaultFolder: Bool { folderPath == nil }
}
