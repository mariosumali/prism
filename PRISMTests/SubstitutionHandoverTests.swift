// SubstitutionHandoverTests.swift
// PRISMTests
//
// One question, asked four ways: who is allowed to put live video back on air,
// and does every surface agree with what is actually going out?
//
// Each of these pins a way the app could have lied about that. A second
// claimant taking the one replay transport out from under the away loop; a
// transport that has claimed the picture but not decoded its first frame yet;
// panic thawing a freeze the user engaged themselves; a deferred freeze that
// never takes hold on the no-camera heartbeat, leaving a picture-in-picture
// moving over a picture every surface calls frozen. All four end the same way
// — live video on air under a UI that says otherwise — which is the most
// damaging thing this product can do.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreVideo
import Metal
import XCTest

final class SubstitutionHandoverTests: XCTestCase {

    // MARK: - The one replay transport (§5.9–§5.14)

    /// The bad connection's delay half rides the §5.12 transport, and taking
    /// it means `begin()` re-bases the player: the away loop is destroyed and
    /// what goes out is the live camera a second or two behind. The user is
    /// not at their desk to notice. So the stunt degrades whatever is already
    /// on air and never claims the transport from it.
    func testTheBadConnectionNeverTakesTheTransportFromTheAwayLoop() {
        let away = ReplayTransportClaim(isAway: true)
        XCTAssertFalse(
            ReplayTransportClaim.connectionMayClaimTransport(mode: .away, standing: away),
            "a bad connection would put delayed live camera on air under an away glyph")
        XCTAssertFalse(
            ReplayTransportClaim.connectionMayClaimTransport(
                mode: .replay, standing: ReplayTransportClaim()))
        XCTAssertFalse(
            ReplayTransportClaim.connectionMayClaimTransport(
                mode: .lag, standing: ReplayTransportClaim(isLagging: true)))
        XCTAssertTrue(
            ReplayTransportClaim.connectionMayClaimTransport(
                mode: .idle, standing: ReplayTransportClaim()),
            "with nothing substituting, the delay half is free to engage")
    }

    /// The flags every surface reads are derived from whoever claimed the
    /// transport, so no claimant can leave another's state standing — the
    /// omission that put an away glyph over delayed live camera.
    func testAClaimPublishesOnlyItsOwnState() {
        XCTAssertEqual(ReplayTransportClaim.claimed(by: .away),
                       ReplayTransportClaim(isAway: true))
        XCTAssertEqual(ReplayTransportClaim.claimed(by: .lag),
                       ReplayTransportClaim(isLagging: true))
        XCTAssertEqual(ReplayTransportClaim.claimed(by: .connectionLag),
                       ReplayTransportClaim(isLagging: true, connectionEngagedLag: true))
        XCTAssertEqual(ReplayTransportClaim.claimed(by: .replay),
                       ReplayTransportClaim(),
                       "a replay publishes replayMode, not a flag of its own")

        // The property that matters, stated once for every claimant: nothing
        // another claimant published survives the claim.
        let claimants: [ReplayTransportClaim.Claimant] = [.replay, .away, .lag, .connectionLag]
        for claimant in claimants {
            let claimed = ReplayTransportClaim.claimed(by: claimant)
            XCTAssertEqual(claimed.isAway, claimant == .away,
                           "\(claimant) leaves the away flag standing")
            XCTAssertEqual(claimed.isCatchingUp, false,
                           "\(claimant) leaves a catch-up standing")
            if claimant != .connectionLag {
                XCTAssertFalse(claimed.connectionEngagedLag,
                               "\(claimant) would have the bad connection release its delay")
            }
        }
    }

    /// What the outgoing claimant leaves behind is its own, not the new
    /// claimant's: the loop's mute comes off with the loop, and the audio
    /// delay line goes back to zero with the delay.
    func testAClaimReleasesTheLoopsMuteAndTheDelayLine() {
        XCTAssertEqual(ReplayTransportClaim(isAway: true).release,
                       ReplayTransportClaim.Release(loop: true, delayLine: false))
        XCTAssertEqual(ReplayTransportClaim(isLagging: true).release,
                       ReplayTransportClaim.Release(loop: false, delayLine: true))
        XCTAssertEqual(ReplayTransportClaim(isCatchingUp: true).release,
                       ReplayTransportClaim.Release(loop: false, delayLine: true),
                       "a catch-up is still the delay line's audio to release")
        XCTAssertEqual(ReplayTransportClaim().release,
                       ReplayTransportClaim.Release(),
                       "an unclaimed transport leaves nothing to undo")
    }

    // MARK: - Panic puts back only what panic did (§5.11)

    /// The failure this exists for: the user freezes the picture themselves to
    /// step out of shot, then panics. Panic never engaged the freeze, so
    /// releasing panic must not thaw it — doing so puts live video on air
    /// while they still believe they are frozen.
    func testReleasingPanicLeavesAFreezeTheUserEngagedThemselves() {
        var settings = PanicSettings()
        settings.freezes = true
        settings.mutes = true

        let engaging = PanicHold.engaging(settings: settings, isFrozen: true, isMuted: false)
        XCTAssertFalse(engaging.freeze, "the picture is already frozen; panic has nothing to do")
        XCTAssertTrue(engaging.mute)

        let releasing = engaging.hold.releasing(isFrozen: true, isMuted: true)
        XCTAssertFalse(releasing.thaw,
                       "panic thawed a freeze it never engaged")
        XCTAssertTrue(releasing.unmute, "the mute panic engaged still comes off")
    }

    /// The other half of the same rule: what panic did engage, it undoes.
    func testReleasingPanicUndoesTheFreezeAndMuteItEngaged() {
        let engaging = PanicHold.engaging(settings: PanicSettings(),
                                          isFrozen: false, isMuted: false)
        XCTAssertTrue(engaging.freeze)
        XCTAssertTrue(engaging.mute)
        XCTAssertEqual(engaging.hold, PanicHold(frozeByUs: true, mutedByUs: true))

        let releasing = engaging.hold.releasing(isFrozen: true, isMuted: true)
        XCTAssertTrue(releasing.thaw)
        XCTAssertTrue(releasing.unmute)
    }

    /// And only while it is still true: a user who thawed the picture by hand
    /// mid-panic must not have it toggled back on the way out.
    func testPanicNeverTogglesAStateThatIsNoLongerEngaged() {
        let hold = PanicHold(frozeByUs: true, mutedByUs: true)
        let releasing = hold.releasing(isFrozen: false, isMuted: false)
        XCTAssertFalse(releasing.thaw)
        XCTAssertFalse(releasing.unmute)
    }

    /// A chord with both halves switched off holds nothing, so releasing it
    /// cannot touch a freeze or a mute the user set for themselves.
    func testAPanicThatEngagesNothingReleasesNothing() {
        var settings = PanicSettings()
        settings.freezes = false
        settings.mutes = false
        let engaging = PanicHold.engaging(settings: settings, isFrozen: false, isMuted: false)
        XCTAssertEqual(engaging.hold, PanicHold())
        XCTAssertEqual(engaging.hold.releasing(isFrozen: true, isMuted: true).thaw, false)
        XCTAssertEqual(engaging.hold.releasing(isFrozen: true, isMuted: true).unmute, false)
    }

    // MARK: - The transport's start-up window (§5.9, §5.10, §5.12)

    /// A transport that has claimed the picture but has not decoded its first
    /// frame yet is still substituting. Declining to encode there passes the
    /// live camera to air — and leaves the `.live` layers moving — for as long
    /// as the decoder takes to reach the target, up to a full GOP.
    func testAStartingTransportHoldsTheBridgeInsteadOfPassingLiveVideo() throws {
        let metal = try makeContext()
        let stage = try ReplayStage(metal: metal)
        let transport = StubTransport()
        stage.player = transport

        XCTAssertFalse(stage.wantsEncode(), "an idle transport substitutes nothing")

        transport.isActive = true          // begin() has claimed it…
        transport.frame = nil              // …and the decoder has not answered
        stage.bridgeFrame = try filled(metal: metal, colour: .bridge)
        XCTAssertTrue(stage.wantsEncode(),
                      "live camera goes to air while the transport spins up")

        let live = try filled(metal: metal, colour: .live)
        let output = try target(metal: metal)
        try run(stage: stage, metal: metal, input: live, output: output)
        assertPixel(output, is: .bridge,
                    "the start-up window drew the live camera instead of the held picture")
    }

    /// The bridge is a full-frame texture and only covers the gap: the first
    /// decoded frame ends it.
    func testTheFirstDecodedFrameReleasesTheBridge() throws {
        let metal = try makeContext()
        let stage = try ReplayStage(metal: metal)
        let transport = StubTransport()
        transport.isActive = true
        stage.player = transport
        stage.bridgeFrame = try filled(metal: metal, colour: .bridge)

        let decoded = try filled(metal: metal, colour: .decoded)
        transport.frame = ReplayPlayer.Frame(texture: decoded, blendTexture: nil, mix: 0)
        XCTAssertTrue(stage.wantsEncode())
        XCTAssertNil(stage.bridgeFrame, "the bridge outlived the frame it was covering for")

        let output = try target(metal: metal)
        try run(stage: stage, metal: metal,
                input: try filled(metal: metal, colour: .live), output: output)
        assertPixel(output, is: .decoded)
    }

    /// A bridge that outlived its transport would hold the picture on its own
    /// — a freeze nobody asked for and no surface would report.
    func testABridgeNeverOutlivesItsTransport() throws {
        let metal = try makeContext()
        let stage = try ReplayStage(metal: metal)
        let transport = StubTransport()
        stage.player = transport
        stage.bridgeFrame = try filled(metal: metal, colour: .bridge)

        XCTAssertFalse(stage.wantsEncode())
        XCTAssertNil(stage.bridgeFrame)
    }

    /// The pipeline arms the bridge from the freeze ring as the transport is
    /// claimed, and releases it when the claim is refused — a bridge left
    /// armed after a refused start would cover a picture nothing is
    /// substituting.
    func testClaimingTheTransportArmsABridgeAndARefusedClaimReleasesIt() throws {
        let metal = try makeContext()
        let pipeline = try VideoPipeline(metal: metal)
        pipeline.configure(outputFormat: VideoFormat(width: 640, height: 360, frameRate: 30))
        let rendered = expectation(description: "first frame rendered")
        rendered.assertForOverFulfill = false
        pipeline.onOutput = { _, _, _ in rendered.fulfill() }

        let pool = try makePool(width: 640, height: 360)
        var created: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created),
            kCVReturnSuccess)
        pipeline.submitCameraFrame(try XCTUnwrap(created),
                                   at: CMTime(value: 0, timescale: 30))
        wait(for: [rendered], timeout: 5)

        XCTAssertTrue(pipeline.startReplayTransport { _ in true })
        XCTAssertNotNil(pipeline.replayStage.bridgeFrame,
                        "nothing to hold while the transport spins up")

        XCTAssertFalse(pipeline.startReplayTransport { _ in false })
        XCTAssertNil(pipeline.replayStage.bridgeFrame,
                     "a refused claim left a bridge armed over live video")
    }

    // MARK: - A deferred freeze on the no-camera heartbeat (§5.2, §5.25)

    /// Freeze with nothing in the ring to hold defers to the next frame. On a
    /// machine whose camera has not delivered, the next frame is the heartbeat
    /// — and if the freeze does not take hold there, FreezeStage never
    /// substitutes, the live feeds are never held, and a picture-in-picture of
    /// the user's screen keeps moving over the placeholder while every surface
    /// says the picture is frozen.
    func testTheHeartbeatTakesADeferredFreezeAndHoldsTheLiveLayers() throws {
        let metal = try makeContext()
        let pipeline = try VideoPipeline(metal: metal)
        pipeline.configure(outputFormat: VideoFormat(width: 640, height: 360, frameRate: 30))

        pipeline.setFrozen(true)
        XCTAssertFalse(pipeline.freezeStage.isFrozen,
                       "no camera has delivered, so there is nothing to hold yet")

        let rendered = expectation(description: "heartbeat rendered")
        rendered.assertForOverFulfill = false
        pipeline.onOutput = { _, _, _ in rendered.fulfill() }
        pipeline.tickWithoutCamera(at: CMClockGetTime(CMClockGetHostTimeClock()))
        wait(for: [rendered], timeout: 5)

        XCTAssertTrue(pipeline.freezeStage.isFrozen,
                      "the deferred freeze was never consumed")
        XCTAssertTrue(pipeline.liveFeeds.isHeld,
                      "a live layer kept streaming under a frozen picture")
    }

    // MARK: - Harness

    /// What ReplayStage needs from the transport, without a decoder: a
    /// claimed transport that has not answered yet is exactly the state the
    /// start-up window is made of.
    private final class StubTransport: ReplayFrameSource {
        var isActive = false
        var frame: ReplayPlayer.Frame?
        func currentFrame(at hostTime: CMTime) -> ReplayPlayer.Frame? { frame }
    }

    private enum Colour {
        case live, bridge, decoded

        /// Distinct BGRA bytes, far enough apart that no filtering could
        /// confuse them.
        var bgra: (UInt8, UInt8, UInt8) {
            switch self {
            case .live: return (0, 0, 220)        // red
            case .bridge: return (220, 0, 0)      // blue
            case .decoded: return (0, 220, 0)     // green
            }
        }
    }

    private var storageMode: MTLStorageMode {
        MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true ? .shared : .managed
    }

    private func makeContext() throws -> MetalContext {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device on this host")
        }
        return try MetalContext()
    }

    private func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
        XCTAssertEqual(
            CVPixelBufferPoolCreate(kCFAllocatorDefault, attrs as CFDictionary,
                                    prismPixelBufferAttributes(width: width,
                                                               height: height) as CFDictionary,
                                    &pool),
            kCVReturnSuccess)
        return try XCTUnwrap(pool)
    }

    private func texture(metal: MetalContext, width: Int = 16, height: Int = 16) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = storageMode
        return try XCTUnwrap(metal.device.makeTexture(descriptor: desc))
    }

    private func filled(metal: MetalContext, colour: Colour) throws -> MTLTexture {
        let texture = try texture(metal: metal)
        let (b, g, r) = colour.bgra
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        for pixel in 0..<(texture.width * texture.height) {
            bytes[pixel * 4 + 0] = b
            bytes[pixel * 4 + 1] = g
            bytes[pixel * 4 + 2] = r
            bytes[pixel * 4 + 3] = 255
        }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                            mipmapLevel: 0,
                            withBytes: $0.baseAddress!,
                            bytesPerRow: texture.width * 4)
        }
        return texture
    }

    private func target(metal: MetalContext) throws -> MTLTexture {
        try texture(metal: metal)
    }

    /// One stage encode, blocking, with the managed-memory synchronize the
    /// readback needs on a discrete GPU.
    private func run(stage: ReplayStage, metal: MetalContext,
                     input: MTLTexture, output: MTLTexture) throws {
        let commandBuffer = try XCTUnwrap(metal.commandQueue.makeCommandBuffer())
        try stage.encode(commandBuffer: commandBuffer, input: input, output: output)
        if storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: output)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
    }

    private func assertPixel(_ texture: MTLTexture, is colour: Colour,
                             _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4,
                         from: MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1),
                         mipmapLevel: 0)
        let (b, g, r) = colour.bgra
        XCTAssertEqual(Int(pixel[0]), Int(b), accuracy: 2, message, file: file, line: line)
        XCTAssertEqual(Int(pixel[1]), Int(g), accuracy: 2, message, file: file, line: line)
        XCTAssertEqual(Int(pixel[2]), Int(r), accuracy: 2, message, file: file, line: line)
    }
}
