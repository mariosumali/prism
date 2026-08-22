// MeetingJoinDetector.swift
// PRISM
//
// Turns the virtual camera/microphone's client edges into one meeting-mode
// suggestion per call. Detection never starts Meeting mode; accepting the
// actionable notification is the only path from a suggestion to listening.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// The small, non-sensitive payload placed in the notification. It names an
/// application, never a window title, URL, participant, or anything said.
public struct MeetingJoinCandidate: Equatable, Hashable, Identifiable {
    public var signingID: String
    public var applicationName: String

    public var id: String { signingID.lowercased() }

    public init(signingID: String, applicationName: String) {
        self.signingID = signingID
        self.applicationName = applicationName
    }
}

/// Supported native meeting apps and browsers that can host Google Meet.
/// Browser detection deliberately says which browser noticed the call rather
/// than claiming PRISM inspected a tab or URL—it does neither.
public enum MeetingClientCatalog {
    private static let exactNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.apple.facetime": "FaceTime",
        "com.microsoft.teams": "Teams",
        "com.microsoft.teams2": "Teams",
        "com.google.chrome": "Chrome",
        "com.google.chrome.canary": "Chrome Canary",
        "com.apple.safari": "Safari",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.browser": "Arc",
    ]

    public static func candidate(for client: CameraClient) -> MeetingJoinCandidate? {
        candidate(signingID: client.signingID)
    }

    public static func candidate(signingID: String) -> MeetingJoinCandidate? {
        let folded = signingID.lowercased()
        if let name = exactNames[folded] {
            return MeetingJoinCandidate(signingID: signingID, applicationName: name)
        }

        // Chrome and Safari installable web apps carry generated suffixes.
        // Treating one as a meeting candidate can only show a suggestion; it
        // grants no access and starts nothing, so prefix matching is safe here.
        if folded.hasPrefix("com.google.chrome.app.") {
            return MeetingJoinCandidate(signingID: signingID,
                                        applicationName: "Google Meet in Chrome")
        }
        if folded.hasPrefix("com.apple.safari.webapp.") {
            return MeetingJoinCandidate(signingID: signingID,
                                        applicationName: "Google Meet in Safari")
        }
        return nil
    }
}

public struct MeetingJoinDetection: Equatable {
    public var prompt: MeetingJoinCandidate?
    public var endedSigningIDs: [String]

    public init(prompt: MeetingJoinCandidate? = nil,
                endedSigningIDs: [String] = []) {
        self.prompt = prompt
        self.endedSigningIDs = endedSigningIDs
    }
}

/// Edge detector over the currently observed meeting clients.
///
/// Camera use is the strongest signal. Virtual-microphone use is a fallback
/// when exactly one supported app (or the frontmost supported app) is running.
/// The caller resolves that app and passes it as `microphoneClient`.
public struct MeetingJoinDetector {
    /// Camera frameworks can briefly disconnect while a call renegotiates.
    /// Treat a quick return as the same call so it cannot produce two prompts.
    public var reconnectGrace: TimeInterval

    private var active: [String: MeetingJoinCandidate] = [:]
    private var absentSince: [String: Date] = [:]

    public init(reconnectGrace: TimeInterval = 120) {
        self.reconnectGrace = max(0, reconnectGrace)
    }

    public mutating func update(cameraClients: [CameraClient],
                                microphoneClient: CameraClient?,
                                at now: Date = Date()) -> MeetingJoinDetection {
        var ordered: [MeetingJoinCandidate] = cameraClients.compactMap {
            MeetingClientCatalog.candidate(for: $0)
        }
        if let microphoneClient,
           let candidate = MeetingClientCatalog.candidate(for: microphoneClient),
           !ordered.contains(where: { $0.id == candidate.id }) {
            ordered.append(candidate)
        }

        // Preserve input order for the notification while using folded IDs
        // for identity. Two processes signed as the same app are one client.
        var current: [String: MeetingJoinCandidate] = [:]
        for candidate in ordered where current[candidate.id] == nil {
            current[candidate.id] = candidate
        }

        let ended = active.keys
            .filter { current[$0] == nil }
            .compactMap { active[$0]?.signingID }
            .sorted()
        for key in active.keys where current[key] == nil {
            absentSince[key] = now
        }

        var prompt: MeetingJoinCandidate?
        for candidate in ordered where active[candidate.id] == nil {
            let awayLongEnough = absentSince[candidate.id].map {
                now.timeIntervalSince($0) >= reconnectGrace
            } ?? true
            if prompt == nil, awayLongEnough {
                prompt = candidate
            }
            absentSince[candidate.id] = nil
        }

        active = current
        return MeetingJoinDetection(prompt: prompt, endedSigningIDs: ended)
    }
}
