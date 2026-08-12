// LUT.metal
// PRISMKernels — prism_lut: trilinear sample of a 3D color-cube texture,
// mixed with the source by strength (SPEC §5.4).
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

kernel void prism_lut(texture2d<float, access::sample> src    [[texture(0)]],
                      texture2d<float, access::write>  dst    [[texture(1)]],
                      texture3d<float, access::sample> lut    [[texture(2)]],
                      constant PRISMLUTParams&         params [[buffer(0)]],
                      uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float4 srcPixel = src.sample(smp, uv);

    // Map [0,1] color onto lattice-point centers: the first and last texels
    // of an N-point cube sit at 0.5/N and (N-0.5)/N in normalized coords.
    float n = float(lut.get_width());
    float3 cube = clamp(srcPixel.rgb, 0.0, 1.0) * ((n - 1.0) / n) + (0.5 / n);
    float3 graded = lut.sample(smp, cube).rgb;

    float strength = clamp(params.strength, 0.0, 1.0);
    float3 outRGB = mix(srcPixel.rgb, graded, strength);

    dst.write(float4(outRGB, srcPixel.a), gid);
}
