// OverlayStage.swift
// PRISM
//
// Green-screen compositing (§5.8, .moderate): a handful of placed, keyed
// layers over the finished frame. Each layer is an image or a looping video
// with an optional chroma or luma key, placed with scale/offset/rotation/
// mirror, and composited either in front of everything or behind the subject
// (using the shared person mask).
//
// This is the stage that turns PRISM from a camera filter into a stage.
// An animated hat, a fire border, a lower third, a picture-in-picture of a
// second feed — they are all the same operation, and the cost is one compute
// pass per layer, so the interesting question was never "can we render it"
// but "how many can we afford". The answer is two caps, per OverlaySettings:
// resident memory is the binding constraint (§7), not GPU time, and it is
// the video layers that spend it — each one carries its own decoder and
// frame FIFO.
//
// Layers composite bottom-up in array order, ping-ponging through two
// scratch textures so the final pass always lands in `output`.
//
// Licensed under the Apache License, Version 2.0.

import CoreGraphics
import CoreMedia
import Foundation
import Metal
import simd

public final class OverlayStage: EffectStage {
    public let id: StageID = .overlay
    public let cost: StageCost = .moderate
    public var isEnabled: Bool = false

    public var settings = OverlaySettings() {
        didSet { reconcileSources(previous: oldValue) }
    }

    public let segmenter: PersonSegmenter
    /// Shared face measurement, injected by the pipeline. Taken in the
    /// initialiser because the tracker is constructed once and shared — a
    /// stage that reached for it later would have to make one of its own,
    /// which is the second full-frame Vision request this exists to prevent.
    public let faceTracker: FaceTracker

    /// Output UV → pre-geometry input UV, pushed by the pipeline each frame.
    ///
    /// The face is measured before Geometry (§5.6) and layers are composited
    /// long after it, so a hat placed straight from the tracker's numbers
    /// would sit where the head was before the zoom, pan, rotation or mirror
    /// moved it — and auto-framing moves it continuously. Composing the
    /// geometry matrix onto the placement puts the prop back on the head for
    /// free, exactly, and without decomposing anything: the layer is glued to
    /// the face in camera space and whatever the camera transform does to the
    /// face it does to the prop.
    public var faceSpaceTransform: simd_float3x3 = matrix_identity_float3x3

    private let metal: MetalContext
    private let overlayPipeline: MTLComputePipelineState
    private let copyPipeline: MTLComputePipelineState

    /// One media source per layer, keyed by layer id so that editing a
    /// slider — which replays the whole settings struct — never restarts a
    /// running video.
    ///
    /// Reconciled on the main thread (settings changes) and read on the frame
    /// queue (wantsEncode), so it is lock-guarded: unlike the single-reference
    /// swaps elsewhere in the stages, concurrent mutation and read of a Swift
    /// Dictionary is a crash, not a stale value.
    private var sources: [UUID: LayerSource] = [:]
    private let sourcesLock = NSLock()

    private func source(for id: UUID) -> LayerSource? {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }
        return sources[id]
    }

    // Frame-queue-confined ping-pong scratch.
    private var scratchA: MTLTexture?
    private var scratchB: MTLTexture?
    private var scratchWidth = 0
    private var scratchHeight = 0

    /// Layers resolved in wantsEncode() and consumed by the encode() that
    /// follows for the same frame.
    private var pending: [(layer: OverlayLayer, texture: MTLTexture)] = []
    /// The face the pending face-anchored layers were admitted against, read
    /// once per frame so that every layer in a frame hangs off the same pose.
    private var pendingFace: FaceTracker.FaceSample?
    private var pendingFaceConfidence: Float = 0

    public init(metal: MetalContext, segmenter: PersonSegmenter,
                faceTracker: FaceTracker) throws {
        self.metal = metal
        self.segmenter = segmenter
        self.faceTracker = faceTracker
        overlayPipeline = try metal.computePipeline(function: "prism_overlay")
        copyPipeline = try metal.computePipeline(function: "prism_copy")
    }

    /// True when any renderable layer sits behind the subject.
    public var needsPersonMask: Bool {
        isEnabled && settings.needsPersonMask
    }

    /// True when a layer is actually riding the face. This is the whole of
    /// the stage's claim on the tracker: nobody pays for a landmark request
    /// because the overlay stage exists, only because a layer is anchored to
    /// a face, and the moment the last one is removed the demand goes away.
    public var needsFaceTracker: Bool {
        isEnabled && settings.needsFaceTracker
    }

    public func setDemandActive(_ active: Bool) {
        sourcesLock.lock()
        let live = Array(sources.values)
        sourcesLock.unlock()
        for source in live {
            source.setDemandActive(active)
        }
    }

    // MARK: - EffectStage

    public func wantsEncode() -> Bool {
        pending.removeAll(keepingCapacity: true)
        guard isEnabled else { return false }
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let maskAvailable = segmenter.latestMask != nil
        pendingFace = faceTracker.smoothedFace
        pendingFaceConfidence = faceTracker.confidence.face
        for layer in settings.renderableLayers {
            // A behind-the-subject layer with no mask yet is skipped rather
            // than drawn in front — showing it in the wrong depth order is a
            // worse first frame than showing it a frame late.
            if layer.placement == .behind, !maskAvailable { continue }
            // Tracking loss hides the layer, through a fade. The alternatives
            // are both worse on camera: freezing at the last pose leaves a
            // moustache hanging in mid-air where a head used to be, and
            // cutting it instantly makes the prop flash on and off with every
            // detection flicker. The tracker's confidence ramp is already
            // ~0.25 s in each direction and already holds the last pose
            // through a dropout, so the prop shrinks out of sight from where
            // it was standing and comes back to where the head is now.
            if layer.anchor == .face, !isFaceUsable { continue }
            guard let source = source(for: layer.id),
                  let texture = source.currentTexture(at: hostTime) else { continue }
            pending.append((layer, texture))
        }
        return !pending.isEmpty
    }

    /// A face-anchored layer needs a pose to hang off. Below the ramp's floor
    /// there is nothing to draw at all, so the pass is skipped rather than
    /// dispatched at zero opacity.
    private var isFaceUsable: Bool {
        pendingFace != nil && pendingFaceConfidence > 0.01
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        let layers = pending
        pending.removeAll(keepingCapacity: true)
        guard !layers.isEmpty else {
            try encodeCopy(commandBuffer: commandBuffer, source: input, destination: output)
            return
        }
        if layers.count > 1 {
            try ensureScratch(width: output.width, height: output.height)
        }

        var current = input
        for (index, entry) in layers.enumerated() {
            let isLast = index == layers.count - 1
            let destination: MTLTexture
            if isLast {
                destination = output
            } else if index % 2 == 0 {
                guard let scratchA else { throw PipelineError.textureAllocationFailed }
                destination = scratchA
            } else {
                guard let scratchB else { throw PipelineError.textureAllocationFailed }
                destination = scratchB
            }
            try encodeLayer(entry.layer, texture: entry.texture,
                            commandBuffer: commandBuffer,
                            base: current, destination: destination)
            current = destination
        }
    }

    // MARK: - Encoding

    private func encodeLayer(_ layer: OverlayLayer,
                             texture: MTLTexture,
                             commandBuffer: MTLCommandBuffer,
                             base: MTLTexture,
                             destination: MTLTexture) throws {
        let contentSize = CGSize(width: texture.width, height: texture.height)
        let outputSize = CGSize(width: destination.width, height: destination.height)
        var params = PRISMOverlayParams()
        var opacity = min(max(layer.opacity, 0), 1)
        if layer.anchor == .face, let face = pendingFace {
            params.uvTransform = Self.facePlacement(layer: layer,
                                                    contentSize: contentSize,
                                                    frameSize: outputSize,
                                                    face: face,
                                                    geometry: faceSpaceTransform)
            opacity *= Double(min(max(pendingFaceConfidence, 0), 1))
        } else {
            params.uvTransform = Self.placement(layer: layer,
                                                contentSize: contentSize,
                                                outputSize: outputSize)
        }
        params.keyColor = SIMD4<Float>(Float(layer.keyColor.red),
                                       Float(layer.keyColor.green),
                                       Float(layer.keyColor.blue), 1)
        params.similarity = Float(min(max(layer.similarity, 0), 1))
        params.smoothness = Float(min(max(layer.smoothness, 0.001), 1))
        params.spill = Float(min(max(layer.spill, 0), 1))
        params.lumaLow = Float(min(max(layer.lumaLow, 0), 1))
        params.lumaHigh = Float(min(max(layer.lumaHigh, 0.001), 1))
        params.opacity = Float(opacity)
        switch layer.keyMode {
        case .none: params.keyMode = 0
        case .chroma: params.keyMode = 1
        case .luma: params.keyMode = 2
        }
        params.placement = layer.placement == .behind ? 1 : 0

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("OverlayStage: no compute encoder")
        }
        encoder.label = "OverlayStage.\(layer.name)"
        encoder.setComputePipelineState(overlayPipeline)
        encoder.setTexture(base, index: 0)
        encoder.setTexture(texture, index: 1)
        // Only read for behind-placement; bind the layer itself as a filler
        // otherwise so the binding is always populated.
        encoder.setTexture(segmenter.latestMask ?? texture, index: 2)
        encoder.setTexture(destination, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<PRISMOverlayParams>.stride, index: 0)
        dispatchOver(destination, pipeline: overlayPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func encodeCopy(commandBuffer: MTLCommandBuffer,
                            source: MTLTexture,
                            destination: MTLTexture) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.encodingFailed("OverlayStage: no copy encoder")
        }
        encoder.label = "OverlayStage.passThrough"
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        dispatchOver(destination, pipeline: copyPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func ensureScratch(width: Int, height: Int) throws {
        guard width != scratchWidth || height != scratchHeight
            || scratchA == nil || scratchB == nil else { return }
        scratchA = try metal.makeIntermediate(width: width, height: height)
        scratchB = try metal.makeIntermediate(width: width, height: height)
        scratchWidth = width
        scratchHeight = height
    }

    // MARK: - Placement transform

    /// Output UV → layer UV.
    ///
    /// At scale 1 the layer is fitted (never cropped) into the frame with its
    /// own aspect preserved, so dropping in a square PNG gives a square, not
    /// a stretched rectangle. Rotation is applied in an aspect-corrected
    /// space so a rotated layer does not shear.
    static func placement(layer: OverlayLayer,
                          contentSize: CGSize,
                          outputSize: CGSize) -> simd_float3x3 {
        guard contentSize.width > 0, contentSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            return matrix_identity_float3x3
        }
        let frameAspect = Float(outputSize.width / outputSize.height)
        let contentAspect = Float(contentSize.width / contentSize.height)
        let ratio = contentAspect / frameAspect

        let scale = Float(min(max(layer.scale, 0.05), 4))
        // Fit, then scale.
        var span = ratio >= 1
            ? SIMD2<Float>(1, 1 / ratio)
            : SIMD2<Float>(ratio, 1)
        span *= scale
        span = SIMD2<Float>(max(span.x, 1e-4), max(span.y, 1e-4))

        let center = SIMD2<Float>(0.5 + Float(min(max(layer.offsetX, -1), 1)) * 0.5,
                                  0.5 + Float(min(max(layer.offsetY, -1), 1)) * 0.5)
        return transform(center: center, span: span, radians: layerRadians(layer),
                         mirrored: layer.mirrored, frameAspect: frameAspect)
    }

    /// Output UV → layer UV for a layer riding the face.
    ///
    /// Everything is built in the space the tracker measured in — pre-Geometry
    /// input UV — and then composed with `geometry` (output UV → input UV) so
    /// the result maps straight from the frame the kernel is writing. Nothing
    /// is decomposed and no assumption is made about what Geometry is doing:
    /// zoom, pan, rotation, mirror and a non-square crop all arrive intact.
    ///
    /// Scale is read against the face rather than the frame: at size 1 a
    /// layer is exactly as wide as the tracked face box, so a prop keeps its
    /// proportion as someone leans toward the camera and away again, and the
    /// same size means the same thing on a 720p call as on a 1080p one.
    /// Offsets are in face widths for the same reason.
    static func facePlacement(layer: OverlayLayer,
                              contentSize: CGSize,
                              frameSize: CGSize,
                              face: FaceTracker.FaceSample,
                              geometry: simd_float3x3) -> simd_float3x3 {
        guard contentSize.width > 0, contentSize.height > 0,
              frameSize.width > 0, frameSize.height > 0,
              face.box.width > 0, face.box.height > 0 else {
            return matrix_identity_float3x3
        }
        let frameAspect = Float(frameSize.width / frameSize.height)
        let contentAspect = Float(contentSize.width / contentSize.height)
        let ratio = contentAspect / frameAspect

        // A face width of `faceWidth` in UV x, with the layer's own aspect
        // carried on the other axis so a square PNG stays square.
        let faceWidth = Float(face.box.width)
        let scale = Float(min(max(layer.scale, 0.05), 4))
        var span = SIMD2<Float>(faceWidth * scale, faceWidth * scale / ratio)
        span = SIMD2<Float>(max(span.x, 1e-4), max(span.y, 1e-4))

        // The head's tilt in this space. FaceTracker flips y at the Vision
        // boundary for every position it reports but leaves the angle in
        // Vision's y-up frame, and a y-flip negates an in-plane angle — so
        // the flip is owed here.
        let roll = -face.roll
        // The prop's own rotation follows the head only when asked: roll is
        // the noisiest quantity the tracker reports, and a hat that jitters
        // is more distracting than one that stays level.
        let radians = layerRadians(layer) + (layer.followsRoll ? roll : 0)

        // The landmark itself always moves with the tilt, whether or not the
        // prop rotates: a moustache belongs under the nose wherever the nose
        // has gone.
        let anchor = anchorPoint(face: face, point: layer.facePoint,
                                 roll: roll, frameAspect: frameAspect)

        // Nudges are in face widths and swing with the head, so one pushed
        // clear of the hairline stays clear of it as the head tilts. Only the
        // head's tilt — the rotation slider spins the artwork in place and
        // leaves the position alone, exactly as it does on a frame-anchored
        // layer.
        let nx = Float(min(max(layer.offsetX, -1), 1))
        let ny = Float(min(max(layer.offsetY, -1), 1))
        let swing = layer.followsRoll ? roll : 0
        let cosR = cos(swing), sinR = sin(swing)
        let offset = SIMD2<Float>(nx * cosR - ny * sinR, nx * sinR + ny * cosR)
        let center = anchor + SIMD2<Float>(offset.x * faceWidth,
                                           offset.y * faceWidth * frameAspect)

        let placed = transform(center: center, span: span, radians: radians,
                               mirrored: layer.mirrored, frameAspect: frameAspect)
        return placed * geometry
    }

    /// Where a layer's centre lands for each anchor point, in the tracker's
    /// input UV.
    ///
    /// The fractions are of the face box height, measured from its centre and
    /// rotated by the head's tilt. They are named for what a prop is worn on
    /// rather than for a landmark index because that is the choice a user
    /// makes — "moustache", not "landmark 27" — and because the face box is
    /// the one measurement Vision reports for every face, including the
    /// profile turns and squints where the landmark constellation gives up.
    /// The eye line is the exception: when both eyes are measured, their
    /// midpoint beats any fraction of a box.
    static func anchorPoint(face: FaceTracker.FaceSample,
                            point: FaceAnchorPoint,
                            roll: Float,
                            frameAspect: Float) -> SIMD2<Float> {
        if point == .eyes {
            if let left = face.left, let right = face.right {
                return (left.lidCenter + right.lidCenter) * 0.5
            }
            if let eye = face.left ?? face.right {
                return eye.lidCenter
            }
        }
        let fraction: Float
        switch point {
        case .aboveHead: fraction = -0.62
        case .eyes:      fraction = -0.13
        case .underNose: fraction = 0.20
        case .mouth:     fraction = 0.30
        case .chin:      fraction = 0.50
        case .face:      fraction = 0
        }
        // Rotate in the isotropic space (1 unit = the frame's height) so a
        // tilt does not shear the offset, then convert x back to UV.
        let height = Float(face.box.height)
        let dx = -sin(roll) * fraction * height
        let dy = cos(roll) * fraction * height
        return SIMD2<Float>(Float(face.box.midX) + dx / frameAspect,
                            Float(face.box.midY) + dy)
    }

    private static func layerRadians(_ layer: OverlayLayer) -> Float {
        Float(min(max(layer.rotationDegrees, -180), 180)) * .pi / 180
    }

    /// The shared construction: centre the layer, rotate it in an
    /// aspect-corrected space so it does not shear, scale UV through its own
    /// span, mirror, and land on the layer's own [0,1] square.
    private static func transform(center: SIMD2<Float>,
                                  span: SIMD2<Float>,
                                  radians: Float,
                                  mirrored: Bool,
                                  frameAspect: Float) -> simd_float3x3 {
        var m = translationMatrix(-center.x, -center.y)
        m = scaleMatrix(frameAspect, 1) * m
        m = rotationMatrix(-radians) * m
        m = scaleMatrix(1 / frameAspect, 1) * m
        m = scaleMatrix(1 / span.x, 1 / span.y) * m
        if mirrored {
            m = scaleMatrix(-1, 1) * m
        }
        m = translationMatrix(0.5, 0.5) * m
        return m
    }

    // MARK: - Source lifecycle

    /// Adds sources for new layers, retargets changed ones, and drops sources
    /// for layers that are gone — releasing their decoders and FIFOs.
    private func reconcileSources(previous: OverlaySettings) {
        let live = settings.mediaLayers
        var kept = Set<UUID>()
        var toConfigure: [(LayerSource, URL?, LayerSourceKind)] = []

        sourcesLock.lock()
        for layer in live {
            kept.insert(layer.id)
            let source: LayerSource
            if let existing = sources[layer.id] {
                source = existing
            } else {
                source = LayerSource(metal: metal,
                                     label: layer.id.uuidString.prefix(8).lowercased())
                sources[layer.id] = source
            }
            toConfigure.append((source, layer.isEnabled ? layer.assetURL : nil,
                                layer.sourceKind))
        }
        // Dropping a source releases its decoder and frame FIFO.
        for id in sources.keys where !kept.contains(id) {
            sources.removeValue(forKey: id)
        }
        sourcesLock.unlock()

        // Opening media is slow; do it outside the lock so the frame queue is
        // never blocked behind a file read.
        for (source, url, kind) in toConfigure {
            source.configure(url: url, kind: kind)
        }
        _ = previous
    }
}

// MARK: - Matrix helpers (column-major homogeneous 2D transforms)

private func translationMatrix(_ tx: Float, _ ty: Float) -> simd_float3x3 {
    simd_float3x3(columns: (SIMD3<Float>(1, 0, 0),
                            SIMD3<Float>(0, 1, 0),
                            SIMD3<Float>(tx, ty, 1)))
}

private func scaleMatrix(_ sx: Float, _ sy: Float) -> simd_float3x3 {
    simd_float3x3(columns: (SIMD3<Float>(sx, 0, 0),
                            SIMD3<Float>(0, sy, 0),
                            SIMD3<Float>(0, 0, 1)))
}

private func rotationMatrix(_ radians: Float) -> simd_float3x3 {
    let c = cos(radians)
    let s = sin(radians)
    return simd_float3x3(columns: (SIMD3<Float>(c, s, 0),
                                   SIMD3<Float>(-s, c, 0),
                                   SIMD3<Float>(0, 0, 1)))
}

/// Dispatch a full-texture compute pass; kernels guard out-of-bounds gid.
private func dispatchOver(_ target: MTLTexture,
                          pipeline: MTLComputePipelineState,
                          encoder: MTLComputeCommandEncoder) {
    let w = pipeline.threadExecutionWidth
    let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
    let group = MTLSize(width: w, height: h, depth: 1)
    let grid = MTLSize(width: (target.width + w - 1) / w,
                       height: (target.height + h - 1) / h,
                       depth: 1)
    encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
}
