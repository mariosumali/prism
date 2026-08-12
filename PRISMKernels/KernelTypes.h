// KernelTypes.h
// PRISMKernels
//
// Parameter structs shared between Swift (via the bridging header) and the
// Metal kernels. Layouts must match MSL alignment rules exactly — keep every
// struct 16-byte friendly and avoid bool/packed types.
//
// Licensed under the Apache License, Version 2.0.

#ifndef PRISM_KERNEL_TYPES_H
#define PRISM_KERNEL_TYPES_H

#include <simd/simd.h>

// Adjust.metal — one pass (§5.4).
typedef struct {
    float exposureEV;     // −2…+2
    float contrast;       // 0…2, 1 = neutral
    float saturation;     // 0…2, 1 = neutral
    float temperature;    // −100…+100, 0 = neutral
    float vignette;       // 0…1
    float _pad0;
    float _pad1;
    float _pad2;
} PRISMAdjustParams;

// LUT.metal — 3D texture trilinear sample, blended by strength.
typedef struct {
    float strength;       // 0…1
    float _pad0;
    float _pad1;
    float _pad2;
} PRISMLUTParams;

// Geometry.metal — zoom/pan/rotation/orientation/mirror composed into one
// inverse 3×3 matrix mapping output UV → input UV (§5.4).
typedef struct {
    simd_float3x3 uvTransform;   // output UV → input UV
    unsigned int useLanczos;     // 1 at zoom ≥ 2× (§5.4)
    unsigned int _pad0;
    unsigned int _pad1;
    unsigned int _pad2;
} PRISMGeometryParams;

// Blur.metal — separable Gaussian, one direction per pass.
typedef struct {
    simd_float2 direction;       // (1,0) horizontal pass, (0,1) vertical
    float radius;                // pixels at full res
    float _pad0;
} PRISMBlurParams;

// Composite.metal — mix sharp person over blurred background by mask.
typedef struct {
    float maskContrast;          // edge hardening, 1 = as delivered
    float _pad0;
    float _pad1;
    float _pad2;
} PRISMCompositeParams;

// Composite.metal / output fit — scale + letterbox into negotiated format.
typedef struct {
    simd_float2 scale;           // content scale within output, ≤ 1
    simd_float2 offset;          // top-left of content in output UV
    unsigned int fillMode;       // 0 = letterbox, 1 = fill (clips), never stretch
    unsigned int _pad0;
    unsigned int _pad1;
    unsigned int _pad2;
} PRISMFitParams;

// Composite.metal — sharpness: Laplacian variance of a 128×72 downsample,
// reduced in one threadgroup, one float out per frame slot (§5.2).
typedef struct {
    unsigned int slot;           // FrameRing slot to write the score into
    unsigned int _pad0;
    unsigned int _pad1;
    unsigned int _pad2;
} PRISMSharpnessParams;

// Composite.metal — 200ms crossfade between two sources (§5.3, §5.5).
typedef struct {
    float mix;                   // 0 = A, 1 = B
    float _pad0;
    float _pad1;
    float _pad2;
} PRISMCrossfadeParams;

#endif /* PRISM_KERNEL_TYPES_H */
