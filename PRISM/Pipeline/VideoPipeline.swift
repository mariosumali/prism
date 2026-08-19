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

    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let pipelineLock = NSLock()

    /// Associated-object key used to pin the pixel buffer to the MTLTexture
    /// that views it, so its IOSurface stays out of the pool's free list for
    /// as long as anything holds the texture.
    private static var pixelBufferOwnerKey: UInt8 = 0

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
        self.device = device
        self.commandQueue = queue
        self.library = library
    }

    /// BGRA8 texture view of an IOSurface-backed pixel buffer.
    ///
    /// Built straight from the buffer's IOSurface rather than through a
    /// CVMetalTextureCache. The cache route hands back a CVMetalTexture that
    /// owns the MTLTexture, and it has to outlive every use of that texture
    /// — but pinning it to the texture (the obvious way to arrange that) is
    /// a retain cycle, so neither is ever freed and every wrapped frame
    /// keeps its IOSurface. Nothing looks wrong until the process hits the
    /// per-client limit of 16384 surfaces and dies: about nine minutes of
    /// 30 fps, which is exactly how it presented (a crash mid-session, with
    /// "IOSurface creation failed … likely per client IOSurface limit
    /// reached" filling the log).
    ///
    /// Attaching the pixel buffer to the texture instead is one-way, so the
    /// pair is released together: the surface stays out of the pool's free
    /// list while the texture is referenced, and goes back the moment it is
    /// not. The texture holds its own reference to the surface, so the
    /// pixels remain valid for as long as the texture does.
    public func makeTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            throw PipelineError.textureAllocationFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        // An IOSurface-backed texture is never .private; on Apple silicon the
        // surface is already shared with the CPU, on Intel it is managed.
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor,
                                               iosurface: surface,
                                               plane: 0) else {
            throw PipelineError.textureAllocationFailed
        }
        objc_setAssociatedObject(texture, &MetalContext.pixelBufferOwnerKey,
                                 pixelBuffer, .OBJC_ASSOCIATION_RETAIN)
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
    public let replayStage: ReplayStage
    public let freezeStage: FreezeStage
    public let gazeStage: GazeStage
    public let geometryStage: GeometryStage
    public let retouchStage: RetouchStage
    public let adjustStage: AdjustStage
    public let lutStage: LUTStage
    public let blurStage: BlurStage
    public let backgroundStage: BackgroundStage
    public let overlayStage: OverlayStage
    public let styleStage: StyleStage
    public let connectionStage: ConnectionStage
    public let outputFitStage: OutputFitStage

    /// One person mask, shared by blur, virtual background, behind-the-
    /// subject overlay layers, and auto-framing (§5.4, §5.7, §5.8).
    public let segmenter: PersonSegmenter
    /// One face measurement, shared by eye contact, retouch and the
    /// face-anchored overlay layers (§5.6).
    public let faceTracker: FaceTracker
    /// Decides which of them runs this frame, and which frames a modality
    /// added later gets. One request per modality per frame, at most one
    /// modality per frame.
    public let vision = VisionCoordinator()
    /// Rolling buffer behind instant replay and the away loop (§5.9, §5.10).
    public let replayBuffer: ReplayBuffer
    public let replayPlayer: ReplayPlayer
    /// A fifth of a second of finished frames, scored, so a still can be the
    /// sharpest of them (§5.16). Disarmed — and empty — by default.
    public let stillRing: StillRing
    /// Whichever of the camera and the screen is not driving the chain, for
    /// `.live` overlay layers (§5.25). Published into from the capture
    /// queues; read from the frame queue.
    let liveFeeds: LiveFeeds

    /// Post-effects output: IOSurface-backed buffer ready for the sink, plus
    /// the final texture for the preview. Invoked from the command buffer's
    /// completed handler (GPU work for the frame is finished at that point).
    public var onOutput: ((CVPixelBuffer, CMTime, MTLTexture) -> Void)?
    /// Per-frame timings for LatencyMonitor. Called on an arbitrary queue.
    public var onTimings: ((StageTimings) -> Void)?
    /// Fires when the memory plan changes — a new format, or the still ring
    /// being armed. Called on the caller's queue, only on an actual change.
    public var onResourcePlan: ((ResourcePlan) -> Void)?

    /// What ResourceGovernor granted at the current format (§7). Read by the
    /// diagnostics pane; the ring depths below are already following it.
    public private(set) var resourcePlan: ResourcePlan

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
    /// Auto-framing's mask demand — the one consumer with no stage of its own.
    private var autoFrameNeedsMask = false
    /// §5.16's setting, remembered so a format change can re-plan against it
    /// without waiting for the next applyStudio.
    private var stillsWantSharpest = false
    /// §5.24 — a ScreenCaptureKit session is running, so its frame queue is
    /// spoken for in the memory plan.
    private var screenSourceActive = false
    /// Counts camera frames past the freeze ring, and the stride it is
    /// counted against — read off the plan once per frame in ensureWorking so
    /// the hot path never takes stateLock for it. Both frameQueue-confined.
    private var ringStrideCounter: UInt64 = 0
    private var ringStride = 1

    /// frameQueue-confined. Set when freeze is engaged but no frame exists to
    /// hold (capture stopped, ring empty); the next live camera frame becomes
    /// the freeze frame. Without this, live video would stream under a frozen
    /// UI once capture resumes — the most damaging failure this app can
    /// produce.
    private var freezePending = false

    /// Previous frame's final output, retained (buffer + texture) so a preset
    /// switch or clip→live return can crossfade from it (§5.5, §5.3).
    private var lastOutput: (buffer: CVPixelBuffer, texture: MTLTexture)?
    /// Host time the last output was emitted at. `lastOutput` alone cannot
    /// answer "is the picture still moving?" — a stalled chain keeps handing
    /// back the same perfectly valid frame forever.
    private var lastOutputHostSeconds: CFTimeInterval?
    private var crossfadeActive = false
    private var crossfadeFrom: (buffer: CVPixelBuffer, texture: MTLTexture)?
    private var crossfadeStartTime: CFTimeInterval?
    private var crossfadeDurationMs: Double = 200

    /// Static GPU weight model. The whole command buffer is measured via
    /// gpuStartTime/gpuEndTime and attributed to the stages that encoded this
    /// frame proportionally to these fixed weights (CONTRACTS: keep the
    /// proportional model, deterministic and documented). Blur carries two
    /// separable blur passes plus the composite, hence 12. Eye contact is a
    /// single full-frame warp on the GPU but drags a Vision landmark request
    /// behind it, and the degradation engine has to see that cost somewhere.
    /// Overlay carries several layer kinds now, each its own full-frame pass.
    /// Style can run a second pass when looks stack. Both are weighted for the
    /// typical case rather than the worst one; a maximal scene under-reports
    /// somewhat, which is the acceptable direction — the model is
    /// proportional, not a measurement.
    ///
    /// Retouch's 9 was 5 while the stage was a registered skeleton, which was
    /// a guess. Measured at 1080p it costs 0.64 ms at the default amount and
    /// 0.78 ms at full against blur's 0.92 ms, so it sits just under blur
    /// rather than at half of it — its bilateral taps are dearer than a
    /// Gaussian's and it runs the same four-pass shape.
    ///
    /// Internal rather than private so ChainRegistrationTests can prove every
    /// StageID has an entry: a missing weight silently attributes 1ms-equivalent
    /// to a stage that may be the most expensive in the chain.
    static let stageWeights: [StageID: Double] = [
        .clip: 1, .replay: 1, .freeze: 1, .gaze: 8, .geometry: 2,
        .retouch: 9, .adjust: 1, .lut: 3, .blur: 12, .background: 6,
        .overlay: 3, .style: 5, .connection: 1, .outputFit: 1,
    ]

    /// Where in the chain segmentation is taken: the first stage that
    /// consumes the person mask — post-geometry, so the mask lines up with
    /// everything that samples it, and so AutoFramer stays the closed-loop
    /// servo it is documented to be (§5.4).
    ///
    /// Retouch is deliberately absent: its skin gate is chroma, not a person
    /// mask, and listing it here would move segmentation two stages earlier
    /// and demand a Vision request for a stage that only wants the mask if one
    /// happens to exist.
    ///
    /// Whether it runs at all is VisionCoordinator's answer, not this set's —
    /// this only says where.
    private static let maskConsumers: Set<StageID> = [.blur, .background, .overlay]

    /// Where the shared face measurement is taken: pre-geometry, which is the
    /// space eye contact warps in (§5.6) and the space face-anchored overlay
    /// layers are placed in before the geometry matrix carries them forward.
    private static let faceConsumers: Set<StageID> = [.gaze, .overlay]

    /// Where the live feeds are held or released: the first stage that can
    /// composite one. Taken here rather than up front because by this point
    /// in the walk every stage that can substitute the picture has already
    /// had its say, and `encoded` is the record of what they decided.
    private static let liveFeedConsumers: Set<StageID> = [.overlay]

    /// The stages that replace the picture wholesale rather than modifying
    /// it. A `.live` layer downstream of one of these would keep moving under
    /// a picture the user believes is held — the failure §5.25 exists to
    /// prevent — so this set is what the hold is keyed on. Internal so
    /// ChainRegistrationTests can prove it stays complete and stays upstream
    /// of the layers.
    static let substitutingStages: Set<StageID> = [.clip, .replay, .freeze]

    // MARK: Init / configure

    public init(metal: MetalContext) throws {
        self.metal = metal
        let initialFormat = VideoFormat(width: 1920, height: 1080, frameRate: 30)
        let initialPlan = ResourceGovernor.plan(
            for: ResourceDemand(format: initialFormat))
        resourcePlan = initialPlan
        segmenter = try PersonSegmenter(metal: metal)
        faceTracker = try FaceTracker(metal: metal)
        replayBuffer = try ReplayBuffer(metal: metal)
        replayPlayer = ReplayPlayer(metal: metal, buffer: replayBuffer)
        liveFeeds = LiveFeeds(metal: metal)

        clipStage = try ClipStage(metal: metal)
        replayStage = try ReplayStage(metal: metal)
        freezeStage = try FreezeStage(metal: metal)
        gazeStage = try GazeStage(metal: metal, faceTracker: faceTracker)
        geometryStage = try GeometryStage(metal: metal)
        retouchStage = try RetouchStage(metal: metal, segmenter: segmenter)
        adjustStage = try AdjustStage(metal: metal)
        lutStage = try LUTStage(metal: metal)
        blurStage = try BlurStage(metal: metal, segmenter: segmenter)
        backgroundStage = try BackgroundStage(metal: metal, segmenter: segmenter)
        overlayStage = try OverlayStage(metal: metal, segmenter: segmenter,
                                        faceTracker: faceTracker)
        styleStage = try StyleStage(metal: metal)
        connectionStage = try ConnectionStage(metal: metal)
        outputFitStage = try OutputFitStage(metal: metal)

        userStages = [clipStage, replayStage, freezeStage, gazeStage, geometryStage,
                      retouchStage, adjustStage, lutStage, blurStage, backgroundStage,
                      overlayStage, styleStage, connectionStage]
        stages = userStages + [outputFitStage]

        frameRing = try FrameRing(metal: metal, width: initialFormat.width,
                                  height: initialFormat.height,
                                  depth: initialPlan.freezeDepth)
        stillRing = try StillRing(metal: metal)
        sharpnessPipeline = try metal.computePipeline(function: "prism_sharpness")
        crossfadePipeline = try metal.computePipeline(function: "prism_crossfade")
        replayStage.player = replayPlayer
        overlayStage.liveFeeds = liveFeeds

        // Every consumer of a Vision modality, declared once. The demands are
        // asked rather than pushed because a stage's enabled flag is written
        // from presets, per-app rules, hotkeys, gestures, panic and the
        // degradation engine — six writers, and a cached copy would be stale
        // at one of them.
        vision.register(.face, cadence: 2)
        vision.register(.person, cadence: 2)
        let gaze = gazeStage, overlay = overlayStage
        let blur = blurStage, background = backgroundStage
        vision.addConsumer(of: .face) { gaze.wantsEncode() }
        // A frame-anchored layer never reaches this, so nobody pays for
        // Vision because they dropped a lower third on the picture.
        vision.addConsumer(of: .face) { overlay.needsFaceTracker }
        vision.addConsumer(of: .person) { blur.isEnabled }
        vision.addConsumer(of: .person) { background.needsPersonMask }
        vision.addConsumer(of: .person) { overlay.needsPersonMask }
        // Auto-framing is the one consumer with no stage of its own, and the
        // reason the mask survives the degradation engine turning blur off.
        vision.addConsumer(of: .person) { [weak self] in
            self?.autoFrameNeedsMask ?? false
        }

        configure(outputFormat: initialFormat)
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
        replan()
    }

    /// Re-asks ResourceGovernor and applies the answer. Called whenever an
    /// input to the plan moves — the negotiated format, or the still ring
    /// being armed — so the depths can never drift from the plan the
    /// diagnostics pane is showing.
    private func replan() {
        stateLock.lock()
        let demand = ResourceDemand(format: outputFormat,
                                    stillsWantSharpest: stillsWantSharpest,
                                    screenSourceActive: screenSourceActive)
        let plan = ResourceGovernor.plan(for: demand)
        let changed = plan != resourcePlan
        resourcePlan = plan
        stateLock.unlock()
        guard changed else { return }
        stillRing.setDepth(plan.stillDepth)
        // No frame ring call here: it is sized to the camera's dimensions
        // rather than the output's, so ensureWorking applies the new depth on
        // the next frame, where it already knows how big a slot has to be.
        onResourcePlan?(plan)
    }

    /// How long ago the last frame reached the sink; nil before the first one.
    /// Polled by anything that has to distinguish "PRISM is quiet" from "PRISM
    /// stopped" — the two look identical from outside the frame path.
    public var lastOutputAgeSeconds: Double? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let emitted = lastOutputHostSeconds else { return nil }
        return max(0, CACurrentMediaTime() - emitted)
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
            // A replay or away loop is substituting upstream of freeze, so
            // the FrameRing (which holds live camera frames) is the wrong
            // source entirely — freeze the picture that is actually on air.
            if replayStage.isEnabled, replayPlayer.isActive {
                refreezeFromCurrentOutput()
                return
            }
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
        retouchStage.settings = config.retouch
        lutStage.settings = config.lut
        blurStage.settings = config.blur
        geometryStage.settings = config.geometry
        gazeStage.settings = config.gaze
        backgroundStage.settings = config.background
        overlayStage.settings = config.overlay
        styleStage.settings = config.style
        // The quality tier belongs to the shared segmenter now; blur is
        // simply where the user happens to set it. Landmark smoothing is the
        // same arrangement one level along: the tracker smooths, eye contact
        // is simply where the knob lives.
        segmenter.quality = config.blur.quality
        faceTracker.smoothing = config.gaze.smoothing

        geometryStage.isEnabled = config.flags(for: .geometry).enabled
        retouchStage.isEnabled = config.flags(for: .retouch).enabled
        adjustStage.isEnabled = config.flags(for: .adjust).enabled
        lutStage.isEnabled = config.flags(for: .lut).enabled
        blurStage.isEnabled = config.flags(for: .blur).enabled
        backgroundStage.isEnabled = config.flags(for: .background).enabled
        overlayStage.isEnabled = config.flags(for: .overlay).enabled
        styleStage.isEnabled = config.flags(for: .style).enabled

        let gazeWasEnabled = gazeStage.isEnabled
        gazeStage.isEnabled = config.flags(for: .gaze).enabled
        if !gazeWasEnabled && gazeStage.isEnabled {
            // Never warp from where the eyes were before the stage was off.
            gazeStage.reset()
        }

        // Auto-framing needs the mask even when nothing visual consumes it
        // (§5.4). Recorded here rather than inferred per frame because it is
        // the one demand with no corresponding stage.
        autoFrameNeedsMask = config.geometry.autoFrame
        // Format and latency policy changes are orchestrated by AppState
        // (format renegotiation is a reconnect boundary, §3.2) — not here.
    }

    /// Arms or disarms the rolling replay buffer (§5.9, §5.10). Separate from
    /// `apply` because it is behaviour, not a look: a preset switch must not
    /// silently start or stop recording.
    public func applyStudio(_ settings: StudioSettings) {
        stateLock.lock()
        let frameRate = outputFormat.frameRate
        stateLock.unlock()
        replayBuffer.configure(armed: settings.replay.isArmed,
                               bufferSeconds: settings.replay.clampedBufferSeconds,
                               maxHeight: settings.replay.maxHeight,
                               frameRate: frameRate)
        // Severity edits apply live while engaged; engagement itself is an
        // AppState intent (§5.14), exactly like freeze.
        connectionStage.settings = settings.connection
        // §5.16: holding finished frames is the cost of the "sharpest frame"
        // setting, so it is paid only while that setting is on — and how many
        // it may hold is §7's call, not the setting's.
        stateLock.lock()
        stillsWantSharpest = settings.capture.prefersSharp
        stateLock.unlock()
        stillRing.setArmed(settings.capture.prefersSharp)
        replan()
    }

    /// §5.24 — a screen capture session is running (as the source, or behind
    /// a picture-in-picture layer). Separate from `apply` because it is not a
    /// look: it is a capture session whose frame queue is a real allocation,
    /// and §5.23 has to see it before it hands the rest of the ceiling out.
    public func setScreenSourceActive(_ active: Bool) {
        stateLock.lock()
        guard active != screenSourceActive else {
            stateLock.unlock()
            return
        }
        screenSourceActive = active
        stateLock.unlock()
        replan()
    }

    /// The frame a still should be written from (§5.16): the sharpest of the
    /// last fifth of a second when the ring is armed, otherwise simply the
    /// last frame that reached the sink — which is the honest answer to
    /// "save what I am looking at".
    ///
    /// Either way this is the finished picture, post-effects, and it is a
    /// pool buffer: the caller must copy the pixels out rather than hold it.
    public func stillFrame() -> CVPixelBuffer? {
        if let pick = stillRing.sharpest(now: CACurrentMediaTime(),
                                         windowSeconds: 0.5) {
            return pick
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastOutput?.buffer
    }

    /// Forwards the pipeline's demand gate to every stage that owns a media
    /// clock, so an idle PRISM neither decodes nor fast-forwards on wake.
    public func setDemandActive(_ active: Bool) {
        backgroundStage.setDemandActive(active)
        overlayStage.setDemandActive(active)
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
        // (§5.2: never a separate synchronous pass). Camera frames only, and
        // only every `freezeStride`-th of those — at 60 fps the ring covers
        // its window by sampling it rather than by holding twice the frames
        // (§7). The slot is published (marked valid) only after this frame's
        // command buffer is committed, so a freeze pick can never snapshot a
        // slot whose copy has not yet been submitted to the queue.
        var ringSlot = -1
        if let cameraBuffer, ringStrideCounter % UInt64(ringStride) == 0 {
            ringSlot = frameRing.record(cameraBuffer, at: time, encoder: commandBuffer)
            if ringSlot >= 0 {
                encodeSharpness(into: commandBuffer, source: source, slot: ringSlot,
                                result: frameRing.sharpnessBuffer)
            }
        }
        if cameraBuffer != nil { ringStrideCounter &+= 1 }

        // Rolling replay buffer (§5.9): raw camera frames only, recorded
        // upstream of every effect so a replay runs the live chain rather
        // than double-applying it. The downscale and thumbnail passes ride
        // this frame's command buffer; the handoff to the encoder waits for
        // the completed handler, where the pixels are actually finished.
        var pendingReplay: ReplayBuffer.PendingRecord?
        if cameraBuffer != nil {
            pendingReplay = replayBuffer.prepare(commandBuffer: commandBuffer,
                                                 source: source,
                                                 hostSeconds: CMTimeGetSeconds(time))
        }

        // Fixed chain (§3.3). Stages whose wantsEncode() is false are skipped
        // entirely — their input passes through. Ping-pong between the two
        // working-resolution intermediates; `current` is never the same
        // texture as the destination by construction.
        var encoded: [StageID] = []
        var current = source
        var useA = true
        var segmentationDone = false
        var faceTrackingDone = false
        var liveFeedsDecided = false
        // One decision for the whole frame, taken before any stage runs: what
        // Vision is wanted, and which single modality gets this frame.
        let visionDecision = vision.beginFrame()
        // The face is measured pre-Geometry and the layers land post-Geometry,
        // so the overlay stage needs this frame's crop to put a prop back on
        // the head it was measured on. The working resolution goes with it:
        // a caption is quoted in points and has to be drawn against the
        // picture it will land in (§5.26).
        overlayStage.frameSize = CGSize(width: source.width, height: source.height)
        overlayStage.faceSpaceTransform = geometryStage.appliedUVTransform(
            inputSize: CGSize(width: source.width, height: source.height))
        for stage in userStages {
            // The face measurement is taken at the first consumer's position,
            // for the same reason as the mask below: two stages each running
            // their own would pay twice for identical numbers.
            if !faceTrackingDone, Self.faceConsumers.contains(stage.id) {
                faceTrackingDone = true
                if visionDecision.demanded.contains(.face) {
                    faceTracker.isDemanded = true
                    faceTracker.update(commandBuffer: commandBuffer, input: current,
                                       capture: visionDecision.running == .face)
                } else if visionDecision.ended.contains(.face) {
                    // Last consumer just went away: drop the face so nothing
                    // re-enabled later anchors to a stale one.
                    faceTracker.isDemanded = false
                    faceTracker.invalidate()
                }
            }
            // The mask is taken at the first mask consumer's position in the
            // chain. Driven here rather than from inside a stage so it does
            // not depend on which of blur / background / overlay happens to be
            // enabled — they all sample the same post-geometry `current`, and
            // auto-framing needs the mask when none of them are on at all.
            if !segmentationDone, Self.maskConsumers.contains(stage.id) {
                segmentationDone = true
                if visionDecision.demanded.contains(.person) {
                    segmenter.isDemanded = true
                    segmenter.update(commandBuffer: commandBuffer, input: current,
                                     capture: visionDecision.running == .person)
                } else if visionDecision.ended.contains(.person) {
                    // Last consumer just went away: drop the mask so nothing
                    // re-enabled later composites against a stale subject.
                    segmenter.isDemanded = false
                    segmenter.invalidate()
                }
            }
            // §5.25: a substituting stage has replaced the picture, so every
            // live layer riding on top of it holds too. Both directions are
            // the same failure — a face still talking over a frozen screen,
            // a screen still scrolling behind a frozen face — and this is
            // the one place that can see either of them happen.
            if !liveFeedsDecided, Self.liveFeedConsumers.contains(stage.id) {
                liveFeedsDecided = true
                liveFeeds.setHeld(encoded.contains { Self.substitutingStages.contains($0) })
            }
            guard stage.wantsEncode() else { continue }
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

        // §5.16: the still ring takes a reference to the finished frame — no
        // copy, no extra pass — and one threadgroup scores it. The slot is
        // published from the completed handler, because the pixels this
        // scores are not final until the GPU says so.
        let stillSlot = stillRing.record(outBuffer, at: CACurrentMediaTime())
        if stillSlot >= 0 {
            encodeSharpness(into: commandBuffer, source: outTexture, slot: stillSlot,
                            result: stillRing.sharpnessBuffer)
        }

        let semaphore = inFlight
        let captureMs = captureToTextureMs
        let replayRecord = pendingReplay
        commandBuffer.addCompletedHandler { [weak self] finished in
            semaphore.signal()
            guard let self else { return }
            let wallMs = (CACurrentMediaTime() - wallStart) * 1000
            guard finished.error == nil else {
                self.onTimings?(StageTimings(captureToTextureMs: captureMs, stageMs: [:],
                                             totalGpuMs: 0, wallMs: wallMs, dropped: true))
                return
            }
            if let replayRecord {
                self.replayBuffer.commit(replayRecord)
            }
            if stillSlot >= 0 {
                self.stillRing.publish(slot: stillSlot)
            }
            let gpuMs = max(0, (finished.gpuEndTime - finished.gpuStartTime) * 1000)
            let stageMs = Self.attribute(totalGpuMs: gpuMs, to: encoded)
            self.stateLock.lock()
            self.lastOutput = (outBuffer, outTexture)
            self.lastOutputHostSeconds = CACurrentMediaTime()
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

    /// Laplacian-variance score for one ring slot. Two rings use it: the
    /// camera-side FrameRing behind freeze (§5.2) and the output-side
    /// StillRing behind stills (§5.16), which is why the destination buffer
    /// is a parameter rather than a constant.
    private func encodeSharpness(into commandBuffer: MTLCommandBuffer,
                                 source: MTLTexture, slot: Int,
                                 result: MTLBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(sharpnessPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(result, offset: 0, index: 0)
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
        let depth = resourcePlan.freezeDepth
        ringStride = max(1, resourcePlan.freezeStride)
        stateLock.unlock()
        if width != workingWidth || height != workingHeight
            || intermediateA == nil || intermediateB == nil {
            intermediateA = try metal.makeIntermediate(width: width, height: height)
            intermediateB = try metal.makeIntermediate(width: width, height: height)
            workingWidth = width
            workingHeight = height
        }
        // §5.2/§7: how far back the ring reaches is the governor's call and
        // moves with the format; reconfigure early-returns when nothing
        // changed, so this costs a comparison per frame.
        try frameRing.reconfigure(width: width, height: height, depth: depth)
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
