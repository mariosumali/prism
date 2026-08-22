// main.c
// Tools/mic_probe
//
// End-to-end probe of the installed "PRISM Microphone" device: records from
// it through the real HAL, exactly the way Zoom or QuickTime does, and
// reports whether audio actually arrives.
//
// This exists because Tools/driver_smoke cannot catch a whole class of
// defect. driver_smoke calls the driver's entry points directly, so it can
// only ever confirm the driver agrees with the *test's* idea of the
// contract. When both were wrong about `ioMainBuffer` — the test handing
// over an AudioBufferList that coreaudiod never passes — driver_smoke
// reported 49/49 while every real client heard silence. Only a probe that
// goes through the HAL can tell you the device works.
//
// It also prints the shared ring's state alongside the delivered audio, so
// a failure is immediately attributable:
//
//   ring advancing + audio present  → the whole path works
//   ring advancing + silence        → the driver's read/output path is broken
//   ring frozen                     → PRISM.app is not capturing (demand,
//                                     mute, or permissions), driver is fine
//
// Usage: Tools/mic_probe/run.sh [seconds] [--control]
//   --control records from the built-in microphone instead, to prove the
//   probe itself holds microphone permission — a TCC-denied client also
//   receives callbacks full of zeros, which looks identical to a broken
//   device.
//
// Exits 0 when audio was captured, 1 on silence or setup failure.
//
// Licensed under the Apache License, Version 2.0.

#include "SharedTypes.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>

#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PRISM_UID    "horse.prism.PRISM.audio.device"
#define BUILTIN_UID  "BuiltInMicrophoneDevice"

// Anything below this peak over the whole take is "the device sent silence".
// Real rooms sit far above it even when nobody speaks; digital silence is
// exactly 0.
static const float kSilenceThreshold = 1e-7f;

static AudioUnit        gUnit;
static AudioBufferList *gABL;
static float            gPeak;
static double           gSumSq;
static unsigned long long gFrames;
static unsigned long long gCallbacks;

// A damaged or stale HAL plug-in can accept configuration and then never
// finish starting its IO thread. A diagnostic must diagnose that state, not
// become one more process waiting on it forever. Keep the handler strictly
// async-signal-safe: write a fixed message and leave immediately.
static void startTimedOut(int signalNumber) {
    (void)signalNumber;
    static const char message[] =
        "FAIL: AudioOutputUnitStart did not return within 10 seconds.\n"
        "      Core Audio is wedged. Restart it with `sudo killall coreaudiod`;\n"
        "      if only PRISM still fails, run ./rebuild.sh --driver-only.\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(2);
}

static OSStatus inputProc(void *ref, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *ts, UInt32 bus,
                          UInt32 frames, AudioBufferList *unused) {
    (void)ref; (void)unused;
    gABL->mNumberBuffers = 1;
    gABL->mBuffers[0].mNumberChannels = 2;
    gABL->mBuffers[0].mDataByteSize = frames * 2 * sizeof(float);
    OSStatus st = AudioUnitRender(gUnit, flags, ts, bus, frames, gABL);
    if (st != noErr) return st;
    gCallbacks++;
    gFrames += frames;
    const float *s = (const float *)gABL->mBuffers[0].mData;
    for (UInt32 i = 0; i < frames * 2; i++) {
        float v = fabsf(s[i]);
        if (v > gPeak) gPeak = v;
        gSumSq += (double)s[i] * s[i];
    }
    return noErr;
}

static AudioDeviceID findDevice(const char *wantUID, char *outName, size_t n) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL,
                                       &size) != noErr || size == 0) return 0;
    UInt32 count = size / (UInt32)sizeof(AudioDeviceID);
    if (count > 128) count = 128;
    AudioDeviceID ids[128];
    size = count * (UInt32)sizeof(AudioDeviceID);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL,
                                   &size, ids) != noErr) return 0;

    for (UInt32 i = 0; i < count; i++) {
        AudioObjectPropertyAddress ua = {kAudioDevicePropertyDeviceUID,
                                         kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        CFStringRef uid = NULL;
        UInt32 s = sizeof(uid);
        if (AudioObjectGetPropertyData(ids[i], &ua, 0, NULL, &s, &uid) != noErr)
            continue;
        char buf[256] = {0};
        if (uid) {
            CFStringGetCString(uid, buf, sizeof(buf), kCFStringEncodingUTF8);
            CFRelease(uid);
        }
        if (strcmp(buf, wantUID) != 0) continue;

        AudioObjectPropertyAddress na = {kAudioObjectPropertyName,
                                         kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        CFStringRef nm = NULL;
        s = sizeof(nm);
        if (outName && n) {
            outName[0] = '\0';
            if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &s, &nm) == noErr
                && nm) {
                CFStringGetCString(nm, outName, (CFIndex)n, kCFStringEncodingUTF8);
                CFRelease(nm);
            }
        }
        return ids[i];
    }
    return 0;
}

// Read-only view of the producer side. NULL when the region does not exist
// (PRISM.app has never run since boot), which is itself a useful answer.
static PRISMRingBuffer *mapRing(void) {
    int fd = shm_open(PRISM_SHM_NAME, O_RDWR);
    if (fd < 0) return NULL;
    void *m = mmap(NULL, sizeof(PRISMRingBuffer), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    close(fd);
    return m == MAP_FAILED ? NULL : (PRISMRingBuffer *)m;
}

int main(int argc, char **argv) {
    // The probe is commonly run from another script or CI, where stdout is
    // block-buffered. Keep progress visible if a CoreAudio call stalls.
    setvbuf(stdout, NULL, _IOLBF, 0);

    int seconds = 5;
    int control = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--control") == 0) control = 1;
        else if (atoi(argv[i]) > 0) seconds = atoi(argv[i]);
    }
    const char *uid = control ? BUILTIN_UID : PRISM_UID;

    char name[256] = {0};
    AudioDeviceID dev = findDevice(uid, name, sizeof(name));
    if (dev == 0) {
        printf("FAIL: no input device with UID \"%s\".\n", uid);
        if (!control) {
            printf("      The HAL plug-in is not installed or coreaudiod "
                   "rejected it.\n      Run Tools/install_audio.sh.\n");
        }
        return 1;
    }
    printf("device: \"%s\" (id %u, uid %s)\n", name, dev, uid);

    PRISMRingBuffer *rb = mapRing();
    printf("ring:   %s\n\n", rb ? "mapped" : "NOT PRESENT (has PRISM.app run?)");

    AudioComponentDescription desc = {kAudioUnitType_Output,
                                      kAudioUnitSubType_HALOutput,
                                      kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &gUnit) != noErr) {
        printf("FAIL: could not create a HAL output unit.\n");
        return 1;
    }

    UInt32 one = 1, zero = 0;
    OSStatus st;
    if ((st = AudioUnitSetProperty(gUnit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1, &one,
                                   sizeof(one))) != noErr
        || (st = AudioUnitSetProperty(gUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &zero,
                                      sizeof(zero))) != noErr
        || (st = AudioUnitSetProperty(gUnit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &dev,
                                      sizeof(dev))) != noErr) {
        printf("FAIL: could not configure the unit (status %d).\n", (int)st);
        return 1;
    }

    // Interleaved stereo float32 at 48k — what an ordinary client asks for.
    // The HAL converts from the device's format as needed.
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate       = PRISM_SAMPLE_RATE;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel   = 32;
    fmt.mBytesPerFrame    = 8;
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerPacket   = 8;
    if ((st = AudioUnitSetProperty(gUnit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &fmt,
                                   sizeof(fmt))) != noErr) {
        printf("FAIL: device refused a 48k stereo float client format "
               "(status %d).\n", (int)st);
        return 1;
    }

    static unsigned char ablStore[sizeof(AudioBufferList) + sizeof(AudioBuffer)];
    static float scratch[16384 * 2];
    gABL = (AudioBufferList *)ablStore;
    gABL->mBuffers[0].mData = scratch;

    AURenderCallbackStruct cb = {inputProc, NULL};
    if ((st = AudioUnitSetProperty(gUnit,
                                   kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0, &cb,
                                   sizeof(cb))) != noErr
        || (st = AudioUnitInitialize(gUnit)) != noErr) {
        printf("FAIL: could not start capture (status %d).\n", (int)st);
        return 1;
    }

    signal(SIGALRM, startTimedOut);
    alarm(10);
    st = AudioOutputUnitStart(gUnit);
    alarm(0);
    if (st != noErr) {
        printf("FAIL: could not start capture (status %d).\n", (int)st);
        return 1;
    }

    printf("recording %ds — make some noise%s\n", seconds,
           control ? "" : " (PRISM must be capturing)");
    unsigned long long prevWrite = rb ? atomic_load(&rb->writeIndex) : 0;
    for (int i = 0; i < seconds; i++) {
        float before = gPeak;
        sleep(1);
        if (rb) {
            unsigned long long w = atomic_load(&rb->writeIndex);
            printf("  t=%2ds  delivered peak=%.6f   ring +%llu frames%s\n",
                   i + 1, gPeak,
                   w - prevWrite,
                   (w == prevWrite) ? "  <- producer idle" : "");
            prevWrite = w;
        } else {
            printf("  t=%2ds  delivered peak=%.6f\n", i + 1, gPeak);
        }
        (void)before;
    }

    AudioOutputUnitStop(gUnit);
    AudioUnitUninitialize(gUnit);
    AudioComponentInstanceDispose(gUnit);

    double rms = gFrames ? sqrt(gSumSq / (double)(gFrames * 2)) : 0;
    printf("\n%llu callbacks, %llu frames, peak=%.6f rms=%.6f\n",
           gCallbacks, gFrames, gPeak, rms);

    if (gCallbacks == 0) {
        printf("FAIL: the device never delivered an IO cycle.\n");
        return 1;
    }
    if (gPeak <= kSilenceThreshold) {
        printf("FAIL: pure silence.\n");
        if (rb && atomic_load(&rb->producerAlive)) {
            printf("      The ring %s. If it advanced, the driver's read or\n"
                   "      output path is at fault; if it stayed put, PRISM.app\n"
                   "      is not capturing (demand, mute, or permissions).\n",
                   "counters are printed above");
        }
        printf("      Re-run with --control to confirm this probe itself has\n"
               "      microphone permission; a denied client also gets zeros.\n");
        return 1;
    }
    printf("PASS: audio captured.\n");
    return 0;
}
