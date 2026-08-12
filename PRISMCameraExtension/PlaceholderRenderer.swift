// PlaceholderRenderer.swift
// PRISMCameraExtension — renders the "PRISM is not running" card (SPEC §3.2)
// with CoreGraphics/CoreText into an IOSurface-backed CVPixelBuffer pool at
// the active format's size. The card is a neutral dark background with the
// PRISM wordmark centered and a 32 pt caption at 60% opacity below it.
// Never a black frame: the buffer is pattern-filled with the background
// color before any drawing, so even a text-rendering failure produces the
// dark card rather than black.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

final class PlaceholderRenderer {

    /// Default published format set. Must exactly mirror
    /// `VideoFormat.defaultSet` in PRISMShared/PixelFormats.swift — the
    /// extension cannot link app sources, so this is a hand-kept copy that
    /// FormatManager asserts against on the app side.
    static let defaultFormats: [ExtFormat] = [
        ExtFormat(width: 3840, height: 2160, frameRate: 30),
        ExtFormat(width: 1920, height: 1080, frameRate: 24),
        ExtFormat(width: 1920, height: 1080, frameRate: 30),
        ExtFormat(width: 1920, height: 1080, frameRate: 60),
        ExtFormat(width: 1280, height: 720, frameRate: 24),
        ExtFormat(width: 1280, height: 720, frameRate: 30),
        ExtFormat(width: 1280, height: 720, frameRate: 60),
        ExtFormat(width: 960, height: 540, frameRate: 30),
        ExtFormat(width: 640, height: 480, frameRate: 30),
    ]

    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let formatDescription: CMVideoFormatDescription
    }

    private let lock = NSLock()
    private var width: Int
    private var height: Int
    private var pool: CVPixelBufferPool?
    private var cached: Frame?

    init(width: Int, height: Int) {
        self.width = max(2, width)
        self.height = max(2, height)
    }

    /// Track the active format; drops the pool and cached card on change.
    func setSize(width: Int, height: Int) {
        let newWidth = max(2, width)
        let newHeight = max(2, height)
        lock.lock()
        defer { lock.unlock() }
        guard newWidth != self.width || newHeight != self.height else { return }
        self.width = newWidth
        self.height = newHeight
        pool = nil
        cached = nil
    }

    /// The card at the current size. The content is static per size, so the
    /// rendered buffer is cached and reused for every 1 fps emission.
    func makeFrame() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        guard let buffer = allocateBuffer() else { return nil }
        renderCard(into: buffer)

        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: buffer,
                                                     formatDescriptionOut: &description)
        guard let description else { return nil }
        let frame = Frame(pixelBuffer: buffer, formatDescription: description)
        cached = frame
        return frame
    }

    // MARK: - Buffer allocation

    private static func bufferAttributes(width: Int, height: Int) -> CFDictionary {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary
    }

    private func ensurePool() {
        guard pool == nil else { return }
        let poolAttributes = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 2,
        ] as CFDictionary
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                poolAttributes,
                                Self.bufferAttributes(width: width, height: height),
                                &newPool)
        pool = newPool
    }

    private func allocateBuffer() -> CVPixelBuffer? {
        ensurePool()
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        if buffer == nil {
            // Pool failed — fall back to a one-off allocation rather than
            // emitting nothing.
            CVPixelBufferCreate(kCFAllocatorDefault,
                                width,
                                height,
                                kCVPixelFormatType_32BGRA,
                                Self.bufferAttributes(width: width, height: height),
                                &buffer)
        }
        return buffer
    }

    // MARK: - Drawing

    private func renderCard(into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // Neutral dark gray #1E1E1E, opaque. BGRA in memory, so the 32-bit
        // little-endian pattern is A(FF) R(1E) G(1E) B(1E).
        var background: UInt32 = 0xFF1E1E1E
        memset_pattern4(base, &background, bytesPerRow * height)

        guard let context = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)
                                          ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            // Background is already correct; the card is just textless.
            return
        }
        drawCard(in: context)
        context.flush()
    }

    private func drawCard(in context: CGContext) {
        let cardWidth = CGFloat(width)
        let cardHeight = CGFloat(height)

        // Wordmark: bold system font, sized to the card, wide tracking.
        let wordmarkSize = max(48, cardHeight * 0.12)
        let wordmarkKern = wordmarkSize * 0.12
        let wordmarkLine = Self.makeLine(text: "PRISM",
                                         font: Self.uiFont(.emphasizedSystem, size: wordmarkSize),
                                         color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                         kern: wordmarkKern)

        // Caption: 32 pt system font at 60% opacity (SPEC §3.2).
        let captionLine = Self.makeLine(text: "PRISM is not running",
                                        font: Self.uiFont(.system, size: 32),
                                        color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6),
                                        kern: 0)

        var wordmarkAscent: CGFloat = 0
        var wordmarkDescent: CGFloat = 0
        var wordmarkLeading: CGFloat = 0
        let wordmarkWidth = CGFloat(CTLineGetTypographicBounds(wordmarkLine,
                                                               &wordmarkAscent,
                                                               &wordmarkDescent,
                                                               &wordmarkLeading))
        var captionAscent: CGFloat = 0
        var captionDescent: CGFloat = 0
        var captionLeading: CGFloat = 0
        let captionWidth = CGFloat(CTLineGetTypographicBounds(captionLine,
                                                              &captionAscent,
                                                              &captionDescent,
                                                              &captionLeading))

        // Center the wordmark + caption block vertically (CG origin is
        // bottom-left). The wordmark's measured width includes its trailing
        // kern, which is subtracted so the glyphs themselves are centered.
        let gap = max(16, cardHeight * 0.03)
        let blockHeight = wordmarkAscent + wordmarkDescent + gap + captionAscent + captionDescent
        let blockTop = (cardHeight + blockHeight) / 2
        let wordmarkBaseline = blockTop - wordmarkAscent
        let captionBaseline = wordmarkBaseline - wordmarkDescent - gap - captionAscent

        context.textPosition = CGPoint(x: (cardWidth - (wordmarkWidth - wordmarkKern)) / 2,
                                       y: wordmarkBaseline)
        CTLineDraw(wordmarkLine, context)

        context.textPosition = CGPoint(x: (cardWidth - captionWidth) / 2,
                                       y: captionBaseline)
        CTLineDraw(captionLine, context)
    }

    // MARK: - CoreText helpers

    private static func uiFont(_ type: CTFontUIFontType, size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(type, size, nil)
            ?? CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }

    private static func makeLine(text: String, font: CTFont, color: CGColor, kern: CGFloat) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if kern != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] =
                NSNumber(value: Double(kern))
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }
}
