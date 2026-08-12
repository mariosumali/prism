// PRISM_PlugIn.cpp
// PRISMAudioPlugIn
//
// COM factory (PRISM_CreatePlugIn), the AudioServerPlugInDriverInterface
// vtable, and property dispatch for the plug-in object. Object-specific
// property handling and IO live in PRISM_Device.cpp / PRISM_Stream.cpp.
// Architecture follows Apple's NullAudio sample; all code here is original.
//
// Licensed under the Apache License, Version 2.0.

#include "PRISM_PlugIn.h"

#include <CoreFoundation/CFPlugInCOM.h>

#include <cstring>

// ===========================================================================
// Shared state
// ===========================================================================
//
// Note: C11 _Atomic (via SharedTypes.h's <stdatomic.h>) is used instead of
// libc++ <atomic>, which cannot coexist with <stdatomic.h> before C++23.

AudioServerPlugInHostRef  gPRISM_Host      = nullptr;
AudioServerPlugInDriverRef gPRISM_DriverRef = nullptr;

static _Atomic uint32_t gPRISM_RefCount = 0;

// ===========================================================================
// Forward declarations for the vtable
// ===========================================================================

extern "C" void* PRISM_CreatePlugIn(CFAllocatorRef inAllocator,
                                    CFUUIDRef inRequestedTypeUUID);

static HRESULT  PRISM_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    PRISM_AddRef(void* inDriver);
static ULONG    PRISM_Release(void* inDriver);
static OSStatus PRISM_Initialize(AudioServerPlugInDriverRef inDriver,
                                 AudioServerPlugInHostRef inHost);
static OSStatus PRISM_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                   CFDictionaryRef inDescription,
                                   const AudioServerPlugInClientInfo* inClientInfo,
                                   AudioObjectID* outDeviceObjectID);
static OSStatus PRISM_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID);
static OSStatus PRISM_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus PRISM_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus PRISM_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                       AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction,
                                                       void* inChangeInfo);
static OSStatus PRISM_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction,
                                                     void* inChangeInfo);
static Boolean  PRISM_HasProperty(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inObjectID,
                                  pid_t inClientProcessID,
                                  const AudioObjectPropertyAddress* inAddress);
static OSStatus PRISM_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inObjectID,
                                         pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress,
                                         Boolean* outIsSettable);
static OSStatus PRISM_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress,
                                          UInt32 inQualifierDataSize,
                                          const void* inQualifierData,
                                          UInt32* outDataSize);
static OSStatus PRISM_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32* outDataSize,
                                      void* outData);
static OSStatus PRISM_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      const void* inData);
static OSStatus PRISM_StartIO(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID);
static OSStatus PRISM_StopIO(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inDeviceObjectID,
                             UInt32 inClientID);
static OSStatus PRISM_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID,
                                       Float64* outSampleTime,
                                       UInt64* outHostTime,
                                       UInt64* outSeed);
static OSStatus PRISM_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID,
                                        UInt32 inOperationID,
                                        Boolean* outWillDo,
                                        Boolean* outWillDoInPlace);
static OSStatus PRISM_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID,
                                       UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus PRISM_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID,
                                    AudioObjectID inStreamObjectID,
                                    UInt32 inClientID,
                                    UInt32 inOperationID,
                                    UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                    void* ioMainBuffer,
                                    void* ioSecondaryBuffer);
static OSStatus PRISM_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

// ===========================================================================
// Vtable + driver ref
// ===========================================================================

static AudioServerPlugInDriverInterface gPRISM_DriverInterface = {
    nullptr,                                    // _reserved
    PRISM_QueryInterface,
    PRISM_AddRef,
    PRISM_Release,
    PRISM_Initialize,
    PRISM_CreateDevice,
    PRISM_DestroyDevice,
    PRISM_AddDeviceClient,
    PRISM_RemoveDeviceClient,
    PRISM_PerformDeviceConfigurationChange,
    PRISM_AbortDeviceConfigurationChange,
    PRISM_HasProperty,
    PRISM_IsPropertySettable,
    PRISM_GetPropertyDataSize,
    PRISM_GetPropertyData,
    PRISM_SetPropertyData,
    PRISM_StartIO,
    PRISM_StopIO,
    PRISM_GetZeroTimeStamp,
    PRISM_WillDoIOOperation,
    PRISM_BeginIOOperation,
    PRISM_DoIOOperation,
    PRISM_EndIOOperation,
};

static AudioServerPlugInDriverInterface* gPRISM_DriverInterfacePtr = &gPRISM_DriverInterface;

// ===========================================================================
// Factory
// ===========================================================================

// Entry point named by CFPlugInFactories under UUID
// 8E9C0B4F-3A61-4D27-9C1E-5B7D2F6A0C43 in Info.plist.
extern "C" void* PRISM_CreatePlugIn(CFAllocatorRef inAllocator,
                                    CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (inRequestedTypeUUID == nullptr) {
        return nullptr;
    }
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    gPRISM_DriverRef = &gPRISM_DriverInterfacePtr;
    atomic_fetch_add_explicit(&gPRISM_RefCount, 1u, memory_order_relaxed);
    return gPRISM_DriverRef;
}

// ===========================================================================
// COM plumbing
// ===========================================================================

static HRESULT PRISM_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (outInterface == nullptr) {
        return E_POINTER;
    }
    if (inDriver == nullptr || inDriver != gPRISM_DriverRef) {
        *outInterface = nullptr;
        return E_POINTER;
    }

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(nullptr, inUUID);
    if (requested == nullptr) {
        *outInterface = nullptr;
        return E_POINTER;
    }

    HRESULT result;
    if (CFEqual(requested, IUnknownUUID) ||
        CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add_explicit(&gPRISM_RefCount, 1u, memory_order_relaxed);
        *outInterface = gPRISM_DriverRef;
        result = S_OK;
    } else {
        *outInterface = nullptr;
        result = E_NOINTERFACE;
    }
    CFRelease(requested);
    return result;
}

static ULONG PRISM_AddRef(void* inDriver)
{
    if (inDriver != gPRISM_DriverRef) {
        return 0;
    }
    return atomic_fetch_add_explicit(&gPRISM_RefCount, 1u, memory_order_relaxed) + 1;
}

static ULONG PRISM_Release(void* inDriver)
{
    if (inDriver != gPRISM_DriverRef) {
        return 0;
    }
    // The driver is a static singleton hosted for the life of coreaudiod;
    // nothing is destroyed at zero.
    uint32_t previous = atomic_load_explicit(&gPRISM_RefCount, memory_order_relaxed);
    if (previous == 0) {
        return 0;
    }
    return atomic_fetch_sub_explicit(&gPRISM_RefCount, 1u, memory_order_relaxed) - 1;
}

// ===========================================================================
// Driver lifecycle
// ===========================================================================

static OSStatus PRISM_Initialize(AudioServerPlugInDriverRef inDriver,
                                 AudioServerPlugInHostRef inHost)
{
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    gPRISM_Host = inHost;
    // Computes the timebase and maps the shared ring; tolerates mapping
    // failure so the device still publishes (it will emit silence).
    return PRISM_Device_Initialize();
}

static OSStatus PRISM_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                   CFDictionaryRef inDescription,
                                   const AudioServerPlugInClientInfo* inClientInfo,
                                   AudioObjectID* outDeviceObjectID)
{
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    // PRISM publishes exactly one fixed device; dynamic devices unsupported.
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus PRISM_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID)
{
    (void)inDeviceObjectID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus PRISM_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return noErr;
}

static OSStatus PRISM_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return noErr;
}

static OSStatus PRISM_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                       AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction,
                                                       void* inChangeInfo)
{
    (void)inChangeAction;
    (void)inChangeInfo;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    // The device supports exactly one sample rate and one format, so there
    // is never a configuration to change.
    return noErr;
}

static OSStatus PRISM_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction,
                                                     void* inChangeInfo)
{
    (void)inChangeAction;
    (void)inChangeInfo;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return noErr;
}

// ===========================================================================
// Property dispatch — routes by object ID
// ===========================================================================

static Boolean PRISM_HasProperty(AudioServerPlugInDriverRef inDriver,
                                 AudioObjectID inObjectID,
                                 pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientProcessID;
    if (inDriver != gPRISM_DriverRef || inAddress == nullptr) {
        return false;
    }
    switch (inObjectID) {
        case kPRISMObjectID_PlugIn: return PRISM_PlugIn_HasProperty(inAddress);
        case kPRISMObjectID_Device: return PRISM_Device_HasProperty(inAddress);
        case kPRISMObjectID_Stream: return PRISM_Stream_HasProperty(inAddress);
        default:                    return false;
    }
}

static OSStatus PRISM_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inObjectID,
                                         pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress,
                                         Boolean* outIsSettable)
{
    (void)inClientProcessID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == nullptr || outIsSettable == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    switch (inObjectID) {
        case kPRISMObjectID_PlugIn:
            return PRISM_PlugIn_IsPropertySettable(inAddress, outIsSettable);
        case kPRISMObjectID_Device:
            return PRISM_Device_IsPropertySettable(inAddress, outIsSettable);
        case kPRISMObjectID_Stream:
            return PRISM_Stream_IsPropertySettable(inAddress, outIsSettable);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus PRISM_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress,
                                          UInt32 inQualifierDataSize,
                                          const void* inQualifierData,
                                          UInt32* outDataSize)
{
    (void)inClientProcessID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == nullptr || outDataSize == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    switch (inObjectID) {
        case kPRISMObjectID_PlugIn:
            return PRISM_PlugIn_GetPropertyDataSize(inAddress, inQualifierDataSize,
                                                    inQualifierData, outDataSize);
        case kPRISMObjectID_Device:
            return PRISM_Device_GetPropertyDataSize(inAddress, inQualifierDataSize,
                                                    inQualifierData, outDataSize);
        case kPRISMObjectID_Stream:
            return PRISM_Stream_GetPropertyDataSize(inAddress, inQualifierDataSize,
                                                    inQualifierData, outDataSize);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus PRISM_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32* outDataSize,
                                      void* outData)
{
    (void)inClientProcessID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == nullptr || outDataSize == nullptr || outData == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    switch (inObjectID) {
        case kPRISMObjectID_PlugIn:
            return PRISM_PlugIn_GetPropertyData(inAddress, inQualifierDataSize,
                                                inQualifierData, inDataSize,
                                                outDataSize, outData);
        case kPRISMObjectID_Device:
            return PRISM_Device_GetPropertyData(inAddress, inQualifierDataSize,
                                                inQualifierData, inDataSize,
                                                outDataSize, outData);
        case kPRISMObjectID_Stream:
            return PRISM_Stream_GetPropertyData(inAddress, inQualifierDataSize,
                                                inQualifierData, inDataSize,
                                                outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus PRISM_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      const void* inData)
{
    (void)inClientProcessID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    switch (inObjectID) {
        case kPRISMObjectID_PlugIn:
            return PRISM_PlugIn_SetPropertyData(inAddress, inQualifierDataSize,
                                                inQualifierData, inDataSize, inData);
        case kPRISMObjectID_Device:
            return PRISM_Device_SetPropertyData(inAddress, inQualifierDataSize,
                                                inQualifierData, inDataSize, inData);
        case kPRISMObjectID_Stream:
            return PRISM_Stream_SetPropertyData(inAddress, inQualifierDataSize,
                                                inQualifierData, inDataSize, inData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

// ===========================================================================
// IO dispatch — forwards to the device
// ===========================================================================

static OSStatus PRISM_StartIO(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return PRISM_Device_StartIO();
}

static OSStatus PRISM_StopIO(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inDeviceObjectID,
                             UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return PRISM_Device_StopIO();
}

static OSStatus PRISM_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID,
                                       Float64* outSampleTime,
                                       UInt64* outHostTime,
                                       UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (outSampleTime == nullptr || outHostTime == nullptr || outSeed == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    return PRISM_Device_GetZeroTimeStamp(outSampleTime, outHostTime, outSeed);
}

static OSStatus PRISM_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID,
                                        UInt32 inOperationID,
                                        Boolean* outWillDo,
                                        Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (outWillDo == nullptr || outWillDoInPlace == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    return PRISM_Device_WillDoIOOperation(inOperationID, outWillDo, outWillDoInPlace);
}

static OSStatus PRISM_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID,
                                       UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return PRISM_Device_BeginIOOperation(inOperationID, inIOBufferFrameSize, inIOCycleInfo);
}

static OSStatus PRISM_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID,
                                    AudioObjectID inStreamObjectID,
                                    UInt32 inClientID,
                                    UInt32 inOperationID,
                                    UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                    void* ioMainBuffer,
                                    void* ioSecondaryBuffer)
{
    (void)inClientID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return PRISM_Device_DoIOOperation(inStreamObjectID, inOperationID,
                                      inIOBufferFrameSize, inIOCycleInfo,
                                      ioMainBuffer, ioSecondaryBuffer);
}

static OSStatus PRISM_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID;
    if (inDriver != gPRISM_DriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kPRISMObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return PRISM_Device_EndIOOperation(inOperationID, inIOBufferFrameSize, inIOCycleInfo);
}

// ===========================================================================
// Plug-in object properties
// ===========================================================================

Boolean PRISM_PlugIn_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

OSStatus PRISM_PlugIn_IsPropertySettable(const AudioObjectPropertyAddress* inAddress,
                                         Boolean* outIsSettable)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyResourceBundle:
            *outIsSettable = false;
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus PRISM_PlugIn_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
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
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = 1 * sizeof(AudioObjectID);      // the one device
            return noErr;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;                              // no custom properties
            return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyTranslateUIDToBox:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0;                              // no boxes
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus PRISM_PlugIn_GetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32* outDataSize,
                                      void* outData)
{
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
            *static_cast<AudioClassID*>(outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) {
                return kAudioHardwareBadPropertySizeError;
            }
            // The plug-in is the root of this driver's object tree.
            *static_cast<AudioObjectID*>(outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<CFStringRef*>(outData) = CFSTR(kPRISM_PlugInName);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<CFStringRef*>(outData) = CFSTR(kPRISM_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            // Return as many of the owned objects as fit (there is one).
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            if (capacity >= 1) {
                static_cast<AudioObjectID*>(outData)[0] = kPRISMObjectID_Device;
                *outDataSize = 1 * sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return noErr;
        }

        case kAudioObjectPropertyCustomPropertyInfoList:
            // No custom properties.
            *outDataSize = 0;
            return noErr;

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inDataSize < sizeof(AudioObjectID)) {
                return kAudioHardwareBadPropertySizeError;
            }
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == nullptr) {
                return kAudioHardwareIllegalOperationError;
            }
            CFStringRef uid = *static_cast<const CFStringRef*>(inQualifierData);
            AudioObjectID found = kAudioObjectUnknown;
            if (uid != nullptr &&
                CFStringCompare(uid, CFSTR(kPRISM_DeviceUID), 0) == kCFCompareEqualTo) {
                found = kPRISMObjectID_Device;
            }
            *static_cast<AudioObjectID*>(outData) = found;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        }

        case kAudioPlugInPropertyBoxList:
            // No boxes.
            *outDataSize = 0;
            return noErr;

        case kAudioPlugInPropertyTranslateUIDToBox:
            if (inDataSize < sizeof(AudioObjectID)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *static_cast<AudioObjectID*>(outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) {
                return kAudioHardwareBadPropertySizeError;
            }
            // Empty path = the plug-in bundle itself.
            *static_cast<CFStringRef*>(outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus PRISM_PlugIn_SetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void* inQualifierData,
                                      UInt32 inDataSize,
                                      const void* inData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;
    (void)inDataSize;
    (void)inData;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyResourceBundle:
            return kAudioHardwareUnsupportedOperationError;   // all read-only
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}
