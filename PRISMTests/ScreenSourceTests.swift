// ScreenSourceTests.swift
// PRISMTests
//
// A screen as a source (§5.24) and a live feed as a layer (§5.25).
//
// Three things here are worth defending with a test. Source identifiers,
// because displays and windows are numbered in separate namespaces and a
// parser that confused them would capture the wrong thing silently. Capture
// sizing, because it is the only thing standing between a 6K display and a
// memory ceiling three IOSurfaces would blow through on their own. And the
// hold, because a live layer that kept moving under a frozen picture is the
// most damaging failure this app can produce, and nothing about it is
// visible from the outside until it happens on someone's call.
//
// Licensed under the Apache License, Version 2.0.

import CoreVideo
import Metal
import XCTest

final class ScreenSourceTests: XCTestCase {

    // MARK: - Source identifiers

    /// A display and a window can both be number 7. The prefix is the only
    /// thing that makes one string enough to name either.
    func testDisplayAndWindowIdentifiersDoNotCollide() {
        let display = ScreenCapture.sourceID(display: 7)
        let window = ScreenCapture.sourceID(window: 7)
        XCTAssertNotEqual(display, window)
        XCTAssertEqual(ScreenCapture.displayID(from: display), 7)
        XCTAssertEqual(ScreenCapture.windowID(from: window), 7)
        XCTAssertNil(ScreenCapture.displayID(from: window),
                     "a window id must never resolve as a display")
        XCTAssertNil(ScreenCapture.windowID(from: display),
                     "a display id must never resolve as a window")
    }

    /// A selection carrying nothing, or something a previous build wrote,
    /// resolves to nothing rather than to display zero — which is a real
    /// display id on every Mac.
    func testMalformedIdentifiersResolveToNothing() {
        XCTAssertNil(ScreenCapture.displayID(from: nil))
        XCTAssertNil(ScreenCapture.displayID(from: ""))
        XCTAssertNil(ScreenCapture.displayID(from: "display:"))
        XCTAssertNil(ScreenCapture.displayID(from: "display:not-a-number"))
        XCTAssertNil(ScreenCapture.windowID(from: "42"))
    }

    // MARK: - Persistence

    /// The persisted pick decodes tolerantly at every field, like every other
    /// persisted struct: a selection that failed to decode as a whole would
    /// take the rest of the user's saved state with it.
    func testSelectionDecodesTolerantly() throws {
        let unknownKind = #"{"kind":"hologram","sourceID":"display:1"}"#
        let decoded = try JSONDecoder().decode(
            VideoSourceSelection.self, from: Data(unknownKind.utf8))
        XCTAssertEqual(decoded.kind, .camera,
                       "an unrecognised source kind falls back to the camera")

        let empty = try JSONDecoder().decode(
            VideoSourceSelection.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .camera)
        XCTAssertNil(empty.sourceID)
    }

    /// A window id does not survive a reboot, so the selection deliberately
    /// stores the id and nothing else and the app re-resolves it. Round-trip
    /// so a later refactor cannot quietly stop persisting the id.
    func testSelectionRoundTrips() throws {
        let selection = VideoSourceSelection(
            kind: .window, sourceID: ScreenCapture.sourceID(window: 4242))
        let data = try JSONEncoder().encode(selection)
        XCTAssertEqual(try JSONDecoder().decode(VideoSourceSelection.self, from: data),
                       selection)
    }

    // MARK: - Never filming ourselves (§5.24, §5.27)

    /// Stands in for `SCRunningApplication`, which has no initializer.
    private struct FakeApp: ScreenCaptureApplication, Equatable {
        var bundleIdentifier: String
        var processID: pid_t
    }

    private static let ownID = "horse.prism.PRISM"

    /// The failure this exists to make unstateable: a display capture built
    /// while PRISM had no window on screen used to exclude nothing, and the
    /// user then opened the main window, typed their script into the
    /// prompter pane, and sent it to the call. The exclusion is by
    /// application precisely so it covers windows that do not exist yet —
    /// so the rule must name PRISM off an empty window list.
    func testTheDisplayExclusionNamesPrismWithNoPrismWindowOnScreen() {
        let excluded = ScreenCapture.ownApplications(
            applications: [FakeApp(bundleIdentifier: Self.ownID, processID: 501),
                           FakeApp(bundleIdentifier: "us.zoom.xos", processID: 733)],
            windowOwners: [],
            bundleID: Self.ownID)
        XCTAssertEqual(excluded, [FakeApp(bundleIdentifier: Self.ownID, processID: 501)],
                       "PRISM is excluded whether or not it has a window right now")
    }

    /// A snapshot that lists only applications it already matched a window
    /// to still has to yield PRISM, so the owners of the windows count too.
    func testWindowOwnersCountTowardsTheExclusion() {
        let own = FakeApp(bundleIdentifier: Self.ownID, processID: 501)
        let excluded = ScreenCapture.ownApplications(
            applications: [FakeApp(bundleIdentifier: "com.apple.Safari", processID: 90)],
            windowOwners: [nil, own, own],
            bundleID: Self.ownID)
        XCTAssertEqual(excluded, [own], "one entry per process, however it was found")
    }

    /// Nothing to match on excludes nothing, which is what makes the empty
    /// result meaningful: `build()` refuses to start a display capture on it
    /// rather than starting one that films the prompter.
    func testAnUnknownBundleIdentifierExcludesNothing() {
        let apps = [FakeApp(bundleIdentifier: Self.ownID, processID: 501)]
        XCTAssertTrue(ScreenCapture.ownApplications(
            applications: apps, windowOwners: [], bundleID: nil).isEmpty)
        XCTAssertTrue(ScreenCapture.ownApplications(
            applications: apps, windowOwners: [], bundleID: "").isEmpty)
    }

    // MARK: - Capture sizing

    /// Fitted, never filled: whatever is left over is OutputFitStage's to
    /// letterbox, in the same place it letterboxes every other source.
    func testCaptureSizeFitsInsideTheNegotiatedFormat() {
        let format = VideoFormat(width: 1920, height: 1080, frameRate: 30)
        // A 16:10 display into a 16:9 format: width binds, height is short.
        let wide = ScreenCapture.captureSize(source: CGSize(width: 2560, height: 1600),
                                             within: format)
        XCTAssertEqual(wide.width, 1728)
        XCTAssertEqual(wide.height, 1080)

        // A tall window: height binds.
        let tall = ScreenCapture.captureSize(source: CGSize(width: 600, height: 1600),
                                             within: format)
        XCTAssertLessThanOrEqual(tall.width, format.width)
        XCTAssertEqual(tall.height, 1080)

        for size in [CGSize(width: 6016, height: 3384), CGSize(width: 800, height: 600),
                     CGSize(width: 1, height: 3000)] {
            let fitted = ScreenCapture.captureSize(source: size, within: format)
            XCTAssertLessThanOrEqual(fitted.width, format.width)
            XCTAssertLessThanOrEqual(fitted.height, format.height)
            XCTAssertEqual(fitted.width % 2, 0, "odd-width BGRA surfaces are a driver lottery")
            XCTAssertEqual(fitted.height % 2, 0)
            XCTAssertGreaterThanOrEqual(fitted.width, 2)
            XCTAssertGreaterThanOrEqual(fitted.height, 2)
        }
    }

    /// A window smaller than the format is captured at its own size — scaling
    /// it up would spend memory inventing pixels the source does not have.
    func testCaptureNeverScalesUp() {
        let format = VideoFormat(width: 1920, height: 1080, frameRate: 30)
        let size = ScreenCapture.captureSize(source: CGSize(width: 640, height: 480),
                                             within: format)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 480)
    }

    /// A source that reports nothing must not produce a zero-sized stream.
    func testDegenerateSourceSizeFallsBackToTheFormat() {
        let format = VideoFormat(width: 1280, height: 720, frameRate: 30)
        let size = ScreenCapture.captureSize(source: .zero, within: format)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
    }

    // MARK: - Memory (§5.23)

    /// ScreenCaptureKit's queue is a real allocation against a ceiling that
    /// was already tight, and it is not elastic — so what gives is the freeze
    /// window, slot for slot, and never the floor underneath it.
    func testScreenCaptureIsPaidForOutOfTheElasticDemands() {
        // 720p60, because that is where there is still elastic room to take
        // it out of: once every allocation is counted (§5.23), 1080p has none
        // and the queue lands in `plannedMB` instead — which the next test
        // is about.
        let format = VideoFormat(width: 1280, height: 720, frameRate: 60)
        let without = ResourceGovernor.plan(for: ResourceDemand(format: format))
        let with = ResourceGovernor.plan(for: ResourceDemand(
            format: format, screenSourceActive: true))

        XCTAssertEqual(without.screenDepth, 0)
        XCTAssertEqual(with.screenDepth, ScreenCapture.queueDepth)
        XCTAssertLessThan(with.freezeDepth, without.freezeDepth,
                          "three full frames have to come from somewhere")
        XCTAssertLessThan(with.freezeSpanSeconds, without.freezeSpanSeconds)
        XCTAssertGreaterThanOrEqual(with.freezeDepth, ResourceGovernor.minimumFreezeDepth,
                                    "freeze's floor is never spent, whoever else is asking")
        XCTAssertLessThanOrEqual(with.plannedMB, ResourceGovernor.ceilingMB)
    }

    /// Where there is nothing elastic left to give, the queue shows up in the
    /// planned figure instead — the arithmetic is charged either way, and a
    /// governor that quietly stopped counting it would report a ceiling it is
    /// not keeping.
    func testScreenCaptureShowsUpInThePlannedFigureWhenNothingIsLeftToGive() {
        let format = VideoFormat(width: 3840, height: 2160, frameRate: 30)
        let without = ResourceGovernor.plan(for: ResourceDemand(format: format))
        let with = ResourceGovernor.plan(for: ResourceDemand(
            format: format, screenSourceActive: true))

        XCTAssertEqual(without.freezeDepth, ResourceGovernor.minimumFreezeDepth)
        XCTAssertEqual(with.freezeDepth, ResourceGovernor.minimumFreezeDepth,
                       "the floor holds even at 4K with a screen on top of it")
        let expected = Double(ScreenCapture.queueDepth) * ResourceGovernor.frameMB(for: format)
        XCTAssertEqual(with.plannedMB - without.plannedMB, expected, accuracy: 0.01)
        XCTAssertEqual(with.tier, .exceeded)
    }

    /// Sharing a screen fits at 720p and below. At 1080p it does not, and the
    /// honest answer is the one the governor gives everywhere else: take
    /// freeze's floor, refuse the still ring, report `exceeded` and name the
    /// figure. The old assertion — that every mainstream format still fits —
    /// only held while Overlay's scratch, Retouch's scratch and the camera's
    /// real slot size were missing from the sum (§5.23, §7).
    func testSharingAScreenFitsAt720pAndIsDeclaredOverAt1080p() {
        for format in VideoFormat.defaultSet where format.width <= 1280 {
            let plan = ResourceGovernor.plan(for: ResourceDemand(
                format: format, stillsWantSharpest: true, screenSourceActive: true))
            XCTAssertLessThanOrEqual(plan.plannedMB, ResourceGovernor.ceilingMB,
                                     "\(format.displayName) plans over the ceiling")
            XCTAssertNotEqual(plan.tier, .exceeded, format.displayName)
        }
        for format in VideoFormat.defaultSet where format.width == 1920 {
            let plan = ResourceGovernor.plan(for: ResourceDemand(
                format: format, stillsWantSharpest: true, screenSourceActive: true))
            XCTAssertEqual(plan.tier, .exceeded, format.displayName)
            XCTAssertEqual(plan.stillDepth, 0, format.displayName)
            XCTAssertEqual(plan.freezeDepth, ResourceGovernor.minimumFreezeDepth,
                           format.displayName)
            XCTAssertTrue(plan.summary.contains("250"), format.displayName)
        }
    }

    // MARK: - Live layers (§5.25)

    /// The demand a picture-in-picture puts on the second capture. This is
    /// what keeps a camera running while a screen is on air — and what stops
    /// it the moment the layer goes.
    func testLiveFeedDemandFollowsTheLayers() {
        var settings = OverlaySettings()
        XCTAssertFalse(settings.needsLiveFeed(.camera))

        settings.layers = [OverlayLayer(name: "Me", sourceKind: .live, liveFeed: .camera)]
        XCTAssertTrue(settings.needsLiveFeed(.camera))
        XCTAssertFalse(settings.needsLiveFeed(.screen))

        // A live layer with no feed chosen yet is a real state the picker
        // passes through, and it must demand nothing.
        settings.layers = [OverlayLayer(name: "Me", sourceKind: .live)]
        XCTAssertFalse(settings.needsLiveFeed(.camera))
        XCTAssertFalse(settings.needsLiveFeed(.screen))

        // Neither must one switched off, or turned all the way down.
        settings.layers = [OverlayLayer(name: "Me", isEnabled: false,
                                        sourceKind: .live, liveFeed: .camera)]
        XCTAssertFalse(settings.needsLiveFeed(.camera))
        settings.layers = [OverlayLayer(name: "Me", sourceKind: .live,
                                        opacity: 0, liveFeed: .camera)]
        XCTAssertFalse(settings.needsLiveFeed(.camera))
    }

    /// A live layer costs no decoder, so it is not charged against the video
    /// cap — three video layers plus a picture-in-picture is legal.
    func testLiveLayersDoNotSpendTheVideoCap() {
        var settings = OverlaySettings()
        settings.layers = (0..<OverlaySettings.maxVideoLayers).map {
            OverlayLayer(name: "Clip \($0)", sourceKind: .video, assetPath: "/tmp/\($0).mov")
        } + [OverlayLayer(name: "Me", sourceKind: .live, liveFeed: .camera)]
        XCTAssertTrue(settings.needsLiveFeed(.camera),
                      "a live layer must not be starved by the decoder cap")
        XCTAssertEqual(settings.renderableLayers.count,
                       OverlaySettings.maxVideoLayers + 1)
    }

    // MARK: - The hold

    private func makeFeeds() throws -> (LiveFeeds, MetalContext) {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device on this host")
        }
        let metal = try MetalContext()
        return (LiveFeeds(metal: metal), metal)
    }

    private func makeBuffer(width: Int = 64, height: Int = 64) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, prismPixelFormat,
            prismPixelBufferAttributes(width: width, height: height) as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("Could not allocate an IOSurface-backed buffer")
        }
        return buffer
    }

    /// The ordinary case: the newest frame is what a layer composites, and a
    /// repeated frame is not re-wrapped.
    func testFeedPublishesTheNewestFrame() throws {
        let (feeds, _) = try makeFeeds()
        XCTAssertNil(feeds.texture(for: .camera), "nothing published, nothing drawn")

        let first = try makeBuffer()
        feeds.publish(first, feed: .camera)
        guard let a = feeds.texture(for: .camera) else {
            return XCTFail("a published frame must produce a texture")
        }
        XCTAssertTrue(feeds.texture(for: .camera) === a,
                      "the same buffer must not be wrapped twice")

        feeds.publish(try makeBuffer(), feed: .camera)
        XCTAssertFalse(feeds.texture(for: .camera) === a)
    }

    /// The whole point of §5.25. While a substituting stage is engaged, every
    /// frame published behind it is dropped: the corner of the picture holds
    /// exactly as still as the rest of it.
    func testHeldFeedIgnoresEverythingPublishedBehindIt() throws {
        let (feeds, _) = try makeFeeds()
        feeds.publish(try makeBuffer(), feed: .camera)
        guard let live = feeds.texture(for: .camera) else {
            return XCTFail("a published frame must produce a texture")
        }

        feeds.setHeld(true)
        guard let held = feeds.texture(for: .camera) else {
            return XCTFail("the hold must snapshot what was on screen")
        }
        XCTAssertFalse(held === live, "the snapshot is a copy — capture pools are shallow")

        for _ in 0..<5 {
            feeds.publish(try makeBuffer(), feed: .camera)
            XCTAssertTrue(feeds.texture(for: .camera) === held,
                          "a live layer must not move under a frozen picture")
        }

        feeds.setHeld(false)
        XCTAssertFalse(feeds.texture(for: .camera) === held,
                       "releasing the hold returns to live")
    }

    /// A feed with nothing on screen when the hold engages stays with
    /// nothing. Handing it the next frame that arrives would be the same
    /// failure a beat later — motion appearing under a held picture.
    func testHoldingAnEmptyFeedKeepsItEmpty() throws {
        let (feeds, _) = try makeFeeds()
        feeds.setHeld(true)
        feeds.publish(try makeBuffer(), feed: .screen)
        XCTAssertNil(feeds.texture(for: .screen))
        feeds.setHeld(false)
        XCTAssertNotNil(feeds.texture(for: .screen))
    }

    /// Switching the source drops what the old one left behind: a stale frame
    /// hanging in a layer is a picture of the past.
    func testClearingAFeedDropsItsLastFrame() throws {
        let (feeds, _) = try makeFeeds()
        feeds.publish(try makeBuffer(), feed: .screen)
        XCTAssertNotNil(feeds.texture(for: .screen))
        feeds.clear(.screen)
        XCTAssertNil(feeds.texture(for: .screen))
    }

    /// The two feeds are independent — holding one must not blank the other,
    /// and publishing to one must not appear in the other.
    func testFeedsDoNotBleedIntoEachOther() throws {
        let (feeds, _) = try makeFeeds()
        feeds.publish(try makeBuffer(), feed: .camera)
        XCTAssertNotNil(feeds.texture(for: .camera))
        XCTAssertNil(feeds.texture(for: .screen))
        feeds.clear(.camera)
        feeds.publish(try makeBuffer(), feed: .screen)
        XCTAssertNil(feeds.texture(for: .camera))
        XCTAssertNotNil(feeds.texture(for: .screen))
    }
}
