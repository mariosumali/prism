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
    private let geometryStage: GeometryStage
    private let adjustStage: AdjustStage
    private let lutStage: LUTStage
    private let blurStage: BlurStage
    private let outputFitStage: OutputFitStage
    private let userStages: [EffectStage]

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
        geometryStage = try GeometryStage(metal: metal)
        adjustStage = try AdjustStage(metal: metal)
        lutStage = try LUTStage(metal: metal)
        blurStage = try BlurStage(metal: metal)
        outputFitStage = try OutputFitStage(metal: metal)
        userStages = [geometryStage, adjustStage, lutStage, blurStage]
        outputFitStage.outputSize = CGSize(width: outputFormat.width,
                                           height: outputFormat.height)
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
        lutStage.settings = config.lut
        blurStage.settings = config.blur
        geometryStage.settings = config.geometry
        geometryStage.isEnabled = config.flags(for: .geometry).enabled
        adjustStage.isEnabled = config.flags(for: .adjust).enabled
        lutStage.isEnabled = config.flags(for: .lut).enabled
        blurStage.isEnabled = config.flags(for: .blur).enabled
        blurStage.maskOnlyMode = false
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
        for stage in userStages where stage.wantsEncode() {
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
