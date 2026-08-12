// FormatManager.swift
// PRISM
//
// Published/active format state (§3.2): keeps the advertised format set, the
// negotiated active format, and the physical-capture-format selection rule.
// Pushing a new set to the extension is a reconnect boundary — the caller
// shows the confirmation first; this class only encodes and writes 'pfmt'.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import Combine
import CoreMedia
import Foundation
import os

@MainActor
public final class FormatManager: ObservableObject {
    private static let log = Logger(subsystem: "horse.prism.PRISM", category: "FormatManager")
    private static let publishedKey = "PRISM.publishedFormats"
    private static let activeKey = "PRISM.activeFormat"

    @Published public private(set) var publishedFormats: [VideoFormat]
    @Published public var activeFormat: VideoFormat

    private let defaults: UserDefaults

    /// Loads the persisted set (or `VideoFormat.defaultSet`) and the persisted
    /// active format.
    public convenience init() {
        self.init(defaults: .standard)
    }

    /// Internal seam so tests can run against an isolated UserDefaults suite;
    /// the public initializer uses `.standard` (identical behavior).
    init(defaults: UserDefaults) {
        self.defaults = defaults
        var published: [VideoFormat]
        if let data = defaults.data(forKey: Self.publishedKey),
           let decoded = try? JSONDecoder().decode([VideoFormat].self, from: data),
           !decoded.isEmpty {
            published = decoded.sorted()
        } else {
            published = VideoFormat.defaultSet
        }
        var active: VideoFormat
        if let data = defaults.data(forKey: Self.activeKey),
           let decoded = try? JSONDecoder().decode(VideoFormat.self, from: data) {
            active = decoded
        } else {
            active = VideoFormat(width: 1920, height: 1080, frameRate: 30)
        }
        if !published.contains(active) {
            active = Self.preferredActive(in: published)
        }
        self.publishedFormats = published
        self.activeFormat = active
    }

    /// §3.2 — the physical capture format is the smallest native format
    /// greater than or equal to the negotiated output in both dimensions
    /// (smallest by area, to avoid upscaling). If none is large enough,
    /// returns the largest available (Geometry upscales with Lanczos).
    /// Among equal-area candidates, one that natively supports the output
    /// frame rate is preferred (deterministic tie-break).
    nonisolated public static func physicalFormat(for device: AVCaptureDevice,
                                                  output: VideoFormat) -> AVCaptureDevice.Format? {
        let formats = device.formats
        let rate = Double(output.frameRate)
        let candidates = formats.map { format -> (width: Int, height: Int, supportsRate: Bool) in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supports = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= rate && rate <= $0.maxFrameRate
            }
            return (Int(d.width), Int(d.height), supports)
        }
        guard let index = selectPhysicalFormatIndex(candidates: candidates, output: output) else {
            return nil
        }
        return formats[index]
    }

    /// Pure core of the §3.2 selection rule, extracted so it is testable
    /// without an AVCaptureDevice. Returns the index of the chosen candidate,
    /// or nil when `candidates` is empty. Fitting = at least the output size
    /// in both dimensions; among fitting candidates the smallest area wins,
    /// equal areas prefer native output-rate support, remaining ties keep the
    /// earliest candidate. No fitting candidate → largest area (earliest on
    /// area ties).
    nonisolated static func selectPhysicalFormatIndex(
        candidates: [(width: Int, height: Int, supportsRate: Bool)],
        output: VideoFormat) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let indexed = Array(candidates.enumerated())
        let fitting = indexed.filter {
            $0.element.width >= output.width && $0.element.height >= output.height
        }
        if !fitting.isEmpty {
            return fitting.min { a, b in
                let areaA = a.element.width * a.element.height
                let areaB = b.element.width * b.element.height
                if areaA != areaB { return areaA < areaB }
                if a.element.supportsRate != b.element.supportsRate {
                    return a.element.supportsRate
                }
                return false
            }?.offset
        }
        return indexed.max { a, b in
            a.element.width * a.element.height < b.element.width * b.element.height
        }?.offset
    }

    /// Pushes the set to the extension via 'pfmt'. The caller has already
    /// shown the reconnect confirmation when clients are streaming (§3.2).
    /// Returns whether the write reached the extension; on failure (e.g. the
    /// extension is not yet approved/connected) the caller is responsible for
    /// re-publishing once the sink connects.
    @discardableResult
    public func publish(_ formats: [VideoFormat], via sink: CMIOSink) -> Bool {
        let cleaned = Array(Set(formats)).sorted()
        guard !cleaned.isEmpty else { return false }
        guard let json = try? JSONEncoder().encode(cleaned) else { return false }

        let wrote = sink.writeFormatList(json)
        // §3.2: the extension republishes BOTH streams from one 'pfmt' write,
        // so sink and source format sets stay identical by construction. A
        // write that fails while the sink IS connected means the app's view
        // of the published set and the extension's have diverged. This was a
        // debug assert, but pollTick retries publishes at 1 Hz — an assert
        // here turns one bad write into a launch crash loop (it did). Log
        // loudly and let the retry converge instead. A failed write to an
        // absent device (extension not yet approved, §9) is an expected
        // offline condition, not a divergence.
        if !wrote && sink.isConnected {
            Self.log.error("'pfmt' write failed against a connected sink — format sets may diverge; pollTick will retry")
        }

        if wrote {
            // The extension tears down and recreates both streams on a format
            // change, orphaning the queue the sink copied. Re-resolve so
            // pushed frames reach the fresh sink stream (§3.2, M4.5).
            sink.reconnect()
        }

        publishedFormats = cleaned
        if !cleaned.contains(activeFormat) {
            activeFormat = Self.preferredActive(in: cleaned)
        }
        persist()
        return wrote
    }

    public func persist() {
        if let data = try? JSONEncoder().encode(publishedFormats) {
            defaults.set(data, forKey: Self.publishedKey)
        }
        if let data = try? JSONEncoder().encode(activeFormat) {
            defaults.set(data, forKey: Self.activeKey)
        }
    }

    // MARK: Private

    /// 1080p30 when available, else the first (largest) published entry.
    nonisolated private static func preferredActive(in formats: [VideoFormat]) -> VideoFormat {
        formats.first { $0.width == 1920 && $0.height == 1080 && $0.frameRate == 30 }
            ?? formats.first
            ?? VideoFormat(width: 1920, height: 1080, frameRate: 30)
    }
}
