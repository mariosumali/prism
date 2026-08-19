// DraftRenderer.swift
// PRISM
//
// Preview-only render of a pending (draft) configuration. While the main
// window stages edits, this runs its own copies of the user stages
// (Geometry → Adjust → LUT → Blur, then output fit) over the same camera
// frames the live pipeline gets — so the user previews the draft while
// every client app keeps seeing the applied look. Deliberately not a
// VideoPipeline: no FrameRing, no sharpness scoring, no output pool, no
// crossfade, no freeze/clip substitution — a draft preview shows the live
// camera with the draft look, nothing more, and costs a few textures
// instead of a second frame ring.
//
// Threading mirrors VideoPipeline: apply()/configure() from the main
// thread, submit() from the capture thread (hops to its own serial queue;
// one frame in flight, extras dropped — a preview can be lossy, the
// virtual camera cannot). onOutput fires on Metal's completion thread.
//
// Outputs are CVPixelBufferPool-backed for the same reason the live path's
// are: the preview MTKView samples on its OWN command queue, and the only
// cross-queue safety Metal gives us here is retention — a pool buffer
// pinned by the preview's texture reference cannot be recycled, whereas a
// fixed texture slot would eventually be rewritten mid-sample.
//
// Auto-framing: the draft's geometry stage is driven by the LIVE
// auto-framer's offset (AppState forwards it), so a draft previews
// auto-framed exactly while live auto-framing runs. A draft that newly
// enables auto-frame previews centered until applied — the draft runs no
// segmentation of its own (a second Vision request per frame whose output
// nothing could consume would be pure cost).
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreVideo
import Foundation
import Metal

final class DraftRenderer {
    private let metal: MetalContext
    private let segmenter: PersonSegmenter
    private let faceTracker: FaceTracker
    /// The draft's own schedule. Separate from the live pipeline's because
    /// the two run different chains over the same camera and each has to be
    /// able to answer "what runs this frame" for itself.
    private let vision = VisionCoordinator()
    private let gazeStage: GazeStage
    private let geometryStage: GeometryStage
    private let retouchStage: RetouchStage
    private let adjustStage: AdjustStage
    private let lutStage: LUTStage
    private let blurStage: BlurStage
    private let backgroundStage: BackgroundStage
    private let overlayStage: OverlayStage
    private let styleStage: StyleStage
    private let outputFitStage: OutputFitStage
    private let userStages: [EffectStage]

    /// Mirrors VideoPipeline.maskConsumers — the chain position where the
    /// draft's own segmentation runs.
    private static let maskConsumers: Set<StageID> = [.blur, .background, .overlay]

    /// Mirrors VideoPipeline.faceConsumers, likewise.
    private static let faceConsumers: Set<StageID> = [.gaze, .overlay]

    /// The finished draft texture for the preview. Completion-thread callback.
    var onOutput: ((MTLTexture) -> Void)?

    private let frameQueue = DispatchQueue(
        label: "horse.prism.PRISM.draftPreview", qos: .userInitiated)
    private let inFlight = DispatchSemaphore(value: 1)
    private let stateLock = NSLock()

    private var outputFormat: VideoFormat

    // frameQueue-confined.
    private var intermediateA: MTLTexture?
    private var intermediateB: MTLTexture?
    private var workingWidth = 0
    private var workingHeight = 0
    private var outputPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init(metal: MetalContext, outputFormat: VideoFormat) throws {
        self.metal = metal
        self.outputFormat = outputFormat
        segmenter = try PersonSegmenter(metal: metal)
        faceTracker = try FaceTracker(metal: metal)
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
        outputFitStage = try OutputFitStage(metal: metal)
        // No connection stage here: bad connection is engaged behaviour, not
        // a look — a draft previews the look it would apply (§5.14 excluded).
        userStages = [gazeStage, geometryStage, retouchStage, adjustStage,
                      lutStage, blurStage, backgroundStage, overlayStage,
                      styleStage]
        outputFitStage.outputSize = CGSize(width: outputFormat.width,
                                           height: outputFormat.height)

        vision.register(.face, cadence: 2)
        vision.register(.person, cadence: 2)
        let gaze = gazeStage, overlay = overlayStage
        let blur = blurStage, background = backgroundStage
        vision.addConsumer(of: .face) { gaze.wantsEncode() }
        vision.addConsumer(of: .face) { overlay.needsFaceTracker }
        vision.addConsumer(of: .person) { blur.isEnabled }
        vision.addConsumer(of: .person) { background.needsPersonMask }
        vision.addConsumer(of: .person) { overlay.needsPersonMask }
        // No auto-frame consumer: the draft is driven by the live
        // auto-framer's offset, so it never needs a subject box of its own.
    }

    deinit {
        // The draft's own media clocks stop with it; a torn-down renderer
        // must not leave a background video decoding for nobody.
        backgroundStage.setDemandActive(false)
        overlayStage.setDemandActive(false)
    }

    func configure(outputFormat: VideoFormat) {
        stateLock.lock()
        self.outputFormat = outputFormat
        stateLock.unlock()
        outputFitStage.outputSize = CGSize(width: outputFormat.width,
                                           height: outputFormat.height)
    }

    /// Same stage mapping as VideoPipeline.apply, except maskOnlyMode:
    /// never set here — the draft's subject box has no consumer (the
    /// auto-framer reads only the live blur stage), so draft segmentation
    /// without visible blur would be Vision cost at camera rate for output
    /// nobody reads.
    func apply(_ config: PipelineConfiguration) {
        adjustStage.settings = config.adjust
        retouchStage.settings = config.retouch
        lutStage.settings = config.lut
        blurStage.settings = config.blur
        geometryStage.settings = config.geometry
        gazeStage.settings = config.gaze
        backgroundStage.settings = config.background
        overlayStage.settings = config.overlay
        styleStage.settings = config.style
        segmenter.quality = config.blur.quality
        faceTracker.smoothing = config.gaze.smoothing

        geometryStage.isEnabled = config.flags(for: .geometry).enabled
        retouchStage.isEnabled = config.flags(for: .retouch).enabled
        adjustStage.isEnabled = config.flags(for: .adjust).enabled
        lutStage.isEnabled = config.flags(for: .lut).enabled
        blurStage.isEnabled = config.flags(for: .blur).enabled
        gazeStage.isEnabled = config.flags(for: .gaze).enabled
        backgroundStage.isEnabled = config.flags(for: .background).enabled
        overlayStage.isEnabled = config.flags(for: .overlay).enabled
        styleStage.isEnabled = config.flags(for: .style).enabled

        backgroundStage.setDemandActive(true)
        overlayStage.setDemandActive(true)
    }

    /// Forwarded from the live auto-framer so the draft previews the same
    /// auto-framing motion the applied config would show.
    func setAutoFrameOffset(_ offset: (zoom: Double, panX: Double, panY: Double)) {
        geometryStage.autoFrameOffset = offset
    }

    /// Camera-thread entry. Drops the frame when one is already rendering.
    func submit(_ buffer: CVPixelBuffer) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        let semaphore = inFlight
        frameQueue.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            do {
                try self.render(buffer)
            } catch {
                semaphore.signal()
            }
        }
    }

    // MARK: - Frame path (frameQueue-confined)

    private func render(_ buffer: CVPixelBuffer) throws {
        let source = try metal.makeTexture(from: buffer)
        try ensureWorking(width: source.width, height: source.height)
        // Pool-backed output; the texture pins its buffer (makeTexture
        // attaches the CVMetalTexture), so the preview's retained reference
        // blocks recycling — the cross-queue safety the live path relies on.
        var pixelBufferOut: CVPixelBuffer?
        guard let pool = try ensureOutputPool(),
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool,
                                                 &pixelBufferOut) == kCVReturnSuccess,
              let outBuffer = pixelBufferOut else {
            throw PipelineError.textureAllocationFailed
        }
        let output = try metal.makeTexture(from: outBuffer)
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            throw PipelineError.encodingFailed("Could not create draft command buffer")
        }

        var current = source
        var useA = true
        var segmentationDone = false
        var faceTrackingDone = false
        let visionDecision = vision.beginFrame()
        overlayStage.frameSize = CGSize(width: source.width, height: source.height)
        overlayStage.faceSpaceTransform = geometryStage.appliedUVTransform(
            inputSize: CGSize(width: source.width, height: source.height))
        for stage in userStages {
            // Same one-request-per-modality-per-frame contract as
            // VideoPipeline, and for the same reason the draft segments at
            // all: a drafted eye contact that previewed as pass-through would
            // be the one thing a preview must not do.
            if !faceTrackingDone, Self.faceConsumers.contains(stage.id) {
                faceTrackingDone = true
                if visionDecision.demanded.contains(.face) {
                    faceTracker.isDemanded = true
                    faceTracker.update(commandBuffer: commandBuffer, input: current,
                                       capture: visionDecision.running == .face)
                } else if visionDecision.ended.contains(.face) {
                    faceTracker.isDemanded = false
                    faceTracker.invalidate()
                }
            }
            // The draft does run its own Vision request when a mask consumer
            // is staged — without it a drafted background or blur would
            // preview as pass-through.
            if !segmentationDone, Self.maskConsumers.contains(stage.id) {
                segmentationDone = true
                if visionDecision.demanded.contains(.person) {
                    segmenter.isDemanded = true
                    segmenter.update(commandBuffer: commandBuffer, input: current,
                                     capture: visionDecision.running == .person)
                } else if visionDecision.ended.contains(.person) {
                    segmenter.isDemanded = false
                    segmenter.invalidate()
                }
            }
            guard stage.wantsEncode() else { continue }
            guard let dst = useA ? intermediateA : intermediateB else {
                throw PipelineError.textureAllocationFailed
            }
            try stage.encode(commandBuffer: commandBuffer, input: current, output: dst)
            current = dst
            useA.toggle()
        }
        try outputFitStage.encode(commandBuffer: commandBuffer,
                                  input: current, output: output)

        let semaphore = inFlight
        commandBuffer.addCompletedHandler { [weak self] finished in
            semaphore.signal()
            guard finished.error == nil, let self else { return }
            self.onOutput?(output)
        }
        commandBuffer.commit()
    }

    private func ensureWorking(width: Int, height: Int) throws {
        if width != workingWidth || height != workingHeight
            || intermediateA == nil || intermediateB == nil {
            intermediateA = try metal.makeIntermediate(width: width, height: height)
            intermediateB = try metal.makeIntermediate(width: width, height: height)
            workingWidth = width
            workingHeight = height
        }
    }

    private func ensureOutputPool() throws -> CVPixelBufferPool? {
        stateLock.lock()
        let format = outputFormat
        stateLock.unlock()
        if let pool = outputPool, poolWidth == format.width, poolHeight == format.height {
            return pool
        }
        var pool: CVPixelBufferPool?
        let bufferAttrs = prismPixelBufferAttributes(width: format.width,
                                                     height: format.height)
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                      poolAttrs as CFDictionary,
                                      bufferAttrs as CFDictionary,
                                      &pool) == kCVReturnSuccess else {
            throw PipelineError.textureAllocationFailed
        }
        outputPool = pool
        poolWidth = format.width
        poolHeight = format.height
        return pool
    }
}

/// Lock-guarded handle so the capture thread can reach the current draft
/// renderer without touching main-actor state — same shape as
/// PreviewTextureBox.
final class DraftRendererBox {
    private let lock = NSLock()
    private var renderer: DraftRenderer?

    func set(_ renderer: DraftRenderer?) {
        lock.lock()
        self.renderer = renderer
        lock.unlock()
    }

    func get() -> DraftRenderer? {
        lock.lock()
        defer { lock.unlock() }
        return renderer
    }
}
