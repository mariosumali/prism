// StudioSettingsTests.swift
// PRISMTests
//
// Behaviour settings for replay, away and panic (§5.9–§5.11), plus the
// forward-compatibility contract that keeps a user's saved configuration and
// presets alive when the app gains a feature.
//
// That last one is not a nicety. Synthesised Codable throws on an absent key
// rather than falling back to a property default, so without a hand-written
// decoder every new field would silently reset every existing user's whole
// setup on upgrade — configuration AND every preset they had saved.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class StudioSettingsTests: XCTestCase {

    // MARK: - Defaults

    /// An armed buffer runs a hardware encoder on every frame. A resident
    /// agent must cost nothing for a feature nobody has switched on.
    func testRollingBufferIsOffByDefault() {
        XCTAssertFalse(StudioSettings().replay.isArmed)
    }

    func testReplayDefaultsCatchUpToLive() {
        XCTAssertGreaterThan(ReplaySettings().playbackRate, 1)
        XCTAssertTrue(ReplaySettings().returnToLiveAtEnd)
    }

    func testAwayMutesByDefault() {
        XCTAssertTrue(AwaySettings().mutesAudio, "stepping away means stepping away")
    }

    func testPanicDoesEverythingByDefault() {
        let panic = PanicSettings()
        XCTAssertTrue(panic.freezes)
        XCTAssertTrue(panic.mutes)
        XCTAssertTrue(panic.swapsBackdrop)
    }

    // MARK: - Clamping

    func testBufferSecondsClampToTheSupportedRange() {
        var replay = ReplaySettings()
        replay.bufferSeconds = 1
        XCTAssertEqual(replay.clampedBufferSeconds, 4)
        replay.bufferSeconds = 600
        XCTAssertEqual(replay.clampedBufferSeconds, 30)
        replay.bufferSeconds = 12
        XCTAssertEqual(replay.clampedBufferSeconds, 12)
    }

    func testPlaybackRateClamps() {
        var replay = ReplaySettings()
        replay.playbackRate = 0
        XCTAssertEqual(replay.clampedPlaybackRate, 0.25)
        replay.playbackRate = 99
        XCTAssertEqual(replay.clampedPlaybackRate, 4)
    }

    func testAwayLoopAndCrossfadeClamp() {
        var away = AwaySettings()
        away.loopSeconds = 0
        XCTAssertEqual(away.clampedLoopSeconds, 2)
        away.loopSeconds = 999
        XCTAssertEqual(away.clampedLoopSeconds, 10)
        away.crossfadeMs = -100
        XCTAssertEqual(away.clampedCrossfadeMs, 0)
        away.crossfadeMs = 99_999
        XCTAssertEqual(away.clampedCrossfadeMs, 1500)
    }

    // MARK: - Panic backdrop

    func testPanicWithoutBackdropUsesAFlatColour() {
        let settings = PanicSettings().backdropConfiguration
        XCTAssertEqual(settings.kind, .color)
        XCTAssertNil(settings.assetPath)
    }

    func testPanicBackdropDetectsVideoByExtension() {
        var panic = PanicSettings()
        panic.backdropPath = "/tmp/brb.mp4"
        XCTAssertEqual(panic.backdropConfiguration.kind, .video)
        panic.backdropPath = "/tmp/brb.PNG"
        XCTAssertEqual(panic.backdropConfiguration.kind, .image)
    }

    func testPanicBackdropCarriesTheChosenColour() {
        var panic = PanicSettings()
        panic.backdropColor = RGBColor(red: 0.2, green: 0.4, blue: 0.6)
        XCTAssertEqual(panic.backdropConfiguration.color, panic.backdropColor)
    }

    // MARK: - Round trips

    func testStudioSettingsRoundTripsThroughJSON() throws {
        var settings = StudioSettings()
        settings.replay.isArmed = true
        settings.replay.bufferSeconds = 17
        settings.replay.maxHeight = 720
        settings.away.loopSeconds = 6
        settings.panic.backdropPath = "/tmp/brb.png"
        settings.panic.mutes = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    /// A file written by a build that predates a field must still load, with
    /// the new field taking its default.
    ///
    /// Note this asserts on a partial NESTED object, which is what version
    /// skew actually produces. A tolerant outer decoder alone would discard
    /// the whole `replay` object here and quietly report isArmed == false.
    func testStudioSettingsDecodesFromAPartialFile() throws {
        let json = Data(#"{"replay":{"isArmed":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertTrue(decoded.replay.isArmed, "a partial nested object must not be discarded")
        XCTAssertEqual(decoded.replay.bufferSeconds, ReplaySettings().bufferSeconds)
        XCTAssertEqual(decoded.away, AwaySettings())
        XCTAssertEqual(decoded.panic, PanicSettings())
    }

    /// The same rule one level deeper: a preset whose blur settings predate a
    /// field must keep the fields it does have.
    func testNestedStageSettingsSurvivePartialObjects() throws {
        let json = Data(#"{"blur":{"radius":31},"lut":{"lutName":"Warm"}}"#.utf8)
        let decoded = try JSONDecoder().decode(PipelineConfiguration.self, from: json)
        XCTAssertEqual(decoded.blur.radius, 31)
        XCTAssertEqual(decoded.blur.quality, .balanced, "absent field takes its default")
        XCTAssertEqual(decoded.lut.lutName, "Warm")
        XCTAssertEqual(decoded.lut.strength, 1)
    }

    /// And in the flags dictionary, where a throwing StageFlags would take
    /// every stage's enabled/pinned state with it.
    func testStageFlagsSurvivePartialObjects() throws {
        let json = Data(#"{"flags":["blur",{"enabled":true}]}"#.utf8)
        let decoded = try JSONDecoder().decode(PipelineConfiguration.self, from: json)
        XCTAssertTrue(decoded.flags(for: .blur).enabled)
        XCTAssertFalse(decoded.flags(for: .blur).pinned)
    }

    func testStudioSettingsDecodesFromAnEmptyObject() throws {
        let decoded = try JSONDecoder().decode(StudioSettings.self,
                                               from: Data("{}".utf8))
        XCTAssertEqual(decoded, StudioSettings())
    }

    // MARK: - Pipeline configuration forward compatibility

    /// The exact upgrade path that matters: a configuration saved before eye
    /// contact, virtual backgrounds and overlays existed. Every old field
    /// must survive and every new one must take its default.
    func testPipelineConfigurationDecodesFromAPreFeatureFile() throws {
        let json = Data("""
        {
          "adjust": {"exposureEV": 0.5, "contrast": 1.2, "saturation": 1.0,
                     "temperature": 10, "vignette": 0.1},
          "lut": {"lutName": "Film", "strength": 0.8},
          "blur": {"quality": "accurate", "radius": 24},
          "geometry": {"zoom": 1.5, "panX": 0.1, "panY": 0, "rotationDegrees": 3,
                       "orientation": 0, "mirror": "none", "cropAspect": "free",
                       "autoFrame": true},
          "format": {"width": 1280, "height": 720, "frameRate": 60},
          "latencyPolicy": "quality"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(PipelineConfiguration.self, from: json)
        // Old fields survive intact.
        XCTAssertEqual(decoded.adjust.exposureEV, 0.5)
        XCTAssertEqual(decoded.lut.lutName, "Film")
        XCTAssertEqual(decoded.blur.quality, .accurate)
        XCTAssertTrue(decoded.geometry.autoFrame)
        XCTAssertEqual(decoded.format, VideoFormat(width: 1280, height: 720, frameRate: 60))
        XCTAssertEqual(decoded.latencyPolicy, .quality)
        // New fields take their defaults rather than failing the whole decode.
        XCTAssertEqual(decoded.gaze, GazeSettings())
        XCTAssertEqual(decoded.background, BackgroundSettings())
        XCTAssertEqual(decoded.overlay, OverlaySettings())
    }

    /// A preset file from an older build must load rather than being dropped
    /// — losing a user's saved looks on upgrade is not an acceptable failure.
    func testPresetDecodesFromAPreFeatureFile() throws {
        let json = Data("""
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "My look",
          "isBuiltIn": false,
          "configuration": {"latencyPolicy": "balanced"}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(Preset.self, from: json)
        XCTAssertEqual(decoded.name, "My look")
        XCTAssertEqual(decoded.configuration.gaze, GazeSettings())
        XCTAssertEqual(decoded.configuration.overlay.layers.count, 0)
    }

    func testPipelineConfigurationRoundTripsWithEveryNewField() throws {
        var config = PipelineConfiguration()
        config.gaze.strength = 0.4
        config.gaze.verticalBias = -0.3
        config.background.kind = .video
        config.background.assetPath = "/tmp/loop.mov"
        config.background.color = RGBColor(red: 0.1, green: 0.2, blue: 0.3)
        config.overlay.layers = [
            OverlayLayer(name: "hat", assetPath: "/tmp/hat.png", placement: .front),
            OverlayLayer(name: "set", sourceKind: .video, assetPath: "/tmp/set.mov",
                         placement: .behind, keyMode: .chroma),
        ]
        config.flags[.gaze] = StageFlags(enabled: true, pinned: true)
        config.flags[.background] = StageFlags(enabled: true)
        config.flags[.overlay] = StageFlags(enabled: true)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PipelineConfiguration.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertTrue(decoded.flags(for: .gaze).pinned)
        XCTAssertEqual(decoded.overlay.layers.count, 2)
    }
}
