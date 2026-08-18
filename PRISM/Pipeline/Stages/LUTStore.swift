// LUTStore.swift
// PRISM
//
// .cube LUT catalog and parser (§5.4). Loads the bundled defaults from the
// app bundle's "LUTs" subdirectory and user imports from Application
// Support/PRISM/LUTs, parses TITLE / LUT_3D_SIZE / DOMAIN_MIN / DOMAIN_MAX
// plus N³ float triples (tolerant of comments and blank lines), and builds
// rgba16Float 3D textures for trilinear sampling. "Neutral" is synthesized
// as a 33³ identity when no file provides it. Lookup is case-insensitive.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal
import simd

public enum LUTError: LocalizedError {
    case unreadable
    case unsupported(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The LUT file could not be read."
        case .unsupported(let detail):
            return "Unsupported LUT: \(detail)."
        case .malformed(let detail):
            return "Malformed .cube file: \(detail)."
        }
    }
}

public final class LUTStore {
    public static let shared = LUTStore()

    private static let builtInOrder = ["Neutral", "Warm", "Cool", "Film", "Mono"]

    private let lock = NSLock()
    /// Parsed textures keyed by lowercased LUT name. Textures are immutable
    /// once built, so caching across stages/devices-of-one is safe.
    private var textureCache: [String: MTLTexture] = [:]

    init() {}

    // MARK: - Catalog

    /// Bundled defaults first (in shipping order), then everything else
    /// alphabetically. "Neutral" is always present (synthesized if missing).
    public var availableLUTs: [String] {
        let catalog = lutCatalog()
        var names: [String] = []
        var seen = Set<String>()
        for builtIn in Self.builtInOrder {
            let key = builtIn.lowercased()
            if key == "neutral" || catalog[key] != nil {
                names.append(builtIn)
                seen.insert(key)
            }
        }
        let others = catalog
            .filter { !seen.contains($0.key) }
            .map { $0.value.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return names + others
    }

    /// The first look in the catalog that is not the identity — what turning
    /// the LUT stage on should select when the current pick is Neutral, so
    /// the switch shows a change instead of nothing. nil only when no .cube
    /// beyond the synthesized Neutral is installed.
    public var firstNonNeutralLUT: String? {
        availableLUTs.first { !LUTSettings.isNeutral($0) }
    }

    /// Case-insensitive lookup; parses and caches the .cube on first use.
    public func texture(named: String, device: MTLDevice) -> MTLTexture? {
        let key = named.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if let cached = textureCache[key] { return cached }

        let lut: CubeLUT
        if let url = lutCatalog()[key], let parsed = try? Self.parseCube(at: url) {
            lut = parsed
        } else if key == "neutral" {
            lut = Self.identityLUT(size: 33)   // §5.4: synthesized identity
        } else {
            return nil
        }
        guard let texture = Self.makeTexture(from: lut, device: device) else {
            return nil
        }
        textureCache[key] = texture
        return texture
    }

    /// Validates by parsing first, then copies the file into Application
    /// Support/PRISM/LUTs. Returns the LUT name (file name without extension).
    @discardableResult
    public func importLUT(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        _ = try Self.parseCube(at: url)        // reject broken files up front

        let directory = importDirectory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)

        let name = url.deletingPathExtension().lastPathComponent
        lock.lock()
        textureCache.removeValue(forKey: name.lowercased())
        lock.unlock()
        return name
    }

    // MARK: - Locations

    /// Internal seam so tests can import into a temporary directory; nil
    /// (always, in the app) means the real Application Support location.
    var importDirectoryOverride: URL?

    private var importDirectory: URL {
        importDirectoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
            .appendingPathComponent("PRISM/LUTs", isDirectory: true)
    }

    /// Lowercased name → URL. Bundled LUTs win over imported ones of the
    /// same name so the shipped defaults cannot be shadowed.
    private func lutCatalog() -> [String: URL] {
        var map: [String: URL] = [:]
        let imported = (try? FileManager.default.contentsOfDirectory(
            at: importDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in imported where url.pathExtension.lowercased() == "cube" {
            map[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }
        // Xcode's Resources build phase copies individually-listed files flat
        // into Contents/Resources, so the shipped .cube files may sit at the
        // bundle root rather than in a LUTs/ subdirectory. Search both so the
        // §5.4 bundled defaults load under either packaging layout.
        var bundled = Bundle.main.urls(forResourcesWithExtension: "cube",
                                       subdirectory: "LUTs") ?? []
        if bundled.isEmpty {
            bundled = Bundle.main.urls(forResourcesWithExtension: "cube",
                                       subdirectory: nil) ?? []
        }
        for url in bundled {
            map[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }
        return map
    }

    // MARK: - .cube parsing

    struct CubeLUT {
        var size: Int
        var title: String?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        /// r,g,b triples, red varying fastest (standard .cube ordering).
        var values: [Float]
    }

    static func parseCube(at url: URL) throws -> CubeLUT {
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            throw LUTError.unreadable
        }

        var size = 0
        var title: String?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") {
                title = String(line.dropFirst("TITLE".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") {
                throw LUTError.unsupported("1D LUTs")
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let fields = splitFields(line)
                guard fields.count >= 2, let n = Int(fields[1]),
                      (2...128).contains(n) else {
                    throw LUTError.malformed("invalid LUT_3D_SIZE")
                }
                size = n
                values.reserveCapacity(n * n * n * 3)
                continue
            }
            if upper.hasPrefix("DOMAIN_MIN") {
                domainMin = try parseTriple(line, skippingFirst: true)
                continue
            }
            if upper.hasPrefix("DOMAIN_MAX") {
                domainMax = try parseTriple(line, skippingFirst: true)
                continue
            }
            // Tolerate unknown keyword lines (LUT_IN_VIDEO_RANGE etc.):
            // data lines always begin with a digit, sign, or dot.
            if let first = line.first,
               !(first.isNumber || first == "-" || first == "+" || first == ".") {
                continue
            }

            let triple = try parseTriple(line, skippingFirst: false)
            // Output range is 0…1 for PRISM's rgba16Float LUT textures.
            values.append(min(max(triple.x, 0), 1))
            values.append(min(max(triple.y, 0), 1))
            values.append(min(max(triple.z, 0), 1))
        }

        guard size > 0 else { throw LUTError.malformed("missing LUT_3D_SIZE") }
        guard domainMax.x > domainMin.x, domainMax.y > domainMin.y,
              domainMax.z > domainMin.z else {
            throw LUTError.malformed("DOMAIN_MAX must exceed DOMAIN_MIN")
        }
        let expected = size * size * size * 3
        guard values.count == expected else {
            throw LUTError.malformed(
                "expected \(expected / 3) entries, found \(values.count / 3)")
        }
        return CubeLUT(size: size, title: title, domainMin: domainMin,
                       domainMax: domainMax, values: values)
    }

    private static func splitFields(_ line: String) -> [Substring] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    }

    private static func parseTriple(_ line: String,
                                    skippingFirst: Bool) throws -> SIMD3<Float> {
        var fields = splitFields(line)
        if skippingFirst { fields = Array(fields.dropFirst()) }
        guard fields.count == 3,
              let r = Float(fields[0]), let g = Float(fields[1]),
              let b = Float(fields[2]),
              r.isFinite, g.isFinite, b.isFinite else {
            throw LUTError.malformed("expected 3 numbers: \"\(line)\"")
        }
        return SIMD3<Float>(r, g, b)
    }

    static func identityLUT(size: Int) -> CubeLUT {
        var values: [Float] = []
        values.reserveCapacity(size * size * size * 3)
        let denominator = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    values.append(Float(r) / denominator)
                    values.append(Float(g) / denominator)
                    values.append(Float(b) / denominator)
                }
            }
        }
        return CubeLUT(size: size, title: "Neutral", values: values)
    }

    // MARK: - Texture construction

    /// rgba16Float 3D texture — half the memory of rgba32Float; the values
    /// are 0…1, well within half precision. x = red (fastest), y = green,
    /// z = blue, matching .cube ordering and normalized RGB sampling.
    static func makeTexture(from lut: CubeLUT, device: MTLDevice) -> MTLTexture? {
        let n = lut.size
        guard n >= 2, lut.values.count == n * n * n * 3 else { return nil }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = n
        descriptor.height = n
        descriptor.depth = n
        descriptor.mipmapLevelCount = 1
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var half = [UInt16](repeating: 0, count: n * n * n * 4)
        let one = floatToHalfBits(1)
        for i in 0..<(n * n * n) {
            half[i * 4 + 0] = floatToHalfBits(lut.values[i * 3 + 0])
            half[i * 4 + 1] = floatToHalfBits(lut.values[i * 3 + 1])
            half[i * 4 + 2] = floatToHalfBits(lut.values[i * 3 + 2])
            half[i * 4 + 3] = one
        }
        half.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n),
                            mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: n * 8,
                            bytesPerImage: n * n * 8)
        }
        return texture
    }

    /// Float32 → IEEE half bit pattern for inputs clamped to 0…1. Portable
    /// (Float16 the type is unavailable on x86_64 macOS). Values below the
    /// smallest normal half flush to zero — visually irrelevant for LUTs.
    static func floatToHalfBits(_ value: Float) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        let bits = clamped.bitPattern & 0x7FFF_FFFF
        if bits < 0x3880_0000 { return 0 }             // subnormal half → 0
        var rebased = bits &- 0x3800_0000              // rebias 127 → 15
        rebased &+= 0x0000_1000                        // round to nearest
        return UInt16(rebased >> 13)
    }
}
