// FoundationTypesTests.swift
// PRISMTests
//
// Locks down the shared vocabulary the whole app builds on: format ordering
// and labels, the latency-policy budget table (§3.4), chain order and
// degradation tie-breaking, and configuration/preset JSON round-trips (§5.5).
//
// Licensed under the Apache License, Version 2.0.

import Metal
import XCTest

final class FoundationTypesTests: XCTestCase {

    // MARK: VideoFormat

    func testDefaultSetMatchesSpecTable() {
        // §3.2 default published set: 9 entries.
        let set = VideoFormat.defaultSet
        XCTAssertEqual(set.count, 9)
        XCTAssertTrue(set.contains(VideoFormat(width: 3840, height: 2160, frameRate: 30)))
        for rate in [24, 30, 60] {
            XCTAssertTrue(set.contains(VideoFormat(width: 1920, height: 1080, frameRate: rate)))
            XCTAssertTrue(set.contains(VideoFormat(width: 1280, height: 720, frameRate: rate)))
        }
        XCTAssertTrue(set.contains(VideoFormat(width: 960, height: 540, frameRate: 30)))
        XCTAssertTrue(set.contains(VideoFormat(width: 640, height: 480, frameRate: 30)))
    }

    func testFormatSortLargestFirst() {
        let sorted = VideoFormat.defaultSet.sorted()
        XCTAssertEqual(sorted.first, VideoFormat(width: 3840, height: 2160, frameRate: 30))
        XCTAssertEqual(sorted.last, VideoFormat(width: 640, height: 480, frameRate: 30))
        // Same dimensions: higher rate first.
        let i60 = sorted.firstIndex(of: VideoFormat(width: 1920, height: 1080, frameRate: 60))!
        let i24 = sorted.firstIndex(of: VideoFormat(width: 1920, height: 1080, frameRate: 24))!
        XCTAssertLessThan(i60, i24)
    }

    func testResolutionLabels() {
        XCTAssertEqual(VideoFormat(width: 1920, height: 1080, frameRate: 30).resolutionLabel, "1080p")
        XCTAssertEqual(VideoFormat(width: 3840, height: 2160, frameRate: 30).resolutionLabel, "4K")
        XCTAssertEqual(VideoFormat(width: 1234, height: 700, frameRate: 30).resolutionLabel, "1234×700")
    }

    func testFrameInterval() {
        XCTAssertEqual(VideoFormat(width: 1920, height: 1080, frameRate: 30).frameIntervalMs,
                       1000.0 / 30.0, accuracy: 0.001)
    }

    // MARK: LatencyPolicy budget table (§3.4)

    func testBudgetTable() {
        let cases: [(LatencyPolicy, Double, Double)] = [
            (.lowest, 1000.0 / 60.0, 3.3), (.lowest, 1000.0 / 30.0, 6.7),
            (.lowest, 1000.0 / 24.0, 8.3),
            (.balanced, 1000.0 / 60.0, 6.7), (.balanced, 1000.0 / 30.0, 13.3),
            (.balanced, 1000.0 / 24.0, 16.7),
            (.quality, 1000.0 / 60.0, 11.7), (.quality, 1000.0 / 30.0, 23.3),
            (.quality, 1000.0 / 24.0, 29.2),
        ]
        for (policy, interval, expected) in cases {
            XCTAssertEqual(policy.budgetMs(frameIntervalMs: interval), expected,
                           accuracy: 0.05,
                           "\(policy) at \(interval)ms must match the §3.4 table")
        }
    }

    // MARK: Chain order and degradation ordering (§3.3, §3.4)

    func testChainOrderIsFixed() {
        let ordered = StageID.allCases.sorted()
        XCTAssertEqual(ordered, [.clip, .replay, .freeze, .gaze, .geometry,
                                 .adjust, .lut, .blur, .background, .overlay,
                                 .style, .connection, .outputFit])
    }

    /// The three substituting stages escalate: a replay overrides a clip, a
    /// freeze overrides a replay. Later stages write the whole frame, so
    /// chain position IS the precedence.
    func testSubstitutionStagesEscalate() {
        XCTAssertLessThan(StageID.clip.chainIndex, StageID.replay.chainIndex)
        XCTAssertLessThan(StageID.replay.chainIndex, StageID.freeze.chainIndex)
    }

    /// Eye contact warps in the space Vision measured landmarks in, so it
    /// must precede any geometric transform.
    func testGazePrecedesGeometry() {
        XCTAssertLessThan(StageID.gaze.chainIndex, StageID.geometry.chainIndex)
    }

    /// Both mask consumers composite over the finished look, and a
    /// foreground overlay layer must land above a replaced background.
    func testCompositingStagesFollowTheLook() {
        XCTAssertLessThan(StageID.lut.chainIndex, StageID.background.chainIndex)
        XCTAssertLessThan(StageID.background.chainIndex, StageID.overlay.chainIndex)
        XCTAssertLessThan(StageID.overlay.chainIndex, StageID.outputFit.chainIndex)
    }

    func testDegradationVictimOrdering() {
        // §3.4: expensive before moderate before cheap; ties broken by later
        // chain position. Simulate the selection rule over enabled stages.
        struct Row { let id: StageID; let cost: StageCost }
        let enabled: [Row] = [
            Row(id: .geometry, cost: .cheap),
            Row(id: .adjust, cost: .cheap),
            Row(id: .lut, cost: .moderate),
            Row(id: .blur, cost: .expensive),
        ]
        func victim(_ rows: [Row]) -> StageID? {
            rows.sorted {
                if $0.cost != $1.cost { return $0.cost > $1.cost }
                return $0.id.chainIndex > $1.id.chainIndex
            }.first?.id
        }
        XCTAssertEqual(victim(enabled), .blur)
        XCTAssertEqual(victim(enabled.filter { $0.id != .blur }), .lut)
        // Tie between two cheap stages → later chain position (adjust) first.
        XCTAssertEqual(victim(enabled.filter { $0.cost == .cheap }), .adjust)
    }

    // MARK: Configuration / preset round-trips (§5.5)

    func testPipelineConfigurationJSONRoundTrip() throws {
        var config = PipelineConfiguration()
        config.adjust.exposureEV = 0.4
        config.adjust.temperature = -25
        config.lut.lutName = "Film"
        config.lut.strength = 0.8
        config.blur.quality = .accurate
        config.geometry.zoom = 2.5
        config.geometry.mirror = .horizontal
        config.geometry.cropAspect = .r16x9
        config.geometry.autoFrame = true
        config.flags[.blur] = StageFlags(enabled: true, pinned: true)
        config.format = VideoFormat(width: 1280, height: 720, frameRate: 60)
        config.latencyPolicy = .lowest
        config.cameraID = "cam-uid"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PipelineConfiguration.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testPresetJSONRoundTrip() throws {
        var config = PipelineConfiguration()
        config.latencyPolicy = .quality
        let preset = Preset(name: "Interview", configuration: config,
                            hotkey: HotkeyCombo(keyCode: 18, option: true, command: true))
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(decoded, preset)
        // displayString renders the key through the active keyboard layout
        // (§5.15), so keycode 18 is only "1" on layouts where it is: on a
        // French layout that key types "&" and is named "1", on Dvorak it is
        // "1" again, and asserting the literal here would fail on a machine
        // that is behaving correctly. What the round trip owes us is the
        // modifier prefix and its order.
        XCTAssertEqual(decoded.hotkey?.displayString, "⌥⌘" + KeyCodeNames.name(for: 18))
        XCTAssertTrue(decoded.hotkey?.displayString.hasPrefix("⌥⌘") == true)
    }

    func testVideoFormatJSONKeysMatchExtensionContract() throws {
        // The camera extension decodes the 'pfmt' payload with its own
        // Codable mirror using keys width/height/frameRate. Guard the keys.
        let data = try JSONEncoder().encode(VideoFormat(width: 1920, height: 1080, frameRate: 30))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["width", "height", "frameRate"])
    }

    // MARK: Settings identity checks (drive wantsEncode fast paths)

    func testIdentityDetection() {
        XCTAssertTrue(AdjustSettings().isIdentity)
        var adjust = AdjustSettings()
        adjust.vignette = 0.2
        XCTAssertFalse(adjust.isIdentity)

        XCTAssertTrue(GeometrySettings().isIdentity)
        var geometry = GeometrySettings()
        geometry.orientation = .deg90
        XCTAssertFalse(geometry.isIdentity)
    }

    func testNeutralLUTNameIsCaseInsensitive() {
        XCTAssertTrue(LUTSettings.isNeutral("Neutral"))
        XCTAssertTrue(LUTSettings.isNeutral("neutral"))
        XCTAssertFalse(LUTSettings.isNeutral("Warm"))
        XCTAssertTrue(LUTSettings().isNeutral, "the default LUT is the identity")
    }

    // MARK: Inert stages — enabled but skipped by the same fast paths

    /// The switch says on, the pipeline skips the pass, the picture does not
    /// change. Every Effects surface reads isInert/inertReason to say so, so
    /// the mapping from "identity settings" to "inert" is load-bearing UI.
    func testInertDetectionMatchesTheWantsEncodeFastPaths() {
        var config = PipelineConfiguration()

        // Off is not inert — there is nothing misleading about an off switch.
        XCTAssertFalse(config.isInert(.adjust))
        XCTAssertNil(config.inertReason(.adjust))

        config.flags[.adjust] = StageFlags(enabled: true)
        XCTAssertTrue(config.isInert(.adjust), "default adjustments are identity")
        XCTAssertNotNil(config.inertReason(.adjust))
        config.adjust.exposureEV = 0.5
        XCTAssertFalse(config.isInert(.adjust))
        XCTAssertNil(config.inertReason(.adjust))

        config.flags[.lut] = StageFlags(enabled: true)
        XCTAssertTrue(config.isInert(.lut), "Neutral IS the identity LUT")
        config.lut.lutName = "Warm"
        XCTAssertFalse(config.isInert(.lut))
        config.lut.strength = 0
        XCTAssertTrue(config.isInert(.lut), "zero strength applies nothing")

        config.flags[.geometry] = StageFlags(enabled: true)
        XCTAssertTrue(config.isInert(.geometry))
        config.geometry.zoom = 1.5
        XCTAssertFalse(config.isInert(.geometry))

        config.flags[.overlay] = StageFlags(enabled: true)
        XCTAssertTrue(config.isInert(.overlay), "no layer has a file")

        // Blur and virtual background always change the picture when on —
        // blur waits for the mask, background falls back to its colour.
        config.flags[.blur] = StageFlags(enabled: true)
        config.flags[.background] = StageFlags(enabled: true)
        XCTAssertFalse(config.isInert(.blur))
        XCTAssertFalse(config.isInert(.background))
    }

    /// The stages that decline to encode and the stages reported inert have
    /// to be the same set, or a surface promises a change the pipeline skips.
    func testInertStagesAreExactlyTheStagesThatDeclineToEncode() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device on this host")
        }
        let metal = try MetalContext()

        var config = PipelineConfiguration()
        for id in StageID.allCases {
            config.flags[id] = StageFlags(enabled: true)
        }

        let adjust = try AdjustStage(metal: metal)
        adjust.isEnabled = true
        adjust.settings = config.adjust
        XCTAssertEqual(adjust.wantsEncode(), !config.isInert(.adjust))

        let geometry = try GeometryStage(metal: metal)
        geometry.isEnabled = true
        geometry.settings = config.geometry
        XCTAssertEqual(geometry.wantsEncode(), !config.isInert(.geometry))

        let lut = try LUTStage(metal: metal)
        lut.isEnabled = true
        lut.settings = config.lut
        XCTAssertEqual(lut.wantsEncode(), !config.isInert(.lut))
    }

    func testKernelParamStructSizes() {
        // Swift and MSL compile KernelTypes.h independently; a size drift
        // means misaligned constant buffers. Sizes are fixed by the header.
        XCTAssertEqual(MemoryLayout<PRISMAdjustParams>.size, 32)
        XCTAssertEqual(MemoryLayout<PRISMLUTParams>.size, 16)
        XCTAssertEqual(MemoryLayout<PRISMBlurParams>.size, 16)
        XCTAssertEqual(MemoryLayout<PRISMCompositeParams>.size, 16)
        XCTAssertEqual(MemoryLayout<PRISMCrossfadeParams>.size, 16)
        XCTAssertEqual(MemoryLayout<PRISMSharpnessParams>.size, 16)
        // simd_float3x3 is 48 bytes (3 × float4-aligned columns).
        XCTAssertEqual(MemoryLayout<PRISMGeometryParams>.size, 64)
    }
}
