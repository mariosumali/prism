// RingBufferTests.swift
// PRISMTests
//
// Exercises the shared-memory SPSC ring (§4.3): ordering, wraparound,
// underrun/overrun accounting, heartbeat liveness, and a two-thread stress
// run. Maps its own shared-memory region, so it is safe to run while
// PRISM.app is live.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class RingBufferTests: XCTestCase {

    private var producer: UnsafeMutablePointer<PRISMRingBuffer>!
    private var consumer: UnsafeMutablePointer<PRISMRingBuffer>!

    /// Deliberately NOT PRISM_SHM_NAME. That region belongs to whichever
    /// PRISM.app is running on this machine: sharing it lets the app write
    /// live audio into the buffer being asserted on, and tearDown's
    /// shm_unlink then destroys the app's ring out from under it. Both
    /// failures are silent and intermittent. Own the region instead.
    private static let shmName = "/horse.prism.audio.tests"

    override func setUp() {
        super.setUp()
        // A region surviving a crashed earlier run would carry its indices in.
        shm_unlink(Self.shmName)
        producer = PRISMRingBufferCreateProducerNamed(Self.shmName)
        XCTAssertNotNil(producer, "shm_open/mmap failed for producer")
        consumer = PRISMRingBufferOpenConsumerNamed(Self.shmName)
        XCTAssertNotNil(consumer, "shm_open/mmap failed for consumer")
    }

    override func tearDown() {
        PRISMRingBufferCloseProducer(producer)
        PRISMRingBufferCloseConsumer(consumer)
        shm_unlink(Self.shmName)
        super.tearDown()
    }

    /// Interleaved stereo frames whose L channel encodes the frame index.
    private func makeFrames(start: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * Int(PRISM_CHANNELS))
        for i in 0..<count {
            out[i * 2] = Float(start + i)
            out[i * 2 + 1] = Float(start + i) + 0.5
        }
        return out
    }

    func testRoundTripPreservesSamples() {
        let frames = 256
        let input = makeFrames(start: 0, count: frames)
        input.withUnsafeBufferPointer {
            PRISMRingBufferWrite(producer, $0.baseAddress!, UInt32(frames))
        }
        var output = [Float](repeating: -1, count: frames * 2)
        let got = output.withUnsafeMutableBufferPointer {
            PRISMRingBufferRead(consumer, $0.baseAddress!, UInt32(frames))
        }
        XCTAssertEqual(got, UInt32(frames))
        XCTAssertEqual(output, input)
        XCTAssertEqual(PRISMRingBufferUnderrunCount(consumer), 0)
        XCTAssertEqual(PRISMRingBufferOverrunCount(consumer), 0)
    }

    func testWraparoundIntegrity() {
        let cap = Int(PRISM_RING_CAPACITY)
        // Park the indices near the end of the ring, then write across the seam.
        let preroll = cap - 100
        var written = 0
        while written < preroll {
            let chunk = min(4096, preroll - written)
            let data = makeFrames(start: written, count: chunk)
            data.withUnsafeBufferPointer {
                PRISMRingBufferWrite(producer, $0.baseAddress!, UInt32(chunk))
            }
            var sink = [Float](repeating: 0, count: chunk * 2)
            _ = sink.withUnsafeMutableBufferPointer {
                PRISMRingBufferRead(consumer, $0.baseAddress!, UInt32(chunk))
            }
            written += chunk
        }
        // This write spans the wrap point.
        let spanning = 300
        let input = makeFrames(start: written, count: spanning)
        input.withUnsafeBufferPointer {
            PRISMRingBufferWrite(producer, $0.baseAddress!, UInt32(spanning))
        }
        var output = [Float](repeating: -1, count: spanning * 2)
        let got = output.withUnsafeMutableBufferPointer {
            PRISMRingBufferRead(consumer, $0.baseAddress!, UInt32(spanning))
        }
        XCTAssertEqual(got, UInt32(spanning))
        XCTAssertEqual(output, input, "data crossing the ring seam must be intact")
    }

    func testUnderrunZeroFillsAndCounts() {
        let input = makeFrames(start: 0, count: 100)
        input.withUnsafeBufferPointer {
            PRISMRingBufferWrite(producer, $0.baseAddress!, 100)
        }
        var output = [Float](repeating: -1, count: 256 * 2)
        let got = output.withUnsafeMutableBufferPointer {
            PRISMRingBufferRead(consumer, $0.baseAddress!, 256)
        }
        XCTAssertEqual(got, 100, "only the real frames are reported")
        XCTAssertEqual(Array(output[0..<200]), input)
        XCTAssertTrue(output[200...].allSatisfy { $0 == 0 },
                      "missing tail must be silence, not stale data")
        XCTAssertEqual(PRISMRingBufferUnderrunCount(consumer), 1)
    }

    func testOverrunDropsOldestAndCounts() {
        let cap = Int(PRISM_RING_CAPACITY)
        let total = cap + 500
        var start = 0
        while start < total {
            let chunk = min(8192, total - start)
            let data = makeFrames(start: start, count: chunk)
            data.withUnsafeBufferPointer {
                PRISMRingBufferWrite(producer, $0.baseAddress!, UInt32(chunk))
            }
            start += chunk
        }
        XCTAssertGreaterThan(PRISMRingBufferOverrunCount(producer), 0)
        // The ring must now hold exactly the newest `cap` frames.
        var output = [Float](repeating: -1, count: 1024 * 2)
        let got = output.withUnsafeMutableBufferPointer {
            PRISMRingBufferRead(consumer, $0.baseAddress!, 1024)
        }
        XCTAssertEqual(got, 1024)
        let firstIndex = Int(output[0])
        XCTAssertEqual(firstIndex, total - cap,
                       "oldest frames are dropped on overrun; read resumes at the survivor window")
    }

    func testHeartbeatLiveness() {
        XCTAssertTrue(PRISMRingBufferProducerIsAlive(consumer, mach_absolute_time()))
        // A heartbeat far in the past must read as dead (§4.3: 500ms).
        PRISMRingBufferSetProducerHeartbeat(producer, 1)
        XCTAssertFalse(PRISMRingBufferProducerIsAlive(consumer, mach_absolute_time()))
        // Fresh write revives it.
        let data = makeFrames(start: 0, count: 32)
        data.withUnsafeBufferPointer {
            PRISMRingBufferWrite(producer, $0.baseAddress!, 32)
        }
        XCTAssertTrue(PRISMRingBufferProducerIsAlive(consumer, mach_absolute_time()))
        // producerAlive == 0 overrides a fresh heartbeat.
        PRISMRingBufferSetProducerAlive(producer, false)
        XCTAssertFalse(PRISMRingBufferProducerIsAlive(consumer, mach_absolute_time()))
    }

    func testFillLevelTracks() {
        XCTAssertEqual(PRISMRingBufferFillLevel(consumer), 0)
        let data = makeFrames(start: 0, count: 500)
        data.withUnsafeBufferPointer {
            PRISMRingBufferWrite(producer, $0.baseAddress!, 500)
        }
        XCTAssertEqual(PRISMRingBufferFillLevel(consumer), 500)
        var sink = [Float](repeating: 0, count: 200 * 2)
        _ = sink.withUnsafeMutableBufferPointer {
            PRISMRingBufferRead(consumer, $0.baseAddress!, 200)
        }
        XCTAssertEqual(PRISMRingBufferFillLevel(consumer), 300)
    }

    /// Two-thread stress: values may skip forward (overrun drops) but must
    /// never repeat or go backward, and every read chunk must be internally
    /// contiguous modulo silence tails.
    func testConcurrentStress() {
        let seconds = 2.0
        let producerPtr = producer!
        let consumerPtr = consumer!
        let stop = expectation(description: "consumer done")
        var violations = 0
        var framesRead: UInt64 = 0

        let writerThread = Thread {
            var index = 0
            let deadline = Date(timeIntervalSinceNow: seconds)
            while Date() < deadline {
                let chunk = 256
                var data = [Float](repeating: 0, count: chunk * 2)
                for i in 0..<chunk {
                    data[i * 2] = Float(index + i)
                    data[i * 2 + 1] = Float(index + i)
                }
                data.withUnsafeBufferPointer {
                    PRISMRingBufferWrite(producerPtr, $0.baseAddress!, UInt32(chunk))
                }
                index += chunk
                usleep(1000)   // ~4× real-time at 48kHz
            }
        }
        let readerThread = Thread {
            var expected: Float = -1
            var out = [Float](repeating: 0, count: 512 * 2)
            let deadline = Date(timeIntervalSinceNow: seconds + 0.2)
            while Date() < deadline {
                let got = out.withUnsafeMutableBufferPointer {
                    PRISMRingBufferRead(consumerPtr, $0.baseAddress!, 512)
                }
                if got > 0 {
                    for i in 0..<Int(got) {
                        let v = out[i * 2]
                        if expected >= 0 && v < expected {
                            violations += 1   // regression = corruption
                        }
                        expected = v + 1
                    }
                    framesRead += UInt64(got)
                }
                usleep(2000)
            }
            stop.fulfill()
        }
        writerThread.start()
        readerThread.start()
        wait(for: [stop], timeout: seconds + 5)
        XCTAssertEqual(violations, 0, "sample stream must never move backward")
        XCTAssertGreaterThan(framesRead, 48_000,
                             "stress run should move at least a second of audio")
    }
}
