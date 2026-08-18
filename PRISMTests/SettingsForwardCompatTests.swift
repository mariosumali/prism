// SettingsForwardCompatTests.swift
// PRISMTests
//
// Decodes JSON captured from the build BEFORE the settings surface grew, and
// asserts that every field a user could have saved back then still arrives
// intact, and that every field added since takes its documented default.
//
// A same-build round-trip — encode this struct, decode it, compare — cannot
// catch the failure this file exists for. Encoding and decoding both walk the
// same CodingKeys, so a key forgotten in both halves round-trips perfectly
// while silently discarding the value in every file already on disk. The only
// way to see that is to decode JSON the current build did not write, which is
// what the fixtures below are: literal captures of the old encoded shape.
//
// If a fixture ever needs editing to make this suite pass, the change that
// prompted it is a preset-format break and every user's saved setup is the
// thing being edited.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class SettingsForwardCompatTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - PipelineConfiguration

    /// Defaults as the pre-foundation build encoded them. Note the shape of
    /// `flags`: JSONEncoder writes a dictionary whose key is neither String
    /// nor Int as a flat alternating array, and StageID is a String *enum*,
    /// not a String — so this is an array, and it has to stay one.
    private let configFixture = #"""
    {
      "adjust" : {
        "contrast" : 1,
        "exposureEV" : 0,
        "saturation" : 1,
        "temperature" : 0,
        "vignette" : 0
      },
      "background" : {
        "color" : { "blue" : 0.13, "green" : 0.11, "red" : 0.1 },
        "edgeSoftness" : 0.3,
        "fillMode" : "fill",
        "kind" : "image",
        "lightWrap" : 0.25,
        "maskContrast" : 1.4
      },
      "blur" : { "quality" : "balanced", "radius" : 18 },
      "flags" : [
        "background", { "enabled" : false, "pinned" : false },
        "retouch", { "enabled" : false, "pinned" : false },
        "blur", { "enabled" : false, "pinned" : false },
        "adjust", { "enabled" : false, "pinned" : false },
        "overlay", { "enabled" : false, "pinned" : false },
        "geometry", { "enabled" : false, "pinned" : false },
        "gaze", { "enabled" : false, "pinned" : false },
        "lut", { "enabled" : false, "pinned" : false },
        "style", { "enabled" : false, "pinned" : false }
      ],
      "format" : { "frameRate" : 30, "height" : 1080, "width" : 1920 },
      "gaze" : {
        "feather" : 0.25,
        "maxShift" : 0.5,
        "smoothing" : 0.8,
        "strength" : 0.75,
        "verticalBias" : 1
      },
      "geometry" : {
        "autoFrame" : false,
        "cropAspect" : "free",
        "mirror" : "none",
        "orientation" : 0,
        "panX" : 0,
        "panY" : 0,
        "rotationDegrees" : 0,
        "zoom" : 1
      },
      "latencyPolicy" : "balanced",
      "lut" : { "lutName" : "Neutral", "strength" : 1 },
      "overlay" : {
        "layers" : [
          {
            "assetPath" : "\/tmp\/hat.png",
            "id" : "11111111-2222-3333-4444-555555555555",
            "isEnabled" : true,
            "keyColor" : { "blue" : 0.1, "green" : 0.7, "red" : 0 },
            "keyMode" : "none",
            "lumaHigh" : 0.25,
            "lumaLow" : 0.05,
            "mirrored" : false,
            "name" : "Hat",
            "offsetX" : 0,
            "offsetY" : 0,
            "opacity" : 1,
            "placement" : "front",
            "rotationDegrees" : 0,
            "scale" : 1,
            "similarity" : 0.2,
            "smoothness" : 0.1,
            "sourceKind" : "image",
            "spill" : 0.5
          }
        ]
      },
      "style" : { "effect" : "normal", "intensity" : 1 }
    }
    """#

    /// The same pre-foundation shape carrying values a user actually chose.
    /// The all-defaults fixture alone would pass even if a decode line went
    /// missing, because the fallback and the saved value would agree.
    private let editedConfigFixture = #"""
    {
      "adjust" : {
        "contrast" : 1.4,
        "exposureEV" : -0.6,
        "saturation" : 0.8,
        "temperature" : 25,
        "vignette" : 0.3
      },
      "background" : {
        "assetPath" : "\/tmp\/room.mov",
        "color" : { "blue" : 0.4, "green" : 0.3, "red" : 0.2 },
        "edgeSoftness" : 0.5,
        "fillMode" : "letterbox",
        "kind" : "video",
        "lightWrap" : 0.6,
        "maskContrast" : 2.2
      },
      "blur" : { "quality" : "accurate", "radius" : 30 },
      "cameraID" : "cam-1",
      "flags" : [
        "lut", { "enabled" : true, "pinned" : true },
        "blur", { "enabled" : true, "pinned" : false }
      ],
      "format" : { "frameRate" : 60, "height" : 720, "width" : 1280 },
      "gaze" : {
        "feather" : 0.4,
        "maxShift" : 0.7,
        "smoothing" : 0.5,
        "strength" : 0.9,
        "verticalBias" : -0.5
      },
      "geometry" : {
        "autoFrame" : true,
        "cropAspect" : "r16x9",
        "mirror" : "horizontal",
        "orientation" : 90,
        "panX" : 0.25,
        "panY" : -0.5,
        "rotationDegrees" : 12,
        "zoom" : 1.8
      },
      "latencyPolicy" : "quality",
      "lut" : { "lutName" : "Cool", "strength" : 0.6 },
      "microphoneID" : "mic-1",
      "overlay" : {
        "layers" : [
          {
            "assetPath" : "\/tmp\/fire.mov",
            "id" : "11111111-2222-3333-4444-555555555555",
            "isEnabled" : true,
            "keyColor" : { "blue" : 0.2, "green" : 0.9, "red" : 0.1 },
            "keyMode" : "chroma",
            "lumaHigh" : 0.8,
            "lumaLow" : 0.15,
            "mirrored" : true,
            "name" : "Fire",
            "offsetX" : -0.3,
            "offsetY" : 0.4,
            "opacity" : 0.7,
            "placement" : "behind",
            "rotationDegrees" : -20,
            "scale" : 2.5,
            "similarity" : 0.45,
            "smoothness" : 0.35,
            "sourceKind" : "video",
            "spill" : 0.9
          }
        ]
      },
      "style" : { "effect" : "vhs", "intensity" : 0.4 }
    }
    """#

    func testPreFoundationConfigurationKeepsEveryFieldItHad() throws {
        let config = try decode(PipelineConfiguration.self, editedConfigFixture)

        XCTAssertEqual(config.adjust.exposureEV, -0.6)
        XCTAssertEqual(config.adjust.contrast, 1.4)
        XCTAssertEqual(config.adjust.saturation, 0.8)
        XCTAssertEqual(config.adjust.temperature, 25)
        XCTAssertEqual(config.adjust.vignette, 0.3)

        XCTAssertEqual(config.lut.lutName, "Cool")
        XCTAssertEqual(config.lut.strength, 0.6)

        XCTAssertEqual(config.blur.quality, .accurate)
        XCTAssertEqual(config.blur.radius, 30)

        XCTAssertEqual(config.geometry.zoom, 1.8)
        XCTAssertEqual(config.geometry.panX, 0.25)
        XCTAssertEqual(config.geometry.panY, -0.5)
        XCTAssertEqual(config.geometry.rotationDegrees, 12)
        XCTAssertEqual(config.geometry.orientation, .deg90)
        XCTAssertEqual(config.geometry.mirror, .horizontal)
        XCTAssertEqual(config.geometry.cropAspect, .r16x9)
        XCTAssertTrue(config.geometry.autoFrame)

        XCTAssertEqual(config.gaze.strength, 0.9)
        XCTAssertEqual(config.gaze.maxShift, 0.7)
        XCTAssertEqual(config.gaze.verticalBias, -0.5)
        XCTAssertEqual(config.gaze.smoothing, 0.5)
        XCTAssertEqual(config.gaze.feather, 0.4)

        XCTAssertEqual(config.background.kind, .video)
        XCTAssertEqual(config.background.assetPath, "/tmp/room.mov")
        XCTAssertEqual(config.background.color, RGBColor(red: 0.2, green: 0.3, blue: 0.4))
        XCTAssertEqual(config.background.fillMode, .letterbox)
        XCTAssertEqual(config.background.maskContrast, 2.2)
        XCTAssertEqual(config.background.edgeSoftness, 0.5)
        XCTAssertEqual(config.background.lightWrap, 0.6)

        XCTAssertEqual(config.style.effect, .vhs)
        XCTAssertEqual(config.style.intensity, 0.4)

        XCTAssertEqual(config.flags(for: .lut), StageFlags(enabled: true, pinned: true))
        XCTAssertEqual(config.flags(for: .blur), StageFlags(enabled: true, pinned: false))
        XCTAssertEqual(config.format, VideoFormat(width: 1280, height: 720, frameRate: 60))
        XCTAssertEqual(config.latencyPolicy, .quality)
        XCTAssertEqual(config.cameraID, "cam-1")
        XCTAssertEqual(config.microphoneID, "mic-1")

        let layer = try XCTUnwrap(config.overlay.layers.first)
        XCTAssertEqual(layer.id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(layer.name, "Fire")
        XCTAssertTrue(layer.isEnabled)
        XCTAssertEqual(layer.sourceKind, .video)
        XCTAssertEqual(layer.assetPath, "/tmp/fire.mov")
        XCTAssertEqual(layer.placement, .behind)
        XCTAssertEqual(layer.keyMode, .chroma)
        XCTAssertEqual(layer.keyColor, RGBColor(red: 0.1, green: 0.9, blue: 0.2))
        XCTAssertEqual(layer.similarity, 0.45)
        XCTAssertEqual(layer.smoothness, 0.35)
        XCTAssertEqual(layer.spill, 0.9)
        XCTAssertEqual(layer.lumaLow, 0.15)
        XCTAssertEqual(layer.lumaHigh, 0.8)
        XCTAssertEqual(layer.opacity, 0.7)
        XCTAssertEqual(layer.scale, 2.5)
        XCTAssertEqual(layer.offsetX, -0.3)
        XCTAssertEqual(layer.offsetY, 0.4)
        XCTAssertEqual(layer.rotationDegrees, -20)
        XCTAssertTrue(layer.mirrored)
    }

    /// The other half of the contract: a field the old build never wrote must
    /// arrive at its default, not at zero and not by failing the decode.
    func testConfigurationFieldsAddedSinceTakeTheirDefaults() throws {
        let config = try decode(PipelineConfiguration.self, configFixture)

        XCTAssertEqual(config.retouch, RetouchSettings())
        XCTAssertEqual(config.retouch.amount, 0.35)
        XCTAssertEqual(config.retouch.detail, 0.55)

        XCTAssertFalse(config.style.audioReactive)
        XCTAssertEqual(config.style.audioDepth, 0.7)

        let layer = try XCTUnwrap(config.overlay.layers.first)
        XCTAssertEqual(layer.text, OverlayTextStyle())
        XCTAssertNil(layer.liveFeed)
        XCTAssertEqual(layer.anchor, .frame)
        XCTAssertEqual(layer.facePoint, .aboveHead)
        XCTAssertFalse(layer.followsRoll)
    }

    /// The defaults fixture is also a statement about what the old build
    /// wrote: every one of these values came out of it verbatim, so a changed
    /// default here is a changed default for everyone already on disk.
    func testPreFoundationDefaultsStillDecodeToTheSameConfiguration() throws {
        var expected = PipelineConfiguration()
        expected.overlay.layers = [
            OverlayLayer(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                         name: "Hat", assetPath: "/tmp/hat.png"),
        ]
        XCTAssertEqual(try decode(PipelineConfiguration.self, configFixture), expected)
    }

    // MARK: - StudioSettings

    private let studioFixture = #"""
    {
      "away" : {
        "armsBufferOnFirstUse" : true,
        "crossfadeMs" : 400,
        "loopSeconds" : 4,
        "mutesAudio" : true
      },
      "connection" : {
        "addsLag" : true,
        "dropsFrames" : true,
        "lagMs" : 1200,
        "severity" : 0.6
      },
      "lag" : {
        "catchUpRate" : 2,
        "delayMs" : 3000,
        "delaysAudio" : true,
        "holdToLag" : true,
        "release" : "snapBack"
      },
      "panic" : {
        "backdropColor" : { "blue" : 0.13, "green" : 0.11, "red" : 0.1 },
        "freezes" : true,
        "mutes" : true,
        "swapsBackdrop" : true
      },
      "replay" : {
        "bufferSeconds" : 10,
        "isArmed" : false,
        "maxHeight" : 1080,
        "playbackRate" : 1.5,
        "returnToLiveAtEnd" : true
      },
      "voice" : { "amount" : 1, "effect" : "off", "lastUsedEffect" : "chipmunk" }
    }
    """#

    private let editedStudioFixture = #"""
    {
      "away" : {
        "armsBufferOnFirstUse" : false,
        "crossfadeMs" : 900,
        "loopSeconds" : 7,
        "mutesAudio" : false
      },
      "connection" : {
        "addsLag" : false,
        "dropsFrames" : false,
        "lagMs" : 800,
        "severity" : 0.9
      },
      "lag" : {
        "catchUpRate" : 3,
        "delayMs" : 5000,
        "delaysAudio" : false,
        "holdToLag" : false,
        "release" : "catchUp"
      },
      "panic" : {
        "backdropColor" : { "blue" : 0.5, "green" : 0.4, "red" : 0.3 },
        "backdropPath" : "\/tmp\/brb.png",
        "freezes" : false,
        "mutes" : true,
        "swapsBackdrop" : false
      },
      "replay" : {
        "bufferSeconds" : 25,
        "isArmed" : true,
        "maxHeight" : 720,
        "playbackRate" : 2.5,
        "returnToLiveAtEnd" : false
      },
      "voice" : { "amount" : 0.5, "effect" : "robot", "lastUsedEffect" : "alien" }
    }
    """#

    func testPreFoundationStudioSettingsKeepEveryFieldTheyHad() throws {
        let studio = try decode(StudioSettings.self, editedStudioFixture)

        XCTAssertTrue(studio.replay.isArmed)
        XCTAssertEqual(studio.replay.bufferSeconds, 25)
        XCTAssertEqual(studio.replay.playbackRate, 2.5)
        XCTAssertEqual(studio.replay.maxHeight, 720)
        XCTAssertFalse(studio.replay.returnToLiveAtEnd)

        XCTAssertEqual(studio.away.loopSeconds, 7)
        XCTAssertEqual(studio.away.crossfadeMs, 900)
        XCTAssertFalse(studio.away.mutesAudio)
        XCTAssertFalse(studio.away.armsBufferOnFirstUse)

        XCTAssertFalse(studio.panic.freezes)
        XCTAssertTrue(studio.panic.mutes)
        XCTAssertFalse(studio.panic.swapsBackdrop)
        XCTAssertEqual(studio.panic.backdropPath, "/tmp/brb.png")
        XCTAssertEqual(studio.panic.backdropColor, RGBColor(red: 0.3, green: 0.4, blue: 0.5))

        XCTAssertEqual(studio.lag.delayMs, 5000)
        XCTAssertFalse(studio.lag.delaysAudio)
        XCTAssertEqual(studio.lag.release, .catchUp)
        XCTAssertEqual(studio.lag.catchUpRate, 3)
        XCTAssertFalse(studio.lag.holdToLag)

        XCTAssertEqual(studio.voice.effect, .robot)
        XCTAssertEqual(studio.voice.lastUsedEffect, .alien)
        XCTAssertEqual(studio.voice.amount, 0.5)

        XCTAssertEqual(studio.connection.severity, 0.9)
        XCTAssertFalse(studio.connection.dropsFrames)
        XCTAssertFalse(studio.connection.addsLag)
        XCTAssertEqual(studio.connection.lagMs, 800)
    }

    /// Everything the settings surface gained has to land inert, on a file
    /// that predates all of it — that is what makes the upgrade invisible.
    func testStudioSettingsAddedSinceLandInert() throws {
        let studio = try decode(StudioSettings.self, studioFixture)

        XCTAssertEqual(studio.capture, CaptureSettings())
        XCTAssertEqual(studio.capture.format, .png)
        XCTAssertNil(studio.capture.folderPath)
        XCTAssertEqual(studio.capture.countdownSeconds, 0)
        XCTAssertFalse(studio.capture.prefersSharp)

        XCTAssertFalse(studio.apps.isEnabled)
        XCTAssertEqual(studio.apps.defaultAccess, .allow)
        XCTAssertTrue(studio.apps.rules.isEmpty)

        XCTAssertEqual(studio.cleanup.mode, .off)
        XCTAssertFalse(studio.micWatch.isEnabled)
        XCTAssertEqual(studio.presence.action, PresenceAction.none)
        XCTAssertFalse(studio.presence.isActive)

        XCTAssertFalse(studio.prompter.isEnabled)
        XCTAssertTrue(studio.prompter.script.isEmpty)
        XCTAssertFalse(studio.prompter.isActive)

        XCTAssertFalse(studio.gestures.isEnabled)
        XCTAssertFalse(studio.gestures.isActive)
        XCTAssertEqual(studio.gestures.bindings.count, HandPose.allCases.count)
    }

    func testPreFoundationStudioDefaultsStillDecodeToTheSameSettings() throws {
        XCTAssertEqual(try decode(StudioSettings.self, studioFixture), StudioSettings())
    }

    // MARK: - Preset

    /// A whole preset as the pre-foundation build exported it — the file
    /// people actually share, hotkey and all.
    private let presetFixture = #"""
    {
      "configuration" : {
        "adjust" : {
          "contrast" : 1,
          "exposureEV" : 0,
          "saturation" : 1,
          "temperature" : 0,
          "vignette" : 0
        },
        "background" : {
          "color" : { "blue" : 0.13, "green" : 0.11, "red" : 0.1 },
          "edgeSoftness" : 0.3,
          "fillMode" : "fill",
          "kind" : "image",
          "lightWrap" : 0.25,
          "maskContrast" : 1.4
        },
        "blur" : { "quality" : "balanced", "radius" : 18 },
        "flags" : [
          "geometry", { "enabled" : false, "pinned" : false },
          "retouch", { "enabled" : false, "pinned" : false },
          "adjust", { "enabled" : false, "pinned" : false },
          "lut", { "enabled" : true, "pinned" : false },
          "gaze", { "enabled" : false, "pinned" : false },
          "background", { "enabled" : false, "pinned" : false },
          "overlay", { "enabled" : false, "pinned" : false },
          "style", { "enabled" : false, "pinned" : false },
          "blur", { "enabled" : false, "pinned" : false }
        ],
        "format" : { "frameRate" : 30, "height" : 1080, "width" : 1920 },
        "gaze" : {
          "feather" : 0.25,
          "maxShift" : 0.5,
          "smoothing" : 0.8,
          "strength" : 0.75,
          "verticalBias" : 1
        },
        "geometry" : {
          "autoFrame" : false,
          "cropAspect" : "free",
          "mirror" : "none",
          "orientation" : 0,
          "panX" : 0,
          "panY" : 0,
          "rotationDegrees" : 0,
          "zoom" : 1
        },
        "latencyPolicy" : "balanced",
        "lut" : { "lutName" : "Neutral", "strength" : 1 },
        "overlay" : { "layers" : [] },
        "style" : { "effect" : "normal", "intensity" : 1 }
      },
      "hotkey" : {
        "command" : true,
        "control" : false,
        "keyCode" : 18,
        "option" : true,
        "shift" : false
      },
      "id" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "isBuiltIn" : true,
      "name" : "Meeting"
    }
    """#

    func testPreFoundationPresetStillImports() throws {
        let preset = try decode(Preset.self, presetFixture)

        XCTAssertEqual(preset.id, UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        XCTAssertEqual(preset.name, "Meeting")
        XCTAssertTrue(preset.isBuiltIn)
        XCTAssertEqual(preset.hotkey, HotkeyCombo(keyCode: 18, option: true, command: true))
        XCTAssertEqual(preset.configuration.flags(for: .lut),
                       StageFlags(enabled: true, pinned: false))
        XCTAssertEqual(preset.configuration.lut.lutName, LUTSettings.neutralName)
        XCTAssertEqual(preset.configuration.retouch, RetouchSettings())
        XCTAssertFalse(preset.configuration.style.audioReactive)
    }
}
