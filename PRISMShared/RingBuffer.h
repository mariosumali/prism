// RingBuffer.h
// PRISMShared
//
// Lock-free single-producer/single-consumer ring over POSIX shared memory.
// Producer: PRISM.app. Consumer: the PRISM AudioServerPlugIn inside
// coreaudiod. Every function here is wait-free and safe to call from a
// real-time IO thread: no locks, no allocation, no logging, no Objective-C.
//
// Licensed under the Apache License, Version 2.0.

#ifndef PRISM_RING_BUFFER_H
#define PRISM_RING_BUFFER_H

#include "SharedTypes.h"
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Mapping (NOT real-time safe; call from setup code only) ---------------

// Creates (or adopts) the shared region and returns a mapped pointer.
// Marks producerAlive = 1. Returns NULL on failure.
PRISMRingBuffer *PRISMRingBufferCreateProducer(void);

// Opens an existing region read-write (the consumer advances readIndex).
// If the region does not exist yet it is created zero-filled so the plug-in
// can come up before the app. Returns NULL on failure.
PRISMRingBuffer *PRISMRingBufferOpenConsumer(void);

// Same, against an arbitrary POSIX shared-memory name. The pair above are
// these with PRISM_SHM_NAME bound.
//
// Tests must use these with a name of their own. The live region is a
// singleton keyed by name, so a suite that opens PRISM_SHM_NAME shares — and
// its teardown shm_unlink()s — the ring belonging to any PRISM.app running on
// the same machine: the app writes real audio into the buffer mid-assertion
// and then loses its region. Both halves of that are silent.
PRISMRingBuffer *PRISMRingBufferCreateProducerNamed(const char *name);
PRISMRingBuffer *PRISMRingBufferOpenConsumerNamed(const char *name);

// Unmaps. Producer variant clears producerAlive first.
void PRISMRingBufferCloseProducer(PRISMRingBuffer *rb);
void PRISMRingBufferCloseConsumer(PRISMRingBuffer *rb);

// --- Real-time-safe operations --------------------------------------------

// Producer: append `frameCount` interleaved stereo frames. On overrun the
// oldest frames are dropped (readIndex advanced) and overrunCount bumped.
// Also stamps producerHeartbeat and producerAlive. Never blocks.
void PRISMRingBufferWrite(PRISMRingBuffer *rb,
                          const float *interleaved,
                          uint32_t frameCount);

// Consumer: copy `frameCount` interleaved frames into `outInterleaved`.
// Missing frames (underrun) are zero-filled and underrunCount bumped.
// Returns the number of real (non-silence) frames delivered. Never blocks.
uint32_t PRISMRingBufferRead(PRISMRingBuffer *rb,
                             float *outInterleaved,
                             uint32_t frameCount);

// Consumer: true when the producer is marked alive and its heartbeat is
// younger than PRISM_HEARTBEAT_TIMEOUT_NS. `nowMach` is mach_absolute_time().
bool PRISMRingBufferProducerIsAlive(const PRISMRingBuffer *rb, uint64_t nowMach);

// Frames currently readable (writeIndex - readIndex).
uint64_t PRISMRingBufferFillLevel(const PRISMRingBuffer *rb);

// --- Counters and liveness state ------------------------------------------

// Swift's C importer drops `_Atomic` struct members, so the fields below are
// unreachable from Swift as `rb.pointee.underrunCount` and must be read
// through these shims — never by hardcoded byte offset, which no compiler
// checks. All are wait-free and safe to call from an IO thread.
uint32_t PRISMRingBufferUnderrunCount(const PRISMRingBuffer *rb);
uint32_t PRISMRingBufferOverrunCount(const PRISMRingBuffer *rb);
uint64_t PRISMRingBufferProducerHeartbeat(const PRISMRingBuffer *rb);

// Fault injection for tests: force the producer's liveness state so a consumer
// can be exercised against a stalled or departed producer. Production code
// marks liveness through Write and CloseProducer, never through these.
void PRISMRingBufferSetProducerHeartbeat(PRISMRingBuffer *rb, uint64_t machTime);
void PRISMRingBufferSetProducerAlive(PRISMRingBuffer *rb, bool alive);

#ifdef __cplusplus
}
#endif

#endif /* PRISM_RING_BUFFER_H */
