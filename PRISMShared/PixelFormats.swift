// PixelFormats.swift
// PRISMShared
//
// Video format vocabulary shared by the app's pipeline, FormatManager, and
// the CMIO sink client. The camera extension has its own copy of the default
// set (it cannot link app code); FormatManager asserts the two stay equal.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreVideo
import Foundation

/// The one pixel format PRISM speaks end-to-end.
public let prismPixelFormat: OSType = kCVPixelFormatType_32BGRA

/// One advertised camera format: fixed dimensions at one frame rate.
public struct VideoFormat: Hashable, Codable, Identifiable, Comparable {
    public var width: Int
    public var height: Int
    public var frameRate: Int

    public init(width: Int, height: Int, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    public var id: String { "\(width)x\(height)@\(frameRate)" }

    public var frameIntervalMs: Double { 1000.0 / Double(frameRate) }

    public var dimensions: CMVideoDimensions {
        CMVideoDimensions(width: Int32(width), height: Int32(height))
    }

    /// "1080p", "720p", "4K" style label for the status line.
    public var resolutionLabel: String {
        switch (width, height) {
        case (3840, 2160): return "4K"
        case (1920, 1080): return "1080p"
        case (1280, 720):  return "720p"
        case (960, 540):   return "540p"
        case (640, 480):   return "480p"
        default:           return "\(width)×\(height)"
        }
    }

    public var displayName: String { "\(width)×\(height) · \(frameRate) fps" }

    /// Sorted largest-first, then highest-rate-first — the order the
    /// extension publishes and pickers display.
    public static func < (lhs: VideoFormat, rhs: VideoFormat) -> Bool {
        if lhs.width != rhs.width { return lhs.width > rhs.width }
        if lhs.height != rhs.height { return lhs.height > rhs.height }
        return lhs.frameRate > rhs.frameRate
    }

    /// The default published set, §3.2. Must match
    /// `PlaceholderRenderer.defaultFormats` in the camera extension.
    public static let defaultSet: [VideoFormat] = [
        VideoFormat(width: 3840, height: 2160, frameRate: 30),
        VideoFormat(width: 1920, height: 1080, frameRate: 24),
        VideoFormat(width: 1920, height: 1080, frameRate: 30),
        VideoFormat(width: 1920, height: 1080, frameRate: 60),
        VideoFormat(width: 1280, height: 720, frameRate: 24),
        VideoFormat(width: 1280, height: 720, frameRate: 30),
        VideoFormat(width: 1280, height: 720, frameRate: 60),
        VideoFormat(width: 960, height: 540, frameRate: 30),
        VideoFormat(width: 640, height: 480, frameRate: 30),
    ]
}

public func makeFormatDescription(for format: VideoFormat) -> CMFormatDescription? {
    var desc: CMFormatDescription?
    CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: prismPixelFormat,
        width: Int32(format.width),
        height: Int32(format.height),
        extensions: nil,
        formatDescriptionOut: &desc)
    return desc
}

/// Metal-compatible, IOSurface-backed pool attributes (§3.3).
public func prismPixelBufferAttributes(width: Int, height: Int) -> [String: Any] {
    [
        kCVPixelBufferPixelFormatTypeKey as String: prismPixelFormat,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
}
