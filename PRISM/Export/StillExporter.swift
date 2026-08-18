// StillExporter.swift
// PRISM
//
// Encodes one finished frame to PNG or HEIC (§5.16).
//
// The pixels are copied out of the pixel buffer before anything else
// happens. The frame handed here is a pool buffer the pipeline will reuse
// the moment nothing references it, and an image encoder that reads it
// lazily would be racing the next frame; a row-by-row copy of one 1080p
// frame is ~8 MB and a fraction of a millisecond, off the frame path.
//
// CGImageDestination rather than CIContext for the same reason the rest of
// the app avoids Core Image: this is a straight byte-for-byte encode of
// pixels that are already final, and nothing in it should be able to
// schedule GPU work behind PRISM's back.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum StillExporter {

    /// HEIC is lossy, so it needs a quality. High enough that a still pulled
    /// off a call survives being cropped and pasted; not 1.0, which costs
    /// most of PNG's size for none of its guarantees.
    static let heicQuality = 0.92

    public static func write(_ pixelBuffer: CVPixelBuffer,
                             format: StillFormat,
                             to url: URL) throws {
        guard let image = makeImage(from: pixelBuffer) else {
            throw CaptureError.noPicture
        }
        let type: UTType = format == .heic ? .heic : .png
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CaptureError.encodingFailed("\(format.displayName) is not available here")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: heicQuality,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            // A finalize that fails still creates the file.
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.encodingFailed("the image could not be written")
        }
    }

    /// BGRA8 pool buffer → CGImage, pixels owned by the image.
    ///
    /// Rows are copied one at a time because a pixel buffer's stride is
    /// padded to the allocator's alignment and is routinely wider than the
    /// visible frame; copying the whole allocation and telling CGImage the
    /// tight width would shear the picture.
    static func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationStride = width * 4
        var pixels = Data(count: destinationStride * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let destination = raw.baseAddress else { return }
            for row in 0..<height {
                memcpy(destination.advanced(by: row * destinationStride),
                       source.advanced(by: row * sourceStride),
                       destinationStride)
            }
        }

        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        // The pipeline's output is opaque BGRA; noneSkipFirst says so, and
        // saves every consumer from a spurious alpha channel.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: destinationStride,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
