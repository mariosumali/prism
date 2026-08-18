// StyleStageTests.swift
// PRISMTests
//
// The Style catalogue is an enum pointing at kernels the compiler never
// checks: a case whose kernel is missing or misnamed would pick fine in the
// UI and silently show the unstyled picture. These tests pin every case to
// a compiling kernel and every kernel to the shared contract — intensity 0
// reproduces the source, intensity 1 visibly changes a non-uniform picture.
// The motion effects run the two-frame variant: their first pass seeds the
// history feedback exactly like StyleStage's dst→history blit, and the
// second pass must show the first frame's ghost. Plus the stage's
// decline-to-encode rules, the settings' forward-compatible decoding
// (including removed catalogue entries), and the isInert bookkeeping every
// surface reads.
//
// Licensed under the Apache License, Version 2.0.

import Metal
import XCTest

final class StyleStageTests: XCTestCase {

    private enum Failure: Error {
        case resourceAllocation(String)
    }

    // Large enough that pixellate's full-intensity block size (2.5% of frame
    // height) is a real mosaic, not sub-pixel.
    private static let width = 256
    private static let height = 144

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var library: MTLLibrary!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host; skipping style tests")
        }
        device = dev
        guard let q = dev.makeCommandQueue() else {
            throw Failure.resourceAllocation("MTLCommandQueue")
        }
        queue = q
        library = try dev.makeDefaultLibrary(bundle: Bundle(for: Self.self))
    }

    // MARK: - Harness

    private var textureStorageMode: MTLStorageMode {
        device.hasUnifiedMemory ? .shared : .managed
    }

    private func makeTexture() throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height,
            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = textureStorageMode
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw Failure.resourceAllocation("BGRA8 texture")
        }
        return texture
    }

    /// Asymmetric pattern: gradients in R/G, an 8px checker in B, opaque
    /// alpha — so mirrors, warps and recolors all visibly change it.
    private func sourceBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let i = (y * Self.width + x) * 4
                bytes[i + 0] = (((x / 8) + (y / 8)) % 2 == 0) ? 255 : 32  // B
                bytes[i + 1] = UInt8(y * 255 / (Self.height - 1))         // G
                bytes[i + 2] = UInt8(x * 255 / (Self.width - 1))          // R
                bytes[i + 3] = 255                                        // A
            }
        }
        return bytes
    }

    private func fill(_ texture: MTLTexture, with bytes: [UInt8]) {
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, Self.width, Self.height),
                            mipmapLevel: 0,
                            withBytes: $0.baseAddress!,
                            bytesPerRow: Self.width * 4)
        }
    }

    private func makeSource() throws -> (texture: MTLTexture, bytes: [UInt8]) {
        let texture = try makeTexture()
        let bytes = sourceBytes()
        fill(texture, with: bytes)
        return (texture, bytes)
    }

    /// Opaque white — a maximally visible "previous frame" for ghost tests.
    private func makeWhiteSource() throws -> MTLTexture {
        let texture = try makeTexture()
        fill(texture, with: [UInt8](repeating: 255,
                                    count: Self.width * Self.height * 4))
        return texture
    }

    /// One kernel pass. Temporal kernels bind src t0 / history t1 / dst t2;
    /// everything else src t0 / dst t1 (the StyleStage.encode contract).
    private func encodePass(_ effect: StyleEffect, intensity: Float,
                            source: MTLTexture, history: MTLTexture?,
                            hasHistory: Bool, into dst: MTLTexture) throws {
        let name = try XCTUnwrap(effect.kernelFunction)
        let fn = try XCTUnwrap(library.makeFunction(name: name),
                               "kernel '\(name)' missing from the library")
        let pipeline = try device.makeComputePipelineState(function: fn)
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw Failure.resourceAllocation("command buffer for \(name)")
        }
        encoder.setComputePipelineState(pipeline)
        if let history {
            encoder.setTexture(source, index: 0)
            encoder.setTexture(history, index: 1)
            encoder.setTexture(dst, index: 2)
        } else {
            encoder.setTexture(source, index: 0)
            encoder.setTexture(dst, index: 1)
        }
        var params = PRISMStyleParams()
        params.intensity = intensity
        params.time = 1.25
        params.aspect = Float(Self.width) / Float(Self.height)
        params.hasHistory = hasHistory ? 1 : 0
        encoder.setBytes(&params, length: MemoryLayout<PRISMStyleParams>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (Self.width + 15) / 16,
                           height: (Self.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        if textureStorageMode == .managed,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: dst)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error, "\(name) command buffer failed")
    }

    /// Runs an effect the way StyleStage does and returns the final output.
    /// Temporal effects run two frames — `previous` seeds the history via a
    /// first pass (hasHistory 0) whose output is copied into the history
    /// texture, mirroring the stage's dst→history blit — and the result is
    /// the second frame's output over `source`.
    private func run(_ effect: StyleEffect, intensity: Float,
                     source: MTLTexture, previous: MTLTexture? = nil) throws -> [UInt8] {
        let dst = try makeTexture()
        if effect.isTemporal {
            let history = try makeTexture()
            let seedDst = try makeTexture()
            try encodePass(effect, intensity: intensity,
                           source: previous ?? source, history: history,
                           hasHistory: false, into: seedDst)
            try copy(seedDst, to: history)
            try encodePass(effect, intensity: intensity, source: source,
                           history: history, hasHistory: true, into: dst)
        } else {
            try encodePass(effect, intensity: intensity, source: source,
                           history: nil, hasHistory: false, into: dst)
        }
        var out = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        out.withUnsafeMutableBytes {
            dst.getBytes($0.baseAddress!, bytesPerRow: Self.width * 4,
                         from: MTLRegionMake2D(0, 0, Self.width, Self.height),
                         mipmapLevel: 0)
        }
        return out
    }

    private func copy(_ source: MTLTexture, to destination: MTLTexture) throws {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw Failure.resourceAllocation("blit command buffer")
        }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Largest per-channel color delta (alpha excluded).
    private func maxDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var m = 0
        for i in 0..<a.count where i % 4 != 3 {
            m = max(m, abs(Int(a[i]) - Int(b[i])))
        }
        return m
    }

    // MARK: - Catalogue ↔ kernel lockstep

    func testEveryEffectNamesACompilingKernel() throws {
        for effect in StyleEffect.allCases where effect != .normal {
            let name = try XCTUnwrap(effect.kernelFunction,
                                     "\(effect) has no kernel name")
            let fn = try XCTUnwrap(library.makeFunction(name: name),
                                   "kernel '\(name)' missing for \(effect)")
            XCTAssertNoThrow(try device.makeComputePipelineState(function: fn),
                             "pipeline for '\(name)' failed to build")
        }
    }

    func testNormalIsTheOneEffectWithNoKernel() {
        XCTAssertNil(StyleEffect.normal.kernelFunction)
        XCTAssertTrue(StyleSettings().isNormal)
        XCTAssertFalse(StyleEffect.normal.isTemporal)
    }

    func testCatalogueGroupsCoverEveryEffectOnce() {
        let grouped = StyleEffect.looks + StyleEffect.distortions
            + StyleEffect.motion
        XCTAssertEqual(grouped.count, Set(grouped).count, "an effect is listed twice")
        XCTAssertEqual(Set(grouped + [.normal]), Set(StyleEffect.allCases),
                       "an effect is missing from every group")
        XCTAssertEqual(Set(StyleEffect.motion),
                       Set(StyleEffect.allCases.filter(\.isTemporal)),
                       "the motion group IS the temporal set")
    }

    // MARK: - Kernel contract

    /// Intensity 0 must reproduce the source: color looks mix toward the
    /// styled picture, warps scale their displacement to zero, discrete
    /// remaps crossfade, and motion effects scale their trails away — all
    /// of them land on the input, history present or not.
    func testZeroIntensityReproducesTheSource() throws {
        let (source, original) = try makeSource()
        let white = try makeWhiteSource()
        for effect in StyleEffect.allCases where effect != .normal {
            let out = try run(effect, intensity: 0, source: source,
                              previous: white)
            XCTAssertLessThanOrEqual(maxDelta(out, original), 2,
                                     "\(effect) is not identity at intensity 0")
        }
    }

    /// Every effect must actually do something at full intensity. Motion
    /// effects ghost a white previous frame over the pattern — the most
    /// visible possible trail.
    func testFullIntensityChangesThePicture() throws {
        let (source, original) = try makeSource()
        let white = try makeWhiteSource()
        for effect in StyleEffect.allCases where effect != .normal {
            let out = try run(effect, intensity: 1, source: source,
                              previous: white)
            XCTAssertGreaterThanOrEqual(maxDelta(out, original), 4,
                                        "\(effect) changes nothing at intensity 1")
        }
    }

    /// A motion effect's first frame (no history yet) must be the source
    /// untouched — undefined history contents may never leak into the
    /// picture; that frame seeds the feedback instead.
    func testMotionEffectsPassThroughUntilSeeded() throws {
        let (source, original) = try makeSource()
        for effect in StyleEffect.motion {
            let dst = try makeTexture()
            let garbage = try makeTexture()   // deliberately never written
            try encodePass(effect, intensity: 1, source: source,
                           history: garbage, hasHistory: false, into: dst)
            var out = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
            out.withUnsafeMutableBytes {
                dst.getBytes($0.baseAddress!, bytesPerRow: Self.width * 4,
                             from: MTLRegionMake2D(0, 0, Self.width, Self.height),
                             mipmapLevel: 0)
            }
            XCTAssertLessThanOrEqual(maxDelta(out, original), 2,
                                     "\(effect) leaked unseeded history")
        }
    }

    // MARK: - Stage behaviour

    func testWantsEncodeDeclinesNormalAndZeroIntensity() throws {
        let metal = try MetalContext()
        let stage = try StyleStage(metal: metal)

        stage.isEnabled = true
        XCTAssertFalse(stage.wantsEncode(), "Normal must never encode")

        stage.settings.effect = .twirl
        stage.settings.intensity = 0
        XCTAssertFalse(stage.wantsEncode(), "zero intensity must not encode")

        stage.settings.intensity = 0.5
        XCTAssertTrue(stage.wantsEncode())

        stage.isEnabled = false
        XCTAssertFalse(stage.wantsEncode())
    }

    /// Style is the last composing stage: after everything the user layers,
    /// before the bad-connection degrade and the always-on output fit (§3.3).
    func testStyleSitsBetweenOverlayAndConnection() {
        XCTAssertLessThan(StageID.overlay, StageID.style)
        XCTAssertLessThan(StageID.style, StageID.connection)
        XCTAssertLessThan(StageID.connection, StageID.outputFit)
    }

    // MARK: - Settings persistence (§5.5 forward compatibility)

    func testSettingsDecodeToleratesAbsentAndUnknownFields() throws {
        let decoder = JSONDecoder()

        let empty = try decoder.decode(StyleSettings.self,
                                       from: Data("{}".utf8))
        XCTAssertEqual(empty.effect, .normal)
        XCTAssertEqual(empty.intensity, 1)

        // "sepia" was in the catalogue once and remains in old presets; a
        // removed (or newer build's) effect falls back to Normal without
        // discarding the rest of the struct.
        let removed = try decoder.decode(
            StyleSettings.self,
            from: Data(#"{"effect":"sepia","intensity":0.5}"#.utf8))
        XCTAssertEqual(removed.effect, .normal)
        XCTAssertEqual(removed.intensity, 0.5)

        // A configuration written before the style field existed decodes
        // with the default rather than throwing (§5.5).
        let config = try decoder.decode(PipelineConfiguration.self,
                                        from: Data("{}".utf8))
        XCTAssertEqual(config.style, StyleSettings())
    }

    func testSettingsRoundTrip() throws {
        var settings = StyleSettings()
        settings.effect = .afterimage
        settings.intensity = 0.7
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StyleSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - isInert bookkeeping

    func testConfigurationTreatsNormalStyleAsInert() {
        var config = PipelineConfiguration()
        config.flags[.style] = StageFlags(enabled: true)

        XCTAssertTrue(config.isInert(.style), "Normal is the unstyled picture")
        XCTAssertNotNil(config.inertReason(.style))

        config.style.effect = .bulge
        config.style.intensity = 0
        XCTAssertTrue(config.isInert(.style), "zero intensity changes nothing")
        XCTAssertNotNil(config.inertReason(.style))

        config.style.intensity = 1
        XCTAssertFalse(config.isInert(.style))
        XCTAssertNil(config.inertReason(.style))

        config.flags[.style] = StageFlags(enabled: false)
        XCTAssertFalse(config.isInert(.style), "an off stage is off, not inert")
    }
}
