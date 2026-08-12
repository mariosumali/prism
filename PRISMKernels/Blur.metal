// Blur.metal
// PRISMKernels — prism_blur: one direction of a separable Gaussian.
// Sigma is radius/2; the tap count adapts to sigma and is clamped to 31
// total taps; weights are computed in-shader and normalized (SPEC §5.4).
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

kernel void prism_blur(texture2d<float, access::sample> src    [[texture(0)]],
                       texture2d<float, access::write>  dst    [[texture(1)]],
                       constant PRISMBlurParams&        params [[buffer(0)]],
                       uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float sigma = max(params.radius, 0.0) * 0.5;
    if (sigma < 1e-3) {
        dst.write(src.sample(smp, uv), gid);
        return;
    }

    // ±3σ support, clamped so total taps (2·halfTaps + 1) never exceed 31.
    int halfTaps = clamp(int(ceil(sigma * 3.0)), 1, 15);

    float2 texelStep = params.direction / float2(src.get_width(), src.get_height());
    float invTwoSigmaSq = 1.0 / (2.0 * sigma * sigma);

    float4 acc = 0.0;
    float weightSum = 0.0;
    for (int i = -halfTaps; i <= halfTaps; ++i) {
        float w = exp(-float(i * i) * invTwoSigmaSq);
        acc += src.sample(smp, uv + float(i) * texelStep) * w;
        weightSum += w;
    }

    dst.write(acc / weightSum, gid);
}
