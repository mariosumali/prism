// PRISM_Device.cpp
// PRISMAudioPlugIn
//
// The "PRISM Microphone" device object: properties per SPEC §4.2 (input-only,
// 48 kHz, virtual transport, safety offset 512, zero-timestamp period 4096)
// and the IO path. ReadInput pulls interleaved stereo floats from the shared
// ring (PRISMShared/RingBuffer.h) and de-interleaves into the two-buffer ABL;
// when the producer (PRISM.app) is gone it emits silence. The IO path takes
// no locks, performs no allocation, and never logs.
//
// Licensed under the Apache License, Version 2.0.

#include "PRISM_PlugIn.h"

#include <mach/mach_time.h>
#include <pthread.h>

#include <cstring>

// ===========================================================================
// Device state
// ===========================================================================
//
// Note: C11 _Atomic (via SharedTypes.h's <stdatomic.h>) is used instead of
// libc++ <atomic>/<mutex>, which cannot coexist with <stdatomic.h> before
// C++23. The mutex is a pthread mutex for the same reason.

// Shared ring, mapped in PRISM_Device_Initialize. NULL when mapping failed;
// the device still publishes and the IO path emits silence.
static PRISMRingBuffer*      gDevice_Ring = nullptr;

// Host clock ticks per audio frame at 48 kHz, computed once at Initialize.
static Float64               gDevice_HostTicksPerFrame = 0.0;

// Serializes StartIO/StopIO and settable-property writes. Never touched on
// the real-time IO path (GetZeroTimeStamp / Begin/Do/EndIOOperation).
static pthread_mutex_t       gDevice_StateMutex = PTHREAD_MUTEX_INITIALIZER;

// Number of outstanding StartIO calls. Read by DeviceIsRunning.
static _Atomic uint32_t      gDevice_IORunningCount = 0;

// Zero-timestamp anchor: host time at the most recent 0→1 StartIO, and the
// number of 4096-frame periods elapsed since. GetZeroTimeStamp is called on
// the device's single IO thread, so relaxed atomics are sufficient — they
// exist to make the StartIO reset visible without a lock.
static _Atomic uint64_t      gDevice_AnchorHostTime = 0;
static _Atomic uint64_t      gDevice_TimeStampCount = 0;

// Ring write index at the most recent 0→1 StartIO: device sample time 0 maps
// to this ring position. ReadInput indexes the ring by the IO cycle's input
// sample time relative to this anchor, so reads are IDEMPOTENT — coreaudiod
// runs an IO cycle per capturing client, and a destructive shared read
// cursor would hand N simultaneous clients disjoint alternating chunks of
// the stream (each hearing gapped audio at N× consumption rate).
static _Atomic uint64_t      gDevice_AnchorWriteIndex = 0;

// ===========================================================================
// Initialization
// ===========================================================================

OSStatus PRISM_Device_Initialize(void)
{
    // Host ticks per frame: mach_absolute_time ticks-per-second divided by
    // the (only) sample rate.
    struct mach_timebase_info timebase = {0, 0};
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1.0e9;
    if (timebase.numer != 0 && timebase.denom != 0) {
        ticksPerSecond = 1.0e9 * static_cast<Float64>(timebase.denom)
                               / static_cast<Float64>(timebase.numer);
    }
    gDevice_HostTicksPerFrame = ticksPerSecond / kPRISM_SampleRate;

    // Map the shared ring. Failure is tolerated: the device still publishes
    // and DoIOOperation emits silence until a later restart maps it.
    gDevice_Ring = PRISMRingBufferOpenConsumer();

    return noErr;
}

// ===========================================================================
// Property helpers
// ===========================================================================

static bool PRISM_ScopeIsGlobalOrInput(AudioObjectPropertyScope inScope)
{
    return inScope == kAudioObjectPropertyScopeGlobal
        || inScope == kAudioObjectPropertyScopeInput;
}

// ===========================================================================
// HasProperty
// ===========================================================================

Boolean PRISM_Device_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        // Object-level and global device properties: any scope.
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreams:            // empty in output scope
            return true;

        // Input-side properties on an input-only device.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return PRISM_ScopeIsGlobalOrInput(inAddress->mScope);

        default:
            return false;
    }
}

// ===========================================================================
// IsPropertySettable
// ===========================================================================

OSStatus PRISM_Device_IsPropertySettable(const AudioObjectPropertyAddress* inAddress,
                                         Boolean* outIsSettable)
{
    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            // Settable, but 48000 is the only accepted value.
            *outIsSettable = true;
            return noErr;

        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            *outIsSettable = false;
            return noErr;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// ===========================================================================
// GetPropertyDataSize
// ===========================================================================

OSStatus PRISM_Device_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
                                          UInt32 inQualifierDataSize,
                                          const void* inQualifierData,
                                          UInt32* outDataSize)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 1 * sizeof(AudioObjectID);      // the input stream
            return noErr;

        case kAudioObjectPropertyControlList:
            *outDataSize = 0;                              // no controls
            return noErr;

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;                              // no custom properties
            return noErr;

        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = 1 * sizeof(AudioObjectID);      // just this device
            return noErr;

        case kAudioDevicePropertyStreams:
            *outDataSize = PRISM_ScopeIsGlobalOrInput(inAddress->mScope)
                         ? 1 * sizeof(AudioObjectID)       // the input stream
                         : 0;                              // no output streams
            return noErr;

        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return noErr;

        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = 1 * sizeof(AudioValueRange);    // 48 kHz only
            return noErr;

        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = static_cast<UInt32>(
                offsetof(AudioChannelLayout, mChannelDescriptions)
                + kPRISM_ChannelCount * sizeof(AudioChannelDescription));
            return noErr;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// ===========================================================================
// GetPropertyData
// ===========================================================================

OSStatus PRISM_Device_GetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32* outDataSize,
                                      void* outData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<AudioClassID*>(outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<AudioClassID*>(outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<AudioObjectID*>(outData) = kPRISMObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<CFStringRef*>(outData) = CFSTR(kPRISM_DeviceName);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<CFStringRef*>(outData) = CFSTR(kPRISM_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyOwnedObjects: {
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            if (capacity >= 1) {
                static_cast<AudioObjectID*>(outData)[0] = kPRISMObjectID_Stream;
                *outDataSize = 1 * sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return noErr;
        }

        case kAudioObjectPropertyControlList:
            // Input-only pass-through device: no volume/mute/data-source
            // controls (SPEC §4.2 — v1 audio is pass-through plus app-side
            // mute; the device itself has no controls).
            *outDataSize = 0;
            return noErr;

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return noErr;

        case kAudioDevicePropertyDeviceUID:
            if (inDataSize < sizeof(CFStringRef)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<CFStringRef*>(outData) = CFSTR(kPRISM_DeviceUID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioDevicePropertyModelUID:
            if (inDataSize < sizeof(CFStringRef)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<CFStringRef*>(outData) = CFSTR(kPRISM_DeviceModelUID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioDevicePropertyTransportType:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyRelatedDevices: {
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            if (capacity >= 1) {
                static_cast<AudioObjectID*>(outData)[0] = kPRISMObjectID_Device;
                *outDataSize = 1 * sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return noErr;
        }

        case kAudioDevicePropertyClockDomain:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyDeviceIsAlive:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            // Always alive — liveness of PRISM.app only gates silence.
            *static_cast<UInt32*>(outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyDeviceIsRunning:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) =
                (atomic_load_explicit(&gDevice_IORunningCount,
                                      memory_order_relaxed) > 0) ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            // Selectable as the system default input device.
            *static_cast<UInt32*>(outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            // System-sound routing is an output concern; never claim it.
            *static_cast<UInt32*>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyLatency:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertySafetyOffset:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = kPRISM_SafetyOffsetFrames;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = kPRISM_ZeroTimeStampPeriod;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyStreams: {
            if (!PRISM_ScopeIsGlobalOrInput(inAddress->mScope)) {
                *outDataSize = 0;                          // no output streams
                return noErr;
            }
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            if (capacity >= 1) {
                static_cast<AudioObjectID*>(outData)[0] = kPRISMObjectID_Stream;
                *outDataSize = 1 * sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return noErr;
        }

        case kAudioDevicePropertyNominalSampleRate:
            if (inDataSize < sizeof(Float64)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<Float64*>(outData) = kPRISM_SampleRate;
            *outDataSize = sizeof(Float64);
            return noErr;

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 capacity = inDataSize / sizeof(AudioValueRange);
            if (capacity >= 1) {
                AudioValueRange* range = static_cast<AudioValueRange*>(outData);
                range->mMinimum = kPRISM_SampleRate;
                range->mMaximum = kPRISM_SampleRate;
                *outDataSize = 1 * sizeof(AudioValueRange);
            } else {
                *outDataSize = 0;
            }
            return noErr;
        }

        case kAudioDevicePropertyIsHidden:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (inDataSize < 2 * sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            static_cast<UInt32*>(outData)[0] = 1;
            static_cast<UInt32*>(outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyPreferredChannelLayout: {
            const UInt32 required = static_cast<UInt32>(
                offsetof(AudioChannelLayout, mChannelDescriptions)
                + kPRISM_ChannelCount * sizeof(AudioChannelDescription));
            if (inDataSize < required) {
                return kAudioHardwareBadPropertySizeError;
            }
            AudioChannelLayout* layout = static_cast<AudioChannelLayout*>(outData);
            std::memset(layout, 0, required);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mChannelBitmap = 0;
            layout->mNumberChannelDescriptions = kPRISM_ChannelCount;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = required;
            return noErr;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// ===========================================================================
// SetPropertyData
// ===========================================================================

OSStatus PRISM_Device_SetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      const void* inData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;
    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate: {
            if (inDataSize != sizeof(Float64) || inData == nullptr) {
                return kAudioHardwareBadPropertySizeError;
            }
            Float64 requested = *static_cast<const Float64*>(inData);
            if (requested != kPRISM_SampleRate) {
                // 48000 is the only rate; anything else is rejected.
                return kAudioHardwareIllegalOperationError;
            }
            // Setting the current (only) rate is a successful no-op — no
            // configuration change needs to be requested from the host.
            return noErr;
        }

        default:
            // Everything else is either read-only or unknown.
            {
                Boolean settable = false;
                OSStatus status = PRISM_Device_IsPropertySettable(inAddress, &settable);
                if (status != noErr) {
                    return status;
                }
                return kAudioHardwareUnsupportedOperationError;
            }
    }
}

// ===========================================================================
// IO — StartIO / StopIO (non-real-time; a lock here is permitted)
// ===========================================================================

OSStatus PRISM_Device_StartIO(void)
{
    pthread_mutex_lock(&gDevice_StateMutex);

    UInt32 running = atomic_load_explicit(&gDevice_IORunningCount,
                                          memory_order_relaxed);
    if (running == UINT32_MAX) {
        pthread_mutex_unlock(&gDevice_StateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (running == 0) {
        // First client: anchor the zero-timestamp clock now.
        atomic_store_explicit(&gDevice_TimeStampCount, 0ull, memory_order_relaxed);
        atomic_store_explicit(&gDevice_AnchorHostTime, mach_absolute_time(),
                              memory_order_relaxed);

        // Anchor the sample-time → ring-position mapping (sample time 0 =
        // current write position), and fast-forward the ring's read cursor
        // past any stale backlog so the first cycles deliver fresh audio
        // rather than up-to-683ms-old data.
        if (gDevice_Ring != nullptr) {
            uint64_t w = atomic_load_explicit(&gDevice_Ring->writeIndex,
                                              memory_order_acquire);
            atomic_store_explicit(&gDevice_AnchorWriteIndex, w,
                                  memory_order_relaxed);
            atomic_store_explicit(&gDevice_Ring->readIndex, w,
                                  memory_order_release);
        }
    }
    atomic_store_explicit(&gDevice_IORunningCount, running + 1,
                          memory_order_relaxed);

    pthread_mutex_unlock(&gDevice_StateMutex);
    return noErr;
}

OSStatus PRISM_Device_StopIO(void)
{
    pthread_mutex_lock(&gDevice_StateMutex);

    UInt32 running = atomic_load_explicit(&gDevice_IORunningCount,
                                          memory_order_relaxed);
    if (running == 0) {
        pthread_mutex_unlock(&gDevice_StateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    atomic_store_explicit(&gDevice_IORunningCount, running - 1,
                          memory_order_relaxed);

    pthread_mutex_unlock(&gDevice_StateMutex);
    return noErr;
}

// ===========================================================================
// IO — real-time path. No locks, no allocation, no logging beyond this line.
// ===========================================================================

OSStatus PRISM_Device_GetZeroTimeStamp(Float64* outSampleTime,
                                       UInt64* outHostTime,
                                       UInt64* outSeed)
{
    const UInt64  anchor         = atomic_load_explicit(&gDevice_AnchorHostTime,
                                                        memory_order_relaxed);
    const Float64 ticksPerPeriod = gDevice_HostTicksPerFrame
                                 * static_cast<Float64>(kPRISM_ZeroTimeStampPeriod);
    const UInt64  now            = mach_absolute_time();

    UInt64 count = atomic_load_explicit(&gDevice_TimeStampCount,
                                        memory_order_relaxed);
    const UInt64 nextHostTime = anchor
        + static_cast<UInt64>(static_cast<Float64>(count + 1) * ticksPerPeriod);
    if (nextHostTime <= now) {
        count += 1;
        atomic_store_explicit(&gDevice_TimeStampCount, count, memory_order_relaxed);
    }

    *outSampleTime = static_cast<Float64>(count)
                   * static_cast<Float64>(kPRISM_ZeroTimeStampPeriod);
    *outHostTime = anchor
        + static_cast<UInt64>(static_cast<Float64>(count) * ticksPerPeriod);
    *outSeed = 1;
    return noErr;
}

OSStatus PRISM_Device_WillDoIOOperation(UInt32 inOperationID,
                                        Boolean* outWillDo,
                                        Boolean* outWillDoInPlace)
{
    // Input-only device: the only operation performed is ReadInput.
    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return noErr;
}

OSStatus PRISM_Device_BeginIOOperation(UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return noErr;
}

OSStatus PRISM_Device_DoIOOperation(AudioObjectID inStreamObjectID,
                                    UInt32 inOperationID,
                                    UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                    void* ioMainBuffer,
                                    void* ioSecondaryBuffer)
{
    (void)ioSecondaryBuffer;

    if (inOperationID != kAudioServerPlugInIOOperationReadInput) {
        return noErr;
    }
    if (inStreamObjectID != kPRISMObjectID_Stream) {
        return kAudioHardwareBadStreamError;
    }
    if (ioMainBuffer == nullptr || inIOBufferFrameSize == 0) {
        return noErr;
    }

    AudioBufferList* abl = static_cast<AudioBufferList*>(ioMainBuffer);
    const UInt32 bufferCount = abl->mNumberBuffers;

    // Per-channel destination pointers and capacities for the two-buffer
    // non-interleaved ABL. Missing/undersized buffers are tolerated.
    float* dest[kPRISM_ChannelCount] = {nullptr, nullptr};
    UInt32 destCapacity[kPRISM_ChannelCount] = {0, 0};
    for (UInt32 c = 0; c < kPRISM_ChannelCount && c < bufferCount; ++c) {
        dest[c] = static_cast<float*>(abl->mBuffers[c].mData);
        destCapacity[c] = abl->mBuffers[c].mDataByteSize
                        / static_cast<UInt32>(sizeof(float));
    }

    const UInt32 frameCount = inIOBufferFrameSize;

    // Producer gone (or ring never mapped): silence, per SPEC §4.3. The
    // aliveness check reads two atomics against mach_absolute_time.
    const bool haveAudio = (gDevice_Ring != nullptr)
        && PRISMRingBufferProducerIsAlive(gDevice_Ring, mach_absolute_time());

    if (!haveAudio) {
        for (UInt32 c = 0; c < kPRISM_ChannelCount; ++c) {
            if (dest[c] != nullptr) {
                UInt32 n = frameCount < destCapacity[c] ? frameCount : destCapacity[c];
                std::memset(dest[c], 0, n * sizeof(float));
            }
        }
        return noErr;
    }

    // Idempotent, sample-time-indexed read (no shared cursor, no scratch):
    // the cycle's input sample time maps onto the ring via the StartIO
    // anchor, so N simultaneous capture clients reading overlapping time
    // ranges all receive the same audio. Frames outside the valid window
    // [wr − capacity, wr) — not yet produced, pre-anchor, or already
    // overwritten — are zero-filled and counted as an underrun.
    const uint64_t anchor = atomic_load_explicit(&gDevice_AnchorWriteIndex,
                                                 memory_order_relaxed);
    const uint64_t wr = atomic_load_explicit(&gDevice_Ring->writeIndex,
                                             memory_order_acquire);
    const uint64_t lowBound = wr > PRISM_RING_CAPACITY
                            ? wr - PRISM_RING_CAPACITY : 0;
    const int64_t stBase = (int64_t)inIOCycleInfo->mInputTime.mSampleTime;
    bool shortfall = false;

    for (UInt32 i = 0; i < frameCount; ++i) {
        const int64_t rel = stBase + (int64_t)i;
        const float* src = nullptr;
        if (rel >= 0) {
            const uint64_t pos = anchor + (uint64_t)rel;
            if (pos >= lowBound && pos < wr) {
                const uint32_t idx = (uint32_t)(pos & (PRISM_RING_CAPACITY - 1));
                src = &gDevice_Ring->data[(size_t)idx * kPRISM_ChannelCount];
            } else {
                shortfall = true;
            }
        }
        for (UInt32 c = 0; c < kPRISM_ChannelCount; ++c) {
            float* out = dest[c];
            if (out != nullptr && i < destCapacity[c]) {
                out[i] = (src != nullptr) ? src[c] : 0.0f;
            }
        }
    }
    if (shortfall) {
        atomic_fetch_add_explicit(&gDevice_Ring->underrunCount, 1,
                                  memory_order_relaxed);
    }

    // Advance readIndex as a consumption high-water mark only (never past
    // the write index, never backwards) so the producer's overrun accounting
    // keeps working; it is not a read cursor and reads never depend on it.
    const int64_t endRel = stBase + (int64_t)frameCount;
    if (endRel > 0) {
        uint64_t end = anchor + (uint64_t)endRel;
        if (end > wr) {
            end = wr;
        }
        uint64_t rd = atomic_load_explicit(&gDevice_Ring->readIndex,
                                           memory_order_relaxed);
        while (end > rd) {
            if (atomic_compare_exchange_weak_explicit(&gDevice_Ring->readIndex,
                                                      &rd, end,
                                                      memory_order_release,
                                                      memory_order_relaxed)) {
                break;
            }
        }
    }

    return noErr;
}

OSStatus PRISM_Device_EndIOOperation(UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return noErr;
}
