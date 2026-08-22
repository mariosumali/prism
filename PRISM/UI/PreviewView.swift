// PreviewView.swift
// PRISM
//
// MTKView wrapper that draws the pipeline's post-effects output texture —
// exactly what clients see (§8.3). The quad pipeline is compiled from a
// small runtime MSL string; this is UI-side rendering, not the hot path.
// Used by both the popover and the main window's Studio pane; when neither
// surface is showing it (state.previewActive), the preview is fully torn
// down: paused view, released drawables, no texture references held.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import MetalKit
import SwiftUI

struct PreviewView: NSViewRepresentable {
    /// Which surface hosts this instance. The pause gate must be the OWNING
    /// surface's visibility, not the union: the main window outlives its
    /// close (isReleasedWhenClosed = false), so gating on the union would
    /// leave the hidden window's MTKView rendering whenever the popover is
    /// open — a second, invisible render loop in a resident agent.
    enum Surface {
        case popover
        case mainWindow
    }

    @EnvironmentObject var state: AppState

    var surface: Surface = .popover
    /// When true and a draft is pending, draws the draft renderer's output
    /// instead of the live pipeline's — the main window's editing panes use
    /// this so "what you're changing" is what the preview shows.
    var usesDraft = false

    private var surfaceVisible: Bool {
        switch surface {
        case .popover: return state.popoverOpen
        case .mainWindow: return state.mainWindowOpen
        }
    }

    func makeCoordinator() -> Renderer {
        Renderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Draw only when PreviewTextureBox receives a finished pipeline
        // frame. A free-running MTKView display link wakes the main thread and
        // acquires a drawable even when the camera is stalled or the pipeline
        // has deliberately dropped a frame.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.coordinator.attach(view)
        context.coordinator.frameObservation = state.observePreviewFrames {
            [weak renderer = context.coordinator] in
            renderer?.requestDraw()
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator
        view.preferredFramesPerSecond = max(state.config.format.frameRate, 1)
        if surfaceVisible {
            renderer.setTextureProvider((usesDraft && state.draftConfig != nil)
                ? state.draftPreviewTextureProvider
                : state.previewTextureProvider)
            renderer.requestDraw()
        } else {
            // §8.3 — zero GPU cost while closed: pause, drop every reference.
            renderer.setTextureProvider(nil)
            view.releaseDrawables()
        }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Renderer) {
        coordinator.frameObservation?.cancel()
        coordinator.frameObservation = nil
        coordinator.setTextureProvider(nil)
        view.delegate = nil
        view.releaseDrawables()
    }

    // MARK: - Renderer

    final class Renderer: NSObject, MTKViewDelegate {
        private static let sharedDevice = MTLCreateSystemDefaultDevice()
        private static let sharedCommandQueue = sharedDevice?.makeCommandQueue()
        private static let sharedPipelineState = makePipeline(device: sharedDevice)

        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private let pipelineState: MTLRenderPipelineState?
        private weak var view: MTKView?
        private let drawLock = NSLock()
        private var drawPending = false
        private var acceptsDrawRequests = false

        var frameObservation: PreviewFrameObservation?

        /// Set while the popover is open; nil tears the preview path down.
        private var textureProvider: (() -> MTLTexture?)?

        override init() {
            // Both preview surfaces use the same immutable pipeline and
            // thread-safe command queue. Compiling an identical runtime Metal
            // library per view wasted startup time and retained duplicate GPU
            // driver state after the main window was closed.
            self.device = Self.sharedDevice
            self.commandQueue = Self.sharedCommandQueue
            self.pipelineState = Self.sharedPipelineState
            super.init()
        }

        func attach(_ view: MTKView) {
            self.view = view
        }

        /// Called on the main thread by SwiftUI. The completion queue only
        /// reads the locked boolean; the closure itself stays main-thread
        /// confined alongside `draw(in:)`.
        func setTextureProvider(_ provider: (() -> MTLTexture?)?) {
            textureProvider = provider
            drawLock.lock()
            acceptsDrawRequests = provider != nil
            if provider == nil { drawPending = false }
            drawLock.unlock()
        }

        /// May be called from Metal's completion queue. Coalescing here is
        /// important: live and draft output can finish close together, and
        /// AppKit needs one main-thread invalidation, not a queue of stale
        /// draws that keeps running after the newest texture has arrived.
        func requestDraw() {
            drawLock.lock()
            guard acceptsDrawRequests, !drawPending else {
                drawLock.unlock()
                return
            }
            drawPending = true
            drawLock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.drawLock.lock()
                self.drawPending = false
                let shouldDraw = self.acceptsDrawRequests
                self.drawLock.unlock()
                guard shouldDraw, let view = self.view else { return }
                // Let AppKit align drawing with its display cycle. Calling
                // MTKView.draw() here can block the main thread in
                // CAMetalLayer.nextDrawable when the camera finishes between
                // display refreshes, making controls feel sticky.
                view.needsDisplay = true
            }
        }

        private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct PreviewVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex PreviewVertexOut prism_preview_vertex(uint vid [[vertex_id]],
                                                     constant float2 &scale [[buffer(0)]]) {
            float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0),
                                    float2(-1.0,  1.0), float2(1.0,  1.0) };
            float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0),
                              float2(0.0, 0.0), float2(1.0, 0.0) };
            PreviewVertexOut out;
            out.position = float4(positions[vid] * scale, 0.0, 1.0);
            out.uv = uvs[vid];
            return out;
        }

        fragment float4 prism_preview_fragment(PreviewVertexOut in [[stage_in]],
                                               texture2d<float> source [[texture(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear,
                                address::clamp_to_edge);
            return float4(source.sample(s, in.uv).rgb, 1.0);
        }
        """

        private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
            guard let device else { return nil }
            do {
                let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
                guard let vertex = library.makeFunction(name: "prism_preview_vertex"),
                      let fragment = library.makeFunction(name: "prism_preview_fragment")
                else { return nil }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let commandQueue,
                  let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }

            // No texture → clear-only pass (black), never stale content.
            if let pipelineState, let texture = textureProvider?() {
                var scale = Self.aspectFitScale(texture: texture,
                                                drawableSize: view.drawableSize)
                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// NDC scale that letterboxes the texture into the drawable.
        private static func aspectFitScale(texture: MTLTexture,
                                           drawableSize: CGSize) -> SIMD2<Float> {
            guard drawableSize.width > 0, drawableSize.height > 0,
                  texture.width > 0, texture.height > 0
            else { return SIMD2<Float>(1, 1) }
            let textureAspect = Float(texture.width) / Float(texture.height)
            let drawableAspect = Float(drawableSize.width) / Float(drawableSize.height)
            if textureAspect > drawableAspect {
                return SIMD2<Float>(1, drawableAspect / textureAspect)
            } else {
                return SIMD2<Float>(textureAspect / drawableAspect, 1)
            }
        }
    }
}
