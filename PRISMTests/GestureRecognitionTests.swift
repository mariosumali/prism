// GestureRecognitionTests.swift
// PRISMTests
//
// Hand gestures (§5.31), held to the only standard that matters: what it
// takes to make one fire, and how many things have to go right at once.
//
// The tests are lopsided on purpose, and so is the feature. A gesture that
// does not fire costs a raised hand and a second try. A gesture that fires by
// itself mutes a call nobody asked to mute — and, if panic were ever bound by
// default, blanks a camera mid-sentence. So most of what is pinned here is
// the recogniser declining: hands in transit, poses held briefly, readings
// under the confidence floor, a pose held through a cooldown, and panic
// specifically, which ships bound to nothing and carries its own longer hold
// even once somebody binds it.
//
// The geometry is tested through `HandPoseClassifier` rather than through
// Vision: a `VNRecognizedPoint` cannot be constructed outside the framework,
// so the joints arrive as plain points and the classifier is pure.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import XCTest

final class GestureRecognitionTests: XCTestCase {

    // MARK: - Hand shapes

    /// A hand pointing up the frame, with each finger either reaching past
    /// its middle joint or curled back inside it. Distances from the wrist
    /// are what the classifier reads, so this is enough to make any of the
    /// three poses (and any of the shapes that are none of them).
    private func hand(index: Bool, middle: Bool, ring: Bool, little: Bool,
                      reach: CGFloat = 1) -> [HandJoint: CGPoint] {
        let wrist = CGPoint(x: 0.5, y: 0.1)
        var joints: [HandJoint: CGPoint] = [.wrist: wrist]
        let fingers: [(tip: HandJoint, pip: HandJoint, x: CGFloat, extended: Bool)] = [
            (.indexTip, .indexPIP, 0.44, index),
            (.middleTip, .middlePIP, 0.48, middle),
            (.ringTip, .ringPIP, 0.52, ring),
            (.littleTip, .littlePIP, 0.56, little),
        ]
        for finger in fingers {
            let knuckle = CGPoint(x: finger.x, y: 0.4)
            joints[finger.pip] = knuckle
            // Extended: well past the knuckle. Folded: well inside it.
            let tipY: CGFloat = finger.extended ? 0.4 + 0.3 * reach : 0.28
            joints[finger.tip] = CGPoint(x: finger.x, y: tipY)
        }
        return joints
    }

    func testTheThreePosesAreRecognised() {
        XCTAssertEqual(HandPoseClassifier.classify(
            joints: hand(index: true, middle: true, ring: true, little: true)), .palm)
        XCTAssertEqual(HandPoseClassifier.classify(
            joints: hand(index: true, middle: true, ring: false, little: false)), .victory)
        XCTAssertEqual(HandPoseClassifier.classify(
            joints: hand(index: false, middle: false, ring: false, little: false)), .fist)
    }

    /// Everything else is nothing. A classifier that always names its closest
    /// match turns every gesticulation into an input, which is the failure
    /// this whole feature is one long argument with.
    func testShapesOutsideTheCatalogueAreNotPoses() {
        let shapes: [(Bool, Bool, Bool, Bool)] = [
            (true, false, false, false),    // pointing
            (false, true, true, true),      // index tucked
            (true, true, true, false),      // three up
            (false, false, true, true),     // the mirror of Victory
        ]
        for shape in shapes {
            XCTAssertNil(HandPoseClassifier.classify(
                joints: hand(index: shape.0, middle: shape.1,
                             ring: shape.2, little: shape.3)),
                         "\(shape) was named a pose")
        }
    }

    /// A hand between shapes — fingers neither reaching nor curled — is not
    /// read at all. This is what stops a hand on its way past the lens
    /// resolving into a pose in transit.
    func testAHandBetweenShapesIsNotRead() {
        var joints = hand(index: true, middle: true, ring: true, little: true)
        // Tips sitting almost exactly on their knuckles' radius.
        for (tip, pip) in [(HandJoint.indexTip, HandJoint.indexPIP),
                           (.middleTip, .middlePIP),
                           (.ringTip, .ringPIP),
                           (.littleTip, .littlePIP)] {
            joints[tip] = CGPoint(x: joints[pip]!.x, y: joints[pip]!.y + 0.01)
        }
        XCTAssertNil(HandPoseClassifier.classify(joints: joints))
    }

    /// A partly seen hand is not a pose. Guessing the missing finger is
    /// exactly how a wave becomes a Victory.
    func testAPartlySeenHandIsNotAPose() {
        var joints = hand(index: true, middle: true, ring: false, little: false)
        joints[.ringTip] = nil
        XCTAssertNil(HandPoseClassifier.classify(joints: joints))

        var noWrist = hand(index: false, middle: false, ring: false, little: false)
        noWrist[.wrist] = nil
        XCTAssertNil(HandPoseClassifier.classify(joints: noWrist))
    }

    /// The radial test is invariant to how the hand is rolled in the frame,
    /// which is the one thing a webcam guarantees will vary. A Victory read
    /// upside down is still a Victory.
    func testThePosesSurviveBeingRotated() {
        let upright = hand(index: true, middle: true, ring: false, little: false)
        let centre = CGPoint(x: 0.5, y: 0.4)
        for degrees in stride(from: 0.0, to: 360.0, by: 45) {
            let radians = degrees * .pi / 180
            var rotated: [HandJoint: CGPoint] = [:]
            for (joint, point) in upright {
                let dx = point.x - centre.x, dy = point.y - centre.y
                rotated[joint] = CGPoint(
                    x: centre.x + dx * cos(radians) - dy * sin(radians),
                    y: centre.y + dx * sin(radians) + dy * cos(radians))
            }
            XCTAssertEqual(HandPoseClassifier.classify(joints: rotated), .victory,
                           "rolled \(Int(degrees))°")
        }
    }

    // MARK: - The watch

    private func settings(action: GestureAction = .toggleMute,
                          for pose: HandPose = .palm) -> GestureSettings {
        var settings = GestureSettings()
        settings.isEnabled = true
        settings.bindings = HandPose.allCases.map {
            GestureBinding(pose: $0,
                           action: $0 == pose ? action : .none,
                           isEnabled: $0 == pose)
        }
        return settings
    }

    /// Feeds a pose at 10 Hz — the rate the recogniser runs at unopposed —
    /// and returns every firing.
    @discardableResult
    private func hold(_ watch: GestureWatch, pose: HandPose?, seconds: Double,
                      settings: GestureSettings, confidence: Double = 0.95,
                      from start: Date) -> [(pose: HandPose, at: Date)] {
        var fired: [(HandPose, Date)] = []
        var elapsed = 0.0
        while elapsed < seconds - 1e-9 {
            elapsed += 0.1
            let now = start.addingTimeInterval(elapsed)
            if let hit = watch.observe(pose: pose, confidence: confidence,
                                       settings: settings, at: now) {
                fired.append((hit, now))
            }
        }
        return fired.map { (pose: $0.0, at: $0.1) }
    }

    func testAHeldPoseFiresOnceItHasBeenHeldLongEnough() {
        let watch = GestureWatch()
        let config = settings()
        let start = Date()
        XCTAssertEqual(hold(watch, pose: .palm, seconds: 0.5,
                            settings: config, from: start).count, 0,
                       "half the hold is not the hold")
        let fired = hold(watch, pose: .palm, seconds: 1,
                         settings: config,
                         from: start.addingTimeInterval(0.5))
        XCTAssertEqual(fired.map(\.pose), [.palm])
    }

    /// The debounce: one held pose is one action, not one per sighting.
    func testAPoseHeldForeverFiresExactlyOnce() {
        let watch = GestureWatch()
        let fired = hold(watch, pose: .palm, seconds: 30,
                         settings: settings(), from: Date())
        XCTAssertEqual(fired.count, 1, "a held palm fired \(fired.count) times")
    }

    /// …and the latch is only released by seeing the pose actually end, so
    /// the second firing needs a fresh hold on top of the cooldown.
    func testTheSamePoseFiresAgainOnlyAfterItHasBeenReleased() {
        let watch = GestureWatch()
        let config = settings()
        var now = Date()
        hold(watch, pose: .palm, seconds: 5, settings: config, from: now)
        now += 5
        hold(watch, pose: nil, seconds: 3, settings: config, from: now)
        now += 3
        let again = hold(watch, pose: .palm, seconds: 2, settings: config, from: now)
        XCTAssertEqual(again.count, 1, "a released and re-made pose must work")
    }

    /// The cooldown, across poses: a gesture cannot be followed instantly by
    /// another one — including the one that would undo it, which is how a
    /// flickering recogniser turns into a strobing mute.
    func testNothingFiresInsideTheCooldown() {
        let watch = GestureWatch()
        var config = GestureSettings()
        config.isEnabled = true
        config.cooldownSeconds = 5
        config.bindings = [
            GestureBinding(pose: .palm, action: .toggleMute, isEnabled: true),
            GestureBinding(pose: .victory, action: .toggleFreeze, isEnabled: true),
            GestureBinding(pose: .fist),
        ]
        var now = Date()
        XCTAssertEqual(hold(watch, pose: .palm, seconds: 2,
                            settings: config, from: now).count, 1)
        now += 2
        // A different pose, held well past its dwell, inside the cooldown.
        XCTAssertEqual(hold(watch, pose: .victory, seconds: 2,
                            settings: config, from: now).count, 0)
        now += 2
        // And once the cooldown lapses it still needs its own fresh hold,
        // rather than firing the instant the refractory period ends.
        let after = hold(watch, pose: .victory, seconds: 3,
                         settings: config, from: now)
        XCTAssertEqual(after.count, 1)
        XCTAssertGreaterThanOrEqual(after[0].at.timeIntervalSince(now), 0.8,
                                    "it fired the moment the cooldown lapsed")
    }

    /// The confidence floor. Below it there is no observation, so a hand
    /// Vision is unsure about cannot accumulate a dwell however long it
    /// stays there.
    func testAReadingUnderTheConfidenceFloorIsNotAnObservation() {
        let watch = GestureWatch()
        var config = settings()
        config.confidence = 0.9
        let fired = hold(watch, pose: .palm, seconds: 10, settings: config,
                         confidence: 0.7, from: Date())
        XCTAssertEqual(fired.count, 0)
    }

    /// And one flaky sighting in the middle of a hold restarts it, rather
    /// than being smoothed over. Strict in the safe direction.
    func testALowConfidenceSightingBreaksTheHold() {
        let watch = GestureWatch()
        let config = settings()
        var now = Date()
        hold(watch, pose: .palm, seconds: 0.7, settings: config, from: now)
        now += 0.7
        _ = watch.observe(pose: .palm, confidence: 0.2, settings: config, at: now)
        // 0.7 s more would have been well past the 0.8 s hold if the dwell
        // had survived the gap.
        XCTAssertEqual(hold(watch, pose: .palm, seconds: 0.7,
                            settings: config, from: now).count, 0)
    }

    /// A pose that changes to another one starts that one's dwell from zero.
    func testChangingPoseRestartsTheDwell() {
        let watch = GestureWatch()
        var config = GestureSettings()
        config.isEnabled = true
        config.bindings = [
            GestureBinding(pose: .palm, action: .toggleMute, isEnabled: true),
            GestureBinding(pose: .victory, action: .toggleFreeze, isEnabled: true),
            GestureBinding(pose: .fist),
        ]
        var now = Date()
        hold(watch, pose: .palm, seconds: 0.7, settings: config, from: now)
        now += 0.7
        XCTAssertEqual(hold(watch, pose: .victory, seconds: 0.4,
                            settings: config, from: now).count, 0,
                       "the previous pose's dwell carried over")
    }

    /// A gap in the sightings is not evidence a hand was held through it.
    /// Four separate observations of the same pose are needed even after a
    /// nap, rather than one.
    func testAGapInTheSightingsCannotSatisfyTheHoldOnItsOwn() {
        let watch = GestureWatch()
        let config = settings()
        let start = Date()
        XCTAssertNil(watch.observe(pose: .palm, confidence: 0.95,
                                   settings: config, at: start))
        XCTAssertNil(watch.observe(pose: .palm, confidence: 0.95,
                                   settings: config,
                                   at: start.addingTimeInterval(600)),
                     "ten minutes between two sightings satisfied a 0.8 s hold")
    }

    func testResetForgetsAHalfHeldPose() {
        let watch = GestureWatch()
        let config = settings()
        var now = Date()
        hold(watch, pose: .palm, seconds: 0.7, settings: config, from: now)
        watch.reset()
        now += 0.7
        XCTAssertEqual(hold(watch, pose: .palm, seconds: 0.4,
                            settings: config, from: now).count, 0)
    }

    // MARK: - Panic

    /// The rule the whole feature is judged on: a gesture must never fire
    /// panic because somebody gestured while talking. Two independent
    /// defences, and this is the first — nothing is bound out of the box, so
    /// the master switch on its own cannot arm anything at all.
    func testPanicIsBoundToNothingOutOfTheBox() {
        var shipped = GestureSettings()
        XCTAssertFalse(shipped.isEnabled, "the master switch ships off")
        XCTAssertFalse(shipped.isActive)
        XCTAssertTrue(shipped.bindings.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(shipped.bindings.allSatisfy { $0.action == .none })

        shipped.isEnabled = true
        XCTAssertFalse(shipped.isActive,
                       "the master switch alone must not make a pose do anything")
        for pose in HandPose.allCases {
            XCTAssertEqual(shipped.action(for: pose), .none)
        }
    }

    /// The second defence: even once somebody binds it deliberately, panic
    /// takes its own longer hold — and the general hold slider, which goes
    /// down to 0.3 s, cannot lower it.
    func testPanicIsHeldLongerThanEverythingElse() {
        var config = GestureSettings()
        config.holdSeconds = 0.3
        XCTAssertEqual(config.dwellSeconds(for: .toggleMute), 0.3)
        XCTAssertEqual(config.dwellSeconds(for: .panic),
                       GestureSettings.panicHoldFloorSeconds)
        XCTAssertGreaterThan(GestureSettings.panicHoldFloorSeconds,
                             config.clampedHoldSeconds)

        // …and a hold longer than the floor is honoured rather than capped.
        config.holdSeconds = 3
        XCTAssertEqual(config.dwellSeconds(for: .panic), 3)
    }

    func testPanicNeedsItsOwnHoldEvenWhenTheSliderIsAtTheMinimum() {
        let watch = GestureWatch()
        var config = GestureSettings()
        config.isEnabled = true
        config.holdSeconds = 0.3
        config.bindings = [
            GestureBinding(pose: .fist, action: .panic, isEnabled: true),
            GestureBinding(pose: .palm),
            GestureBinding(pose: .victory),
        ]
        let start = Date()
        XCTAssertEqual(hold(watch, pose: .fist, seconds: 1.4,
                            settings: config, from: start).count, 0,
                       "panic fired inside its own floor")
        XCTAssertEqual(hold(watch, pose: .fist, seconds: 0.5, settings: config,
                            from: start.addingTimeInterval(1.4)).count, 1)
    }

    // MARK: - Settings

    /// A binding wired to "Nothing" is a switch wired to nothing (§8.7), and
    /// the recogniser must not run for it — that is a Vision request per
    /// three frames bought for no behaviour at all.
    func testTheRecogniserIsInactiveUntilSomethingIsActuallyBound() {
        var config = GestureSettings()
        config.isEnabled = true
        config.bindings = HandPose.allCases.map {
            GestureBinding(pose: $0, action: .none, isEnabled: true)
        }
        XCTAssertFalse(config.isActive, "enabled bindings that do nothing are not demand")

        config.bindings = [GestureBinding(pose: .palm, action: .toggleFreeze,
                                          isEnabled: true)]
        XCTAssertTrue(config.isActive)
        config.isEnabled = false
        XCTAssertFalse(config.isActive, "the master switch is a master switch")
    }

    func testSettingsDecodeToleratesAbsentAndUnknownFields() throws {
        let decoder = JSONDecoder()
        let empty = try decoder.decode(GestureSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, GestureSettings())

        // An action this build no longer has degrades to Nothing without
        // taking the rest of the binding — or the rest of the file — with it.
        let json = #"""
        {"isEnabled":true,"holdSeconds":1.5,
         "bindings":[{"pose":"palm","action":"launchTheMissiles","isEnabled":true}]}
        """#
        let settings = try decoder.decode(GestureSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.holdSeconds, 1.5)
        XCTAssertEqual(settings.bindings.first?.action, GestureAction.none)
        XCTAssertEqual(settings.cooldownSeconds, 2.0, "an absent field takes its default")
        XCTAssertEqual(settings.confidence, 0.85)
        XCTAssertFalse(settings.isActive, "an unknown action cannot fire anything")

        // And a StudioSettings written before gestures existed still loads.
        let studio = try decoder.decode(StudioSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(studio.gestures, GestureSettings())
    }

    func testTheClampsHoldTheSlidersToTheirDocumentedRanges() {
        var config = GestureSettings()
        config.holdSeconds = 99
        config.cooldownSeconds = -5
        config.confidence = 0
        XCTAssertEqual(config.clampedHoldSeconds, 3)
        XCTAssertEqual(config.clampedCooldownSeconds, 0.5)
        XCTAssertEqual(config.clampedConfidence, 0.5)
    }

    // MARK: - The schedule

    /// §5.23 — the recogniser arrives as a registration and a demand closure,
    /// which is what keeps eye contact's cadence exactly what it was. At
    /// cadence 3 against everything else it still produces enough sightings
    /// inside the shortest hold the settings allow for the dwell to be
    /// satisfiable — a recogniser that never runs is a broken feature, and
    /// one that runs at eye contact's expense is a worse bug than that.
    func testHandsGetEnoughSightingsInsideTheShortestHold() {
        let coordinator = VisionCoordinator()
        coordinator.register(.face, cadence: 2)
        coordinator.register(.person, cadence: 2)
        coordinator.register(.hands, cadence: 3)
        coordinator.register(.presence, cadence: 15)
        for modality in VisionCoordinator.Modality.allCases {
            coordinator.addConsumer(of: modality) { true }
        }
        // 0.3 s is the shortest hold the settings allow; 9 frames at 30 fps.
        let ran = (0..<9).map { _ in coordinator.beginFrame().running }
        let sightings = ran.filter { $0 == .hands }.count
        XCTAssertGreaterThanOrEqual(sightings, 2,
                                    "hands ran \(sightings) times in 9 frames")
    }
}
