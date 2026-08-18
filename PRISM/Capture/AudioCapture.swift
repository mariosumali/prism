// AudioCapture.swift
// PRISM
//
// HAL input AudioUnit wrapper (SPEC §4.4, §5.1, §7). Pulls from the selected
// physical input device via kAudioUnitSubType_HALOutput (input scope enabled
// on bus 1, output disabled on bus 0), converts to 48kHz stereo interleaved
// float (AudioConverter when the device rate differs; mono duplicated to both
// channels), runs the microphone chains (§5.15 cleanup, then §5.13 voice
// effects), and writes into the shared ring via AudioSink. All conversion
// buffers are preallocated in start(); the render callback performs no
// allocation, no locking, and no logging.
//
// Licensed under the Apache License, Version 2.0.

import AudioToolbox
import CoreAudio
import Foundation
import os

// MARK: - Real-time callback plumbing (file scope, C-compatible)

/// Sentinel returned by the converter feed proc when the single input slice
/// has been consumed. AudioConverterFillComplexBuffer surfaces it after
/// producing whatever output it could; the caller treats it as success.
private let prismFeedExhausted: OSStatus = OSStatus(bitPattern: 0x70726D66) // 'prmf'

/// One-shot input for AudioConverterFillComplexBuffer: hands the freshly
/// rendered interleaved slice to the converter exactly once per callback.
private struct ConverterFeed {
    var data: UnsafeMutableRawPointer?
    var byteSize: UInt32
    var packets: UInt32
    var channels: UInt32
}

private func prismConverterFeedProc(
    _ converter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outPacketDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let feedPtr = inUserData?.assumingMemoryBound(to: ConverterFeed.self),
          feedPtr.pointee.packets > 0 else {
        ioNumberDataPackets.pointee = 0
        return prismFeedExhausted
    }
    let feed = feedPtr.pointee
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = feed.channels
    ioData.pointee.mBuffers.mDataByteSize = feed.byteSize
    ioData.pointee.mBuffers.mData = feed.data
    ioNumberDataPackets.pointee = feed.packets
    feedPtr.pointee.packets = 0            // consumed
    return noErr
}

/// AURenderCallback installed via kAudioOutputUnitProperty_SetInputCallback.
/// Runs on the HAL's real-time IO thread. No allocation, no locks, no
/// logging. `inRefCon` is an unretained AudioCapture.
private func prismAudioInputProc(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let capture = Unmanaged<AudioCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.renderInput(ioActionFlags: ioActionFlags,
                               timeStamp: inTimeStamp,
                               busNumber: inBusNumber,
                               frameCount: inNumberFrames)
}

// MARK: - AudioCapture

public final class AudioCapture {

    // MARK: Public surface (CONTRACTS.md)

    /// Written on the RT thread — set before start().
    public var sink: AudioSink?

    /// Mute writes silence into the ring (mic muted ≠ ring stalled).
    ///
    /// Flag semantics: single writer (the main thread, via this setter) and a
    /// single reader (the RT callback). The setter serializes writers through
    /// an os_unfair_lock; the RT callback reads the raw Bool without taking
    /// the lock. A one-byte Bool cannot tear on arm64/x86_64, and the worst
    /// case is the callback observing the old value for one IO slice (~5ms),
    /// which is inaudible and well within spec. The lock is deliberately
    /// never touched on the RT path.
    public var isMuted: Bool {
        get { _isMuted }
        set {
            os_unfair_lock_lock(flagLock)
            _isMuted = newValue
            os_unfair_lock_unlock(flagLock)
        }
    }

    /// While clip audio owns the ring, live capture stands down entirely
    /// (writes nothing, so ClipPlayer's writes are the only producer).
    /// Same single-writer/lock-on-set-only discipline as isMuted.
    public var isSuppressed: Bool {
        get { _isSuppressed }
        set {
            os_unfair_lock_lock(flagLock)
            _isSuppressed = newValue
            os_unfair_lock_unlock(flagLock)
        }
    }

    /// Acknowledgment side of the suppression handshake: the RT callback
    /// copies `isSuppressed` here at the top of every IO slice, so once this
    /// reads true no further live-capture ring writes can be in flight.
    /// ClipPlayer's audio pump gates on this before writing, enforcing the
    /// ring's single-producer contract (§4.3) across the handoff. Written
    /// only by the RT callback; read anywhere.
    public var suppressionEngaged: Bool { _suppressAck }

    /// Whether the HAL input unit is currently running (start() succeeded and
    /// stop() has not been called).
    public var isCapturing: Bool { running }

    /// CoreAudio UID of the device the running unit is bound to; nil when
    /// stopped. Lets AppState detect that the *default-resolved* device (a
    /// nil selection) was unplugged — the HAL unit stays silently bound to
    /// the dead AudioDeviceID otherwise. Written on setupQueue; the reader
    /// (main thread) tolerates a one-cycle-stale value.
    public private(set) var currentDeviceUID: String?

    /// Actual IO buffer size granted by the device; 256 requested (§4.4),
    /// nearest supported value accepted.
    public private(set) var effectiveBufferFrames: Int = 256

    /// §4.4: device buffer latency at the device's actual rate (the buffer
    /// size is granted in device-rate frames) plus the ring-traversal
    /// estimate (one client buffer period; 256 frames @ 48kHz assumed
    /// = 5.33ms), plus whatever the voice changer's pitch grains are costing
    /// right now (§5.13) — an opt-in cost, but a real one, so it is reported
    /// like every other.
    public var addedLatencyMs: Double {
        Double(effectiveBufferFrames) / deviceSampleRate * 1000.0 + 256.0 / 48_000.0 * 1000.0
            + voiceChanger.reportedLatencyMs + voiceCleanup.reportedLatencyMs
    }

    // MARK: Voice cleanup (§5.15)
    //
    // Noise suppression and levelling, ahead of the voice effects in the
    // chain and independent of them. Costs no latency — deliberately, since
    // the §6 audio budget has ~1.3 ms of slack over the HAL buffer and the
    // ring, which is not enough to buy any lookahead worth having. Stored as
    // a `let` for the same reason the voice changer is: the RT path may call
    // methods on a constant reference without ARC traffic.
    public let voiceCleanup = VoiceCleanup()

    // MARK: Voice changer (§5.13)
    //
    // The microphone voice-effect chain. Parameters arrive from the main
    // thread via voiceChanger.apply(); processing happens inside the RT
    // callback between format conversion and the ring write, so the
    // deliberate delay line (§5.12) and the ring both carry the processed
    // voice. Stored as a `let` on purpose: the RT path may call methods on a
    // constant reference the class owns for its whole lifetime without ARC
    // traffic, the same argument rtRing makes for the sink.
    public let voiceChanger = VoiceChanger()

    /// RT-private: set on the muted and suppressed early-outs, consumed just
    /// before the voice hook. While muted (or while clip audio owns the
    /// ring) the voice chain does not run, so its delay lines freeze holding
    /// pre-mute audio; clearing them on resume keeps a mute acoustically
    /// clean in both directions — an unmute must never replay the echo tail
    /// of the last thing said before the mute. Only the RT callback touches
    /// this flag.
    private var voicePathInterrupted = false

    // MARK: Mic check tap (§5.13)
    //
    // A passive, armed-on-demand copy of the post-effect microphone signal,
    // so the mic check can play back exactly what the ring receives.
    // Allocated once at init (like the voice changer's buffers) so the main
    // thread's reader can never race a teardown's deallocation.

    let micTap = MicTapRing()
    /// Same single-writer/lock-on-set-only discipline as isMuted.
    private var _micTapArmed = false

    /// Arms the mic-check tap. Main thread; the RT callback observes the
    /// flag raw, at worst one IO slice late.
    public func setMicTapArmed(_ armed: Bool) {
        os_unfair_lock_lock(flagLock)
        _micTapArmed = armed
        os_unfair_lock_unlock(flagLock)
    }

    /// Where a mic-check recording should start reading from: the write
    /// head as of now, so a take contains only frames captured after arming.
    public var micTapCursor: UInt64 { micTap.head }

    /// Drains tap frames written since `cursor`. Main thread.
    public func readMicTap(from cursor: UInt64,
                           into buffer: UnsafeMutablePointer<Float>,
                           maxFrames: Int) -> (cursor: UInt64, frames: Int) {
        micTap.read(from: cursor, into: buffer, maxFrames: maxFrames)
    }

    // MARK: Input level (§5.15)
    //
    // A continuous "is the microphone hearing me" reading, published from
    // the RT callback into a lock-free mailbox and sampled by the UI on a
    // timer. Demand-gated: nothing is measured unless something is watching
    // — a meter on screen, or the muted-and-talking watch, which can only
    // fire while the microphone is already off air.

    let inputLevel = InputLevelMailbox()
    /// Same single-writer/lock-on-set-only discipline as isMuted.
    private var _inputLevelArmed = false

    /// Arms the level meter. Main thread; the RT callback observes the flag
    /// raw, at worst one IO slice late.
    public func setInputLevelArmed(_ armed: Bool) {
        os_unfair_lock_lock(flagLock)
        _inputLevelArmed = armed
        os_unfair_lock_unlock(flagLock)
    }

    /// Newest published RMS and the counter identifying its window. A caller
    /// that sees the counter twice knows no audio arrived in between and can
    /// decay its meter instead of freezing it.
    public var inputLevelReading: (rms: Double, sequence: UInt32) {
        inputLevel.reading
    }

    public init() {
        flagLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        flagLock.initialize(to: os_unfair_lock_s())
        feedBox = UnsafeMutablePointer<ConverterFeed>.allocate(capacity: 1)
        feedBox.initialize(to: ConverterFeed(data: nil, byteSize: 0, packets: 0, channels: 2))
    }

    deinit {
        teardown()
        feedBox.deinitialize(count: 1)
        feedBox.deallocate()
        flagLock.deinitialize(count: 1)
        flagLock.deallocate()
    }

    // MARK: Private state

    private var _isMuted = false
    private var _isSuppressed = false
    /// RT-callback-written mirror of _isSuppressed (see suppressionEngaged).
    private var _suppressAck = false
    private let flagLock: UnsafeMutablePointer<os_unfair_lock_s>

    /// Serializes start/stop/restart against the retry timer. Never touched
    /// by the RT callback.
    private let setupQueue = DispatchQueue(
        label: "horse.prism.PRISM.audio-setup", qos: .userInitiated)

    private var audioUnit: AudioUnit?
    private var running = false
    private var requestedUID: String?
    private var generation: UInt64 = 0
    /// Set once start() has been called; restart() (wake) is a no-op before
    /// then so a never-authorized capture is not spun up from the wake path.
    private var everStarted = false

    /// Raw ring + silence pointers captured from `sink` at build time so the
    /// RT callback never touches managed references (§4.3: no Swift ARC
    /// traffic inside IO callbacks). Cleared in teardown() after the unit
    /// stops; AudioSink stays alive for the app's lifetime (owned by
    /// AppState) so the pointers cannot dangle while the unit runs.
    private var rtRing: UnsafeMutablePointer<PRISMRingBuffer>?
    private var rtSilence: UnsafePointer<Float>?
    private var rtSilenceFrames = 0

    // MARK: Deliberate delay line (§5.12)
    //
    // Delaying audio is cheap in a way delaying video is not: ten seconds of
    // 48 kHz stereo float is under 4 MB, where the same ten seconds of 1080p
    // is gigabytes. So the microphone gets a plain circular delay buffer
    // here, while video is delayed by trailing the compressed rolling buffer
    // (§5.9). Preallocated in start(); the RT callback only indexes it.

    /// Interleaved stereo, `delayCapacityFrames` frames. Allocated once.
    private var delayData: UnsafeMutablePointer<Float>?
    private var delayCapacityFrames = 0
    /// Write cursor in frames, monotonic; wrapped on use.
    private var delayWritten: UInt64 = 0
    /// Target delay in frames. Same single-writer/lock-on-set-only discipline
    /// as isMuted: the setter serializes writers, the RT callback reads raw.
    private var _delayFrames = 0
    /// Requested delay in seconds; 0 disables the line entirely so the
    /// off case costs one comparison on the RT path.
    public var delaySeconds: Double {
        get {
            os_unfair_lock_lock(flagLock)
            defer { os_unfair_lock_unlock(flagLock) }
            return Double(_delayFrames) / 48_000.0
        }
        set {
            // Clamped against the static maximum, not the live capacity:
            // `delayCapacityFrames` belongs to the RT path, and reading it
            // from the setter would be a race for no benefit. The RT path
            // clamps again against what it actually has.
            let seconds = min(max(newValue, 0), Self.maxDelaySeconds)
            let frames = Int((seconds * 48_000.0).rounded())
            os_unfair_lock_lock(flagLock)
            _delayFrames = frames
            os_unfair_lock_unlock(flagLock)
        }
    }

    /// Longest delay the line can hold (§5.12 clamps the UI to this).
    public static let maxDelaySeconds: Double = 10

    // Device/client format, fixed for the life of one start().
    private var deviceSampleRate: Double = 48_000
    private var clientChannels: Int = 2

    // Preallocated RT buffers (start() only). Capacities in frames.
    private static let maxSliceFrames = 4096
    private var renderData: UnsafeMutableRawPointer?          // AudioUnitRender target
    private var renderCapacityBytes: Int = 0
    private var convertData: UnsafeMutableRawPointer?         // converter output
    private var convertCapacityFrames: Int = 0
    private var stereoData: UnsafeMutablePointer<Float>?      // mono→stereo staging
    private var stereoCapacityFrames: Int = 0
    private var converter: AudioConverterRef?
    private let feedBox: UnsafeMutablePointer<ConverterFeed>

    /// §7 sleep/wake retry schedule, seconds.
    private static let retryDelays: [Double] = [0.5, 1.0, 2.0, 4.0]

    // MARK: Lifecycle

    /// nil = default input device. PRISM's own virtual microphone is never
    /// selected as a default or fallback (§5.1).
    public func start(deviceUID: String?) {
        setupQueue.sync {
            generation &+= 1
            everStarted = true
            requestedUID = deviceUID
            teardown()
            if !buildAndRun(deviceUID: deviceUID) {
                scheduleRetry(generation: generation, attempt: 0)
            }
        }
    }

    public func stop() {
        setupQueue.sync {
            generation &+= 1
            teardown()
        }
    }

    /// §7 sleep/wake: tear down and rebuild against the same selection,
    /// retrying at 0.5s / 1s / 2s / 4s while the device reappears. A no-op
    /// unless start() has run — wake must not begin capturing from the
    /// default microphone when capture was never authorized/started.
    public func restart() {
        setupQueue.sync {
            guard everStarted else { return }
            generation &+= 1
            let uid = requestedUID
            teardown()
            if !buildAndRun(deviceUID: uid) {
                scheduleRetry(generation: generation, attempt: 0)
            }
        }
    }

    private func scheduleRetry(generation gen: UInt64, attempt: Int) {
        guard attempt < AudioCapture.retryDelays.count else { return }
        setupQueue.asyncAfter(deadline: .now() + AudioCapture.retryDelays[attempt]) { [weak self] in
            guard let self, gen == self.generation, self.audioUnit == nil else { return }
            if !self.buildAndRun(deviceUID: self.requestedUID) {
                self.scheduleRetry(generation: gen, attempt: attempt + 1)
            }
        }
    }

    // MARK: Unit construction (setupQueue only)

    private func buildAndRun(deviceUID: String?) -> Bool {
        // A previous failed attempt (or a device swap) may have left a stale
        // sample-rate converter installed; running new audio through the old
        // device's converter would pitch/speed-shift it. Dispose it before
        // anything else so `converter` is only ever set for the device this
        // attempt actually binds.
        if let stale = converter {
            AudioConverterDispose(stale)
            converter = nil
        }

        // Resolve the physical device, excluding PRISM Microphone.
        guard let deviceID = AudioCapture.resolveDevice(uid: deviceUID) else { return false }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { return false }
        var unitOpt: AudioUnit?
        guard AudioComponentInstanceNew(component, &unitOpt) == noErr,
              let unit = unitOpt else { return false }

        func fail() -> Bool {
            AudioComponentInstanceDispose(unit)
            freeBuffers()
            return false
        }

        // Input scope enabled on bus 1, output disabled on bus 0 (§4.4).
        var one: UInt32 = 1
        var zero: UInt32 = 0
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1,
                                   &one, UInt32(MemoryLayout<UInt32>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0,
                                   &zero, UInt32(MemoryLayout<UInt32>.size)) == noErr
        else { return fail() }

        // Bind to the selected device.
        var boundDevice = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0,
                                   &boundDevice,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { return fail() }

        // Request a 256-frame IO buffer; accept the nearest supported (§4.4).
        effectiveBufferFrames = AudioCapture.setBufferFrames(deviceID: deviceID, requested: 256)

        // Device (hardware-side) format: scope Input, element 1.
        var deviceFormat = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 1,
                                   &deviceFormat, &asbdSize) == noErr
        else { return fail() }
        deviceSampleRate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : 48_000
        clientChannels = deviceFormat.mChannelsPerFrame >= 2 ? 2 : 1

        // Client format we pull with AudioUnitRender: interleaved Float32 at
        // the device rate (the AHAL unit does not rate-convert on input).
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * clientChannels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * clientChannels),
            mChannelsPerFrame: UInt32(clientChannels),
            mBitsPerChannel: 32,
            mReserved: 0)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1,
                                   &clientFormat, asbdSize) == noErr
        else { return fail() }

        var maxSlice = UInt32(AudioCapture.maxSliceFrames)
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                 kAudioUnitScope_Global, 0,
                                 &maxSlice, UInt32(MemoryLayout<UInt32>.size))

        // Preallocate every RT buffer (§4.4: nothing allocates in the callback).
        allocateBuffers()

        // Capture the ring + silence pointers so the RT callback calls the C
        // ring API directly, with zero managed references (§4.3).
        rtRing = sink?.ringPointer
        rtSilence = sink?.silencePointer
        rtSilenceFrames = AudioSink.silenceBlockFrames

        // Sample-rate converter when the device is not at 48k. Channel count
        // is preserved; mono duplication happens after conversion.
        if deviceSampleRate != 48_000 {
            var dst = clientFormat
            dst.mSampleRate = 48_000
            var conv: AudioConverterRef?
            guard AudioConverterNew(&clientFormat, &dst, &conv) == noErr,
                  let conv else { return fail() }
            converter = conv
        }

        // Install the RT input callback.
        var callback = AURenderCallbackStruct(
            inputProc: prismAudioInputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0,
                                   &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
        else { return fail() }

        guard AudioUnitInitialize(unit) == noErr else { return fail() }
        guard AudioOutputUnitStart(unit) == noErr else {
            AudioUnitUninitialize(unit)
            return fail()
        }

        audioUnit = unit
        running = true
        currentDeviceUID = CoreAudioDevices.uid(of: deviceID)
        return true
    }

    private func teardown() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        running = false
        currentDeviceUID = nil
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }
        rtRing = nil
        rtSilence = nil
        rtSilenceFrames = 0
        freeBuffers()
    }

    private func allocateBuffers() {
        freeBuffers()
        renderCapacityBytes = AudioCapture.maxSliceFrames * clientChannels * MemoryLayout<Float>.size
        renderData = UnsafeMutableRawPointer.allocate(
            byteCount: renderCapacityBytes, alignment: MemoryLayout<Float>.alignment)
        // Worst-case upsampling output for one slice, plus converter slack.
        let ratio = max(1.0, 48_000.0 / max(deviceSampleRate, 1))
        convertCapacityFrames = Int((Double(AudioCapture.maxSliceFrames) * ratio).rounded(.up)) + 64
        convertData = UnsafeMutableRawPointer.allocate(
            byteCount: convertCapacityFrames * clientChannels * MemoryLayout<Float>.size,
            alignment: MemoryLayout<Float>.alignment)
        stereoCapacityFrames = convertCapacityFrames
        stereoData = UnsafeMutablePointer<Float>.allocate(capacity: stereoCapacityFrames * 2)

        // Voice changer (§5.13): size its mixdown scratch for the worst
        // post-conversion slice and clear stale effect tails. RT unit is not
        // running here, so touching its buffers is safe.
        voiceChanger.prepare(maxFrames: convertCapacityFrames)
        // §5.15: the cleanup chain's learned noise floor describes one
        // room through one microphone. A device swap invalidates it.
        voiceCleanup.reset()
        inputLevel.resetAccumulator()
        voicePathInterrupted = false
        // The tap's lap-skip margin must dominate the largest single write.
        micTap.setMaxWriteFrames(convertCapacityFrames)

        // Deliberate delay line (§5.12). Preallocated with the rest of the RT
        // buffers even when lag is never used: 10 s of 48 kHz stereo float is
        // 3.8 MB, and the alternative — allocating when the switch is first
        // thrown — would mean swapping a pointer the RT callback is reading.
        // Sized with one extra slice of headroom so the read window can never
        // overlap the frames being written this callback.
        delayCapacityFrames = Int(Self.maxDelaySeconds * 48_000) + Self.maxSliceFrames
        delayData = UnsafeMutablePointer<Float>.allocate(capacity: delayCapacityFrames * 2)
        delayData?.initialize(repeating: 0, count: delayCapacityFrames * 2)
        delayWritten = 0
    }

    private func freeBuffers() {
        renderData?.deallocate(); renderData = nil
        convertData?.deallocate(); convertData = nil
        stereoData?.deallocate(); stereoData = nil
        delayData?.deallocate(); delayData = nil
        renderCapacityBytes = 0
        convertCapacityFrames = 0
        stereoCapacityFrames = 0
        delayCapacityFrames = 0
        delayWritten = 0
    }

    // MARK: Real-time render path

    /// Body of the RT input callback. Pull → (convert) → (duplicate mono) →
    /// sink.write. Preallocated buffers only; no allocation, locks, or
    /// logging here.
    fileprivate func renderInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32) -> OSStatus {

        guard let unit = audioUnit,
              let renderData,
              frameCount > 0,
              Int(frameCount) <= AudioCapture.maxSliceFrames else { return noErr }

        // Suppressed: clip audio owns the ring; write nothing (§5.3), but
        // still pull the hardware so the unit's timeline keeps advancing.
        // Acknowledge the flag first: once suppressionEngaged reads true, no
        // live write from this or any later slice can be in flight, so the
        // clip pump may safely take over as the ring's single producer.
        let suppressed = _isSuppressed
        if _suppressAck != suppressed { _suppressAck = suppressed }
        let muted = _isMuted
        // Raw ring pointer only — no managed references on the RT path (§4.3).
        guard let ring = rtRing else { return noErr }

        let channels = UInt32(clientChannels)
        let byteSize = frameCount * channels * 4
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: channels,
                                  mDataByteSize: byteSize,
                                  mData: renderData))
        let status = AudioUnitRender(unit, ioActionFlags, timeStamp,
                                     busNumber, frameCount, &abl)
        guard status == noErr else { return status }

        // §5.15: the meter is taken from the raw device slice — ahead of
        // mute, suppression, cleanup and the voice changer — because the
        // question it answers ("is my microphone hearing me") has to keep
        // being answerable while muted. That is the whole basis of the
        // muted-and-talking watch, and it is also what a user checking a
        // dead-sounding microphone actually wants to see. Off costs one
        // comparison.
        if _inputLevelArmed {
            inputLevel.accumulate(renderData.assumingMemoryBound(to: Float.self),
                                  frameCount: Int(frameCount),
                                  channels: clientChannels)
        }

        if suppressed {
            voicePathInterrupted = true
            return noErr
        }

        // Frame count after conversion to 48k (used for the mute path too so
        // the ring advances at the true output rate).
        let outEstimate = deviceSampleRate == 48_000
            ? Int(frameCount)
            : Int((Double(frameCount) * 48_000.0 / deviceSampleRate).rounded())

        if muted {
            voicePathInterrupted = true
            rtWriteSilence(ring: ring, frameCount: outEstimate)
            return noErr
        }

        var samples = renderData.assumingMemoryBound(to: Float.self)
        var frames = Int(frameCount)

        if let converter, let convertData {
            feedBox.pointee = ConverterFeed(data: renderData,
                                            byteSize: byteSize,
                                            packets: frameCount,
                                            channels: channels)
            var outPackets = UInt32(convertCapacityFrames)
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channels,
                    mDataByteSize: UInt32(convertCapacityFrames * clientChannels * 4),
                    mData: convertData))
            let convStatus = AudioConverterFillComplexBuffer(
                converter, prismConverterFeedProc, UnsafeMutableRawPointer(feedBox),
                &outPackets, &outABL, nil)
            guard convStatus == noErr || convStatus == prismFeedExhausted else {
                return noErr    // drop this slice rather than propagate
            }
            samples = convertData.assumingMemoryBound(to: Float.self)
            frames = Int(outPackets)
        }

        guard frames > 0 else { return noErr }

        // §5.13/§5.15: both microphone chains process the 48 kHz signal in
        // place, before mono duplication and before the delay line, so
        // everything downstream — the deliberate delay included — carries
        // the processed voice. Each costs one trylock and one comparison
        // when off.
        //
        // Cleanup runs first, and the order is load-bearing: it exists to
        // hand the effects a clean signal (the autotune detector and the
        // grain shifter both degrade on a noisy one), and gating a
        // deliberately ring-modulated or echoed signal afterwards would chew
        // the effect's own tail.
        if voicePathInterrupted {
            voicePathInterrupted = false
            // RT-safe: bounded memsets of preallocated buffers.
            voiceCleanup.clearDSPState()
            voiceChanger.clearDSPState()
        }
        if clientChannels == 1 {
            voiceCleanup.processMono(samples, frameCount: frames)
            voiceChanger.processMono(samples, frameCount: frames)
        } else {
            voiceCleanup.processStereoInterleaved(samples, frameCount: frames)
            voiceChanger.processStereoInterleaved(samples, frameCount: frames)
        }

        // §5.13 mic check: when armed, copy the post-effect mono signal into
        // the tap ring for the main thread to play back. Passive — the
        // on-air path is untouched — and pre-delay, so a lag switch does not
        // delay the check. Off costs one comparison.
        if _micTapArmed {
            if clientChannels == 1 {
                micTap.writeMono(samples, frameCount: frames)
            } else {
                micTap.writeStereoMixdown(samples, frameCount: frames)
            }
        }

        if clientChannels == 1 {
            // Mono duplicated to both channels (§4.2).
            guard let stereoData, frames <= stereoCapacityFrames else { return noErr }
            for i in 0..<frames {
                let v = samples[i]
                stereoData[i * 2] = v
                stereoData[i * 2 + 1] = v
            }
            rtEmit(ring: ring, samples: stereoData, frameCount: frames)
        } else {
            rtEmit(ring: ring, samples: samples, frameCount: frames)
        }
        return noErr
    }

    /// Ring write, through the deliberate delay line when one is set (§5.12).
    /// RT-safe: indexes a preallocated circular buffer and calls the C ring
    /// API. With no delay this is one comparison and the original direct
    /// write, so the feature costs nothing when it is off.
    private func rtEmit(ring: UnsafeMutablePointer<PRISMRingBuffer>,
                        samples: UnsafePointer<Float>,
                        frameCount: Int) {
        let capacity = delayCapacityFrames
        // Clamp against what the line actually has, leaving a slice of
        // headroom so the read window never overlaps this callback's write.
        let delay = min(_delayFrames, max(0, capacity - AudioCapture.maxSliceFrames))
        guard delay > 0, let delayData, capacity > 0, frameCount <= capacity else {
            PRISMRingBufferWrite(ring, samples, UInt32(frameCount))
            return
        }

        // Append this slice to the circular buffer.
        var cursor = Int(delayWritten % UInt64(capacity))
        var remaining = frameCount
        var source = samples
        while remaining > 0 {
            let chunk = min(remaining, capacity - cursor)
            memcpy(delayData + cursor * 2, source,
                   chunk * 2 * MemoryLayout<Float>.size)
            cursor = (cursor + chunk) % capacity
            source += chunk * 2
            remaining -= chunk
        }
        delayWritten &+= UInt64(frameCount)

        // Emit the slice sitting `delay` frames behind the new write cursor.
        let start = Int64(delayWritten) - Int64(delay) - Int64(frameCount)
        guard start >= 0 else {
            // The line has not filled yet — this is the stall at the start of
            // a delay, and silence is the honest thing to send. Video does
            // exactly the same by holding its engage frame.
            let missing = min(frameCount, Int(-start))
            rtWriteSilence(ring: ring, frameCount: missing)
            let rest = frameCount - missing
            if rest > 0 {
                rtWriteDelayed(ring: ring, from: 0, count: rest)
            }
            return
        }
        rtWriteDelayed(ring: ring, from: Int(start % Int64(capacity)), count: frameCount)
    }

    /// Writes `count` frames from the delay line starting at frame index
    /// `from`, split across the wrap point. RT-safe.
    private func rtWriteDelayed(ring: UnsafeMutablePointer<PRISMRingBuffer>,
                                from: Int, count: Int) {
        guard let delayData, delayCapacityFrames > 0 else { return }
        var cursor = from
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, delayCapacityFrames - cursor)
            PRISMRingBufferWrite(ring, delayData + cursor * 2, UInt32(chunk))
            cursor = (cursor + chunk) % delayCapacityFrames
            remaining -= chunk
        }
    }

    /// RT-safe silence write: chunks the preallocated zero block through the
    /// C ring API. No allocation, no managed references.
    private func rtWriteSilence(ring: UnsafeMutablePointer<PRISMRingBuffer>,
                                frameCount: Int) {
        guard let rtSilence, rtSilenceFrames > 0, frameCount > 0 else { return }
        var remaining = frameCount
        while remaining > 0 {
            let chunk = min(remaining, rtSilenceFrames)
            PRISMRingBufferWrite(ring, rtSilence, UInt32(chunk))
            remaining -= chunk
        }
    }

    // MARK: CoreAudio device helpers

    /// uid = nil → system default input. PRISM's own virtual microphone is
    /// excluded from default and fallback resolution; capturing from it
    /// would loop the ring back into itself.
    private static func resolveDevice(uid: String?) -> AudioDeviceID? {
        if let uid,
           let id = CoreAudioDevices.deviceID(forUID: uid),
           !CoreAudioDevices.isPrismVirtualMicrophone(id),
           CoreAudioDevices.inputChannelCount(id) > 0 {
            return id
        }
        // Selected device gone (or nil requested): system default input.
        if let def = CoreAudioDevices.defaultInputDeviceID(),
           !CoreAudioDevices.isPrismVirtualMicrophone(def),
           CoreAudioDevices.inputChannelCount(def) > 0 {
            return def
        }
        // Default is PRISM (or missing): first physical input device.
        return CoreAudioDevices.allDeviceIDs().first {
            !CoreAudioDevices.isPrismVirtualMicrophone($0)
                && CoreAudioDevices.inputChannelCount($0) > 0
        }
    }

    /// Clamps the request into the device's supported range (nearest
    /// accepted, §4.4), sets it, and returns what the device actually granted.
    private static func setBufferFrames(deviceID: AudioDeviceID, requested: UInt32) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var target = requested
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &range) == noErr,
           range.mMaximum > 0 {
            target = UInt32(min(max(Double(requested), range.mMinimum), range.mMaximum))
        }
        address.mSelector = kAudioDevicePropertyBufferFrameSize
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &target)
        var actual: UInt32 = target
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &actual) == noErr,
           actual > 0 {
            return Int(actual)
        }
        return Int(target)
    }
}
