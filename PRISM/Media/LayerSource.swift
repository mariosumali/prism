// LayerSource.swift
// PRISM
//
// One layer's pixels as a Metal texture, per frame: a still image loaded
// once, a video decoded on a loop, or a string rasterised by Core Text
// (§5.26). Backs both the virtual background (§5.7) and every green-screen
// overlay layer (§5.8), which need exactly the same thing and differ only in
// what they composite it against.
//
// Text arrives through this door rather than beside it deliberately. The
// overlay stage already keeps one source per layer id, reconciles them when
// settings change, and releases them when a layer is removed; a caption that
// carried its own parallel lifetime would be a second copy of all of that,
// and the first thing to fall out of step.
//
// This is deliberately not ClipPlayer. ClipPlayer owns transport (play,
// pause, scrub, position publishing), routes audio into the shared ring, and
// keeps a 30-frame decode-ahead so the first frame after load is instant.
// A backdrop has no transport, no audio, and no user watching for a scrub to
// land — it just needs to be running. The decode-ahead here is 4 frames
// precisely because a 1080p FIFO is ~8 MB per slot and a scene can hold a
// background plus three overlay layers (§7: < 250 MB resident).
//
// Threading mirrors the rest of the pipeline: load/unload from the main
// thread, currentTexture(at:) from the frame queue only, decoding on a
// private serial queue.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit

// MARK: - Looping video decode

final class LoopingVideoSource {
    private static let decodeAhead = 4

    private let metal: MetalContext
    /// Dedicated cache so layer textures never contend with the live-capture
    /// wrap path.
    private let textureCache: CVMetalTextureCache
    private let decodeQueue: DispatchQueue
    private let lock = NSLock()

    private struct FrameEntry {
        let buffer: CVPixelBuffer
        /// Monotonic across loop iterations: loopIndex × duration + pts.
        let timelineSeconds: Double
    }

    // lock-guarded
    private var loaded = false
    private var fifo: [FrameEntry] = []
    private var lastDelivered: FrameEntry?
    private var generation: UInt64 = 0
    private var duration: Double = 0
    private var elapsedAtSuspend: Double = 0
    private var runningSince: CMTime?
    private var fillScheduled = false
    private var suspended = false
    private var naturalSize: CGSize = .zero

    // decodeQueue-confined
    private var asset: AVAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var loopBase: Double = 0

    // Frame-queue-confined texture wrapper cache.
    private var cachedBuffer: CVPixelBuffer?
    private var cachedCVTexture: CVMetalTexture?
    private var cachedTexture: MTLTexture?

    init(metal: MetalContext, label: String) {
        self.metal = metal
        decodeQueue = DispatchQueue(label: "horse.prism.PRISM.layer.\(label)",
                                    qos: .userInitiated)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metal.device, nil, &cache)
        precondition(cache != nil, "CVMetalTextureCacheCreate failed")
        textureCache = cache!
    }

    deinit {
        reader?.cancelReading()
    }

    var contentSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return loaded && naturalSize.width > 0 ? naturalSize : nil
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    @discardableResult
    func load(url: URL) -> Bool {
        unload()

        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        // Synchronous by contract, same as ClipPlayer.load: the caller is
        // configuring a layer on the main thread and needs to know now
        // whether the file is usable, so the deprecated synchronous
        // accessors are the intended tool here.
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return false }
        let assetDuration = asset.duration.seconds
        guard assetDuration.isFinite, assetDuration > 0 else { return false }
        guard let (reader, output) = try? Self.makeReader(asset: asset,
                                                          track: videoTrack,
                                                          startingAt: 0) else { return false }

        let size = videoTrack.naturalSize.applying(videoTrack.preferredTransform)

        lock.lock()
        generation &+= 1
        let gen = generation
        loaded = true
        duration = assetDuration
        naturalSize = CGSize(width: abs(size.width), height: abs(size.height))
        elapsedAtSuspend = 0
        runningSince = suspended ? nil : CMClockGetTime(CMClockGetHostTimeClock())
        lock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.asset = asset
            self.track = videoTrack
            self.reader = reader
            self.output = output
            self.loopBase = 0
            self.fill(generation: gen)
        }
        return true
    }

    func unload() {
        lock.lock()
        generation &+= 1
        loaded = false
        fifo.removeAll()
        lastDelivered = nil
        duration = 0
        elapsedAtSuspend = 0
        runningSince = nil
        fillScheduled = false
        naturalSize = .zero
        lock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.reader?.cancelReading()
            self.reader = nil
            self.output = nil
            self.asset = nil
            self.track = nil
            self.loopBase = 0
        }
    }

    /// Stops the loop's clock while the pipeline has no consumers, so an idle
    /// PRISM neither decodes nor fast-forwards through the idle gap when it
    /// wakes (same contract as ClipPlayer.setDemandActive).
    func setDemandActive(_ active: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock()
        let wantSuspend = !active
        guard wantSuspend != suspended else {
            lock.unlock()
            return
        }
        suspended = wantSuspend
        if wantSuspend {
            if let start = runningSince {
                elapsedAtSuspend += max(0, CMTimeSubtract(now, start).seconds)
                runningSince = nil
            }
        } else if loaded {
            runningSince = now
        }
        lock.unlock()
    }

    /// Frame-queue entry point: the frame whose timeline position best
    /// matches the elapsed loop clock.
    func currentTexture(at hostTime: CMTime) -> MTLTexture? {
        lock.lock()
        guard loaded else {
            lock.unlock()
            return nil
        }
        if !suspended {
            let target = elapsedLocked(atHost: hostTime)
            while let first = fifo.first, first.timelineSeconds <= target {
                lastDelivered = first
                fifo.removeFirst()
            }
        }
        if lastDelivered == nil, !fifo.isEmpty {
            lastDelivered = fifo.removeFirst()
        }
        let entry = lastDelivered
        let gen = generation
        var scheduleRefill = false
        if fifo.count < Self.decodeAhead, !fillScheduled {
            fillScheduled = true
            scheduleRefill = true
        }
        lock.unlock()

        if scheduleRefill {
            decodeQueue.async { [weak self] in self?.fill(generation: gen) }
        }
        guard let entry else { return nil }
        return texture(for: entry.buffer)
    }

    // MARK: - Private

    /// Caller holds `lock`.
    private func elapsedLocked(atHost host: CMTime) -> Double {
        guard let start = runningSince else { return elapsedAtSuspend }
        return elapsedAtSuspend + max(0, CMTimeSubtract(host, start).seconds)
    }

    private func fill(generation gen: UInt64) {
        lock.lock()
        fillScheduled = false
        lock.unlock()

        while true {
            lock.lock()
            guard gen == generation, loaded else {
                lock.unlock()
                return
            }
            let need = Self.decodeAhead - fifo.count
            let assetDuration = duration
            lock.unlock()
            guard need > 0 else { return }
            guard let output, let reader else { return }

            if let sample = output.copyNextSampleBuffer() {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let entry = FrameEntry(buffer: pixelBuffer,
                                       timelineSeconds: loopBase + pts)
                lock.lock()
                if gen == generation, loaded {
                    fifo.append(entry)
                }
                lock.unlock()
            } else {
                guard reader.status != .failed else { return }
                // End of pass: restart immediately. A layer always loops, so
                // there is no end-of-media state to publish.
                loopBase += assetDuration
                guard rebuildReader(at: 0) else { return }
            }
        }
    }

    @discardableResult
    private func rebuildReader(at seconds: Double) -> Bool {
        reader?.cancelReading()
        reader = nil
        output = nil
        guard let asset, let track,
              let (newReader, newOutput) = try? Self.makeReader(
                  asset: asset, track: track, startingAt: seconds) else {
            return false
        }
        reader = newReader
        output = newOutput
        return true
    }

    private func texture(for buffer: CVPixelBuffer) -> MTLTexture? {
        if cachedBuffer === buffer, let texture = cachedTexture {
            return texture
        }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        cachedBuffer = buffer
        cachedCVTexture = cvTexture
        cachedTexture = texture
        return texture
    }

    private static func makeReader(
        asset: AVAsset, track: AVAssetTrack, startingAt seconds: Double
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: prismPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PipelineError.encodingFailed("layer: cannot attach video output")
        }
        reader.add(output)
        if seconds > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: seconds, preferredTimescale: 600),
                duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            throw PipelineError.encodingFailed("layer: startReading failed")
        }
        return (reader, output)
    }
}

// MARK: - LayerSource

/// A still or a looping video, addressed uniformly. Reloading is keyed on
/// (url, kind) so re-applying an unchanged configuration — which happens on
/// every slider drag — does not tear down and restart a video layer.
/// `configure` runs on the main thread while `currentTexture` runs on the
/// frame queue, so the resolved state behind them is lock-guarded. The image
/// path is the reason: unlike the single-reference swaps elsewhere in the
/// stages, configure mutates several fields that must be observed together —
/// a frame that saw the new kind but the old texture would composite the
/// wrong file.
final class LayerSource {
    private let metal: MetalContext
    private let loader: MTKTextureLoader
    private let video: LoopingVideoSource
    private let text: TextRasterizer
    private let lock = NSLock()

    // lock-guarded
    private var currentURL: URL?
    private var currentKind: LayerSourceKind?
    private var imageTexture: MTLTexture?
    private var imageSize: CGSize?

    init(metal: MetalContext, label: String) {
        self.metal = metal
        loader = MTKTextureLoader(device: metal.device)
        video = LoopingVideoSource(metal: metal, label: label)
        text = TextRasterizer(metal: metal, label: label)
    }

    /// Main-thread configuration. Passing nil unloads. Keyed on (url, kind)
    /// so re-applying an unchanged configuration — which happens on every
    /// slider drag — never restarts a running video. The style is handed on
    /// unconditionally because the rasteriser keys on it in the same way,
    /// and only a text layer has one worth reacting to.
    func configure(url: URL?, kind: LayerSourceKind,
                   style: OverlayTextStyle = OverlayTextStyle()) {
        text.configure(kind == .text ? style : OverlayTextStyle())

        lock.lock()
        guard url != currentURL || kind != currentKind else {
            lock.unlock()
            return
        }
        currentURL = url
        currentKind = kind
        imageTexture = nil
        imageSize = nil
        lock.unlock()

        video.unload()
        guard let url else { return }
        switch kind {
        case .image:
            loadImage(url, expecting: url)
        case .video:
            _ = video.load(url: url)
        case .text, .live:
            // Not file-backed: a text layer is drawn from its style and a
            // live layer comes from a running capture session, so neither
            // has a URL to open here.
            break
        }
    }

    func setDemandActive(_ active: Bool) {
        video.setDemandActive(active)
    }

    /// Frame-queue entry point. `frameSize` is the picture the layer is about
    /// to be composited into, in pixels — the size a text layer rasterises
    /// against, and ignored by every other kind.
    func currentTexture(at hostTime: CMTime, frameSize: CGSize = .zero) -> MTLTexture? {
        lock.lock()
        let kind = currentKind
        let texture = imageTexture
        lock.unlock()
        switch kind {
        case .image: return texture
        case .video: return video.currentTexture(at: hostTime)
        case .text: return text.texture(frameSize: frameSize)
        case .live, nil: return nil
        }
    }

    /// Natural pixel size of the content, for aspect-correct placement.
    var contentSize: CGSize? {
        lock.lock()
        let kind = currentKind
        let size = imageSize
        lock.unlock()
        switch kind {
        case .image: return size
        case .video: return video.contentSize
        case .text: return text.contentSize
        case .live, nil: return nil
        }
    }

    private func loadImage(_ url: URL, expecting: URL) {
        // SRGB: false keeps the file's stored 8-bit values untouched, which
        // is how every other texture in this pipeline is treated (camera
        // BGRA is sampled raw). Letting the loader linearise here would make
        // a PNG backdrop render brighter than the same frame from a video.
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        // A failed load leaves the texture nil, and configure() is keyed on
        // the URL — so a broken path resolves to "draws nothing" once rather
        // than retrying a disk read on every frame.
        let loaded = try? loader.newTexture(URL: url, options: options)
        lock.lock()
        // Another configure() may have landed while the file was being read.
        if currentURL == expecting {
            imageTexture = loaded
            imageSize = loaded.map { CGSize(width: $0.width, height: $0.height) }
        }
        lock.unlock()
    }
}
