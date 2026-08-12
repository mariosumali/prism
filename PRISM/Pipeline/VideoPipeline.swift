// VideoPipeline.swift
// PRISM
//
// Frame-graph orchestration (§3.3): wraps camera pixel buffers as Metal
// textures, runs the fixed effect chain in a single command buffer per frame,
// records the FrameRing + sharpness score, handles freeze pick-up and the
// 200ms output crossfade, and emits IOSurface-backed output buffers at the
// negotiated format. Also defines MetalContext (device/queue/library/texture
// cache) and StageTimings.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import ObjectiveC
import QuartzCore

// MARK: - MetalContext

public final class MetalContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary            // default library (PRISMKernels)
    public let textureCache: CVMetalTextureCache

    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let pipelineLock = NSLock()

    /// Associated-object key used to pin the CVMetalTexture to the MTLTexture
    /// it vends, so the IOSurface binding stays alive for the frame.
    private static var cvTextureOwnerKey: UInt8 = 0

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PipelineError.pipelineStateUnavailable("No Metal device available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw PipelineError.pipelineStateUnavailable("Could not create MTLCommandQueue")
        }
        // The app's kernels live in Bundle.main; in the unit-test bundle they
        // compile into the bundle containing this class instead (identical to
        // Bundle.main when running as the app).
        guard let library = device.makeDefaultLibrary()
            ?? (try? device.makeDefaultLibrary(bundle: Bundle(for: MetalContext.self))) else {
            throw PipelineError.pipelineStateUnavailable("Default Metal library missing")
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw PipelineError.pipelineStateUnavailable("CVMetalTextureCacheCreate failed (\(status))")
        }
        self.device = device
        self.commandQueue = queue
        self.library = library
        self.textureCache = cache
    }

    /// BGRA8 texture view of an IOSurface-backed pixel buffer. Keeps the
    /// CVMetalTexture alive for the frame via the returned wrapper.
    public func makeTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw PipelineError.textureAllocationFailed
        }
        // The MTLTexture does not retain its CVMetalTexture; attach it so the
        // texture keeps the IOSurface mapping alive as long as it is referenced.
        objc_setAssociatedObject(texture, &MetalContext.cvTextureOwnerKey,
                                 cvTexture, .OBJC_ASSOCIATION_RETAIN)
        return texture
    }

    public func makeIntermediate(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw PipelineError.textureAllocationFailed
        }
        return texture
    }

    public func computePipeline(function: String) throws -> MTLComputePipelineState {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let cached = pipelineCache[function] { return cached }
        guard let fn = library.makeFunction(name: function) else {
            throw PipelineError.pipelineStateUnavailable("Missing kernel '\(function)'")
        }
        do {
            let state = try device.makeComputePipelineState(function: fn)
            pipelineCache[function] = state
            return state
        } catch {
            throw PipelineError.pipelineStateUnavailable(
                "Pipeline for '\(function)' failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - StageTimings

public struct StageTimings {
    public var captureToTextureMs: Double
    public var stageMs: [StageID: Double]   // estimated per-stage GPU ms
    public var totalGpuMs: Double
    public var wallMs: Double               // capture callback → push handoff
    public var dropped: Bool
    public init(captureToTextureMs: Double, stageMs: [StageID: Double],
                totalGpuMs: Double, wallMs: Double, dropped: Bool) {
        self.captureToTextureMs = captureToTextureMs
        self.stageMs = stageMs
        self.totalGpuMs = totalGpuMs
        self.wallMs = wallMs
        self.dropped = dropped
    }
}

// MARK: - VideoPipeline

/// Owns the stage array (fixed order §3.3), intermediate textures, output
/// pool, FrameRing and crossfade state. `submitCameraFrame` /
/// `tickWithoutCamera` run on the capture queue; one MTLCommandBuffer per
/// frame, one commit, one completed handler.
public final class VideoPipeline {
    public let metal: MetalContext
    public private(set) var stages: [EffectStage]      // chain order, outputFit last

    public let clipStage: ClipStage
    public let freezeStage: FreezeStage
    public let geometryStage: GeometryStage
    public let adjustStage: AdjustStage
    public let lutStage: LUTStage
    public let blurStage: BlurStage
    public let outputFitStage: OutputFitStage

    /// Post-effects output: IOSurface-backed buffer ready for the sink, plus
    /// the final texture for the preview. Invoked from the command buffer's
    /// completed handler (GPU work for the frame is finished at that point).
    public var onOutput: ((CVPixelBuffer, CMTime, MTLTexture) -> Void)?
    /// Per-frame timings for LatencyMonitor. Called on an arbitrary queue.
    public var onTimings: ((StageTimings) -> Void)?

    /// Preview texture retention: false tears the preview path down (§8.3).
    /// The pipeline itself keeps no preview-only resources; consumers gate
    /// their MTKView on this flag via AppState.
    public var previewEnabled: Bool = true

    // MARK: Private state

    /// Stages the user chain runs through; outputFit is applied separately as
    /// the always-on final fit.
    private let userStages: [EffectStage]
    private let frameRing: FrameRing
    private let sharpnessPipeline: MTLComputePipelineState
    private let crossfadePipeline: MTLComputePipelineState

    /// Bounds GPU backlog to two frames in flight; a frame arriving while both
    /// slots are busy is counted as dropped rather than queued (§3.4: a frame
    /// backlog is latency, and latency is the product's core promise).
    private let inFlight = DispatchSemaphore(value: 2)
    private let stateLock = NSLock()

    /// Serializes every entry into process() — camera frames (capture queue),
    /// the no-camera heartbeat (main), and the freeze pick — so the shared
    /// intermediates, FrameRing, and stage-internal state are never mutated
    /// concurrently. The camera path enters with `sync` (no extra hop on the
    /// hot path); the heartbeat and freeze paths hop on/into it.
    private let frameQueue = DispatchQueue(
        label: "horse.prism.PRISM.pipeline.frames", qos: .userInteractive)

    private var outputFormat = VideoFormat(width: 1920, height: 1080, frameRate: 30)
    private var outputPool: CVPixelBufferPool?
    private var workingWidth = 0
    private var workingHeight = 0
    private var intermediateA: MTLTexture?
    private var intermediateB: MTLTexture?
    private var outputScratch: MTLTexture?     // outputFit target while crossfading
    private var darkTexture: MTLTexture?       // neutral source for tickWithoutCamera

    private var frozenFlag = false
    private var lastFrameTime = CMTime.zero

    /// frameQueue-confined. Set when freeze is engaged but no frame exists to
    /// hold (capture stopped, ring empty); the next live camera frame becomes
    /// the freeze frame. Without this, live video would stream under a frozen
    /// UI once capture resumes — the most damaging failure this app can
    /// produce.
    private var freezePending = false

    /// Previous frame's final output, retained (buffer + texture) so a preset
    /// switch or clip→live return can crossfade from it (§5.5, §5.3).
    private var lastOutput: (buffer: CVPixelBuffer, texture: MTLTexture)?
    private var crossfadeActive = false
    private var crossfadeFrom: (buffer: CVPixelBuffer, texture: MTLTexture)?
    private var crossfadeStartTime: CFTimeInterval?
    private var crossfadeDurationMs: Double = 200

    /// Static GPU weight model. The whole command buffer is measured via
    /// gpuStartTime/gpuEndTime and attributed to the stages that encoded this
    /// frame proportionally to these fixed weights (CONTRACTS: keep the
    /// proportional model, deterministic and documented). Blur carries the
    /// segmentation composite plus two separable blur passes, hence 12.
    private static let stageWeights: [StageID: Double] = [
        .clip: 1, .freeze: 1, .geometry: 2, .adjust: 1,
        .lut: 3, .blur: 12, .outputFit: 1,
    ]

    // MARK: Init / configure

    public init(metal: MetalContext) throws {
        self.metal = metal
        clipStage = try ClipStage(metal: metal)
        freezeStage = try FreezeStage(metal: metal)
        geometryStage = try GeometryStage(metal: metal)
        adjustStage = try AdjustStage(metal: metal)
        lutStage = try LUTStage(metal: metal)
        blurStage = try BlurStage(metal: metal)
        outputFitStage = try OutputFitStage(metal: metal)
        userStages = [clipStage, freezeStage, geometryStage, adjustStage, lutStage, blurStage]
        stages = [clipStage, freezeStage, geometryStage, adjustStage, lutStage, blurStage, outputFitStage]
        frameRing = try FrameRing(metal: metal, width: 1920, height: 1080)
        sharpnessPipeline = try metal.computePipeline(function: "prism_sharpness")
        crossfadePipeline = try metal.computePipeline(function: "prism_crossfade")
        configure(outputFormat: VideoFormat(width: 1920, height: 1080, frameRate: 30))
    }

    public func configure(outputFormat: VideoFormat) {
        stateLock.lock()
        let dimensionsChanged = outputFormat.width != self.outputFormat.width
            || outputFormat.height != self.outputFormat.height
        self.outputFormat = outputFormat
        if dimensionsChanged || outputPool == nil {
            self.outputPool = Self.makeOutputPool(width: outputFormat.width,
                                                  height: outputFormat.height)
        }
        if dimensionsChanged {
            // Output-sized scratch resources are size-dependent; drop and
            // rebuild lazily. A crossfade spanning a dimension change is
            // abandoned — the two endpoints no longer share sizes. A
            // frame-rate-only change keeps the fade (and lastOutput) alive so
            // preset switches between rates still crossfade (§5.5).
            darkTexture = nil
            outputScratch = nil
            crossfadeActive = false
            crossfadeFrom = nil
            crossfadeStartTime = nil
            lastOutput = nil
        }
        stateLock.unlock()
        outputFitStage.outputSize = CGSize(width: outputFormat.width, height: outputFormat.height)
    }

    // MARK: Frozen state

    public var isFrozen: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return frozenFlag
    }

    /// §5.2 — freeze takes effect for the very next frame. The sharpest frame
    /// of the preceding 300ms is picked from the ring, copied into a private
    /// texture (so ring reuse cannot corrupt it), and handed to FreezeStage.
    /// While a clip is substituting, freeze pauses the clip instead (§5.3).
    public func setFrozen(_ frozen: Bool) {
        stateLock.lock()
        guard frozen != frozenFlag else {
            stateLock.unlock()
            return
        }
        frozenFlag = frozen
        let now = lastFrameTime
        stateLock.unlock()

        if frozen {
            clipStage.player?.holdCurrentFrame(true)
            // hasFrame (unlike wantsEncode/currentTexture) touches no
            // frame-path-confined texture caches, and the ring pick + freeze
            // mutation are serialized with process() on frameQueue.
            frameQueue.sync {
                let clipSubstituting = clipStage.isEnabled
                    && (clipStage.player?.hasFrame ?? false)
                if !clipSubstituting {
                    let pick = frameRing.sharpestFrame(nowTime: now, windowMs: 300)
                        ?? frameRing.sharpestFrame(nowTime: now, windowMs: .infinity)
                    if let pick, let copy = snapshotTexture(of: pick) {
                        freezeStage.freeze(texture: copy)
                    } else {
                        // Nothing to hold (capture stopped / ring empty).
                        // Defer: the first live frame becomes the freeze
                        // frame, so live video never leaks under a frozen UI.
                        freezePending = true
                    }
                }
            }
        } else {
            clipStage.player?.holdCurrentFrame(false)
            frameQueue.sync {
                freezeStage.unfreeze()
                freezePending = false
            }
        }
    }

    /// Re-arms the freeze frame from the most recent emitted output. Used
    /// when clip substitution ends while frozen (§5.2): without this the
    /// freeze stage holds nothing (freeze-during-clip relies on the clip
    /// holding its frame) and live video would silently resume while the UI
    /// still shows frozen — the most damaging failure this app can produce.
    public func refreezeFromCurrentOutput() {
        stateLock.lock()
        let last = lastOutput
        stateLock.unlock()
        guard let last else { return }
        frameQueue.sync {
            freezeStage.freeze(texture: last.texture)
        }
    }

    // MARK: Configuration

    public func apply(_ config: PipelineConfiguration) {
        adjustStage.settings = config.adjust
        lutStage.settings = config.lut
        blurStage.settings = config.blur
        geometryStage.settings = config.geometry
        geometryStage.isEnabled = config.flags(for: .geometry).enabled
        adjustStage.isEnabled = config.flags(for: .adjust).enabled
        lutStage.isEnabled = config.flags(for: .lut).enabled
        blurStage.isEnabled = config.flags(for: .blur).enabled
        // Auto-framing needs the segmentation mask even when blur is off (§5.4).
        blurStage.maskOnlyMode = config.geometry.autoFrame && !config.flags(for: .blur).enabled
        // Format and latency policy changes are orchestrated by AppState
        // (format renegotiation is a reconnect boundary, §3.2) — not here.
    }

    /// 200ms output crossfade (preset switch, clip → live return). Fades from
    /// the retained previous output into the live chain output.
    public func beginCrossfade(durationMs: Double) {
        stateLock.lock()
        if let last = lastOutput {
            crossfadeFrom = last
            crossfadeActive = true
            crossfadeStartTime = nil            // anchored on the next frame
            crossfadeDurationMs = max(1, durationMs)
        }
        stateLock.unlock()
    }

    // MARK: Frame entry points

    /// Live camera frame. Also drives clip/freeze substitution. Enters the
    /// frame path with `sync` so the calling capture thread does the work
    /// under frameQueue's exclusion — no extra hop on the hot path.
    public func submitCameraFrame(_ buffer: CVPixelBuffer, at time: CMTime) {
        frameQueue.sync {
            let wallStart = CACurrentMediaTime()
            guard inFlight.wait(timeout: .now()) == .success else {
                onTimings?(StageTimings(captureToTextureMs: 0, stageMs: [:],
                                        totalGpuMs: 0, wallMs: 0, dropped: true))
                return
            }
            do {
                let source = try metal.makeTexture(from: buffer)
                let captureMs = (CACurrentMediaTime() - wallStart) * 1000
                try process(source: source, cameraBuffer: buffer, time: time,
                            wallStart: wallStart, captureToTextureMs: captureMs)
            } catch {
                inFlight.signal()
                onTimings?(StageTimings(captureToTextureMs: 0, stageMs: [:],
                                        totalGpuMs: 0,
                                        wallMs: (CACurrentMediaTime() - wallStart) * 1000,
                                        dropped: true))
            }
        }
    }

    /// Heartbeat when no camera is available (timer-driven at output fps) so
    /// clip playback and freeze keep producing frames. Uses a neutral dark
    /// source texture at the output size in place of the camera. Hops onto
    /// frameQueue so it can never run process() concurrently with a camera
    /// frame arriving as the camera comes back (§5.1/§7).
    public func tickWithoutCamera(at time: CMTime) {
        frameQueue.async { [weak self] in
            guard let self else { return }
            let wallStart = CACurrentMediaTime()
            guard self.inFlight.wait(timeout: .now()) == .success else {
                self.onTimings?(StageTimings(captureToTextureMs: 0, stageMs: [:],
                                             totalGpuMs: 0, wallMs: 0, dropped: true))
                return
            }
            do {
                let source = try self.ensureDarkSource()
                try self.process(source: source, cameraBuffer: nil, time: time,
                                 wallStart: wallStart, captureToTextureMs: 0)
            } catch {
                self.inFlight.signal()
                self.onTimings?(StageTimings(captureToTextureMs: 0, stageMs: [:],
                                             totalGpuMs: 0,
                                             wallMs: (CACurrentMediaTime() - wallStart) * 1000,
                                             dropped: true))
            }
        }
    }

    // MARK: Core frame path

    /// Single command buffer per frame: ring record + sharpness → user chain
    /// (ping-pong intermediates at the working resolution) → output fit into
    /// a pool buffer (crossfaded while active) → one commit, one completed
    /// handler that reports timings and pushes the output.
    private func process(source: MTLTexture,
                         cameraBuffer: CVPixelBuffer?,
                         time: CMTime,
                         wallStart: CFTimeInterval,
                         captureToTextureMs: Double) throws {
        stateLock.lock()
        let pool = outputPool
        lastFrameTime = time
        stateLock.unlock()

        // Consume a deferred freeze: this is the first camera frame since
        // freeze was engaged with nothing to hold. Snapshot it before the
        // chain runs so the frozen image is this frame, not live video.
        if freezePending, cameraBuffer != nil,
           !(clipStage.isEnabled && (clipStage.player?.hasFrame ?? false)) {
            if let cameraBuffer, let copy = snapshotTexture(of: cameraBuffer) {
                freezeStage.freeze(texture: copy)
                freezePending = false
            }
        }

        guard let pool else { throw PipelineError.textureAllocationFailed }
        try ensureWorking(width: source.width, height: source.height)
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            throw PipelineError.encodingFailed("Could not create command buffer")
        }

        // Ring record + sharpness score, encoded into the same command buffer
        // (§5.2: never a separate synchronous pass). Camera frames only. The
        // slot is published (marked valid) only after this frame's command
        // buffer is committed, so a freeze pick can never snapshot a slot
        // whose copy has not yet been submitted to the queue.
        var ringSlot = -1
        if let cameraBuffer {
            ringSlot = frameRing.record(cameraBuffer, at: time, encoder: commandBuffer)
            if ringSlot >= 0 {
                encodeSharpness(into: commandBuffer, source: source, slot: ringSlot)
            }
        }

        // Fixed chain (§3.3). Stages whose wantsEncode() is false are skipped
        // entirely — their input passes through. Ping-pong between the two
        // working-resolution intermediates; `current` is never the same
        // texture as the destination by construction.
        var encoded: [StageID] = []
        var current = source
        var useA = true
        for stage in userStages where stage.wantsEncode() {
            guard let dst = useA ? intermediateA : intermediateB else {
                throw PipelineError.textureAllocationFailed
            }
            try stage.encode(commandBuffer: commandBuffer, input: current, output: dst)
            current = dst
            useA.toggle()
            encoded.append(stage.id)
        }

        // Output buffer at the negotiated format.
        var pixelBufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut) == kCVReturnSuccess,
              let outBuffer = pixelBufferOut else {
            throw PipelineError.textureAllocationFailed
        }
        let outTexture = try metal.makeTexture(from: outBuffer)

        // Crossfade bookkeeping (under the lock; encoding after).
        stateLock.lock()
        var fadeFrom: MTLTexture?
        var fadeMix: Double = 1
        if crossfadeActive, let from = crossfadeFrom,
           from.texture.width == outTexture.width,
           from.texture.height == outTexture.height {
            if crossfadeStartTime == nil { crossfadeStartTime = wallStart }
            let elapsedMs = (wallStart - (crossfadeStartTime ?? wallStart)) * 1000
            fadeMix = min(1, max(0, elapsedMs / crossfadeDurationMs))
            fadeFrom = from.texture
            if fadeMix >= 1 {
                crossfadeActive = false
                crossfadeFrom = nil
                crossfadeStartTime = nil
            }
        } else if crossfadeActive {
            // Dimensions diverged (format change mid-fade): abandon the fade.
            crossfadeActive = false
            crossfadeFrom = nil
            crossfadeStartTime = nil
        }
        stateLock.unlock()

        // Output fit always runs (§3.3); while a crossfade is active it lands
        // in a scratch texture and prism_crossfade is the final pass.
        if let fadeFrom {
            let scratch = try ensureOutputScratch()
            try outputFitStage.encode(commandBuffer: commandBuffer, input: current, output: scratch)
            encodeCrossfade(into: commandBuffer, a: fadeFrom, b: scratch,
                            dst: outTexture, mix: Float(fadeMix))
        } else {
            try outputFitStage.encode(commandBuffer: commandBuffer, input: current, output: outTexture)
        }
        encoded.append(.outputFit)

        let semaphore = inFlight
        let captureMs = captureToTextureMs
        commandBuffer.addCompletedHandler { [weak self] finished in
            semaphore.signal()
            guard let self else { return }
            let wallMs = (CACurrentMediaTime() - wallStart) * 1000
            guard finished.error == nil else {
                self.onTimings?(StageTimings(captureToTextureMs: captureMs, stageMs: [:],
                                             totalGpuMs: 0, wallMs: wallMs, dropped: true))
                return
            }
            let gpuMs = max(0, (finished.gpuEndTime - finished.gpuStartTime) * 1000)
            let stageMs = Self.attribute(totalGpuMs: gpuMs, to: encoded)
            self.stateLock.lock()
            self.lastOutput = (outBuffer, outTexture)
            self.stateLock.unlock()
            self.onOutput?(outBuffer, time, outTexture)
            self.onTimings?(StageTimings(captureToTextureMs: captureMs, stageMs: stageMs,
                                         totalGpuMs: gpuMs, wallMs: wallMs, dropped: false))
        }
        commandBuffer.commit()
        if ringSlot >= 0 {
            // Committed: queue order now guarantees any later snapshot blit
            // sees this slot's new contents.
            frameRing.publish(slot: ringSlot)
        }
    }

    // MARK: Encoding helpers

    private func encodeSharpness(into commandBuffer: MTLCommandBuffer,
                                 source: MTLTexture, slot: Int) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(sharpnessPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(frameRing.sharpnessBuffer, offset: 0, index: 0)
        var params = PRISMSharpnessParams()
        params.slot = UInt32(slot)
        encoder.setBytes(&params, length: MemoryLayout<PRISMSharpnessParams>.stride, index: 1)
        // One threadgroup of 256 threads striding a 128×72 sample grid (contract).
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
    }

    private func encodeCrossfade(into commandBuffer: MTLCommandBuffer,
                                 a: MTLTexture, b: MTLTexture,
                                 dst: MTLTexture, mix: Float) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(crossfadePipeline)
        encoder.setTexture(a, index: 0)
        encoder.setTexture(b, index: 1)
        encoder.setTexture(dst, index: 2)
        var params = PRISMCrossfadeParams()
        params.mix = mix
        encoder.setBytes(&params, length: MemoryLayout<PRISMCrossfadeParams>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (dst.width + group.width - 1) / group.width,
                           height: (dst.height + group.height - 1) / group.height,
                           depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    // MARK: Resource management

    private func ensureWorking(width: Int, height: Int) throws {
        stateLock.lock()
        let frameRate = outputFormat.frameRate
        stateLock.unlock()
        if width != workingWidth || height != workingHeight
            || intermediateA == nil || intermediateB == nil {
            intermediateA = try metal.makeIntermediate(width: width, height: height)
            intermediateB = try metal.makeIntermediate(width: width, height: height)
            workingWidth = width
            workingHeight = height
        }
        // §5.2: the ring retains 500ms, so its capacity follows the frame
        // rate; reconfigure early-returns when nothing changed.
        try frameRing.reconfigure(width: width, height: height, frameRate: frameRate)
    }

    private func ensureOutputScratch() throws -> MTLTexture {
        stateLock.lock()
        let format = outputFormat
        if let scratch = outputScratch,
           scratch.width == format.width, scratch.height == format.height {
            stateLock.unlock()
            return scratch
        }
        stateLock.unlock()
        let texture = try metal.makeIntermediate(width: format.width, height: format.height)
        stateLock.lock()
        outputScratch = texture
        stateLock.unlock()
        return texture
    }

    /// Neutral dark source (BGRA 30/30/30, opaque) at the output size for
    /// camera-less operation. CPU-filled once per format change.
    private func ensureDarkSource() throws -> MTLTexture {
        stateLock.lock()
        let format = outputFormat
        if let dark = darkTexture,
           dark.width == format.width, dark.height == format.height {
            stateLock.unlock()
            return dark
        }
        stateLock.unlock()

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: format.width, height: format.height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = metal.device.hasUnifiedMemory ? .shared : .managed
        guard let texture = metal.device.makeTexture(descriptor: desc) else {
            throw PipelineError.textureAllocationFailed
        }
        let bytesPerRow = format.width * 4
        var row = [UInt8](repeating: 0, count: bytesPerRow)
        for x in 0..<format.width {
            row[x * 4 + 0] = 30   // B
            row[x * 4 + 1] = 30   // G
            row[x * 4 + 2] = 30   // R
            row[x * 4 + 3] = 255  // A
        }
        for y in 0..<format.height {
            texture.replace(region: MTLRegionMake2D(0, y, format.width, 1),
                            mipmapLevel: 0, withBytes: row, bytesPerRow: bytesPerRow)
        }
        stateLock.lock()
        darkTexture = texture
        stateLock.unlock()
        return texture
    }

    /// Copies a ring frame into a private texture so ring slot reuse cannot
    /// corrupt a held freeze frame. This is an event-path command buffer (the
    /// one-command-buffer rule applies to the per-frame path); queue ordering
    /// guarantees the copy lands before any later ring overwrite.
    private func snapshotTexture(of pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let source = try? metal.makeTexture(from: pixelBuffer),
              let copy = try? metal.makeIntermediate(width: source.width, height: source.height),
              let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(from: source, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        return copy
    }

    // MARK: Static helpers

    private static func makeOutputPool(width: Int, height: Int) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let bufferAttrs = prismPixelBufferAttributes(width: width, height: height)
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttrs as CFDictionary,
                                             bufferAttrs as CFDictionary,
                                             &pool)
        return status == kCVReturnSuccess ? pool : nil
    }

    private static func attribute(totalGpuMs: Double, to encoded: [StageID]) -> [StageID: Double] {
        guard !encoded.isEmpty else { return [:] }
        let weights = encoded.map { stageWeights[$0] ?? 1 }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return [:] }
        var result: [StageID: Double] = [:]
        for (id, weight) in zip(encoded, weights) {
            result[id] = totalGpuMs * weight / sum
        }
        return result
    }
}
