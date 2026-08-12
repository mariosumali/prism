// PRISM_PlugIn.h
// PRISMAudioPlugIn
//
// Shared declarations for the PRISM AudioServerPlugIn HAL driver: fixed
// object IDs, device constants (SPEC §4.2), and the per-object property /
// IO entry points implemented across PRISM_PlugIn.cpp, PRISM_Device.cpp and
// PRISM_Stream.cpp. Architecture follows Apple's NullAudio sample (original
// code, no GPL sources).
//
// Licensed under the Apache License, Version 2.0.

#ifndef PRISM_PLUGIN_H
#define PRISM_PLUGIN_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include "SharedTypes.h"
#include "RingBuffer.h"

// ---------------------------------------------------------------------------
// Object IDs — fixed for the lifetime of the plug-in (CONTRACTS: plug-in 1,
// device 2, input stream 3). kAudioObjectPlugInObject is defined as 1.
// ---------------------------------------------------------------------------

enum : AudioObjectID {
    kPRISMObjectID_PlugIn = kAudioObjectPlugInObject,   // 1
    kPRISMObjectID_Device = 2,
    kPRISMObjectID_Stream = 3,
};

// ---------------------------------------------------------------------------
// Device constants (SPEC §4.2)
// ---------------------------------------------------------------------------

#define kPRISM_DeviceName          "PRISM Microphone"
#define kPRISM_DeviceUID           "horse.prism.PRISM.audio.device"
#define kPRISM_DeviceModelUID      "PRISM Virtual Microphone"
#define kPRISM_Manufacturer        "PRISM"
#define kPRISM_PlugInName          "PRISM Audio"
#define kPRISM_StreamName          "PRISM Microphone Input"

enum : UInt32 {
    kPRISM_SafetyOffsetFrames     = 512,
    kPRISM_ZeroTimeStampPeriod    = 4096,
    kPRISM_ChannelCount           = PRISM_CHANNELS,     // 2
};

// 48000 Hz is the only supported rate.
#define kPRISM_SampleRate          PRISM_SAMPLE_RATE

// ---------------------------------------------------------------------------
// Shared driver state (defined in PRISM_PlugIn.cpp / PRISM_Device.cpp)
// ---------------------------------------------------------------------------

// The host ref handed to Initialize; may be NULL until then.
extern AudioServerPlugInHostRef gPRISM_Host;

// The driver ref (address of the vtable pointer), needed for identity checks.
extern AudioServerPlugInDriverRef gPRISM_DriverRef;

// ---------------------------------------------------------------------------
// Plug-in object property dispatch (PRISM_PlugIn.cpp)
// ---------------------------------------------------------------------------

Boolean  PRISM_PlugIn_HasProperty(const AudioObjectPropertyAddress* inAddress);
OSStatus PRISM_PlugIn_IsPropertySettable(const AudioObjectPropertyAddress* inAddress,
                                         Boolean* outIsSettable);
OSStatus PRISM_PlugIn_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
                                          UInt32 inQualifierDataSize,
                                          const void* inQualifierData,
                                          UInt32* outDataSize);
OSStatus PRISM_PlugIn_GetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32* outDataSize,
                                      void* outData);
OSStatus PRISM_PlugIn_SetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      const void* inData);

// ---------------------------------------------------------------------------
// Device object property dispatch + IO (PRISM_Device.cpp)
// ---------------------------------------------------------------------------

// Called once from Initialize: computes the host-clock timebase and maps the
// shared ring via PRISMRingBufferOpenConsumer. A mapping failure is tolerated
// (the device still publishes and emits silence). Always returns noErr.
OSStatus PRISM_Device_Initialize(void);

Boolean  PRISM_Device_HasProperty(const AudioObjectPropertyAddress* inAddress);
OSStatus PRISM_Device_IsPropertySettable(const AudioObjectPropertyAddress* inAddress,
                                         Boolean* outIsSettable);
OSStatus PRISM_Device_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
                                          UInt32 inQualifierDataSize,
                                          const void* inQualifierData,
                                          UInt32* outDataSize);
OSStatus PRISM_Device_GetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32* outDataSize,
                                      void* outData);
OSStatus PRISM_Device_SetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      const void* inData);

OSStatus PRISM_Device_StartIO(void);
OSStatus PRISM_Device_StopIO(void);
OSStatus PRISM_Device_GetZeroTimeStamp(Float64* outSampleTime,
                                       UInt64* outHostTime,
                                       UInt64* outSeed);
OSStatus PRISM_Device_WillDoIOOperation(UInt32 inOperationID,
                                        Boolean* outWillDo,
                                        Boolean* outWillDoInPlace);
OSStatus PRISM_Device_BeginIOOperation(UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
OSStatus PRISM_Device_DoIOOperation(AudioObjectID inStreamObjectID,
                                    UInt32 inOperationID,
                                    UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                    void* ioMainBuffer,
                                    void* ioSecondaryBuffer);
OSStatus PRISM_Device_EndIOOperation(UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

// ---------------------------------------------------------------------------
// Stream object property dispatch (PRISM_Stream.cpp)
// ---------------------------------------------------------------------------

// The single supported format: 48 kHz, 2 ch, 32-bit float, non-interleaved.
AudioStreamBasicDescription PRISM_Stream_Format(void);

Boolean  PRISM_Stream_HasProperty(const AudioObjectPropertyAddress* inAddress);
OSStatus PRISM_Stream_IsPropertySettable(const AudioObjectPropertyAddress* inAddress,
                                         Boolean* outIsSettable);
OSStatus PRISM_Stream_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
                                          UInt32 inQualifierDataSize,
                                          const void* inQualifierData,
                                          UInt32* outDataSize);
OSStatus PRISM_Stream_GetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32* outDataSize,
                                      void* outData);
OSStatus PRISM_Stream_SetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      const void* inData);

#endif /* PRISM_PLUGIN_H */
