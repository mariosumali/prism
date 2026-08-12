// Gaze.metal
// PRISMKernels — eye-contact correction: a localised, mass-preserving warp
// that translates each iris toward the lens while pinning the eyelids.
//
// The deformation field per eye is the product of two falloffs:
//
//   wIris — 1 across the whole iris disc, decaying outward. Inside the iris
//           the warp is a rigid translation, so the pupil and limbal ring
//           keep their shape instead of smearing into an oval.
//   wLid  — 1 at the centre of the eye opening, 0 at its boundary. This is
//           what keeps eyelids, lashes and skin exactly where they were;
//           without it the warp drags the lid and the face reads as melting.
//
// Everything between the iris edge and the lid boundary is sclera, and it
// takes up the difference by stretching. That is the classic warp-based
// approach to gaze redirection, and it is the honest one to run in a
// real-time budget: it moves where the eye is looking without inventing
// pixels. It holds up for the ±10° of correction a webcam-above-display
// setup needs and degrades gracefully (rather than uncannily) beyond it,
// which is why GazeStage clamps the shift rather than extrapolating.
//
// Licensed under the Apache License, Version 2.0.

#include <metal_stdlib>
#include "KernelTypes.h"

using namespace metal;

// Displacement contributed by one eye at `uv`, in UV units. Zero outside the
// eye opening, so the two eyes never interact and the rest of the frame is
// an exact copy.
static inline float2 prism_gaze_offset(constant PRISMGazeEye& eye,
                                       float2 uv,
                                       float feather)
{
    if (eye.valid < 0.5) {
        return float2(0.0);
    }

    float2 lidRadii = max(eye.lidRadii, float2(1e-5));
    float dl = length((uv - eye.lidCenter) / lidRadii);
    if (dl >= 1.0) {
        return float2(0.0);              // outside the eye opening: pinned
    }

    float2 irisRadii = max(eye.irisRadii, float2(1e-5));
    float di = length((uv - eye.irisCenter) / irisRadii);

    // Rigid across the iris (di ≤ 1), released over the sclera.
    float wIris = 1.0 - smoothstep(1.0, 1.0 + feather * 3.0, di);
    // Pinned at the lid boundary.
    float wLid = 1.0 - smoothstep(1.0 - feather, 1.0, dl);

    return eye.shift * (wIris * wLid);
}

kernel void prism_gaze(texture2d<float, access::sample> src    [[texture(0)]],
                       texture2d<float, access::write>  dst    [[texture(1)]],
                       constant PRISMGazeParams&        params [[buffer(0)]],
                       uint2                            gid    [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float feather = clamp(params.feather, 0.01, 1.0);
    float2 offset = prism_gaze_offset(params.left, uv, feather)
                  + prism_gaze_offset(params.right, uv, feather);

    // Inverse warp: to move the iris by +shift, sample from −shift.
    float4 pixel = src.sample(smp, uv - offset);
    dst.write(float4(pixel.rgb, 1.0), gid);
}
