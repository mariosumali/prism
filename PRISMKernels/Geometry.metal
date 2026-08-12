// Geometry.metal
// PRISMKernels — prism_geometry: applies the composed 3×3 output-UV →
// input-UV transform (zoom, pan, rotation, orientation, mirror, crop) in one
// pass. Bilinear below 2× zoom, separable Lanczos-2 (4 taps per axis,
// 16 total) at or above it. Out-of-range UV produces opaque black (SPEC §5.4).
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

// Lanczos-2 window: sinc(x) * sinc(x/2) for |x| < 2, else 0.
static inline float prism_lanczos2(float x)
{
    x = abs(x);
    if (x < 1e-5) {
        return 1.0;
    }
    if (x >= 2.0) {
        return 0.0;
    }
    float px = M_PI_F * x;
    // (sin(px)/px) * (sin(px/2)/(px/2)) == 2·sin(px)·sin(px/2) / px²
    return 2.0 * sin(px) * sin(px * 0.5) / (px * px);
}

kernel void prism_geometry(texture2d<float, access::sample> src    [[texture(0)]],
                           texture2d<float, access::write>  dst    [[texture(1)]],
                           constant PRISMGeometryParams&    params [[buffer(0)]],
                           uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float2 outUV = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // Bottom row of uvTransform is (0 0 1), so no perspective divide.
    float3 mapped = params.uvTransform * float3(outUV, 1.0);
    float2 inUV = mapped.xy;

    if (any(inUV < 0.0) || any(inUV > 1.0)) {
        dst.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    if (params.useLanczos == 0) {
        // Bilinear.
        constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
        dst.write(src.sample(smp, inUV), gid);
        return;
    }

    // Separable-weight Lanczos-2: 4 taps per axis, 16 texel reads.
    float2 srcSize = float2(src.get_width(), src.get_height());
    float2 pos = inUV * srcSize - 0.5;
    float2 base = floor(pos);
    float2 frac = pos - base;

    float wx[4];
    float wy[4];
    float sumX = 0.0;
    float sumY = 0.0;
    for (int i = 0; i < 4; ++i) {
        wx[i] = prism_lanczos2(frac.x - float(i - 1));
        wy[i] = prism_lanczos2(frac.y - float(i - 1));
        sumX += wx[i];
        sumY += wy[i];
    }

    int2 baseCoord = int2(base);
    int2 maxCoord = int2(srcSize) - 1;
    float4 acc = 0.0;
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            int2 coord = clamp(baseCoord + int2(i - 1, j - 1), int2(0), maxCoord);
            acc += src.read(uint2(coord)) * (wx[i] * wy[j]);
        }
    }
    acc /= (sumX * sumY);

    // Lanczos lobes can over/undershoot; clamp before the unorm write.
    dst.write(clamp(acc, 0.0, 1.0), gid);
}
