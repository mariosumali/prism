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
    ///
    /// It names eight stages, because that build's `StageID` had eight it
    /// could switch. Anything this programme added is absent here on purpose:
    /// a name that build could not write is a name no file on disk carries,
    /// and pencilling one in would make this fixture a capture of ourselves.
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
        // Zero, not defaultAmount: the stage ships off and its knob ships
        // inert, so a configuration written before retouch existed must come
        // back meaning "no retouch" rather than "retouch, ready to go".
        XCTAssertEqual(config.retouch.amount, 0)
        XCTAssertEqual(config.retouch.detail, 0.55)

        // A stage the old table could not name arrives absent, not off-by-
        // accident: every reader goes through `flags(for:)`, which reads an
        // absent stage as switched off, so the ninth switch means exactly
        // what it should on a file written before it existed.
        XCTAssertNil(config.flags[.retouch])
        XCTAssertEqual(config.flags(for: .retouch), StageFlags())

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
        // The one honest difference: that build's table had eight stages, so
        // the file has eight and today's default table has nine. The gap is
        // the assertion, not a mismatch to paper over — an absent stage reads
        // as off, and the alternative was editing the fixture to claim the
        // old build wrote a stage name it had no case for.
        expected.flags[.retouch] = nil
        XCTAssertEqual(try decode(PipelineConfiguration.self, configFixture), expected)
    }

    /// The suite is only evidence while its fixtures are captures rather than
    /// constructions, and the cheapest way to lose that is to pencil a new
    /// stage into an old `flags` array so an equality assertion goes green.
    /// This walks the fixtures as raw JSON and refuses any stage name the
    /// pre-programme build had no case for — the edit the header forbids,
    /// caught as a failure instead of as a review comment.
    func testFixturesNameOnlyStagesThePreFoundationBuildCouldWrite() throws {
        for (label, json) in [("configuration", configFixture),
                              ("edited configuration", editedConfigFixture),
                              ("preset", presetFixture)] {
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                "\(label): fixture is not a JSON object")
            // The preset fixture wraps its configuration; the others are one.
            let configuration = (root["configuration"] as? [String: Any]) ?? root
            XCTAssertNil(configuration["stageFlags"],
                         "\(label): stageFlags is this build's shape, not that one's")
            let array = try XCTUnwrap(configuration["flags"] as? [Any],
                                      "\(label): flags is a flat alternating array")
            for name in array.compactMap({ $0 as? String }) {
                XCTAssertNotNil(PreFoundationStageID(rawValue: name),
                                "\(label): '\(name)' is a stage that build could not name")
            }
        }
    }

    /// And the two all-defaults fixtures carry that build's whole table, so
    /// the decode they pin is a full one rather than a lucky subset.
    func testDefaultFixturesCarryThePreFoundationTableWhole() throws {
        for (label, json) in [("configuration", configFixture),
                              ("preset", presetFixture)] {
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let configuration = (root["configuration"] as? [String: Any]) ?? root
            let array = try XCTUnwrap(configuration["flags"] as? [Any])
            let names = Set(array.compactMap { $0 as? String })
            XCTAssertEqual(names,
                           Set(PipelineConfiguration.legacyFlagStages.map(\.rawValue)),
                           "\(label): the old default table was these stages exactly")
        }
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

        // §5.32/§5.33. The fixture predates both, so this is the real
        // question rather than a round-trip: a settings file written before
        // these existed must still decode, and must land with transcription
        // off, no far end, and no AI provider — a user who upgrades does not
        // acquire a feature that listens to their calls.
        XCTAssertFalse(studio.meeting.transcribes)
        XCTAssertFalse(studio.meeting.isActive)
        XCTAssertEqual(studio.meeting.farEnd, .off)
        XCTAssertFalse(studio.meeting.wantsFarEnd)
        XCTAssertNil(studio.meeting.farEndBundleID)
        XCTAssertEqual(studio.meeting.model, SpeechModelCatalog.defaultModel)
        XCTAssertTrue(studio.meeting.savesTranscript)

        XCTAssertEqual(studio.assistant.provider, .none)
        XCTAssertFalse(studio.assistant.isEnabled)
        XCTAssertFalse(studio.assistant.isActive)
        XCTAssertFalse(studio.assistant.providerIsConfigured)
        XCTAssertTrue(studio.assistant.aboutMe.isEmpty)
    }

    /// §5.33: the assistant panel's open state is hard-coded out of the
    /// decoder rather than merely defaulting off, so a file that *does*
    /// carry `isEnabled: true` still decodes to false.
    ///
    /// PRISM launches at login for most people, and a panel that restored
    /// itself would put yesterday's answer over whatever they actually
    /// opened their Mac to do — floating, on every space. A default would
    /// not survive the first time somebody quit with the panel open.
    func testAssistantPanelNeverRestoresItselfEvenWhenTheFileSaysItWasOpen() throws {
        let json = #"{"isEnabled":true,"provider":"anthropic","aboutMe":"I ship a virtual camera."}"#
        let settings = try decode(AssistantSettings.self, json)

        XCTAssertFalse(settings.isEnabled, "a stored open panel must not reopen itself")
        XCTAssertFalse(settings.isActive)
        // Everything else on the same object still decodes, so this is a
        // deliberate exception rather than a broken decoder.
        XCTAssertEqual(settings.provider, .anthropic)
        XCTAssertEqual(settings.aboutMe, "I ship a virtual camera.")
    }

    /// §5.34: a file from before live insights decodes with the mode off,
    /// the default pace and every kind.
    func testPreInsightsAssistantSettingsDecodeWithTheModeOff() throws {
        let json = #"{"provider":"ollama","ollamaModel":"llama3"}"#
        let settings = try decode(AssistantSettings.self, json)

        XCTAssertFalse(settings.liveInsights)
        XCTAssertEqual(settings.insightPace, .balanced)
        XCTAssertEqual(settings.insightKinds, InsightKind.defaultSet)
        XCTAssertFalse(settings.wantsLiveInsights)
    }

    /// A kind or a pace this build does not know — a file from a later
    /// build, or a hand-edit — is skipped, not fatal: the kinds it does
    /// know survive, and the pace falls back.
    func testUnknownInsightKindsAndPacesAreSkippedNotFatal() throws {
        let json = #"{"liveInsights":true,"insightPace":"frantic","insightKinds":["term","hologram","commitment"]}"#
        let settings = try decode(AssistantSettings.self, json)

        XCTAssertTrue(settings.liveInsights)
        XCTAssertEqual(settings.insightPace, .balanced)
        XCTAssertEqual(settings.insightKinds, [.term, .commitment])
    }

    /// The mode is a preference and round-trips. The panel's open state
    /// still does not, so a restored `liveInsights: true` has nothing to arm
    /// at launch — the three switches are three switches on purpose.
    func testLiveInsightsRoundTripsButCannotArmWithoutThePanel() throws {
        var settings = AssistantSettings()
        settings.isEnabled = true
        settings.provider = .ollama
        settings.ollamaModel = "llama3"
        settings.liveInsights = true
        settings.insightPace = .eager
        settings.insightKinds = [.answer]
        XCTAssertTrue(settings.wantsLiveInsights)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: data)

        XCTAssertTrue(decoded.liveInsights)
        XCTAssertEqual(decoded.insightPace, .eager)
        XCTAssertEqual(decoded.insightKinds, [.answer])
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertFalse(decoded.wantsLiveInsights, "a restored mode must not be able to send at login")
    }

    /// A partially-written meeting settings object — the shape a downgrade
    /// or a hand-edit produces — keeps what it names and defaults the rest,
    /// rather than throwing the whole struct away.
    func testPartialMeetingSettingsKeepWhatTheyNameAndDefaultTheRest() throws {
        let json = #"{"farEnd":"everything","farEndLabel":"The client"}"#
        let settings = try decode(MeetingSettings.self, json)

        XCTAssertEqual(settings.farEnd, .everything)
        XCTAssertEqual(settings.resolvedFarEndLabel, "The client")
        XCTAssertFalse(settings.transcribes)
        XCTAssertEqual(settings.model, SpeechModelCatalog.defaultModel)
        XCTAssertEqual(settings.clampedSilenceRMS, 0.005, accuracy: 1e-9)
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

    // MARK: - The other direction: the PREVIOUS build reading this one

    // A preset is a sharing format (§5.5), so compatibility is not only about
    // reading old files — it is about the file this build exports landing in
    // the build the person on the other end is running. The stage table is
    // the one field where getting that wrong is silent: `flags` is a
    // dictionary keyed by a String *enum*, JSONEncoder writes it as a flat
    // alternating array, and decoding that array is all-or-nothing. A single
    // stage key the reader's enum has no case for throws for the whole
    // dictionary, the tolerant decode substitutes an empty one, and the
    // preset arrives with every effect switched off and no error anywhere.

    /// The pre-programme build's stage identifier, verbatim: the same String
    /// enum without the case this programme added.
    private enum PreFoundationStageID: String, Codable, Hashable {
        case clip, replay, freeze, gaze, geometry, adjust, lut, blur
        case background, overlay, style, connection, outputFit
    }

    private struct PreFoundationFlags: Codable, Equatable {
        var enabled = false
        var pinned = false
    }

    /// Only the field under test, decoded exactly the way that build decoded
    /// it — tolerantly, falling back to an empty table.
    private struct PreFoundationConfiguration: Decodable {
        var flags: [PreFoundationStageID: PreFoundationFlags] = [:]
        enum CodingKeys: String, CodingKey { case flags }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let table = [PreFoundationStageID: PreFoundationFlags].self
            flags = ((try? container.decodeIfPresent(table, forKey: .flags)) ?? nil) ?? [:]
        }
    }

    private struct PreFoundationPreset: Decodable {
        var name: String
        var configuration: PreFoundationConfiguration
    }

    func testAPresetFromThisBuildStillCarriesItsSwitchesIntoThePreviousOne() throws {
        var configuration = PipelineConfiguration()
        configuration.flags[.lut] = StageFlags(enabled: true, pinned: true)
        configuration.flags[.blur] = StageFlags(enabled: true, pinned: false)
        configuration.flags[.retouch] = StageFlags(enabled: true, pinned: false)
        let data = try JSONEncoder().encode(
            Preset(name: "Studio", configuration: configuration))

        let old = try JSONDecoder().decode(PreFoundationPreset.self, from: data)
        XCTAssertEqual(old.configuration.flags[.lut],
                       PreFoundationFlags(enabled: true, pinned: true),
                       "the shared preset arrived with every effect switched off")
        XCTAssertEqual(old.configuration.flags[.blur],
                       PreFoundationFlags(enabled: true, pinned: false))
        XCTAssertEqual(old.configuration.flags[.style], PreFoundationFlags())
        XCTAssertEqual(old.configuration.flags.count,
                       PipelineConfiguration.legacyFlagStages.count,
                       "every stage that build can name, and only those")
    }

    /// The same rule in the other direction: a stage from a build newer than
    /// this one costs its own switch and nothing else.
    func testAStageThisBuildHasNeverHeardOfCostsOnlyItsOwnSwitch() throws {
        let json = #"""
        {
          "stageFlags" : {
            "lut" : { "enabled" : true, "pinned" : false },
            "holograph" : { "enabled" : true, "pinned" : true },
            "blur" : { "enabled" : true, "pinned" : false }
          }
        }
        """#
        let config = try decode(PipelineConfiguration.self, json)
        XCTAssertEqual(config.flags(for: .lut), StageFlags(enabled: true, pinned: false))
        XCTAssertEqual(config.flags(for: .blur), StageFlags(enabled: true, pinned: false))
        XCTAssertEqual(config.flags.count, 2, "the unknown stage took the table down")
    }

    /// And the stage the old array cannot carry still survives a round trip
    /// through this build's own file — it travels in the other shape.
    func testEveryStageSurvivesThisBuildsOwnRoundTrip() throws {
        var configuration = PipelineConfiguration()
        configuration.flags[.retouch] = StageFlags(enabled: true, pinned: true)
        configuration.flags[.gaze] = StageFlags(enabled: true, pinned: false)
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(PipelineConfiguration.self, from: data),
                       configuration)
    }
}
