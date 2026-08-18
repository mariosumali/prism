// MetalContextTests.swift
// PRISMTests
//
// The one shared CVMetalTextureCache every render surface wraps its pixel
// buffers through (§3.3). The interesting property is not that it produces a
// texture — every frame proves that — but that wrapping a buffer does not
// outlive the frame: a texture cache keeps its own reference to whatever it
// has wrapped until it is flushed, and a pool whose buffers are all still
// referenced cannot recycle. Nothing about that is visible in the picture;
// it shows up an hour later as "IOSurface creation failed … likely per
// client IOSurface limit of 16384 reached" and a dead app.
//
// Licensed under the Apache License, Version 2.0.

import CoreMedia
import CoreVideo
import Metal
import XCTest

final class MetalContextTests: XCTestCase {

    private func makeContext() throws -> MetalContext {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device on this host")
        }
        return try MetalContext()
    }

    private func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            prismPixelBufferAttributes(width: width, height: height) as CFDictionary,
            &pool)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pool)
    }

    /// Vend far more frames than any pool should need, releasing each texture
    /// before asking for the next — exactly the live pipeline's per-frame
    /// shape. Every one of those buffers should come back to the pool, so the
    /// run costs a handful of IOSurfaces, not one per frame. At 30 fps, "one
    /// per frame" is the 16384-surface ceiling in nine minutes.
    func testWrappingAFrameDoesNotPinItsBufferForever() throws {
        let metal = try makeContext()
        let pool = try makePool(width: 320, height: 180)

        var surfaces = Set<UInt>()
        for _ in 0..<120 {
            try autoreleasepool {
                var created: CVPixelBuffer?
                XCTAssertEqual(
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created),
                    kCVReturnSuccess)
                let buffer = try XCTUnwrap(created)
                _ = try metal.makeTexture(from: buffer)
                let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(buffer))
                surfaces.insert(UInt(bitPattern: surface.toOpaque()))
            }
        }

        XCTAssertLessThanOrEqual(surfaces.count, 8,
                                 "the pool stopped recycling: \(surfaces.count) surfaces for 120 frames")
    }

    /// The texture has to keep working after the cache is flushed — the
    /// flush may only drop what nothing references, or the frame in flight
    /// loses its pixels.
    func testWrappedTextureSurvivesLaterWrapping() throws {
        let metal = try makeContext()
        let pool = try makePool(width: 64, height: 64)

        var first: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &first),
            kCVReturnSuccess)
        let held = try metal.makeTexture(from: try XCTUnwrap(first))

        for _ in 0..<16 {
            try autoreleasepool {
                var created: CVPixelBuffer?
                XCTAssertEqual(
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created),
                    kCVReturnSuccess)
                _ = try metal.makeTexture(from: try XCTUnwrap(created))
            }
        }

        XCTAssertEqual(held.width, 64)
        XCTAssertEqual(held.height, 64)
        // The binding itself is the thing at risk, so check it directly.
        XCTAssertNotNil(held.iosurface, "the texture lost its IOSurface")
    }

    /// The same wrap, but reading the pixels back through the texture after
    /// every wrapper object the call site never saw has gone: the surface
    /// binding has to survive on the texture's own reference, or frames come
    /// out of the pipeline blank.
    func testWrappedTextureStillSeesItsPixels() throws {
        let metal = try makeContext()
        let pool = try makePool(width: 64, height: 64)

        var created: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)

        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        memset(base, 0x5A, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let texture = try metal.makeTexture(from: buffer)
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4,
                         from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(pixel[0], 0x5A)
        XCTAssertNotNil(texture.iosurface)
    }

    // MARK: - End to end

    /// The same property one level up, where it actually bit: a soak of the
    /// live pipeline. Every frame wraps a camera buffer, renders the chain
    /// and vends an output buffer from a pool, so a surface pinned anywhere
    /// in that path shows up here as an ever-growing set. Frames are paced
    /// on the output callback because the pipeline drops a frame that
    /// arrives while one is in flight, and a dropped frame proves nothing.
    func testPipelineSoakDoesNotMintASurfacePerFrame() throws {
        let metal = try makeContext()
        let pipeline = try VideoPipeline(metal: metal)
        pipeline.configure(outputFormat: VideoFormat(width: 640, height: 360, frameRate: 30))
        let pool = try makePool(width: 640, height: 360)

        let lock = NSLock()
        var outputs = Set<UInt>()
        let rendered = DispatchSemaphore(value: 0)
        pipeline.onOutput = { buffer, _, _ in
            if let surface = CVPixelBufferGetIOSurface(buffer) {
                lock.lock()
                outputs.insert(UInt(bitPattern: surface.toOpaque()))
                lock.unlock()
            }
            rendered.signal()
        }

        let frames = 180
        var sources = Set<UInt>()
        var completed = 0
        for frame in 0..<frames {
            try autoreleasepool {
                var created: CVPixelBuffer?
                XCTAssertEqual(
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created),
                    kCVReturnSuccess)
                let buffer = try XCTUnwrap(created)
                pipeline.submitCameraFrame(buffer,
                                           at: CMTime(value: CMTimeValue(frame), timescale: 30))
                let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(buffer))
                sources.insert(UInt(bitPattern: surface.toOpaque()))
                if rendered.wait(timeout: .now() + 1) == .success { completed += 1 }
            }
        }

        lock.lock()
        let outputCount = outputs.count
        lock.unlock()
        XCTAssertGreaterThan(completed, frames / 2, "too few frames rendered to prove anything")
        XCTAssertLessThanOrEqual(sources.count, 8,
                                 "camera buffers stopped recycling: \(sources.count) for \(frames) frames")
        XCTAssertLessThanOrEqual(outputCount, 24,
                                 "output buffers stopped recycling: \(outputCount) for \(frames) frames")
    }
}
