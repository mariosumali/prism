// Layers.metal
// PRISMKernels — the two compositing kernels behind virtual backgrounds and
// green-screen layers:
//
//   prism_background_replace — swaps everything behind the person mask for a
//       still, a looping video, or a flat colour. Same mask as background
//       blur; the difference is only what fills the background.
//   prism_overlay — composites one placed, optionally keyed layer either in
//       front of the whole frame or behind the person. Chroma and luma keys
//       are computed in YCbCr so the key colour is arbitrary rather than
//       hard-coded green, and despill works for any hue.
//
// Both are single-pass and gid-guarded.
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

// MARK: - Colour helpers

static inline float prism_layers_luma(float3 rgb)
{
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}

/// Rec.601 chroma pair — the space keying has always been done in, because
/// it separates hue/saturation from brightness, so a shadow falling on the
/// screen does not read as a different colour.
static inline float2 prism_chroma(float3 rgb)
{
    return float2(dot(rgb, float3(-0.168736, -0.331264, 0.5)),
                  dot(rgb, float3(0.5, -0.418688, -0.081312)));
}

static inline float prism_luma601(float3 rgb)
{
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

static inline float3 prism_ycbcr_to_rgb(float y, float2 cbcr)
{
    return float3(y + 1.402 * cbcr.y,
                  y - 0.344136 * cbcr.x - 0.714136 * cbcr.y,
                  y + 1.772 * cbcr.x);
}

/// Hardens and feathers a segmentation mask. `contrast` ≥ 1 narrows the
/// transition around 0.5; `softness` widens it again symmetrically. Both at
/// their neutral values leave the mask exactly as Vision delivered it.
static inline float prism_shape_mask(float m, float contrast, float softness)
{
    float c = max(contrast, 1.0);
    float halfWidth = 0.5 / c;
    float hardened = smoothstep(0.5 - halfWidth, 0.5 + halfWidth, m);
    m = mix(m, hardened, saturate(c - 1.0));

    float s = saturate(softness);
    if (s > 0.0) {
        float w = mix(0.0, 0.45, s);
        m = smoothstep(0.5 - w - 1e-4, 0.5 + w + 1e-4, m);
    }
    return saturate(m);
}

// MARK: - Virtual background

// Replaces the background behind the person mask. `lightWrap` bleeds the new
// background into the subject's rim, which is the cheapest thing that stops
// a composite reading as a sticker: real subjects pick up the colour of what
// is behind them.
kernel void prism_background_replace(texture2d<float, access::sample> src    [[texture(0)]],
                                     texture2d<float, access::sample> bg     [[texture(1)]],
                                     texture2d<float, access::sample> mask   [[texture(2)]],
                                     texture2d<float, access::write>  dst    [[texture(3)]],
                                     constant PRISMBackgroundParams&  params [[buffer(0)]],
                                     uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float3 foreground = src.sample(smp, uv).rgb;

    float3 background;
    if (params.useTexture != 0) {
        float2 bgUV = (uv - params.bgOffset) / max(params.bgScale, float2(1e-5));
        background = bg.sample(smp, clamp(bgUV, 0.0, 1.0)).rgb;
    } else {
        background = params.flatColor.rgb;
    }

    float m = prism_shape_mask(mask.sample(smp, uv).r,
                               params.maskContrast, params.edgeSoftness);

    // Peaks at the mask edge (m = 0.5) and vanishes in both interiors.
    float rim = saturate(4.0 * m * (1.0 - m));
    foreground = mix(foreground, background, rim * saturate(params.lightWrap));

    dst.write(float4(mix(background, foreground, m), 1.0), gid);
}

// MARK: - Keyed overlay layer

kernel void prism_overlay(texture2d<float, access::sample> base   [[texture(0)]],
                          texture2d<float, access::sample> layer  [[texture(1)]],
                          texture2d<float, access::sample> mask   [[texture(2)]],
                          texture2d<float, access::write>  dst    [[texture(3)]],
                          constant PRISMOverlayParams&     params [[buffer(0)]],
                          uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float4 baseColor = base.sample(smp, uv);

    float3 mapped = params.uvTransform * float3(uv, 1.0);
    float2 layerUV = mapped.xy;
    if (any(layerUV < 0.0) || any(layerUV > 1.0)) {
        dst.write(float4(baseColor.rgb, 1.0), gid);   // outside the placed layer
        return;
    }

    float4 sampled = layer.sample(smp, layerUV);
    float3 rgb = sampled.rgb;
    float alpha = sampled.a;                          // honours PNG alpha as-is

    if (params.keyMode == 1) {
        // Chroma key: transparent where the colour sits close to the key hue.
        float2 c = prism_chroma(rgb);
        float2 k = prism_chroma(params.keyColor.rgb);
        float keyLen = length(k);
        if (keyLen > 1e-4) {
            float distance = length(c - k);
            float keyed = smoothstep(params.similarity,
                                     params.similarity + max(params.smoothness, 1e-4),
                                     distance);
            alpha *= keyed;

            // Despill: remove what is left of the key hue from the surviving
            // pixels, so a green screen stops tinting hair and shoulders.
            float spill = saturate(params.spill);
            if (spill > 0.0) {
                float2 axis = k / keyLen;
                float projection = dot(c, axis);
                if (projection > 0.0) {
                    c -= axis * projection * spill;
                    rgb = saturate(prism_ycbcr_to_rgb(prism_luma601(rgb), c));
                }
            }
        }
    } else if (params.keyMode == 2) {
        // Luma key: transparent in the dark end, opaque in the bright end.
        float low = min(params.lumaLow, params.lumaHigh - 1e-4);
        alpha *= smoothstep(low, params.lumaHigh, prism_layers_luma(rgb));
    }

    alpha *= saturate(params.opacity);

    if (params.placement == 1) {
        // Behind the person: the subject occludes the layer.
        alpha *= 1.0 - saturate(mask.sample(smp, uv).r);
    }

    dst.write(float4(mix(baseColor.rgb, rgb, saturate(alpha)), 1.0), gid);
}
