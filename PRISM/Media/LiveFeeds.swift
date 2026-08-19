// LiveFeeds.swift
// PRISM
//
// The other running capture, as a texture an overlay layer can composite
// (§5.8 `.live`, §5.25). Whichever of the camera and the screen is not
// feeding the pipeline publishes here instead, and the overlay stage picks it
// up on the frame queue — so a picture-in-picture is one more keyed layer
// through `prism_overlay` rather than a stage of its own.
//
// The whole of the difficulty is the hold.
//
// A live layer sits at `.overlay`, far downstream of clip, replay and freeze.
// Left alone it would keep moving under a frozen picture: freeze the screen
// and your face carries on talking in the corner, freeze the camera and the
// screen behind it keeps scrolling. That is the most damaging failure this
// app can produce — the user believes nothing is on air and something is —
// and it is the same failure in both directions, so it gets one answer.
// While any stage is substituting the picture, the feeds are HELD: the
// texture is snapshotted into a private copy and every frame published
// afterwards is dropped until the substitution ends.
//
// The snapshot is a copy rather than a retained reference on purpose.
// Capture pools are shallow (three slots for ScreenCaptureKit, a handful for
// AVFoundation), and a freeze can last minutes — holding one of their buffers
// for that long starves the session that owns it. Copying costs one private
// texture per held feed, paid only while held. FreezeStage takes the same
// trade for the same reason.
//
// Licensed under the Apache License, Version 2.0.

import CoreVideo
import Foundation
import Metal

final class LiveFeeds {

    private let metal: MetalContext
    private let feeds: [LiveLayerFeed: Feed]
    /// frame-queue-confined.
    private var held = false

    init(metal: MetalContext) {
        self.metal = metal
        var built: [LiveLayerFeed: Feed] = [:]
        for feed in LiveLayerFeed.allCases {
            built[feed] = Feed(metal: metal)
        }
        feeds = built
    }

    // MARK: - Publisher side (capture queues)

    /// Hands the newest frame to a feed. Called from whichever capture queue
    /// produced it; the frame is not wrapped here, because wrapping is the
    /// frame queue's job and a feed nobody composites must not pay for one.
    func publish(_ buffer: CVPixelBuffer, feed: LiveLayerFeed) {
        feeds[feed]?.publish(buffer)
    }

    /// Drops whatever a feed was holding — the source switched, or its
    /// capture stopped. Without this, flipping the source would leave the
    /// last frame of the old one hanging in a layer forever.
    func clear(_ feed: LiveLayerFeed) {
        feeds[feed]?.clear()
    }

    // MARK: - Frame queue

    /// Engages or releases the hold. Idempotent, and the snapshot happens
    /// only on the engaging edge, so a minute of freeze costs one copy rather
    /// than one per frame.
    func setHeld(_ wanted: Bool) {
        guard wanted != held else { return }
        held = wanted
        for feed in feeds.values {
            if wanted {
                feed.hold()
            } else {
                feed.release()
            }
        }
    }

    /// The texture a `.live` layer should composite this frame, or nil when
    /// the feed has nothing to show. Nil is the honest answer while held with
    /// nothing snapshotted: the layer was showing nothing when the picture
    /// stopped, so it shows nothing until the picture moves again.
    func texture(for feed: LiveLayerFeed) -> MTLTexture? {
        feeds[feed]?.current(held: held)
    }

    // MARK: - One feed

    private final class Feed {
        private let metal: MetalContext
        private let lock = NSLock()

        // lock-guarded
        private var pending: CVPixelBuffer?

        // frame-queue-confined
        private var cachedBuffer: CVPixelBuffer?
        private var cachedTexture: MTLTexture?
        private var heldTexture: MTLTexture?

        init(metal: MetalContext) {
            self.metal = metal
        }

        func publish(_ buffer: CVPixelBuffer) {
            lock.lock()
            pending = buffer
            lock.unlock()
        }

        func clear() {
            lock.lock()
            pending = nil
            lock.unlock()
        }

        func current(held: Bool) -> MTLTexture? {
            if held { return heldTexture }
            lock.lock()
            let buffer = pending
            lock.unlock()
            guard let buffer else { return nil }
            if let cachedBuffer, cachedBuffer === buffer { return cachedTexture }
            let texture = try? metal.makeTexture(from: buffer)
            cachedBuffer = buffer
            cachedTexture = texture
            return texture
        }

        /// Copies the frame currently on screen into a private texture. This
        /// is an event-path command buffer — the one-per-frame rule governs
        /// the frame path — and queue ordering puts the copy ahead of every
        /// later read, exactly as FreezeStage's capture copy does.
        func hold() {
            guard let source = current(held: false) else {
                heldTexture = nil
                return
            }
            let reuse = heldTexture.flatMap { texture -> MTLTexture? in
                texture.width == source.width && texture.height == source.height
                    && texture.pixelFormat == source.pixelFormat ? texture : nil
            }
            guard let destination = reuse
                ?? (try? metal.makeIntermediate(width: source.width, height: source.height)),
                let commandBuffer = metal.commandQueue.makeCommandBuffer(),
                let blit = commandBuffer.makeBlitCommandEncoder() else {
                heldTexture = nil
                return
            }
            commandBuffer.label = "LiveFeeds.holdCopy"
            blit.copy(from: source, to: destination)
            blit.endEncoding()
            commandBuffer.commit()
            heldTexture = destination
        }

        func release() {
            heldTexture = nil
        }
    }
}
