// PRISM_Stream.cpp
// PRISMAudioPlugIn
//
// The single input stream object (ID 3) of "PRISM Microphone": direction
// input, terminal type microphone, and exactly one format — 48 kHz stereo
// 32-bit float, non-interleaved (two AudioBuffers in the ABL), published via
// both the virtual- and physical-format properties (SPEC §4.2).
//
// Licensed under the Apache License, Version 2.0.

#include "PRISM_PlugIn.h"

#include <cstring>

// ===========================================================================
// Stream state
// ===========================================================================

// Whether the stream participates in IO. The HAL may toggle this; the device
// has nothing to reconfigure either way. C11 _Atomic (via SharedTypes.h's
// <stdatomic.h>) rather than libc++ <atomic>, which cannot coexist with
// <stdatomic.h> before C++23.
static _Atomic uint32_t gStream_IsActive = 1;

// ===========================================================================
// The one supported format
// ===========================================================================

AudioStreamBasicDescription PRISM_Stream_Format(void)
{
    AudioStreamBasicDescription asbd;
    std::memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate       = kPRISM_SampleRate;
    asbd.mFormatID         = kAudioFormatLinearPCM;
    asbd.mFormatFlags      = kAudioFormatFlagIsFloat
                           | kAudioFormatFlagsNativeEndian
                           | kAudioFormatFlagIsPacked
                           | kAudioFormatFlagIsNonInterleaved;
    // Non-interleaved: each of the two AudioBuffers carries one channel of
    // 32-bit floats, so packets and frames are 4 bytes per channel buffer.
    asbd.mBytesPerPacket   = sizeof(Float32);
    asbd.mFramesPerPacket  = 1;
    asbd.mBytesPerFrame    = sizeof(Float32);
    asbd.mChannelsPerFrame = kPRISM_ChannelCount;
    asbd.mBitsPerChannel   = 32;
    return asbd;
}

// True when the proposed format is (equivalent to) the one supported format.
static bool PRISM_Stream_FormatIsSupported(const AudioStreamBasicDescription* inFormat)
{
    if (inFormat == nullptr) {
        return false;
    }
    return inFormat->mFormatID == kAudioFormatLinearPCM
        && inFormat->mSampleRate == kPRISM_SampleRate
        && inFormat->mChannelsPerFrame == kPRISM_ChannelCount
        && inFormat->mBitsPerChannel == 32
        && (inFormat->mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && (inFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
}

// ===========================================================================
// HasProperty
// ===========================================================================

Boolean PRISM_Stream_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

// ===========================================================================
// IsPropertySettable
// ===========================================================================

OSStatus PRISM_Stream_IsPropertySettable(const AudioObjectPropertyAddress* inAddress,
                                         Boolean* outIsSettable)
{
    switch (inAddress->mSelector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            // Formats are "settable" but only to the one published format.
            *outIsSettable = true;
            return noErr;

        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outIsSettable = false;
            return noErr;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// ===========================================================================
// GetPropertyDataSize
// ===========================================================================

OSStatus PRISM_Stream_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
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
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;                              // no custom properties
            return noErr;

        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = 1 * sizeof(AudioStreamRangedDescription);  // 48k only
            return noErr;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// ===========================================================================
// GetPropertyData
// ===========================================================================

OSStatus PRISM_Stream_GetPropertyData(const AudioObjectPropertyAddress* inAddress,
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
            *static_cast<AudioClassID*>(outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<AudioObjectID*>(outData) = kPRISMObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<CFStringRef*>(outData) = CFSTR(kPRISM_StreamName);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return noErr;

        case kAudioStreamPropertyIsActive:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) =
                atomic_load_explicit(&gStream_IsActive, memory_order_relaxed);
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyDirection:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = 1;            // 1 = input
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyTerminalType:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = kAudioStreamTerminalTypeMicrophone;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyStartingChannel:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyLatency:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<UInt32*>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<AudioStreamBasicDescription*>(outData) = PRISM_Stream_Format();
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 capacity = inDataSize
                            / static_cast<UInt32>(sizeof(AudioStreamRangedDescription));
            if (capacity >= 1) {
                AudioStreamRangedDescription* ranged =
                    static_cast<AudioStreamRangedDescription*>(outData);
                ranged->mFormat = PRISM_Stream_Format();
                ranged->mSampleRateRange.mMinimum = kPRISM_SampleRate;
                ranged->mSampleRateRange.mMaximum = kPRISM_SampleRate;
                *outDataSize = 1 * sizeof(AudioStreamRangedDescription);
            } else {
                *outDataSize = 0;
            }
            return noErr;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// ===========================================================================
// SetPropertyData
// ===========================================================================

OSStatus PRISM_Stream_SetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      const void* inData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;
    switch (inAddress->mSelector) {
        case kAudioStreamPropertyIsActive: {
            if (inDataSize != sizeof(UInt32) || inData == nullptr) {
                return kAudioHardwareBadPropertySizeError;
            }
            UInt32 requested = *static_cast<const UInt32*>(inData);
            atomic_store_explicit(&gStream_IsActive,
                                  requested != 0 ? 1u : 0u,
                                  memory_order_relaxed);
            return noErr;
        }

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize != sizeof(AudioStreamBasicDescription) || inData == nullptr) {
                return kAudioHardwareBadPropertySizeError;
            }
            const AudioStreamBasicDescription* requested =
                static_cast<const AudioStreamBasicDescription*>(inData);
            if (!PRISM_Stream_FormatIsSupported(requested)) {
                return kAudioDeviceUnsupportedFormatError;
            }
            // The requested format is the current (only) format: a
            // successful no-op, no configuration change required.
            return noErr;
        }

        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return kAudioHardwareUnsupportedOperationError;   // read-only

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}
