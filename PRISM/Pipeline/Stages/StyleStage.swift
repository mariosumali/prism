// StyleStage.swift
// PRISM
//
// Style (§5.4, .moderate): up to two preset visual effects over the finished,
// composed scene — warps, glitches, motion trails and a few gadget-camera
// looks. Each effect is its own prism_style_* kernel; picking one compiles
// (and caches) its pipeline here, off the frame path. The motion effects
// feed on their own output: the stage keeps a history texture holding the
// previous styled frame and blits each frame's result into it. "Normal" is
// the unstyled picture, so the stage declines to encode for it (or at zero
// intensity) — the pass would be a no-op.
//
// Two effects stack (§5.29) by running the second over the first's output,
// through a stage-private scratch texture: the pipeline hands every stage one
// input and one output, so a second pass has to land somewhere the ping-pong
// intermediates do not own. Both passes ride the same command buffer.
//
// Intensity can breathe with the microphone (§5.30). The level arrives
// through a closure the stage samples once per frame — one atomic load out of
// the audio callback's mailbox, so neither the RT thread nor the frame queue
// ever waits on the other — and an attack/decay envelope on the frame clock
// turns a stream of 21 ms windows into something that pulses rather than
// flickers. It multiplies into PRISMStyleParams.intensity at encode time;
// no kernel knows it exists.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Metal
import QuartzCore

// MARK: - Level envelope

/// Attack/decay follower over the microphone level, stepped on the frame
/// clock. Pure arithmetic so StyleStageTests can hold it to its own shape
/// without a microphone.
///
/// A raw RMS window lands about 47 times a second and jumps by half its range
/// between two of them; driving a warp straight off it looks like a fault, not
/// a rhythm. So the rise is quick enough to land on the front of a syllable
/// and the fall is slow enough to ride over the gaps inside a word — the
/// asymmetry IS the musicality, and it is the same shape a compressor's
/// envelope has for the same reason.
public struct StyleLevelEnvelope: Equatable {
    /// Fast enough that the effect arrives with the word rather than after it.
    public static let attackSeconds: Double = 0.06
    /// Slow enough that the consonant gaps inside a word do not read as
    /// silence, quick enough that a finished sentence visibly settles.
    public static let releaseSeconds: Double = 0.35
    /// The most one frame may advance the envelope by. A gap in the frames —
    /// the app napped, the camera went away — is not evidence about the room,
    /// and integrating one whole would snap the picture at the moment it
    /// came back.
    public static let maximumStepSeconds: Double = 0.1

    public private(set) var value: Double = 0

    public init() {}

    @discardableResult
    public mutating func step(level: Double, elapsed: Double) -> Double {
        let target = min(max(level.isFinite ? level : 0, 0), 1)
        let dt = min(max(elapsed.isFinite ? elapsed : 0, 0), Self.maximumStepSeconds)
        guard dt > 0 else { return value }
        let tau = target > value ? Self.attackSeconds : Self.releaseSeconds
        value += (target - value) * (1 - exp(-dt / tau))
        return value
    }

    public mutating func reset() { value = 0 }
}

// MARK: - StyleStage

public final class StyleStage: EffectStage {
    public let id: StageID = .style
    public let cost: StageCost = .moderate

    /// Turning the stage off drops the trail history (and its texture):
    /// ghosts recorded before a gap must never replay when the stage comes
    /// back, and a disabled stage should not hold a working-resolution
    /// texture resident.
    public var isEnabled: Bool = false {
        didSet { if !isEnabled { release() } }
    }

    /// Rebuilds the pass plan in the setter, off the frame path (MetalContext
    /// caches compiled pipelines, so returning to an effect is free). The
    /// history goes only when the *set of effects being run* changes — a
    /// different effect must not inherit the previous one's trails, and
    /// parking a slot at zero intensity is a trail gap too — so dragging an
    /// intensity slider re-plans without breaking a running trail.
    public var settings: StyleSettings {
        didSet {
            guard settings != oldValue else { return }
            let before = oldValue.renderableLayers.map(\.effect)
            let after = settings.renderableLayers.map(\.effect)
            rebuild(dropsHistory: before != after)
        }
    }

    /// The microphone level, 0…1, as the meter shows it. Sampled once per
    /// frame ON THE FRAME QUEUE, so whatever is installed here must not
    /// block, allocate or take a lock the audio thread holds — the shipped
    /// implementation is one acquire-load out of InputLevelMailbox, which is
    /// the whole reason the mailbox is a scalar rather than a ring. nil (or
    /// an unarmed meter) simply means no audio is arriving, which the
    /// envelope decays to rather than snapping.
    public var audioLevelSource: (() -> Double)?

    /// §3.4 — how many times this stage's table weight it actually encoded.
    /// One pass or two, and the difference is a whole full-frame kernel, so a
    /// stack that reported the same cost as a single effect would let the
    /// degradation engine believe stacking is free.
    public var weightMultiplier: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Double(max(1, passes.count))
    }

    private let metal: MetalContext
    private let copyPipeline: MTLComputePipelineState

    /// One compiled effect, and everything encode() needs to run it. Built
    /// off the frame path so the frame path never touches `settings`, whose
    /// writer is the main thread.
    private struct Pass {
        let effect: StyleEffect
        let pipeline: MTLComputePipelineState
        let isTemporal: Bool
        let intensity: Float
        let audioReactive: Bool
    }

    /// Guards (passes, audioDepth, historyTexture, historyValid, scratch),
    /// which must
    /// change together: settings land from the main thread while encode()
    /// runs on the frame path, and a kernel dispatched with the other
    /// family's texture layout would write its output into the wrong texture.
    /// encode() takes one snapshot under the lock and re-validates against it
    /// before publishing the history — an invalidation that lands mid-encode
    /// wins over the completing frame.
    private let stateLock = NSLock()
    private var passes: [Pass] = []
    private var audioDepth: Float = 0.7
    /// Previous styled output for the motion effects. Stage-owned so ring
    /// reuse of the pipeline's ping-pong intermediates cannot corrupt it;
    /// released whenever no motion effect could legitimately resume its
    /// trails. There is exactly one, which is why exactly one motion effect
    /// may be in the stack (StyleSettings.renderableLayers).
    private var historyTexture: MTLTexture?
    private var historyValid = false

    /// Where the first pass lands when two effects stack. Stage-private: the
    /// pipeline's own intermediates are `input` and `output` here, and
    /// reading a texture the same pass is writing is undefined whatever the
    /// kernel does. Only allocated while stacking; under the lock because
    /// switching the stage off releases it from the main thread.
    private var scratchTexture: MTLTexture?

    /// Frame-path-confined. Trails age out across ANY encoding gap —
    /// zero-intensity parks, degradation disables, app naps — a ghost older
    /// than half a second reads as a glitch, not a trail. This closes every
    /// gap class the flag-based invalidation cannot see, and it is the same
    /// gap the level envelope restarts from.
    private var lastEncodeTime: CFTimeInterval = -.infinity
    private static let maxTrailGapSeconds: CFTimeInterval = 0.5

    /// Frame-path-confined; see StyleLevelEnvelope.
    private var envelope = StyleLevelEnvelope()

    /// Time base for the animated looks: seconds since stage creation.
    private let timeBase = CACurrentMediaTime()

    public init(metal: MetalContext) throws {
        self.metal = metal
        copyPipeline = try metal.computePipeline(function: "prism_copy")
        settings = StyleSettings()
    }

    public func wantsEncode() -> Bool {
        stateLock.lock()
        let hasWork = !passes.isEmpty
        stateLock.unlock()
        return isEnabled && hasWork
    }

    public func encode(commandBuffer: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture) throws {
        // One consistent snapshot: the pass plan and its texture layout
        // belong to the same set of effects even if a switch lands mid-encode.
        stateLock.lock()
        let plan = passes
        let depth = audioDepth
        var history = historyTexture
        var seeded = historyValid
        stateLock.unlock()

        let now = CACurrentMediaTime()
        let gap = now - lastEncodeTime
        if gap > Self.maxTrailGapSeconds {
            seeded = false
            // The same gap that invalidates a trail invalidates the envelope:
            // resuming at the loudness of whenever the chain last ran would
            // put a full-strength pulse on the first frame back.
            envelope.reset()
        }
        lastEncodeTime = now

        guard !plan.isEmpty else {
            // Defensive pass-through if encode is called with no plan.
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw PipelineError.encodingFailed("StyleStage: no compute encoder")
            }
            encoder.label = "StyleStage.passThrough"
            encoder.setComputePipelineState(copyPipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            dispatchOver(output, pipeline: copyPipeline, encoder: encoder)
            encoder.endEncoding()
            return
        }

        // Every throwing allocation happens before an encoder is open — an
        // abandoned command buffer with a live encoder is a Metal assertion,
        // not a dropped frame.
        if plan.contains(where: \.isTemporal) {
            if history == nil || history?.width != output.width
                || history?.height != output.height {
                let fresh = try metal.makeIntermediate(width: output.width,
                                                       height: output.height)
                history = fresh
                seeded = false
                stateLock.lock()
                historyTexture = fresh
                historyValid = false
                stateLock.unlock()
            }
        }
        var destinations: [MTLTexture] = [output]
        if plan.count > 1 {
            let scratch = try ensureScratch(width: output.width, height: output.height)
            // First pass into the scratch, last pass into the real output, so
            // the picture the pipeline carries forward is always `output`
            // whichever slot happened to be filled.
            destinations = [scratch, output]
        }

        // The microphone, once per frame, off the mailbox. A level that is not
        // being published reads as silence and the envelope releases toward
        // it — which is what "the meter is not armed" should look like.
        let level = audioLevelSource?() ?? 0
        let reactive = Float(1 - Double(depth) + Double(depth) * envelope.step(
            level: level, elapsed: gap))

        for (index, pass) in plan.enumerated() {
            let dst = destinations[index]
            var params = PRISMStyleParams()
            let base = min(max(pass.intensity, 0), 1)
            params.intensity = pass.audioReactive ? base * reactive : base
            // Wrapped hourly before the Float32 narrowing: past ~a week of
            // uptime, Float ulp exceeds the VHS kernel's 1/24s reseed step and
            // its noise would hold-then-snap. The wrap is a fresh random seed
            // once an hour — indistinguishable inside noise reseeded at 24Hz.
            params.time = Float((now - timeBase).truncatingRemainder(dividingBy: 3600))
            params.aspect = Float(input.width) / Float(max(1, input.height))
            params.hasHistory = (pass.isTemporal && seeded) ? 1 : 0

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw PipelineError.encodingFailed("StyleStage: no compute encoder")
            }
            encoder.label = "StyleStage.\(pass.effect.rawValue)"
            encoder.setComputePipelineState(pass.pipeline)
            let src = index == 0 ? input : destinations[index - 1]
            if pass.isTemporal, let history {
                // First frame after a seed loss: the kernel outputs the source
                // untouched and this frame's blit below seeds the feedback.
                encoder.setTexture(src, index: 0)
                encoder.setTexture(history, index: 1)
                encoder.setTexture(dst, index: 2)
            } else {
                encoder.setTexture(src, index: 0)
                encoder.setTexture(dst, index: 1)
            }
            encoder.setBytes(&params, length: MemoryLayout<PRISMStyleParams>.stride, index: 0)
            dispatchOver(dst, pipeline: pass.pipeline, encoder: encoder)
            encoder.endEncoding()

            guard pass.isTemporal, let history else { continue }
            // Same command buffer, after this effect's compute pass: next
            // frame's history is THIS pass's output, not the stage's — a
            // motion effect in slot 0 must trail its own picture rather than
            // whatever slot 1 painted over it.
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw PipelineError.encodingFailed("StyleStage: no blit encoder")
            }
            blit.copy(from: dst, to: history)
            blit.endEncoding()
            // Publish only if no invalidation landed since the snapshot —
            // a seed-drop must never be overwritten by a completing frame.
            stateLock.lock()
            if historyTexture === history { historyValid = true }
            stateLock.unlock()
        }
    }

    // MARK: - Private

    /// One scratch texture, so two passes. The settings cap the stack at two
    /// as well (§5.29); this is the stage refusing to run a plan it has
    /// nowhere to land rather than trusting the model to agree with it — a
    /// third pass would have to read the texture the second is writing.
    private static let maxPasses = 2

    private func rebuild(dropsHistory: Bool) {
        // A missing kernel leaves the slot out of the plan rather than
        // failing frames; StyleStageTests pins every catalogue case to a
        // compiling kernel so this can only happen to a corrupted build.
        var built: [Pass] = []
        for layer in settings.renderableLayers.prefix(Self.maxPasses) {
            guard let name = layer.effect.kernelFunction,
                  let pipeline = try? metal.computePipeline(function: name) else { continue }
            built.append(Pass(effect: layer.effect,
                              pipeline: pipeline,
                              isTemporal: layer.effect.isTemporal,
                              intensity: Float(layer.clampedIntensity),
                              audioReactive: layer.audioReactive))
        }
        stateLock.lock()
        passes = built
        audioDepth = Float(settings.clampedAudioDepth)
        if dropsHistory {
            historyTexture = nil
            historyValid = false
        }
        stateLock.unlock()
    }

    private func ensureScratch(width: Int, height: Int) throws -> MTLTexture {
        stateLock.lock()
        let existing = scratchTexture
        stateLock.unlock()
        if let existing, existing.width == width, existing.height == height {
            return existing
        }
        let fresh = try metal.makeIntermediate(width: width, height: height)
        stateLock.lock()
        scratchTexture = fresh
        stateLock.unlock()
        return fresh
    }

    /// Everything the stage holds while it is on air. The scratch goes with
    /// the history: a stage that is off should not keep two
    /// working-resolution textures resident for a look nobody is running.
    private func release() {
        stateLock.lock()
        historyTexture = nil
        historyValid = false
        scratchTexture = nil
        stateLock.unlock()
    }
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
