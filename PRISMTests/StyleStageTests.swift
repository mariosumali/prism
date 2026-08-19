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

    // MARK: - Running the stage itself

    /// One frame through StyleStage, returning the output bytes. This is the
    /// stage's own contract rather than the kernel's: one command buffer, one
    /// commit, whatever passes the settings ask for.
    private func runStage(_ stage: StyleStage, source: MTLTexture) throws -> [UInt8] {
        let dst = try makeTexture()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw Failure.resourceAllocation("command buffer for the stage")
        }
        try stage.encode(commandBuffer: commandBuffer, input: source, output: dst)
        if textureStorageMode == .managed,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: dst)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error, "stage command buffer failed")
        var out = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        out.withUnsafeMutableBytes {
            dst.getBytes($0.baseAddress!, bytesPerRow: Self.width * 4,
                         from: MTLRegionMake2D(0, 0, Self.width, Self.height),
                         mipmapLevel: 0)
        }
        return out
    }

    private func makeStage(_ configure: (inout StyleSettings) -> Void) throws -> StyleStage {
        let stage = try StyleStage(metal: try MetalContext())
        stage.isEnabled = true
        var settings = StyleSettings()
        configure(&settings)
        stage.settings = settings
        return stage
    }

    /// §5.29 — the second effect runs over the first's output, not beside it.
    /// Pixelate then Thermal must be Thermal applied to a mosaic, which is
    /// what running the two singly in that order produces; if the stack ran
    /// them in the other order, or dropped one, this diverges immediately.
    func testStackedEffectsRunInOrderOverEachOther() throws {
        let (source, _) = try makeSource()

        let stacked = try makeStage { settings in
            settings.mutate(slot: 0) { $0.effect = .pixellate }
            settings.mutate(slot: 1) { $0.effect = .thermal }
        }
        let stackedOut = try runStage(stacked, source: source)

        // The same two effects, one stage pass each, chained by hand.
        let first = try makeStage { $0.mutate(slot: 0) { $0.effect = .pixellate } }
        let firstOut = try runStage(first, source: source)
        let intermediate = try makeTexture()
        fill(intermediate, with: firstOut)
        let second = try makeStage { $0.mutate(slot: 0) { $0.effect = .thermal } }
        let secondOut = try runStage(second, source: intermediate)

        XCTAssertLessThanOrEqual(maxDelta(stackedOut, secondOut), 2,
                                 "the stack is not the two effects composed in order")
        XCTAssertGreaterThan(maxDelta(stackedOut, firstOut), 4,
                             "the second effect never reached the picture")
    }

    /// §3.4 — a stacked pair is two full-frame passes and has to be charged
    /// for two. A static weight would tell the degradation engine the second
    /// effect was free, and it is the engine that decides what to turn off.
    func testWeightMultiplierTracksThePassCount() throws {
        let stage = try makeStage { $0.mutate(slot: 0) { $0.effect = .thermal } }
        XCTAssertEqual(stage.weightMultiplier, 1)

        stage.settings.mutate(slot: 1) { $0.effect = .bulge }
        XCTAssertEqual(stage.weightMultiplier, 2)

        // A slot parked at zero is not a pass, so it is not charged for one.
        stage.settings.mutate(slot: 1) { $0.intensity = 0 }
        XCTAssertEqual(stage.weightMultiplier, 1)
    }

    /// And the attribution actually spends those weights: the same stage list
    /// with a doubled style weight must take a bigger share of the frame.
    func testAttributionChargesAStackedStageForBothPasses() {
        let single = VideoPipeline.attribute(totalGpuMs: 10,
                                             to: [.adjust, .style],
                                             weights: [1, 5])
        let stacked = VideoPipeline.attribute(totalGpuMs: 10,
                                              to: [.adjust, .style],
                                              weights: [1, 10])
        XCTAssertGreaterThan(stacked[.style] ?? 0, single[.style] ?? 0)
        XCTAssertLessThan(stacked[.adjust] ?? 0, single[.adjust] ?? 0,
                          "the model is proportional; a dearer stage crowds the others")
    }

    /// §5.30 — an opted-in slot at full depth with a silent room lands at
    /// zero intensity, which the kernel contract says reproduces the source.
    /// This is the whole data path end to end: a level closure, an envelope,
    /// and a multiply into PRISMStyleParams.intensity.
    func testSilenceParksAnAudioReactiveEffectAtTheSource() throws {
        let (source, original) = try makeSource()
        let stage = try makeStage { settings in
            settings.mutate(slot: 0) { $0.effect = .thermal; $0.audioReactive = true }
            settings.audioDepth = 1
        }
        stage.audioLevelSource = { 0 }
        // Two frames: the first seeds the envelope's clock, the second is the
        // one whose elapsed time is real.
        _ = try runStage(stage, source: source)
        let out = try runStage(stage, source: source)
        XCTAssertLessThanOrEqual(maxDelta(out, original), 2,
                                 "a silent room at full depth is not the source")
    }

    /// …and a slot that did not opt in is untouched by the same silence.
    /// Per-effect opt-in is the whole point: the pairing people want is one
    /// effect breathing over one that holds still.
    func testSilenceLeavesASlotThatDidNotOptInAlone() throws {
        let (source, original) = try makeSource()
        let stage = try makeStage { settings in
            settings.mutate(slot: 0) { $0.effect = .thermal }
            settings.audioDepth = 1
        }
        stage.audioLevelSource = { 0 }
        _ = try runStage(stage, source: source)
        let out = try runStage(stage, source: source)
        XCTAssertGreaterThanOrEqual(maxDelta(out, original), 4,
                                    "silence dimmed an effect that never asked to listen")
    }

    // MARK: - The level envelope (§5.30)

    /// Attack faster than release is the musicality: the effect arrives with
    /// the word and settles after it, rather than chattering at the rate the
    /// RMS windows land.
    func testEnvelopeRisesFasterThanItFalls() {
        var rising = StyleLevelEnvelope()
        rising.step(level: 1, elapsed: 0.05)
        var falling = StyleLevelEnvelope()
        falling.step(level: 1, elapsed: 10)          // saturate
        let from = falling.value
        falling.step(level: 0, elapsed: 0.05)
        XCTAssertGreaterThan(rising.value, from - falling.value,
                             "the same 50 ms moves the envelope further up than down")
    }

    func testEnvelopeStaysInsideZeroToOne() {
        var envelope = StyleLevelEnvelope()
        for level in [2.0, -1.0, .nan, .infinity, 0.5] {
            envelope.step(level: level, elapsed: 0.033)
            XCTAssertTrue(envelope.value >= 0 && envelope.value <= 1,
                          "level \(level) took the envelope to \(envelope.value)")
        }
    }

    /// A gap in the frames is not evidence about the room. Integrating one
    /// whole would put a full-strength pulse on the first frame back, which
    /// is precisely the visible artefact the envelope exists to remove.
    func testEnvelopeCapsWhatOneFrameCanDo() {
        var capped = StyleLevelEnvelope()
        capped.step(level: 1, elapsed: 30)
        var stepped = StyleLevelEnvelope()
        stepped.step(level: 1, elapsed: StyleLevelEnvelope.maximumStepSeconds)
        XCTAssertEqual(capped.value, stepped.value, accuracy: 1e-9)
        XCTAssertLessThan(capped.value, 1, "a nap must not saturate the envelope")
    }

    func testEnvelopeIgnoresAZeroLengthStep() {
        var envelope = StyleLevelEnvelope()
        envelope.step(level: 1, elapsed: 0.05)
        let held = envelope.value
        envelope.step(level: 1, elapsed: 0)
        XCTAssertEqual(envelope.value, held)
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

    // MARK: - The stack's decoder precedence (§5.29)
    //
    // This is the highest-risk backward-compatibility change in the app:
    // every preset and every saved configuration in existence holds the flat
    // single-effect shape, and this struct now has two. The rule is that
    // `layers` wins whenever the key is present at all, and these pin it from
    // both sides.

    func testAPreStackPresetLoadsIntoTheFirstSlot() throws {
        let settings = try JSONDecoder().decode(
            StyleSettings.self,
            from: Data(#"{"effect":"underwater","intensity":0.4,"audioReactive":true}"#.utf8))
        XCTAssertEqual(settings.layers.count, StyleSettings.maxLayers)
        XCTAssertEqual(settings.layer(0).effect, .underwater)
        XCTAssertEqual(settings.layer(0).intensity, 0.4)
        XCTAssertTrue(settings.layer(0).audioReactive)
        XCTAssertEqual(settings.layer(1).effect, .normal, "nothing invented a second effect")
        XCTAssertEqual(settings.renderableLayers.count, 1)
    }

    /// A file this build wrote carries both shapes, and its flat keys describe
    /// only the first of two effects. Preferring them would silently drop the
    /// second effect every time a preset went through its own decoder.
    func testLayersWinOverTheFlatKeysWhenBothArePresent() throws {
        let json = #"""
        {"effect":"vhs","intensity":0.1,
         "layers":[{"effect":"underwater","intensity":0.8},
                   {"effect":"afterimage","intensity":0.5}]}
        """#
        let settings = try JSONDecoder().decode(StyleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.layer(0).effect, .underwater)
        XCTAssertEqual(settings.layer(0).intensity, 0.8)
        XCTAssertEqual(settings.layer(1).effect, .afterimage)
    }

    /// Present-but-empty is a cleared stack, not an absent key — which is why
    /// the decoder cannot use the `tolerant` helper for this one field.
    func testAnEmptyLayerArrayIsAClearedStackRatherThanAMissingOne() throws {
        let settings = try JSONDecoder().decode(
            StyleSettings.self,
            from: Data(#"{"effect":"vhs","intensity":1,"layers":[]}"#.utf8))
        XCTAssertTrue(settings.isNormal, "an empty stack is the unstyled picture")
        XCTAssertTrue(settings.renderableLayers.isEmpty)
    }

    /// The other half of the bargain: a preset exported from this build still
    /// loads its primary effect in a build that predates the stack, because
    /// the flat keys are still written. Shared presets are how a community
    /// forms around this (§5.5), and one that reads as blank in an older
    /// build is worse than one that arrives with an effect missing.
    func testTheFlatKeysAreStillWrittenForBuildsThatPredateTheStack() throws {
        var settings = StyleSettings()
        settings.mutate(slot: 0) { $0.effect = .twirl; $0.intensity = 0.6 }
        settings.mutate(slot: 1) { $0.effect = .echo }
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(settings)) as? [String: Any]
        XCTAssertEqual(object?["effect"] as? String, "twirl")
        XCTAssertEqual(object?["intensity"] as? Double, 0.6)
        XCTAssertNotNil(object?["layers"])
    }

    /// A newer build's longer stack truncates rather than failing, and a
    /// shorter one is filled — `layers` is always exactly `maxLayers`.
    func testALongerStackFromANewerBuildIsTruncated() throws {
        let json = #"""
        {"layers":[{"effect":"twirl"},{"effect":"bulge"},{"effect":"wave"}]}
        """#
        let settings = try JSONDecoder().decode(StyleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.layers.count, StyleSettings.maxLayers)
        XCTAssertEqual(settings.layer(0).effect, .twirl)
        XCTAssertEqual(settings.layer(1).effect, .bulge)
    }

    func testASlotDecodesEachFieldTolerantly() throws {
        let settings = try JSONDecoder().decode(
            StyleSettings.self,
            from: Data(#"{"layers":[{},{"effect":"sepia","intensity":0.3}]}"#.utf8))
        XCTAssertEqual(settings.layer(0), StyleLayer())
        XCTAssertEqual(settings.layer(1).effect, .normal, "a removed effect degrades to Normal")
        XCTAssertEqual(settings.layer(1).intensity, 0.3, "and does not take the number with it")
    }

    // MARK: - What the stack will actually run

    /// One history texture, so one motion effect. The earlier slot keeps it;
    /// the later one is simply not run rather than quietly trailing the
    /// other's ghosts.
    func testOnlyOneMotionEffectSurvivesTheStack() {
        var settings = StyleSettings()
        settings.mutate(slot: 0) { $0.effect = .afterimage }
        // A motion effect alone never blocks itself, and the other slot is
        // where the menus stop offering the second one.
        XCTAssertTrue(settings.acceptsTemporal(inSlot: 0))
        XCTAssertFalse(settings.acceptsTemporal(inSlot: 1))

        // Reachable only by hand-editing a preset, and it still has to
        // resolve: the earlier slot keeps the history, the later one is not
        // run rather than quietly trailing the other's ghosts.
        settings.mutate(slot: 1) { $0.effect = .echo }
        XCTAssertEqual(settings.renderableLayers.map(\.effect), [.afterimage])

        // A distortion under a motion effect is the pairing this exists for.
        settings.mutate(slot: 0) { $0.effect = .underwater }
        XCTAssertEqual(settings.renderableLayers.map(\.effect), [.underwater, .echo])
        XCTAssertTrue(settings.acceptsTemporal(inSlot: 1))
        XCTAssertFalse(settings.acceptsTemporal(inSlot: 0))
    }

    func testASlotAtZeroIntensityIsNotAPassButKeepsItsEffect() {
        var settings = StyleSettings()
        settings.mutate(slot: 0) { $0.effect = .twirl; $0.intensity = 0 }
        XCTAssertTrue(settings.renderableLayers.isEmpty)
        XCTAssertFalse(settings.isNormal, "an effect parked at zero is still chosen")
        // Which is what lets a slider come back off zero without the effect
        // having been forgotten in the meantime.
        settings.mutate(slot: 0) { $0.intensity = 0.5 }
        XCTAssertEqual(settings.renderableLayers.map(\.effect), [.twirl])
    }

    func testAudioReactivityIsPerSlot() {
        var settings = StyleSettings()
        settings.mutate(slot: 0) { $0.effect = .twirl }
        XCTAssertFalse(settings.isAudioReactive)
        settings.mutate(slot: 1) { $0.effect = .thermal; $0.audioReactive = true }
        XCTAssertTrue(settings.isAudioReactive)
        // A slot nobody is running cannot arm the microphone.
        settings.mutate(slot: 1) { $0.intensity = 0 }
        XCTAssertFalse(settings.isAudioReactive)
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

        // §5.29: a live second effect keeps the stage doing something even
        // when the first one is parked, so neither surface may call it inert.
        config.style.mutate(slot: 0) { $0.intensity = 0 }
        config.style.mutate(slot: 1) { $0.effect = .thermal }
        XCTAssertFalse(config.isInert(.style))
        config.style.mutate(slot: 1) { $0.intensity = 0 }
        XCTAssertTrue(config.isInert(.style))
        XCTAssertEqual(config.inertReason(.style),
                       "On, but both effects are at intensity 0.")

        config.flags[.style] = StageFlags(enabled: false)
        XCTAssertFalse(config.isInert(.style), "an off stage is off, not inert")
    }
}
