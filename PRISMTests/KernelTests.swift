// KernelTests.swift
// PRISMTests
//
// GPU correctness tests for the PRISMKernels compute kernels (SPEC §5.2–§5.4,
// CONTRACTS "Metal kernel contract"). Skipped wholesale when no Metal device
// is present. Kernels load from the test bundle's default library; small BGRA8
// textures are built from float RGBA patterns, each kernel runs in its own
// command buffer with a synchronous waitUntilCompleted, and results are read
// back on the CPU. Default tolerance is 2/255 per channel.
//
// Licensed under the Apache License, Version 2.0.

import Metal
import XCTest
import simd

final class KernelTests: XCTestCase {

    private enum Failure: Error {
        case missingKernel(String)
        case resourceAllocation(String)
    }

    private static let width = 64
    private static let height = 36
    private static let tolerance: Float = 2.0 / 255.0

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var library: MTLLibrary!
    private var pipelines: [String: MTLComputePipelineState] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host; skipping kernel tests")
        }
        device = dev
        guard let q = dev.makeCommandQueue() else {
            throw Failure.resourceAllocation("MTLCommandQueue")
        }
        queue = q
        // The .metal sources compile into the test bundle's default library.
        library = try dev.makeDefaultLibrary(bundle: Bundle(for: Self.self))
    }

    // MARK: - Harness

    private var textureStorageMode: MTLStorageMode {
        device.hasUnifiedMemory ? .shared : .managed
    }

    private func pipeline(_ name: String) throws -> MTLComputePipelineState {
        if let cached = pipelines[name] { return cached }
        guard let fn = library.makeFunction(name: name) else {
            throw Failure.missingKernel(name)
        }
        let state = try device.makeComputePipelineState(function: fn)
        pipelines[name] = state
        return state
    }

    /// BGRA8 texture filled from an RGBA float pattern (row-major).
    private func makeTexture(width: Int, height: Int,
                             pixels: [SIMD4<Float>]) throws -> MTLTexture {
        precondition(pixels.count == width * height)
        let texture = try makeOutputTexture(width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (i, p) in pixels.enumerated() {
            let c = p.clamped(lowerBound: .zero, upperBound: .one)
            bytes[i * 4 + 0] = UInt8((c.z * 255).rounded())   // B
            bytes[i * 4 + 1] = UInt8((c.y * 255).rounded())   // G
            bytes[i * 4 + 2] = UInt8((c.x * 255).rounded())   // R
            bytes[i * 4 + 3] = UInt8((c.w * 255).rounded())   // A
        }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: $0.baseAddress!,
                            bytesPerRow: width * 4)
        }
        return texture
    }

    private func makeOutputTexture(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = textureStorageMode
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw Failure.resourceAllocation("\(width)×\(height) BGRA8 texture")
        }
        return texture
    }

    /// Single-channel r8Unorm mask (person = 1), as prism_composite expects.
    private func makeMaskTexture(width: Int, height: Int,
                                 values: [Float]) throws -> MTLTexture {
        precondition(values.count == width * height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = textureStorageMode
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw Failure.resourceAllocation("\(width)×\(height) r8 mask")
        }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for (i, v) in values.enumerated() {
            bytes[i] = UInt8((min(max(v, 0), 1) * 255).rounded())
        }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: $0.baseAddress!,
                            bytesPerRow: width)
        }
        return texture
    }

    /// N³ rgba8Unorm 3D LUT whose texel (r,g,b) holds `value(r,g,b)`.
    private func makeLUTTexture(size: Int,
                                value: (Int, Int, Int) -> SIMD3<Float>) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba8Unorm
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.usage = [.shaderRead]
        desc.storageMode = textureStorageMode
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw Failure.resourceAllocation("\(size)³ LUT texture")
        }
        var bytes = [UInt8](repeating: 0, count: size * size * size * 4)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = value(r, g, b).clamped(lowerBound: .zero, upperBound: .one)
                    let offset = ((b * size + g) * size + r) * 4
                    bytes[offset + 0] = UInt8((v.x * 255).rounded())
                    bytes[offset + 1] = UInt8((v.y * 255).rounded())
                    bytes[offset + 2] = UInt8((v.z * 255).rounded())
                    bytes[offset + 3] = 255
                }
            }
        }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size),
                            mipmapLevel: 0,
                            slice: 0,
                            withBytes: $0.baseAddress!,
                            bytesPerRow: size * 4,
                            bytesPerImage: size * size * 4)
        }
        return texture
    }

    /// Raw BGRA bytes of a texture (post-GPU contents must have been
    /// synchronized by the dispatch helper on discrete-memory devices).
    private func rawBytes(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!,
                             bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return bytes
    }

    /// Texture contents as RGBA floats, row-major.
    private func readPixels(_ texture: MTLTexture) -> [SIMD4<Float>] {
        let bytes = rawBytes(texture)
        return (0..<(texture.width * texture.height)).map { i in
            SIMD4(Float(bytes[i * 4 + 2]) / 255,
                  Float(bytes[i * 4 + 1]) / 255,
                  Float(bytes[i * 4 + 0]) / 255,
                  Float(bytes[i * 4 + 3]) / 255)
        }
    }

    /// Encodes one compute pass and blocks until the GPU finishes. Managed
    /// GPU-written textures are blit-synchronized so getBytes sees them.
    private func dispatch(_ name: String,
                          threadgroups: MTLSize,
                          threadsPerThreadgroup: MTLSize,
                          synchronizing: [MTLTexture] = [],
                          configure: (MTLComputeCommandEncoder) -> Void) throws {
        let state = try pipeline(name)
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw Failure.resourceAllocation("command buffer for \(name)")
        }
        encoder.setComputePipelineState(state)
        configure(encoder)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        if textureStorageMode == .managed, !synchronizing.isEmpty,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            for texture in synchronizing { blit.synchronize(resource: texture) }
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error, "\(name) command buffer failed")
    }

    /// Standard 2D grid covering `output`; kernels guard out-of-bounds gid.
    private func run2D(_ name: String, output: MTLTexture,
                       configure: (MTLComputeCommandEncoder) -> Void) throws {
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (output.width + group.width - 1) / group.width,
                           height: (output.height + group.height - 1) / group.height,
                           depth: 1)
        try dispatch(name, threadgroups: grid, threadsPerThreadgroup: group,
                     synchronizing: [output], configure: configure)
    }

    private func setParams<T>(_ encoder: MTLComputeCommandEncoder, _ value: T, index: Int) {
        var copy = value
        encoder.setBytes(&copy, length: MemoryLayout<T>.stride, index: index)
    }

    // MARK: - Patterns and assertions

    /// Deterministic pattern with variation in every channel including alpha.
    private func variedPattern(width: Int = KernelTests.width,
                               height: Int = KernelTests.height) -> [SIMD4<Float>] {
        (0..<(width * height)).map { i in
            let x = i % width
            let y = i / width
            return SIMD4(Float((x * 7 + y * 13) % 251) / 250,
                         Float((x * 31 + y * 3) % 239) / 238,
                         Float((x * 5 + y * 17) % 227) / 226,
                         Float((x * 11 + y * 29) % 199) / 198)
        }
    }

    private func uniform(_ color: SIMD4<Float>,
                         width: Int = KernelTests.width,
                         height: Int = KernelTests.height) -> [SIMD4<Float>] {
        [SIMD4<Float>](repeating: color, count: width * height)
    }

    private func checkerboard(width: Int, height: Int, block: Int) -> [SIMD4<Float>] {
        (0..<(width * height)).map { i in
            let bx = (i % width) / block
            let by = (i / width) / block
            let v: Float = ((bx + by) % 2 == 0) ? 1 : 0
            return SIMD4(v, v, v, 1)
        }
    }

    /// CPU 3×3 box blur (clamped edges) of the RGB channels; alpha forced 1.
    private func boxBlurred3x3(_ pixels: [SIMD4<Float>],
                               width: Int, height: Int) -> [SIMD4<Float>] {
        var out = pixels
        for y in 0..<height {
            for x in 0..<width {
                var acc = SIMD3<Float>.zero
                for dy in -1...1 {
                    for dx in -1...1 {
                        let sx = min(max(x + dx, 0), width - 1)
                        let sy = min(max(y + dy, 0), height - 1)
                        let p = pixels[sy * width + sx]
                        acc += SIMD3(p.x, p.y, p.z)
                    }
                }
                let m = acc / 9
                out[y * width + x] = SIMD4(m.x, m.y, m.z, 1)
            }
        }
        return out
    }

    /// What a float pattern becomes after the 8-bit upload quantization.
    private func quantized(_ v: SIMD4<Float>) -> SIMD4<Float> {
        let c = v.clamped(lowerBound: .zero, upperBound: .one)
        return SIMD4((c.x * 255).rounded() / 255,
                     (c.y * 255).rounded() / 255,
                     (c.z * 255).rounded() / 255,
                     (c.w * 255).rounded() / 255)
    }

    private func assertClose(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>,
                             tolerance: Float = KernelTests.tolerance,
                             _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        for c in 0..<4 {
            XCTAssertEqual(actual[c], expected[c], accuracy: tolerance,
                           "channel \(c) \(message)", file: file, line: line)
        }
    }

    private func assertImagesClose(_ actual: [SIMD4<Float>], _ expected: [SIMD4<Float>],
                                   tolerance: Float = KernelTests.tolerance,
                                   _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        var worst: Float = 0
        var worstIndex = 0
        for i in 0..<min(actual.count, expected.count) {
            let d = simd_reduce_max(simd_abs(actual[i] - expected[i]))
            if d > worst {
                worst = d
                worstIndex = i
            }
        }
        XCTAssertLessThanOrEqual(
            worst, tolerance,
            "\(message) — worst deviation \(worst) at pixel index \(worstIndex)",
            file: file, line: line)
    }

    private func pixel(_ image: [SIMD4<Float>], _ x: Int, _ y: Int,
                       width: Int = KernelTests.width) -> SIMD4<Float> {
        image[y * width + x]
    }

    // MARK: - 1. prism_copy

    func testCopyIsExact() throws {
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: variedPattern())
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)
        try run2D("prism_copy", output: dst) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
        }
        // Same dimensions → the bilinear sampler lands on exact texel centers;
        // the copy must be byte-exact, alpha included.
        XCTAssertEqual(rawBytes(dst), rawBytes(src), "prism_copy must be exact")
    }

    // MARK: - 2. prism_adjust

    private func adjustParams(exposure: Float = 0, contrast: Float = 1,
                              saturation: Float = 1, temperature: Float = 0,
                              vignette: Float = 0) -> PRISMAdjustParams {
        var p = PRISMAdjustParams()
        p.exposureEV = exposure
        p.contrast = contrast
        p.saturation = saturation
        p.temperature = temperature
        p.vignette = vignette
        return p
    }

    private func runAdjust(_ params: PRISMAdjustParams,
                           on src: MTLTexture) throws -> [SIMD4<Float>] {
        let dst = try makeOutputTexture(width: src.width, height: src.height)
        try run2D("prism_adjust", output: dst) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            setParams(enc, params, index: 0)
        }
        return readPixels(dst)
    }

    func testAdjustIdentityIsPassThrough() throws {
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: variedPattern())
        let out = try runAdjust(adjustParams(), on: src)
        assertImagesClose(out, readPixels(src), "identity adjust must pass through")
    }

    /// The shader implements exposure as a straight gain in its working space:
    /// rgb *= exp2(EV) (Adjust.metal). +1 EV on mid-gray therefore lands at
    /// exactly 2× the stored value, and intermediate EVs follow 2^EV
    /// monotonically.
    func testAdjustExposureCurve() throws {
        let gray: Float = 0.25
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: uniform(SIMD4(gray, gray, gray, 1)))
        let stored = quantized(SIMD4(gray, gray, gray, 1)).x

        let ev0 = pixel(try runAdjust(adjustParams(exposure: 0), on: src), 32, 18)
        let evHalf = pixel(try runAdjust(adjustParams(exposure: 0.5), on: src), 32, 18)
        let ev1 = pixel(try runAdjust(adjustParams(exposure: 1), on: src), 32, 18)

        XCTAssertEqual(ev0.x, stored, accuracy: Self.tolerance)
        XCTAssertEqual(evHalf.x, stored * exp2(0.5), accuracy: Self.tolerance,
                       "+0.5 EV must follow the 2^EV gain curve")
        XCTAssertEqual(ev1.x, stored * 2, accuracy: Self.tolerance,
                       "+1 EV must be 2× in the shader's working space")
        XCTAssertLessThan(ev0.x, evHalf.x, "exposure must brighten monotonically")
        XCTAssertLessThan(evHalf.x, ev1.x, "exposure must brighten monotonically")
    }

    func testAdjustSaturationZeroIsGrayscale() throws {
        let color = SIMD4<Float>(0.8, 0.2, 0.4, 1)
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: uniform(color))
        let out = pixel(try runAdjust(adjustParams(saturation: 0), on: src), 32, 18)

        XCTAssertEqual(out.x, out.y, accuracy: Self.tolerance, "R must equal G at saturation 0")
        XCTAssertEqual(out.y, out.z, accuracy: Self.tolerance, "G must equal B at saturation 0")

        let stored = quantized(color)
        let luma = simd_dot(SIMD3(stored.x, stored.y, stored.z),
                            SIMD3<Float>(0.2126, 0.7152, 0.0722))
        XCTAssertEqual(out.x, luma, accuracy: Self.tolerance,
                       "saturation 0 must collapse to Rec.709 luma")
    }

    func testAdjustVignetteDarkensCornersMoreThanCenter() throws {
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: uniform(SIMD4(0.5, 0.5, 0.5, 1)))
        let out = try runAdjust(adjustParams(vignette: 1), on: src)

        let center = pixel(out, Self.width / 2, Self.height / 2)
        let corner = pixel(out, 0, 0)
        XCTAssertEqual(center.x, quantized(SIMD4(0.5, 0.5, 0.5, 1)).x,
                       accuracy: Self.tolerance,
                       "vignette falloff must be zero at the center")
        XCTAssertLessThan(corner.x, center.x - 0.25,
                          "vignette must darken corners well below the center")
    }

    // MARK: - 3. prism_lut

    private func runLUT(strength: Float, lut: MTLTexture,
                        on src: MTLTexture) throws -> [SIMD4<Float>] {
        let dst = try makeOutputTexture(width: src.width, height: src.height)
        try run2D("prism_lut", output: dst) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            enc.setTexture(lut, index: 2)
            var p = PRISMLUTParams()
            p.strength = strength
            setParams(enc, p, index: 0)
        }
        return readPixels(dst)
    }

    func testLUTIdentityPassesThrough() throws {
        // 2³ identity cube: texel (r,g,b) = (r,g,b)/(N−1). Trilinear
        // interpolation of the identity lattice reproduces the input.
        let identity = try makeLUTTexture(size: 2) { r, g, b in
            SIMD3(Float(r), Float(g), Float(b))
        }
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: variedPattern())
        let out = try runLUT(strength: 1, lut: identity, on: src)
        assertImagesClose(out, readPixels(src), "identity LUT at strength 1 must pass through")
    }

    func testLUTStrengthZeroIgnoresLUTContents() throws {
        // Inverted cube: texel (r,g,b) = 1 − identity. Wrong in every entry —
        // strength 0 must still pass the source through untouched.
        let inverted = try makeLUTTexture(size: 2) { r, g, b in
            SIMD3(1 - Float(r), 1 - Float(g), 1 - Float(b))
        }
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: variedPattern())
        let out = try runLUT(strength: 0, lut: inverted, on: src)
        assertImagesClose(out, readPixels(src), "strength 0 must ignore the LUT")

        // Sanity: the same LUT at strength 1 must invert, proving the
        // pass-through above came from strength, not a dead LUT path.
        let outFull = try runLUT(strength: 1, lut: inverted, on: src)
        let expected = readPixels(src).map { SIMD4(1 - $0.x, 1 - $0.y, 1 - $0.z, $0.w) }
        assertImagesClose(outFull, expected, "inverted LUT at strength 1 must invert RGB")
    }

    // MARK: - 4. prism_geometry

    private func runGeometry(_ transform: simd_float3x3, lanczos: Bool = false,
                             on src: MTLTexture) throws -> [SIMD4<Float>] {
        let dst = try makeOutputTexture(width: src.width, height: src.height)
        try run2D("prism_geometry", output: dst) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            var p = PRISMGeometryParams()
            p.uvTransform = transform
            p.useLanczos = lanczos ? 1 : 0
            setParams(enc, p, index: 0)
        }
        return readPixels(dst)
    }

    func testGeometryIdentityPassesThrough() throws {
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: variedPattern())
        let out = try runGeometry(matrix_identity_float3x3, on: src)
        assertImagesClose(out, readPixels(src), "identity uvTransform must pass through")
    }

    func testGeometryHorizontalMirrorFlipsPattern() throws {
        // Left half black, right half white.
        let pixels = (0..<(Self.width * Self.height)).map { i -> SIMD4<Float> in
            (i % Self.width) < Self.width / 2 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1)
        }
        let src = try makeTexture(width: Self.width, height: Self.height, pixels: pixels)

        // Output UV → input UV: u' = 1 − u (column-major columns).
        let mirror = simd_float3x3(SIMD3<Float>(-1, 0, 0),
                                   SIMD3<Float>(0, 1, 0),
                                   SIMD3<Float>(1, 0, 1))
        let out = try runGeometry(mirror, on: src)

        // Sampled away from the mid boundary to stay clear of bilinear blend.
        assertClose(pixel(out, 8, 18), SIMD4(1, 1, 1, 1), "left output must be white after mirror")
        assertClose(pixel(out, 24, 18), SIMD4(1, 1, 1, 1), "left output must be white after mirror")
        assertClose(pixel(out, 40, 18), SIMD4(0, 0, 0, 1), "right output must be black after mirror")
        assertClose(pixel(out, 56, 18), SIMD4(0, 0, 0, 1), "right output must be black after mirror")
    }

    func testGeometryOutOfRangeUVIsOpaqueBlack() throws {
        // Zoom-out style matrix: inUV = 2·outUV − 0.5. The outer border of the
        // output maps outside [0,1] and must come back opaque black.
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: uniform(SIMD4(1, 1, 1, 1)))
        let zoomOut = simd_float3x3(SIMD3<Float>(2, 0, 0),
                                    SIMD3<Float>(0, 2, 0),
                                    SIMD3<Float>(-0.5, -0.5, 1))
        let out = try runGeometry(zoomOut, on: src)

        for (x, y) in [(0, 0), (Self.width - 1, 0), (0, Self.height - 1),
                       (Self.width - 1, Self.height - 1)] {
            let p = pixel(out, x, y)
            XCTAssertEqual(p.x, 0, "out-of-range UV must be black at (\(x),\(y))")
            XCTAssertEqual(p.y, 0, "out-of-range UV must be black at (\(x),\(y))")
            XCTAssertEqual(p.z, 0, "out-of-range UV must be black at (\(x),\(y))")
            XCTAssertEqual(p.w, 1, "out-of-range UV must be opaque at (\(x),\(y))")
        }
        // Center still samples the (white) source.
        assertClose(pixel(out, Self.width / 2, Self.height / 2), SIMD4(1, 1, 1, 1),
                    "center must still sample the source")
    }

    // MARK: - 5. prism_blur

    private func runBlur(direction: SIMD2<Float>, radius: Float,
                         from src: MTLTexture, to dst: MTLTexture) throws {
        try run2D("prism_blur", output: dst) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            var p = PRISMBlurParams()
            p.direction = direction
            p.radius = radius
            setParams(enc, p, index: 0)
        }
    }

    func testBlurImpulseSpreadsEnergy() throws {
        var pixels = uniform(SIMD4(0, 0, 0, 1))
        let cx = Self.width / 2
        let cy = Self.height / 2
        pixels[cy * Self.width + cx] = SIMD4(1, 1, 1, 1)
        let src = try makeTexture(width: Self.width, height: Self.height, pixels: pixels)
        let tmp = try makeOutputTexture(width: Self.width, height: Self.height)
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)

        let radius: Float = 2   // sigma 1 → 7 taps, well inside the frame

        try runBlur(direction: SIMD2(1, 0), radius: radius, from: src, to: tmp)
        let horizontal = readPixels(tmp)
        XCTAssertLessThanOrEqual(pixel(horizontal, cx, cy - 1).x, Self.tolerance,
                                 "horizontal pass must not spread vertically")
        XCTAssertGreaterThan(pixel(horizontal, cx + 1, cy).x, 0.05,
                             "horizontal pass must spread horizontally")

        try runBlur(direction: SIMD2(0, 1), radius: radius, from: tmp, to: dst)
        let blurred = readPixels(dst)

        let center = pixel(blurred, cx, cy).x
        XCTAssertLessThan(center, 0.5, "impulse center must be attenuated")
        XCTAssertGreaterThan(center, 0.02, "impulse center must survive")
        XCTAssertGreaterThan(pixel(blurred, cx - 1, cy).x, 0.02, "left neighbor must receive energy")
        XCTAssertGreaterThan(pixel(blurred, cx + 1, cy).x, 0.02, "right neighbor must receive energy")
        XCTAssertGreaterThan(pixel(blurred, cx, cy - 1).x, 0.02, "top neighbor must receive energy")
        XCTAssertGreaterThan(pixel(blurred, cx, cy + 1).x, 0.02, "bottom neighbor must receive energy")

        // Normalized Gaussian taps conserve DC: total red energy of the
        // impulse (1.0) survives the two passes within quantization noise.
        let energy = blurred.reduce(Float(0)) { $0 + $1.x }
        XCTAssertEqual(energy, 1.0, accuracy: 0.15,
                       "separable blur must roughly conserve energy (got \(energy))")
    }

    func testBlurRadiusZeroIsPassThroughAndExtremeRadiusDoesNotCrash() throws {
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: variedPattern())
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)

        // Radius 0 → early-out pass-through.
        try runBlur(direction: SIMD2(1, 0), radius: 0, from: src, to: dst)
        assertImagesClose(readPixels(dst), readPixels(src), "radius 0 must pass through")

        // Edge of range: sigma far past the 31-tap clamp. Must complete
        // without error (asserted inside dispatch) and stay in range. The
        // blur runs on all four channels, so use an opaque source when
        // checking that alpha comes out untouched.
        let opaque = try makeTexture(
            width: Self.width, height: Self.height,
            pixels: variedPattern().map { SIMD4($0.x, $0.y, $0.z, 1) })
        let big = try makeOutputTexture(width: Self.width, height: Self.height)
        try runBlur(direction: SIMD2(1, 0), radius: 100, from: opaque, to: dst)
        try runBlur(direction: SIMD2(0, 1), radius: 100, from: dst, to: big)
        for p in readPixels(big) {
            XCTAssertEqual(p.w, 1, "alpha must survive an extreme blur of an opaque source")
        }
    }

    // MARK: - 6. prism_composite

    func testCompositeMaskSelectsSharpOverBlurred() throws {
        let sharpColor = SIMD4<Float>(1, 0, 0, 1)      // "sharp input" stand-in
        let blurredColor = SIMD4<Float>(0, 0, 1, 1)    // "blurred input" stand-in
        let sharp = try makeTexture(width: Self.width, height: Self.height,
                                    pixels: uniform(sharpColor))
        let blurred = try makeTexture(width: Self.width, height: Self.height,
                                      pixels: uniform(blurredColor))
        // Person (mask = 1) on the left, background (mask = 0) on the right.
        let maskValues = (0..<(Self.width * Self.height)).map { i -> Float in
            (i % Self.width) < Self.width / 2 ? 1 : 0
        }
        let mask = try makeMaskTexture(width: Self.width, height: Self.height,
                                       values: maskValues)
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)

        try run2D("prism_composite", output: dst) { enc in
            enc.setTexture(sharp, index: 0)
            enc.setTexture(blurred, index: 1)
            enc.setTexture(mask, index: 2)
            enc.setTexture(dst, index: 3)
            var p = PRISMCompositeParams()
            p.maskContrast = 1                          // mask exactly as delivered
            setParams(enc, p, index: 0)
        }
        let out = readPixels(dst)

        assertClose(pixel(out, 8, 18), sharpColor, "mask=1 region must show the sharp input")
        assertClose(pixel(out, 24, 18), sharpColor, "mask=1 region must show the sharp input")
        assertClose(pixel(out, 40, 18), blurredColor, "mask=0 region must show the blurred input")
        assertClose(pixel(out, 56, 18), blurredColor, "mask=0 region must show the blurred input")
    }

    // MARK: - 7. prism_output_fit

    func testOutputFitLetterboxesSixteenNineIntoSquare() throws {
        // 64×36 (16:9) content into a 64×64 (1:1) output. Content alpha is
        // deliberately 0.5 to prove the kernel forces opaque output.
        let contentPixels = (0..<(Self.width * Self.height)).map { i -> SIMD4<Float> in
            (i % Self.width) < Self.width / 2
                ? SIMD4(1, 0, 0, 0.5)
                : SIMD4(0, 1, 0, 0.5)
        }
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: contentPixels)
        let outSize = 64
        let dst = try makeOutputTexture(width: outSize, height: outSize)

        // Letterbox: content spans full width, 36/64 of the height, centered.
        let scaleY = Float(Self.height) / Float(outSize)          // 0.5625
        try run2D("prism_output_fit", output: dst) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            var p = PRISMFitParams()
            p.scale = SIMD2(1, scaleY)
            p.offset = SIMD2(0, (1 - scaleY) / 2)                 // 0.21875
            p.fillMode = 0
            setParams(enc, p, index: 0)
        }
        let out = readPixels(dst)

        // Content occupies rows 14…49; bars are rows 0…13 and 50…63.
        for y in [0, 5, 13, 50, 60, 63] {
            for x in [0, 16, 47, 63] {
                let p = pixel(out, x, y, width: outSize)
                XCTAssertEqual(p.x, 0, "bar row \(y) must be black")
                XCTAssertEqual(p.y, 0, "bar row \(y) must be black")
                XCTAssertEqual(p.z, 0, "bar row \(y) must be black")
                XCTAssertEqual(p.w, 1, "bar row \(y) must be opaque")
            }
        }
        for y in [14, 32, 49] {
            assertClose(pixel(out, 8, y, width: outSize), SIMD4(1, 0, 0, 1),
                        "content row \(y) left half must be preserved")
            assertClose(pixel(out, 56, y, width: outSize), SIMD4(0, 1, 0, 1),
                        "content row \(y) right half must be preserved")
        }
        let minAlpha = out.map(\.w).min() ?? 0
        XCTAssertEqual(minAlpha, 1, "alpha must be 1 everywhere in the fitted output")
    }

    // MARK: - 8. prism_crossfade

    func testCrossfadeMixEndpointsAndMidpoint() throws {
        let colorA = SIMD4<Float>(0.8, 0.2, 0.4, 1)
        let colorB = SIMD4<Float>(0.2, 0.6, 0.8, 1)
        let texA = try makeTexture(width: Self.width, height: Self.height,
                                   pixels: uniform(colorA))
        let texB = try makeTexture(width: Self.width, height: Self.height,
                                   pixels: uniform(colorB))

        func crossfade(_ mix: Float) throws -> SIMD4<Float> {
            let dst = try makeOutputTexture(width: Self.width, height: Self.height)
            try run2D("prism_crossfade", output: dst) { enc in
                enc.setTexture(texA, index: 0)
                enc.setTexture(texB, index: 1)
                enc.setTexture(dst, index: 2)
                var p = PRISMCrossfadeParams()
                p.mix = mix
                setParams(enc, p, index: 0)
            }
            return pixel(readPixels(dst), 32, 18)
        }

        let storedA = quantized(colorA)
        let storedB = quantized(colorB)
        assertClose(try crossfade(0), storedA, "mix 0 must be A")
        assertClose(try crossfade(1), storedB, "mix 1 must be B")
        assertClose(try crossfade(0.5), (storedA + storedB) / 2,
                    tolerance: 3.0 / 255.0, "mix 0.5 must be the midpoint")
    }

    // MARK: - 9. prism_sharpness

    /// CONTRACTS dispatch geometry: exactly ONE threadgroup of 256 threads.
    private func scoreSharpness(of texture: MTLTexture, slot: Int,
                                into buffer: MTLBuffer) throws {
        try dispatch("prism_sharpness",
                     threadgroups: MTLSize(width: 1, height: 1, depth: 1),
                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)) { enc in
            enc.setTexture(texture, index: 0)
            enc.setBuffer(buffer, offset: 0, index: 0)
            var p = PRISMSharpnessParams()
            p.slot = UInt32(slot)
            setParams(enc, p, index: 1)
        }
    }

    func testSharpnessOrderingAndSlotAddressing() throws {
        let slotCount = 15                          // matches FrameRing capacity
        guard let buffer = device.makeBuffer(length: slotCount * MemoryLayout<Float>.stride,
                                             options: .storageModeShared) else {
            throw Failure.resourceAllocation("sharpness result buffer")
        }
        let sentinel: Float = -1
        let slots = buffer.contents().bindMemory(to: Float.self, capacity: slotCount)
        for i in 0..<slotCount { slots[i] = sentinel }

        let flat = try makeTexture(width: Self.width, height: Self.height,
                                   pixels: uniform(SIMD4(0.5, 0.5, 0.5, 1)))
        let checkerPixels = checkerboard(width: Self.width, height: Self.height, block: 4)
        let checker = try makeTexture(width: Self.width, height: Self.height,
                                      pixels: checkerPixels)
        let softened = try makeTexture(width: Self.width, height: Self.height,
                                       pixels: boxBlurred3x3(checkerPixels,
                                                             width: Self.width,
                                                             height: Self.height))

        // PRISMSharpnessParams.slot addresses result[slot] directly.
        try scoreSharpness(of: flat, slot: 1, into: buffer)
        try scoreSharpness(of: checker, slot: 3, into: buffer)
        try scoreSharpness(of: softened, slot: 4, into: buffer)

        let flatScore = slots[1]
        let checkerScore = slots[3]
        let softenedScore = slots[4]

        XCTAssertLessThan(flatScore, 1e-4, "flat gray has no Laplacian energy")
        XCTAssertGreaterThan(checkerScore, flatScore + 0.01,
                             "checkerboard must score far above flat gray")
        XCTAssertGreaterThan(checkerScore, softenedScore * 1.5,
                             "sharp pattern must outscore its box-blurred copy")

        // Every other slot keeps its sentinel: the kernel writes result[slot]
        // and nothing else.
        for i in 0..<slotCount where ![1, 3, 4].contains(i) {
            XCTAssertEqual(slots[i], sentinel, "slot \(i) must be untouched")
        }
    }

    // MARK: - 10. prism_retouch_blur / prism_retouch_combine

    /// A mid-grey with a skin hue: what the gate is supposed to let through.
    private static let skinColor = SIMD4<Float>(0.78, 0.60, 0.50, 1)

    private func runRetouchBlur(direction: SIMD2<Float>,
                                radius: Float,
                                rangeSigma: Float,
                                from src: MTLTexture,
                                to dst: MTLTexture) throws {
        try run2D("prism_retouch_blur", output: dst) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            var p = PRISMRetouchBlurParams()
            p.direction = direction
            p.radius = radius
            p.rangeSigma = rangeSigma
            setParams(enc, p, index: 0)
        }
    }

    private func runRetouchCombine(src: MTLTexture,
                                   smoothed: MTLTexture,
                                   mask: MTLTexture?,
                                   amount: Float,
                                   detail: Float,
                                   to dst: MTLTexture) throws {
        try run2D("prism_retouch_combine", output: dst) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(smoothed, index: 1)
            enc.setTexture(mask ?? src, index: 2)
            enc.setTexture(dst, index: 3)
            var p = PRISMRetouchParams()
            p.amount = amount
            p.detail = detail
            p.useMask = mask == nil ? 0 : 1
            setParams(enc, p, index: 0)
        }
    }

    /// The edge-preserving claim, stated as a comparison: with a tight range
    /// sigma a luma cliff survives the blur, and with a loose one — which is
    /// a plain Gaussian in all but name — it does not. This is the whole
    /// difference between a retouched face and a plastic one.
    func testRetouchBlurKeepsAHardEdgeThatAGaussianWouldMelt() throws {
        // Dark left half, bright right half — an eyelash, structurally.
        let step = (0..<(Self.width * Self.height)).map { i -> SIMD4<Float> in
            (i % Self.width) < Self.width / 2 ? SIMD4(0.1, 0.1, 0.1, 1)
                                              : SIMD4(0.9, 0.9, 0.9, 1)
        }
        let src = try makeTexture(width: Self.width, height: Self.height, pixels: step)
        let preserved = try makeOutputTexture(width: Self.width, height: Self.height)
        let melted = try makeOutputTexture(width: Self.width, height: Self.height)

        try runRetouchBlur(direction: SIMD2(1, 0), radius: 8, rangeSigma: 0.03,
                           from: src, to: preserved)
        try runRetouchBlur(direction: SIMD2(1, 0), radius: 8, rangeSigma: 10,
                           from: src, to: melted)

        // One pixel to the left of the seam, on the dark side.
        let x = Self.width / 2 - 1
        let dark = pixel(readPixels(preserved), x, 18).x
        let bled = pixel(readPixels(melted), x, 18).x
        XCTAssertLessThan(dark, 0.2, "the bilateral must not pull the bright half across")
        XCTAssertGreaterThan(bled, dark + 0.15,
                             "a wide range sigma is a plain Gaussian and must bleed")
    }

    /// Inside a region of one colour there is no edge to protect, so the
    /// bilateral has to smooth exactly like the Gaussian it is built from —
    /// otherwise it would preserve the pores it exists to soften.
    func testRetouchBlurStillSmoothsWithinOneTone() throws {
        var pixels = uniform(SIMD4<Float>(0.5, 0.5, 0.5, 1))
        // A speck of texture: one pixel a little brighter than its neighbours.
        pixels[18 * Self.width + 32] = SIMD4(0.56, 0.56, 0.56, 1)
        let src = try makeTexture(width: Self.width, height: Self.height, pixels: pixels)
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)
        try runRetouchBlur(direction: SIMD2(1, 0), radius: 6, rangeSigma: 0.12,
                           from: src, to: dst)
        let out = pixel(readPixels(dst), 32, 18).x
        XCTAssertLessThan(out, 0.545, "fine texture within one tone must be averaged away")
        XCTAssertGreaterThan(out, 0.5)
    }

    /// Amount 0 is off, not "run four passes and write the source back with a
    /// rounding error in it".
    func testRetouchCombineAtZeroAmountIsExactPassThrough() throws {
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: uniform(Self.skinColor))
        let smoothed = try makeTexture(width: Self.width, height: Self.height,
                                       pixels: uniform(SIMD4(0, 1, 0, 1)))
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)
        try runRetouchCombine(src: src, smoothed: smoothed, mask: nil,
                              amount: 0, detail: 0, to: dst)
        assertImagesClose(readPixels(dst), readPixels(src),
                          "amount 0 must not touch a single pixel")
    }

    /// Full detail restores everything the blur removed, so the combine is an
    /// identity however hard the smoothing was. This is the property that
    /// makes `detail` the honest knob it claims to be.
    func testRetouchCombineAtFullDetailReturnsTheSource() throws {
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: uniform(Self.skinColor))
        let smoothed = try makeTexture(width: Self.width, height: Self.height,
                                       pixels: uniform(SIMD4(0.5, 0.4, 0.35, 1)))
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)
        try runRetouchCombine(src: src, smoothed: smoothed, mask: nil,
                              amount: 1, detail: 1, to: dst)
        assertImagesClose(readPixels(dst), readPixels(src),
                          "detail 1 hands every removed frequency back")
    }

    /// The gate is chroma, so a blue wall behind someone is left alone even
    /// at full amount — and the same test says the gate is doing something
    /// rather than passing everything.
    func testRetouchCombineSmoothsSkinAndLeavesOtherColoursAlone() throws {
        let half = (0..<(Self.width * Self.height)).map { i -> SIMD4<Float> in
            (i % Self.width) < Self.width / 2 ? Self.skinColor
                                              : SIMD4(0.15, 0.25, 0.80, 1)
        }
        let src = try makeTexture(width: Self.width, height: Self.height, pixels: half)
        // A flat "smoothed" input, so any movement is unambiguous.
        let smoothed = try makeTexture(width: Self.width, height: Self.height,
                                       pixels: uniform(SIMD4(0.5, 0.5, 0.5, 1)))
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)
        try runRetouchCombine(src: src, smoothed: smoothed, mask: nil,
                              amount: 1, detail: 0, to: dst)
        let out = readPixels(dst)
        let skin = pixel(out, 8, 18)
        let wall = pixel(out, 56, 18)
        XCTAssertGreaterThan(simd_reduce_max(simd_abs(skin - Self.skinColor)), 0.05,
                             "skin must actually be smoothed")
        assertClose(wall, quantized(SIMD4(0.15, 0.25, 0.80, 1)), tolerance: 0.02,
                    "a blue wall is not skin and must be untouched")
    }

    /// The mask is opportunistic, but when it is there it narrows the gate to
    /// the subject: skin-coloured furniture behind someone stays sharp.
    func testRetouchCombineMaskNarrowsTheGateToTheSubject() throws {
        let src = try makeTexture(width: Self.width, height: Self.height,
                                  pixels: uniform(Self.skinColor))
        let smoothed = try makeTexture(width: Self.width, height: Self.height,
                                       pixels: uniform(SIMD4(0.2, 0.2, 0.2, 1)))
        let maskValues = (0..<(Self.width * Self.height)).map { i -> Float in
            (i % Self.width) < Self.width / 2 ? 1 : 0
        }
        let mask = try makeMaskTexture(width: Self.width, height: Self.height,
                                       values: maskValues)
        let dst = try makeOutputTexture(width: Self.width, height: Self.height)
        try runRetouchCombine(src: src, smoothed: smoothed, mask: mask,
                              amount: 1, detail: 0, to: dst)
        let out = readPixels(dst)
        XCTAssertLessThan(pixel(out, 8, 18).x, Self.skinColor.x - 0.1,
                          "the subject must be smoothed")
        assertClose(pixel(out, 56, 18), quantized(Self.skinColor), tolerance: 0.02,
                    "mask 0 must leave the frame exactly as it arrived")
    }
}
