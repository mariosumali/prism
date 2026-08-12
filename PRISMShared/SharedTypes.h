// SharedTypes.h
// PRISMShared
//
// Shared-memory contract between PRISM.app (producer) and the PRISM
// AudioServerPlugIn hosted in coreaudiod (consumer). This header is compiled
// into both components and must stay in lockstep; bump PRISM_SHM_NAME's
// version suffix on any layout change.
//
// Licensed under the Apache License, Version 2.0.

#ifndef PRISM_SHARED_TYPES_H
#define PRISM_SHARED_TYPES_H

#include <stdatomic.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PRISM_SHM_NAME       "/horse.prism.audio.v1"
#define PRISM_RING_CAPACITY  32768        // frames, power of two
#define PRISM_CHANNELS       2
#define PRISM_SAMPLE_RATE    48000.0

// Producer heartbeat older than this (in nanoseconds) means the app is gone
// and the plug-in must emit silence.
#define PRISM_HEARTBEAT_TIMEOUT_NS  500000000ull   // 500ms

// Frames are stored interleaved (L R L R …) in `data`. The plug-in
// de-interleaves into the non-interleaved AudioBufferList it vends.
typedef struct {
    _Atomic uint64_t writeIndex;          // monotonic, frames
    _Atomic uint64_t readIndex;           // monotonic, frames
    _Atomic uint64_t producerHeartbeat;   // mach_absolute_time of last write
    _Atomic uint32_t underrunCount;
    _Atomic uint32_t overrunCount;
    _Atomic uint32_t producerAlive;       // 1 = app running
    uint32_t         _pad;
    float            data[PRISM_RING_CAPACITY * PRISM_CHANNELS];
} PRISMRingBuffer;

#ifdef __cplusplus
}
#endif

#endif /* PRISM_SHARED_TYPES_H */
