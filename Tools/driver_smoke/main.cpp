// main.cpp
// Tools/driver_smoke
//
// In-process smoke test for the PRISM AudioServerPlugIn HAL driver — the
// SPEC §4 verification that coreaudiod would accept the plug-in. Links the
// driver sources directly (no bundle loading) and exercises, in order:
//
//   1. PRISM_CreatePlugIn(kAudioServerPlugInTypeUUID) + COM plumbing:
//      QueryInterface for kAudioServerPlugInDriverInterfaceUUID, AddRef /
//      Release refcount sanity.
//   2. Initialize with a minimal stub AudioServerPlugInHostRef.
//   3. Property walk asserting SPEC §4.2 exactly (device name / UID /
//      transport / safety offset / zero-timestamp period / sample rates /
//      stream topology / stream virtual format). Expected values are
//      hardcoded here on purpose — independent of the driver's constants —
//      so drift in the driver is caught.
//   4. A full IO cycle against the real SHM ring: producer writes a known
//      ramp, StartIO → GetZeroTimeStamp → Begin/Do/EndIOOperation into the
//      raw interleaved IO buffer coreaudiod actually passes, then sample
//      verification. The buffer is deliberately NOT an AudioBufferList —
//      that is the whole point of the check.
//   4b. Anchor self-healing when the producer starts after StartIO.
//   5. Silence-when-dead: producerAlive = 0 must yield all zeros.
//   6. StopIO + final Release with refcount-underflow checks. (The
//      AudioServerPlugInDriverInterface has no Deinitialize entry point;
//      teardown is Release-only.)
//
// Every assertion prints PASS/FAIL with detail; the process exits nonzero
// on any FAIL. The SHM region is shm_unlink'ed at start and end so runs
// are hermetic.
//
// Licensed under the Apache License, Version 2.0.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>

#include <mach/mach_time.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstring>

#include "SharedTypes.h"
#include "RingBuffer.h"

// The factory is declared only in PRISM_PlugIn.cpp; declare it here.
extern "C" void* PRISM_CreatePlugIn(CFAllocatorRef inAllocator,
                                    CFUUIDRef inRequestedTypeUUID);

// ===========================================================================
// Expected values — SPEC §4.2 / CONTRACTS, hardcoded independently of the
// driver's own constants.
// ===========================================================================

static const char*   kExpectedDeviceName   = "PRISM Microphone";
static const char*   kExpectedDeviceUID    = "horse.prism.PRISM.audio.device";
static const UInt32  kExpectedSafetyOffset = 512;
static const UInt32  kExpectedZTSPeriod    = 4096;
static const Float64 kExpectedSampleRate   = 48000.0;
static const UInt32  kExpectedChannels     = 2;
static const AudioObjectID kExpectedPlugInID = 1;   // kAudioObjectPlugInObject
static const AudioObjectID kExpectedDeviceID = 2;
static const AudioObjectID kExpectedStreamID = 3;

static const UInt32 kIOFrames = 512;                 // one client IO buffer

// ===========================================================================
// PASS/FAIL plumbing
// ===========================================================================

static int gFailures = 0;
static int gChecks   = 0;

__attribute__((format(printf, 2, 3)))
static void check(bool ok, const char* fmt, ...)
{
    ++gChecks;
    if (!ok) {
        ++gFailures;
    }
    std::fputs(ok ? "PASS: " : "FAIL: ", stdout);
    va_list args;
    va_start(args, fmt);
    std::vprintf(fmt, args);
    va_end(args);
    std::fputc('\n', stdout);
}

// ===========================================================================
// Minimal stub host — no-op implementations of the five host entry points
// (shape per CoreAudio/AudioServerPlugIn.h's AudioServerPlugInHostInterface).
// ===========================================================================

static OSStatus StubPropertiesChanged(AudioServerPlugInHostRef,
                                      AudioObjectID,
                                      UInt32,
                                      const AudioObjectPropertyAddress*)
{
    return noErr;
}

static OSStatus StubCopyFromStorage(AudioServerPlugInHostRef,
                                    CFStringRef,
                                    CFPropertyListRef* outData)
{
    if (outData != nullptr) {
        *outData = nullptr;
    }
    return kAudioHardwareUnknownPropertyError;   // "nothing stored"
}

static OSStatus StubWriteToStorage(AudioServerPlugInHostRef,
                                   CFStringRef,
                                   CFPropertyListRef)
{
    return noErr;
}

static OSStatus StubDeleteFromStorage(AudioServerPlugInHostRef, CFStringRef)
{
    return noErr;
}

static OSStatus StubRequestDeviceConfigurationChange(AudioServerPlugInHostRef,
                                                     AudioObjectID,
                                                     UInt64,
                                                     void*)
{
    return noErr;
}

static AudioServerPlugInHostInterface gStubHost = {
    StubPropertiesChanged,
    StubCopyFromStorage,
    StubWriteToStorage,
    StubDeleteFromStorage,
    StubRequestDeviceConfigurationChange,
};

// ===========================================================================
// Property helpers
// ===========================================================================

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel,
                                       AudioObjectPropertyScope scope
                                           = kAudioObjectPropertyScopeGlobal)
{
    AudioObjectPropertyAddress a;
    a.mSelector = sel;
    a.mScope    = scope;
    a.mElement  = kAudioObjectPropertyElementMain;
    return a;
}

static OSStatus getPropSize(AudioServerPlugInDriverRef drv, AudioObjectID obj,
                            const AudioObjectPropertyAddress& a, UInt32* outSize)
{
    return (*drv)->GetPropertyDataSize(drv, obj, getpid(), &a, 0, nullptr, outSize);
}

static OSStatus getProp(AudioServerPlugInDriverRef drv, AudioObjectID obj,
                        const AudioObjectPropertyAddress& a,
                        UInt32 inSize, UInt32* outSize, void* outData)
{
    return (*drv)->GetPropertyData(drv, obj, getpid(), &a, 0, nullptr,
                                   inSize, outSize, outData);
}

static bool cfstringEquals(CFStringRef s, const char* expected, char* buf, size_t bufLen)
{
    buf[0] = '\0';
    if (s == nullptr) {
        std::snprintf(buf, bufLen, "(null CFString)");
        return false;
    }
    if (!CFStringGetCString(s, buf, static_cast<CFIndex>(bufLen),
                            kCFStringEncodingUTF8)) {
        std::snprintf(buf, bufLen, "(unconvertible CFString)");
        return false;
    }
    return std::strcmp(buf, expected) == 0;
}

// Fetch a CFString property, compare against `expected`, print PASS/FAIL.
static void checkStringProp(AudioServerPlugInDriverRef drv, AudioObjectID obj,
                            AudioObjectPropertySelector sel,
                            const char* label, const char* expected)
{
    CFStringRef value = nullptr;
    UInt32 outSize = 0;
    OSStatus st = getProp(drv, obj, addr(sel), sizeof(CFStringRef), &outSize, &value);
    char buf[256];
    bool ok = (st == noErr)
           && (outSize == sizeof(CFStringRef))
           && cfstringEquals(value, expected, buf, sizeof(buf));
    check(ok, "%s == \"%s\" (status=%d, got \"%s\")",
          label, expected, static_cast<int>(st), buf);
    if (value != nullptr) {
        CFRelease(value);   // HAL convention: caller owns returned CFObjects
    }
}

static void checkUInt32Prop(AudioServerPlugInDriverRef drv, AudioObjectID obj,
                            const AudioObjectPropertyAddress& a,
                            const char* label, UInt32 expected)
{
    UInt32 value = 0xDEADBEEF;
    UInt32 outSize = 0;
    OSStatus st = getProp(drv, obj, a, sizeof(UInt32), &outSize, &value);
    check(st == noErr && outSize == sizeof(UInt32) && value == expected,
          "%s == %u (status=%d, size=%u, got %u)",
          label, static_cast<unsigned>(expected), static_cast<int>(st),
          static_cast<unsigned>(outSize), static_cast<unsigned>(value));
}

// ===========================================================================
// main
// ===========================================================================

int main()
{
    std::printf("=== PRISM AudioServerPlugIn driver smoke test ===\n");

    // Hermetic start: remove any leftover SHM region from a previous run.
    shm_unlink(PRISM_SHM_NAME);

    // -----------------------------------------------------------------------
    // 1. Factory + COM plumbing
    // -----------------------------------------------------------------------

    std::printf("--- 1. Factory / QueryInterface / refcount ---\n");

    // Wrong type UUID must be refused.
    void* wrongType = PRISM_CreatePlugIn(kCFAllocatorDefault, IUnknownUUID);
    check(wrongType == nullptr,
          "PRISM_CreatePlugIn(wrong type UUID) returns NULL (got %p)", wrongType);

    void* factoryResult =
        PRISM_CreatePlugIn(kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    check(factoryResult != nullptr,
          "PRISM_CreatePlugIn(kAudioServerPlugInTypeUUID) returns a driver ref");
    if (factoryResult == nullptr) {
        std::printf("=== ABORT: no driver ref; %d checks, %d failures ===\n",
                    gChecks, gFailures);
        return 1;
    }
    // Refcount is now 1 (factory reference).

    AudioServerPlugInDriverRef driver =
        static_cast<AudioServerPlugInDriverRef>(factoryResult);

    // QueryInterface for the driver interface → refcount 2.
    LPVOID iface = nullptr;
    HRESULT hr = (*driver)->QueryInterface(
        driver, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface);
    check(hr == S_OK && iface == static_cast<LPVOID>(driver),
          "QueryInterface(kAudioServerPlugInDriverInterfaceUUID) == S_OK, same ref "
          "(hr=0x%lx, iface=%p, driver=%p)",
          static_cast<unsigned long>(hr), iface, static_cast<void*>(driver));

    // QueryInterface for an unrelated UUID → E_NOINTERFACE, NULL out.
    CFUUIDRef bogus = CFUUIDCreateFromString(nullptr,
        CFSTR("00000000-1111-2222-3333-444444444444"));
    LPVOID bogusIface = reinterpret_cast<LPVOID>(0x1);
    HRESULT bogusHr = (*driver)->QueryInterface(
        driver, CFUUIDGetUUIDBytes(bogus), &bogusIface);
    CFRelease(bogus);
    check(bogusHr == E_NOINTERFACE && bogusIface == nullptr,
          "QueryInterface(unknown UUID) == E_NOINTERFACE with NULL out "
          "(hr=0x%lx, out=%p)",
          static_cast<unsigned long>(bogusHr), bogusIface);

    // AddRef/Release sanity: 2 → 3 → 2 → 1 (drop the QueryInterface ref).
    ULONG rc = (*driver)->AddRef(driver);
    check(rc == 3, "AddRef returns 3 (factory + QI + AddRef) (got %lu)",
          static_cast<unsigned long>(rc));
    rc = (*driver)->Release(driver);
    check(rc == 2, "Release returns 2 (got %lu)", static_cast<unsigned long>(rc));
    rc = (*driver)->Release(driver);
    check(rc == 1, "Release (QI ref) returns 1 (got %lu)",
          static_cast<unsigned long>(rc));

    // -----------------------------------------------------------------------
    // 2. Initialize with the stub host
    // -----------------------------------------------------------------------

    std::printf("--- 2. Initialize ---\n");

    OSStatus st = (*driver)->Initialize(driver, &gStubHost);
    check(st == noErr, "Initialize(stub host) == noErr (got %d)",
          static_cast<int>(st));

    // -----------------------------------------------------------------------
    // 3. Property walk — SPEC §4.2 exactly
    // -----------------------------------------------------------------------

    std::printf("--- 3. Property walk (SPEC §4.2) ---\n");

    // Plug-in owns exactly one device; discover its ID the way the HAL would.
    UInt32 size = 0;
    st = getPropSize(driver, kExpectedPlugInID,
                     addr(kAudioPlugInPropertyDeviceList), &size);
    check(st == noErr && size == sizeof(AudioObjectID),
          "plug-in device list size == 1 device (status=%d, size=%u)",
          static_cast<int>(st), static_cast<unsigned>(size));

    AudioObjectID deviceList[4] = {0, 0, 0, 0};
    UInt32 outSize = 0;
    st = getProp(driver, kExpectedPlugInID, addr(kAudioPlugInPropertyDeviceList),
                 sizeof(deviceList), &outSize, deviceList);
    check(st == noErr && outSize == sizeof(AudioObjectID)
              && deviceList[0] == kExpectedDeviceID,
          "plug-in owns exactly one device, ID %u (status=%d, count=%u, first=%u)",
          static_cast<unsigned>(kExpectedDeviceID), static_cast<int>(st),
          static_cast<unsigned>(outSize / sizeof(AudioObjectID)),
          static_cast<unsigned>(deviceList[0]));
    const AudioObjectID deviceID = deviceList[0] != 0 ? deviceList[0]
                                                      : kExpectedDeviceID;

    // Device name / UID.
    checkStringProp(driver, deviceID, kAudioObjectPropertyName,
                    "device name", kExpectedDeviceName);
    checkStringProp(driver, deviceID, kAudioDevicePropertyDeviceUID,
                    "device UID", kExpectedDeviceUID);

    // Transport type: virtual.
    checkUInt32Prop(driver, deviceID, addr(kAudioDevicePropertyTransportType),
                    "transport type == kAudioDeviceTransportTypeVirtual",
                    kAudioDeviceTransportTypeVirtual);

    // Safety offset (input scope): 512.
    checkUInt32Prop(driver, deviceID,
                    addr(kAudioDevicePropertySafetyOffset,
                         kAudioObjectPropertyScopeInput),
                    "safety offset (input scope)", kExpectedSafetyOffset);

    // Zero-timestamp period: 4096.
    checkUInt32Prop(driver, deviceID,
                    addr(kAudioDevicePropertyZeroTimeStampPeriod),
                    "zero-timestamp period", kExpectedZTSPeriod);

    // Nominal sample rate: 48000.
    {
        Float64 rate = 0.0;
        st = getProp(driver, deviceID, addr(kAudioDevicePropertyNominalSampleRate),
                     sizeof(Float64), &outSize, &rate);
        check(st == noErr && outSize == sizeof(Float64)
                  && rate == kExpectedSampleRate,
              "nominal sample rate == 48000 (status=%d, got %.1f)",
              static_cast<int>(st), rate);
    }

    // Available nominal sample rates: exactly one range, min == max == 48000.
    {
        st = getPropSize(driver, deviceID,
                         addr(kAudioDevicePropertyAvailableNominalSampleRates),
                         &size);
        check(st == noErr && size == sizeof(AudioValueRange),
              "available sample rates: exactly one entry (status=%d, size=%u)",
              static_cast<int>(st), static_cast<unsigned>(size));

        AudioValueRange ranges[4];
        std::memset(ranges, 0, sizeof(ranges));
        st = getProp(driver, deviceID,
                     addr(kAudioDevicePropertyAvailableNominalSampleRates),
                     sizeof(ranges), &outSize, ranges);
        check(st == noErr && outSize == sizeof(AudioValueRange)
                  && ranges[0].mMinimum == kExpectedSampleRate
                  && ranges[0].mMaximum == kExpectedSampleRate,
              "available sample rates contain only 48000 "
              "(status=%d, count=%u, [%.1f, %.1f])",
              static_cast<int>(st),
              static_cast<unsigned>(outSize / sizeof(AudioValueRange)),
              ranges[0].mMinimum, ranges[0].mMaximum);
    }

    // Exactly one input stream, zero output streams.
    AudioObjectID streamID = kExpectedStreamID;
    {
        AudioObjectID streams[4] = {0, 0, 0, 0};
        st = getProp(driver, deviceID,
                     addr(kAudioDevicePropertyStreams,
                          kAudioObjectPropertyScopeInput),
                     sizeof(streams), &outSize, streams);
        check(st == noErr && outSize == sizeof(AudioObjectID)
                  && streams[0] == kExpectedStreamID,
              "exactly one input stream, ID %u (status=%d, count=%u, first=%u)",
              static_cast<unsigned>(kExpectedStreamID), static_cast<int>(st),
              static_cast<unsigned>(outSize / sizeof(AudioObjectID)),
              static_cast<unsigned>(streams[0]));
        if (streams[0] != 0) {
            streamID = streams[0];
        }

        st = getPropSize(driver, deviceID,
                         addr(kAudioDevicePropertyStreams,
                              kAudioObjectPropertyScopeOutput),
                         &size);
        check(st == noErr && size == 0,
              "zero output streams (status=%d, size=%u)",
              static_cast<int>(st), static_cast<unsigned>(size));
    }

    // Stream direction: input (1).
    checkUInt32Prop(driver, streamID, addr(kAudioStreamPropertyDirection),
                    "stream direction == input (1)", 1);

    // Stream virtual format: 48 kHz, 2 ch, float32, non-interleaved, packed,
    // native-endian — the exact ASBD of SPEC §4.2.
    {
        // Interleaved: an AudioServerPlugIn's IO buffer is one raw block of
        // sample data, so a non-interleaved stream format has nowhere to put
        // its second plane.
        const UInt32 expectedFlags = kAudioFormatFlagIsFloat
                                   | kAudioFormatFlagsNativeEndian
                                   | kAudioFormatFlagIsPacked;
        AudioStreamBasicDescription asbd;
        std::memset(&asbd, 0, sizeof(asbd));
        st = getProp(driver, streamID, addr(kAudioStreamPropertyVirtualFormat),
                     sizeof(asbd), &outSize, &asbd);
        check(st == noErr && outSize == sizeof(asbd),
              "stream virtual format readable (status=%d, size=%u)",
              static_cast<int>(st), static_cast<unsigned>(outSize));
        check(asbd.mFormatID == kAudioFormatLinearPCM,
              "virtual format ID == LinearPCM (got '%c%c%c%c')",
              static_cast<char>(asbd.mFormatID >> 24),
              static_cast<char>(asbd.mFormatID >> 16),
              static_cast<char>(asbd.mFormatID >> 8),
              static_cast<char>(asbd.mFormatID));
        check(asbd.mFormatFlags == expectedFlags,
              "virtual format flags == Float|NativeEndian|Packed, interleaved "
              "(expected 0x%x, got 0x%x)",
              static_cast<unsigned>(expectedFlags),
              static_cast<unsigned>(asbd.mFormatFlags));
        check(asbd.mSampleRate == kExpectedSampleRate,
              "virtual format sample rate == 48000 (got %.1f)", asbd.mSampleRate);
        check(asbd.mChannelsPerFrame == kExpectedChannels,
              "virtual format channels == 2 (got %u)",
              static_cast<unsigned>(asbd.mChannelsPerFrame));
        check(asbd.mBitsPerChannel == 32,
              "virtual format bits per channel == 32 (got %u)",
              static_cast<unsigned>(asbd.mBitsPerChannel));
        // Interleaved: one 8-byte frame carries both channels.
        check(asbd.mBytesPerFrame == kExpectedChannels * sizeof(Float32)
                  && asbd.mBytesPerPacket == kExpectedChannels * sizeof(Float32)
                  && asbd.mFramesPerPacket == 1,
              "virtual format packing: 8 bytes/frame (interleaved stereo), "
              "1 frame/packet (got bpf=%u bpp=%u fpp=%u)",
              static_cast<unsigned>(asbd.mBytesPerFrame),
              static_cast<unsigned>(asbd.mBytesPerPacket),
              static_cast<unsigned>(asbd.mFramesPerPacket));
    }

    // -----------------------------------------------------------------------
    // 4. IO cycle — ramp through the SHM ring
    // -----------------------------------------------------------------------

    std::printf("--- 4. IO cycle (ramp through SHM ring) ---\n");

    // The consumer side (the driver) mapped/created the ring in Initialize;
    // this producer mapping adopts the same region.
    PRISMRingBuffer* ring = PRISMRingBufferCreateProducer();
    check(ring != nullptr, "PRISMRingBufferCreateProducer maps the shared ring");
    if (ring == nullptr) {
        std::printf("=== ABORT: no ring; %d checks, %d failures ===\n",
                    gChecks, gFailures);
        shm_unlink(PRISM_SHM_NAME);
        return 1;
    }

    st = (*driver)->StartIO(driver, deviceID, 0);
    check(st == noErr, "StartIO == noErr (got %d)", static_cast<int>(st));

    // Write the ramp AFTER StartIO: StartIO deliberately parks the ring's
    // read cursor at the write cursor (stale-backlog flush, so the first
    // cycles deliver fresh audio) — anything written earlier would be
    // skipped by design.
    float ramp[kIOFrames * kExpectedChannels];
    for (UInt32 i = 0; i < kIOFrames * kExpectedChannels; ++i) {
        ramp[i] = static_cast<float>(i);
    }
    PRISMRingBufferWrite(ring, ramp, kIOFrames);
    check(PRISMRingBufferFillLevel(ring) == kIOFrames,
          "ring fill level == %u after ramp write (got %llu)",
          static_cast<unsigned>(kIOFrames),
          static_cast<unsigned long long>(PRISMRingBufferFillLevel(ring)));

    // GetZeroTimeStamp: freshly anchored → sample time 0, valid seed, host
    // time in the past-or-present.
    {
        Float64 sampleTime = -1.0;
        UInt64 hostTime = 0, seed = 0;
        st = (*driver)->GetZeroTimeStamp(driver, deviceID, 0,
                                         &sampleTime, &hostTime, &seed);
        check(st == noErr && sampleTime == 0.0 && seed != 0
                  && hostTime != 0 && hostTime <= mach_absolute_time(),
              "GetZeroTimeStamp: sampleTime 0, nonzero seed, anchored host time "
              "(status=%d, sampleTime=%.1f, seed=%llu)",
              static_cast<int>(st), sampleTime,
              static_cast<unsigned long long>(seed));

        // The zero timestamp must advance by one 4096-frame period within
        // ~85ms; allow 400ms of slack.
        Float64 advanced = 0.0;
        for (int i = 0; i < 80; ++i) {
            usleep(5000);
            (*driver)->GetZeroTimeStamp(driver, deviceID, 0,
                                        &advanced, &hostTime, &seed);
            if (advanced >= static_cast<Float64>(kExpectedZTSPeriod)) {
                break;
            }
        }
        check(advanced == static_cast<Float64>(kExpectedZTSPeriod),
              "zero timestamp advances by exactly one 4096-frame period "
              "(got %.1f)", advanced);
    }

    // WillDoIOOperation: ReadInput only.
    {
        Boolean willDo = false, inPlace = false;
        st = (*driver)->WillDoIOOperation(driver, deviceID, 0,
                                          kAudioServerPlugInIOOperationReadInput,
                                          &willDo, &inPlace);
        check(st == noErr && willDo,
              "WillDoIOOperation(ReadInput) == true (status=%d, willDo=%d)",
              static_cast<int>(st), willDo);
        st = (*driver)->WillDoIOOperation(driver, deviceID, 0,
                                          kAudioServerPlugInIOOperationWriteMix,
                                          &willDo, &inPlace);
        check(st == noErr && !willDo,
              "WillDoIOOperation(WriteMix) == false (status=%d, willDo=%d)",
              static_cast<int>(st), willDo);
    }

    // The IO buffer exactly as coreaudiod passes it: ONE raw block of
    // interleaved sample data in the stream's physical format — never an
    // AudioBufferList. Building an ABL here (as this test did originally)
    // hides the defect it exists to catch: a driver that reads ioMainBuffer
    // as an ABL finds mNumberBuffers = 0 in a HAL-zeroed buffer, writes
    // nothing, and ships silence to every real client while passing here.
    //
    // Sentinel-filled before each cycle so untouched output is detectable;
    // `left`/`right` are read back through the interleave.
    float ioBuffer[kIOFrames * kExpectedChannels];
    auto left  = [&](UInt32 f) { return ioBuffer[f * kExpectedChannels]; };
    auto right = [&](UInt32 f) { return ioBuffer[f * kExpectedChannels + 1]; };
    void* const abl = ioBuffer;      // what DoIOOperation receives

    auto resetABL = [&](float sentinel) {
        for (UInt32 i = 0; i < kIOFrames * kExpectedChannels; ++i) {
            ioBuffer[i] = sentinel;
        }
    };

    AudioServerPlugInIOCycleInfo cycle;
    std::memset(&cycle, 0, sizeof(cycle));
    cycle.mIOCycleCounter = 1;
    cycle.mNominalIOBufferFrameSize = kIOFrames;

    resetABL(12345.0f);
    st = (*driver)->BeginIOOperation(driver, deviceID, 0,
                                     kAudioServerPlugInIOOperationReadInput,
                                     kIOFrames, &cycle);
    check(st == noErr, "BeginIOOperation == noErr (got %d)", static_cast<int>(st));

    st = (*driver)->DoIOOperation(driver, deviceID, streamID, 0,
                                  kAudioServerPlugInIOOperationReadInput,
                                  kIOFrames, &cycle, abl, nullptr);
    check(st == noErr, "DoIOOperation(ReadInput) == noErr (got %d)",
          static_cast<int>(st));

    st = (*driver)->EndIOOperation(driver, deviceID, 0,
                                   kAudioServerPlugInIOOperationReadInput,
                                   kIOFrames, &cycle);
    check(st == noErr, "EndIOOperation == noErr (got %d)", static_cast<int>(st));

    // De-interleave check: L channel = even samples of the interleaved ramp,
    // R channel = odd samples.
    {
        UInt32 badL = 0, badR = 0;
        UInt32 firstBad = kIOFrames;
        for (UInt32 f = 0; f < kIOFrames; ++f) {
            const float expectL = static_cast<float>(2 * f);
            const float expectR = static_cast<float>(2 * f + 1);
            if (left(f) != expectL) {
                ++badL;
                if (firstBad == kIOFrames) firstBad = f;
            }
            if (right(f) != expectR) {
                ++badR;
                if (firstBad == kIOFrames) firstBad = f;
            }
        }
        if (badL == 0 && badR == 0) {
            check(true, "ramp de-interleaved correctly: L = even samples, "
                        "R = odd samples (%u frames)",
                  static_cast<unsigned>(kIOFrames));
        } else {
            check(false, "ramp de-interleave mismatch: %u bad L, %u bad R; "
                         "first bad frame %u (L=%.1f R=%.1f, expected L=%.1f R=%.1f)",
                  static_cast<unsigned>(badL), static_cast<unsigned>(badR),
                  static_cast<unsigned>(firstBad),
                  left(firstBad < kIOFrames ? firstBad : 0),
                  right(firstBad < kIOFrames ? firstBad : 0),
                  static_cast<float>(2 * (firstBad < kIOFrames ? firstBad : 0)),
                  static_cast<float>(2 * (firstBad < kIOFrames ? firstBad : 0) + 1));
        }
        check(PRISMRingBufferUnderrunCount(ring) == 0,
              "no underrun reading exactly what was written (count=%u)",
              PRISMRingBufferUnderrunCount(ring));
    }

    // -----------------------------------------------------------------------
    // 4b. Anchor self-healing — producer behind the device clock
    // -----------------------------------------------------------------------
    //
    // Regression for the flow that ships silence forever: a client StartIOs
    // (anchoring sample time 0 at the then-current write index) while the
    // producer is not yet streaming, so every window the device clock asks
    // for sits ahead of the write head. The driver must slide its anchor to
    // land kPRISM_ReanchorCushionFrames behind the write head, deliver real
    // frames in that very cycle, and keep the healed mapping stable across
    // the next contiguous cycle.

    std::printf("--- 4b. Anchor self-healing (late producer) ---\n");

    {
        const UInt32 kPatternFrames = 4096;
        const float  kPatternBase   = 100000.0f;
        static float pattern[kPatternFrames * kExpectedChannels];
        for (UInt32 i = 0; i < kPatternFrames * kExpectedChannels; ++i) {
            pattern[i] = kPatternBase + static_cast<float>(i);
        }
        PRISMRingBufferWrite(ring, pattern, kPatternFrames);
        // Ring timeline: [0, 512) ramp, [512, 4608) pattern; write head 4608.

        const UInt32 underrunsBefore = PRISMRingBufferUnderrunCount(ring);

        // A cycle whose sample time is far past anything the producer has
        // written — the device clock ran while the producer did not.
        const Float64 kLateSampleTime = 50000.0;
        AudioServerPlugInIOCycleInfo lateCycle;
        std::memset(&lateCycle, 0, sizeof(lateCycle));
        lateCycle.mIOCycleCounter = 2;
        lateCycle.mNominalIOBufferFrameSize = kIOFrames;
        lateCycle.mInputTime.mSampleTime = kLateSampleTime;

        resetABL(424242.0f);
        (*driver)->BeginIOOperation(driver, deviceID, 0,
                                    kAudioServerPlugInIOOperationReadInput,
                                    kIOFrames, &lateCycle);
        st = (*driver)->DoIOOperation(driver, deviceID, streamID, 0,
                                      kAudioServerPlugInIOOperationReadInput,
                                      kIOFrames, &lateCycle, abl, nullptr);
        (*driver)->EndIOOperation(driver, deviceID, 0,
                                  kAudioServerPlugInIOOperationReadInput,
                                  kIOFrames, &lateCycle);

        // Healed mapping: window end = writeHead − cushion = 4608 − 1024 =
        // 3584, so the window is ring positions [3072, 3584) — pattern
        // frames 2560…3071.
        UInt32 bad = 0;
        UInt32 firstBad = kIOFrames;
        for (UInt32 f = 0; f < kIOFrames; ++f) {
            const UInt32 patternFrame = 3072 + f - 512;
            const float expectL = kPatternBase + static_cast<float>(2 * patternFrame);
            const float expectR = expectL + 1.0f;
            if (left(f) != expectL || right(f) != expectR) {
                ++bad;
                if (firstBad == kIOFrames) firstBad = f;
            }
        }
        check(st == noErr && bad == 0,
              "late-producer cycle heals the anchor and delivers audio "
              "(status=%d, %u bad frames, first bad %u: L=%.1f expected %.1f)",
              static_cast<int>(st), static_cast<unsigned>(bad),
              static_cast<unsigned>(firstBad),
              firstBad < kIOFrames ? left(firstBad) : -1.0f,
              kPatternBase + static_cast<float>(2 * (3072 + (firstBad < kIOFrames ? firstBad : 0) - 512)));

        // The healed read must not have been billed as an underrun.
        check(PRISMRingBufferUnderrunCount(ring) == underrunsBefore,
              "healed cycle counts no underrun (before=%u, after=%u)",
              static_cast<unsigned>(underrunsBefore),
              PRISMRingBufferUnderrunCount(ring));

        // The next contiguous cycle must reuse the healed anchor: same
        // mapping, no second slide, seamless continuation at [3584, 4096).
        lateCycle.mIOCycleCounter = 3;
        lateCycle.mInputTime.mSampleTime = kLateSampleTime + kIOFrames;

        resetABL(424242.0f);
        (*driver)->BeginIOOperation(driver, deviceID, 0,
                                    kAudioServerPlugInIOOperationReadInput,
                                    kIOFrames, &lateCycle);
        st = (*driver)->DoIOOperation(driver, deviceID, streamID, 0,
                                      kAudioServerPlugInIOOperationReadInput,
                                      kIOFrames, &lateCycle, abl, nullptr);
        (*driver)->EndIOOperation(driver, deviceID, 0,
                                  kAudioServerPlugInIOOperationReadInput,
                                  kIOFrames, &lateCycle);

        bad = 0;
        firstBad = kIOFrames;
        for (UInt32 f = 0; f < kIOFrames; ++f) {
            const UInt32 patternFrame = 3584 + f - 512;
            const float expectL = kPatternBase + static_cast<float>(2 * patternFrame);
            const float expectR = expectL + 1.0f;
            if (left(f) != expectL || right(f) != expectR) {
                ++bad;
                if (firstBad == kIOFrames) firstBad = f;
            }
        }
        check(st == noErr && bad == 0,
              "following cycle continues seamlessly on the healed anchor "
              "(status=%d, %u bad frames, first bad %u)",
              static_cast<int>(st), static_cast<unsigned>(bad),
              static_cast<unsigned>(firstBad));
        check(PRISMRingBufferUnderrunCount(ring) == underrunsBefore,
              "contiguous healed cycle counts no underrun (before=%u, after=%u)",
              static_cast<unsigned>(underrunsBefore),
              PRISMRingBufferUnderrunCount(ring));
    }

    // -----------------------------------------------------------------------
    // 5. Silence when the producer is dead
    // -----------------------------------------------------------------------

    std::printf("--- 5. Silence-when-dead ---\n");

    // Refill the ring so silence can only come from the liveness gate, then
    // mark the producer dead.
    PRISMRingBufferWrite(ring, ramp, kIOFrames);
    PRISMRingBufferSetProducerAlive(ring, false);

    resetABL(777.0f);
    (*driver)->BeginIOOperation(driver, deviceID, 0,
                                kAudioServerPlugInIOOperationReadInput,
                                kIOFrames, &cycle);
    st = (*driver)->DoIOOperation(driver, deviceID, streamID, 0,
                                  kAudioServerPlugInIOOperationReadInput,
                                  kIOFrames, &cycle, abl, nullptr);
    (*driver)->EndIOOperation(driver, deviceID, 0,
                              kAudioServerPlugInIOOperationReadInput,
                              kIOFrames, &cycle);
    {
        UInt32 nonZero = 0;
        for (UInt32 f = 0; f < kIOFrames; ++f) {
            if (left(f) != 0.0f) ++nonZero;
            if (right(f) != 0.0f) ++nonZero;
        }
        check(st == noErr && nonZero == 0,
              "producerAlive=0 → DoIOOperation outputs pure silence "
              "(status=%d, %u nonzero samples of %u)",
              static_cast<int>(st), static_cast<unsigned>(nonZero),
              static_cast<unsigned>(2 * kIOFrames));
    }

    // -----------------------------------------------------------------------
    // 6. Teardown — StopIO + final Release, no refcount underflow
    // -----------------------------------------------------------------------

    std::printf("--- 6. Teardown ---\n");

    st = (*driver)->StopIO(driver, deviceID, 0);
    check(st == noErr, "StopIO == noErr (got %d)", static_cast<int>(st));

    // Unbalanced StopIO must be rejected, not underflow the running count.
    st = (*driver)->StopIO(driver, deviceID, 0);
    check(st != noErr, "extra StopIO rejected (got %d)", static_cast<int>(st));

    // The AudioServerPlugInDriverInterface has no Deinitialize entry point;
    // coreaudiod tears a driver down via Release alone.
    rc = (*driver)->Release(driver);   // factory ref: 1 → 0
    check(rc == 0, "final Release returns 0 (got %lu)",
          static_cast<unsigned long>(rc));
    rc = (*driver)->Release(driver);   // over-release must not underflow
    check(rc == 0, "over-Release clamps at 0, no underflow (got %lu)",
          static_cast<unsigned long>(rc));

    PRISMRingBufferCloseProducer(ring);

    // Hermetic end.
    shm_unlink(PRISM_SHM_NAME);

    std::printf("=== %d checks, %d failure%s ===\n",
                gChecks, gFailures, gFailures == 1 ? "" : "s");
    return gFailures == 0 ? 0 : 1;
}
