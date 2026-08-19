// ClipDisclosureTests.swift
// PRISMTests
//
// The check that stands between "save the last seconds" and writing a video
// of the room somebody chose to hide (§5.15).
//
// The rolling buffer records the camera upstream of every effect, which is
// what makes a replay run through the current look — and what makes a saved
// clip a recording of everything the effects were covering. This is the one
// place PRISM can catch that, and it has to catch it for exactly the right
// set of effects: miss one and somebody publishes their bedroom; fire on a
// zoom and the confirmation becomes noise nobody reads.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class ClipDisclosureTests: XCTestCase {

    private func config(_ enabled: StageID...) -> PipelineConfiguration {
        var config = PipelineConfiguration()
        for id in enabled {
            var flags = config.flags(for: id)
            flags.enabled = true
            config.flags[id] = flags
        }
        return config
    }

    // MARK: - What counts

    func testNothingIsConcealedByAPlainCamera() {
        XCTAssertTrue(ClipDisclosure.concealments(in: PipelineConfiguration(),
                                                  isPanicked: false).isEmpty)
    }

    func testBackgroundBlurIsConcealment() {
        XCTAssertEqual(ClipDisclosure.concealments(in: config(.blur), isPanicked: false),
                       ["background blur"])
    }

    func testVirtualBackgroundIsConcealment() {
        XCTAssertEqual(ClipDisclosure.concealments(in: config(.background), isPanicked: false),
                       ["your virtual background"])
    }

    /// Panic is the case with the highest stakes and the least attention
    /// available, so it is named as itself rather than as a background.
    func testPanicBackdropIsNamedAsItself() {
        XCTAssertEqual(ClipDisclosure.concealments(in: config(.background), isPanicked: true),
                       ["the panic backdrop"])
    }

    func testLayerBehindTheSubjectIsConcealment() {
        var settings = OverlaySettings()
        settings.layers = [OverlayLayer(assetPath: "/tmp/wall.png", placement: .behind)]
        var configuration = config(.overlay)
        configuration.overlay = settings
        XCTAssertEqual(ClipDisclosure.concealments(in: configuration, isPanicked: false),
                       ["a layer sitting behind you"])
    }

    /// A layer in front is a sticker on top of the picture. It hides nothing
    /// the camera saw that the call did not also see.
    func testLayerInFrontIsNotConcealment() {
        var settings = OverlaySettings()
        settings.layers = [OverlayLayer(assetPath: "/tmp/logo.png", placement: .front)]
        var configuration = config(.overlay)
        configuration.overlay = settings
        XCTAssertTrue(ClipDisclosure.concealments(in: configuration,
                                                  isPanicked: false).isEmpty)
    }

    // MARK: - What deliberately does not count

    /// Cropping, rotation and colour make a saved clip differ from the call,
    /// and the standing "raw camera" caption covers them. A modal that fires
    /// on a zoom is a modal nobody reads by the time it matters.
    func testFramingAndColourDoNotRaiseTheConfirmation() {
        var configuration = config(.geometry, .adjust, .lut, .style, .retouch, .gaze)
        configuration.geometry.zoom = 2.4
        XCTAssertTrue(ClipDisclosure.concealments(in: configuration,
                                                  isPanicked: false).isEmpty)
    }

    func testADisabledStageConcealsNothing() {
        var configuration = PipelineConfiguration()
        configuration.blur.radius = 40
        XCTAssertTrue(ClipDisclosure.concealments(in: configuration,
                                                  isPanicked: false).isEmpty)
    }

    // MARK: - Copy

    func testPhraseReadsAsASentenceAtEveryLength() {
        XCTAssertEqual(ClipDisclosure.phrase([]), "")
        XCTAssertEqual(ClipDisclosure.phrase(["blur"]), "blur")
        XCTAssertEqual(ClipDisclosure.phrase(["blur", "a backdrop"]), "blur and a backdrop")
        XCTAssertEqual(ClipDisclosure.phrase(["one", "two", "three"]),
                       "one, two, and three")
    }

    /// §5.15/§8.3: the standing line is there on every open, and the
    /// concealment sentence *joins* it rather than replacing it. Swapping
    /// them over is the tempting edit — the concealment sentence is the more
    /// alarming one — and it takes "no effects", the half that teaches that
    /// the crop, the colour and the overlays go too, off the screen in the
    /// exact state where a saved clip gives most away.
    func testTheStandingLineIsThereWhetherOrNotSomethingIsConcealed() {
        XCTAssertEqual(ClipDisclosure.captions([]), [ClipDisclosure.alwaysTrue])
        XCTAssertNil(ClipDisclosure.consequence([]))

        let both = ClipDisclosure.captions(["background blur"])
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both.first, ClipDisclosure.alwaysTrue,
                       "the rule was replaced by the consequence")
        XCTAssertTrue(both[1].contains("background blur"))
    }

    func testTheStandingLineNamesBothOmissions() {
        // Sound is the half people forget: a clip with no audio is not a
        // recording of the meeting, and saying so once is cheaper than the
        // support thread.
        XCTAssertTrue(ClipDisclosure.alwaysTrue.contains("raw camera"))
        XCTAssertTrue(ClipDisclosure.alwaysTrue.contains("no sound"))
    }
}
