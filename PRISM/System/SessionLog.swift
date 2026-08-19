// SessionLog.swift
// PRISM
//
// An in-memory record of what happened this session (§5.21): auto-disables,
// device changes, dropped frames, the moments that changed what clients
// could see. PRISM already computes every one of these and then throws them
// away, so "why did my effects turn off?" has no answer ten minutes later —
// by which time the warning row has long since been replaced.
//
// Strictly local and strictly ephemeral: a bounded array in this process,
// never written to disk unless the user exports it, never sent anywhere.
// Quitting PRISM is how you delete it.
//
// And strictly unrevealing, because "unless the user exports it" is the
// whole risk: an exported log is a plain-text file that gets attached to a
// support thread. Rows may name devices and applications — what the pickers
// already show — and may not name the *contents* of anything. A shared
// window's title is a document name; callers redact it before it gets here
// (`ScreenSourceInfo.logName`).
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public struct SessionEvent: Identifiable, Equatable {
    public enum Kind: String, CaseIterable {
        case degradation      // §3.4 auto-disable / re-enable / budget pressure
        case device           // camera or microphone arrived, left, or fell over
        case drops            // frames the sink could not hand off
        case onAir            // what clients could see changed
        case format           // published set or active format changed
        case clients          // an app started or stopped using PRISM

        public var displayName: String {
            switch self {
            case .degradation: return "Effects"
            case .device: return "Devices"
            case .drops: return "Dropped frames"
            case .onAir: return "On air"
            case .format: return "Format"
            case .clients: return "Apps"
            }
        }

        public var symbolName: String {
            switch self {
            case .degradation: return "wand.and.stars"
            case .device: return "camera"
            case .drops: return "exclamationmark.triangle"
            case .onAir: return "dot.radiowaves.left.and.right"
            case .format: return "rectangle.on.rectangle"
            case .clients: return "app.connected.to.app.below.fill"
            }
        }
    }

    public let id = UUID()
    public let kind: Kind
    /// Mutable so a run of drops can restate its own total in place rather
    /// than filing a row four times a second.
    public internal(set) var text: String
    public let first: Date
    /// Repeats collapse into the one row rather than pushing history off the
    /// end: a camera that reconnects forty times is one story, not forty.
    public internal(set) var last: Date
    public internal(set) var count: Int

    public init(kind: Kind, text: String, at date: Date = Date()) {
        self.kind = kind
        self.text = text
        self.first = date
        self.last = date
        self.count = 1
    }
}

@MainActor
public final class SessionLog: ObservableObject {

    /// Bounded so a machine left running for a week cannot grow it without
    /// limit. Oldest first; the tail is what a user actually reads.
    public static let capacity = 300

    @Published public private(set) var events: [SessionEvent] = []
    /// Worst total added latency seen this session, and the worst each stage
    /// reached. The live meter answers "what is it costing me now"; this
    /// answers "what was it costing me when it gave up".
    @Published public private(set) var peakAddedMs: Double = 0
    @Published public private(set) var peakStageMs: [StageID: Double] = [:]
    @Published public private(set) var droppedFrames = 0
    public let startedAt = Date()

    /// Frames counted into the drop row currently at the tail.
    private var runDrops = 0

    public init() {}

    public func record(_ kind: SessionEvent.Kind, _ text: String,
                       at date: Date = Date()) {
        if var last = events.last, last.kind == kind, last.text == text {
            last.count += 1
            last.last = date
            events[events.count - 1] = last
            return
        }
        events.append(SessionEvent(kind: kind, text: text, at: date))
        trim()
    }

    private func trim() {
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
    }

    /// Fed from the latency monitor's 4 Hz publish. Peaks only — keeping the
    /// samples themselves would be a time-series database nobody asked for.
    public func observe(_ report: LatencyReport, at date: Date = Date()) {
        if report.totalAddedMs > peakAddedMs { peakAddedMs = report.totalAddedMs }
        for (id, ms) in report.stages where ms > (peakStageMs[id] ?? 0) {
            peakStageMs[id] = ms
        }
        if report.droppedFrames > droppedFrames {
            let delta = report.droppedFrames - droppedFrames
            droppedFrames = report.droppedFrames
            recordDrops(delta, at: date)
        }
    }

    /// Drops arrive with every report while a chain is struggling, and a row
    /// per report would push the auto-disable that explains them off a
    /// bounded list inside a minute. A run accumulates into one row instead,
    /// and any other event ends the run — so the history stays in order.
    private func recordDrops(_ delta: Int, at date: Date) {
        if var last = events.last, last.kind == .drops {
            runDrops += delta
            last.text = Self.dropText(runDrops)
            last.last = date
            last.count += 1
            events[events.count - 1] = last
            return
        }
        runDrops = delta
        events.append(SessionEvent(kind: .drops, text: Self.dropText(delta), at: date))
        trim()
    }

    private static func dropText(_ count: Int) -> String {
        "\(count) frame\(count == 1 ? "" : "s") dropped"
    }

    public func clear() {
        events.removeAll()
        peakAddedMs = 0
        peakStageMs = [:]
        runDrops = 0
        // droppedFrames is a running total from the sink, not a count of what
        // is in the list: resetting it would make the next observe() report
        // every drop since launch as if it had just happened.
    }

    /// Plain text, produced only when the user picks Export.
    ///
    /// Nothing here identifies a machine or a person beyond the names of the
    /// devices and applications the user already sees in the pickers — and
    /// specifically not the title of a window they shared, which is a
    /// document name or a browser tab and is the one thing in this app's
    /// reach that would genuinely embarrass someone who attached the file to
    /// a support thread. Callers name a window by its application
    /// (`ScreenSourceInfo.logName`); the title never gets this far.
    public func exportText(now: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        var lines = [
            "PRISM session log",
            "Session started \(ISO8601DateFormatter().string(from: startedAt))",
            "Duration \(Self.duration(from: startedAt, to: now))",
            "Dropped frames \(droppedFrames)",
            String(format: "Peak added latency %.1f ms", peakAddedMs),
            "",
        ]
        for event in events {
            let repeats = event.count > 1 ? " (×\(event.count))" : ""
            lines.append("\(stamp.string(from: event.first))  "
                + "[\(event.kind.rawValue)] \(event.text)\(repeats)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds) s"
    }
}
