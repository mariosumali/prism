#!/usr/bin/env swift
//
// make_icon.swift — regenerates PRISM/Resources/Assets.xcassets/AppIcon.appiconset.
//
// The icon is drawn, not painted: a white beam enters the left face of a glass
// triangle, refracts, and leaves the right face as a six-band spectrum. Keeping
// it as code means every size is rendered from the same geometry and the whole
// set can be regenerated after a tweak with:
//
//     swift Tools/make_icon.swift
//
// Geometry is expressed in "body space" — a unit square over the rounded icon
// body (824/1024 of the canvas, per the macOS icon grid), y pointing down.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Geometry (body space, unit square, y down)

/// Glass triangle, apex up. Nudged above centre so the centroid lands on the
/// optical middle rather than the geometric one.
let apex = CGPoint(x: 0.500, y: 0.166)
let baseLeft = CGPoint(x: 0.180, y: 0.720)
let baseRight = CGPoint(x: 0.820, y: 0.720)

/// Where the incident beam strikes the left face, and where the refracted beam
/// leaves the right face. Both are points on the faces themselves, and the
/// segment between them runs at 22° — the centre line of the fan below.
let hitIn = CGPoint(x: 0.3648, y: 0.400)
let hitOut = CGPoint(x: 0.7175, y: 0.5425)

/// Spectrum fan, in degrees below horizontal, straddling that 22° centre line.
/// Red deviates least, violet most, so the bands run red at the top to violet
/// at the bottom. Keeping the fan symmetric about the beam is what lets the
/// wedges emerge cleanly from under it (see `setback`).
let fanStart = 7.0
let fanEnd = 37.0

let spectrum: [(CGFloat, CGFloat, CGFloat)] = [
    (1.000, 0.231, 0.188),  // red
    (1.000, 0.584, 0.000),  // orange
    (1.000, 0.839, 0.039),  // yellow
    (0.188, 0.820, 0.345),  // green
    (0.039, 0.518, 1.000),  // blue
    (0.749, 0.353, 0.949),  // violet
]

// MARK: - Drawing

let srgb = CGColorSpaceCreateDeviceRGB()

func gray(_ w: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: srgb, components: [w, w, w, a])!
}

func rgb(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [c.0, c.1, c.2, a])!
}

/// Superellipse standing in for the macOS squircle. Circular corners read as
/// visibly rounder than neighbouring icons in the Dock.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func renderIcon(pixels n: Int) -> CGImage {
    let N = CGFloat(n)
    let body = N * 824 / 1024
    let margin = (N - body) / 2
    let bodyRect = CGRect(x: margin, y: margin, width: body, height: body)

    // Body space -> device space.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: margin + x * body, y: margin + y * body)
    }
    func p(_ pt: CGPoint) -> CGPoint { p(pt.x, pt.y) }

    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // Flip so body space matches the geometry above (y down from the top).
    ctx.translateBy(x: 0, y: N)
    ctx.scaleBy(x: 1, y: -1)

    let shape = squircle(in: bodyRect)

    // Drop shadow, cast by filling the body shape opaque before it is clipped.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: N * 0.008),
                  blur: N * 0.014, color: gray(0, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(gray(0.06, 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Backplate: cool graphite, darkest at the bottom so the spectrum carries.
    let bg = CGGradient(colorsSpace: srgb, colors: [
        CGColor(colorSpace: srgb, components: [0.137, 0.141, 0.184, 1])!,
        CGColor(colorSpace: srgb, components: [0.047, 0.051, 0.078, 1])!,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: p(0.5, 0), end: p(0.5, 1), options: [])

    // Light bloom at the exit face.
    let glow = CGGradient(colorsSpace: srgb,
                          colors: [gray(1, 0.13), gray(1, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: p(hitOut), startRadius: 0,
                           endCenter: p(hitOut), endRadius: body * 0.40, options: [])

    // Spectrum fan. Its apex sits back along the refracted ray so the bands are
    // exactly beam-width where they leave the glass; the overshoot hides under
    // the beam, which is stroked last.
    let dx = hitOut.x - hitIn.x, dy = hitOut.y - hitIn.y
    let len = sqrt(dx * dx + dy * dy)
    let beamW: CGFloat = max(body * 0.032, N >= 128 ? 0 : 1.25)
    let setback = (beamW / body / 2) / tan(CGFloat(fanEnd - fanStart) / 2 * .pi / 180)
    let fanApex = CGPoint(x: hitOut.x - dx / len * setback, y: hitOut.y - dy / len * setback)

    let band = (fanEnd - fanStart) / Double(spectrum.count)
    for (i, colour) in spectrum.enumerated() {
        // A hair of overlap keeps seams from showing between adjacent bands.
        let a0 = (fanStart + band * Double(i) - 0.4) * .pi / 180
        let a1 = (fanStart + band * Double(i + 1) + 0.4) * .pi / 180
        let r: CGFloat = 1.8
        let wedge = CGMutablePath()
        wedge.move(to: p(fanApex))
        wedge.addLine(to: p(fanApex.x + r * cos(CGFloat(a0)), fanApex.y + r * sin(CGFloat(a0))))
        wedge.addLine(to: p(fanApex.x + r * cos(CGFloat(a1)), fanApex.y + r * sin(CGFloat(a1))))
        wedge.closeSubpath()
        ctx.addPath(wedge)
        ctx.setFillColor(rgb(colour))
        ctx.fillPath()
    }

    // Glass triangle.
    let tri = CGMutablePath()
    tri.move(to: p(apex))
    tri.addLine(to: p(baseRight))
    tri.addLine(to: p(baseLeft))
    tri.closeSubpath()

    ctx.saveGState()
    ctx.addPath(tri)
    ctx.clip()
    // Below 64px the outline alone survives resampling as grey mush, so the
    // glass is filled harder to keep the triangle a distinct shape.
    let lift: CGFloat = N < 64 ? 0.13 : 0
    let glass = CGGradient(colorsSpace: srgb,
                           colors: [gray(1, 0.19 + lift), gray(1, 0.06 + lift)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(glass, start: p(0.5, apex.y), end: p(0.5, baseLeft.y), options: [])
    ctx.restoreGState()

    ctx.addPath(tri)
    ctx.setStrokeColor(gray(1, 0.92))
    ctx.setLineWidth(max(body * 0.026, N >= 128 ? 0 : 1.15))
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Incident beam, then the refracted path through the glass, as one stroke.
    ctx.move(to: p(-0.06, hitIn.y))
    ctx.addLine(to: p(hitIn))
    ctx.addLine(to: p(hitOut))
    ctx.setStrokeColor(gray(1, 1))
    ctx.setLineWidth(beamW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Glassy rim on the body itself.
    ctx.addPath(squircle(in: bodyRect.insetBy(dx: N * 0.003, dy: N * 0.003)))
    ctx.setStrokeColor(gray(1, 0.10))
    ctx.setLineWidth(max(N * 0.005, 0.75))
    ctx.strokePath()

    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - Output

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
               : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("PRISM/Resources/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: iconset.path) else {
    FileHandle.standardError.write(Data("no appiconset at \(iconset.path)\n".utf8))
    exit(1)
}

/// (point size, scale) -> file name, per the Xcode asset catalogue convention.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                              (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

var cache: [Int: CGImage] = [:]
var entries: [String] = []

for (size, scale) in variants {
    let pixels = size * scale
    let image = cache[pixels] ?? renderIcon(pixels: pixels)
    cache[pixels] = image

    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    let url = iconset.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("cannot write \(name)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("cannot encode \(name)\n".utf8))
        exit(1)
    }
    print("wrote \(name) (\(pixels)px)")

    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(size)x\(size)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
