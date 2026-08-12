// Adjust.metal
// PRISMKernels — prism_adjust: exposure, contrast, saturation, temperature,
// and vignette in a single compute pass (SPEC §5.4).
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

kernel void prism_adjust(texture2d<float, access::sample> src    [[texture(0)]],
                         texture2d<float, access::write>  dst    [[texture(1)]],
                         constant PRISMAdjustParams&      params [[buffer(0)]],
                         uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float4 srcPixel = src.sample(smp, uv);
    float3 rgb = srcPixel.rgb;

    // Exposure — EV applied as a power-of-two gain.
    rgb *= exp2(params.exposureEV);

    // Contrast — pivot at 0.5 in (linear-ish) sRGB; 1 is neutral.
    rgb = (rgb - 0.5) * params.contrast + 0.5;

    // Saturation — mix toward Rec.709 luma; 1 is neutral.
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, params.saturation);

    // Temperature — opposing R/B gain tilt, ±10% gain at the ±100 extremes.
    float tilt = params.temperature * (0.1 / 100.0);
    rgb.r *= 1.0 + tilt;
    rgb.b *= 1.0 - tilt;

    // Vignette — smooth radial falloff; distance normalized so the frame
    // corners sit at 1.0 regardless of aspect ratio.
    float d = length(uv - 0.5) * 1.41421356;
    float falloff = smoothstep(0.3, 1.0, d);
    rgb *= 1.0 - params.vignette * falloff;

    dst.write(float4(clamp(rgb, 0.0, 1.0), srcPixel.a), gid);
}
