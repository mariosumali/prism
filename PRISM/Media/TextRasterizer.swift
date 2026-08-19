// TextRasterizer.swift
// PRISM
//
// A string as a Metal texture (§5.26). Core Text lays the glyphs out, a
// CGBitmapContext draws them, and the result is uploaded once and handed to
// `prism_overlay` like any other layer — so a caption inherits placement,
// rotation, opacity, keying and behind-the-subject depth for free, and the
// compositing kernel never learns that text exists.
//
// The whole design is the cache. Laying out and drawing a paragraph costs
// milliseconds, and §3.4 budgets the entire chain in single-digit
// milliseconds — a rasterisation on the frame path would blow the budget on
// the frame it happened, which is a dropped frame in a feature that is not
// allowed to drop frames. So the pixels are redrawn only when the string,
// the style, or the size they will occupy on screen actually changes, and
// even then on a private queue: the frame queue asks for a texture, gets
// whatever is currently drawn (possibly nothing, for the first frame or two
// of a brand-new caption), and never waits. A caption that arrives one frame
// late is invisible; a frame that arrives one frame late is not.
//
// Threading mirrors LayerSource: configure() from the main thread,
// texture(frameSize:) from the frame queue only, drawing on a private serial
// queue, everything shared behind one lock.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal

final class TextRasterizer {
    /// The size `OverlayTextStyle.fontSize` is quoted at. A caption set at 48
    /// points has to be the same fraction of the picture whether the chain is
    /// running at 720p or 4K, so the point size is scaled by the frame's own
    /// height against this reference — which is the whole of "retina" on this
    /// path: there is no screen involved, only a frame with its own scale.
    static let referenceHeight: CGFloat = 1080

    /// Ceiling on the canvas, as a fraction of the frame. A wrapped paragraph
    /// wider than the picture is text nobody can read, and an unbounded
    /// canvas would let a pasted essay allocate a texture larger than the
    /// frame it is drawn into.
    static let maxWidthFraction: CGFloat = 0.94
    static let maxHeightFraction: CGFloat = 0.94

    private let metal: MetalContext
    private let drawQueue: DispatchQueue
    private let lock = NSLock()

    // lock-guarded
    private var style = OverlayTextStyle()
    /// Bumped by every configure(); a draw from an older generation throws
    /// its bitmap away rather than publishing the previous caption's pixels
    /// over the current one.
    private var generation: UInt64 = 0
    private var drawing = false
    private var texture: MTLTexture?
    /// What `texture` was drawn for. Both halves matter: the same words at a
    /// different frame height are different pixels.
    private var drawnStyle: OverlayTextStyle?
    private var drawnFrameSize: CGSize = .zero

    init(metal: MetalContext, label: String) {
        self.metal = metal
        drawQueue = DispatchQueue(label: "horse.prism.PRISM.text.\(label)",
                                  qos: .userInitiated)
    }

    /// Main-thread configuration. Cheap and idempotent: an unchanged style is
    /// dropped here, so re-applying the whole settings struct — which happens
    /// on every slider drag anywhere in the app — never touches the cache.
    func configure(_ newStyle: OverlayTextStyle) {
        lock.lock()
        guard newStyle != style else {
            lock.unlock()
            return
        }
        style = newStyle
        generation &+= 1
        lock.unlock()
    }

    /// Frame-queue entry point. Returns the currently drawn texture and, if
    /// it no longer matches what is wanted, schedules a redraw for a later
    /// frame. Never blocks and never draws on this thread.
    func texture(frameSize: CGSize) -> MTLTexture? {
        guard frameSize.width >= 1, frameSize.height >= 1 else { return nil }

        lock.lock()
        let wanted = style
        let current = texture
        let stale = drawnStyle != wanted || drawnFrameSize != frameSize
        var schedule = false
        if stale, !drawing {
            drawing = true
            schedule = true
        }
        let gen = generation
        lock.unlock()

        if schedule {
            drawQueue.async { [weak self] in
                self?.draw(style: wanted, frameSize: frameSize, generation: gen)
            }
        }
        // A stale texture is still the right thing to show: it is last
        // frame's spelling of the same caption, and blanking it while the
        // user types would make the picture flicker on every keystroke.
        return current
    }

    /// Pixel size of what is currently drawn, for aspect-correct placement.
    var contentSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        guard let texture else { return nil }
        return CGSize(width: texture.width, height: texture.height)
    }

    // MARK: - Drawing

    private func draw(style: OverlayTextStyle, frameSize: CGSize, generation gen: UInt64) {
        let rendered = Self.render(style: style, frameSize: frameSize,
                                   device: metal.device)
        lock.lock()
        drawing = false
        // Another configure() landed while the glyphs were being drawn; the
        // next texture() call schedules the run that matters, and these
        // pixels are dropped rather than published over the newer caption.
        if gen == generation {
            texture = rendered
            drawnStyle = rendered == nil ? nil : style
            drawnFrameSize = rendered == nil ? .zero : frameSize
        }
        lock.unlock()
    }

    /// Lays the text out and draws it. Pure apart from the texture
    /// allocation, and off the main thread — Core Text and CGBitmapContext
    /// are both usable from any thread, and nothing here touches AppKit's
    /// mutable state.
    static func render(style: OverlayTextStyle,
                       frameSize: CGSize,
                       device: MTLDevice) -> MTLTexture? {
        guard style.hasText else { return nil }
        // A frame with no size is a frame the caption cannot be measured
        // against; drawing it at some arbitrary fallback scale would put the
        // wrong size of text on the first frame after a format change.
        guard frameSize.width >= 1, frameSize.height >= 1 else { return nil }
        let layout = layout(style: style, frameSize: frameSize)
        guard layout.canvas.width >= 1, layout.canvas.height >= 1 else { return nil }

        let width = Int(layout.canvas.width)
        let height = Int(layout.canvas.height)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            // Premultiplied BGRA, which is the only alpha layout
            // CGBitmapContext offers; the un-premultiply below is what turns
            // it back into what the compositing kernel expects.
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            drawPlate(style: style, layout: layout, into: context)
            drawGlyphs(layout: layout, into: context)
            return true
        }
        guard drawn else { return nil }

        // `prism_overlay` mixes the layer's RGB into the base by its alpha,
        // exactly as it does for a PNG — so it wants straight alpha, and a
        // premultiplied bitmap would fade every antialiased edge to black.
        // Fully transparent pixels are given the layer's own colour rather
        // than left at zero, because the kernel samples bilinearly: a
        // transparent black neighbour would drag a dark rim around every
        // glyph on the way out.
        unpremultiply(&pixels, fringe: layout.fringe)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
        }
        return texture
    }

    // MARK: - Layout

    /// Everything the draw needs, and the one part worth testing on its own.
    struct Layout {
        var canvas: CGSize          // pixels
        var padding: CGFloat        // pixels, glyphs to plate edge
        var cornerRadius: CGFloat   // pixels
        var haloRadius: CGFloat     // pixels, for the blurred plate
        var text: NSAttributedString
        var textRect: CGRect        // where the laid-out text sits in the canvas
        var haloColor: RGBColor
        var haloAlpha: CGFloat
        /// What a fully transparent pixel is coloured, so bilinear sampling
        /// has nothing dark to bleed in from.
        var fringe: (b: UInt8, g: UInt8, r: UInt8)
    }

    static func layout(style: OverlayTextStyle, frameSize: CGSize) -> Layout {
        let scale = max(frameSize.height, 1) / referenceHeight
        let pointSize = CGFloat(style.pointSize) * scale
        // Padding is the gap between the glyphs and the plate's edge, so with
        // no plate there is nothing to be inside of. Applying it anyway would
        // bake an invisible margin into the canvas — and since placement pins
        // the canvas, a leading-aligned caption would sit at its margin
        // rather than at its first letter.
        let padding = style.plate == .solid
            ? (CGFloat(min(max(style.padding, 0), 2)) * pointSize).rounded()
            : 0
        let text = attributedString(style: style, pointSize: pointSize)

        // A halo needs room outside the glyphs even with no plate padding,
        // or the blur is clipped square by the canvas edge.
        let halo = style.plate == .blur ? (pointSize * 0.22).rounded() : 0
        let inset = padding + halo

        let maxCanvasWidth = max(16, (frameSize.width * maxWidthFraction).rounded(.down))
        let maxCanvasHeight = max(16, (frameSize.height * maxHeightFraction).rounded(.down))
        let maxTextWidth = max(8, maxCanvasWidth - inset * 2)

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var fitRange = CFRange()
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            &fitRange)
        // Core Text's suggestion rounds down often enough to clip a descender
        // or the last glyph of a line; a pixel on each axis is cheaper than
        // the bug report.
        let textSize = CGSize(width: min(maxTextWidth, measured.width.rounded(.up) + 1),
                              height: measured.height.rounded(.up) + 1)

        let canvas = CGSize(
            width: min(maxCanvasWidth, (textSize.width + inset * 2).rounded(.up)),
            height: min(maxCanvasHeight, (textSize.height + inset * 2).rounded(.up)))
        let textRect = CGRect(x: inset, y: inset,
                              width: max(1, canvas.width - inset * 2),
                              height: max(1, canvas.height - inset * 2))

        // Whatever the outermost drawn pixels are: the plate's rounded corner
        // for a slab, the halo's outer edge for a blur, the glyphs themselves
        // for neither.
        let fringeColor = style.plate == .none ? style.color : style.plateColor
        return Layout(canvas: canvas,
                      padding: padding,
                      cornerRadius: (pointSize * 0.28).rounded(),
                      haloRadius: halo,
                      text: text,
                      textRect: textRect,
                      haloColor: style.plateColor,
                      haloAlpha: CGFloat(min(max(style.plateOpacity, 0), 1)),
                      fringe: byteTriple(fringeColor))
    }

    /// Title, then subtitle at `subtitleRatio` and slightly dimmed. One
    /// attributed string rather than two draws so Core Text does the line
    /// breaking, the alignment and the vertical spacing between them.
    private static func attributedString(style: OverlayTextStyle,
                                         pointSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        switch style.alignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping

        let color = nsColor(style.color, alpha: 1)
        let result = NSMutableAttributedString()
        let title = style.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            result.append(NSAttributedString(string: title, attributes: [
                .font: font(family: style.fontFamily, size: pointSize,
                            weight: style.weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        }
        if style.hasSubtitle {
            let subtitleSize = max(8, pointSize * CGFloat(OverlayTextStyle.subtitleRatio))
            let separator = title.isEmpty ? "" : "\n"
            let subtitle = style.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(NSAttributedString(string: separator + subtitle, attributes: [
                // Always regular: the subtitle reads as secondary because it
                // is smaller and quieter, and a bold job title under a bold
                // name is two headlines.
                .font: font(family: style.fontFamily, size: subtitleSize,
                            weight: .regular),
                .foregroundColor: nsColor(style.color, alpha: 0.78),
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

    /// A named family may not exist on the machine a preset travelled to, so
    /// every failure falls through to the system font at the asked-for weight
    /// rather than failing the layer.
    private static func font(family: String, size: CGFloat,
                             weight: OverlayTextWeight) -> NSFont {
        let systemWeight: NSFont.Weight
        switch weight {
        case .regular: systemWeight = .regular
        case .medium: systemWeight = .medium
        case .bold: systemWeight = .bold
        }
        guard !family.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .systemFont(ofSize: size, weight: systemWeight)
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: systemWeight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size)
            ?? NSFont(name: family, size: size)
            ?? .systemFont(ofSize: size, weight: systemWeight)
    }

    // MARK: - Drawing primitives

    private static func drawPlate(style: OverlayTextStyle, layout: Layout,
                                  into context: CGContext) {
        guard style.plate == .solid else { return }
        let opacity = CGFloat(min(max(style.plateOpacity, 0), 1))
        guard opacity > 0 else { return }
        let rect = CGRect(origin: .zero, size: layout.canvas)
            .insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect,
                          cornerWidth: min(layout.cornerRadius, rect.width / 2),
                          cornerHeight: min(layout.cornerRadius, rect.height / 2),
                          transform: nil)
        context.setFillColor(cgColor(style.plateColor, alpha: opacity))
        context.addPath(path)
        context.fillPath()
    }

    private static func drawGlyphs(layout: Layout, into context: CGContext) {
        context.saveGState()
        if layout.haloRadius > 0, layout.haloAlpha > 0 {
            // CGContext's shadow is a real Gaussian, centred on the glyphs
            // rather than offset, which is what makes it read as the text
            // sitting on its own soft plate instead of casting a shadow.
            context.setShadow(offset: .zero, blur: layout.haloRadius * 2,
                              color: cgColor(layout.haloColor,
                                             alpha: layout.haloAlpha))
        }
        let path = CGPath(rect: layout.textRect, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(layout.text)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Straight alpha, with transparent pixels coloured rather than cleared.
    private static func unpremultiply(_ pixels: inout [UInt8],
                                      fringe: (b: UInt8, g: UInt8, r: UInt8)) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            var index = 0
            while index + 3 < buffer.count {
                let alpha = buffer[index + 3]
                if alpha == 0 {
                    buffer[index] = fringe.b
                    buffer[index + 1] = fringe.g
                    buffer[index + 2] = fringe.r
                } else if alpha < 255 {
                    let a = Int(alpha)
                    for channel in 0..<3 {
                        buffer[index + channel] =
                            UInt8(min(255, Int(buffer[index + channel]) * 255 / a))
                    }
                }
                index += 4
            }
        }
    }

    // MARK: - Colour helpers

    private static func byteTriple(_ color: RGBColor) -> (b: UInt8, g: UInt8, r: UInt8) {
        func byte(_ value: Double) -> UInt8 {
            UInt8(min(255, max(0, (value * 255).rounded())))
        }
        return (byte(color.blue), byte(color.green), byte(color.red))
    }

    private static func cgColor(_ color: RGBColor, alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                blue: CGFloat(color.blue), alpha: alpha)
    }

    private static func nsColor(_ color: RGBColor, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                blue: CGFloat(color.blue), alpha: alpha)
    }
}
