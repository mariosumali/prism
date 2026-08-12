// Composite.metal
// PRISMKernels — utility kernels: prism_copy, prism_composite (person mask
// over blurred background), prism_output_fit (letterbox/fill into the
// negotiated format), prism_crossfade, and prism_sharpness (Laplacian
// variance for FrameRing sharpest-frame scoring) (SPEC §5.2–§5.4).
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

static inline float prism_luma709(float3 rgb)
{
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}

// Straight copy (resamples if dimensions differ).
kernel void prism_copy(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write>  dst [[texture(1)]],
                       uint2                            gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(src.sample(smp, uv), gid);
}

// Sharp person over blurred background, selected by a single-channel mask
// (person = 1). maskContrast ≥ 1 hardens the mask edge via a smoothstep
// window around 0.5; 1 leaves the mask exactly as delivered.
kernel void prism_composite(texture2d<float, access::sample> sharp   [[texture(0)]],
                            texture2d<float, access::sample> blurred [[texture(1)]],
                            texture2d<float, access::sample> mask    [[texture(2)]],
                            texture2d<float, access::write>  dst     [[texture(3)]],
                            constant PRISMCompositeParams&   params  [[buffer(0)]],
                            uint2                            gid     [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float4 fg = sharp.sample(smp, uv);
    float4 bg = blurred.sample(smp, uv);
    float m = mask.sample(smp, uv).r;

    float contrast = max(params.maskContrast, 1.0);
    float halfWidth = 0.5 / contrast;
    float hardened = smoothstep(0.5 - halfWidth, 0.5 + halfWidth, m);
    // Blend so contrast == 1 passes the mask through untouched and the
    // hardening ramps in continuously above it.
    m = mix(m, hardened, saturate(contrast - 1.0));

    dst.write(float4(mix(bg.rgb, fg.rgb, m), 1.0), gid);
}

// Scale/offset content into the negotiated output format. Letterbox bars
// are opaque black; fill mode clamps instead of matting (content computed
// CPU-side always covers the output in fill mode).
kernel void prism_output_fit(texture2d<float, access::sample> src    [[texture(0)]],
                             texture2d<float, access::write>  dst    [[texture(1)]],
                             constant PRISMFitParams&         params [[buffer(0)]],
                             uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 outUV = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float2 contentUV = (outUV - params.offset) / params.scale;

    bool inside = all(contentUV >= 0.0) && all(contentUV <= 1.0);
    if (params.fillMode == 0 && !inside) {
        dst.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    float4 pixel = src.sample(smp, clamp(contentUV, 0.0, 1.0));
    dst.write(float4(pixel.rgb, 1.0), gid);
}

// Linear crossfade between two sources: 0 = A, 1 = B.
kernel void prism_crossfade(texture2d<float, access::sample> texA   [[texture(0)]],
                            texture2d<float, access::sample> texB   [[texture(1)]],
                            texture2d<float, access::write>  dst    [[texture(2)]],
                            constant PRISMCrossfadeParams&   params [[buffer(0)]],
                            uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float4 a = texA.sample(smp, uv);
    float4 b = texB.sample(smp, uv);
    dst.write(mix(a, b, saturate(params.mix)), gid);
}

// Sharpness score for FrameRing (§5.2): variance of a 3×3 Laplacian of
// Rec.709 luma over a 128×72 downsample of src. Dispatched as exactly ONE
// threadgroup of 256 threads; each thread strides the sample grid, the
// partial sums are tree-reduced in threadgroup memory, and thread 0 writes
// the variance into result[slot].
kernel void prism_sharpness(texture2d<float, access::sample> src    [[texture(0)]],
                            device float*                    result [[buffer(0)]],
                            constant PRISMSharpnessParams&   params [[buffer(1)]],
                            uint                             tid    [[thread_index_in_threadgroup]])
{
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    const uint gridW = 128;
    const uint gridH = 72;
    const uint gridCount = gridW * gridH;      // 9216 samples
    const uint threads = 256;
    const float2 invGrid = float2(1.0 / float(gridW), 1.0 / float(gridH));

    threadgroup float tgSum[256];
    threadgroup float tgSumSq[256];

    float localSum = 0.0;
    float localSumSq = 0.0;

    for (uint i = tid; i < gridCount; i += threads) {
        uint gx = i % gridW;
        uint gy = i / gridW;
        float2 uv = (float2(gx, gy) + 0.5) * invGrid;

        float center = prism_luma709(src.sample(smp, uv).rgb);
        float neighbors = 0.0;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                if (dx == 0 && dy == 0) {
                    continue;
                }
                // clamp_to_edge covers the grid border.
                float2 nuv = uv + float2(dx, dy) * invGrid;
                neighbors += prism_luma709(src.sample(smp, nuv).rgb);
            }
        }
        float laplacian = 8.0 * center - neighbors;
        localSum += laplacian;
        localSumSq += laplacian * laplacian;
    }

    tgSum[tid] = localSum;
    tgSumSq[tid] = localSumSq;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = threads / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            tgSum[tid] += tgSum[tid + stride];
            tgSumSq[tid] += tgSumSq[tid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        float n = float(gridCount);
        float mean = tgSum[0] / n;
        float variance = max(tgSumSq[0] / n - mean * mean, 0.0);
        result[params.slot] = variance;
    }
}

// Luma thumbnail for the replay ring's away-loop search: writes a
// width×height grid of Rec.709 luma into result[slot·width·height …].
// Dispatched over the thumbnail grid itself (32×18 = 576 threads), not over
// the source — linear filtering does the box-averaging for free.
kernel void prism_thumbnail(texture2d<float, access::sample> src    [[texture(0)]],
                            device float*                    result [[buffer(0)]],
                            constant PRISMThumbnailParams&   params [[buffer(1)]],
                            uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(params.width, params.height);
    uint index = params.slot * params.width * params.height + gid.y * params.width + gid.x;
    result[index] = prism_luma709(src.sample(smp, uv).rgb);
}
