// RingBuffer.c
// PRISMShared
//
// Licensed under the Apache License, Version 2.0.

#include "RingBuffer.h"

#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// mach_absolute_time ticks are not nanoseconds on Apple Silicon; cache the
// timebase once. mach_timebase_info is async-signal-safe and cheap, but we
// still keep it out of the IO path.
static uint64_t prism_ns_to_mach(uint64_t ns) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) {
        mach_timebase_info(&tb);
    }
    // ns → ticks: ticks = ns * denom / numer
    return ns * tb.denom / tb.numer;
}

static PRISMRingBuffer *prism_map(const char *name, bool create) {
    int flags = O_RDWR | (create ? O_CREAT : 0);
    int fd = shm_open(name, flags, 0666);
    if (fd < 0 && !create) {
        // Consumer path: create zero-filled so the plug-in can precede the app.
        fd = shm_open(name, O_RDWR | O_CREAT, 0666);
    }
    if (fd < 0) {
        return NULL;
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return NULL;
    }
    if ((size_t)st.st_size < sizeof(PRISMRingBuffer)) {
        if (ftruncate(fd, (off_t)sizeof(PRISMRingBuffer)) != 0) {
            close(fd);
            return NULL;
        }
    }

    void *mem = mmap(NULL, sizeof(PRISMRingBuffer),
                     PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);  // mapping keeps the region alive
    if (mem == MAP_FAILED) {
        return NULL;
    }
    return (PRISMRingBuffer *)mem;
}

PRISMRingBuffer *PRISMRingBufferCreateProducer(void) {
    return PRISMRingBufferCreateProducerNamed(PRISM_SHM_NAME);
}

PRISMRingBuffer *PRISMRingBufferOpenConsumer(void) {
    return PRISMRingBufferOpenConsumerNamed(PRISM_SHM_NAME);
}

PRISMRingBuffer *PRISMRingBufferCreateProducerNamed(const char *name) {
    if (!name) {
        return NULL;
    }
    PRISMRingBuffer *rb = prism_map(name, true);
    if (!rb) {
        return NULL;
    }
    // A fresh producer session restarts the stream: park the reader at the
    // writer so stale frames from a previous run are never replayed.
    uint64_t wr = atomic_load_explicit(&rb->writeIndex, memory_order_relaxed);
    atomic_store_explicit(&rb->readIndex, wr, memory_order_relaxed);
    atomic_store_explicit(&rb->producerHeartbeat, mach_absolute_time(),
                          memory_order_relaxed);
    atomic_store_explicit(&rb->producerAlive, 1, memory_order_release);
    return rb;
}

PRISMRingBuffer *PRISMRingBufferOpenConsumerNamed(const char *name) {
    return name ? prism_map(name, false) : NULL;
}

void PRISMRingBufferCloseProducer(PRISMRingBuffer *rb) {
    if (!rb) {
        return;
    }
    atomic_store_explicit(&rb->producerAlive, 0, memory_order_release);
    munmap(rb, sizeof(PRISMRingBuffer));
}

void PRISMRingBufferCloseConsumer(PRISMRingBuffer *rb) {
    if (!rb) {
        return;
    }
    munmap(rb, sizeof(PRISMRingBuffer));
}

void PRISMRingBufferWrite(PRISMRingBuffer *rb,
                          const float *interleaved,
                          uint32_t frameCount) {
    if (!rb || !interleaved || frameCount == 0) {
        return;
    }
    if (frameCount > PRISM_RING_CAPACITY) {
        // Keep only the newest full window; older samples are already lost.
        interleaved += (size_t)(frameCount - PRISM_RING_CAPACITY) * PRISM_CHANNELS;
        frameCount = PRISM_RING_CAPACITY;
    }

    uint64_t wr = atomic_load_explicit(&rb->writeIndex, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&rb->readIndex, memory_order_acquire);

    // Overrun: drop oldest by advancing readIndex. The consumer may be
    // advancing it concurrently, so CAS — if the CAS loses, the consumer
    // freed the space itself and we re-check.
    uint64_t needed = (wr - rd) + frameCount;
    while (needed > PRISM_RING_CAPACITY) {
        uint64_t newRd = wr + frameCount - PRISM_RING_CAPACITY;
        if (atomic_compare_exchange_weak_explicit(&rb->readIndex, &rd, newRd,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
            atomic_fetch_add_explicit(&rb->overrunCount, 1,
                                      memory_order_relaxed);
            break;
        }
        needed = (wr - rd) + frameCount;
    }

    // Copy with wrap. Capacity is a power of two.
    uint32_t start = (uint32_t)(wr & (PRISM_RING_CAPACITY - 1));
    uint32_t firstFrames = PRISM_RING_CAPACITY - start;
    if (firstFrames > frameCount) {
        firstFrames = frameCount;
    }
    memcpy(&rb->data[(size_t)start * PRISM_CHANNELS],
           interleaved,
           (size_t)firstFrames * PRISM_CHANNELS * sizeof(float));
    uint32_t remaining = frameCount - firstFrames;
    if (remaining > 0) {
        memcpy(&rb->data[0],
               interleaved + (size_t)firstFrames * PRISM_CHANNELS,
               (size_t)remaining * PRISM_CHANNELS * sizeof(float));
    }

    atomic_store_explicit(&rb->writeIndex, wr + frameCount,
                          memory_order_release);
    atomic_store_explicit(&rb->producerHeartbeat, mach_absolute_time(),
                          memory_order_relaxed);
    atomic_store_explicit(&rb->producerAlive, 1, memory_order_relaxed);
}

uint32_t PRISMRingBufferRead(PRISMRingBuffer *rb,
                             float *outInterleaved,
                             uint32_t frameCount) {
    if (!rb || !outInterleaved || frameCount == 0) {
        return 0;
    }

    uint64_t rd = atomic_load_explicit(&rb->readIndex, memory_order_relaxed);
    uint64_t wr = atomic_load_explicit(&rb->writeIndex, memory_order_acquire);

    uint64_t avail64 = wr - rd;
    uint32_t avail = avail64 > PRISM_RING_CAPACITY
                         ? PRISM_RING_CAPACITY
                         : (uint32_t)avail64;
    uint32_t toRead = avail < frameCount ? avail : frameCount;

    uint32_t start = (uint32_t)(rd & (PRISM_RING_CAPACITY - 1));
    uint32_t firstFrames = PRISM_RING_CAPACITY - start;
    if (firstFrames > toRead) {
        firstFrames = toRead;
    }
    memcpy(outInterleaved,
           &rb->data[(size_t)start * PRISM_CHANNELS],
           (size_t)firstFrames * PRISM_CHANNELS * sizeof(float));
    uint32_t remaining = toRead - firstFrames;
    if (remaining > 0) {
        memcpy(outInterleaved + (size_t)firstFrames * PRISM_CHANNELS,
               &rb->data[0],
               (size_t)remaining * PRISM_CHANNELS * sizeof(float));
    }

    if (toRead < frameCount) {
        memset(outInterleaved + (size_t)toRead * PRISM_CHANNELS, 0,
               (size_t)(frameCount - toRead) * PRISM_CHANNELS * sizeof(float));
        atomic_fetch_add_explicit(&rb->underrunCount, 1, memory_order_relaxed);
    }

    if (toRead > 0) {
        // CAS: the producer may have advanced readIndex past us on overrun.
        uint64_t expected = rd;
        atomic_compare_exchange_strong_explicit(&rb->readIndex, &expected,
                                                rd + toRead,
                                                memory_order_release,
                                                memory_order_relaxed);
    }
    return toRead;
}

bool PRISMRingBufferProducerIsAlive(const PRISMRingBuffer *rb, uint64_t nowMach) {
    if (!rb) {
        return false;
    }
    PRISMRingBuffer *mrb = (PRISMRingBuffer *)rb;
    if (atomic_load_explicit(&mrb->producerAlive, memory_order_acquire) == 0) {
        return false;
    }
    uint64_t beat = atomic_load_explicit(&mrb->producerHeartbeat,
                                         memory_order_relaxed);
    uint64_t timeout = prism_ns_to_mach(PRISM_HEARTBEAT_TIMEOUT_NS);
    return nowMach >= beat ? (nowMach - beat) <= timeout : true;
}

uint64_t PRISMRingBufferFillLevel(const PRISMRingBuffer *rb) {
    if (!rb) {
        return 0;
    }
    PRISMRingBuffer *mrb = (PRISMRingBuffer *)rb;
    uint64_t rd = atomic_load_explicit(&mrb->readIndex, memory_order_relaxed);
    uint64_t wr = atomic_load_explicit(&mrb->writeIndex, memory_order_acquire);
    return wr - rd;
}

// Statistics counters: relaxed loads are correct here, nothing is ordered
// against them.
uint32_t PRISMRingBufferUnderrunCount(const PRISMRingBuffer *rb) {
    if (!rb) {
        return 0;
    }
    PRISMRingBuffer *mrb = (PRISMRingBuffer *)rb;
    return atomic_load_explicit(&mrb->underrunCount, memory_order_relaxed);
}

uint32_t PRISMRingBufferOverrunCount(const PRISMRingBuffer *rb) {
    if (!rb) {
        return 0;
    }
    PRISMRingBuffer *mrb = (PRISMRingBuffer *)rb;
    return atomic_load_explicit(&mrb->overrunCount, memory_order_relaxed);
}

uint64_t PRISMRingBufferProducerHeartbeat(const PRISMRingBuffer *rb) {
    if (!rb) {
        return 0;
    }
    PRISMRingBuffer *mrb = (PRISMRingBuffer *)rb;
    return atomic_load_explicit(&mrb->producerHeartbeat, memory_order_relaxed);
}

void PRISMRingBufferSetProducerHeartbeat(PRISMRingBuffer *rb, uint64_t machTime) {
    if (!rb) {
        return;
    }
    atomic_store_explicit(&rb->producerHeartbeat, machTime, memory_order_relaxed);
}

void PRISMRingBufferSetProducerAlive(PRISMRingBuffer *rb, bool alive) {
    if (!rb) {
        return;
    }
    // Release, matching CloseProducer: the flag must not be reordered ahead of
    // the writes it describes.
    atomic_store_explicit(&rb->producerAlive, alive ? 1u : 0u,
                          memory_order_release);
}

void PRISMAtomicU64StoreRelease(uint64_t *target, uint64_t value) {
    atomic_store_explicit((_Atomic uint64_t *)target, value,
                          memory_order_release);
}

uint64_t PRISMAtomicU64LoadAcquire(const uint64_t *target) {
    return atomic_load_explicit((const _Atomic uint64_t *)target,
                                memory_order_acquire);
}
