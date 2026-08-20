// RollingSpeechBuffer.swift
// PRISM
//
// The window of 16 kHz audio a decode actually sees, and the bookkeeping
// that keeps word times absolute while the window slides (§5.32).
//
// The awkward part of live transcription is that the model wants overlap
// and the meeting does not stop. Each decode must re-read the previous
// sentence — that is what makes two hypotheses agree, which is the whole
// basis of `LocalAgreement` — while the buffer must not grow for the
// length of a meeting, and every word that comes out must be stamped with
// where it happened in the meeting rather than where it happened in the
// buffer.
//
// So: append at the head, trim at the tail, and carry an `offsetSamples`
// that counts what has been thrown away. A word's absolute time is derived
// from that offset and never from the buffer index. Getting this wrong is
// not a crash — it is a transcript that silently rewinds to 00:00 the first
// time the buffer trims, which is the kind of bug that survives a demo.
//
// The 30-second cap matches Whisper's own receptive field: the model pads
// or truncates to 30 s internally, so audio beyond that in one decode is
// paid for and discarded.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public struct RollingSpeechBuffer {

    public static let sampleRate = 16_000
    /// Whisper's window. Beyond this the model truncates anyway.
    public static let maxSamples = 30 * 16_000
    /// Kept behind the confirmed point when trimming, so the next decode
    /// still overlaps what the last one confirmed. Two seconds is enough
    /// for a clause and cheap enough to re-decode.
    public static let contextSamples = 2 * 16_000

    /// The audio the next decode will see.
    public private(set) var samples: [Float] = []
    /// How many samples have been trimmed away since the meeting started.
    /// The origin for every absolute time this buffer's words will carry.
    public private(set) var offsetSamples: Int = 0
    /// Samples appended but not yet decoded. The trigger for a decode.
    public private(set) var pendingSamples: Int = 0

    public init() {}

    // MARK: - Filling

    public mutating func append(_ new: [Float]) {
        guard !new.isEmpty else { return }
        samples.append(contentsOf: new)
        pendingSamples += new.count
        enforceCap()
    }

    public mutating func append(_ new: ArraySlice<Float>) {
        guard !new.isEmpty else { return }
        samples.append(contentsOf: new)
        pendingSamples += new.count
        enforceCap()
    }

    /// A gap in the captured audio — the user muted, or the tap ring lapped.
    ///
    /// This is deliberately not "insert silence". Silence is something the
    /// model will happily transcribe as "Thank you.", and stitching across a
    /// gap as though it were continuous produces a sentence that nobody
    /// said, assembled from two halves that were minutes apart. Dropping
    /// the buffer and advancing the offset means the transcript has an
    /// honest hole in it.
    public mutating func breakContinuity(advancingBy droppedSamples: Int) {
        offsetSamples += samples.count + max(0, droppedSamples)
        samples.removeAll(keepingCapacity: true)
        pendingSamples = 0
    }

    // MARK: - Decoding

    /// Seconds of audio waiting to be decoded.
    public var pendingSeconds: Double {
        Double(pendingSamples) / Double(Self.sampleRate)
    }

    public var durationSeconds: Double {
        Double(samples.count) / Double(Self.sampleRate)
    }

    /// Absolute position of `samples[0]`, for `SpeechRequest.sampleOffset`.
    public var requestOffset: Int { offsetSamples }

    /// Marks the current contents as decoded. Called when a decode is
    /// dispatched, not when it returns — a decode that takes 800 ms must not
    /// cause the 800 ms of audio that arrived meanwhile to be counted twice.
    public mutating func markDecoded() {
        pendingSamples = 0
    }

    /// Trims everything before `confirmedSampleIndex`, keeping
    /// `contextSamples` of overlap behind it.
    ///
    /// `confirmedSampleIndex` is absolute — it is where `LocalAgreement`
    /// last confirmed a word, in meeting time — so callers never have to
    /// reason about buffer indices, which is the arithmetic that goes wrong.
    public mutating func trim(confirmedTo confirmedSampleIndex: Int) {
        let keepFrom = max(0, confirmedSampleIndex - Self.contextSamples)
        let dropCount = keepFrom - offsetSamples
        guard dropCount > 0, dropCount <= samples.count else { return }
        samples.removeFirst(dropCount)
        offsetSamples += dropCount
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        offsetSamples = 0
        pendingSamples = 0
    }

    // MARK: - Time helpers

    /// Milliseconds from the start of the meeting for an absolute sample.
    public static func milliseconds(forSample index: Int) -> Int64 {
        Int64((Double(index) / Double(sampleRate)) * 1000.0)
    }

    /// The inverse, for turning a confirmed word's time back into a trim
    /// point.
    public static func sample(forMilliseconds ms: Int64) -> Int {
        Int((Double(ms) / 1000.0) * Double(sampleRate))
    }

    // MARK: - Private

    /// Hard cap. Reached only when nothing is being confirmed — a long run
    /// of speech the model keeps revising — so the oldest audio goes and the
    /// offset moves with it.
    private mutating func enforceCap() {
        guard samples.count > Self.maxSamples else { return }
        let excess = samples.count - Self.maxSamples
        samples.removeFirst(excess)
        offsetSamples += excess
    }
}
