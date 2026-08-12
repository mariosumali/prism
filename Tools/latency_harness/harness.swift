// harness.swift
// PRISM latency harness — ad-hoc CLI, compiled by run.sh (not part of the
// Xcode project). Measures (a) shared-memory ring traversal latency across
// two threads using the real C ring, and (b) virtual-camera added latency by
// pushing a counter-stamped test pattern into the PRISM Camera sink stream
// and capturing it back via AVCaptureSession. Prints a LatencyReport-shaped
// summary. Degrades gracefully when the camera extension is not installed.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import Darwin
import Dispatch
import Foundation

// MARK: - Time helpers

let machTimebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

func machToMs(_ ticks: UInt64) -> Double {
    Double(ticks) * Double(machTimebase.numer) / Double(machTimebase.denom) / 1_000_000.0
}

// MARK: - Stats

struct Stats {
    let count: Int
    let p50: Double
    let p90: Double
    let p99: Double
    let max: Double

    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func pct(_ p: Double) -> Double {
            let idx = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[Swift.min(idx, sorted.count - 1)]
        }
        count = sorted.count
        p50 = pct(0.50)
        p90 = pct(0.90)
        p99 = pct(0.99)
        max = sorted[sorted.count - 1]
    }

    func line(unit: String = "ms") -> String {
        String(format: "p50 %6.3f %@   p90 %6.3f %@   p99 %6.3f %@   max %6.3f %@ (N=%d)",
               p50, unit, p90, unit, p99, unit, max, unit, count)
    }
}

// MARK: - Arguments

struct Options {
    var runRing = true
    var runCamera = true
    var ringIterations = 2000
    var cameraSeconds = 10.0
    var width = 1280
    var height = 720
    var fps = 30
}

func parseOptions() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--ring-only":
            opts.runCamera = false
        case "--camera-only":
            opts.runRing = false
        case "--iterations":
            if let v = args.first, let n = Int(v), n > 0 { opts.ringIterations = n; args.removeFirst() }
        case "--seconds":
            if let v = args.first, let s = Double(v), s > 0 { opts.cameraSeconds = s; args.removeFirst() }
        case "-h", "--help":
            print("""
            PRISM latency harness

            Usage: run.sh [options]
              --ring-only         only the shared-memory ring self-test
              --camera-only       only the virtual-camera loop
              --iterations N      ring test bursts (default 2000)
              --seconds S         camera loop duration (default 10)
              -h, --help          this text

            Notes:
              * Quit PRISM.app before running — the harness takes the sink
                stream and the audio ring for itself.
              * The camera loop needs the PRISM Camera extension installed
                and approved, plus camera permission for your terminal.
            """)
            exit(0)
        default:
            FileHandle.standardError.write("Unknown option: \(arg) (try --help)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return opts
}

// MARK: - Phase A: shared-memory ring self-test

/// Maps the real POSIX SHM ring twice (producer + consumer mapping, exactly
/// as app and coreaudiod do), then measures write → read traversal latency:
/// the producer thread stamps each 256-frame burst with mach_absolute_time
/// split across the first two floats; the consumer thread spins on the fill
/// level, reads the burst back through its own mapping, and records the delta.
func runRingSelfTest(iterations: Int) -> Stats? {
    print("── Ring self-test (\(iterations) × 256-frame bursts through \(PRISM_SHM_NAME)) ──")
    print("   note: if PRISM Microphone is actively in use, coreaudiod is a")
    print("   competing consumer and results will be invalid. Quit PRISM.app")
    print("   and stop any recording before trusting these numbers.")

    guard let producer = PRISMRingBufferCreateProducer() else {
        print("   FAILED: could not create/map the shared ring (shm_open). Skipping.")
        return nil
    }
    guard let consumer = PRISMRingBufferOpenConsumer() else {
        print("   FAILED: could not open a consumer mapping. Skipping.")
        PRISMRingBufferCloseProducer(producer)
        return nil
    }

    let burst = 256
    let channels = Int(PRISM_CHANNELS)
    var results: [Double] = []
    results.reserveCapacity(iterations)
    let done = DispatchSemaphore(value: 0)

    // Consumer thread: spin (yield) on fill level, read whole bursts.
    let consumerThread = Thread {
        var out = [Float](repeating: 0, count: burst * channels)
        var received = 0
        let deadline = Date().addingTimeInterval(30)
        while received < iterations && Date() < deadline {
            if PRISMRingBufferFillLevel(consumer) >= UInt64(burst) {
                let got = out.withUnsafeMutableBufferPointer { buf in
                    PRISMRingBufferRead(consumer, buf.baseAddress!, UInt32(burst))
                }
                let now = mach_absolute_time()
                if got == UInt32(burst) {
                    let hi = UInt64(out[0].bitPattern)
                    let lo = UInt64(out[1].bitPattern)
                    let stamp = (hi << 32) | lo
                    if stamp != 0 && now >= stamp {
                        results.append(machToMs(now - stamp))
                    }
                    received += 1
                }
            } else {
                sched_yield()
            }
        }
        done.signal()
    }
    consumerThread.qualityOfService = .userInteractive
    consumerThread.start()

    // Producer thread (this thread): paced bursts, stamp in samples 0+1.
    var samples = [Float](repeating: 0, count: burst * channels)
    for _ in 0..<iterations {
        let t = mach_absolute_time()
        samples[0] = Float(bitPattern: UInt32(truncatingIfNeeded: t >> 32))
        samples[1] = Float(bitPattern: UInt32(truncatingIfNeeded: t))
        samples.withUnsafeBufferPointer { buf in
            PRISMRingBufferWrite(producer, buf.baseAddress!, UInt32(burst))
        }
        usleep(2000)   // ~2ms pacing keeps the run short but bursts distinct
    }

    _ = done.wait(timeout: .now() + 35)
    PRISMRingBufferCloseConsumer(consumer)
    PRISMRingBufferCloseProducer(producer)

    guard let stats = Stats(results) else {
        print("   FAILED: no bursts observed by the consumer thread.")
        return nil
    }
    print("   traversal  \(stats.line())")
    return stats
}

// MARK: - Phase B helpers: CMIO C API (same approach as CMIOSink)

func prismPropertyAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(selector),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func cmioObjectIDs(of objectID: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
    var addr = prismPropertyAddress(selector)
    var dataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(objectID, &addr, 0, nil, &dataSize) == 0,
          dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
    var ids = [CMIOObjectID](repeating: 0, count: count)
    var used: UInt32 = 0
    let status = ids.withUnsafeMutableBufferPointer { buf in
        CMIOObjectGetPropertyData(objectID, &addr, 0, nil, dataSize, &used, buf.baseAddress!)
    }
    guard status == 0 else { return [] }
    return ids
}

func cmioString(of objectID: CMIOObjectID, selector: Int) -> String? {
    var addr = prismPropertyAddress(selector)
    var unmanaged: Unmanaged<CFString>?
    var used: UInt32 = 0
    let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
        CMIOObjectGetPropertyData(objectID, &addr, 0, nil, size, &used, ptr)
    }
    guard status == 0, let value = unmanaged?.takeRetainedValue() else { return nil }
    return value as String
}

func cmioUInt32(of objectID: CMIOObjectID, selector: Int) -> UInt32? {
    var addr = prismPropertyAddress(selector)
    var value: UInt32 = 0
    var used: UInt32 = 0
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        CMIOObjectGetPropertyData(objectID, &addr, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &used, ptr)
    }
    guard status == 0 else { return nil }
    return value
}

let prismCameraDeviceUID = "horse.prism.PRISM.camera.device"

/// Finds the PRISM Camera CMIO device and its sink stream. The sink is
/// identified by kCMIOStreamPropertyDirection; if directions are ambiguous
/// we fall back to the second stream, which matches the creation order in
/// PRISM's own extension (source first, sink second).
func findPrismSink() -> (device: CMIODeviceID, sink: CMIOStreamID)? {
    let systemID = CMIOObjectID(kCMIOObjectSystemObject)
    let devices = cmioObjectIDs(of: systemID, selector: Int(kCMIOHardwarePropertyDevices))
    guard let device = devices.first(where: {
        cmioString(of: $0, selector: Int(kCMIODevicePropertyDeviceUID)) == prismCameraDeviceUID
    }) else {
        return nil
    }
    let streams = cmioObjectIDs(of: device, selector: Int(kCMIODevicePropertyStreams))
    guard !streams.isEmpty else { return nil }

    let directions = streams.map { cmioUInt32(of: $0, selector: Int(kCMIOStreamPropertyDirection)) }
    // Sink = the stream the host writes into (direction 1); source = 0.
    if let idx = directions.firstIndex(where: { $0 == 1 }) {
        return (device, streams[idx])
    }
    if streams.count >= 2 {
        return (device, streams[1])
    }
    return nil
}

// MARK: - Phase B helpers: test pattern

// Counter stripe: 16 full-width blocks across the top eighth of the frame,
// bit i of the counter = block i (white = 1, black = 0). Full-width blocks
// survive any proportional scaling between push and capture.

func makeFrame(counter: Int, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
    var pbOut: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess,
          let pb = pbOut else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    if let base = CVPixelBufferGetBaseAddress(pb) {
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var gray: UInt32 = 0xFF80_8080   // BGRA bytes 80 80 80 FF — mid gray
        memset_pattern4(base, &gray, stride * height)
        let stripeH = max(2, height / 8)
        let blockW = width / 16
        for row in 0..<stripeH {
            let rowPtr = base.advanced(by: row * stride)
            for i in 0..<16 {
                var color: UInt32 = ((counter >> i) & 1) == 1 ? 0xFFFF_FFFF : 0xFF00_0000
                memset_pattern4(rowPtr.advanced(by: i * blockW * 4), &color, blockW * 4)
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

func decodeCounter(_ pb: CVPixelBuffer) -> Int? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
          let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    guard w >= 32, h >= 16 else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let y = max(1, h / 16)   // middle of the top-eighth stripe
    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
    var counter = 0
    for i in 0..<16 {
        let x = ((2 * i + 1) * w) / 32   // center of block i
        let r = row[x * 4 + 2]           // BGRA → red at +2
        if r >= 0xC0 {
            counter |= (1 << i)
        } else if r > 0x40 {
            return nil   // midtone: not our stripe (placeholder card, etc.)
        }
    }
    return counter > 0 ? counter : nil   // counter 0 is indistinguishable from black
}

// MARK: - Phase B: capture delegate

final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let lock = NSLock()
    var sendTimes: [Int: UInt64] = [:]   // counter → mach send time
    var latenciesMs: [Double] = []
    var unmatchedFrames = 0

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = mach_absolute_time()
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let counter = decodeCounter(pb) else {
            lock.lock(); unmatchedFrames += 1; lock.unlock()
            return
        }
        lock.lock()
        if let sent = sendTimes.removeValue(forKey: counter), now >= sent {
            latenciesMs.append(machToMs(now - sent))
        } else {
            unmatchedFrames += 1
        }
        lock.unlock()
    }
}

// MARK: - Phase B: virtual camera loop

func runCameraLoop(seconds: Double, width: Int, height: Int, fps: Int) -> Stats? {
    print("── Virtual camera loop (\(width)×\(height)@\(fps), \(Int(seconds))s of counter frames) ──")
    print("   note: quit PRISM.app first — two writers on the sink stream")
    print("   corrupt each other's measurements.")

    // 1. Locate the extension's sink stream.
    guard let (deviceID, sinkStreamID) = findPrismSink() else {
        print("""
           SKIPPED: PRISM Camera was not found.
           Install PRISM.app, approve the camera extension in System
           Settings → Privacy & Security, then re-run (see README §Install).
        """)
        return nil
    }

    // 2. Camera permission for this process (terminal).
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        break
    case .notDetermined:
        let sema = DispatchSemaphore(value: 0)
        var ok = false
        AVCaptureDevice.requestAccess(for: .video) { granted in
            ok = granted
            sema.signal()
        }
        sema.wait()
        if !ok {
            print("   SKIPPED: camera permission denied for this terminal.")
            return nil
        }
    default:
        print("   SKIPPED: camera permission denied for this terminal.")
        print("   Grant it in System Settings → Privacy & Security → Camera.")
        return nil
    }

    // 3. Copy the sink's buffer queue and start the stream (CMIOSink's path).
    var queueRef: Unmanaged<CMSimpleQueue>?
    var status = CMIOStreamCopyBufferQueue(sinkStreamID, nil, nil, &queueRef)
    guard status == 0, let sinkQueue = queueRef?.takeRetainedValue() else {
        print("   SKIPPED: CMIOStreamCopyBufferQueue failed (\(status)).")
        return nil
    }
    status = CMIODeviceStartStream(deviceID, sinkStreamID)
    guard status == 0 else {
        print("   SKIPPED: CMIODeviceStartStream failed (\(status)). Is PRISM.app running?")
        return nil
    }
    defer { CMIODeviceStopStream(deviceID, sinkStreamID) }

    // 4. Capture session on the PRISM Camera AVCaptureDevice.
    // (.externalUnknown is deprecated in macOS 14 in favor of .external,
    // but PRISM targets macOS 13.0 — the warning is expected.)
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
        mediaType: .video, position: .unspecified)
    guard let camera = discovery.devices.first(where: {
        $0.uniqueID == prismCameraDeviceUID || $0.localizedName == "PRISM Camera"
    }) else {
        print("   SKIPPED: PRISM Camera not visible to AVFoundation yet.")
        print("   (A just-approved extension can take a few seconds to appear.)")
        return nil
    }

    let delegate = CaptureDelegate()
    let session = AVCaptureSession()
    session.beginConfiguration()
    if session.canSetSessionPreset(.hd1280x720) {
        session.sessionPreset = .hd1280x720
    }
    do {
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            print("   SKIPPED: cannot add PRISM Camera as capture input.")
            return nil
        }
        session.addInput(input)
    } catch {
        print("   SKIPPED: AVCaptureDeviceInput failed: \(error.localizedDescription)")
        return nil
    }
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = false
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let captureQueue = DispatchQueue(label: "prism.harness.capture", qos: .userInteractive)
    output.setSampleBufferDelegate(delegate, queue: captureQueue)
    guard session.canAddOutput(output) else {
        print("   SKIPPED: cannot add video data output.")
        return nil
    }
    session.addOutput(output)
    session.commitConfiguration()
    session.startRunning()
    defer { session.stopRunning() }

    // 5. Push counter frames at the target cadence.
    var poolRef: CVPixelBufferPool?
    let poolAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttrs as CFDictionary,
                                  &poolRef) == kCVReturnSuccess,
          let pool = poolRef else {
        print("   SKIPPED: pixel buffer pool creation failed.")
        return nil
    }

    var counter = 1
    var sentCount = 0
    var enqueueDrops = 0
    let pushQueue = DispatchQueue(label: "prism.harness.push", qos: .userInteractive)
    let timer = DispatchSource.makeTimerSource(queue: pushQueue)
    timer.schedule(deadline: .now() + 0.5, repeating: 1.0 / Double(fps))
    timer.setEventHandler {
        guard let frame = makeFrame(counter: counter, pool: pool,
                                    width: width, height: height) else { return }
        var fmtOut: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame,
            formatDescriptionOut: &fmtOut) == noErr, let fmt = fmtOut else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sbufOut: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleTiming: &timing, sampleBufferOut: &sbufOut) == noErr,
            let sbuf = sbufOut else { return }

        if CMSimpleQueueGetCount(sinkQueue) >= CMSimpleQueueGetCapacity(sinkQueue) {
            enqueueDrops += 1
            return
        }
        delegate.lock.lock()
        delegate.sendTimes[counter] = mach_absolute_time()
        delegate.lock.unlock()
        let retained = Unmanaged.passRetained(sbuf)
        if CMSimpleQueueEnqueue(sinkQueue, element: retained.toOpaque()) != 0 {
            retained.release()
            enqueueDrops += 1
            delegate.lock.lock()
            delegate.sendTimes.removeValue(forKey: counter)
            delegate.lock.unlock()
        } else {
            sentCount += 1
        }
        counter += 1
    }
    timer.resume()

    // 6. Let it run (main run loop, so AVFoundation stays serviced).
    RunLoop.main.run(until: Date().addingTimeInterval(seconds + 0.5))
    timer.cancel()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // drain in-flight

    delegate.lock.lock()
    let latencies = delegate.latenciesMs
    let unmatched = delegate.unmatchedFrames
    let neverArrived = delegate.sendTimes.count
    delegate.lock.unlock()

    print("   sent \(sentCount) frames, matched \(latencies.count), " +
          "unmatched captures \(unmatched), lost \(neverArrived), " +
          "enqueue drops \(enqueueDrops)")
    guard let stats = Stats(latencies) else {
        print("   FAILED: no frames made the round trip. Is another producer")
        print("   (PRISM.app) holding the sink stream?")
        return nil
    }
    print("   sink push → capture  \(stats.line())")
    return stats
}

// MARK: - Main

let opts = parseOptions()
print("PRISM latency harness — \(Date())")
print("")

var ringStats: Stats?
var cameraStats: Stats?

if opts.runRing {
    ringStats = runRingSelfTest(iterations: opts.ringIterations)
    print("")
}
if opts.runCamera {
    cameraStats = runCameraLoop(seconds: opts.cameraSeconds,
                                width: opts.width, height: opts.height,
                                fps: opts.fps)
    print("")
}

// LatencyReport-shaped summary (§6). The harness sits where clients sit, so
// "handoff" here is the full sink push → client receive hop, and audio added
// latency is the HAL input buffer (256 frames @ 48k = 5.33ms) plus the
// measured ring traversal.
print("── LatencyReport summary ──")
let audioBufferMs = 256.0 / 48_000.0 * 1000.0
if let r = ringStats {
    let audioAdded = audioBufferMs + r.p50
    print(String(format: "   audioAddedMs:  %6.2f   (%.2f HAL buffer + %.3f ring traversal p50)",
                 audioAdded, audioBufferMs, r.p50))
} else {
    print("   audioAddedMs:  n/a (ring test did not run)")
}
if let c = cameraStats {
    print(String(format: "   handoffMs:     %6.2f   (sink push → client receive, p50)", c.p50))
    print(String(format: "   totalAddedMs:  %6.2f   (video path added latency, p50; excludes", c.p50))
    print("                            physical capture + GPU effects — the running")
    print("                            app reports those in its own LatencyReport)")
    if let r = ringStats {
        let skew = c.p50 - (audioBufferMs + r.p50)
        print(String(format: "   syncSkewMs:    %+6.2f   (video − audio; §6 requires |skew| ≤ 15)", skew))
    }
} else {
    print("   handoffMs:     n/a (camera loop did not run)")
    print("   totalAddedMs:  n/a")
}
print("")
print("Budget context (§6): sink→source hop ≤ 3.0ms, audio total ≤ 12.0ms,")
print("A/V skew ≤ 15ms. See README \"Latency model\" for the full table.")
