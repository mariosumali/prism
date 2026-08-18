// Style.metal
// PRISMKernels — prism_style_*: the preset visual-effect catalogue (SPEC
// §5.4) — gadget-camera looks, distortions, and motion effects, one compute
// pass per effect. Contract shared by every kernel: read the base pixel
// exactly, style it, and land on the source when intensity is 0 — color
// looks mix toward the styled picture, warps scale their displacement,
// discrete remaps crossfade, motion effects scale their trails away.
// `time` animates only the effects that use it; `aspect` keeps radial and
// horizontal motion true on screen. The motion kernels additionally read a
// history texture holding the previous styled OUTPUT (StyleStage blits
// dst → history each frame); when hasHistory == 0 the history contents are
// undefined and the output must be exactly the source, which seeds the
// feedback.
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

// Ironbow gradient: black -> deep blue -> magenta -> orange -> yellow -> white.
static inline float3 thermal_ironbow(float t)
{
    const float3 black   = float3(0.00, 0.00, 0.00);
    const float3 blue    = float3(0.11, 0.00, 0.42);
    const float3 magenta = float3(0.66, 0.05, 0.55);
    const float3 orange  = float3(0.93, 0.38, 0.07);
    const float3 yellow  = float3(1.00, 0.84, 0.10);
    const float3 white   = float3(1.00, 1.00, 1.00);
    t = clamp(t, 0.0, 1.0) * 5.0;   // five equal segments across the six stops
    if (t < 1.0) { return mix(black,   blue,    t); }
    if (t < 2.0) { return mix(blue,    magenta, t - 1.0); }
    if (t < 3.0) { return mix(magenta, orange,  t - 2.0); }
    if (t < 4.0) { return mix(orange,  yellow,  t - 3.0); }
    return mix(yellow, white, t - 4.0);
}

// Photo Booth "Thermal Camera" — luma mapped through an ironbow heat palette.
kernel void prism_style_thermal(texture2d<float, access::sample> src    [[texture(0)]],
                                texture2d<float, access::write>  dst    [[texture(1)]],
                                constant PRISMStyleParams&       params [[buffer(0)]],
                                uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    float luma = dot(base.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 styled = thermal_ironbow(luma);

    dst.write(float4(clamp(mix(base.rgb, styled, clamp(params.intensity, 0.0, 1.0)), 0.0, 1.0), base.a), gid);
}

// Photo Booth "X-Ray" — inverted luma, slightly boosted contrast, faint blue-cyan cast.
kernel void prism_style_xray(texture2d<float, access::sample> src    [[texture(0)]],
                             texture2d<float, access::write>  dst    [[texture(1)]],
                             constant PRISMStyleParams&       params [[buffer(0)]],
                             uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    float luma = dot(base.rgb, float3(0.2126, 0.7152, 0.0722));
    float inverted = 1.0 - luma;
    // Slight contrast boost around the midpoint of the inverted ramp.
    float c = clamp((inverted - 0.5) * 1.25 + 0.5, 0.0, 1.0);
    // Shadows sink to a deep blue floor, highlights rise to cyan-tinged white.
    float3 styled = mix(float3(0.01, 0.05, 0.12), float3(0.85, 0.97, 1.00), c);

    dst.write(float4(clamp(mix(base.rgb, styled, clamp(params.intensity, 0.0, 1.0)), 0.0, 1.0), base.a), gid);
}

// Static per-frame white noise from the pixel coordinate alone (no time
// input). Hoskins hash12, not fract(sin(dot)): fast-math sin collapses at
// the ~1e5 dot products a 1080p/4K gid produces, and the grain would band.
static inline float nightVision_hash(uint2 p)
{
    float3 p3 = fract(float3(float2(p).xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Night-vision goggles — green mono with lifted gain, static sensor grain, circular scope vignette.
kernel void prism_style_nightVision(texture2d<float, access::sample> src    [[texture(0)]],
                                    texture2d<float, access::write>  dst    [[texture(1)]],
                                    constant PRISMStyleParams&       params [[buffer(0)]],
                                    uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float luma = dot(base.rgb, float3(0.2126, 0.7152, 0.0722));
    // Intensifier-tube gain: a sub-unity power lifts shadows and midtones hard.
    float gain = pow(luma, 0.65) * 1.15;
    float grain = (nightVision_hash(gid) - 0.5) * 0.10;
    // Aspect-corrected radial distance keeps the scope circular on screen.
    float d = length((uv - 0.5) * float2(params.aspect, 1.0));
    float scope = 1.0 - smoothstep(0.42, 0.62, d);
    float g = clamp(gain + grain, 0.0, 1.0) * scope;
    float3 styled = g * float3(0.15, 1.00, 0.30);

    dst.write(float4(clamp(mix(base.rgb, styled, clamp(params.intensity, 0.0, 1.0)), 0.0, 1.0), base.a), gid);
}

// Robust 2D → 0…1 hash (Hoskins hash12); stable for large pixel coords.
static inline float vhs_hash(float2 p)
{
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Worn VHS tape (animated): per-scanline jitter with occasional glitch bands,
// R/B chroma fringing, scanlines, tape static, desaturated lifted picture.
kernel void prism_style_vhs(texture2d<float, access::sample> src    [[texture(0)]],
                            texture2d<float, access::write>  dst    [[texture(1)]],
                            constant PRISMStyleParams&       params [[buffer(0)]],
                            uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float t = clamp(params.intensity, 0.0, 1.0);
    float frame = floor(params.time * 24.0);   // re-seed hashes at tape rate

    // Horizontal jitter on a fixed 240-line grid (resolution independent),
    // plus rare wider glitch bands. Displacements are fractions of frame
    // height; /aspect converts them to horizontal UV.
    float line = floor(uv.y * 240.0);
    float jitter = (vhs_hash(float2(line, frame)) - 0.5) * 0.004;
    float band = floor(uv.y * 14.0);
    float glitch = step(0.94, vhs_hash(float2(band + 41.0, frame)))
                 * (vhs_hash(float2(band, frame + 11.0)) - 0.5) * 0.09;
    float2 shift = float2((jitter + glitch) / params.aspect, 0.0) * t;

    // R and B sampled a few pixels apart around the jittered position.
    float2 fringe = float2(0.0035 / params.aspect, 0.0) * t;
    float3 col;
    col.r = src.sample(smp, uv + shift + fringe).r;
    col.g = src.sample(smp, uv + shift).g;
    col.b = src.sample(smp, uv + shift - fringe).b;

    // Tape grade: mild desaturation and lifted blacks.
    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    float3 styled = mix(col, float3(luma), 0.3);
    styled = styled * 0.9 + 0.06;

    // Scanlines on the same virtual 240-line grid.
    styled *= 1.0 - 0.14 * (0.5 + 0.5 * cos(uv.y * 240.0 * 6.28318531));

    // Animated static.
    float n = vhs_hash(float2(gid) + float2(frame * 7.0, frame * 3.0));
    styled += (n - 0.5) * 0.10;

    dst.write(float4(clamp(mix(col, styled, t), 0.0, 1.0), base.a), gid);
}

// Chunky 8-bit mosaic: square blocks up to 2.5% of frame height, filled from their centers.
kernel void prism_style_pixellate(texture2d<float, access::sample> src    [[texture(0)]],
                                  texture2d<float, access::write>  dst    [[texture(1)]],
                                  constant PRISMStyleParams&       params [[buffer(0)]],
                                  uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    // Nearest filtering: block interiors must be flat, not blended.
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 dstSize = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / dstSize;

    // The block-size ramp is the intensity scaling: 1px blocks reproduce the
    // source exactly, so no crossfade is needed.
    float k = clamp(params.intensity, 0.0, 1.0);
    float blockPx = mix(1.0, 0.025 * dstSize.y, k);

    // Same edge length on both axes in pixel space keeps blocks square on
    // screen; nearest-sample each block's center.
    float2 blockUV = (floor(uv * dstSize / blockPx) + 0.5) * blockPx / dstSize;
    float4 sampled = src.sample(smp, blockUV);
    dst.write(float4(clamp(sampled.rgb, 0.0, 1.0), base.a), gid);
}

// Photo Booth "Bulge" — magnifies a central disc (radius ~0.35), easing back to identity at the rim.
kernel void prism_style_bulge(texture2d<float, access::sample> src    [[texture(0)]],
                              texture2d<float, access::write>  dst    [[texture(1)]],
                              constant PRISMStyleParams&       params [[buffer(0)]],
                              uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    // Aspect-corrected delta from center so the bulge disc is circular on screen.
    float2 d = uv - 0.5;
    d.x *= params.aspect;
    float r = length(d);

    // Magnify = sample closer to center; falloff reaches identity at the rim.
    float w = 1.0 - smoothstep(0.0, 0.35, r);
    float scale = 1.0 - 0.6 * w;             // up to 2.5x magnification at center

    // mix keeps displacement proportional to intensity: t == 0 samples uv exactly.
    float2 warped = d * mix(1.0, scale, t);
    warped.x /= params.aspect;

    float4 s = src.sample(smp, warped + 0.5);
    dst.write(float4(clamp(s.rgb, 0.0, 1.0), base.a), gid);
}

// Photo Booth "Dent" — pinches the central disc (radius ~0.35) inward, easing back to identity at the rim.
kernel void prism_style_dent(texture2d<float, access::sample> src    [[texture(0)]],
                             texture2d<float, access::write>  dst    [[texture(1)]],
                             constant PRISMStyleParams&       params [[buffer(0)]],
                             uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    // Aspect-corrected delta from center so the dent disc is circular on screen.
    float2 d = uv - 0.5;
    d.x *= params.aspect;
    float r = length(d);

    // Shrink = sample farther from center; falloff reaches identity at the rim.
    float w = 1.0 - smoothstep(0.0, 0.35, r);
    float scale = 1.0 + 0.6 * w;

    // mix keeps displacement proportional to intensity: t == 0 samples uv exactly.
    float2 warped = d * mix(1.0, scale, t);
    warped.x /= params.aspect;

    float4 s = src.sample(smp, warped + 0.5);
    dst.write(float4(clamp(s.rgb, 0.0, 1.0), base.a), gid);
}

// Photo Booth "Twirl" — rotates around center, strongest at the middle and unwinding to zero by radius ~0.5.
kernel void prism_style_twirl(texture2d<float, access::sample> src    [[texture(0)]],
                              texture2d<float, access::write>  dst    [[texture(1)]],
                              constant PRISMStyleParams&       params [[buffer(0)]],
                              uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    // Aspect-corrected delta from center so the twirl is circular on screen.
    float2 d = uv - 0.5;
    d.x *= params.aspect;
    float r = length(d);

    // Squared falloff concentrates the twist at the center; zero by r = 0.5.
    float fall = 1.0 - smoothstep(0.0, 0.5, r);
    // Angle scales with intensity, so t == 0 rotates by nothing and samples uv exactly.
    float angle = t * 2.5 * fall * fall;

    float c = cos(angle);
    float s = sin(angle);
    float2 warped = float2(c * d.x - s * d.y, s * d.x + c * d.y);
    warped.x /= params.aspect;

    float4 tap = src.sample(smp, warped + 0.5);
    dst.write(float4(clamp(tap.rgb, 0.0, 1.0), base.a), gid);
}

// Photo Booth "Squeeze" — compresses the frame horizontally toward the vertical center line, strongest at mid-height.
kernel void prism_style_squeeze(texture2d<float, access::sample> src    [[texture(0)]],
                                texture2d<float, access::write>  dst    [[texture(1)]],
                                constant PRISMStyleParams&       params [[buffer(0)]],
                                uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    // Strongest at mid-height, easing to identity at the top and bottom edges.
    float wy = 1.0 - smoothstep(0.0, 0.5, abs(uv.y - 0.5));

    // Compress = sample farther from the vertical center line. The gain above 1
    // is scaled by intensity, so t == 0 samples uv exactly.
    float dx = uv.x - 0.5;
    float sampleX = 0.5 + dx * (1.0 + t * 0.6 * wy);

    float4 s = src.sample(smp, float2(sampleX, uv.y));
    dst.write(float4(clamp(s.rgb, 0.0, 1.0), base.a), gid);
}

// Photo Booth "Mirror": the right half becomes a mirror image of the left half.
kernel void prism_style_mirror(texture2d<float, access::sample> src    [[texture(0)]],
                               texture2d<float, access::write>  dst    [[texture(1)]],
                               constant PRISMStyleParams&       params [[buffer(0)]],
                               uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // Fold the right half onto the left: columns x and 1-x show the same source column.
    float2 mirroredUV = float2(min(uv.x, 1.0 - uv.x), uv.y);
    float3 remapped = src.sample(smp, mirroredUV).rgb;

    float k = clamp(params.intensity, 0.0, 1.0);
    dst.write(float4(clamp(mix(base.rgb, remapped, k), 0.0, 1.0), base.a), gid);
}

// Photo Booth "Light Tunnel": image intact inside a ring, surround smeared into radial streaks.
kernel void prism_style_lightTunnel(texture2d<float, access::sample> src    [[texture(0)]],
                                    texture2d<float, access::write>  dst    [[texture(1)]],
                                    constant PRISMStyleParams&       params [[buffer(0)]],
                                    uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // Center-relative coordinates with x scaled by aspect so the ring is circular
    // on screen; the radius is therefore a fraction of frame height.
    float2 p = (uv - 0.5) * float2(params.aspect, 1.0);
    float r = length(p);
    const float r0 = 0.25;

    // Target is the ring point along the same angle; identity inside the ring.
    // (r > r0 guarantees r > 0, so the division is safe.)
    float2 ringP = (r > r0) ? p * (r0 / r) : p;

    float k = clamp(params.intensity, 0.0, 1.0);
    float2 warpedP = mix(p, ringP, k);
    float2 warpedUV = warpedP / float2(params.aspect, 1.0) + 0.5;
    float4 warped = src.sample(smp, warpedUV);
    dst.write(float4(clamp(warped.rgb, 0.0, 1.0), base.a), gid);
}

// Photo Booth "Fish Eye" — full-frame barrel distortion: center magnified, straight lines bowing outward.
kernel void prism_style_fisheye(texture2d<float, access::sample> src    [[texture(0)]],
                                texture2d<float, access::write>  dst    [[texture(1)]],
                                constant PRISMStyleParams&       params [[buffer(0)]],
                                uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    // Aspect-corrected delta from center so the barrel is circular on screen.
    float2 d = uv - 0.5;
    d.x *= params.aspect;
    float r = length(d);

    // Normalize by the corner radius so rn == 1 at the frame corners.
    float rMax = 0.5 * length(float2(params.aspect, 1.0));
    float rn = r / rMax;

    // Barrel remap r' = r·(1 + k·rn²)/(1 + k): up to (1+k)x magnification at
    // the center, exactly identity at the corners so the frame stays filled.
    const float k = 1.2;
    float scale = (1.0 + k * rn * rn) / (1.0 + k);

    // mix keeps displacement proportional to intensity: t == 0 samples uv exactly.
    float2 warped = d * mix(1.0, scale, t);
    warped.x /= params.aspect;

    float4 s = src.sample(smp, warped + 0.5);
    dst.write(float4(clamp(s.rgb, 0.0, 1.0), base.a), gid);
}

// Photo Booth "Stretch": center-line horizontal stretch easing to identity at the edges.
kernel void prism_style_stretch(texture2d<float, access::sample> src    [[texture(0)]],
                                texture2d<float, access::write>  dst    [[texture(1)]],
                                constant PRISMStyleParams&       params [[buffer(0)]],
                                uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float dx = uv.x - 0.5;
    float t = min(2.0 * abs(dx), 1.0);   // 0 at the center line, 1 at the edges

    // Compress the sampling distance near the center (0.4 => 2.5x magnification),
    // smoothstep-easing to no change at the edges so the frame boundary stays put.
    float scale = mix(0.4, 1.0, t * t * (3.0 - 2.0 * t));

    float k = clamp(params.intensity, 0.0, 1.0);
    float2 warpedUV = float2(uv.x + k * dx * (scale - 1.0), uv.y);
    float4 warped = src.sample(smp, warpedUV);
    dst.write(float4(clamp(warped.rgb, 0.0, 1.0), base.a), gid);
}

// 6-fold kaleidoscope: one mirrored 60-degree wedge replicated around the center.
kernel void prism_style_kaleidoscope(texture2d<float, access::sample> src    [[texture(0)]],
                                     texture2d<float, access::write>  dst    [[texture(1)]],
                                     constant PRISMStyleParams&       params [[buffer(0)]],
                                     uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // Aspect-corrected polar coordinates so the wedges are circular on screen.
    float2 p = (uv - 0.5) * float2(params.aspect, 1.0);
    float r = length(p);

    // atan2(0,0) is undefined under fast math (NaN on Apple GPUs); the exact
    // center pixel exists whenever both dimensions are odd, so guard it.
    if (r < 1e-5) {
        dst.write(float4(clamp(base.rgb, 0.0, 1.0), base.a), gid);
        return;
    }

    float angle = atan2(p.y, p.x);

    const float wedge = M_PI_F / 3.0;   // 60 degrees

    // Positive modulo into a mirrored wedge pair, then reflect the second
    // wedge back onto the first so adjacent copies meet seamlessly.
    float m = angle - floor(angle / (2.0 * wedge)) * (2.0 * wedge);
    float folded = (m > wedge) ? (2.0 * wedge - m) : m;

    float2 foldedP = r * float2(cos(folded), sin(folded));
    float2 foldedUV = foldedP / float2(params.aspect, 1.0) + 0.5;
    float3 remapped = src.sample(smp, foldedUV).rgb;

    float k = clamp(params.intensity, 0.0, 1.0);
    dst.write(float4(clamp(mix(base.rgb, remapped, k), 0.0, 1.0), base.a), gid);
}

// Traveling ripple (animated): a sine wave rolling down the frame sways
// pixels sideways, with a lighter second-harmonic bob on the vertical axis.
kernel void prism_style_wave(texture2d<float, access::sample> src    [[texture(0)]],
                             texture2d<float, access::write>  dst    [[texture(1)]],
                             constant PRISMStyleParams&       params [[buffer(0)]],
                             uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    // Amplitudes are fractions of frame height; /aspect converts the sway to
    // horizontal UV so it covers the same on-screen distance as the bob.
    const float A = 0.012;
    float dx = A * sin(uv.y * 32.0 + params.time * 3.5) / params.aspect;
    // Second harmonic of the same traveling wave: doubled frequency and speed.
    float dy = 0.4 * A * sin(uv.y * 64.0 + params.time * 7.0);

    // Displacement scales with intensity: t == 0 samples uv exactly.
    float4 s = src.sample(smp, uv + float2(dx, dy) * t);
    dst.write(float4(clamp(s.rgb, 0.0, 1.0), base.a), gid);
}

// Refractive underwater wobble (animated): a slow two-frequency warp on both
// axes, a blue-green grade, and a faint caustic shimmer from the same field.
kernel void prism_style_underwater(texture2d<float, access::sample> src    [[texture(0)]],
                                   texture2d<float, access::write>  dst    [[texture(1)]],
                                   constant PRISMStyleParams&       params [[buffer(0)]],
                                   uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    // Two incommensurate spatial frequencies per axis at two slow speeds, so
    // the wobble drifts without a visible loop. Each field is -1…1; amplitude
    // is a fraction of frame height, with /aspect keeping the x wobble equal
    // on screen.
    const float A = 0.008;
    float wx = 0.5 * (sin(uv.y * 21.0 + params.time * 1.2) + cos(uv.y * 13.0 - params.time * 1.7));
    float wy = 0.5 * (cos(uv.x * 17.0 + params.time * 1.7) + sin(uv.x * 29.0 + params.time * 1.2));
    float2 wobble = float2(wx * A / params.aspect, wy * A);

    // Warp displacement scales with intensity: t == 0 samples uv exactly.
    float3 col = src.sample(smp, uv + wobble * t).rgb;

    // Watery grade toward a deep teal, weight scaling with intensity.
    float3 styled = mix(col, float3(0.10, 0.50, 0.55), 0.25 * t);

    // Faint caustic shimmer: brightness modulated by the same wobble field.
    styled *= 1.0 + 0.08 * (wx * wy) * t;

    dst.write(float4(clamp(styled, 0.0, 1.0), base.a), gid);
}

// Robust 2D → 0…1 hash (Hoskins hash12); stable for large coordinates.
static inline float glitch_hash(float2 p)
{
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Digital glitch (animated): at ~8 Hz a hash picks ~10% of 24 horizontal
// bands to shear sideways with an extra R/B split; idle bands pass through.
kernel void prism_style_glitch(texture2d<float, access::sample> src    [[texture(0)]],
                               texture2d<float, access::write>  dst    [[texture(1)]],
                               constant PRISMStyleParams&       params [[buffer(0)]],
                               uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    float step8 = floor(params.time * 8.0);   // re-pick the glitching bands at ~8 Hz
    float band = floor(uv.y * 24.0);

    // One hash gates the band (top 10% glitch), a second signs and sizes its
    // shift. Displacements are fractions of frame height; /aspect converts
    // them to horizontal UV.
    float gate = step(0.90, glitch_hash(float2(band, step8)));
    float amount = (glitch_hash(float2(band + 57.0, step8)) - 0.5) * 2.0;   // -1…1
    float2 shift = float2(gate * amount * 0.08 * t / params.aspect, 0.0);

    // Shifted bands pick up a small R/B split; zero when the band is idle,
    // so untouched bands reproduce the source exactly.
    float2 split = float2(gate * 0.004 * t / params.aspect, 0.0);
    float3 col;
    col.r = src.sample(smp, uv + shift + split).r;
    col.g = src.sample(smp, uv + shift).g;
    col.b = src.sample(smp, uv + shift - split).b;

    dst.write(float4(clamp(col, 0.0, 1.0), base.a), gid);
}

// Little-planet stereographic remap: the frame wraps into a circular planet —
// bottom of frame at the center, top of frame curling around the rim.
kernel void prism_style_tinyPlanet(texture2d<float, access::sample> src    [[texture(0)]],
                                   texture2d<float, access::write>  dst    [[texture(1)]],
                                   constant PRISMStyleParams&       params [[buffer(0)]],
                                   uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // Aspect-corrected polar coordinates so the planet is circular on screen.
    float2 p = (uv - 0.5) * float2(params.aspect, 1.0);
    float r = length(p);

    // atan2(0,0) is undefined under fast math (NaN on Apple GPUs); the exact
    // center pixel exists whenever both dimensions are odd, so guard it.
    if (r < 1e-5) {
        dst.write(float4(clamp(base.rgb, 0.0, 1.0), base.a), gid);
        return;
    }

    // Angle sweeps the source left-to-right once around the planet; measuring
    // against +y puts the atan2 discontinuity (the wrap seam) at the top.
    float srcX = atan2(p.x, p.y) / (2.0 * M_PI_F) + 0.5;

    // Stereographic radius curve: latitude 2·atan(r/R) runs 0 at the center
    // toward π far out, so the source's bottom row lands at the center and
    // its top row wraps the rim. R sets the planet's on-screen size.
    const float R = 0.35;
    float srcY = 1.0 - (2.0 / M_PI_F) * atan(r / R);

    float3 remapped = src.sample(smp, float2(srcX, srcY)).rgb;

    // Discrete remap: crossfade by intensity rather than scaling a displacement.
    float k = clamp(params.intensity, 0.0, 1.0);
    dst.write(float4(clamp(mix(base.rgb, remapped, k), 0.0, 1.0), base.a), gid);
}

// Chromatic aberration: R and B pulled apart along a mostly-horizontal axis
// with a slight radial lean, the split growing toward the frame edges.
kernel void prism_style_rgbSplit(texture2d<float, access::sample> src    [[texture(0)]],
                                 texture2d<float, access::write>  dst    [[texture(1)]],
                                 constant PRISMStyleParams&       params [[buffer(0)]],
                                 uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float t = clamp(params.intensity, 0.0, 1.0);

    // Aspect-corrected offset from center; its length grows the split, its
    // direction adds a small radial lean to the horizontal axis. The x term
    // stays below 1, so the direction never degenerates before normalize.
    float2 c = (uv - 0.5) * float2(params.aspect, 1.0);
    float r = length(c);
    float2 dir = normalize(float2(1.0, 0.0) + c * 0.6);

    // Magnitude is a fraction of frame height, scaled by intensity so t == 0
    // samples uv exactly; /aspect on x keeps the split length equal on screen.
    float mag = (0.005 + 0.006 * r) * t;
    float2 d = dir * mag / float2(params.aspect, 1.0);

    float3 col;
    col.r = src.sample(smp, uv + d).r;
    col.g = src.sample(smp, uv).g;
    col.b = src.sample(smp, uv - d).b;

    dst.write(float4(clamp(col, 0.0, 1.0), base.a), gid);
}

// Motion trails (temporal): the previous styled frame decays under the live
// picture, so anything bright that moves leaves a short ghost behind it.
kernel void prism_style_afterimage(texture2d<float, access::sample> src     [[texture(0)]],
                                   texture2d<float, access::sample> history [[texture(1)]],
                                   texture2d<float, access::write>  dst     [[texture(2)]],
                                   constant PRISMStyleParams&       params  [[buffer(0)]],
                                   uint2                            gid     [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // No history yet: its contents are undefined, so write the source exactly —
    // that seeds the dst -> history feedback for the next frame.
    if (params.hasHistory < 0.5) {
        dst.write(float4(clamp(base.rgb, 0.0, 1.0), base.a), gid);
        return;
    }

    float4 trail = history.sample(smp, uv);

    // Per-frame decay ~0.90 reads as ~0.3s ghosts at 30fps; max keeps the live
    // picture at least as bright as the fading trail, so only trails linger.
    float3 styled = max(base.rgb, trail.rgb * 0.90);

    dst.write(float4(clamp(mix(base.rgb, styled, clamp(params.intensity, 0.0, 1.0)), 0.0, 1.0), base.a), gid);
}

// Color-separated trails (temporal): each channel decays at its own rate, so
// moving edges smear into rainbow tails — red fades first, blue lingers.
kernel void prism_style_echo(texture2d<float, access::sample> src     [[texture(0)]],
                             texture2d<float, access::sample> history [[texture(1)]],
                             texture2d<float, access::write>  dst     [[texture(2)]],
                             constant PRISMStyleParams&       params  [[buffer(0)]],
                             uint2                            gid     [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // No history yet: its contents are undefined, so write the source exactly —
    // that seeds the dst -> history feedback for the next frame.
    if (params.hasHistory < 0.5) {
        dst.write(float4(clamp(base.rgb, 0.0, 1.0), base.a), gid);
        return;
    }

    float4 trail = history.sample(smp, uv);

    // Same max-blend shape as afterimage, but the decay is per channel
    // (R 0.84, G 0.90, B 0.96) so the tail's color drifts as it fades.
    float3 styled = max(base.rgb, trail.rgb * float3(0.84, 0.90, 0.96));

    dst.write(float4(clamp(mix(base.rgb, styled, clamp(params.intensity, 0.0, 1.0)), 0.0, 1.0), base.a), gid);
}

// Light painting (temporal): near-unity decay holds bright pixels for seconds,
// so a moving light paints a persistent streak across the frame.
kernel void prism_style_longExposure(texture2d<float, access::sample> src     [[texture(0)]],
                                     texture2d<float, access::sample> history [[texture(1)]],
                                     texture2d<float, access::write>  dst     [[texture(2)]],
                                     constant PRISMStyleParams&       params  [[buffer(0)]],
                                     uint2                            gid     [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // No history yet: its contents are undefined, so write the source exactly —
    // that seeds the dst -> history feedback for the next frame.
    if (params.hasHistory < 0.5) {
        dst.write(float4(clamp(base.rgb, 0.0, 1.0), base.a), gid);
        return;
    }

    float4 trail = history.sample(smp, uv);

    // Decay 0.995 per frame — highlights take on the order of seconds to fade.
    float3 styled = max(base.rgb, trail.rgb * 0.995);

    dst.write(float4(clamp(mix(base.rgb, styled, clamp(params.intensity, 0.0, 1.0)), 0.0, 1.0), base.a), gid);
}

// Frozen ghost (temporal, animated): a ~2 Hz beat reseeds a snapshot of you
// that hangs in the air, barely decaying, until the next beat.
kernel void prism_style_strobe(texture2d<float, access::sample> src     [[texture(0)]],
                               texture2d<float, access::sample> history [[texture(1)]],
                               texture2d<float, access::write>  dst     [[texture(2)]],
                               constant PRISMStyleParams&       params  [[buffer(0)]],
                               uint2                            gid     [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    float4 base = src.read(gid);

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    // No history yet: its contents are undefined, so write the source exactly —
    // that seeds the dst -> history feedback for the next frame.
    if (params.hasHistory < 0.5) {
        dst.write(float4(clamp(base.rgb, 0.0, 1.0), base.a), gid);
        return;
    }

    // Beat clock from time alone: pulse = 1 for the first ~8% of each 0.5s
    // cycle (a frame or two at 30fps). Pulse frames zero the ghost weight, so
    // the output is exactly base — which reseeds the snapshot through the
    // dst -> history feedback.
    float pulse = step(fract(params.time * 2.0), 0.08);

    float4 trail = history.sample(smp, uv);

    // Slow decay (0.985) keeps the snapshot readable across the whole beat.
    float3 styled = max(base.rgb, trail.rgb * 0.985);
    float k = clamp(params.intensity, 0.0, 1.0) * 0.85 * (1.0 - pulse);

    dst.write(float4(clamp(mix(base.rgb, styled, k), 0.0, 1.0), base.a), gid);
}
