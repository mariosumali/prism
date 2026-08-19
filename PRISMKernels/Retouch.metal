// Retouch.metal
// PRISMKernels — the two passes behind skin retouch (§5.22):
//
//   prism_retouch_blur — one direction of a separable *bilateral* blur.
//       Weighting by luma distance as well as by spatial distance is the
//       whole difference from prism_blur: eyelashes, nostrils and the lip
//       line are luma cliffs, and a plain Gaussian melts them, which is
//       precisely what makes a smoothed face read as a plastic mask.
//
//   prism_retouch_combine — mixes that smoothed image back over the source
//       under a skin gate, then hands the fine texture back. Everything the
//       blur removed is `source − smoothed`; returning `detail` of it is
//       frequency separation, so pores and stubble survive a heavy smooth.
//
// Both are gid-guarded. The blur runs at half resolution and the combine at
// full, so `smoothed` is sampled with a linear sampler and upscales for free.
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

static inline float prism_retouch_luma(float3 rgb)
{
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

/// Membership of the Rec.601 chroma region skin occupies, feathered at its
/// boundary so the gate never draws a visible edge across a cheek.
///
/// Chroma rather than luma on purpose: across skin tones melanin moves
/// brightness far more than it moves hue, so a Cb/Cr region covers the range
/// of human skin where a luma threshold would quietly work for some people
/// and not others. The luma terms below only reject the extremes — the
/// smoothing has nothing to find in a crushed shadow or a blown highlight,
/// and dark hair against skin is the edge this stage most needs to keep.
static inline float prism_skin_gate(float3 rgb)
{
    float y = prism_retouch_luma(rgb);
    float2 cbcr = float2(dot(rgb, float3(-0.168736, -0.331264, 0.5)),
                         dot(rgb, float3(0.5, -0.418688, -0.081312)));

    // Centre and radii of the classic Cb/Cr skin locus, normalised to ±0.5.
    float2 centered = (cbcr - float2(-0.100, 0.100)) / float2(0.105, 0.095);
    float distance = length(centered);
    float chroma = 1.0 - smoothstep(0.75, 1.20, distance);

    float shadows = smoothstep(0.05, 0.18, y);
    float highlights = 1.0 - smoothstep(0.93, 1.00, y);
    return saturate(chroma * shadows * highlights);
}

kernel void prism_retouch_blur(texture2d<float, access::sample> src    [[texture(0)]],
                               texture2d<float, access::write>  dst    [[texture(1)]],
                               constant PRISMRetouchBlurParams& params [[buffer(0)]],
                               uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float4 center = src.sample(smp, uv);

    float sigma = max(params.radius, 0.0) * 0.5;
    if (sigma < 1e-3) {
        dst.write(center, gid);
        return;
    }

    // ±3σ support, capped at 21 total taps rather than prism_blur's 31: this
    // pass runs twice a frame and is nearly the whole of the stage's §3.4
    // budget, and a bilateral tap costs a luma difference on top of a sample.
    int halfTaps = clamp(int(ceil(sigma * 3.0)), 1, 10);

    float2 texelStep = params.direction / float2(src.get_width(), src.get_height());
    float invTwoSigmaSq = 1.0 / (2.0 * sigma * sigma);
    float rangeSigma = max(params.rangeSigma, 1e-3);
    float invTwoRangeSq = 1.0 / (2.0 * rangeSigma * rangeSigma);
    float centerLuma = prism_retouch_luma(center.rgb);

    float4 acc = 0.0;
    float weightSum = 0.0;
    for (int i = -halfTaps; i <= halfTaps; ++i) {
        float4 s = src.sample(smp, uv + float(i) * texelStep);
        float dl = prism_retouch_luma(s.rgb) - centerLuma;
        // The centre tap weighs exactly 1, so the sum can never reach zero
        // however far the neighbourhood is from the centre in colour.
        float w = exp(-float(i * i) * invTwoSigmaSq - dl * dl * invTwoRangeSq);
        acc += s * w;
        weightSum += w;
    }

    dst.write(acc / weightSum, gid);
}

kernel void prism_retouch_combine(texture2d<float, access::sample> src    [[texture(0)]],
                                  texture2d<float, access::sample> smoothed [[texture(1)]],
                                  texture2d<float, access::sample> mask   [[texture(2)]],
                                  texture2d<float, access::write>  dst    [[texture(3)]],
                                  constant PRISMRetouchParams&     params [[buffer(0)]],
                                  uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float4 source = src.sample(smp, uv);
    float3 blurred = smoothed.sample(smp, uv).rgb;

    float gate = prism_skin_gate(source.rgb);
    if (params.useMask != 0) {
        gate *= saturate(mask.sample(smp, uv).r);
    }

    // What the blur took out. Handing `detail` of it back is what keeps the
    // result a smoothed face rather than a rendered one.
    float3 residue = source.rgb - blurred;
    float3 retouched = blurred + residue * saturate(params.detail);

    float amount = saturate(params.amount) * gate;
    dst.write(float4(mix(source.rgb, retouched, amount), source.a), gid);
}
